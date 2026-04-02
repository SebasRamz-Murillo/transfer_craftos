-- ============================================================
--  transfer_restock.lua  v1.0
--  Auto-restock / min-max stock management module
-- ============================================================

local lib = require("transfer_lib")

local restock = {}

restock.RESTOCK_FILE = "transfer_restock.dat"

-- Initialise state
lib.state.restocks = lib.state.restocks or {}

-- ============================================================
--  Persistence
-- ============================================================

function restock.save()
    lib.safeWrite(restock.RESTOCK_FILE, lib.state.restocks)
end

function restock.load()
    if fs.exists(restock.RESTOCK_FILE) then
        local f = fs.open(restock.RESTOCK_FILE, "r")
        if f then
            local d = textutils.unserialise(f.readAll())
            f.close()
            if d then lib.state.restocks = d end
        end
    end
end

-- ============================================================
--  CRUD
-- ============================================================

--- Create a new restock rule.
-- @param opts table with fields:
--   inventory (string)  target inventory peripheral name to maintain stock in
--   item      (string)  item ID or glob pattern (e.g. "minecraft:iron_ingot" or "*ingot*")
--   minStock  (number)  pull when count drops below this
--   maxStock  (number)  stop pulling when count reaches this
--   sources   (table|nil)  list of source inventory names, empty/nil = search all
--   enabled   (bool, optional, default true)
-- @return index of the new restock rule
function restock.create(opts)
    local rule = {
        inventory = opts.inventory,
        item      = opts.item,
        minStock  = tonumber(opts.minStock) or 0,
        maxStock  = tonumber(opts.maxStock) or 0,
        sources   = opts.sources or {},
        enabled   = opts.enabled == nil and true or opts.enabled,
        status    = "idle",
        lastPulled = 0,
    }
    table.insert(lib.state.restocks, rule)
    restock.save()
    lib.tLog("[RESTOCK] Created: " .. lib.shortName(rule.item)
        .. " min=" .. rule.minStock .. " max=" .. rule.maxStock
        .. " in " .. lib.shortName(rule.inventory))
    return #lib.state.restocks
end

function restock.delete(index)
    local rule = lib.state.restocks[index]
    if not rule then return false end
    table.remove(lib.state.restocks, index)
    restock.save()
    lib.tLog("[RESTOCK] Deleted rule #" .. index)
    return true
end

function restock.toggle(index)
    local rule = lib.state.restocks[index]
    if not rule then return false end
    rule.enabled = not rule.enabled
    if not rule.enabled then
        rule.status = "idle"
        rule.lastPulled = 0
    end
    restock.save()
    lib.tLog("[RESTOCK] " .. (rule.enabled and "Enabled" or "Disabled") .. " rule #" .. index)
    return true
end

-- ============================================================
--  Check logic
-- ============================================================

function restock.check()
    for i, rule in ipairs(lib.state.restocks) do
        if rule.enabled then
            rule.lastPulled = 0

            -- Wrap target inventory
            local ok, targetInv = pcall(peripheral.wrap, rule.inventory)
            if not ok or not targetInv or not targetInv.list then
                rule.status = "error"
            else
                local okList, raw = pcall(targetInv.list)
                if not okList or not raw then
                    rule.status = "error"
                else
                    -- Count matching items in target
                    local count = 0
                    local usePattern = lib.isPattern(rule.item)
                    for _, item in pairs(raw) do
                        if usePattern then
                            if lib.matchesPattern(item.name, rule.item) then
                                count = count + item.count
                            end
                        else
                            if item.name == rule.item then
                                count = count + item.count
                            end
                        end
                    end

                    if count >= rule.minStock then
                        rule.status = "satisfied"
                    else
                        -- Need to pull items: target is maxStock - count
                        local needed = rule.maxStock - count
                        local totalPulled = 0

                        -- Build source list
                        local sources = {}
                        if rule.sources and #rule.sources > 0 then
                            for _, srcName in ipairs(rule.sources) do
                                local okS, srcP = pcall(peripheral.wrap, srcName)
                                if okS and srcP and srcP.list and srcP.pushItems then
                                    table.insert(sources, { name = srcName, peripheral = srcP })
                                end
                            end
                        else
                            -- Use all known inventories except target
                            for _, inv in ipairs(lib.state.inventories) do
                                if inv.name ~= rule.inventory then
                                    table.insert(sources, inv)
                                end
                            end
                        end

                        -- Pull from each source
                        for _, src in ipairs(sources) do
                            if needed <= 0 then break end
                            local okSrc, srcItems = pcall(src.peripheral.list)
                            if okSrc and srcItems then
                                for slot, item in pairs(srcItems) do
                                    if needed <= 0 then break end
                                    local match = false
                                    if usePattern then
                                        match = lib.matchesPattern(item.name, rule.item)
                                    else
                                        match = item.name == rule.item
                                    end
                                    if match then
                                        local qty = math.min(item.count, needed)
                                        local okM, r = pcall(src.peripheral.pushItems, rule.inventory, slot, qty)
                                        local moved = (okM and r) and r or 0
                                        if moved > 0 then
                                            totalPulled = totalPulled + moved
                                            needed = needed - moved
                                            lib.recordMovement(item.name, moved)
                                        end
                                    end
                                end
                            end
                        end

                        rule.lastPulled = totalPulled
                        if totalPulled > 0 then
                            rule.status = "pulling"
                            lib.tLog("[RESTOCK] Pulled " .. totalPulled .. "x "
                                .. lib.shortName(rule.item) .. " into "
                                .. lib.shortName(rule.inventory))
                            -- Check if we reached minStock after pulling
                            if count + totalPulled >= rule.minStock then
                                rule.status = "satisfied"
                            end
                        else
                            -- Could not pull anything, still below min
                            rule.status = "idle"
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

function restock.count()
    return #lib.state.restocks
end

function restock.countActive()
    local n = 0
    for _, rule in ipairs(lib.state.restocks) do
        if rule.enabled then n = n + 1 end
    end
    return n
end

function restock.countPulling()
    local n = 0
    for _, rule in ipairs(lib.state.restocks) do
        if rule.status == "pulling" or rule.lastPulled > 0 then
            n = n + 1
        end
    end
    return n
end

-- ============================================================
--  Background loop
-- ============================================================

function restock.loop()
    while lib.state.running do
        sleep(10)
        restock.check()
    end
end

return restock
