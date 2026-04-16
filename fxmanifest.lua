fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'vms_cityhall_wasabi_bridge'
author 'OpenAI'
description 'Production-ready bridge between vms_cityhall tickets and wasabi_mdt charges'
version '4.0.0'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config.lua',
    'server.lua'
}

dependencies {
    'oxmysql',
    'es_extended',
    'vms_cityhall',
    'wasabi_bridge',
    'wasabi_mdt'
}
