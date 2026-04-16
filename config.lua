Config = {}

Config.Debug = true
Config.GiveItem = true

Config.LogPrefix = '[vms_cityhall_wasabi_bridge]'
Config.VersionTag = '4.0.0'

Config.DefaultLocation = 'Unbekannt'
Config.FallbackOfficerName = 'Unbekannter Officer'
Config.FallbackTargetName = 'Unbekannt'

Config.AllowedBillTypes = {
    ticket = true,
    ['traffic-ticket'] = true,
    invoice = true,
    receipt = true
}

-- Business decision defaults:
-- ticket + traffic-ticket => sync by default
-- invoice + receipt => do not sync by default
Config.SyncToMDTByType = {
    ['ticket'] = true,
    ['traffic-ticket'] = true,
    ['invoice'] = false,
    ['receipt'] = false
}

Config.AllowedCategories = {
    'felony',
    'misdemeanor',
    'infraction'
}

Config.AllowedCategoriesMap = {
    felony = true,
    misdemeanor = true,
    infraction = true
}

Config.CategoryAliases = {
    ['traffic-ticket'] = 'infraction',
    traffic_ticket = 'infraction',
    traffic = 'infraction',
    infraction = 'infraction',
    ordinance = 'infraction',
    contravention = 'infraction',

    ticket = 'misdemeanor',
    bill = 'misdemeanor',
    invoice = 'misdemeanor',
    fine = 'misdemeanor',
    charge = 'misdemeanor',
    offense = 'misdemeanor',
    offence = 'misdemeanor',
    misdemeanor = 'misdemeanor',

    felony = 'felony',
    crime = 'felony',
    criminal = 'felony',
    major = 'felony',
    serious = 'felony',
    violent = 'felony'
}

Config.DefaultCategory = 'misdemeanor'

Config.DefaultCategoryByType = {
    ['traffic-ticket'] = 'infraction',
    ['ticket'] = 'misdemeanor',
    ['invoice'] = 'misdemeanor',
    ['receipt'] = 'misdemeanor'
}

Config.DefaultJailTimeByCategory = {
    infraction = 0,
    misdemeanor = 0,
    felony = 0
}

Config.DefaultJailTimeByType = {
    ['traffic-ticket'] = 0,
    ['ticket'] = 0,
    ['invoice'] = 0,
    ['receipt'] = 0
}

Config.SyncStatuses = {
    pending_bill = 'pending_bill',
    bill_created = 'bill_created',
    sync_pending = 'sync_pending',
    synced = 'synced',
    sync_failed = 'sync_failed',
    skipped = 'skipped',
    duplicate_blocked = 'duplicate_blocked'
}

Config.MaxSyncAttempts = 10
Config.AutoResyncOnStart = false
Config.AutoResyncDelayMs = 5000

-- Restrict command access quickly; keep nil for open access.
-- Example: 'group.admin' or function(src) return IsPlayerAceAllowed(src, 'bridge.admin') end
Config.CommandPermission = nil
