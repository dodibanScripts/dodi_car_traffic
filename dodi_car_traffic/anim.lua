-- NPC driver visuals: dodi_cars steer clips (upper body) + hands on wheel IK.
-- Steering comes from the car's yaw rate (no A/D for AI).

local Native = {
    RequestAnimDict = 0xA862A2AD321F94B4,
    CreateObject = 0x509D5878EB39E842,
    AttachEntityToEntity = 0x6B9BBD38AB0796DF,
    SetIkTarget = 0xC32779C16FCEECD9,
    InverseKinematicsSetDisabled = 0x0EABF182FBB63D72,
    ClonePed = 0xEF29A16337FACADB,
    SetEntityAnimSpeed = 0xEAA885BA3CEA4E4A,
    GetEntityAnimCurrentTime = 0x627520389E288A73,
    SetEntityAnimCurrentTime = 0x11CDABDC7783B2BC,
    SetPedCanPlayAmbientAnims = 0x6373D1349925A70E,
    SetPedCanPlayAmbientBaseAnims = 0x0EB0585D15254740,
    SetPedCanPlayGestureAnims = 0xBAF20C5432058024,
}

local IK_LEFT_HAND = 3
local IK_RIGHT_HAND = 4
local HANDS = {
    { key = 'left', ik = IK_LEFT_HAND, shoulder = 'SKEL_L_UpperArm' },
    { key = 'right', ik = IK_RIGHT_HAND, shoulder = 'SKEL_R_UpperArm' },
}
local ANCHOR_MODELS = { `p_bottlebeer01x`, `p_crate03x` }

local AnimCfg = Config.DriverAnim
local IkCfg = Config.DriverIk

local states = {} -- [veh] = { ped, clipKey, yawRate, lastHeading, lastT, ik = {...} }
local barIkByModel = nil

local function dbg(msg)
    if DodiTraffic.isDebug() then
        print(('[dodi_car_traffic:anim] %s'):format(msg))
    end
end

local function toVec(t, fallback)
    if type(t) ~= 'table' then
        return fallback or vector3(0.0, 0.0, 0.0)
    end
    return vector3(tonumber(t.x) or 0.0, tonumber(t.y) or 0.0, tonumber(t.z) or 0.0)
end

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function cross(a, b)
    return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

-- Rodrigues: rotate p around unit axis a through c.
local function rotateAround(p, c, a, deg)
    local v = p - c
    local t = math.rad(deg)
    local cs, sn = math.cos(t), math.sin(t)
    return c + v * cs + cross(a, v) * sn + a * (dot(a, v) * (1.0 - cs))
end

-- Vehicle space -> bone 0 space (bone 0 isn't always at the entity origin / unrotated).
local function toBone(basis, v)
    local d = v - basis.origin
    return vector3(dot(d, basis.ex), dot(d, basis.ey), dot(d, basis.ez))
end

---------------------------------------------------------------------------
-- dodi_cars driverBarIk per chassis model
---------------------------------------------------------------------------

local function loadDodiCarsBarIk()
    local map = {}
    if not IkCfg.readDodiCarsConfig then
        return map
    end
    for _, car in pairs(DodiTraffic.getDodiCarsConfig().Cars or {}) do
        if type(car) == 'table' and type(car.chassisModel) == 'string' then
            local key = car.chassisModel:lower()
            if map[key] == nil then
                if car.driverBarIk == nil then
                    map[key] = 'default'
                else
                    map[key] = car.driverBarIk
                end
            end
        end
    end
    return map
end

-- Wheel-mode config for a model, or nil (bikes / disabled).
local function resolveIkConfig(model)
    if not IkCfg.enabled then
        return nil
    end
    barIkByModel = barIkByModel or loadDodiCarsBarIk()

    local raw = barIkByModel[model:lower()]
    if raw == false then
        return nil
    end

    local cfg = IkCfg.default
    if type(raw) == 'table' then
        if raw.wheel == nil and raw.bone == nil then
            cfg = {}
            for k, v in pairs(IkCfg.default) do
                cfg[k] = v
            end
            for k, v in pairs(raw) do
                cfg[k] = v
            end
        else
            cfg = raw
        end
    end
    if type(cfg.wheel) ~= 'table' or not cfg.wheel.left or not cfg.wheel.right then
        return nil
    end

    local w = cfg.wheel
    local left, right = toVec(w.left), toVec(w.right)
    local axis = toVec(w.axis, vector3(0.0, -1.0, 0.0))
    local len = #axis
    return {
        left = left,
        right = right,
        center = toVec(w.center, (left + right) / 2.0),
        axis = len > 0.001 and axis / len or vector3(0.0, -1.0, 0.0),
        maxDeg = tonumber(w.maxDeg) or 35.0,
        seatBone = w.seatBone,
        bone = w.bone,
        spread = tonumber(cfg.spread) or 0.0,
        drop = tonumber(cfg.drop) or 0.0,
        forward = tonumber(cfg.forward) or 0.0,
        side = tonumber(cfg.side) or 0.0,
        swapHands = cfg.swapHands == true,
        p7 = tonumber(cfg.p7) or IkCfg.p7,
        blendMs = tonumber(cfg.blendMs) or IkCfg.blendMs,
    }
end

---------------------------------------------------------------------------
-- Anim clips
---------------------------------------------------------------------------

local function requestDict(dict)
    if HasAnimDictLoaded(dict) then
        return true
    end
    Citizen.InvokeNative(Native.RequestAnimDict, dict)
    return false
end

local function stopClip(st)
    if st.clipKey and DoesEntityExist(st.ped) then
        local clip = AnimCfg.clips[st.clipKey]
        StopAnimTask(st.ped, clip.dict, clip.name, 1.0)
    end
    st.clipKey = nil
end

local function playClip(st, key)
    local clip = AnimCfg.clips[key]
    if not clip or not requestDict(clip.dict) then
        return
    end
    if st.clipKey and st.clipKey ~= key then
        local old = AnimCfg.clips[st.clipKey]
        StopAnimTask(st.ped, old.dict, old.name, 1.0)
    end
    TaskPlayAnim(
        st.ped,
        clip.dict,
        clip.name,
        AnimCfg.blendIn,
        AnimCfg.blendOut,
        -1,
        key == 'drive' and AnimCfg.flagsDrive or AnimCfg.flagsSteer,
        0.0,
        false,
        0,
        false,
        AnimCfg.taskFilter,
        false
    )
    st.clipKey = key
end

-- Positive yaw rate = turning left (heading grows counter-clockwise).
local function pickClip(st)
    local r = st.yawRate
    if st.clipKey == 'left' and r > AnimCfg.steerReleaseYawRate then
        return 'left'
    end
    if st.clipKey == 'right' and r < -AnimCfg.steerReleaseYawRate then
        return 'right'
    end
    if r >= AnimCfg.steerYawRate then
        return 'left'
    end
    if r <= -AnimCfg.steerYawRate then
        return 'right'
    end
    return 'drive'
end

local function updateYawRate(st, veh)
    local now = GetGameTimer()
    local h = GetEntityHeading(veh)
    if st.lastHeading then
        local dt = (now - st.lastT) / 1000.0
        if dt > 0.0 then
            local d = ((h - st.lastHeading + 540.0) % 360.0) - 180.0
            local rate = d / dt
            if GetEntitySpeedVector(veh, true).y < -0.5 then
                rate = -rate -- reversing: wheel turns the other way
            end
            st.yawRate = st.yawRate * 0.6 + rate * 0.4
        end
    end
    st.lastHeading, st.lastT = h, now
end

---------------------------------------------------------------------------
-- IK anchors
---------------------------------------------------------------------------

local anchorModel = nil

local function loadAnchorModel()
    if anchorModel then
        return anchorModel
    end
    for _, hash in ipairs(ANCHOR_MODELS) do
        if IsModelValid(hash) then
            RequestModel(hash)
            local deadline = GetGameTimer() + 3000
            while not HasModelLoaded(hash) and GetGameTimer() < deadline do
                Wait(0)
            end
            if HasModelLoaded(hash) then
                anchorModel = hash
                return hash
            end
        end
    end
    return nil
end

local function makeAnchor(at)
    local hash = loadAnchorModel()
    if not hash then
        return 0
    end
    local ent = Citizen.InvokeNative(
        Native.CreateObject, hash, at.x, at.y, at.z - 5.0,
        false, false, false, false, true,
        Citizen.ResultAsInteger()
    )
    if not ent or ent == 0 then
        return 0
    end
    SetEntityAsMissionEntity(ent, true, true)
    SetEntityVisible(ent, false)
    SetEntityCollision(ent, false, false)
    return ent
end

local function attachAnchor(ent, veh, off)
    Citizen.InvokeNative(
        Native.AttachEntityToEntity,
        ent, veh, 0,
        off.x, off.y, off.z,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true, false, false, false
    )
    SetEntityCollision(ent, false, false)
end

-- Same as dodi_cars bar_ik probeBone: 4 probes on bone 0 -> bone basis in vehicle space.
-- Cached per model (one-time cost).
local PROBE_LEN = 0.5
local basisByModel = {}

local function probeBasis(veh)
    local model = GetEntityModel(veh)
    if basisByModel[model] then
        return basisByModel[model]
    end
    local offs = {
        vector3(0.0, 0.0, 0.0),
        vector3(PROBE_LEN, 0.0, 0.0),
        vector3(0.0, PROBE_LEN, 0.0),
        vector3(0.0, 0.0, PROBE_LEN),
    }
    local probes = {}
    local ok = true
    for i, off in ipairs(offs) do
        probes[i] = makeAnchor(GetEntityCoords(veh))
        if probes[i] == 0 then
            ok = false
            break
        end
        attachAnchor(probes[i], veh, off)
    end
    local basis = nil
    if ok then
        Wait(0)
        Wait(0)
        local p = {}
        for i = 1, 4 do
            local w = GetEntityCoords(probes[i])
            p[i] = GetOffsetFromEntityGivenWorldCoords(veh, w.x, w.y, w.z)
        end
        basis = {
            origin = p[1],
            ex = (p[2] - p[1]) / PROBE_LEN,
            ey = (p[3] - p[1]) / PROBE_LEN,
            ez = (p[4] - p[1]) / PROBE_LEN,
        }
        if #basis.ex < 0.9 or #basis.ey < 0.9 or #basis.ez < 0.9 then
            basis = nil -- probes not attached yet
        end
    end
    for _, ent in pairs(probes) do
        if ent ~= 0 and DoesEntityExist(ent) then
            DetachEntity(ent, true, true)
            DeleteEntity(ent)
        end
    end
    if basis then
        basisByModel[model] = basis
        dbg(('bone0 basis model=%s origin=(%.3f %.3f %.3f) ex=(%.2f %.2f %.2f) ey=(%.2f %.2f %.2f) ez=(%.2f %.2f %.2f)')
            :format(model, basis.origin.x, basis.origin.y, basis.origin.z,
                basis.ex.x, basis.ex.y, basis.ex.z, basis.ey.x, basis.ey.y, basis.ey.z,
                basis.ez.x, basis.ez.y, basis.ez.z))
    end
    return basis
end

local function clearIk(st)
    if not st.ik then
        return
    end
    for _, hand in ipairs(HANDS) do
        local ent = st.ik.anchors[hand.key]
        if ent and DoesEntityExist(ent) then
            DetachEntity(ent, true, true)
            DeleteEntity(ent)
        end
    end
    st.ik = nil
end

-- Builds grips in vehicle space (bone 0) + 2 anchors. false if the seat bone is missing.
local function setupIk(st, veh, cfg)
    local seatPos = vector3(0.0, 0.0, 0.0)
    if cfg.seatBone then
        local idx = GetEntityBoneIndexByName(veh, cfg.seatBone)
        if idx == -1 then
            return false
        end
        local w = GetWorldPositionOfEntityBone(veh, idx)
        seatPos = GetOffsetFromEntityGivenWorldCoords(veh, w.x, w.y, w.z)
    end

    local left = seatPos + cfg.left
    local right = seatPos + cfg.right
    if cfg.spread ~= 0.0 then
        local across = right - left
        local len = #across
        if len > 0.01 then
            local dir = across / len
            left, right = left - dir * cfg.spread, right + dir * cfg.spread
        end
    end
    local tweak = vector3(cfg.side, cfg.forward, -cfg.drop)
    left, right = left + tweak, right + tweak

    local basis = probeBasis(veh)
    if not basis then
        return false
    end

    local anchors = { left = makeAnchor(GetEntityCoords(veh)), right = makeAnchor(GetEntityCoords(veh)) }
    if anchors.left == 0 or anchors.right == 0 then
        for _, ent in pairs(anchors) do
            if ent ~= 0 then
                DeleteEntity(ent)
            end
        end
        return false
    end
    attachAnchor(anchors.left, veh, toBone(basis, left))
    attachAnchor(anchors.right, veh, toBone(basis, right))

    st.ik = {
        cfg = cfg,
        basis = basis,
        anchors = anchors,
        grips = { left = left, right = right },
        center = seatPos + cfg.center + vector3(cfg.side, 0.0, 0.0),
        steerDeg = 0.0,
        attachedDeg = 0.0,
        primed = false,
    }
    Citizen.InvokeNative(Native.InverseKinematicsSetDisabled, st.ped, false)
    SetPedCanArmIk(st.ped, true)
    return true
end

local function tickIk(st, veh)
    local ik = st.ik
    local cfg = ik.cfg

    local target = math.max(-cfg.maxDeg, math.min(cfg.maxDeg, st.yawRate * IkCfg.steerGain))
    local step = IkCfg.steerDegPerSec * GetFrameTime()
    local delta = target - ik.steerDeg
    if math.abs(delta) <= step then
        ik.steerDeg = target
    else
        ik.steerDeg = ik.steerDeg + (delta > 0 and step or -step)
    end

    if math.abs(ik.steerDeg - ik.attachedDeg) >= 0.25 then
        for _, hand in ipairs(HANDS) do
            local ent = ik.anchors[hand.key]
            if DoesEntityExist(ent) then
                attachAnchor(ent, veh, toBone(ik.basis, rotateAround(ik.grips[hand.key], ik.center, cfg.axis, ik.steerDeg)))
            end
        end
        ik.attachedDeg = ik.steerDeg
    end

    local blend = ik.primed and -1 or cfg.blendMs
    ik.unreachable = 0
    for _, hand in ipairs(HANDS) do
        local ent = ik.anchors[hand.key]
        if DoesEntityExist(ent) then
            if not IsEntityAttachedToEntity(ent, veh) then
                attachAnchor(ent, veh, toBone(ik.basis, rotateAround(ik.grips[hand.key], ik.center, cfg.axis, ik.steerDeg)))
            end
            -- Reach guard: a target far from the shoulder stretches the arm (hands-up look). Skip that hand.
            local shoulderIdx = GetEntityBoneIndexByName(st.ped, hand.shoulder)
            local reach = shoulderIdx ~= -1
                and #(GetWorldPositionOfEntityBone(st.ped, shoulderIdx) - GetEntityCoords(ent))
                or 0.0
            if reach <= IkCfg.maxReach then
                local ikIndex = hand.ik
                if cfg.swapHands then
                    ikIndex = ikIndex == IK_LEFT_HAND and IK_RIGHT_HAND or IK_LEFT_HAND
                end
                Citizen.InvokeNative(Native.SetIkTarget, st.ped, ikIndex, ent, 0, 0.0, 0.0, 0.0, cfg.p7, blend, blend)
            else
                ik.unreachable = ik.unreachable + 1
                ik.lastReach = reach
            end
        end
    end
    ik.primed = true
end

---------------------------------------------------------------------------
-- Bike rider clone (dodi_cars driverVisualClone attach mode, local on every client)
-- Real rider is hidden by its owner (client.lua taskCar); clone sits on the seat bone
-- and plays the bike clips full body (flags 1, no filter) like dodi_cars cfgForPed.
---------------------------------------------------------------------------

-- clone entity -> netVeh (carjack.lua: aiming at the visible bike rider)
DodiTraffic.cloneNet = {}

local function deleteClone(st)
    if st.clone then
        DodiTraffic.cloneNet[st.clone] = nil
    end
    if st.clone and DoesEntityExist(st.clone) then
        DetachEntity(st.clone, true, true)
        DeleteEntity(st.clone)
    end
    st.clone, st.cloneClip, st.cloneHolding = nil, nil, false
end

local function attachClone(clone, veh, c)
    local bone = GetEntityBoneIndexByName(veh, c.bone)
    if bone == -1 then
        bone = 0
    end
    Citizen.InvokeNative(
        Native.AttachEntityToEntity,
        clone, veh, bone,
        c.offset.x, c.offset.y, c.offset.z,
        c.rotation.x, c.rotation.y, c.rotation.z,
        false, false, false, true, 2, true, false, false, false
    )
    SetEntityCollision(clone, false, false)
    FreezeEntityPosition(clone, true)
end

local function ensureClone(st)
    if st.clone and DoesEntityExist(st.clone) then
        if not IsEntityAttachedToEntity(st.clone, st.veh) then
            attachClone(st.clone, st.veh, st.rider.clone)
        end
        return true
    end
    local clone = Citizen.InvokeNative(Native.ClonePed, st.ped, false, false, true, Citizen.ResultAsInteger())
    if not clone or clone == 0 then
        return false
    end
    SetEntityAsMissionEntity(clone, true, true)
    SetEntityVisible(clone, true)
    SetEntityInvincible(clone, true)
    SetBlockingOfNonTemporaryEvents(clone, true)
    SetPedCanRagdoll(clone, false)
    Citizen.InvokeNative(Native.SetPedCanPlayAmbientAnims, clone, false)
    Citizen.InvokeNative(Native.SetPedCanPlayAmbientBaseAnims, clone, false)
    Citizen.InvokeNative(Native.SetPedCanPlayGestureAnims, clone, 0, 1)
    attachClone(clone, st.veh, st.rider.clone)
    st.clone, st.cloneClip, st.cloneHolding = clone, nil, false
    DodiTraffic.cloneNet[clone] = st.netVeh
    return true
end

-- carjack.lua: real rider is getting off -> clone gone now (other clients drop it on 'remove')
function DodiTraffic.killClone(netVeh)
    local st = states[netVeh]
    if st then
        st.noClone = true
        deleteClone(st)
    end
end

local function tickClone(st)
    if st.noClone then
        return
    end
    if st.dist > Config.Bikes.cloneDist or not IsPedSittingInVehicle(st.ped, st.veh) then
        deleteClone(st)
        return
    end
    if not ensureClone(st) then
        return
    end
    local rider = st.rider
    local clips = rider.clips or AnimCfg.clips
    local key = pickClip(st)
    local clip = clips[key]
    if not clip or not requestDict(clip.dict) then
        return
    end

    if key ~= st.cloneClip or not IsEntityPlayingAnim(st.clone, clip.dict, clip.name, 3) then
        TaskPlayAnim(st.clone, clip.dict, clip.name, 8.0, -8.0, -1, 1, 0.0, false, 0, false, false, false)
        st.cloneClip, st.cloneHolding = key, false
        st.clipKey = key -- pickClip hysteresis
        return
    end

    -- left/right: run to holdPhase then freeze (dodi_cars holdLastFrame); drive: animRate
    if key ~= 'drive' then
        if not st.cloneHolding then
            local phase = Citizen.InvokeNative(Native.GetEntityAnimCurrentTime, st.clone, clip.dict, clip.name, Citizen.ResultAsFloat()) or 0.0
            if phase >= rider.holdPhase then
                st.cloneHolding = true
            elseif rider.animRate > 0.0 then
                Citizen.InvokeNative(Native.SetEntityAnimSpeed, st.clone, clip.dict, clip.name, rider.animRate + 0.0)
            end
        end
        if st.cloneHolding then
            Citizen.InvokeNative(Native.SetEntityAnimSpeed, st.clone, clip.dict, clip.name, 0.0)
            Citizen.InvokeNative(Native.SetEntityAnimCurrentTime, st.clone, clip.dict, clip.name, rider.holdPhase + 0.0)
        end
    elseif rider.animRate > 0.0 then
        Citizen.InvokeNative(Native.SetEntityAnimSpeed, st.clone, clip.dict, clip.name, rider.animRate + 0.0)
    end
end

---------------------------------------------------------------------------
-- Threads (states keyed by netVeh; entities resolved every tick)
---------------------------------------------------------------------------

local function dropState(netVeh)
    local st = states[netVeh]
    if not st then
        return
    end
    deleteClone(st)
    clearIk(st)
    if st.ped and DoesEntityExist(st.ped) and NetworkHasControlOfEntity(st.ped) then
        stopClip(st)
    end
    states[netVeh] = nil
end

-- Clips (ped owner only, task syncs) + yaw rate for everyone (100ms)
CreateThread(function()
    while true do
        local sleep = 500
        local known = DodiTraffic.known
        if (AnimCfg.enabled or IkCfg.enabled) and next(known) then
            sleep = 100
            local pc = GetEntityCoords(PlayerPedId())

            for netVeh in pairs(states) do
                if not known[netVeh] then
                    dropState(netVeh)
                end
            end

            for netVeh, entry in pairs(known) do
                local veh, ped = 0, 0
                if not entry.parked then
                    veh, ped = DodiTraffic.resolve(entry)
                end
                if veh == 0 or ped == 0 then
                    if states[netVeh] then
                        dropState(netVeh)
                    end
                else
                    local st = states[netVeh]
                    if not st or st.ped ~= ped or st.veh ~= veh then
                        dropState(netVeh)
                        st = { netVeh = netVeh, veh = veh, ped = ped, model = entry.model, yawRate = 0.0 }
                        st.rider = DodiTraffic.getRiderCfg(entry.model)
                        -- bikes: hands come from the clip (dodi bone-mode IK not ported)
                        st.ikCfg = not (st.rider and st.rider.clone) and resolveIkConfig(entry.model) or nil
                        states[netVeh] = st
                    end

                    updateYawRate(st, veh)
                    st.dist = #(GetEntityCoords(veh) - pc)

                    st.jacked = entry.jacked ~= nil and not (st.rider and st.rider.clone)
                    if st.jacked then
                        -- car driver in a carjack (hands up): no wheel clip / IK
                        if st.clipKey and NetworkHasControlOfEntity(ped) then
                            stopClip(st)
                        end
                    elseif st.rider and st.rider.clone then
                        if AnimCfg.enabled then
                            tickClone(st)
                        end
                    elseif AnimCfg.enabled and NetworkHasControlOfEntity(ped) then
                        if st.dist <= AnimCfg.maxDist and IsPedSittingInVehicle(ped, veh) then
                            local key = pickClip(st)
                            local clip = AnimCfg.clips[key]
                            if key ~= st.clipKey or not IsEntityPlayingAnim(ped, clip.dict, clip.name, 3) then
                                playClip(st, key)
                            end
                        elseif st.clipKey then
                            stopClip(st)
                        end
                    end
                end
            end
            -- IK budget: N closest on-screen drivers within maxDist
            local ranked = {}
            for _, st in pairs(states) do
                st.ikAllowed = false
                if st.ikCfg and not st.jacked and st.dist and st.dist <= IkCfg.maxDist and IsEntityOnScreen(st.veh) then
                    ranked[#ranked + 1] = st
                end
            end
            table.sort(ranked, function(a, b)
                return a.dist < b.dist
            end)
            for i = 1, math.min(#ranked, IkCfg.maxCars or 3) do
                ranked[i].ikAllowed = true
            end
        elseif next(states) then
            for netVeh in pairs(states) do
                dropState(netVeh)
            end
        end
        Wait(sleep)
    end
end)

-- Hands IK, local on every client (per frame while any driver is close)
CreateThread(function()
    while true do
        local sleep = 250
        if IkCfg.enabled then
            for _, st in pairs(states) do
                local near = st.ikAllowed and DoesEntityExist(st.veh)
                if near and not st.ik and (st.ikRetryAt or 0) <= GetGameTimer() then
                    if not setupIk(st, st.veh, st.ikCfg) then
                        st.ikRetryAt = GetGameTimer() + 2000
                        dbg(('ik setup failed veh=%s model=%s'):format(st.veh, st.model))
                    end
                elseif not near and st.ik then
                    clearIk(st)
                end
                if st.ik then
                    sleep = 0
                    tickIk(st, st.veh)
                end
            end
        end
        Wait(sleep)
    end
end)

-- Nearest traffic driver state (F8). Use when a driver looks wrong.
DevCommand('trafficinspect', function()
    local pc = GetEntityCoords(PlayerPedId())
    local best, bestNet, bestDist = nil, nil, 20.0
    for netVeh, st in pairs(states) do
        if DoesEntityExist(st.veh) then
            local d = #(GetEntityCoords(st.veh) - pc)
            if d < bestDist then
                best, bestNet, bestDist = st, netVeh, d
            end
        end
    end
    if not best then
        print('[dodi_car_traffic] inspect: no traffic driver within 20m')
        return
    end
    local st, ped, veh = best, best.ped, best.veh
    local clip = st.clipKey and AnimCfg.clips[st.clipKey]
    local lines = {
        ('net=%s model=%s dist=%.1f'):format(bestNet, st.model, bestDist),
        ('vehOwner=%s pedOwner=%s (me=%s)'):format(
            NetworkGetEntityOwner(veh), NetworkGetEntityOwner(ped), PlayerId()),
        ('collisionDisabled=%s waitingWorldCol=%s myVeh=%s myVehColDisabled=%s'):format(
            tostring(Citizen.InvokeNative(0xAA2FADD30F45A9DA, veh, Citizen.ResultAsInteger()) == 1),
            tostring(Citizen.InvokeNative(0x5E1CC2E8DC3111DD, veh, Citizen.ResultAsInteger()) == 1),
            tostring(GetVehiclePedIsIn(PlayerPedId(), false)),
            tostring(GetVehiclePedIsIn(PlayerPedId(), false) ~= 0
                and Citizen.InvokeNative(0xAA2FADD30F45A9DA, GetVehiclePedIsIn(PlayerPedId(), false), Citizen.ResultAsInteger()) == 1)),
        ('seat-1=%s sitting=%s dead=%s'):format(
            tostring(GetPedInVehicleSeat(veh, -1) == ped), tostring(IsPedSittingInVehicle(ped, veh)),
            tostring(IsEntityDead(ped))),
        ('clip=%s playing=%s yaw=%.1f'):format(
            tostring(st.clipKey), tostring(clip and IsEntityPlayingAnim(ped, clip.dict, clip.name, 3) or false),
            st.yawRate or 0.0),
        ('ik=%s allowed=%s unreachable=%s lastReach=%s cfg=%s'):format(
            tostring(st.ik ~= nil), tostring(st.ikAllowed), tostring(st.ik and st.ik.unreachable),
            st.ik and st.ik.lastReach and ('%.2f'):format(st.ik.lastReach) or '-',
            st.ikCfg and (st.ikCfg.seatBone and 'seatBone' or 'vehSpace') or 'none'),
    }
    if st.ik and st.ik.basis then
        local b = st.ik.basis
        lines[#lines + 1] = ('bone0 origin=(%.3f %.3f %.3f) ez=(%.2f %.2f %.2f)'):format(
            b.origin.x, b.origin.y, b.origin.z, b.ez.x, b.ez.y, b.ez.z)
    end
    for _, l in ipairs(lines) do
        print('[dodi_car_traffic] inspect ' .. l)
    end
end, false)

DevCommand('trafficanimflags', function(_, args)
    AnimCfg.flagsDrive = tonumber(args[1]) or AnimCfg.flagsDrive
    AnimCfg.flagsSteer = tonumber(args[2]) or AnimCfg.flagsSteer
    for _, st in pairs(states) do
        st.clipKey = nil -- force replay
    end
    print(('[dodi_car_traffic] anim flags drive=%d steer=%d'):format(AnimCfg.flagsDrive, AnimCfg.flagsSteer))
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then
        return
    end
    for netVeh in pairs(states) do
        dropState(netVeh)
    end
end)
