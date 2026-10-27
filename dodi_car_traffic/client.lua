-- dodi_car_traffic client
--  * host: spawns city cars the server asks for (off-screen, on road nodes inside the town zone)
--  * owner: whoever is the network owner of a traffic car drives it (task, stuck, throttle audio)
--  * everyone: blips, vanilla density suppression (anim.lua does clips + hand IK)
--
-- Server (restricted): /trafficcar [model] [wander|roam]  /trafficfill [n]  /trafficclear
--                      /trafficpause  /trafficstatus
-- Client:              /trafficmode <wander|roam>  /trafficstyle <int>  /trafficdebug
--                      /trafficpoint  /trafficanimflags <drive> [steer]

local Native = {
    CreateVehicle = 0xAF35D0D2583051B0,
    CreateVehicleLegacy = 0xDD958B5A23777EA3,
    CreatePedInsideVehicle = 0x7DD959874C1FD534,
    IsAnyPedNearPoint = 0x083961498679DC9F,
    SetRandomOutfitVariation = 0x283978A15512B2FE,
    SetDrivingSeat = 0x4BA972D0E5AD8122,
    SetTransportExclusiveDriver = 0x4248AB2EEB3C75AD,
    SetVehicleExclusiveDriver = 0xC6B9BF123B9463B6,
    TaskVehicleDriveWander = 0x480142959D337D00,
    TaskVehicleDriveToDestination = 0x7F241A0D14354583,
    TaskVehicleTempAction = 0xC429DCEEB339E129,
    SetDriveTaskCruiseSpeed = 0x5C9B84BD7D31D908,
    GetClosestVehicleNodeWithHeading = 0x23CFFD4CCB243354,
    SetVehicleEngineOn = 0xB64CFA14CB9A2E78,
    SetPedKeepTask = 0x971D38760FBC02EF,
    BlipAddForEntity = 0x23F74C2FDA6E7C61,
    SetBlipName = 0x9CB1A1623062F402,
    IsVehicleStuckTimerUp = 0x1ABA9753939503C5,
    ResetVehicleStuckTimer = 0x23298B468F7D88B6,
    SetVehicleIsStolen = 0x6C32FC81DFF25C9A,
    GetMapZoneAtCoords = 0x43AD8FC02B429D33,
    IsSphereVisible = 0x2E941B5FFA2989C6,
    IsAnyVehicleNearPoint = 0x5698BA4FD04D39C4,
    SetVehicleDoorsLocked = 0x96F78A6A075D55D9,
    StopBringingVehicleToHalt = 0x7C06330BFDDA182E,
    SetPedCanPlayAmbientAnims = 0x6373D1349925A70E,
    SetPedCanPlayAmbientBaseAnims = 0x0EB0585D15254740,
    SetPedCanPlayGestureAnims = 0xBAF20C5432058024,
    SetVehicleDensityMultiplierThisFrame = 0x606374EBFC27B133,
    SetRandomVehicleDensityMultiplierThisFrame = 0x1F91D44490E1EA0C,
    SetParkedVehicleDensityMultiplierThisFrame = 0xFEDFA97638D61D4A,
    GetVehiclePedIsEntering = 0xF92691AED837A5FC,
}

local KNOCKOFF_NEVER = 1
local ZONE_TOWN = 1

local Pop = Config.Population
local Drive = Config.Driving

local known = {} -- [netVeh] = { netVeh, netPed, model, carId, city, parked, speed, mode, dest, retries, managed, blip, ... }
local debugOn = Config.Debug

for _, city in pairs(Config.Cities) do
    city.zoneHash = city.zone and GetHashKey(city.zone) or nil
end

local function dbg(msg)
    if debugOn then
        print(('[dodi_car_traffic] %s'):format(msg))
    end
end

-- Client tuning commands, registered only with Config.DevCommands (shared with anim.lua / carjack.lua)
function DevCommand(name, fn)
    if Config.DevCommands then
        RegisterCommand(name, fn, false)
    end
end

local function notify(msg)
    TriggerEvent('dodi_notifys:ShowSimpleRightText', msg, 4000)
end

RegisterNetEvent('dodi_car_traffic:client:notify', function(msg)
    notify(msg)
    TriggerEvent('chat:addMessage', { args = { 'traffic', msg } })
end)

---------------------------------------------------------------------------
-- dodi_cars config (sandboxed, cached): carId / audio / barIk come from here
---------------------------------------------------------------------------

local dodiCarsConfig = nil

local function getDodiCarsConfig()
    if dodiCarsConfig then
        return dodiCarsConfig
    end
    dodiCarsConfig = {}
    local src = LoadResourceFile('dodi_cars', 'config.lua')
    if not src then
        print('[dodi_car_traffic] dodi_cars/config.lua not found')
        return dodiCarsConfig
    end
    local env = setmetatable({ Config = {} }, { __index = _G })
    local chunk, err = load(src, '@dodi_cars/config.lua', 't', env)
    local ok, runErr = false, err
    if chunk then
        ok, runErr = pcall(chunk)
    end
    if not ok then
        print(('[dodi_car_traffic] dodi_cars config error: %s'):format(runErr))
        return dodiCarsConfig
    end
    dodiCarsConfig = env.Config or {}
    return dodiCarsConfig
end

local carIdByModel = {}

-- chassisModel -> dodi_cars carId (prefers <model>_ntv)
local function resolveCarId(model)
    local key = model:lower()
    if carIdByModel[key] ~= nil then
        return carIdByModel[key] or nil
    end
    local carsCfg = getDodiCarsConfig().Cars or {}
    local found = false
    if carsCfg[key .. '_ntv'] then
        found = key .. '_ntv'
    else
        for carId, car in pairs(carsCfg) do
            if type(car) == 'table' and type(car.chassisModel) == 'string' and car.chassisModel:lower() == key then
                found = carId
                break
            end
        end
    end
    carIdByModel[key] = found
    return found or nil
end

---------------------------------------------------------------------------
-- Registry helpers (shared with anim.lua)
---------------------------------------------------------------------------

-- Rider visuals per model from dodi_cars: driverSteer clips + driverVisualClone (attach = bikes).
-- { clips, animRate, holdPhase, clone = { bone, offset, rotation } | nil } or nil (use Config.DriverAnim)
local riderCfgByModel = {}

local function getRiderCfg(model)
    local key = model:lower()
    if riderCfgByModel[key] ~= nil then
        return riderCfgByModel[key] or nil
    end
    local carId = resolveCarId(key)
    local car = carId and (getDodiCarsConfig().Cars or {})[carId]
    local cfg = false
    if car then
        local steer = type(car.driverSteer) == 'table' and car.driverSteer or nil
        local vc = type(car.driverVisualClone) == 'table' and car.driverVisualClone.attach == true and car.driverVisualClone or nil
        if (steer and steer.clips) or vc then
            local off, rot = vc and vc.offset or {}, vc and vc.rotation or {}
            cfg = {
                clips = steer and steer.clips or nil,
                animRate = steer and tonumber(steer.animRate) or 0.0,
                holdPhase = steer and tonumber(steer.holdPhase) or 0.98,
                clone = vc and {
                    bone = vc.bone or 'seat_dside_f',
                    offset = vector3(off.x or 0.0, off.y or 0.0, off.z or 0.0),
                    rotation = vector3(rot.x or 0.0, rot.y or 0.0, rot.z or 0.0),
                } or nil,
            }
        end
    end
    riderCfgByModel[key] = cfg
    return cfg or nil
end

local function entFromNet(netId)
    if netId and netId ~= 0 and NetworkDoesNetworkIdExist(netId) then
        local ent = NetworkGetEntityFromNetworkId(netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            return ent
        end
    end
    return 0
end

local function resolve(entry)
    return entFromNet(entry.netVeh), entFromNet(entry.netPed)
end

local function isMine(ent)
    return ent ~= 0 and NetworkGetEntityOwner(ent) == PlayerId()
end

DodiTraffic = {
    known = known,
    entFromNet = entFromNet,
    isMine = isMine,
    getRiderCfg = getRiderCfg,
    resolve = resolve,
    isDebug = function()
        return debugOn
    end,
    getDodiCarsConfig = getDodiCarsConfig,
}

---------------------------------------------------------------------------
-- Generic helpers
---------------------------------------------------------------------------

local function toHash(model)
    return type(model) == 'number' and model or GetHashKey(model)
end

-- Traffic models stay resident (Config.Population.keepModelsLoaded): load/unload per spawn
-- re-streams the yourmaps YFT/YTD every time and hitches the host.
local residentModels = {}

local function releaseModel(hash)
    if not Pop.keepModelsLoaded then
        SetModelAsNoLongerNeeded(hash)
    end
end

local function requestModel(model, timeoutMs)
    local hash = toHash(model)
    if residentModels[hash] and HasModelLoaded(hash) then
        return true, hash
    end
    if not IsModelValid(hash) then
        return false, hash
    end
    RequestModel(hash)
    local deadline = GetGameTimer() + (timeoutMs or 10000)
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then
            return false, hash
        end
        Wait(25)
    end
    residentModels[hash] = true
    return true, hash
end

local validDriverCache = {}

local function pickDriver(list)
    list = list or Config.DefaultDrivers
    local valid = validDriverCache[list]
    if not valid then
        valid = {}
        for _, name in ipairs(list) do
            if IsModelValid(GetHashKey(name)) then
                valid[#valid + 1] = name
            else
                dbg(('driver model invalid, skipped: %s'):format(name))
            end
        end
        validDriverCache[list] = valid
    end
    return valid[math.random(math.max(1, #valid))]
end

-- Models that keep timing out (e.g. vehicle resource restarted without reconnect) are
-- benched for a while so the city fills with the ones that load.
local modelFails = {} -- [model] = { count, benchedUntil }

local function noteModelFail(model)
    local f = modelFails[model] or { count = 0, benchedUntil = 0 }
    f.count = f.count + 1
    if f.count >= Pop.modelFailBench then
        f.benchedUntil = GetGameTimer() + Pop.modelBenchMs
        f.count = 0
        print(('[dodi_car_traffic] model %s benched for %ds (timeouts). Vehicle resource restarted? Reconnect.')
            :format(model, Pop.modelBenchMs // 1000))
    end
    modelFails[model] = f
end

local function isBenched(model)
    local f = modelFails[model]
    return f and f.benchedUntil > GetGameTimer()
end

-- Models from packs the server doesn't run (e.g. no yourmaps_native_cars) never enter the pool
local streamedCache = {}

local function isStreamed(name)
    if streamedCache[name] == nil then
        streamedCache[name] = IsModelValid(GetHashKey(name)) and true or false
        if not streamedCache[name] then
            dbg(('model not streamed, skipped: %s'):format(name))
        end
    end
    return streamedCache[name]
end

-- { 'model', weight } | 'model'
local function pickModel(list)
    list = list or Config.DefaultModels
    local pool, total = {}, 0
    for _, m in ipairs(list) do
        local name = type(m) == 'table' and m[1] or m
        if isStreamed(name) and not isBenched(name) then
            local w = type(m) == 'table' and (m[2] or 1) or 1
            pool[#pool + 1] = { name, w }
            total = total + w
        end
    end
    if #pool == 0 then
        return nil
    end
    local r = math.random() * total
    for _, m in ipairs(pool) do
        r = r - m[2]
        if r <= 0 then
            return m[1]
        end
    end
    return pool[#pool][1]
end

local function randomSpeed(range)
    range = range or Drive.speed
    return range.min + math.random() * (range.max - range.min)
end

-- Config.ModelOverrides[model].speed beats the city / default range
local function speedFor(model, cityRange)
    local o = Config.ModelOverrides and Config.ModelOverrides[model]
    return randomSpeed(o and o.speed or cityRange)
end

local function flat(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function countKnown(filter)
    local n = 0
    for _, e in pairs(known) do
        if not filter or filter(e) then
            n = n + 1
        end
    end
    return n
end

-- Road node closest to (x,y,z). Returns pos, heading or nil.
local function getRoadNode(x, y, z)
    local ok, pos, heading = Citizen.InvokeNative(
        Native.GetClosestVehicleNodeWithHeading,
        x, y, z,
        Citizen.PointerValueVector(),
        Citizen.PointerValueFloat(),
        Config.NodeType, 3.0, 0,
        Citizen.ResultAsInteger()
    )
    if ok ~= 1 and ok ~= true then
        return nil
    end
    if not pos or (pos.x == 0.0 and pos.y == 0.0) then
        return nil
    end
    return pos, heading or 0.0
end

-- angle = optional center direction (rad), points within +-90 deg of it
local function randomPointAround(center, minDist, maxDist, angle)
    local a = angle and (angle + (math.random() - 0.5) * math.pi) or math.random() * math.pi * 2.0
    local d = minDist + math.random() * (maxDist - minDist)
    return vector3(center.x + math.cos(a) * d, center.y + math.sin(a) * d, center.z)
end

local function inCity(city, pos)
    if city.zoneHash then
        return Citizen.InvokeNative(Native.GetMapZoneAtCoords, pos.x, pos.y, pos.z, ZONE_TOWN, Citizen.ResultAsInteger())
            == city.zoneHash
    end
    return flat(pos, city.center) <= city.radius
end

-- Spawn spot rules vs every player + other traffic.
local function spotOk(pos, minDist, hiddenDist, spacing)
    local me = PlayerId()
    for _, pid in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(pid)
        local pp = GetEntityCoords(ped)
        local d = #(pp - pos)
        if d < minDist then
            return false
        end
        if d < hiddenDist then
            if pid == me then
                if Citizen.InvokeNative(Native.IsSphereVisible, pos.x, pos.y, pos.z + 1.0, 3.0, Citizen.ResultAsInteger()) == 1 then
                    return false
                end
            else
                -- remote camera unknown: reject spots in front of the ped
                local fwd = GetEntityForwardVector(ped)
                local dir = (pos - pp) / d
                if fwd.x * dir.x + fwd.y * dir.y > 0.2 then
                    return false
                end
            end
        end
    end
    if spacing and spacing > 0.0 then
        for _, e in pairs(known) do
            local v = entFromNet(e.netVeh)
            if v ~= 0 and #(GetEntityCoords(v) - pos) < spacing then
                return false
            end
        end
    end
    if Citizen.InvokeNative(Native.IsAnyVehicleNearPoint, pos.x, pos.y, pos.z, 5.0, Citizen.ResultAsInteger()) == 1 then
        return false
    end
    -- sidewalk / street peds on the spot -> physics shove on spawn
    if Citizen.InvokeNative(Native.IsAnyPedNearPoint, pos.x, pos.y, pos.z, Pop.pedClearRadius, Citizen.ResultAsInteger()) == 1 then
        return false
    end
    return true
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

---------------------------------------------------------------------------
-- Driving
---------------------------------------------------------------------------

-- behind = vehicle forward vector -> first tries only behind the car (after a reverse)
local function pickRoamDest(entry, from, behind)
    local city = entry.city and Config.Cities[entry.city]
    local R = Config.Roam
    local backAngle = behind and math.atan(-behind.y, -behind.x) or nil
    for i = 1, R.attempts do
        local p = randomPointAround(from, R.minDist, R.maxDist, i <= R.attempts // 2 and backAngle or nil)
        local node = getRoadNode(p.x, p.y, from.z)
        if node and #(node - from) >= R.minDist * 0.5 and (not city or inCity(city, node)) then
            return node
        end
    end
    if city then
        for _ = 1, R.attempts do
            local p = randomPointAround(city.center, 0.0, city.radius * 0.8)
            local node = getRoadNode(p.x, p.y, city.center.z)
            if node and #(node - from) >= R.minDist * 0.5 and inCity(city, node) then
                return node
            end
        end
    end
    return nil
end

local function isVehicleStuck(veh)
    local ms = Config.Stuck.timeMs
    local function up(t)
        return Citizen.InvokeNative(Native.IsVehicleStuckTimerUp, veh, t, ms, Citizen.ResultAsInteger()) == 1
    end
    return up(0) or up(1) or up(2) or (up(3) and IsVehicleStopped(veh))
end

-- Stopped for Config.Stuck.stallMs (blocked by a ped / car, or no route to dest)
local function isStalled(entry, veh, now)
    if GetEntitySpeed(veh) > Config.Stuck.stallSpeed then
        entry.stallSince = nil
        return false
    end
    entry.stallSince = entry.stallSince or now
    return now - entry.stallSince >= Config.Stuck.stallMs
end

-- Player in the driver seat or pulling the driver out (vanilla jack): never warp the NPC back on top
local function playerTakingSeat(veh)
    local vc = GetEntityCoords(veh)
    for _, pid in ipairs(GetActivePlayers()) do
        local pp = GetPlayerPed(pid)
        if GetPedInVehicleSeat(veh, Config.DriverSeat) == pp
            or Citizen.InvokeNative(Native.GetVehiclePedIsEntering, pp, Citizen.ResultAsInteger()) == veh
            or #(GetEntityCoords(pp) - vc) < Config.Carjack.pullGuardDist
        then
            return true
        end
    end
    return false
end

local function anyPlayerWithin(pos, dist)
    for _, pid in ipairs(GetActivePlayers()) do
        if #(GetEntityCoords(GetPlayerPed(pid)) - pos) < dist then
            return true
        end
    end
    return false
end

-- Ambient idles (smoking, scratching head, gestures) override the steer clip + hand IK.
-- Same calls R* uses in script_rel. Re-applied by every new owner (may not survive migration).
local function lockDriverAnims(ped)
    if not Config.DriverAnim.disableAmbient then
        return
    end
    Citizen.InvokeNative(Native.SetPedCanPlayAmbientAnims, ped, false)
    Citizen.InvokeNative(Native.SetPedCanPlayAmbientBaseAnims, ped, false)
    Citizen.InvokeNative(Native.SetPedCanPlayGestureAnims, ped, 0, 1)
end

local function seatDriver(ped, veh)
    SetPedIntoVehicle(ped, veh, Config.DriverSeat)
    Wait(50)
    return GetPedInVehicleSeat(veh, Config.DriverSeat) == ped
end

local function taskCar(entry, veh, ped)
    entry.stallSince = nil
    entry.reverseUntil = nil
    if not requestControl(veh) or not requestControl(ped) then
        dbg(('no control net=%s'):format(entry.netVeh))
        return false
    end

    ClearPedTasks(ped)
    if GetPedInVehicleSeat(veh, Config.DriverSeat) ~= ped then
        seatDriver(ped, veh)
    end
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanBeKnockedOffVehicle(ped, KNOCKOFF_NEVER)
    lockDriverAnims(ped)
    FreezeEntityPosition(veh, false)
    SetEntityCollision(veh, true, true)
    Citizen.InvokeNative(Native.StopBringingVehicleToHalt, veh) -- released carjack
    -- Bikes: real rider hidden (owner -> synced), every client shows a local clone on the seat bone (anim.lua)
    local rider = getRiderCfg(entry.model)
    if rider and rider.clone then
        SetEntityVisible(ped, false)
    end
    Citizen.InvokeNative(Native.SetDrivingSeat, veh, Config.DriverSeat)
    -- No exclusive driver (dodi autopilot needs it for its ghost ped, traffic doesn't):
    -- it kicks any player out of the driver seat while the NPC is alive (carjack).
    Citizen.InvokeNative(Native.SetVehicleEngineOn, veh, true, true)
    Citizen.InvokeNative(Native.ResetVehicleStuckTimer, veh, 0)

    local speed = (entry.speed or randomSpeed()) + 0.0
    if entry.mode == 'wander' then
        entry.dest = nil
    else
        entry.dest = pickRoamDest(entry, GetEntityCoords(veh), entry.preferBehind and GetEntityForwardVector(veh) or nil)
    end
    entry.preferBehind = nil

    if entry.dest then
        Citizen.InvokeNative(
            Native.TaskVehicleDriveToDestination,
            ped, veh,
            entry.dest.x, entry.dest.y, entry.dest.z,
            speed,
            Drive.drivingFlags,
            Drive.drivingParam,
            Drive.stopRange,
            Drive.straightLineDist,
            false
        )
    else
        Citizen.InvokeNative(Native.TaskVehicleDriveWander, ped, veh, speed, Drive.drivingStyle)
    end
    Citizen.InvokeNative(Native.SetDriveTaskCruiseSpeed, ped, speed)
    Citizen.InvokeNative(Native.SetPedKeepTask, ped, true)
    return true
end

---------------------------------------------------------------------------
-- Spawn
---------------------------------------------------------------------------

local function createVehicle(hash, pos, heading)
    local veh = Citizen.InvokeNative(
        Native.CreateVehicle, hash,
        pos.x, pos.y, pos.z, heading,
        true, true, true, false,
        Citizen.ResultAsInteger()
    )
    if veh and veh ~= 0 then
        return veh
    end
    return Citizen.InvokeNative(
        Native.CreateVehicleLegacy, hash,
        pos.x, pos.y, pos.z, heading,
        true, true, true, false,
        Citizen.ResultAsInteger()
    )
end

local function createDriver(veh, drivers)
    local name = pickDriver(drivers)
    if not name then
        return 0
    end
    local ok, hash = requestModel(name)
    if not ok then
        return 0
    end
    -- Born seated (R*: CREATE_PED_INSIDE_VEHICLE(veh, model, -1, true, true, false)):
    -- no ped in the world overlapping the car, no warp.
    local ped = Citizen.InvokeNative(
        Native.CreatePedInsideVehicle, veh, hash, Config.DriverSeat,
        true, true, false,
        Citizen.ResultAsInteger()
    )
    releaseModel(hash)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return 0
    end
    Citizen.InvokeNative(Native.SetRandomOutfitVariation, ped, true)
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanBeKnockedOffVehicle(ped, KNOCKOFF_NEVER)
    lockDriverAnims(ped)
    return ped
end

local function registerNetworked(entity)
    NetworkRegisterEntityAsNetworked(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    local deadline = GetGameTimer() + 2500
    while (not netId or netId == 0) and GetGameTimer() < deadline do
        Wait(50)
        netId = NetworkGetNetworkIdFromEntity(entity)
    end
    if netId and netId ~= 0 then
        SetNetworkIdExistsOnAllMachines(netId, true)
    end
    return netId or 0
end

local function settleOnGround(veh, pos)
    FreezeEntityPosition(veh, true)
    RequestCollisionAtCoord(pos.x, pos.y, pos.z)
    local deadline = GetGameTimer() + Pop.collisionWaitMs
    while not HasCollisionLoadedAroundEntity(veh) and GetGameTimer() < deadline do
        Wait(50)
    end
    SetVehicleOnGroundProperly(veh)
    FreezeEntityPosition(veh, false)
    SetEntityCollision(veh, true, true)
end

-- opts = { model, pos, heading, city, mode, speed, drivers, parked, slot, pendingId }
-- Returns entry or nil, reason
local function spawnCar(opts)
    local model = opts.model
    if not model then
        return nil, 'all models benched (reconnect after restarting vehicle resources)'
    end
    local ok, hash = requestModel(model, Pop.modelTimeoutMs)
    if not ok then
        noteModelFail(model)
        return nil, ('model invalid/timeout: %s'):format(model)
    end

    local veh = createVehicle(hash, opts.pos + vector3(0.0, 0.0, 0.5), opts.heading)
    releaseModel(hash)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return nil, ('CreateVehicle failed: %s'):format(model)
    end
    SetEntityAsMissionEntity(veh, true, true)
    Citizen.InvokeNative(Native.SetVehicleIsStolen, veh, false)
    settleOnGround(veh, opts.pos)
    Wait(0) -- spread vehicle / ped creation over frames

    local ped = 0
    if not opts.parked then
        ped = createDriver(veh, opts.drivers)
        if ped == 0 then
            DeleteEntity(veh)
            return nil, 'driver ped failed (check drivers list)'
        end
        if GetPedInVehicleSeat(veh, Config.DriverSeat) ~= ped and not seatDriver(ped, veh) then
            DeleteEntity(ped)
            DeleteEntity(veh)
            return nil, ('driver did not get into seat %d: %s'):format(Config.DriverSeat, model)
        end
    else
        Citizen.InvokeNative(Native.SetVehicleDoorsLocked, veh, 2)
        Citizen.InvokeNative(Native.SetVehicleEngineOn, veh, false, true)
    end

    local entry = {
        netVeh = registerNetworked(veh),
        netPed = ped ~= 0 and registerNetworked(ped) or 0,
        model = model,
        carId = resolveCarId(model), -- audio + carjack adoption (dodi_cars:spawnShell)
        city = opts.city,
        parked = opts.parked == true,
        slot = opts.slot,
        mode = opts.mode or Drive.mode,
        speed = opts.speed or speedFor(model),
        retries = 0,
    }
    if entry.netVeh == 0 then
        if ped ~= 0 then
            DeleteEntity(ped)
        end
        DeleteEntity(veh)
        return nil, 'no network id'
    end
    known[entry.netVeh] = entry

    TriggerServerEvent('dodi_car_traffic:server:register', {
        netVeh = entry.netVeh,
        netPed = entry.netPed,
        model = model,
        carId = entry.carId,
        city = entry.city,
        parked = entry.parked,
        slot = entry.slot,
        speed = entry.speed,
        mode = entry.mode,
        pendingId = opts.pendingId,
    })

    if not entry.parked then
        Wait(150)
        entry.managed = taskCar(entry, veh, ped)
    end

    dbg(('spawn %s city=%s parked=%s net=%s/%s mode=%s speed=%.1f at %.1f %.1f %.1f'):format(
        model, tostring(entry.city), tostring(entry.parked), entry.netVeh, entry.netPed, entry.mode, entry.speed,
        opts.pos.x, opts.pos.y, opts.pos.z))
    return entry
end

---------------------------------------------------------------------------
-- City host
---------------------------------------------------------------------------

local function findCitySpot(city)
    local me = GetEntityCoords(PlayerPedId())
    local points = city.spawnPoints or {}
    for i = 1, Pop.attempts do
        local pos, heading
        if #points > 0 and i % 2 == 1 then
            local p = points[math.random(#points)]
            pos, heading = vector3(p.x, p.y, p.z), p.w
        else
            local p = randomPointAround(me, Pop.minPlayerDist, Pop.maxHostDist)
            pos, heading = getRoadNode(p.x, p.y, me.z)
        end
        if pos
            and #(pos - me) <= Pop.maxHostDist
            and inCity(city, pos)
            and spotOk(pos, Pop.minPlayerDist, Pop.hiddenDist, Pop.spacing)
        then
            return pos, heading
        end
    end
    return nil
end

local spawnBusy = false

RegisterNetEvent('dodi_car_traffic:client:citySpawn', function(cityId, pendingIds)
    local city = Config.Cities[cityId]
    if not city or type(pendingIds) ~= 'table' then
        return
    end
    CreateThread(function()
        while spawnBusy do
            Wait(100)
        end
        spawnBusy = true
        for _, pendingId in ipairs(pendingIds) do
            local pos, heading = findCitySpot(city)
            local entry, err
            if pos then
                local model = pickModel(city.models)
                entry, err = spawnCar({
                    model = model,
                    pos = pos,
                    heading = heading,
                    city = cityId,
                    mode = city.mode,
                    speed = model and speedFor(model, city.speed) or nil,
                    drivers = city.drivers,
                    pendingId = pendingId,
                })
            else
                err = 'no spot (all visible / too close / occupied)'
            end
            if not entry then
                dbg(('city %s spawn failed: %s'):format(cityId, err))
                TriggerServerEvent('dodi_car_traffic:server:spawnFailed', cityId, pendingId, nil)
            end
            Wait(200)
        end
        spawnBusy = false
    end)
end)

RegisterNetEvent('dodi_car_traffic:client:cityParked', function(cityId, slots)
    local city = Config.Cities[cityId]
    if not city or type(slots) ~= 'table' then
        return
    end
    CreateThread(function()
        while spawnBusy do
            Wait(100)
        end
        spawnBusy = true
        for _, slot in ipairs(slots) do
            local spot = city.parked[slot]
            local coords = type(spot) == 'table' and spot.coords or spot
            local entry
            if coords then
                local pos = vector3(coords.x, coords.y, coords.z)
                if spotOk(pos, Pop.minPlayerDist, Pop.hiddenDist, 0.0) then
                    entry = spawnCar({
                        model = (type(spot) == 'table' and spot.model and isStreamed(spot.model) and spot.model) or pickModel(city.models),
                        pos = pos,
                        heading = coords.w,
                        city = cityId,
                        parked = true,
                        slot = slot,
                    })
                end
            end
            if not entry then
                TriggerServerEvent('dodi_car_traffic:server:spawnFailed', cityId, nil, slot)
            end
            Wait(100)
        end
        spawnBusy = false
    end)
end)

---------------------------------------------------------------------------
-- Registry sync
---------------------------------------------------------------------------

local function removeBlip(entry)
    if entry.blip and DoesBlipExist(entry.blip) then
        RemoveBlip(entry.blip)
    end
    entry.blip = nil
end

local function upsert(data)
    local e = known[data.netVeh] or { retries = 0 }
    for k, v in pairs(data) do
        e[k] = v
    end
    known[data.netVeh] = e
end

RegisterNetEvent('dodi_car_traffic:client:add', function(data)
    if type(data) == 'table' and data.netVeh then
        upsert(data)
    end
end)

RegisterNetEvent('dodi_car_traffic:client:sync', function(list)
    for _, data in ipairs(list or {}) do
        upsert(data)
    end
end)

-- Carjack stage broadcast: 'surrender' | 'floor' | nil (back to traffic)
RegisterNetEvent('dodi_car_traffic:client:jackState', function(netVeh, jackState)
    local e = known[netVeh]
    if e then
        e.jacked = jackState
        if not jackState then
            e.managed = false
        end
    end
end)

RegisterNetEvent('dodi_car_traffic:client:remove', function(netVeh)
    local e = known[netVeh]
    if e then
        removeBlip(e)
        known[netVeh] = nil
    end
end)

CreateThread(function()
    Wait(2000)
    TriggerServerEvent('dodi_car_traffic:server:hello')
end)

local function requestRemove(entry, reason)
    local now = GetGameTimer()
    if entry.removeRequestedAt and now - entry.removeRequestedAt < Config.Stuck.removeRetryMs then
        return
    end
    entry.removeRequestedAt = now
    TriggerServerEvent('dodi_car_traffic:server:remove', entry.netVeh, reason)
end

---------------------------------------------------------------------------
-- Owner management: task on ownership, arrival (roam), stuck, dead driver
---------------------------------------------------------------------------

CreateThread(function()
    local lastDebug = 0
    while true do
        local sleep = 2000
        if next(known) then
            sleep = 1000
            local now = GetGameTimer()
            local pc = GetEntityCoords(PlayerPedId())
            local printNow = debugOn and now - lastDebug > 5000
            if printNow then
                lastDebug = now
                print(('[dodi_car_traffic] --- %d known, %d mine ---'):format(
                    countKnown(),
                    countKnown(function(e)
                        return isMine(entFromNet(e.netVeh))
                    end)))
            end

            for netVeh, entry in pairs(known) do
                local veh, ped = resolve(entry)
                if entry.parked or veh == 0 or entry.jacked then
                    -- jacked: carjack.lua drives the ped; re-task when it clears
                    entry.managed = false
                elseif not isMine(veh) then
                    entry.managed = false
                elseif (ped == 0 or GetPedInVehicleSeat(veh, Config.DriverSeat) ~= ped) and playerTakingSeat(veh) then
                    -- vanilla jack: carjack.lua (jacker's client) adopts it as stolen. Before the dead /
                    -- missing check: the fled driver despawning must not delete the car under the robber.
                    entry.managed = false
                elseif ped == 0 or IsEntityDead(ped) then
                    requestRemove(entry, 'driver dead/missing')
                else
                    local vc = GetEntityCoords(veh)
                    if not entry.managed then
                        -- just became owner (spawned elsewhere / migrated): tasks may not survive migration
                        entry.managed = taskCar(entry, veh, ped)
                        dbg(('took over net=%s'):format(netVeh))
                    elseif GetPedInVehicleSeat(veh, Config.DriverSeat) ~= ped then
                        entry.managed = taskCar(entry, veh, ped)
                    elseif entry.reverseUntil then
                        -- backing out of a deadlock, then drive to a destination behind
                        if now >= entry.reverseUntil then
                            entry.preferBehind = true
                            taskCar(entry, veh, ped)
                        end
                    elseif entry.dest and #(vc - entry.dest) < Config.Roam.arriveDist then
                        taskCar(entry, veh, ped)
                    elseif isVehicleStuck(veh) or isStalled(entry, veh, now) then
                        local S = Config.Stuck
                        entry.retries = (entry.retries or 0) + 1
                        entry.stuckPos = entry.stuckPos or vc
                        -- never pop a car in someone's face: keep trying while visible / close
                        if entry.retries > S.maxRetries and not IsEntityOnScreen(veh)
                            and not anyPlayerWithin(vc, Pop.minPlayerDist)
                        then
                            requestRemove(entry, 'stuck')
                        elseif entry.retries >= S.reverseFromRetry and requestControl(veh) then
                            local action = S.reverseActions[math.random(#S.reverseActions)]
                            dbg(('stuck net=%s retry=%d -> reverse %d'):format(netVeh, entry.retries, action))
                            Citizen.InvokeNative(Native.TaskVehicleTempAction, ped, veh, action, S.reverseMs)
                            entry.stallSince = nil
                            entry.reverseUntil = now + S.reverseMs
                        else
                            dbg(('stuck net=%s retry=%d dest=%s'):format(netVeh, entry.retries, tostring(entry.dest)))
                            taskCar(entry, veh, ped)
                        end
                    elseif (entry.retries or 0) > 0 and entry.stuckPos
                        and #(vc - entry.stuckPos) > Config.Stuck.clearDist
                    then
                        -- speed alone resets on every reverse / bump -> rocking deadlock never hit maxRetries
                        entry.retries, entry.stuckPos = 0, nil
                    end

                    if printNow then
                        print(('  %s net=%s city=%s %s %.0fkm/h player=%.0fm dest=%s'):format(
                            entry.model, netVeh, tostring(entry.city), entry.mode, GetEntitySpeed(veh) * 3.6,
                            #(vc - pc), entry.dest and ('%.0fm'):format(#(vc - entry.dest)) or '-'))
                    end
                end
            end
        end
        Wait(sleep)
    end
end)

---------------------------------------------------------------------------
-- Engine audio throttle -> dodi_cars:engineThrottleState (via server, owner only)
-- Same curve as dodi_cars computeThrottleRatio autopilot branch.
---------------------------------------------------------------------------

local function audioCfgFor(carId)
    local global = getDodiCarsConfig().Audio or {}
    local car = (getDodiCarsConfig().Cars or {})[carId] or {}
    local audio = car.audio or {}
    return {
        minSpeed = audio.minThrottleSpeed or global.minThrottleSpeed or 1.0,
        maxSpeed = audio.maxThrottleSpeed or global.maxThrottleSpeed or 12.0,
        boost = audio.accelerationBoost or global.accelerationBoost or 0.35,
    }
end

CreateThread(function()
    while true do
        local sleep = 1000
        if Config.Audio.enabled and next(known) then
            sleep = Config.Audio.throttleUpdateMs
            local batch = {}

            for netVeh, entry in pairs(known) do
                local veh = entry.carId and not entry.parked and entFromNet(netVeh) or 0
                if veh ~= 0 and isMine(veh) then
                    entry.audioCfg = entry.audioCfg or audioCfgFor(entry.carId)
                    local a = entry.audioCfg
                    local speed = GetEntitySpeed(veh)
                    local accel = math.max(0.0, speed - (entry.lastSpeed or speed))
                    entry.lastSpeed = speed

                    local speedRatio = math.max(0.0, math.min(1.0, (speed - a.minSpeed) / math.max(0.01, a.maxSpeed - a.minSpeed)))
                    local ratio
                    if speed > 0.2 or accel > 0.01 then
                        ratio = math.max(speedRatio, 0.55) + accel * a.boost
                    else
                        ratio = speedRatio * 0.28
                    end
                    ratio = math.floor(math.max(0.0, math.min(1.0, ratio)) * 100 + 0.5) / 100

                    if math.abs(ratio - (entry.sentRatio or -1.0)) >= Config.Audio.minDelta then
                        entry.sentRatio = ratio
                        batch[tostring(netVeh)] = ratio
                    end
                end
            end

            if next(batch) then
                TriggerServerEvent('dodi_car_traffic:server:throttle', batch)
            end
        end
        Wait(sleep)
    end
end)

---------------------------------------------------------------------------
-- Blips (debug), hour report, vanilla density
---------------------------------------------------------------------------

CreateThread(function()
    while true do
        if Config.Blips then
            for _, entry in pairs(known) do
                local veh = entFromNet(entry.netVeh)
                if veh ~= 0 and not entry.blip then
                    local blip = Citizen.InvokeNative(Native.BlipAddForEntity, GetHashKey('BLIP_STYLE_CREATOR_DEFAULT'), veh)
                    if blip and blip ~= 0 then
                        SetBlipSprite(blip, GetHashKey(Config.BlipSprite), true)
                        SetBlipScale(blip, entry.parked and 0.4 or 0.6)
                        Citizen.InvokeNative(Native.SetBlipName, blip,
                            ('Traffic %s%s'):format(entry.model, entry.parked and ' (parado)' or ''))
                        entry.blip = blip
                    end
                elseif veh == 0 and entry.blip then
                    removeBlip(entry)
                end
            end
        end
        Wait(1000)
    end
end)

CreateThread(function()
    while true do
        TriggerServerEvent('dodi_car_traffic:server:hour', GetClockHours())
        Wait(Pop.hourReportMs)
    end
end)

local currentSuppress = nil

CreateThread(function()
    while true do
        currentSuppress = nil
        local global = Pop.suppressVanilla
        if global and global.enabled then
            local pc = GetEntityCoords(PlayerPedId())
            for _, city in pairs(Config.Cities) do
                if city.enabled and city.suppressVanilla ~= false and flat(pc, city.center) <= city.radius then
                    currentSuppress = type(city.suppressVanilla) == 'table' and city.suppressVanilla or global
                    break
                end
            end
        end
        Wait(1000)
    end
end)

CreateThread(function()
    while true do
        local s = currentSuppress
        if s then
            Citizen.InvokeNative(Native.SetVehicleDensityMultiplierThisFrame, s.vehicleDensity + 0.0)
            Citizen.InvokeNative(Native.SetRandomVehicleDensityMultiplierThisFrame, s.randomVehicleDensity + 0.0)
            Citizen.InvokeNative(Native.SetParkedVehicleDensityMultiplierThisFrame, s.parkedVehicleDensity + 0.0)
            Wait(0)
        else
            Wait(1000)
        end
    end
end)

---------------------------------------------------------------------------
-- Test (triggered by restricted server commands)
---------------------------------------------------------------------------

local function isValidMode(m)
    return m == 'wander' or m == 'roam'
end

RegisterNetEvent('dodi_car_traffic:client:testCar', function(args)
    args = args or {}
    local model = args[1]
    local mode = isValidMode(args[2]) and args[2] or nil
    if model and isValidMode(model) then
        mode, model = model, nil
    end

    local ped = PlayerPedId()
    local pc = GetEntityCoords(ped)
    local ahead = GetOffsetFromEntityInWorldCoords(ped, 0.0, Config.Test.ahead, 0.0)

    local pos, heading = getRoadNode(ahead.x, ahead.y, ahead.z)
    if not pos or #(pos - pc) < Config.Test.minPlayerDist then
        dbg('no road node ahead, spawning in front of player')
        local front = GetOffsetFromEntityInWorldCoords(ped, 0.0, 10.0, 0.0)
        local found, gz = GetGroundZFor_3dCoord(front.x, front.y, front.z + 5.0, false)
        pos = vector3(front.x, front.y, found and gz or front.z)
        heading = GetEntityHeading(ped)
    end

    CreateThread(function()
        local entry, err = spawnCar({ model = model or pickModel(), pos = pos, heading = heading, mode = mode })
        if entry then
            notify(('Traffic: %s'):format(entry.model))
        else
            notify(('Traffic failed: %s'):format(err))
        end
    end)
end)

RegisterNetEvent('dodi_car_traffic:client:testFill', function(n)
    local T = Config.Test
    n = math.min(tonumber(n) or 5, T.fillMax)
    local center = GetEntityCoords(PlayerPedId())

    CreateThread(function()
        local spawned, attempts = 0, 0
        while spawned < n and attempts < n * 6 do
            attempts = attempts + 1
            local p = randomPointAround(center, T.fillMinDist, T.fillMaxDist)
            local pos, heading = getRoadNode(p.x, p.y, center.z)
            if pos and spotOk(pos, T.fillMinDist * 0.5, 0.0, T.fillSpacing) then
                local entry, err = spawnCar({ model = pickModel(), pos = pos, heading = heading })
                if entry then
                    spawned = spawned + 1
                else
                    dbg(err)
                end
                Wait(250)
            end
        end
        notify(('Traffic fill: %d/%d'):format(spawned, n))
    end)
end)

---------------------------------------------------------------------------
-- Client commands
---------------------------------------------------------------------------

local function retaskMine()
    CreateThread(function()
        for _, entry in pairs(known) do
            local veh, ped = resolve(entry)
            if not entry.parked and isMine(veh) and ped ~= 0 then
                taskCar(entry, veh, ped)
            end
        end
    end)
end

DevCommand('trafficmode', function(_, args)
    local mode = args[1]
    if not isValidMode(mode) then
        notify('Usage: /trafficmode wander|roam')
        return
    end
    Drive.mode = mode
    for _, entry in pairs(known) do
        entry.mode = mode
    end
    retaskMine()
    notify(('Traffic mode: %s (cars you control)'):format(mode))
end, false)

DevCommand('trafficstyle', function(_, args)
    local style = tonumber(args[1])
    if not style then
        notify(('Current style: %d'):format(Drive.drivingStyle))
        return
    end
    Drive.drivingStyle = math.floor(style)
    retaskMine()
    notify(('Traffic style: %d'):format(Drive.drivingStyle))
end, false)

DevCommand('trafficdebug', function()
    debugOn = not debugOn
    notify(('Traffic debug: %s'):format(debugOn and 'ON' or 'OFF'))
end, false)

-- Prints a vector4 for Config.Cities[*].spawnPoints / parked
DevCommand('trafficpoint', function()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local ent = veh ~= 0 and veh or ped
    local c = GetEntityCoords(ent)
    local zone = Citizen.InvokeNative(Native.GetMapZoneAtCoords, c.x, c.y, c.z, ZONE_TOWN, Citizen.ResultAsInteger())
    local line = ('vector4(%.2f, %.2f, %.2f, %.2f),'):format(c.x, c.y, c.z, GetEntityHeading(ent))
    print(('[dodi_car_traffic] %s -- town zone hash %s'):format(line, tostring(zone)))
    notify(line)
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then
        return
    end
    for _, entry in pairs(known) do
        removeBlip(entry)
    end
end)
