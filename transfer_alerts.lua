-- ============================================================
--  transfer_alerts.lua  v1.0
--  Stock alerts and redstone integration module
-- ============================================================

local lib = require("transfer_lib")

local alerts = {}

alerts.ALERTS_FILE = "transfer_alerts.dat"

-- Initialise state
lib.state.alerts = lib.state.alerts or {}

local VALID_SIDES = {
    top = true, bottom = true, left = true,
    right = true, front = true, back = true,
}

-- ============================================================
--  Pattern matching helper
-- ============================================================

local function matchesPattern(itemName, pattern)
    if not pattern:find("%*") then
        return itemName == pattern
    end
    -- Convert glob pattern to Lua pattern: escape magic chars, * -> .*
    local luaPat = "^"
        .. pattern:gsub("([%.%+%-%^%$%(%)%%])", "%%%1"):gsub("%*", ".*")
        .. "$"
    return itemName:match(luaPat) ~= nil
end

-- ============================================================
--  Persistence
-- ============================================================

function alerts.save()
    lib.safeWrite(alerts.ALERTS_FILE, lib.state.alerts)
end

function alerts.load()
    if fs.exists(alerts.ALERTS_FILE) then
        local f = fs.open(alerts.ALERTS_FILE, "r")
        if f then
            local d = textutils.unserialise(f.readAll())
            f.close()
            if d then lib.state.alerts = d end
        end
    end
end

-- ============================================================
--  CRUD
-- ============================================================

--- Create a new alert.
-- @param opts table with fields:
--   inventory    (string)  peripheral name
--   item         (string)  item ID or glob pattern (e.g. "minecraft:iron_ingot" or "minecraft:*_ore")
--   threshold    (number)  quantity threshold
--   below        (bool)    true = alert when count < threshold, false = when count > threshold
--   redstoneSide (string|nil) one of the valid CC sides, or nil for no redstone
--   enabled      (bool, optional, default true)
-- @return index of the new alert
function alerts.create(opts)
    local alert = {
        inventory    = opts.inventory,
        item         = opts.item,
        threshold    = tonumber(opts.threshold) or 0,
        below        = opts.below == nil and true or opts.below,
        redstoneSide = (opts.redstoneSide and VALID_SIDES[opts.redstoneSide]) and opts.redstoneSide or nil,
        enabled      = opts.enabled == nil and true or opts.enabled,
        triggered    = false,
    }
    table.insert(lib.state.alerts, alert)
    alerts.save()
    lib.tLog("[ALERT] Created: " .. lib.shortName(alert.item)
        .. (alert.below and " < " or " > ") .. alert.threshold
        .. " in " .. lib.shortName(alert.inventory))
    return #lib.state.alerts
end

function alerts.delete(index)
    local alert = lib.state.alerts[index]
    if not alert then return false end
    -- Clear redstone before removing
    if alert.redstoneSide and alert.triggered then
        redstone.setOutput(alert.redstoneSide, false)
    end
    table.remove(lib.state.alerts, index)
    alerts.save()
    lib.tLog("[ALERT] Deleted alert #" .. index)
    return true
end

function alerts.toggle(index)
    local alert = lib.state.alerts[index]
    if not alert then return false end
    alert.enabled = not alert.enabled
    -- If disabling a triggered alert, clear its redstone and triggered state
    if not alert.enabled and alert.triggered then
        alert.triggered = false
        if alert.redstoneSide then
            redstone.setOutput(alert.redstoneSide, false)
        end
    end
    alerts.save()
    lib.tLog("[ALERT] " .. (alert.enabled and "Enabled" or "Disabled") .. " alert #" .. index)
    return true
end

-- ============================================================
--  Check logic
-- ============================================================

function alerts.check()
    for i, alert in ipairs(lib.state.alerts) do
        if alert.enabled then
            local ok, inv = pcall(peripheral.wrap, alert.inventory)
            if ok and inv and inv.list then
                local okList, raw = pcall(inv.list)
                if okList and raw then
                    -- Sum matching item counts
                    local count = 0
                    local usePattern = alert.item:find("%*") ~= nil
                    for _, item in pairs(raw) do
                        if usePattern then
                            if matchesPattern(item.name, alert.item) then
                                count = count + item.count
                            end
                        else
                            if item.name == alert.item then
                                count = count + item.count
                            end
                        end
                    end

                    -- Evaluate condition
                    local conditionMet
                    if alert.below then
                        conditionMet = count < alert.threshold
                    else
                        conditionMet = count > alert.threshold
                    end

                    if conditionMet and not alert.triggered then
                        -- Trigger the alert
                        alert.triggered = true
                        lib.tLog("[ALERT] TRIGGERED #" .. i .. ": "
                            .. lib.shortName(alert.item) .. " = " .. count
                            .. (alert.below and " < " or " > ") .. alert.threshold
                            .. " in " .. lib.shortName(alert.inventory))
                        if alert.redstoneSide then
                            redstone.setOutput(alert.redstoneSide, true)
                        end
                    elseif not conditionMet and alert.triggered then
                        -- Clear the alert
                        alert.triggered = false
                        lib.tLog("[ALERT] Cleared #" .. i .. ": "
                            .. lib.shortName(alert.item) .. " = " .. count
                            .. " in " .. lib.shortName(alert.inventory))
                        if alert.redstoneSide then
                            redstone.setOutput(alert.redstoneSide, false)
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================
--  Queries
-- ============================================================

function alerts.getTriggered()
    local result = {}
    for i, alert in ipairs(lib.state.alerts) do
        if alert.triggered then
            table.insert(result, { index = i, alert = alert })
        end
    end
    return result
end

function alerts.count()
    return #lib.state.alerts
end

function alerts.countTriggered()
    local n = 0
    for _, alert in ipairs(lib.state.alerts) do
        if alert.triggered then n = n + 1 end
    end
    return n
end

-- ============================================================
--  Background loop
-- ============================================================

function alerts.loop()
    while lib.state.running do
        sleep(5)
        alerts.check()
    end
end

return alerts
