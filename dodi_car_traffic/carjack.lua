-- Armed carjack of traffic cars / bikes.
-- Aim (free aim or lock-on) at the driver, the vehicle or the bike rider clone:
--   * floorItChance: driver panics and speeds away
--   * else: BRING_VEHICLE_TO_HALT + TASK_HANDS_UP (cars). Prompt G -> driver leaves and flees,
--     server takes the vehicle out of the population and hands it to dodi_cars (unowned, dodiStolen).
-- Natives / params as R* uses them in script_rel (halt 5.0, hands up -1, flee 1000 / 3.0).

local Native = {
    TaskVehicleDriveWander = 0x480142959D337D00,
    SetDriveTaskCruiseSpeed = 0x5C9B84BD7D31D908,
    BringVehicleToHalt = 0x260BE8F09E326A20,
    StopBringingVehicleToHalt = 0x7C06330BFDDA182E,
    TaskHandsUp = 0xF2EAB31979A7F910,
    TaskLeaveVehicle = 0xD3DBCE61A490BE02,
    TaskSmartFleePed = 0x22B0D0E37CCB840D,
    SetPedKeepTask = 0x971D38760FBC02EF,
    SetVehicleDoorsLocked = 0x96F78A6A075D55D9,
    TaskPlayAnimAdvanced = 0x83CDB10EA29B370B,
    GetAnimDuration = 0x9FFAF4940A54CC09,
    RequestAnimDict = 0xA862A2AD321F94B4,
    SetPedOffTransportSeat = 0x8886D83A430537FD,
    WarpPedOutOfVehicle = 0xE0B61ED8BB37712F,
    SetVehicleExclusiveDriver = 0xC6B9BF123B9463B6,
    SetTransportExclusiveDriver = 0x4248AB2EEB3C75AD,
    SetBlipName = 0x9CB1A1623062F402,
    SetEntityNoCollisionEntity = 0xE037BF068223C38D,
    SetVehicleOnGroundProperly = 0x7263332501E07F52,
    SetEntityDynamic = 0xFBFC4473F66CE344,
    ActivatePhysics = 0x710311ADF0E20730,
    SetVehicleUndriveable = 0x6E884BAB713A2A94,
    SetVehicleHandbrake = 0x91BE51AEC4E99710,
    SetVehicleEngineOn = 0xB64CFA14CB9A2E78,
    SetDrivingSeat = 0x4BA972D0E5AD8122,
    GetDrivingSeat = 0xE62754D09354F6CF,
    IsVehicleDriveable = 0xB86D29B10F627379,
    IsEntityStatic = 0x86468ADFA0F6B861,
}

local CJ = Config.Carjack
local P = Config.CarjackPolice
local GUNS = 4 -- IS_PED_ARMED flag

local job = nil -- { netVeh, entry, veh, ped, isBike, stage = 'surrender'|'leaving', lastAim, leaveDeadline }
local floorUntil = {} -- [netVeh] = gameTimer

local function dbg(msg)
    if DodiTraffic.isDebug() then
        print(('[dodi_car_traffic:carjack] %s'):format(msg))
    end
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

local function requestDict(dict, timeoutMs)
    if HasAnimDictLoaded(dict) then
        return true
    end
    Citizen.InvokeNative(Native.RequestAnimDict, dict)
    local deadline = GetGameTimer() + (timeoutMs or 0)
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do
        Wait(10)
    end
    return HasAnimDictLoaded(dict)
end

---------------------------------------------------------------------------
-- Prompt
---------------------------------------------------------------------------

local prompt = Citizen.InvokeNative(0x04F97DE45A519419) -- PromptRegisterBegin
PromptSetControlAction(prompt, CJ.promptKey)
PromptSetText(prompt, CreateVarString(10, 'LITERAL_STRING', CJ.promptCar))
PromptSetEnabled(prompt, false)
PromptSetVisible(prompt, false)
PromptSetHoldMode(prompt, false)
PromptRegisterEnd(prompt)

local function showPrompt(show)
    PromptSetEnabled(prompt, show)
    PromptSetVisible(prompt, show)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function aimTarget()
    local pid = PlayerId()
    if not IsPedArmed(PlayerPedId(), GUNS) then
        return 0
    end
    local ok, ent = GetEntityPlayerIsFreeAimingAt(pid)
    if ok and ent and ent ~= 0 then
        return ent
    end
    ok, ent = GetPlayerTargetEntity(pid)
    if ok and ent and ent ~= 0 then
        return ent
    end
    return 0
end

-- entity (vehicle / driver / bike clone) -> entry, veh, ped
local function entryFor(ent)
    local known = DodiTraffic.known
    local cloneNet = DodiTraffic.cloneNet and DodiTraffic.cloneNet[ent]
    if cloneNet and known[cloneNet] then
        local veh, ped = DodiTraffic.resolve(known[cloneNet])
        return known[cloneNet], veh, ped
    end
    for _, e in pairs(known) do
        if not e.parked then
            local veh, ped = DodiTraffic.resolve(e)
            if veh ~= 0 and (ent == veh or ent == ped) then
                return e, veh, ped
            end
        end
    end
    return nil
end

local function isJobTarget(ent)
    return job and ent ~= 0 and (ent == job.veh or ent == job.ped or DodiTraffic.cloneNet[ent] == job.netVeh)
end

local function vehicleLabel(entry)
    local cars = DodiTraffic.getDodiCarsConfig().Cars or {}
    local car = entry.carId and cars[entry.carId]
    return car and car.label or entry.model
end

local function placeLabel(pos)
    for _, city in pairs(Config.Cities) do
        local dx, dy = pos.x - city.center.x, pos.y - city.center.y
        if math.sqrt(dx * dx + dy * dy) <= city.radius then
            return city.label or ''
        end
    end
    return ''
end

local function hasWitness(pos, victim)
    for _, p in ipairs(GetGamePool('CPed')) do
        if p ~= victim
            and not IsPedAPlayer(p)
            and not DodiTraffic.cloneNet[p]
            and not IsEntityDead(p)
            and IsPedHuman(p)
            and #(GetEntityCoords(p) - pos) <= P.witnessRadius
        then
            return true
        end
    end
    return false
end

local function rollPoliceAlert(entry, veh, ped, floorIt, pulled)
    if not P.enabled or (floorIt and not P.alertOnFloorIt) then
        return
    end
    local pos = GetEntityCoords(veh)
    local witness = hasWitness(pos, ped)
    local chance = witness and P.chanceWithWitness or P.chanceNoWitness
    local roll = math.random()
    dbg(('police roll witness=%s chance=%.2f roll=%.2f'):format(tostring(witness), chance, roll))
    if roll < chance then
        TriggerServerEvent('dodi_car_traffic:server:policeAlert', { x = pos.x, y = pos.y, z = pos.z }, {
            place = placeLabel(pos),
            vehicle = vehicleLabel(entry),
            floorIt = floorIt,
            pulled = pulled,
        })
    end
end

-- Older traffic cars were spawned with the NPC as exclusive driver: free the seat for the robber.
local function clearExclusiveDriver(veh)
    Citizen.InvokeNative(Native.SetVehicleExclusiveDriver, veh, 0, 0)
    Citizen.InvokeNative(Native.SetVehicleExclusiveDriver, veh, 0, 1)
    Citizen.InvokeNative(Native.SetTransportExclusiveDriver, veh, 0, false)
end

local function setJackState(netVeh, jackState)
    local e = DodiTraffic.known[netVeh]
    if e then
        e.jacked = jackState
    end
    TriggerServerEvent('dodi_car_traffic:server:jackState', netVeh, jackState)
end

---------------------------------------------------------------------------
-- Flow
---------------------------------------------------------------------------

local function startJack(entry, veh, ped)
    local me = PlayerPedId()
    if entry.jacked or #(GetEntityCoords(me) - GetEntityCoords(veh)) > CJ.maxDist then
        return
    end
    if GetEntitySpeed(veh) > CJ.maxSpeed then
        return
    end
    if not requestControl(veh) or not requestControl(ped) then
        dbg(('no control net=%s'):format(entry.netVeh))
        return
    end

    local rider = DodiTraffic.getRiderCfg(entry.model)
    local isBike = rider and rider.clone ~= nil

    if math.random() < CJ.floorItChance then
        ClearPedTasks(ped)
        local speed = (entry.speed or Config.Driving.speed.max) * CJ.floorItSpeedMult
        Citizen.InvokeNative(Native.TaskVehicleDriveWander, ped, veh, speed + 0.0, Config.Driving.drivingStyle)
        Citizen.InvokeNative(Native.SetDriveTaskCruiseSpeed, ped, speed + 0.0)
        Citizen.InvokeNative(Native.SetPedKeepTask, ped, true)
        floorUntil[entry.netVeh] = GetGameTimer() + CJ.floorItMs
        setJackState(entry.netVeh, 'floor')
        rollPoliceAlert(entry, veh, ped, true)
        dbg(('floor it net=%s'):format(entry.netVeh))
        return
    end

    Citizen.InvokeNative(Native.BringVehicleToHalt, veh, CJ.haltDist + 0.0, -1, false)
    if not isBike then
        ClearPedTasks(ped)
        Citizen.InvokeNative(Native.TaskHandsUp, ped, -1, me, -1, false)
    end
    setJackState(entry.netVeh, 'surrender')

    job = {
        netVeh = entry.netVeh,
        entry = entry,
        veh = veh,
        ped = ped,
        isBike = isBike,
        stage = 'surrender',
        lastAim = GetGameTimer(),
    }
    PromptSetText(prompt, CreateVarString(10, 'LITERAL_STRING', isBike and CJ.promptBike or CJ.promptCar))
    if isBike and CJ.bikeDismount.enabled then
        local D = CJ.bikeDismount
        for _, side in ipairs({ 'left', 'right' }) do -- preload while halting
            requestDict(D.startDict:format(side), 0)
            requestDict(D.offDict:format(side), 0)
        end
    end
    rollPoliceAlert(entry, veh, ped, false)
    dbg(('surrender net=%s bike=%s'):format(entry.netVeh, tostring(isBike)))
end

local function releaseJob()
    if not job then
        return
    end
    if DoesEntityExist(job.veh) then
        Citizen.InvokeNative(Native.StopBringingVehicleToHalt, job.veh)
    end
    if DoesEntityExist(job.ped) and NetworkHasControlOfEntity(job.ped) then
        ClearPedTasks(job.ped)
    end
    setJackState(job.netVeh, nil) -- owner re-tasks it (client.lua)
    dbg(('released net=%s'):format(job.netVeh))
    job = nil
    showPrompt(false)
end

local function animMs(dict, name)
    local secs = Citizen.InvokeNative(Native.GetAnimDuration, dict, name, Citizen.ResultAsFloat()) or 0.0
    return math.floor(secs * 1000)
end

-- 'auto': get off on the side away from the robber.
local function dismountSide(veh, from)
    local D = CJ.bikeDismount
    if D.side ~= 'auto' or not from then
        return D.side == 'right' and 'right' or 'left'
    end
    local rel = GetOffsetFromEntityGivenWorldCoords(veh, from.x, from.y, from.z)
    return rel.x < 0.0 and 'right' or 'left'
end

-- get_off_to_run_<angle>: angle relative to the bike heading (+ = left, like headings), snapped to 45.
local function dismountAngle(veh, from)
    local D = CJ.bikeDismount
    if D.runAngle then
        return D.runAngle
    end
    if not from then
        return 0
    end
    local vp = GetEntityCoords(veh)
    local away = GetHeadingFromVector_2d(vp.x - from.x, vp.y - from.y)
    local rel = ((away - GetEntityHeading(veh)) * D.angleSign + 180.0) % 360.0 - 180.0
    local snapped = math.floor(rel / 45.0 + 0.5) * 45
    return math.max(-D.maxAngle, math.min(D.maxAngle, snapped))
end

local dismountToken = {}

-- Horse dismount as the motion system plays it: get_off_start -> get_off_to_run_<angle>.
-- TASK_PLAY_ANIM_ADVANCED args as R* passes them (..., -1, flags, phase 0, rotOrder 2, ik 0, 0).
-- force = { side, angle } (calibration). Returns total ms, side, angle - or nil.
local function playBikeDismount(ped, veh, from, force)
    local D = CJ.bikeDismount
    if not D.enabled then
        return nil
    end
    local side = force and force.side or dismountSide(veh, from)
    local angle = force and force.angle or dismountAngle(veh, from)
    local startDict, offDict = D.startDict:format(side), D.offDict:format(side)
    local offClip = D.offClip:format(angle)
    if not requestDict(startDict, 1000) or not requestDict(offDict, 1000) then
        return nil
    end
    local startMs, offMs = animMs(startDict, D.startClip), animMs(offDict, offClip)
    if startMs <= 0 or offMs <= 0 then
        dbg(('dismount clip missing: %s / %s'):format(D.startClip, offClip))
        return nil
    end

    local o = GetOffsetFromEntityInWorldCoords(veh, D.offset.x, D.offset.y, D.offset.z)
    local h = GetEntityHeading(veh) + D.heading
    local function play(dict, name, blendIn, blendOut)
        Citizen.InvokeNative(
            Native.TaskPlayAnimAdvanced,
            ped, dict, name,
            o.x, o.y, o.z,
            0.0, 0.0, h,
            blendIn + 0.0, blendOut + 0.0,
            -1, D.flags, 0.0, 2, 0, 0
        )
    end

    play(startDict, D.startClip, D.blendIn, -D.chainBlend)
    local token = {}
    dismountToken[ped] = token
    local chainAt = math.max(0, startMs - D.chainOverlapMs)
    SetTimeout(chainAt, function()
        if dismountToken[ped] == token and DoesEntityExist(ped) and not IsEntityDead(ped) then
            play(offDict, offClip, D.chainBlend, D.blendOut)
        end
        if dismountToken[ped] == token then
            dismountToken[ped] = nil
        end
    end)
    dbg(('dismount side=%s angle=%d start=%dms off=%dms'):format(side, angle, startMs, offMs))
    return chainAt + offMs, side, angle
end

local function isSeated(ped, veh)
    return GetVehiclePedIsIn(ped, false) == veh or IsPedInVehicle(ped, veh, false)
end

-- Same sequence as dodi_cars kickPedOutOfVehicle (works on the custom bike layouts, which have
-- no exit anim): off transport seat -> warp out -> leave 4160 -> still in: side + warp again.
local function warpOut(ped, veh)
    requestControl(ped)
    requestControl(veh)
    Citizen.InvokeNative(Native.SetPedOffTransportSeat, ped, 0)
    Citizen.InvokeNative(Native.WarpPedOutOfVehicle, ped)
    Citizen.InvokeNative(Native.TaskLeaveVehicle, ped, veh, 4160, 0)
    if isSeated(ped, veh) then
        local side = GetOffsetFromEntityInWorldCoords(veh, CJ.warpSideX, 0.0, 0.5)
        SetEntityCoords(ped, side.x, side.y, side.z, false, false, false, false)
        ClearPedTasks(ped, true, true)
        Citizen.InvokeNative(Native.WarpPedOutOfVehicle, ped)
    end
end

local function orderOut()
    local veh, ped = job.veh, job.ped
    if not requestControl(ped) then
        return
    end
    job.stage = 'leaving'
    job.leaveDeadline = GetGameTimer() + (job.isBike and 0 or CJ.leaveTimeoutMs)
    job.nextWarpAt = 0
    showPrompt(false)
    if not job.isBike then
        ClearPedTasks(ped)
        Citizen.InvokeNative(Native.TaskLeaveVehicle, ped, veh, 0, 0)
    end
    -- bike: tickJob warps it out (rider stays hidden behind the clone until it is really off)
end

-- The dismount starts with the ped capsule inside the bike: the push-out shoves the light bike
-- through its thin YFT ground bound (limbo). Freeze it and cut ped<->bike collision for the clip.
local function holdBikeDuringDismount(veh, ped, ms, onDone)
    local start = GetEntityCoords(veh)
    local startRot = GetEntityRotation(veh, 2)
    FreezeEntityPosition(veh, true)
    CreateThread(function()
        local me = PlayerPedId()
        local untilAt = GetGameTimer() + ms
        while GetGameTimer() < untilAt and DoesEntityExist(veh) and GetVehiclePedIsIn(me, false) ~= veh do
            if DoesEntityExist(ped) then
                Citizen.InvokeNative(Native.SetEntityNoCollisionEntity, ped, veh, false)
                Citizen.InvokeNative(Native.SetEntityNoCollisionEntity, veh, ped, false)
            end
            Wait(0)
        end
        if DoesEntityExist(veh) then
            requestControl(veh)
            FreezeEntityPosition(veh, false)
            SetEntityCollision(veh, true, true)
            local now = GetEntityCoords(veh)
            if now.z < start.z - CJ.bikeSinkTolerance then
                dbg(('bike sank %.2fm, restoring'):format(start.z - now.z))
                SetEntityCoordsNoOffset(veh, start.x, start.y, start.z + 0.1, false, false, false)
                SetEntityRotation(veh, startRot.x, startRot.y, startRot.z, 2, true)
                Citizen.InvokeNative(Native.SetVehicleOnGroundProperly, veh, false)
            end
        end
        onDone()
    end)
end

local function finishSteal()
    local veh, ped, me, netVeh, isBike = job.veh, job.ped, PlayerPedId(), job.netVeh, job.isBike
    job = nil -- entry.jacked stays 'surrender' until the server drops it, so no re-jack meanwhile
    local function flee()
        if DoesEntityExist(ped) and not IsEntityDead(ped) then
            Citizen.InvokeNative(Native.TaskSmartFleePed, ped, me, 1000.0, -1, 0, 3.0, 0)
            Citizen.InvokeNative(Native.SetPedKeepTask, ped, true)
        end
    end
    local function handOver()
        if not DoesEntityExist(veh) then
            return
        end
        Citizen.InvokeNative(Native.StopBringingVehicleToHalt, veh)
        Citizen.InvokeNative(Native.SetVehicleDoorsLocked, veh, 0)
        if requestControl(veh) then
            clearExclusiveDriver(veh)
        end
        -- dodi_cars spawnShell wakes the chassis physics: only after the bike is released
        TriggerServerEvent('dodi_car_traffic:server:stolen', netVeh)
        TriggerEvent('dodi_notifys:Tip', CJ.stolenTip, 4000)
        dbg(('stolen net=%s'):format(netVeh))
    end

    if isBike then
        -- rider is off the seat but still hidden: start the dismount (mounted pose), then show it
        -- and drop the clone in the same frame. A task given early would cut the anim / ragdoll.
        requestControl(veh)
        local dur = playBikeDismount(ped, veh, GetEntityCoords(me))
        SetEntityVisible(ped, true)
        DodiTraffic.killClone(netVeh)
        local holdMs
        if dur and dur > 0 then
            holdMs = dur
            SetTimeout(math.max(0, dur - 150), flee)
        else
            holdMs = CJ.bikeRagdollMs
            SetPedToRagdoll(ped, CJ.bikeRagdollMs, CJ.bikeRagdollMs, 0, false, false, false)
            SetTimeout(CJ.bikeRagdollMs + 300, flee)
        end
        holdBikeDuringDismount(veh, ped, holdMs, handOver)
    else
        SetEntityVisible(ped, true)
        flee()
        handOver()
    end

    -- fled driver becomes ambient once out of sight
    SetTimeout(20000, function()
        if DoesEntityExist(ped) then
            SetPedAsNoLongerNeeded(ped)
        end
    end)
end

local function tickJob()
    if not DoesEntityExist(job.veh) or not DoesEntityExist(job.ped) or not DodiTraffic.known[job.netVeh] then
        job = nil
        showPrompt(false)
        return
    end
    local now = GetGameTimer()
    local me = PlayerPedId()
    local dist = #(GetEntityCoords(me) - GetEntityCoords(job.veh))

    if job.stage == 'surrender' then
        if isJobTarget(aimTarget()) then
            job.lastAim = now
        end
        local show = dist <= CJ.keepDist and IsPedArmed(me, GUNS)
        showPrompt(show)
        if show and IsControlJustPressed(0, CJ.promptKey) then
            orderOut()
        elseif now - job.lastAim > CJ.releaseMs or dist > CJ.keepDist * 2.0 then
            releaseJob()
        end
    elseif job.stage == 'leaving' then
        if not isSeated(job.ped, job.veh) then
            finishSteal()
        elseif now > job.leaveDeadline then
            -- exit anim missing / timed out: warp, retry every 300ms, give up after warpGiveUpMs
            if now >= job.nextWarpAt then
                job.nextWarpAt = now + 300
                warpOut(job.ped, job.veh)
            end
            if now > job.leaveDeadline + CJ.warpGiveUpMs then
                dbg(('could not get driver out net=%s, releasing'):format(job.netVeh))
                releaseJob()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Vanilla jack (E on the driver door, no gun): the player pulled the NPC out and took the seat.
-- Same outcome as the armed carjack: driver flees, car becomes a dodi_cars car, police roll.
-- Without this the NPC's kept drive task / the owner's re-seat put him back on top of the player.
---------------------------------------------------------------------------

local pulledSent = {} -- [netVeh] = gameTimer of the last pulledOut request (resent while still traffic)

-- The armed flow hands over a released car before anyone sits in it. Here the robber is already
-- at the wheel: own it, undo anything the traffic side left on it, engine on.
local function makeDrivable(veh)
    local deadline = GetGameTimer() + 2000
    while not NetworkHasControlOfEntity(veh) and GetGameTimer() < deadline do
        NetworkRequestControlOfEntity(veh)
        Wait(50)
    end
    if not NetworkHasControlOfEntity(veh) then
        dbg('pulled out: no control of the vehicle')
        return
    end
    Citizen.InvokeNative(Native.StopBringingVehicleToHalt, veh)
    Citizen.InvokeNative(Native.SetVehicleDoorsLocked, veh, 0)
    clearExclusiveDriver(veh)
    FreezeEntityPosition(veh, false)
    Citizen.InvokeNative(Native.SetEntityDynamic, veh, true)
    Citizen.InvokeNative(Native.ActivatePhysics, veh)
    Citizen.InvokeNative(Native.SetVehicleUndriveable, veh, false)
    Citizen.InvokeNative(Native.SetVehicleHandbrake, veh, false)
    Citizen.InvokeNative(Native.SetDrivingSeat, veh, Config.DriverSeat)
    Citizen.InvokeNative(Native.SetVehicleEngineOn, veh, true, true)
end

local function adoptPulledOut(netVeh, entry, veh, ped)
    pulledSent[netVeh] = GetGameTimer()
    local me = PlayerPedId()
    makeDrivable(veh)
    if ped ~= 0 and DoesEntityExist(ped) then
        if requestControl(ped) then
            ClearPedTasks(ped)
            Citizen.InvokeNative(Native.SetPedKeepTask, ped, false)
            SetBlockingOfNonTemporaryEvents(ped, false)
            SetEntityVisible(ped, true)
            if not IsEntityDead(ped) then
                Citizen.InvokeNative(Native.TaskSmartFleePed, ped, me, 1000.0, -1, 0, 3.0, 0)
            end
        end
        SetTimeout(20000, function()
            if DoesEntityExist(ped) then
                SetPedAsNoLongerNeeded(ped)
            end
        end)
    end
    DodiTraffic.killClone(netVeh)
    TriggerServerEvent('dodi_car_traffic:server:pulledOut', netVeh)
    TriggerEvent('dodi_notifys:Tip', CJ.stolenTip, 4000)
    rollPoliceAlert(entry, veh, ped, false, true)
    -- dodi_cars builds the shell (settle / profile) after spawnShell: release again once it's up
    SetTimeout(2000, function()
        if DoesEntityExist(veh) and GetPedInVehicleSeat(veh, Config.DriverSeat) == PlayerPedId() then
            makeDrivable(veh)
        end
    end)
    dbg(('pulled out net=%s'):format(netVeh))
end

-- /trafficwhy: hold W for 3s in a car that won't move -> prints what is holding it
DevCommand('trafficwhy', function()
    local me = PlayerPedId()
    local veh = GetVehiclePedIsIn(me, false)
    if veh == 0 then
        print('[trafficwhy] not in a vehicle')
        return
    end
    TriggerEvent('dodi_notifys:Tip', 'Hold W for 3s', 3000)
    CreateThread(function()
        local acc = `INPUT_VEH_CAR_ACCELERATE`
        local frames, pressed, blocked = 0, 0, 0
        local untilAt = GetGameTimer() + 3000
        while GetGameTimer() < untilAt do
            frames = frames + 1
            if IsControlPressed(0, acc) then
                pressed = pressed + 1
            elseif IsDisabledControlPressed(0, acc) then
                blocked = blocked + 1
            end
            Wait(0)
        end
        local st = Entity(veh).state
        print(('[trafficwhy] model=%s net=%s owner_me=%s driver_me=%s drivingSeat=%s driveable=%s static=%s speed=%.1f'):format(
            GetEntityModel(veh), NetworkGetNetworkIdFromEntity(veh),
            tostring(NetworkGetEntityOwner(veh) == PlayerId()),
            tostring(GetPedInVehicleSeat(veh, Config.DriverSeat) == me),
            tostring(Citizen.InvokeNative(Native.GetDrivingSeat, veh, Citizen.ResultAsInteger())),
            tostring(Citizen.InvokeNative(Native.IsVehicleDriveable, veh, false, false)),
            tostring(Citizen.InvokeNative(Native.IsEntityStatic, veh)),
            GetEntitySpeed(veh)))
        print(('[trafficwhy] W frames=%d pressed=%d BLOCKED_BY_SCRIPT=%d | dodiCarId=%s dodiStolen=%s still_traffic=%s'):format(
            frames, pressed, blocked, tostring(st.dodiCarId), tostring(st.dodiStolen),
            tostring(DodiTraffic.known[NetworkGetNetworkIdFromEntity(veh)] ~= nil)))
    end)
end, false)

CreateThread(function()
    while true do
        local sleep = 500
        if CJ.enabled and CJ.allowPullOut and not job and next(DodiTraffic.known) then
            local me = PlayerPedId()
            local veh = GetVehiclePedIsIn(me, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, Config.DriverSeat) == me then
                sleep = 100
                for netVeh, entry in pairs(DodiTraffic.known) do
                    if not entry.parked then
                        local v, ped = DodiTraffic.resolve(entry)
                        if v == veh then
                            if not pulledSent[netVeh] then
                                adoptPulledOut(netVeh, entry, veh, ped)
                            elseif GetGameTimer() - pulledSent[netVeh] > 3000 then
                                -- server didn't adopt yet (refused / lost): ask again
                                pulledSent[netVeh] = GetGameTimer()
                                dbg(('pulled out resend net=%s'):format(netVeh))
                                TriggerServerEvent('dodi_car_traffic:server:pulledOut', netVeh)
                            end
                            break
                        end
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

RegisterNetEvent('dodi_car_traffic:client:remove', function(netVeh)
    pulledSent[netVeh] = nil
end)

CreateThread(function()
    while true do
        local sleep = 250
        if CJ.enabled and next(DodiTraffic.known) then
            if job then
                sleep = 0
                tickJob()
            elseif IsPedArmed(PlayerPedId(), GUNS) then
                sleep = 50
                local target = aimTarget()
                if target ~= 0 then
                    local entry, veh, ped = entryFor(target)
                    if entry and veh ~= 0 and ped ~= 0 and not entry.jacked then
                        startJack(entry, veh, ped)
                    end
                end
            end
        elseif job then
            job = nil
            showPrompt(false)
        end
        Wait(sleep)
    end
end)

-- floor-it ends -> back to normal traffic
CreateThread(function()
    while true do
        local now = GetGameTimer()
        for netVeh, untilAt in pairs(floorUntil) do
            if now >= untilAt then
                floorUntil[netVeh] = nil
                if DodiTraffic.known[netVeh] then
                    setJackState(netVeh, nil)
                end
            end
        end
        Wait(1000)
    end
end)

---------------------------------------------------------------------------
-- Police alert (officers on duty, from server)
---------------------------------------------------------------------------

RegisterNetEvent('dodi_car_traffic:client:policeAlert', function(pos, place, vehicle, floorIt, pulled)
    local what = pulled and 'Vehicle theft' or floorIt and 'Attempted theft' or 'Armed robbery'
    local text = ('%s - %s%s'):format(what, vehicle, place ~= '' and (' at ' .. place) or '')
    TriggerEvent('dodi_notifys:NotifyLeft', P.title, text, 'generic_textures', 'tick', 6000)

    local blip = BlipAddForCoords(GetHashKey('BLIP_STYLE_CREATOR_DEFAULT'), pos.x, pos.y, pos.z)
    local blip2 = BlipAddForCoords(GetHashKey('BLIP_STYLE_COP_PERSISTENT'), pos.x, pos.y, pos.z)
    SetBlipSprite(blip, GetHashKey('blip_ambient_law'), true)
    SetBlipSprite(blip2, GetHashKey('blip_overlay_ring'), true)
    BlipAddModifier(blip, GetHashKey('BLIP_MODIFIER_AREA_PULSE'))
    BlipAddModifier(blip2, GetHashKey('BLIP_MODIFIER_AREA_PULSE'))
    SetBlipScale(blip, 0.8)
    SetBlipScale(blip2, 2.0)
    Citizen.InvokeNative(Native.SetBlipName, blip, P.title)
    Citizen.InvokeNative(Native.SetBlipName, blip2, P.title)

    SetTimeout(P.blipMs, function()
        for _, b in ipairs({ blip, blip2 }) do
            if DoesBlipExist(b) then
                RemoveBlip(b)
            end
        end
    end)
end)

---------------------------------------------------------------------------
-- /trafficdismount x y z heading [angle] [left|right] : tune Config.Carjack.bikeDismount on yourself.
-- Stand next to any bike (5m), values stay until restart -> copy the printed line to config.
---------------------------------------------------------------------------

DevCommand('trafficdismount', function(_, args)
    local D = CJ.bikeDismount
    D.offset.x = tonumber(args[1]) or D.offset.x
    D.offset.y = tonumber(args[2]) or D.offset.y
    D.offset.z = tonumber(args[3]) or D.offset.z
    D.heading = tonumber(args[4]) or D.heading
    local force = {
        angle = tonumber(args[5]) or 0,
        side = (args[6] == 'right') and 'right' or 'left',
    }

    local me = PlayerPedId()
    local pc = GetEntityCoords(me)
    local best, bestDist = 0, 5.0
    for _, v in ipairs(GetGamePool('CVehicle')) do
        local d = #(GetEntityCoords(v) - pc)
        if d < bestDist then
            best, bestDist = v, d
        end
    end
    print(('[dodi_car_traffic] bikeDismount offset = { x = %.3f, y = %.3f, z = %.3f }, heading = %.1f  (side %s, %s)'):format(
        D.offset.x, D.offset.y, D.offset.z, D.heading, force.side, D.offClip:format(force.angle)))
    if best == 0 then
        TriggerEvent('dodi_notifys:Tip', 'Stand next to a bike (5m)', 3000)
        return
    end
    CreateThread(function()
        ClearPedTasksImmediately(me)
        local dur = playBikeDismount(me, best, nil, force)
        if not dur then
            TriggerEvent('dodi_notifys:Tip', ('Clip did not load: %s'):format(D.offClip:format(force.angle)), 3000)
        end
    end)
end, false)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and job then
        releaseJob()
    end
end)
