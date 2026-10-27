# dodi_car_traffic

Free NPC traffic add-on for **dodi_cars**. NPC drivers cruise around the towns, park along the streets, and can be carjacked.

## Requirements

- **dodi_cars** + **dodi_cars_vehicles**
- **dodi_notifys** (the same notifications dodi_cars uses)

## Optional

- **yourmaps_native_cars** / **yourmaps_vintage_motorbikes** (YourMAPS packs). When they are running, their cars and bikes join the traffic automatically.
  - Without them, traffic uses the two dodi_cars_vehicles cars (Union Pickup and Union Sedan).
  - Models that are not streamed on the server are skipped, so nothing needs to change in the config.

## Install

```cfg
ensure dodi_cars_vehicles
ensure dodi_cars
# ensure yourmaps_native_cars        (optional)
# ensure yourmaps_vintage_motorbikes (optional)
ensure dodi_car_traffic
```

Start it after dodi_cars. It reads `dodi_cars/config.lua` to turn traffic cars into dodi cars (fuel, speedometer, engine audio, driver anims) once they are stolen.

## Features

- **Per-town population:** model mix, drivers, speed and opening hours per town. Small towns go quiet at night, while Saint Denis never fully sleeps.
- **Parked cars** at fixed spots.
- **Carjack:** aim at a driver to make them stop and get out. Some panic and floor it instead. Bike riders get off with a dismount animation.
  - After a carjack the vehicle becomes an unowned dodi_cars car.
- **No riding along:** players can't get in while an NPC is at the wheel; the carjack is the only way in.
- **Police alert:** on carjack, with a witness chance. This only works with `dodi_police` running; without it, the alert is skipped.

## Admin commands

These require the `command` ace (`group.admin` on RSG by default).

| Command | What it does |
|---|---|
| `/trafficcar [model]` | Spawns a traffic car in front of you |
| `/trafficfill [n]` | Spawns n traffic cars around you |
| `/trafficclear` | Removes all traffic; the population refills it unless paused |
| `/trafficpause` | Pauses or resumes the population |
| `/trafficstatus` | Shows per-town counts |

`Config.DevCommands = true` turns on the client tuning commands:
- `/trafficpoint` prints a `vector4` for spawn and parked spots.
- `/trafficdebug`, `/trafficmode`, `/trafficstyle`, `/trafficwhy`, `/trafficinspect`, `/trafficanimflags`, `/trafficdismount` are for debugging and tuning.

Every player can use these, so keep it off on a live server.

## Config

Everything lives in `config.lua`:
- `Config.DefaultModels`, `Config.Cities` (models, drivers, spawn points, parked spots, hours), `Config.ModelOverrides`
- `Config.Carjack`, `Config.NoRide`, `Config.CarjackPolice` (texts included)
- `Config.Blips` (debug blip on every traffic car)
