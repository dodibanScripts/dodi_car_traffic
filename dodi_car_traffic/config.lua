Config = {}

Config.Debug = false -- /trafficdebug toggles it client-side at runtime

-- Client tuning commands (/trafficmode /trafficstyle /trafficdebug /trafficpoint /trafficwhy
-- /trafficinspect /trafficanimflags /trafficdismount). Anyone can type them -> keep off on live servers.
Config.DevCommands = false

-- Server commands (/trafficcar /trafficfill /trafficclear /trafficpause /trafficstatus) are restricted.
-- Admins with "command" allowed (RSG default for group.admin) can use them.

---------------------------------------------------------------------------
-- Defaults (each city can override models / drivers / speed / mode)
---------------------------------------------------------------------------

-- { model, weight }. Models not streamed on the server are skipped automatically:
-- dodi_cars_vehicles ships union_pickup + union_sedan, the rest come from the YourMAPS packs
-- (yourmaps_native_cars, yourmaps_vintage_motorbikes). Every list below keeps at least one of the two.
Config.DefaultModels = {
    { 'union_pickup', 3 },
    { 'union_sedan', 3 },
    { 'union_taxi', 1 },
    { 'liberty_tourer', 3 },
    { 'liberty_taxi', 1 },
    { 'liberty_marbella_duo', 2 },
    { 'bellano_six', 1 },
    { 'velmar_coupe', 1 },
    { 'imperia_class', 1 },
    -- yourmaps_vintage_motorbikes (rider = hidden ped + local clone on seat bone, like dodi_cars)
    { 'fumel_250', 1 },
    { 'fumel_350', 1 },
    { 'zunvap_courier', 1 },
}

-- Per model tweaks. speed beats city / default range.
Config.ModelOverrides = {
    fumel_250 = { speed = { min = 5.0, max = 7.5 } },
    fumel_350 = { speed = { min = 5.5, max = 8.0 } },
    zunvap_courier = { speed = { min = 4.5, max = 6.5 } },
    granger_tractor = { speed = { min = 3.0, max = 4.5 } },
    union_delivery = { speed = { min = 4.5, max = 6.5 } },
    imperia_class = { speed = { min = 5.0, max = 7.0 } }, -- rich folk cruise, they don't race
}

-- Per city mix by price tier (dealer: bikes 420-560 < pickup 790 < tourer/taxi 960
-- < marbella/sedan 1100 < bellano/velmar ~1450 < imperia 1850)
local MODELS_FRONTIER = { -- small/rural towns: work vehicles + cheap bikes, rare used sedan
    { 'union_pickup', 6 },
    { 'fumel_250', 3 },
    { 'zunvap_courier', 2 },
    { 'liberty_tourer', 2 },
    { 'granger_tractor', 1 },
}
local MODELS_TOWN = { -- Rhodes: farm money, a few middle class cars
    { 'union_pickup', 5 },
    { 'liberty_tourer', 3 },
    { 'fumel_250', 2 },
    { 'fumel_350', 1 },
    { 'zunvap_courier', 1 },
    { 'union_sedan', 1 },
    { 'liberty_marbella_duo', 1 },
}
local MODELS_BLACKWATER = { -- modern/progressive town: middle class + some luxury
    { 'liberty_tourer', 4 },
    { 'union_sedan', 4 },
    { 'liberty_marbella_duo', 3 },
    { 'union_pickup', 2 },
    { 'liberty_taxi', 1 },
    { 'union_delivery', 1 },
    { 'bellano_six', 2 },
    { 'velmar_coupe', 2 },
    { 'imperia_class', 1 },
    { 'fumel_350', 1 },
}
local MODELS_SAINT_DENIS = { -- big city: taxis, deliveries, the rich
    { 'union_sedan', 4 },
    { 'liberty_tourer', 3 },
    { 'liberty_marbella_duo', 3 },
    { 'union_taxi', 3 },
    { 'liberty_taxi', 3 },
    { 'union_delivery', 2 },
    { 'bellano_six', 3 },
    { 'velmar_coupe', 3 },
    { 'imperia_class', 2 },
    { 'union_pickup', 1 },
    { 'fumel_350', 1 },
}

local DRIVERS_VALENTINE = {
    'A_M_M_VALTOWNFOLK_01',
    'A_M_M_VALTOWNFOLK_02',
    'A_M_M_VALFARMER_01',
    'A_M_M_VALLABORER_01',
    'A_M_M_RANCHER_01',
    'A_M_M_RANCHERTRAVELERS_WARM_01',
}
local DRIVERS_RHODES = {
    'A_M_M_RHDTOWNFOLK_01',
    'A_M_M_RHDTOWNFOLK_02',
    'A_M_M_RHDFOREMAN_01',
    'A_M_M_RHDUPPERCLASS_01',
    'A_F_M_RHDTOWNFOLK_01',
    'A_M_M_RANCHERTRAVELERS_WARM_01',
}
local DRIVERS_BLACKWATER = {
    'A_M_M_BLWTOWNFOLK_01',
    'A_M_M_BLWUPPERCLASS_01',
    'A_M_M_BLWFOREMAN_01',
    'A_F_M_BLWTOWNFOLK_01',
    'A_F_M_BLWUPPERCLASS_01',
    'A_M_O_BLWUPPERCLASS_01',
}
local DRIVERS_SAINT_DENIS = {
    'A_M_M_BYNFANCYDRIVERS_01',
    'A_M_M_NBXUPPERCLASS_01',
    'A_F_M_NBXUPPERCLASS_01',
    'A_M_M_MIDDLESDTOWNFOLK_01',
    'A_M_M_MIDDLESDTOWNFOLK_02',
    'A_M_M_MIDDLESDTOWNFOLK_03',
    'A_F_M_MIDDLESDTOWNFOLK_01',
    'A_M_O_SDUPPERCLASS_01',
    'A_M_M_NBXDOCKWORKERS_01',
}
local DRIVERS_FRONTIER = {
    'A_M_M_STRTOWNFOLK_01',
    'A_M_M_STRLABORER_01',
    'A_M_M_ASBTOWNFOLK_01',
    'A_M_M_RANCHER_01',
    'A_M_M_RANCHERTRAVELERS_COOL_01',
    'A_M_M_RANCHERTRAVELERS_WARM_01',
}

-- Small towns go to bed early, Saint Denis never fully sleeps
local HOURS_SMALL_TOWN = {
    { from = 6, to = 8, mult = 0.5 },
    { from = 8, to = 18, mult = 1.0 },
    { from = 18, to = 21, mult = 0.4 },
    { from = 21, to = 6, mult = 0.0 },
}
local HOURS_BIG_CITY = {
    { from = 5, to = 7, mult = 0.4 },
    { from = 7, to = 10, mult = 1.0 }, -- morning rush
    { from = 10, to = 16, mult = 0.8 },
    { from = 16, to = 20, mult = 1.0 }, -- evening rush
    { from = 20, to = 23, mult = 0.6 }, -- theater / saloons
    { from = 23, to = 5, mult = 0.25 },
}

-- Bike rider clone (anim.lua). Offset / bone / clips come from dodi_cars driverVisualClone + driverSteer.
Config.Bikes = {
    cloneDist = 150.0, -- clone shown within this; farther the hidden rider = riderless bike
}

-- Invalid models are skipped at runtime (printed when Config.Debug)
Config.DefaultDrivers = {
    'A_M_M_RANCHERTRAVELERS_WARM_01',
    'A_M_M_VALTOWNFOLK_01',
    'A_M_M_STRTOWNFOLK_01',
    'A_M_M_BLWUPPERCLASS_01',
    'A_F_M_BLWUPPERCLASS_01',
    'A_M_M_RHDTOWNFOLK_01',
}

-- -1 = driver (left). 0 on these yourmaps cars is the front passenger.
Config.DriverSeat = -1

-- 'wander' = TASK_VEHICLE_DRIVE_WANDER
-- 'roam'   = TASK_VEHICLE_DRIVE_TO_DESTINATION to a random road node, re-picks on arrival
--            (city cars only pick nodes inside their city -> traffic stays in town)
Config.Driving = {
    mode = 'roam',
    speed = { min = 6.0, max = 9.0 }, -- m/s, random per car. R* wagons: 3-5
    -- Values below are the most common ones in Rockstar's decompiled scripts (script_rel)
    drivingStyle = 524419, -- wander (R* also uses 524295, 524311)
    -- roam. 524419 (33x in script_rel) = StopForCars|StopForPeds|StopAtLights|ChangeLanes
    -- +8 SteerAroundStationaryCars +32 SteerAroundObjects -> goes around a parked/blocking car
    drivingFlags = 524459,
    drivingParam = 6,
    stopRange = 5.0,
    straightLineDist = 7.0,
}

Config.Roam = {
    minDist = 120.0,
    maxDist = 400.0,
    arriveDist = 15.0,
    attempts = 10,
}

-- IS_VEHICLE_STUCK_TIMER_UP types 0-2 + (3 && stopped), same as rcm_creole1
-- + own stall check: AI braking for a blocker / failed route never trips the R* stuck timers
Config.Stuck = {
    timeMs = 5000,
    stallSpeed = 1.0, -- m/s; slower than this counts as stopped
    stallMs = 8000, -- stopped this long -> re-task with a new destination (re-path / turn around)
    -- from this retry on: TASK_VEHICLE_TEMP_ACTION reverse first, then a destination behind the car
    -- (deadlocks: traffic cars waiting on each other in alleys / junctions)
    reverseFromRetry = 2,
    reverseMs = 2500,
    reverseActions = { 13, 14 }, -- RAGE TEMPACT_REVERSE_LEFT / _RIGHT (3 = straight)
    maxRetries = 4, -- then removed if off the owner's screen and no player within Population.minPlayerDist
    clearDist = 25.0, -- retries only reset once the car got this far from where it got stuck (not on a reverse nudge)
    removeRetryMs = 10000, -- remove request refused / lost (ownership migration) -> ask again after this

    -- Server backstop (no owner logic involved): car that hasn't moved progressDist in a while is deleted
    progressDist = 15.0,
    noProgressMs = 120000, -- deleted if no player within Population.minPlayerDist
    forceRemoveMs = 300000, -- deleted anyway unless a player is within forceMinPlayerDist (in it / right next to it)
    forceMinPlayerDist = 8.0,
    -- Orphans: vehicles tagged dodiTraffic that the server no longer tracks
    orphanSweepMs = 30000,
    orphanGraceMs = 60000,
}

-- GET_CLOSEST_VEHICLE_NODE_WITH_HEADING: 0 main roads, 1 any road (includes alleys / backyards -> deadlocks)
Config.NodeType = 0

---------------------------------------------------------------------------
-- City population
---------------------------------------------------------------------------

Config.Population = {
    enabled = true,
    tickMs = 2000, -- server population tick
    maxTotal = 15, -- server-wide cap (driving cars, parked not counted)

    spawnPerTick = 1, -- per city per tick when topping up
    fillSpawnPerTick = 3, -- per city per tick while below fillBelow * target (player just arrived)
    fillBelow = 0.5,
    pendingTimeoutMs = 8000, -- spawn request without register -> counted as failed

    -- Spawn rules (checked against every player, not only the host)
    minPlayerDist = 45.0, -- never closer than this
    hiddenDist = 140.0, -- closer than this must be off-screen (host cam) / behind (other players)
    maxHostDist = 250.0, -- host only spawns near itself (collision / nodes are loaded)
    spacing = 25.0, -- min distance to other traffic cars
    attempts = 25, -- node tries per car
    collisionWaitMs = 2000,
    pedClearRadius = 4.0, -- no ped this close to the spawn spot
    keepModelsLoaded = true, -- keep car/driver models resident (no re-stream hitch per spawn)
    modelTimeoutMs = 15000,
    modelFailBench = 2, -- timeouts in a row before a model is benched
    modelBenchMs = 300000, -- benched models are skipped this long

    -- Cleanup (server)
    despawnDist = 300.0, -- no player within this -> delete
    outsideCityDespawnDist = 120.0, -- outside its city radius and no player within this -> delete

    -- Budget multiplier by in-game hour (from = inclusive, to = exclusive, wraps midnight)
    hourMultiplier = {
        { from = 6, to = 9, mult = 0.6 },
        { from = 9, to = 19, mult = 1.0 },
        { from = 19, to = 22, mult = 0.5 },
        { from = 22, to = 6, mult = 0.15 },
    },
    hourReportMs = 60000, -- clients report GetClockHours to the server

    -- Vanilla population inside active cities (per frame while the player is in the city)
    suppressVanilla = {
        enabled = true,
        vehicleDensity = 0.4, -- SET_VEHICLE_DENSITY_MULTIPLIER_THIS_FRAME
        randomVehicleDensity = 0.4,
        parkedVehicleDensity = 0.6,
    },
}

-- zone = TOWN name for GET_MAP_ZONE_AT_COORDS (exact town polygon). nil = circle only.
-- center/radius = coarse area (node sampling + server cleanup). activationRadius = player distance
-- that turns the city on. Centers/radius from dodi_taxi.
--
-- Optional per city:
--   models = { { 'union_pickup', 1 }, ... }   drivers = { 'A_M_M_...' }
--   speed = { min, max }                       mode = 'roam' | 'wander'
--   hourMultiplier = { ... }                   suppressVanilla = false | { ... }
--   spawnPoints = { vector4(...), ... }        -- curated street spots (tried before random nodes)
--   parked = { vector4(...) | { coords = vector4(...), model = 'bellano_six' }, ... }  (missing model -> random from models)
--   /trafficpoint prints a vector4 of where you stand (or your car) to paste here.
-- Rural towns keep more vanilla wagons (cars are still rare out there)
local SUPPRESS_SMALL_TOWN = {
    vehicleDensity = 0.8,
    randomVehicleDensity = 0.8,
    parkedVehicleDensity = 0.9,
}

Config.Cities = {
    saint_denis = {
        enabled = true,
        label = 'Saint Denis',
        zone = 'StDenis',
        center = vector3(2650.0, -1300.0, 49.0),
        radius = 650.0,
        activationRadius = 750.0,
        budget = 12,
        models = MODELS_SAINT_DENIS,
        drivers = DRIVERS_SAINT_DENIS,
        hourMultiplier = HOURS_BIG_CITY,
        speed = { min = 6.0, max = 8.5 },
        spawnPoints = {},
        parked = {},
    },
    valentine = {
        enabled = true,
        label = 'Valentine',
        zone = 'valentine',
        center = vector3(-306.0, 780.0, 118.0),
        radius = 350.0,
        activationRadius = 450.0,
        budget = 3,
        models = MODELS_FRONTIER,
        drivers = DRIVERS_VALENTINE,
        hourMultiplier = HOURS_SMALL_TOWN,
        suppressVanilla = SUPPRESS_SMALL_TOWN,
        speed = { min = 5.0, max = 7.0 },
        spawnPoints = {},
        parked = {},
    },
    rhodes = {
        enabled = true,
        label = 'Rhodes',
        zone = 'Rhodes',
        center = vector3(1300.0, -1300.0, 77.0),
        radius = 320.0,
        activationRadius = 420.0,
        budget = 3,
        models = MODELS_TOWN,
        drivers = DRIVERS_RHODES,
        hourMultiplier = HOURS_SMALL_TOWN,
        suppressVanilla = SUPPRESS_SMALL_TOWN,
        speed = { min = 5.0, max = 7.0 },
        spawnPoints = {},
        parked = {},
    },
    blackwater = {
        enabled = true,
        label = 'Blackwater',
        zone = 'Blackwater',
        center = vector3(-813.0, -1310.0, 43.0),
        radius = 400.0,
        activationRadius = 500.0,
        budget = 6,
        models = MODELS_BLACKWATER,
        drivers = DRIVERS_BLACKWATER,
        speed = { min = 5.5, max = 8.0 },
        spawnPoints = {},
        parked = {},
    },
    strawberry = {
        enabled = false,
        label = 'Strawberry',
        zone = 'Strawberry',
        center = vector3(-1790.0, -430.0, 158.0),
        radius = 280.0,
        activationRadius = 380.0,
        budget = 1,
        models = MODELS_FRONTIER,
        drivers = DRIVERS_FRONTIER,
        hourMultiplier = HOURS_SMALL_TOWN,
        suppressVanilla = SUPPRESS_SMALL_TOWN,
        speed = { min = 4.5, max = 6.5 },
        spawnPoints = {},
        parked = {},
    },
    annesburg = {
        enabled = false,
        label = 'Annesburg',
        zone = 'Annesburg',
        center = vector3(2935.0, 1340.0, 44.0),
        radius = 420.0,
        activationRadius = 520.0,
        budget = 2,
        models = MODELS_FRONTIER,
        drivers = DRIVERS_FRONTIER,
        hourMultiplier = HOURS_SMALL_TOWN,
        suppressVanilla = SUPPRESS_SMALL_TOWN,
        spawnPoints = {},
        parked = {},
    },
    armadillo = {
        enabled = false,
        label = 'Armadillo',
        zone = 'Armadillo',
        center = vector3(-3680.0, -2600.0, -13.0),
        radius = 350.0,
        activationRadius = 450.0,
        budget = 1,
        models = MODELS_FRONTIER,
        drivers = DRIVERS_FRONTIER,
        hourMultiplier = HOURS_SMALL_TOWN,
        suppressVanilla = SUPPRESS_SMALL_TOWN,
        spawnPoints = {},
        parked = {},
    },
}

---------------------------------------------------------------------------
-- Test commands (/trafficcar, /trafficfill)
---------------------------------------------------------------------------

Config.Test = {
    ahead = 45.0, -- /trafficcar: node search point in front of the player
    minPlayerDist = 12.0,
    fillMinDist = 60.0,
    fillMaxDist = 220.0,
    fillSpacing = 25.0,
    fillMax = 20,
}

---------------------------------------------------------------------------
-- Driver visuals (anim.lua)
---------------------------------------------------------------------------

-- Same clips the player uses in dodi_cars (Config.DriverSteer), streamed by dodi_cars (stream/anims).
-- Picked by the car's yaw rate instead of A/D. Played by the ped's network owner (syncs).
Config.DriverAnim = {
    enabled = true,
    disableAmbient = true, -- no smoking / head scratch / gesture idles on drivers (they fight the clip + IK)
    maxDist = 50.0, -- only animate drivers near the player
    clips = {
        drive = { dict = 'dodi_canims@sdrive_01', name = 'sdriv' },
        left = { dict = 'dodi_canims@sleft_01', name = 'sleft' },
        right = { dict = 'dodi_canims@sright_01', name = 'srght' },
    },
    -- 1 loop | 2 hold last frame | 16 upper body | 32 secondary (keeps the drive task alive)
    flagsDrive = 49,
    flagsSteer = 50,
    taskFilter = 'UpperbodyFixup_filter',
    blendIn = 8.0,
    blendOut = -8.0,
    steerYawRate = 12.0, -- deg/s of turning to switch to left/right clip
    steerReleaseYawRate = 6.0, -- back to drive clip below this
}

-- Hands on the wheel by IK, same as dodi_cars client/bar_ik.lua (wheel mode). Local on every client.
-- Per-car driverBarIk is read from dodi_cars/config.lua (by chassisModel); fallback = default.
Config.DriverIk = {
    enabled = true,
    maxDist = 25.0, -- per-frame cost, keep it tight
    maxCars = 3, -- only the N closest drivers that are on screen get hand IK
    maxReach = 0.85, -- m from shoulder; farther targets are skipped (no stretched / raised arms)
    readDodiCarsConfig = true,
    p7 = 8,
    blendMs = 180,
    steerGain = 1.2, -- wheel deg per yaw deg/s
    steerDegPerSec = 140.0,
    default = {
        wheel = {
            seatBone = 'seat_dside_f',
            left = { x = -0.226, y = 0.5795, z = 0.4142 },
            right = { x = 0.226, y = 0.5795, z = 0.4142 },
            center = { x = 0.0, y = 0.5855, z = 0.2942 },
            axis = { x = 0.0, y = -0.8285, z = 0.56 },
            maxDeg = 35.0,
        },
        forward = 0.03,
    },
}

-- Engine sound through dodi_cars (same NUI audio as player cars; needs car.audio in dodi_cars config)
Config.Audio = {
    enabled = true,
    throttleUpdateMs = 300,
    minDelta = 0.05, -- only sync throttle when it changes this much
}

---------------------------------------------------------------------------
-- Carjack: armed robbery of traffic cars / bikes (carjack.lua)
-- Aim a gun at the driver (or the car) -> stops, hands up -> G -> driver gets out and flees.
-- The vehicle leaves the population and becomes a dodi_cars car (dodi_cars:spawnShell, no owner),
-- so speedometer / fuel / trunk / chopshop all work. Statebag dodiStolen = true.
---------------------------------------------------------------------------

Config.Carjack = {
    enabled = true,
    -- E on the driver door without a gun (vanilla jack) also steals it: driver flees, police roll.
    -- false = enter keys blocked near traffic cars with a driver (noride.lua)
    allowPullOut = true,
    pullGuardDist = 4.0, -- player this close + NPC off the seat -> owner never warps the NPC back
    maxDist = 15.0, -- aim distance to start
    keepDist = 20.0, -- prompt / hold distance once started
    maxSpeed = 14.0, -- m/s; faster vehicles ignore you
    floorItChance = 0.2, -- driver panics and floors it instead of stopping
    floorItSpeedMult = 1.7,
    floorItMs = 20000, -- then back to normal traffic
    releaseMs = 8000, -- stop aiming this long -> driver drives off
    haltDist = 5.0, -- BRING_VEHICLE_TO_HALT distance (R* uses 5.0)
    promptKey = 0x760A9C6F, -- G
    promptCar = 'Get out of the car!',
    promptBike = 'Get off the bike!',
    leaveTimeoutMs = 5000, -- car driver still inside after this -> warped out
    warpSideX = -1.2, -- warp-out offset (left side of the vehicle)
    warpGiveUpMs = 3000, -- still seated after warping this long -> carjack released
    bikeRagdollMs = 1500, -- bike rider knocked to the ground (fallback when bikeDismount fails)
    bikeSinkTolerance = 0.5, -- bike dropped more than this (m) during the dismount -> put back on the road
    -- Bike rider gets off with the real horse dismount (the clips TASK_DISMOUNT_ANIMAL plays):
    -- get_off_start/in_seat_to_get_off -> get_off/get_off_to_run_<angle>. Both are in horse root
    -- space, so both share one origin = bike origin + offset (bike space). Seat lower than a saddle -> tune z.
    -- Calibrate next to any bike: /trafficdismount x y z heading [angle] [left|right]  (plays on you)
    bikeDismount = {
        enabled = true,
        startDict = 'veh_horseback@horse@standard@seat_rider@%s@exit@land@ped@saddle@male@from_idle@get_off_start',
        startClip = 'in_seat_to_get_off',
        offDict = 'veh_horseback@horse@standard@seat_rider@%s@exit@land@ped@saddle@male@from_idle@get_off',
        offClip = 'get_off_to_run_%d', -- angles -90 -45 0 45 90 (also get_off_to_walk_%d, get_out_to_stand_%d)
        side = 'auto', -- 'left' | 'right' | 'auto' = side away from the robber
        runAngle = nil, -- nil = run away from the robber, else fixed (-90..90)
        angleSign = 1.0, -- flip to -1.0 if he runs towards you
        maxAngle = 90,
        offset = { x = 0.0, y = 0.0, z = -0.45 },
        heading = 0.0, -- added to the bike heading
        flags = 0,
        blendIn = 1000.0, -- instant: rider is already in the seated pose (clone)
        chainBlend = 8.0, -- get_off_start -> get_off
        chainOverlapMs = 100,
        blendOut = -4.0,
    },
    stolenTip = 'Vehicle stolen. Get in and start it.',
}

-- No boarding traffic cars with an NPC driver (noride.lua). Carjack is the only way in.
Config.NoRide = {
    enabled = true,
    blockDist = 6.0, -- enter keys disabled this close to a traffic car with a live driver
    tip = "The driver won't let you in.",
    -- player inside anyway -> car halts, then TASK_LEAVE_VEHICLE, warp out after leaveTimeoutMs
    jackGraceMs = 2500, -- inside with the NPC still at the wheel this long (jack anim) before being put out
    exitSpeed = 1.0, -- m/s
    haltTimeoutMs = 4000,
    leaveTimeoutMs = 3000,
}

Config.CarjackPolice = {
    enabled = true,
    witnessRadius = 40.0, -- ambient peds this close count as witnesses
    chanceWithWitness = 0.7,
    chanceNoWitness = 0.15,
    alertOnFloorIt = true, -- failed attempt (driver floored it) also rolls
    cooldownMs = 30000, -- per robber
    blipMs = 90000,
    title = 'Vehicle theft',
}

Config.Blips = false -- debug blip on every traffic car
Config.BlipSprite = 'blip_ambient_coach'
