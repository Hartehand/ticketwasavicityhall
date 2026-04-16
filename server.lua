local ESX = exports['es_extended']:getSharedObject()

local RESOURCE_NAME = GetCurrentResourceName()
local activeFineSyncs = {}

local function getConfigValue(key, fallback)
    if Config and Config[key] ~= nil then
        return Config[key]
    end
    return fallback
end

local function safeString(value, fallback)
    if value == nil then
        return fallback
    end

    local t = type(value)
    if t == 'string' then
        if value == '' then
            return fallback
        end
        return value
    end

    if t == 'number' or t == 'boolean' then
        return tostring(value)
    end

    return fallback
end

local function safeNumber(value, fallback)
    local n = tonumber(value)
    if n == nil then
        return fallback
    end
    return n
end

local function jsonEncode(value)
    local ok, encoded = pcall(json.encode, value)
    if not ok then
        return '{}'
    end
    return encoded
end

local function jsonDecode(value)
    if type(value) ~= 'string' or value == '' then
        return nil
    end

    local ok, decoded = pcall(json.decode, value)
    if not ok then
        return nil
    end

    return decoded
end

local function log(level, msg, ...)
    local prefix = getConfigValue('LogPrefix', '[vms_cityhall_wasabi_bridge]')
    local formatted = msg
    if select('#', ...) > 0 then
        formatted = string.format(msg, ...)
    end
    print(('%s [%s] %s'):format(prefix, level, formatted))
end

local function debugLog(msg, ...)
    if getConfigValue('Debug', false) then
        log('DEBUG', msg, ...)
    end
end

local function getXPlayer(src)
    if not src then
        return nil
    end

    local ok, xPlayer = pcall(ESX.GetPlayerFromId, src)
    if not ok then
        return nil
    end

    return xPlayer
end

local function getCharacterFullName(src)
    local xPlayer = getXPlayer(src)
    if not xPlayer then
        return nil
    end

    if xPlayer.getName then
        local ok, name = pcall(xPlayer.getName, xPlayer)
        if ok and name and name ~= '' then
            return name
        end
    end

    local firstName = xPlayer.get and xPlayer.get('firstName') or xPlayer.firstName
    local lastName = xPlayer.get and xPlayer.get('lastName') or xPlayer.lastName
    local fullName = (safeString(firstName, '') .. ' ' .. safeString(lastName, '')):gsub('^%s+', ''):gsub('%s+$', '')

    if fullName ~= '' then
        return fullName
    end

    return GetPlayerName(src)
end

local function getPlayerIdentifier(src)
    if not src then
        return nil
    end

    local identifiers = GetPlayerIdentifiers(src) or {}
    for _, identifier in ipairs(identifiers) do
        if identifier:match('^char%d+:') then
            return identifier
        end
    end

    local xPlayer = getXPlayer(src)
    if xPlayer then
        if type(xPlayer.identifier) == 'string' and xPlayer.identifier:match('^char%d+:') then
            return xPlayer.identifier
        end

        if xPlayer.getIdentifier then
            local ok, xIdentifier = pcall(xPlayer.getIdentifier, xPlayer)
            if ok and type(xIdentifier) == 'string' and xIdentifier:match('^char%d+:') then
                return xIdentifier
            end
        end

        if type(xPlayer.identifier) == 'string' and xPlayer.identifier ~= '' then
            return xPlayer.identifier
        end
    end

    for _, identifier in ipairs(identifiers) do
        if identifier:match('^license:') then
            return identifier
        end
    end

    return nil
end

local function normalizeChargeCategory(category)
    local allowedMap = getConfigValue('AllowedCategoriesMap', {})
    local aliases = getConfigValue('CategoryAliases', {})
    local defaultCategory = getConfigValue('DefaultCategory', 'misdemeanor')

    local clean = safeString(category, ''):lower():gsub('%s+', '-')
    if clean ~= '' and aliases[clean] then
        clean = aliases[clean]
    end

    if clean ~= '' and allowedMap[clean] then
        return clean
    end

    return defaultCategory
end

local function getChargeCategory(billType, billData, options)
    options = options or {}
    billData = billData or {}

    local explicitCategory = options.category or options.chargeCategory or billData.category
    if explicitCategory then
        return normalizeChargeCategory(explicitCategory)
    end

    local typeDefaults = getConfigValue('DefaultCategoryByType', {})
    if typeDefaults[billType] then
        return normalizeChargeCategory(typeDefaults[billType])
    end

    return normalizeChargeCategory(getConfigValue('DefaultCategory', 'misdemeanor'))
end

local function getJailTimeForCharge(category, billType, billData, options)
    options = options or {}
    billData = billData or {}

    local explicit = safeNumber(options.jail_time or options.jailTime or billData.jail_time or billData.jailTime, nil)
    if explicit ~= nil then
        return math.max(0, explicit)
    end

    local byType = getConfigValue('DefaultJailTimeByType', {})
    local byCategory = getConfigValue('DefaultJailTimeByCategory', {})

    if byType[billType] ~= nil then
        return math.max(0, safeNumber(byType[billType], 0))
    end

    return math.max(0, safeNumber(byCategory[category], 0))
end

local function shouldSyncBillTypeToMDT(billType)
    local map = getConfigValue('SyncToMDTByType', {})
    return map[billType] == true
end

local function hasCommandPermission(src)
    local permission = getConfigValue('CommandPermission', nil)
    if src == 0 or permission == nil then
        return true
    end

    if type(permission) == 'string' then
        return IsPlayerAceAllowed(src, permission)
    end

    if type(permission) == 'function' then
        local ok, result = pcall(permission, src)
        return ok and result == true
    end

    return false
end

local function validateBillRequest(officerSrc, targetSrc, billType, billData, options)
    options = options or {}

    local allowedBillTypes = getConfigValue('AllowedBillTypes', {})

    if type(officerSrc) ~= 'number' then
        return false, 'officerSrc must be a number'
    end

    if type(targetSrc) ~= 'number' then
        return false, 'targetSrc must be a number'
    end

    if GetPlayerName(targetSrc) == nil then
        return false, ('targetSrc %s is not online'):format(targetSrc)
    end

    if type(billType) ~= 'string' or billType == '' then
        return false, 'billType must be a non-empty string'
    end

    if not allowedBillTypes[billType] then
        return false, ('unsupported billType: %s'):format(billType)
    end

    if type(billData) ~= 'table' then
        return false, 'billData must be a table'
    end

    if billType ~= 'invoice' and billType ~= 'receipt' then
        local amount = safeNumber(billData.amount, nil)
        if amount == nil or amount < 0 then
            return false, 'billData.amount must be a non-negative number for ticket/traffic-ticket'
        end
    end

    return true
end

local function normalizeBillPayload(billType, billData, options)
    options = options or {}
    billData = billData or {}

    local payload = {}
    for k, v in pairs(billData) do
        payload[k] = v
    end

    if payload.locationOfViolation == nil then
        payload.locationOfViolation = getConfigValue('DefaultLocation', 'Unbekannt')
    end

    if payload.comments == nil and type(options.comments) == 'string' then
        payload.comments = options.comments
    end

    if payload.issuerName == nil then
        payload.issuerName = safeString(getCharacterFullName(options.officerSrc), getConfigValue('FallbackOfficerName', 'Unbekannter Officer'))
    end

    if billType == 'invoice' and type(payload.invoiceData) ~= 'table' then
        payload.invoiceData = {}
    elseif billType == 'receipt' and type(payload.receiptData) ~= 'table' then
        payload.receiptData = {}
    end

    return payload
end

local function buildChargeTitle(fineId, billType, billData, category)
    local prefix
    if billType == 'traffic-ticket' then
        prefix = 'Traffic Ticket'
    elseif category == 'felony' then
        prefix = 'Felony Charge'
    elseif category == 'infraction' then
        prefix = 'Infraction Charge'
    else
        prefix = 'Ticket'
    end

    local violation = safeString(billData.violation, nil)
    if violation then
        return ('%s #%s - %s'):format(prefix, fineId, violation)
    end

    return ('%s #%s'):format(prefix, fineId)
end

local function buildChargeDescription(ctx)
    local lines = {
        'CITYHALL ENTRY',
        ('Fine ID: %s'):format(safeString(ctx.fineId, 'unknown')),
        ('Type: %s'):format(safeString(ctx.billType, 'unknown')),
        ('Category: %s'):format(safeString(ctx.category, 'unknown')),
        '',
        'PARTIES',
        ('Recipient: %s'):format(safeString(ctx.targetName, 'unknown')),
        ('Recipient-ID: %s'):format(safeString(ctx.targetIdentifier, 'unknown')),
        ('Issued by: %s'):format(safeString(ctx.officerName, 'unknown')),
        ('Officer-ID: %s'):format(safeString(ctx.officerIdentifier, 'unknown'))
    }

    local amount = safeNumber(ctx.billData.amount, nil)
    if amount ~= nil then
        lines[#lines + 1] = ('Amount: %s'):format(amount)
    end

    if ctx.billData.locationOfViolation then
        lines[#lines + 1] = ('Location: %s'):format(safeString(ctx.billData.locationOfViolation, getConfigValue('DefaultLocation', 'Unbekannt')))
    end

    if ctx.billData.violation then
        lines[#lines + 1] = ('Violation: %s'):format(safeString(ctx.billData.violation, 'n/a'))
    end

    if ctx.billData.comments then
        lines[#lines + 1] = ('Comments: %s'):format(safeString(ctx.billData.comments, 'n/a'))
    end

    local vehicle = ctx.billData.vehicle
    if type(vehicle) == 'table' then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'VEHICLE'
        lines[#lines + 1] = ('Plate: %s'):format(safeString(vehicle.plate, 'n/a'))
        lines[#lines + 1] = ('Make: %s'):format(safeString(vehicle.make, 'n/a'))
        lines[#lines + 1] = ('Model: %s'):format(safeString(vehicle.model, 'n/a'))
        lines[#lines + 1] = ('VIN: %s'):format(safeString(vehicle.vin, 'n/a'))
    end

    return table.concat(lines, '\n')
end

local function buildChargeMetadata(ctx)
    local metadata = {
        bridge_resource = RESOURCE_NAME,
        bridge_version = getConfigValue('VersionTag', 'unknown'),
        vms_fine_id = safeString(ctx.fineId, ''),
        vms_bill_type = safeString(ctx.billType, ''),
        locationOfViolation = safeString(ctx.billData.locationOfViolation, nil),
        comments = safeString(ctx.billData.comments, nil),
        violation = safeString(ctx.billData.violation, nil),
        amount = safeNumber(ctx.billData.amount, nil),
        target_identifier = safeString(ctx.targetIdentifier, nil)
    }

    if type(ctx.billData.vehicle) == 'table' then
        metadata.vehicle = {
            plate = safeString(ctx.billData.vehicle.plate, nil),
            make = safeString(ctx.billData.vehicle.make, nil),
            model = safeString(ctx.billData.vehicle.model, nil),
            vin = safeString(ctx.billData.vehicle.vin, nil)
        }
    end

    local license = safeString(ctx.billData.license, nil)
    if license then
        metadata.license = license
    end

    metadata.licenseRevocation = ctx.billData.licenseRevocation == true
    metadata.licenseSuspensionTime = safeNumber(ctx.billData.licenseSuspensionTime, nil)
    metadata.penaltyPointsCount = safeNumber(ctx.billData.penaltyPointsCount, nil)

    return metadata
end

local function buildChargePayload(ctx)
    local payload = {
        title = buildChargeTitle(ctx.fineId, ctx.billType, ctx.billData, ctx.category),
        description = buildChargeDescription(ctx),
        jail_time = ctx.jailTime,
        fine = safeNumber(ctx.billData.amount, 0),
        category = ctx.category,
        metadata = buildChargeMetadata(ctx),
        created_by = safeString(ctx.officerIdentifier, nil),
        created_by_name = safeString(ctx.officerName, getConfigValue('FallbackOfficerName', 'Unbekannter Officer'))
    }

    if payload.created_by == nil then
        payload.created_by = safeString(ctx.targetIdentifier, 'unknown')
    end

    return payload
end

local function getSyncRecordByFineId(fineId)
    return MySQL.single.await('SELECT * FROM vms_cityhall_wasabi_bridge_sync WHERE fine_id = ? LIMIT 1', { tostring(fineId) })
end

local function markSyncStatus(fineId, status, chargeId, lastError)
    MySQL.update.await([[
        UPDATE vms_cityhall_wasabi_bridge_sync
        SET status = ?, charge_id = COALESCE(?, charge_id), last_error = ?
        WHERE fine_id = ?
    ]], { status, chargeId, lastError, tostring(fineId) })
end

local function incrementAttemptCounter(fineId)
    MySQL.update.await('UPDATE vms_cityhall_wasabi_bridge_sync SET attempts = attempts + 1 WHERE fine_id = ?', { tostring(fineId) })
end

local function insertOrUpdateSyncRecord(data)
    MySQL.insert.await([[
        INSERT INTO vms_cityhall_wasabi_bridge_sync (
            fine_id, charge_id, bill_type,
            officer_src, officer_identifier, officer_name,
            target_src, target_identifier, target_name,
            status, attempts, last_error,
            payload_json, charge_payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            bill_type = VALUES(bill_type),
            officer_src = VALUES(officer_src),
            officer_identifier = VALUES(officer_identifier),
            officer_name = VALUES(officer_name),
            target_src = VALUES(target_src),
            target_identifier = VALUES(target_identifier),
            target_name = VALUES(target_name),
            status = VALUES(status),
            last_error = VALUES(last_error),
            payload_json = VALUES(payload_json),
            charge_payload_json = VALUES(charge_payload_json)
    ]], {
        tostring(data.fineId),
        data.chargeId,
        data.billType,
        data.officerSrc,
        data.officerIdentifier,
        data.officerName,
        data.targetSrc,
        data.targetIdentifier,
        data.targetName,
        data.status,
        data.attempts or 0,
        data.lastError,
        data.payloadJson,
        data.chargePayloadJson
    })
end

local function createVMSBill(targetSrc, billType, billData, giveItem)
    local p = promise.new()

    exports['vms_cityhall']:giveBill(targetSrc, billType, billData, giveItem, function(fineId)
        p:resolve(fineId)
    end)

    local fineId = Citizen.Await(p)
    return fineId
end

local function createWasabiCharge(chargePayload)
    local ok, result = pcall(function()
        return exports['wasabi_mdt']:CreateCharge(chargePayload)
    end)

    if not ok then
        return nil, ('CreateCharge threw error: %s'):format(tostring(result))
    end

    if type(result) ~= 'table' then
        return nil, 'CreateCharge returned invalid result type'
    end

    local chargeId = safeNumber(result.id, nil)
    if not chargeId then
        return nil, 'CreateCharge result is missing numeric id'
    end

    return result
end

local function syncFineToMDT(syncData)
    local fineId = tostring(syncData.fineId)

    if activeFineSyncs[fineId] then
        return nil, 'fine currently being synced'
    end

    activeFineSyncs[fineId] = true

    local ok, resultOrError, maybeErr = pcall(function()
        local existing = getSyncRecordByFineId(fineId)
        if not existing then
            return nil, 'sync record does not exist'
        end

        if safeNumber(existing.charge_id, nil) then
            markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).duplicate_blocked or 'duplicate_blocked', existing.charge_id, nil)
            return {
                duplicate = true,
                chargeId = safeNumber(existing.charge_id, nil)
            }
        end

        local status = existing.status
        if status == (getConfigValue('SyncStatuses', {}).synced or 'synced') then
            return {
                duplicate = true,
                chargeId = safeNumber(existing.charge_id, nil)
            }
        end

        incrementAttemptCounter(fineId)
        markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).sync_pending or 'sync_pending', nil, nil)

        local wasabiResponse, createErr = createWasabiCharge(syncData.chargePayload)
        if not wasabiResponse then
            markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).sync_failed or 'sync_failed', nil, createErr)
            return nil, createErr
        end

        local chargeId = safeNumber(wasabiResponse.id, nil)
        markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).synced or 'synced', chargeId, nil)
        MySQL.update.await('UPDATE vms_cityhall_wasabi_bridge_sync SET charge_payload_json = ? WHERE fine_id = ?', {
            jsonEncode(syncData.chargePayload),
            fineId
        })

        return {
            chargeId = chargeId,
            title = syncData.chargePayload.title,
            category = syncData.chargePayload.category
        }
    end)

    activeFineSyncs[fineId] = nil

    if not ok then
        local message = ('syncFineToMDT runtime error for fineId=%s: %s'):format(fineId, tostring(resultOrError))
        log('ERROR', message)
        markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).sync_failed or 'sync_failed', nil, message)
        return nil, message
    end

    if not resultOrError then
        return nil, maybeErr
    end

    return resultOrError
end

local function giveBillAndSyncMDT(officerSrc, targetSrc, billType, billData, options, cb)
    options = options or {}

    local isValid, validationError = validateBillRequest(officerSrc, targetSrc, billType, billData, options)
    if not isValid then
        log('ERROR', 'Validation failed: %s', validationError)
        if cb then cb(false, validationError) end
        return false, validationError
    end

    local normalizedBillData = normalizeBillPayload(billType, billData, {
        officerSrc = officerSrc,
        comments = options.comments
    })

    local officerIdentifier = getPlayerIdentifier(officerSrc)
    local targetIdentifier = getPlayerIdentifier(targetSrc)
    local officerName = safeString(getCharacterFullName(officerSrc), getConfigValue('FallbackOfficerName', 'Unbekannter Officer'))
    local targetName = safeString(getCharacterFullName(targetSrc), getConfigValue('FallbackTargetName', 'Unbekannt'))

    local giveItem = options.giveItem
    if giveItem == nil then
        giveItem = getConfigValue('GiveItem', true)
    end

    local fineId = createVMSBill(targetSrc, billType, normalizedBillData, giveItem)
    if fineId == nil or tostring(fineId) == '' then
        local err = 'vms_cityhall giveBill callback returned nil/empty fineId'
        log('ERROR', err)
        if cb then cb(false, err) end
        return false, err
    end

    fineId = tostring(fineId)

    local payloadJson = jsonEncode({
        billType = billType,
        billData = normalizedBillData,
        options = options
    })

    insertOrUpdateSyncRecord({
        fineId = fineId,
        billType = billType,
        officerSrc = officerSrc,
        officerIdentifier = officerIdentifier,
        officerName = officerName,
        targetSrc = targetSrc,
        targetIdentifier = targetIdentifier,
        targetName = targetName,
        status = getConfigValue('SyncStatuses', {}).bill_created or 'bill_created',
        attempts = 0,
        lastError = nil,
        payloadJson = payloadJson,
        chargePayloadJson = nil
    })

    if not shouldSyncBillTypeToMDT(billType) then
        markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).skipped or 'skipped', nil, 'sync disabled by config for bill type')
        local response = {
            fineId = fineId,
            skipped = true,
            reason = 'sync disabled by config for bill type'
        }
        if cb then cb(true, response) end
        return true, response
    end

    local category = getChargeCategory(billType, normalizedBillData, options)
    local jailTime = getJailTimeForCharge(category, billType, normalizedBillData, options)

    local context = {
        fineId = fineId,
        billType = billType,
        billData = normalizedBillData,
        category = category,
        jailTime = jailTime,
        officerIdentifier = officerIdentifier,
        officerName = officerName,
        targetIdentifier = targetIdentifier,
        targetName = targetName
    }

    local chargePayload = buildChargePayload(context)
    MySQL.update.await('UPDATE vms_cityhall_wasabi_bridge_sync SET charge_payload_json = ? WHERE fine_id = ?', {
        jsonEncode(chargePayload),
        fineId
    })

    local syncResult, syncErr = syncFineToMDT({
        fineId = fineId,
        chargePayload = chargePayload
    })

    if not syncResult then
        local err = ('VMS bill created but MDT sync failed for fineId=%s: %s'):format(fineId, tostring(syncErr))
        log('ERROR', err)
        if cb then cb(false, err, { fineId = fineId }) end
        return false, err
    end

    local response = {
        fineId = fineId,
        chargeId = syncResult.chargeId,
        title = chargePayload.title,
        category = category,
        duplicate = syncResult.duplicate == true
    }

    if cb then cb(true, response) end
    return true, response
end

local function resyncByFineId(fineId)
    local record = getSyncRecordByFineId(fineId)
    if not record then
        return false, ('fineId %s not found'):format(tostring(fineId))
    end

    if safeNumber(record.charge_id, nil) ~= nil then
        markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).duplicate_blocked or 'duplicate_blocked', record.charge_id, nil)
        return true, {
            fineId = tostring(fineId),
            chargeId = safeNumber(record.charge_id, nil),
            duplicate = true
        }
    end

    if not shouldSyncBillTypeToMDT(record.bill_type) then
        markSyncStatus(fineId, getConfigValue('SyncStatuses', {}).skipped or 'skipped', nil, 'sync disabled by config for bill type')
        return true, {
            fineId = tostring(fineId),
            skipped = true,
            reason = 'sync disabled by config for bill type'
        }
    end

    local chargePayload = jsonDecode(record.charge_payload_json)
    if type(chargePayload) ~= 'table' then
        local payload = jsonDecode(record.payload_json) or {}
        local billData = payload.billData or {}
        local options = payload.options or {}

        local category = getChargeCategory(record.bill_type, billData, options)
        local jailTime = getJailTimeForCharge(category, record.bill_type, billData, options)

        chargePayload = buildChargePayload({
            fineId = tostring(record.fine_id),
            billType = record.bill_type,
            billData = billData,
            category = category,
            jailTime = jailTime,
            officerIdentifier = record.officer_identifier,
            officerName = record.officer_name,
            targetIdentifier = record.target_identifier,
            targetName = record.target_name
        })

        MySQL.update.await('UPDATE vms_cityhall_wasabi_bridge_sync SET charge_payload_json = ? WHERE fine_id = ?', {
            jsonEncode(chargePayload),
            tostring(fineId)
        })
    end

    return syncFineToMDT({ fineId = tostring(fineId), chargePayload = chargePayload })
end

local function resyncFailedEntries(onlyFailed)
    local statuses = getConfigValue('SyncStatuses', {})
    local params = {}
    local query

    if onlyFailed then
        query = 'SELECT fine_id FROM vms_cityhall_wasabi_bridge_sync WHERE status = ? ORDER BY updated_at ASC LIMIT 200'
        params = { statuses.sync_failed or 'sync_failed' }
    else
        query = [[
            SELECT fine_id FROM vms_cityhall_wasabi_bridge_sync
            WHERE status IN (?, ?, ?, ?)
            ORDER BY updated_at ASC LIMIT 200
        ]]
        params = {
            statuses.sync_failed or 'sync_failed',
            statuses.bill_created or 'bill_created',
            statuses.sync_pending or 'sync_pending',
            statuses.pending_bill or 'pending_bill'
        }
    end

    local rows = MySQL.query.await(query, params) or {}
    local out = {
        total = #rows,
        success = 0,
        failed = 0
    }

    for _, row in ipairs(rows) do
        local ok = resyncByFineId(row.fine_id)
        if ok then
            out.success = out.success + 1
        else
            out.failed = out.failed + 1
        end
        Wait(50)
    end

    return out
end

local function getBridgeStats()
    local rows = MySQL.query.await('SELECT status, COUNT(*) AS count FROM vms_cityhall_wasabi_bridge_sync GROUP BY status ORDER BY status ASC') or {}
    local stats = {}
    for _, row in ipairs(rows) do
        stats[row.status] = safeNumber(row.count, 0)
    end
    return stats
end

exports('GiveBillAndSyncMDT', giveBillAndSyncMDT)

RegisterNetEvent('vms_cityhall_wasabi_bridge:GiveBillAndSyncMDT', function(targetSrc, billType, billData, options)
    local officerSrc = source
    giveBillAndSyncMDT(officerSrc, targetSrc, billType, billData, options)
end)

RegisterCommand('bridge_test_identifier', function(src)
    if not hasCommandPermission(src) then
        return
    end

    local identifier = getPlayerIdentifier(src)
    local name = getCharacterFullName(src)
    local msg = ('name=%s | identifier=%s'):format(safeString(name, 'unknown'), safeString(identifier, 'nil'))

    if src == 0 then
        print(msg)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { 'bridge', msg } })
    end
end, false)

RegisterCommand('mdtchargetest', function(src, args)
    if not hasCommandPermission(src) then
        return
    end

    local targetSrc = safeNumber(args[1], src)
    local category = normalizeChargeCategory(args[2] or 'misdemeanor')

    if not targetSrc or GetPlayerName(targetSrc) == nil then
        local msg = 'invalid player id for mdtchargetest'
        if src == 0 then print(msg) else TriggerClientEvent('chat:addMessage', src, { args = { 'bridge', msg } }) end
        return
    end

    local officerIdentifier = getPlayerIdentifier(src)
    local chargeData = {
        title = 'Bridge Charge Test',
        description = ('Direct bridge test charge at %s'):format(os.date('!%Y-%m-%d %H:%M:%S UTC')),
        jail_time = getJailTimeForCharge(category, 'ticket', {}, {}),
        fine = 1,
        category = category,
        metadata = {
            bridge_test = true,
            target_src = targetSrc,
            target_identifier = getPlayerIdentifier(targetSrc),
            bridge_version = getConfigValue('VersionTag', 'unknown')
        },
        created_by = officerIdentifier or getPlayerIdentifier(targetSrc) or 'unknown',
        created_by_name = safeString(getCharacterFullName(src), getConfigValue('FallbackOfficerName', 'Unbekannter Officer'))
    }

    local result, err = createWasabiCharge(chargeData)
    local msg
    if not result then
        msg = ('mdtchargetest failed: %s'):format(tostring(err))
        log('ERROR', msg)
    else
        msg = ('mdtchargetest success: charge id %s'):format(tostring(result.id))
        log('INFO', msg)
    end

    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { 'bridge', msg } })
    end
end, false)

RegisterCommand('bridge_status', function(src)
    if not hasCommandPermission(src) then
        return
    end

    local stats = getBridgeStats()
    local parts = {}
    for status, count in pairs(stats) do
        parts[#parts + 1] = ('%s=%s'):format(status, count)
    end
    table.sort(parts)

    local msg = 'bridge status: ' .. (#parts > 0 and table.concat(parts, ', ') or 'no entries')
    if src == 0 then
        print(msg)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { 'bridge', msg } })
    end
end, false)

RegisterCommand('bridge_lookup', function(src, args)
    if not hasCommandPermission(src) then
        return
    end

    local fineId = safeString(args[1], nil)
    if not fineId then
        local msg = 'usage: /bridge_lookup [fineId]'
        if src == 0 then print(msg) else TriggerClientEvent('chat:addMessage', src, { args = { 'bridge', msg } }) end
        return
    end

    local record = getSyncRecordByFineId(fineId)
    local msg
    if not record then
        msg = ('fineId=%s not found'):format(fineId)
    else
        msg = ('fineId=%s status=%s attempts=%s chargeId=%s lastError=%s'):format(
            fineId,
            safeString(record.status, 'unknown'),
            tostring(safeNumber(record.attempts, 0)),
            tostring(safeNumber(record.charge_id, 0)),
            safeString(record.last_error, 'none')
        )
    end

    if src == 0 then
        print(msg)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { 'bridge', msg } })
    end
end, false)

RegisterCommand('bridge_resync', function(src, args)
    if not hasCommandPermission(src) then
        return
    end

    local target = safeString(args[1], 'failed')
    local msg

    if target == 'all' then
        local result = resyncFailedEntries(false)
        msg = ('resync all pending/failed complete: total=%s success=%s failed=%s'):format(result.total, result.success, result.failed)
    elseif target == 'failed' then
        local result = resyncFailedEntries(true)
        msg = ('resync failed complete: total=%s success=%s failed=%s'):format(result.total, result.success, result.failed)
    else
        local ok, resultOrErr = resyncByFineId(target)
        if ok then
            msg = ('resync fineId=%s success (chargeId=%s skipped=%s duplicate=%s)'):format(
                target,
                tostring(resultOrErr.chargeId),
                tostring(resultOrErr.skipped == true),
                tostring(resultOrErr.duplicate == true)
            )
        else
            msg = ('resync fineId=%s failed: %s'):format(target, tostring(resultOrErr))
        end
    end

    if src == 0 then
        print(msg)
    else
        TriggerClientEvent('chat:addMessage', src, { args = { 'bridge', msg } })
    end
end, false)

CreateThread(function()
    Wait(1000)

    log('INFO', 'Loaded bridge version %s', safeString(getConfigValue('VersionTag', 'unknown'), 'unknown'))

    if getConfigValue('AutoResyncOnStart', false) then
        Wait(safeNumber(getConfigValue('AutoResyncDelayMs', 5000), 5000))
        local result = resyncFailedEntries(false)
        log('INFO', 'AutoResync complete: total=%s success=%s failed=%s', result.total, result.success, result.failed)
    else
        log('INFO', 'AutoResyncOnStart disabled; use /bridge_resync failed or /bridge_resync all')
    end
end)
