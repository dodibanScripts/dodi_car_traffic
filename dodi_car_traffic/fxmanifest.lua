fx_version "adamant"
games {"rdr3"}
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

description 'dodi_car_traffic - NPC driven traffic for dodi_cars'
version '1.0.0'

shared_script 'config.lua'

client_scripts {
    'client.lua',
    'anim.lua',
    'carjack.lua',
    'noride.lua',
}

server_script 'server.lua'

-- Optional: yourmaps_native_cars / yourmaps_vintage_motorbikes add more models.
-- Without them, only the dodi_cars_vehicles cars (union_pickup, union_sedan) spawn.
