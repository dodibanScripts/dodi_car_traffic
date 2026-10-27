-- City traffic population manager.
-- Server decides budgets per city and asks a host client (a player inside the city) to spawn.
-- Whoever is the network owner of a car drives it (client.lua); server only cleans up.
-- Engine audio goes through dodi_cars (same events player cars use).

local Pop = Config.Population

local traffic = {} -- [netVeh] = { netPed, model, carId, city, parked, slot, speed, mode, owner }
local cities = {} -- [cityId] = { active, host, pending = { [id] = expiresAt }, parkedPending = { [slot] = expiresAt } }
local paused = not Pop.enabled
local currentHour = 12
local pendingSeq = 0

local function dbg(msg)
    if Config.Debug then
        print(('[dodi_car_traffic] %s'):format(msg))
    end
end

for id in pairs(Config.Cities) do
    cities[id] = { active = false, host = nil, pending = {}, parkedPending = {} }
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function entityFromNet(netId)
    if not netId or netId == 0 then
        return 0
    end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent and ent ~= 0 and DoesEntityExist(ent) then
        return ent
    end
    return 0
end

local function setEngineAudio(netVeh, carId, enabled)
    if not carId or not Config.Audio.enabled or GetResourceState('dodi_cars') ~= 'started' then
        return
    end
    -- dodi_cars server handler doesn't use source; broadcasts engineAudioState + keeps it for late joiners
    TriggerEvent('dodi_cars:setEngineAudio', netVeh, carId, enabled)
    if not enabled then
        TriggerClientEvent('dodi_cars:engineThrottleState', -1, netVeh, 0.0)
    end
end

local function removeTraffic(netVeh, reason)
    local t = traffic[netVeh]
    if not t then
        return
    end
    traffic[netVeh] = nil
    setEngineAudio(netVeh, t.carId, false)

    local ped = entityFromNet(t.netPed)
    if ped ~= 0 then
        DeleteEntity(ped)
    end
    local veh = entityFromNet(netVeh)
    if veh ~= 0 then
        DeleteEntity(veh)
    end
    TriggerClientEvent('dodi_car_traffic:client:remove', -1, netVeh)
    dbg(('remove net=%s city=%s reason=%s'):format(netVeh, tostring(t.city), reason or '-'))
end

local function hourMult(list, hour)
    for _, r in ipairs(list or Pop.hourMultiplier) do
        if r.from <= r.to then
            if hour >= r.from and hour < r.to then
                return r.mult
            end
        elseif hour >= r.from or hour < r.to then
            return r.mult
        end
    end
    return 1.0
end

local function cityTarget(city)
    return math.floor((city.budget or 0) * hourMult(city.hourMultiplier, currentHour) + 0.5)
end

local function flat(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function getPlayerPositions()
    local list = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            list[#list + 1] = { src = src, pos = GetEntityCoords(ped) }
        end
    end
    return list
end

local function nearestPlayerDist(pos, players)
    local best = math.huge
    for _, p in ipairs(players) do
        local d = #(p.pos - pos)
        if d < best then
            best = d
        end
    end
    return best
end

local function countPending(map, now)
    local n = 0
    for k, exp in pairs(map) do
        if exp < now then
            map[k] = nil
        else
            n = n + 1
        end
    end
    return n
end

---------------------------------------------------------------------------
-- Population tick
---------------------------------------------------------------------------

local function cleanup(players)
    -- carjack left hanging (robber dropped / client crashed): back to traffic
    local jackTimeout = math.max(Config.Carjack.floorItMs, Config.Carjack.releaseMs) + 15000
    for netVeh, t in pairs(traffic) do
        if t.jacked and t.jackedAt and GetGameTimer() - t.jackedAt > jackTimeout then
            t.jacked, t.jackedAt = nil, nil
            TriggerClientEvent('dodi_car_traffic:client:jackState', -1, netVeh, nil)
        end
    end

    for netVeh, t in pairs(traffic) do
        local veh = entityFromNet(netVeh)
        if veh == 0 then
            -- entity gone server side (deleted / never created)
            if GetGameTimer() - (t.registeredAt or 0) > 5000 then
                removeTraffic(netVeh, 'entity missing')
            end
        else
            local pos = GetEntityCoords(veh)
            local near = nearestPlayerDist(pos, players)
            local city = t.city and Config.Cities[t.city]
            if near > Pop.despawnDist then
                removeTraffic(netVeh, ('no player within %.0fm'):format(Pop.despawnDist))
            elseif city and not t.parked and flat(pos, city.center) > city.radius * 1.1 and near > Pop.outsideCityDespawnDist then
                removeTraffic(netVeh, 'left city')
            elseif not t.parked and t.netPed and entityFromNet(t.netPed) == 0 and GetGameTimer() - (t.registeredAt or 0) > 5000
                and near > Pop.minPlayerDist -- never yank a car from under a player (jacked / sitting in it)
            then
                removeTraffic(netVeh, 'driver missing')
            elseif not t.parked then
                -- backstop for the owner's stuck logic (never removes while visible / migrating / refused)
                local now, S = GetGameTimer(), Config.Stuck
                if t.jacked or not t.progressPos or #(pos - t.progressPos) > S.progressDist then
                    t.progressPos, t.progressAt = pos, now
                elseif now - t.progressAt > S.forceRemoveMs and near > S.forceMinPlayerDist then
                    removeTraffic(netVeh, ('no progress %ds (forced)'):format((now - t.progressAt) // 1000))
                elseif now - t.progressAt > S.noProgressMs and near > Pop.minPlayerDist then
                    removeTraffic(netVeh, ('no progress %ds'):format((now - t.progressAt) // 1000))
                end
            end
        end
    end
end

-- Vehicles tagged dodiTraffic that the server lost track of (tracked entry removed, entity kept)
local orphanSince = {}
local function sweepOrphans(players)
    local now, S = GetGameTimer(), Config.Stuck
    local seen = {}
    for _, veh in ipairs(GetAllVehicles()) do
        local st = Entity(veh).state
        if st.dodiTraffic and not st.dodiStolen then
            local netVeh = NetworkGetNetworkIdFromEntity(veh)
            if not traffic[netVeh] then
                seen[netVeh] = true
                orphanSince[netVeh] = orphanSince[netVeh] or now
                if now - orphanSince[netVeh] > S.orphanGraceMs
                    and nearestPlayerDist(GetEntityCoords(veh), players) > Pop.minPlayerDist
                then
                    local ped = GetPedInVehicleSeat(veh, Config.DriverSeat)
                    if ped and ped ~= 0 and not IsPedAPlayer(ped) then
                        DeleteEntity(ped)
                    end
                    DeleteEntity(veh)
                    seen[netVeh] = nil
                    dbg(('orphan deleted net=%s'):format(netVeh))
                end
            end
        end
    end
    for netVeh in pairs(orphanSince) do
        if not seen[netVeh] then
            orphanSince[netVeh] = nil
        end
    end
end

local function tickCities(players)
    local now = GetGameTimer()
    local total = 0
    local perCity, parkedPerCity = {}, {}
    for _, t in pairs(traffic) do
        if t.city then
            if t.parked then
                parkedPerCity[t.city] = parkedPerCity[t.city] or {}
                parkedPerCity[t.city][t.slot] = true
            else
                perCity[t.city] = (perCity[t.city] or 0) + 1
            end
        end
        if not t.parked then
            total = total + 1
        end
    end

    for id, city in pairs(Config.Cities) do
        local st = cities[id]
        local inside = {}
        if city.enabled then
            for _, p in ipairs(players) do
                if flat(p.pos, city.center) <= city.activationRadius then
                    inside[#inside + 1] = p
                end
            end
        end

        if #inside == 0 then
            if st.active then
                dbg(('city %s off'):format(id))
            end
            st.active, st.host = false, nil
        else
            if not st.active then
                dbg(('city %s on (%d players)'):format(id, #inside))
            end
            st.active = true

            -- keep host while inside, else closest to center
            local hostOk = false
            for _, p in ipairs(inside) do
                if p.src == st.host then
                    hostOk = true
                    break
                end
            end
            if not hostOk then
                table.sort(inside, function(a, b)
                    return flat(a.pos, city.center) < flat(b.pos, city.center)
                end)
                st.host = inside[1].src
                dbg(('city %s host -> %s'):format(id, st.host))
            end

            if not paused then
                -- driving cars
                local count = (perCity[id] or 0) + countPending(st.pending, now)
                local target = cityTarget(city)
                if count < target and total < Pop.maxTotal then
                    local burst = count < target * Pop.fillBelow and Pop.fillSpawnPerTick or Pop.spawnPerTick
                    local n = math.min(target - count, burst, Pop.maxTotal - total)
                    if n > 0 then
                        local ids = {}
                        for i = 1, n do
                            pendingSeq = pendingSeq + 1
                            st.pending[pendingSeq] = now + Pop.pendingTimeoutMs
                            ids[i] = pendingSeq
                        end
                        total = total + n
                        TriggerClientEvent('dodi_car_traffic:client:citySpawn', st.host, id, ids)
                    end
                end

                -- parked cars
                if city.parked and #city.parked > 0 then
                    countPending(st.parkedPending, now)
                    local have = parkedPerCity[id] or {}
                    local slots = {}
                    for slot = 1, #city.parked do
                        if not have[slot] and not st.parkedPending[slot] then
                            slots[#slots + 1] = slot
                            st.parkedPending[slot] = now + Pop.pendingTimeoutMs
                        end
                    end
                    if #slots > 0 then
                        TriggerClientEvent('dodi_car_traffic:client:cityParked', st.host, id, slots)
                    end
                end
            end
        end
    end
end

CreateThread(function()
    local lastSweep = 0
    while true do
        Wait(Pop.tickMs)
        local players = getPlayerPositions()
        cleanup(players)
        if GetGameTimer() - lastSweep > Config.Stuck.orphanSweepMs then
            lastSweep = GetGameTimer()
            sweepOrphans(players)
        end
        tickCities(players)
    end
end)

---------------------------------------------------------------------------
-- Client events
---------------------------------------------------------------------------

local function publicData(netVeh, t)
    return {
        netVeh = netVeh,
        netPed = t.netPed,
        model = t.model,
        carId = t.carId,
        city = t.city,
        parked = t.parked,
        speed = t.speed,
        mode = t.mode,
        jacked = t.jacked,
    }
end

-- data = { netVeh, netPed, model, carId, city, parked, slot, speed, mode, pendingId }
RegisterNetEvent('dodi_car_traffic:server:register', function(data)
    local src = source
    if type(data) ~= 'table' or type(data.netVeh) ~= 'number' or data.netVeh == 0 then
        return
    end
    local city = data.city and Config.Cities[data.city] and data.city or nil
    if city then
        local st = cities[city]
        if data.pendingId then
            st.pending[data.pendingId] = nil
        end
        if data.parked and data.slot then
            st.parkedPending[data.slot] = nil
        end
    end

    local t = {
        netPed = tonumber(data.netPed) or 0,
        model = tostring(data.model or ''),
        carId = type(data.carId) == 'string' and data.carId ~= '' and data.carId or nil,
        city = city,
        parked = data.parked == true,
        slot = tonumber(data.slot),
        speed = tonumber(data.speed),
        mode = data.mode == 'wander' and 'wander' or 'roam',
        owner = src,
        registeredAt = GetGameTimer(),
    }
    traffic[data.netVeh] = t
    local veh = entityFromNet(data.netVeh)
    if veh ~= 0 then
        Entity(veh).state:set('dodiTraffic', true, false) -- server-only tag for sweepOrphans
    end
    if not t.parked then
        setEngineAudio(data.netVeh, t.carId, true)
    end
    TriggerClientEvent('dodi_car_traffic:client:add', -1, publicData(data.netVeh, t))
end)

-- Spawn failed on the host: free the pending slot so the next tick retries
RegisterNetEvent('dodi_car_traffic:server:spawnFailed', function(cityId, pendingId, slot)
    local st = cities[cityId]
    if not st then
        return
    end
    if pendingId then
        st.pending[pendingId] = nil
    end
    if slot then
        st.parkedPending[slot] = nil
    end
end)

-- Owner asks to remove (stuck / driver dead)
RegisterNetEvent('dodi_car_traffic:server:remove', function(netVeh, reason)
    local src = source
    local t = traffic[netVeh]
    if not t then
        return
    end
    local veh = entityFromNet(netVeh)
    if veh ~= 0 and NetworkGetEntityOwner(veh) ~= src and t.owner ~= src then
        return
    end
    removeTraffic(netVeh, ('client %s: %s'):format(src, tostring(reason)))
end)

-- batch = { [tostring(netVeh)] = ratio }, sent by the car's network owner
RegisterNetEvent('dodi_car_traffic:server:throttle', function(batch)
    local src = source
    if type(batch) ~= 'table' then
        return
    end
    for key, ratio in pairs(batch) do
        local netVeh = tonumber(key)
        local t = netVeh and traffic[netVeh]
        if t and t.carId and type(ratio) == 'number' then
            local veh = entityFromNet(netVeh)
            if veh ~= 0 and NetworkGetEntityOwner(veh) == src then
                TriggerClientEvent('dodi_cars:engineThrottleState', -1, netVeh, math.max(0.0, math.min(1.0, ratio)))
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Carjack
---------------------------------------------------------------------------

local function robberNear(src, netVeh, maxDist)
    local ped = GetPlayerPed(src)
    local veh = entityFromNet(netVeh)
    return ped ~= 0 and veh ~= 0 and #(GetEntityCoords(ped) - GetEntityCoords(veh)) <= maxDist
end

-- 'surrender' | 'floor' | nil
RegisterNetEvent('dodi_car_traffic:server:jackState', function(netVeh, jackState)
    local src = source
    local t = traffic[netVeh]
    if not t or t.parked then
        return
    end
    if jackState ~= nil and jackState ~= 'surrender' and jackState ~= 'floor' then
        return
    end
    if jackState and not robberNear(src, netVeh, Config.Carjack.keepDist + 10.0) then
        return
    end
    t.jacked = jackState
    t.jackedAt = jackState and GetGameTimer() or nil
    TriggerClientEvent('dodi_car_traffic:client:jackState', -1, netVeh, jackState)
end)

-- Driver is out: vehicle leaves the population (not deleted) and becomes a dodi_cars car.
local function adoptStolen(netVeh, t, src, how)
    traffic[netVeh] = nil
    setEngineAudio(netVeh, t.carId, false)
    TriggerClientEvent('dodi_car_traffic:client:remove', -1, netVeh)

    local veh = entityFromNet(netVeh)
    if veh ~= 0 then
        Entity(veh).state:set('dodiStolen', true, true)
        Entity(veh).state:set('dodiTraffic', nil, false)
    end
    if t.carId and GetResourceState('dodi_cars') == 'started' then
        -- no vehicleDbId -> unowned "command" car (fuel / trunk / speedometer, no owner lock)
        TriggerEvent('dodi_cars:spawnShell', netVeh, t.carId)
    end
    dbg(('stolen (%s) net=%s model=%s by %s'):format(how, netVeh, t.model, src))
end

RegisterNetEvent('dodi_car_traffic:server:stolen', function(netVeh)
    local src = source
    local t = traffic[netVeh]
    if not t or t.jacked ~= 'surrender' or not robberNear(src, netVeh, Config.Carjack.keepDist + 10.0) then
        return
    end
    adoptStolen(netVeh, t, src, 'carjack')
end)

-- Vanilla jack (E on the driver door, no gun): the player is already in the driver seat.
-- Distance check only: server-side GET_PED_IN_VEHICLE_SEAT reads 0 on RDR vehicles.
RegisterNetEvent('dodi_car_traffic:server:pulledOut', function(netVeh)
    local src = source
    local t = traffic[netVeh]
    if not t or t.parked or not robberNear(src, netVeh, 6.0) then
        dbg(('pulledOut refused net=%s src=%s known=%s'):format(tostring(netVeh), src, tostring(t ~= nil)))
        return
    end
    adoptStolen(netVeh, t, src, 'pulled out')
end)

local lastAlert = {}

-- coords = { x, y, z }, info = { place, vehicle, floorIt }
RegisterNetEvent('dodi_car_traffic:server:policeAlert', function(coords, info)
    local src = source
    local P = Config.CarjackPolice
    if not P.enabled or type(coords) ~= 'table' or GetResourceState('dodi_police') ~= 'started' then
        return
    end
    local now = GetGameTimer()
    if lastAlert[src] and now - lastAlert[src] < P.cooldownMs then
        return
    end
    lastAlert[src] = now

    local ok, officers = pcall(function()
        return exports['dodi_police']:GetOnlineOfficers()
    end)
    if not ok or type(officers) ~= 'table' then
        return
    end
    info = type(info) == 'table' and info or {}
    local pos = vector3(tonumber(coords.x) or 0.0, tonumber(coords.y) or 0.0, tonumber(coords.z) or 0.0)
    local n = 0
    for officerId in pairs(officers) do
        local id = tonumber(officerId)
        if id and id ~= src then
            TriggerClientEvent('dodi_car_traffic:client:policeAlert', id, pos, tostring(info.place or ''),
                tostring(info.vehicle or ''), info.floorIt == true, info.pulled == true)
            n = n + 1
        end
    end
    dbg(('police alert carjack by %s -> %d officers'):format(src, n))
end)

RegisterNetEvent('dodi_car_traffic:server:hour', function(hour)
    hour = tonumber(hour)
    if hour and hour >= 0 and hour < 24 then
        currentHour = math.floor(hour)
    end
end)

-- Late joiner / resource restart on client
RegisterNetEvent('dodi_car_traffic:server:hello', function()
    local src = source
    local list = {}
    for netVeh, t in pairs(traffic) do
        list[#list + 1] = publicData(netVeh, t)
    end
    TriggerClientEvent('dodi_car_traffic:client:sync', src, list)
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, st in pairs(cities) do
        if st.host == src then
            st.host = nil
        end
    end
    -- cars migrate to other players; cleanup() removes them if nobody is near
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then
        return
    end
    for netVeh in pairs(traffic) do
        removeTraffic(netVeh, 'resource stop')
    end
end)

---------------------------------------------------------------------------
-- Admin commands (restricted: need "command" ace)
---------------------------------------------------------------------------

local function reply(src, msg)
    if src == 0 then
        print(msg)
    else
        TriggerClientEvent('dodi_car_traffic:client:notify', src, msg)
    end
end

RegisterCommand('trafficcar', function(src, args)
    if src ~= 0 then
        TriggerClientEvent('dodi_car_traffic:client:testCar', src, args)
    end
end, true)

RegisterCommand('trafficfill', function(src, args)
    if src ~= 0 then
        TriggerClientEvent('dodi_car_traffic:client:testFill', src, tonumber(args[1]) or 5)
    end
end, true)

RegisterCommand('trafficclear', function(src)
    local n = 0
    for netVeh in pairs(traffic) do
        removeTraffic(netVeh, 'trafficclear')
        n = n + 1
    end
    for _, st in pairs(cities) do
        st.pending, st.parkedPending = {}, {}
    end
    reply(src, ('Traffic: %d removed%s'):format(n, paused and '' or ' (population will refill; /trafficpause to stop)'))
end, true)

RegisterCommand('trafficpause', function(src)
    paused = not paused
    reply(src, ('Traffic population: %s'):format(paused and 'PAUSED' or 'ACTIVE'))
end, true)

RegisterCommand('trafficstatus', function(src)
    local perCity, total = {}, 0
    for _, t in pairs(traffic) do
        local key = t.city or 'test'
        perCity[key] = perCity[key] or { driving = 0, parked = 0 }
        if t.parked then
            perCity[key].parked = perCity[key].parked + 1
        else
            perCity[key].driving = perCity[key].driving + 1
            total = total + 1
        end
    end
    local lines = { ('hour=%d total=%d/%d %s'):format(currentHour, total, Pop.maxTotal, paused and 'PAUSED' or '') }
    for id, city in pairs(Config.Cities) do
        local st = cities[id]
        local c = perCity[id] or { driving = 0, parked = 0 }
        lines[#lines + 1] = ('%s: %s host=%s driving=%d/%d parked=%d/%d'):format(
            id, st.active and 'ON' or 'off', tostring(st.host), c.driving, cityTarget(city), c.parked, #(city.parked or {}))
    end
    if perCity.test then
        lines[#lines + 1] = ('test: %d'):format(perCity.test.driving)
    end
    for _, l in ipairs(lines) do
        print('[dodi_car_traffic] ' .. l)
        if src ~= 0 then
            TriggerClientEvent('chat:addMessage', src, { args = { 'traffic', l } })
        end
    end
end, true)
