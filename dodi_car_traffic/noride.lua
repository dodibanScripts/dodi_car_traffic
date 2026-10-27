-- Traffic cars with an NPC at the wheel can't be boarded (only carjack takes them).
-- Vanilla enter seated the player next to the driver, who kept driving, and the game holds a
-- passenger in the seat while the car moves -> player stuck inside, no way out.
-- Fallback: player ends up inside anyway (warp, ragdoll into it) -> car halts, player is put out.

local Native = {
    BringVehicleToHalt = 0x260BE8F09E326A20,
    StopBringingVehicleToHalt = 0x7C06330BFDDA182E,
    TaskLeaveVehicle = 0xD3DBCE61A490BE02,
    WarpPedOutOfVehicle = 0xE0B61ED8BB37712F,
    SetPedOffTransportSeat = 0x8886D83A430537FD,
    GetVehiclePedIsEntering = 0xF92691AED837A5FC,
    GetSeatPedIsTryingToEnter = 0x6F4C85ACD641BCD2,
}

local NR = Config.NoRide
local ENTER_CONTROLS = {
    `INPUT_ENTER`,
    `INPUT_VEH_HORSE_ENTER`,
    `INPUT_VEH_DRAFT_SWITCH_DRIVERS`,
}

local lastTip = 0
local function tip()
    local now = GetGameTimer()
    if now - lastTip > 4000 then
        lastTip = now
        TriggerEvent('dodi_notifys:Tip', NR.tip, 4000)
    end
end

-- Traffic vehicle whose NPC driver is alive and still in the seat
local function driverAtWheel(entry)
    if entry.parked then
        return 0
    end
    local veh, ped = DodiTraffic.resolve(entry)
    if veh == 0 or ped == 0 or IsEntityDead(ped) or GetPedInVehicleSeat(veh, Config.DriverSeat) ~= ped then
        return 0
    end
    return veh
end

local function trafficVehicleOf(veh)
    for _, entry in pairs(DodiTraffic.known) do
        local v = DodiTraffic.resolve(entry)
        if v == veh then
            return entry
        end
    end
    return nil
end

local function cancelEnter(ped)
    Citizen.InvokeNative(Native.SetPedOffTransportSeat, ped, 0)
    ClearPedTasks(ped, true, true)
end

local function requestControl(entity)
    if NetworkHasControlOfEntity(entity) then
        return true
    end
    NetworkRequestControlOfEntity(entity)
    local attempts = 0
    while not NetworkHasControlOfEntity(entity) and attempts < 5 do
        Wait(50)
        attempts = attempts + 1
    end
    return NetworkHasControlOfEntity(entity)
end

local function putOut(ped, veh, entry)
    tip()
    local halted = false
    if GetEntitySpeed(veh) > NR.exitSpeed and requestControl(veh) then
        Citizen.InvokeNative(Native.BringVehicleToHalt, veh, 3.0, -1, false)
        halted = true
    end
    local deadline = GetGameTimer() + NR.haltTimeoutMs
    while DoesEntityExist(veh) and GetEntitySpeed(veh) > NR.exitSpeed and GetGameTimer() < deadline do
        Wait(100)
    end
    Citizen.InvokeNative(Native.TaskLeaveVehicle, ped, veh, 0, 0)
    deadline = GetGameTimer() + NR.leaveTimeoutMs
    while GetVehiclePedIsIn(ped, false) == veh and GetGameTimer() < deadline do
        Wait(100)
    end
    if GetVehiclePedIsIn(ped, false) == veh then
        Citizen.InvokeNative(Native.WarpPedOutOfVehicle, ped)
        local side = GetOffsetFromEntityInWorldCoords(veh, 1.6, 0.0, 0.3)
        SetEntityCoords(ped, side.x, side.y, side.z, false, false, false, false)
    end
    if halted and DoesEntityExist(veh) then
        Citizen.InvokeNative(Native.StopBringingVehicleToHalt, veh)
        entry.managed = false -- owner loop re-tasks the drive
    end
end

-- E on the driver door = vanilla jack (carjack.lua adopts it as stolen). Passenger doors stay blocked.
local function pullOutAllowed()
    return Config.Carjack.enabled and Config.Carjack.allowPullOut
end

local function enteringVeh(ped)
    return Citizen.InvokeNative(Native.GetVehiclePedIsEntering, ped, Citizen.ResultAsInteger())
end

local insideSince = 0

CreateThread(function()
    while not DodiTraffic or not DodiTraffic.known do
        Wait(500)
    end
    while true do
        local sleep = 500
        if NR.enabled and next(DodiTraffic.known) then
            local ped = PlayerPedId()
            local seatedVeh = GetVehiclePedIsIn(ped, false)
            if seatedVeh ~= 0 then
                local entry = trafficVehicleOf(seatedVeh)
                -- grace: mid-jack the NPC is still at the wheel while the game already counts us inside
                if entry and not entry.jacked and driverAtWheel(entry) == seatedVeh and enteringVeh(ped) ~= seatedVeh then
                    sleep = 100
                    insideSince = insideSince ~= 0 and insideSince or GetGameTimer()
                    if GetGameTimer() - insideSince > NR.jackGraceMs then
                        insideSince = 0
                        putOut(ped, seatedVeh, entry)
                    end
                else
                    insideSince = 0
                end
            else
                insideSince = 0
                local pc = GetEntityCoords(ped)
                local nearVeh = 0
                for _, entry in pairs(DodiTraffic.known) do
                    local veh = driverAtWheel(entry)
                    if veh ~= 0 and #(GetEntityCoords(veh) - pc) < NR.blockDist then
                        nearVeh = veh
                        break
                    end
                end
                if nearVeh ~= 0 then
                    sleep = 0
                    if not pullOutAllowed() then
                        for i = 1, #ENTER_CONTROLS do
                            DisableControlAction(0, ENTER_CONTROLS[i], true)
                            if IsDisabledControlJustPressed(0, ENTER_CONTROLS[i]) then
                                tip()
                            end
                        end
                    end
                    if enteringVeh(ped) == nearVeh then
                        local seat = Citizen.InvokeNative(Native.GetSeatPedIsTryingToEnter, ped, Citizen.ResultAsInteger())
                        if not pullOutAllowed() or seat ~= Config.DriverSeat then
                            cancelEnter(ped)
                            tip()
                        end
                    end
                end
            end
        end
        Wait(sleep)
    end
end)
