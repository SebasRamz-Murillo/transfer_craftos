-- ============================================================
--  transfer_lib.lua  v5.1
--  Capa de datos: estado, persistencia, inventarios, movimiento
-- ============================================================

local lib = {}

lib.RULES_FILE   = "transfer_rules.dat"
lib.TASKS_FILE   = "transfer_tasks.dat"
lib.HISTORY_FILE = "transfer_history.dat"
lib.LABELS_FILE  = "transfer_labels.dat"
lib.MAX_HISTORY  = 100
lib.MAX_QUANTITY = 99999

lib.MON_IDS = {
    control   = "monitor_14",
    tasks     = "monitor_10",
    browse    = "monitor_13",
    dashboard = "monitor_12",
    activity  = "monitor_11",
}

-- ============================================================
--  Estado global
-- ============================================================
lib.state = {
    running        = true,
    inventories    = {},
    rules          = {},
    tasks          = {},
    history        = {},
    rulesRunning   = true,
    startTime      = 0,
    totalMoved     = 0,
    totalTransfers = 0,
    totalErrors    = 0,
    workerActive   = false,
    workerFrom     = nil,
    workerTo       = nil,
    workerInterval = 5,
    workerStats    = {
        cycles = 0, totalMoved = 0, startTime = 0,
        lastItems = {}, destFull = false,
    },
    labels  = {},   -- { {monitor=str, inventory=str, color=num}, ... }
    aliases = {},   -- { [invName] = "friendly name", ... }
    stats = {
        movementLog = {},  -- { {time=os.clock(), item=str, count=N}, ... }
        itemCounts  = {},  -- { [itemName] = totalMoved }
    },
    favorites    = {},     -- { [invName] = true, ... }
    compactMode  = false,
    disconnected = {},     -- { [invName] = true, ... }
}

-- ============================================================
--  Terminal log
-- ============================================================
lib.termLog = {}
local MAX_TERM = 80

function lib.tLog(msg)
    local time = textutils.formatTime(os.time(), true)
    local line = "[" .. time .. "] " .. msg
    table.insert(lib.termLog, 1, line)
    if #lib.termLog > MAX_TERM then table.remove(lib.termLog) end
    os.queueEvent("log_update")
end

function lib.drawTerminal()
    term.clear()
    term.setCursorPos(1, 1)
    local tW, tH = term.getSize()
    term.setTextColor(colors.yellow)
    print("=== TRANSFER v5.1 Multi-Monitor ===")
    term.setTextColor(colors.gray)
    print("Inv:" .. #lib.state.inventories
        .. " Reglas:" .. #lib.state.rules
        .. " Tareas:" .. #lib.state.tasks
        .. " | Ctrl+T=salir")
    print(string.rep("-", tW))
    local maxLines = tH - 4
    for i = 1, math.min(#lib.termLog, maxLines) do
        term.setCursorPos(1, 3 + i)
        local l = lib.termLog[i]
        if l:find("ERROR") then term.setTextColor(colors.red)
        elseif l:find("AUTO") or l:find("TASK") then term.setTextColor(colors.cyan)
        elseif l:find("WORKER") then term.setTextColor(colors.yellow)
        elseif l:find("OK") or l:find("LISTO") then term.setTextColor(colors.lime)
        else term.setTextColor(colors.lightGray) end
        print(l:sub(1, tW))
    end
    term.setTextColor(colors.white)
end

-- ============================================================
--  Pattern matching (glob -> Lua pattern)
-- ============================================================

function lib.isPattern(str)
    return type(str) == "string" and str:find("%*") ~= nil and str ~= "*"
end

function lib.matchesPattern(itemName, pattern)
    -- Convert glob pattern to Lua pattern: escape magic chars, then * -> .-
    local luaPat = pattern:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
    luaPat = luaPat:gsub("%*", ".*")
    luaPat = "^" .. luaPat .. "$"
    return itemName:match(luaPat) ~= nil
end

-- ============================================================
--  Inventarios
-- ============================================================

function lib.refreshInventories()
    lib.state.inventories = {}
    for _, name in ipairs(peripheral.getNames()) do
        if not name:find("^monitor") and not name:find("^computer") then
            local ok, w = pcall(peripheral.wrap, name)
            if ok and w and w.list and w.pushItems then
                local size = 0
                pcall(function() size = w.size() end)
                table.insert(lib.state.inventories, {
                    name = name, size = size, peripheral = w,
                })
            end
        end
    end
    table.sort(lib.state.inventories, function(a, b)
        local aFav = lib.state.favorites[a.name] and true or false
        local bFav = lib.state.favorites[b.name] and true or false
        if aFav ~= bFav then return aFav end
        return a.name < b.name
    end)
end

function lib.getItems(inv)
    local ok, raw = pcall(inv.peripheral.list)
    if not ok or not raw then return {} end
    local grouped, order = {}, {}
    for slot, item in pairs(raw) do
        local key = item.name
        if not grouped[key] then
            grouped[key] = { name = item.name, total = 0, slots = {} }
            table.insert(order, key)
        end
        grouped[key].total = grouped[key].total + item.count
        table.insert(grouped[key].slots, { slot = slot, count = item.count })
    end
    local items = {}
    for _, key in ipairs(order) do table.insert(items, grouped[key]) end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

-- Cached inventory fill for dashboard (avoids repeated peripheral calls)
lib._fillCache = {}
lib._fillCacheTime = 0
lib.FILL_CACHE_TTL = 5  -- seconds

function lib.refreshFillCache()
    local now = os.clock()
    if now - lib._fillCacheTime < lib.FILL_CACHE_TTL then return end
    lib._fillCacheTime = now
    for _, inv in ipairs(lib.state.inventories) do
        local ok, raw = pcall(inv.peripheral.list)
        local used = 0
        if ok and raw then
            for _ in pairs(raw) do used = used + 1 end
        end
        lib._fillCache[inv.name] = { used = used, size = inv.size }
    end
end

function lib.getInventoryFill(inv)
    local cached = lib._fillCache[inv.name]
    if cached then return cached.used, cached.size end
    local ok, raw = pcall(inv.peripheral.list)
    if not ok or not raw then return 0, inv.size end
    local used = 0
    for _ in pairs(raw) do used = used + 1 end
    return used, inv.size
end

-- ============================================================
--  Movimiento
-- ============================================================

function lib.moveItems(fromPeripheral, toName, itemName, cantidad, usePattern)
    local ok, raw = pcall(fromPeripheral.list)
    if not ok or not raw then return 0 end
    local movido = 0
    for slot, item in pairs(raw) do
        local match = false
        if usePattern then
            match = lib.matchesPattern(item.name, itemName)
        else
            match = (item.name == itemName)
        end
        if match then
            local mover = math.min(item.count, cantidad - movido)
            local okM, r = pcall(fromPeripheral.pushItems, toName, slot, mover)
            if okM and r and r > 0 then movido = movido + r end
            if movido >= cantidad then break end
        end
    end
    return movido
end

function lib.moveAllItems(fromInv, toInv, onProgress)
    local ok, raw = pcall(fromInv.peripheral.list)
    if not ok or not raw then
        return { total = 0, totalOriginal = 0, slots = 0, totalSlots = 0, items = {}, destFull = false, fullItems = {} }
    end
    local totalSlots, totalItems = 0, 0
    local summary = {}
    for _, item in pairs(raw) do
        totalSlots = totalSlots + 1
        totalItems = totalItems + item.count
        if not summary[item.name] then summary[item.name] = { moved = 0, failed = 0 } end
    end
    -- Build ordered slot list to avoid next() inside pairs() issues
    local slotList = {}
    for slot, item in pairs(raw) do
        table.insert(slotList, { slot = slot, item = item })
    end

    local processed, movidoTotal = 0, 0
    local itemFull = {}    -- tracks items that can't fit (per-item, not whole inv)
    local destFull = false -- true only when ALL items fail (no space at all)
    local consecutiveFails = 0

    for _, entry in ipairs(slotList) do
        processed = processed + 1
        if onProgress then
            onProgress({
                processed = processed, total = totalSlots,
                moved = movidoTotal, totalItems = totalItems,
                current = entry.item.name, destFull = destFull,
                summary = summary, fullItems = itemFull,
            })
        end

        -- Skip items we already know can't fit
        if itemFull[entry.item.name] then
            summary[entry.item.name].failed = summary[entry.item.name].failed + entry.item.count
        else
            local okM, result = pcall(fromInv.peripheral.pushItems, toInv.name, entry.slot, entry.item.count)
            local moved = (okM and result) and result or 0
            summary[entry.item.name].moved = summary[entry.item.name].moved + moved
            movidoTotal = movidoTotal + moved

            if moved < entry.item.count then
                summary[entry.item.name].failed = summary[entry.item.name].failed + (entry.item.count - moved)
                if moved == 0 then
                    -- This specific item can't fit, but others might
                    itemFull[entry.item.name] = true
                    consecutiveFails = consecutiveFails + 1
                else
                    consecutiveFails = 0
                end
            else
                consecutiveFails = 0
            end

            -- If many consecutive items fail, the inv is probably truly full
            if consecutiveFails >= 5 then
                destFull = true
                -- Mark remaining items as failed
                for j = processed + 1, #slotList do
                    local rem = slotList[j]
                    summary[rem.item.name].failed = summary[rem.item.name].failed + rem.item.count
                end
                break
            end
        end
        sleep(0.05)
    end

    -- Build result list
    local itemList = {}
    local fullItemList = {}
    for name, data in pairs(summary) do
        table.insert(itemList, { name = name, moved = data.moved, failed = data.failed })
        if itemFull[name] then
            table.insert(fullItemList, lib.shortName(name))
        end
    end
    table.sort(itemList, function(a, b) return a.moved > b.moved end)
    return {
        total = movidoTotal, totalOriginal = totalItems,
        slots = processed, totalSlots = totalSlots,
        items = itemList, destFull = destFull,
        fullItems = fullItemList,
    }
end

-- ============================================================
--  Filtro
-- ============================================================

function lib.applyFilter(nav)
    if nav.searchText == "" then
        nav.filteredItems = nav.items
    else
        nav.filteredItems = {}
        local search = nav.searchText:lower()
        for _, item in ipairs(nav.items) do
            local sn = (item.name:match(":(.+)") or item.name):lower()
            if sn:find(search, 1, true) then table.insert(nav.filteredItems, item) end
        end
    end
    nav.page = 1
end

-- ============================================================
--  Historial
-- ============================================================

function lib.safeWrite(path, data)
    local f = fs.open(path, "w")
    if not f then
        lib.tLog("ERROR: No se pudo escribir " .. path)
        return false
    end
    f.write(textutils.serialise(data))
    f.close()
    return true
end

function lib.saveHistory()
    lib.safeWrite(lib.HISTORY_FILE, lib.state.history)
end

function lib.loadHistory()
    if fs.exists(lib.HISTORY_FILE) then
        local f = fs.open(lib.HISTORY_FILE, "r")
        local d = textutils.unserialise(f.readAll())
        f.close()
        if d then lib.state.history = d end
    end
end

function lib.addHistory(from, to, item, requested, moved)
    table.insert(lib.state.history, 1, {
        from = from, to = to, item = item,
        requested = requested, moved = moved,
        time = textutils.formatTime(os.time(), true), day = os.day(),
        undoable = true,
    })
    if #lib.state.history > lib.MAX_HISTORY then table.remove(lib.state.history) end
    lib.saveHistory()
    lib.state.totalTransfers = lib.state.totalTransfers + 1
    lib.state.totalMoved = lib.state.totalMoved + moved
    lib.recordMovement(item, moved)
end

-- ============================================================
--  Reglas
-- ============================================================

function lib.saveRules()
    lib.safeWrite(lib.RULES_FILE, lib.state.rules)
end

function lib.loadRules()
    if fs.exists(lib.RULES_FILE) then
        local f = fs.open(lib.RULES_FILE, "r")
        local d = textutils.unserialise(f.readAll())
        f.close()
        if d then lib.state.rules = d end
    end
end

function lib.executeRule(rule)
    local fromP = peripheral.wrap(rule.from)
    if not fromP or not fromP.list then return 0 end
    local total = 0
    if rule.item == "*" then
        local ok, items = pcall(fromP.list)
        if ok and items then
            for slot, item in pairs(items) do
                local qty = rule.cantidad == 0 and item.count or math.min(item.count, rule.cantidad - total)
                local okM, r = pcall(fromP.pushItems, rule.to, slot, qty)
                if okM and r then total = total + r end
                if rule.cantidad > 0 and total >= rule.cantidad then break end
            end
        end
    elseif lib.isPattern(rule.item) then
        -- Glob pattern matching (e.g. *ore*, *ingot*)
        local ok2, items = pcall(fromP.list)
        if ok2 and items then
            for slot, item in pairs(items) do
                if lib.matchesPattern(item.name, rule.item) then
                    local qty = rule.cantidad == 0 and item.count or math.min(item.count, rule.cantidad - total)
                    local okM, r = pcall(fromP.pushItems, rule.to, slot, qty)
                    if okM and r then total = total + r end
                    if rule.cantidad > 0 and total >= rule.cantidad then break end
                end
            end
        end
    else
        total = lib.moveItems(fromP, rule.to, rule.item, rule.cantidad == 0 and lib.MAX_QUANTITY or rule.cantidad)
    end
    return total
end

-- ============================================================
--  Agrupador: consolida items al inv con mayor cantidad
-- ============================================================

function lib.groupItems(onProgress)
    lib.refreshInventories()
    -- 1. Scan all inventories, build item map
    local itemMap = {}  -- itemName -> { {inv=inv, count=N, slots={{slot,count},...}}, ... }
    for _, inv in ipairs(lib.state.inventories) do
        local ok, raw = pcall(inv.peripheral.list)
        if ok and raw then
            for slot, item in pairs(raw) do
                if not itemMap[item.name] then itemMap[item.name] = {} end
                -- Find or create entry for this inv
                local found = nil
                for _, e in ipairs(itemMap[item.name]) do
                    if e.inv.name == inv.name then found = e; break end
                end
                if not found then
                    found = { inv = inv, count = 0, slots = {} }
                    table.insert(itemMap[item.name], found)
                end
                found.count = found.count + item.count
                table.insert(found.slots, { slot = slot, count = item.count })
            end
        end
    end

    -- 2. For each item, find the inv with the most and move from others
    local totalMoved = 0
    local itemsGrouped = 0
    local details = {}
    local totalItems = 0
    for _ in pairs(itemMap) do totalItems = totalItems + 1 end
    local processed = 0

    for itemName, entries in pairs(itemMap) do
        processed = processed + 1
        if #entries > 1 then
            -- Find max
            local maxEntry = entries[1]
            for _, e in ipairs(entries) do
                if e.count > maxEntry.count then maxEntry = e end
            end
            -- Move from all others to max
            local movedForItem = 0
            for _, e in ipairs(entries) do
                if e.inv.name ~= maxEntry.inv.name then
                    for _, s in ipairs(e.slots) do
                        local okM, r = pcall(e.inv.peripheral.pushItems, maxEntry.inv.name, s.slot, s.count)
                        local moved = (okM and r) and r or 0
                        movedForItem = movedForItem + moved
                        totalMoved = totalMoved + moved
                    end
                end
            end
            if movedForItem > 0 then
                itemsGrouped = itemsGrouped + 1
                local sn = itemName:match(":(.+)") or itemName
                table.insert(details, { name = sn, moved = movedForItem, dest = maxEntry.inv.name })
            end
        end
        if onProgress then
            onProgress({
                processed = processed, total = totalItems,
                moved = totalMoved, grouped = itemsGrouped,
                current = itemName,
            })
        end
        if processed % 5 == 0 then sleep(0.05) end
    end

    table.sort(details, function(a, b) return a.moved > b.moved end)
    lib.tLog("[GROUP] " .. itemsGrouped .. " items agrupados, " .. totalMoved .. " movidos")
    return {
        totalMoved = totalMoved,
        itemsGrouped = itemsGrouped,
        totalTypes = totalItems,
        details = details,
    }
end

-- ============================================================
--  Labels: monitores pintados vinculados a inventarios
-- ============================================================

function lib.saveLabels()
    local data = {
        labels      = lib.state.labels,
        aliases     = lib.state.aliases,
        favorites   = lib.state.favorites,
        compactMode = lib.state.compactMode,
    }
    lib.safeWrite(lib.LABELS_FILE, data)
end

function lib.loadLabels()
    if fs.exists(lib.LABELS_FILE) then
        local f = fs.open(lib.LABELS_FILE, "r")
        local d = textutils.unserialise(f.readAll())
        f.close()
        if d then
            lib.state.labels      = d.labels or {}
            lib.state.aliases     = d.aliases or {}
            lib.state.favorites   = d.favorites or {}
            lib.state.compactMode = d.compactMode or false
        end
    end
end

function lib.getExtraMonitors()
    local reserved = {}
    for _, id in pairs(lib.MON_IDS) do reserved[id] = true end
    local result = {}
    for _, name in ipairs(peripheral.getNames()) do
        if name:find("^monitor") and not reserved[name] then
            local ok, mon = pcall(peripheral.wrap, name)
            if ok and mon and mon.setBackgroundColor then
                table.insert(result, name)
            end
        end
    end
    table.sort(result)
    return result
end

-- Returns black for light backgrounds, white for dark
function lib.contrastFg(bg)
    if bg == colors.white or bg == colors.yellow or bg == colors.lime
       or bg == colors.lightGray or bg == colors.lightBlue or bg == colors.pink then
        return colors.black
    end
    return colors.white
end

function lib.paintMonitor(label)
    local mon = peripheral.wrap(label.monitor)
    if not mon then return false end
    local col = label.color or colors.blue
    mon.setTextScale(1.0)
    mon.setBackgroundColor(col)
    mon.clear()
    local w, h = mon.getSize()
    local fg = lib.contrastFg(col)
    -- Show inventory name/alias
    local invName = label.inventory or "?"
    local display = lib.getAlias(invName)
    if #display > w - 2 then display = display:sub(1, w - 4) .. ".." end
    mon.setTextColor(fg)
    mon.setCursorPos(math.max(1, math.floor((w - #display) / 2) + 1), math.floor(h / 2))
    mon.write(display)
    -- Show monitor id small at bottom
    local mid = label.monitor
    if #mid > w - 2 then mid = mid:sub(1, w - 4) .. ".." end
    mon.setCursorPos(1, h)
    mon.setTextColor(fg)
    mon.write(mid:sub(1, w))
    return true
end

function lib.paintAllLabels()
    for _, label in ipairs(lib.state.labels) do
        lib.paintMonitor(label)
    end
end

function lib.addLabel(monName, invName, col)
    -- Remove existing label for this monitor
    for i = #lib.state.labels, 1, -1 do
        if lib.state.labels[i].monitor == monName then
            table.remove(lib.state.labels, i)
        end
    end
    local label = { monitor = monName, inventory = invName, color = col }
    table.insert(lib.state.labels, label)
    lib.saveLabels()
    lib.paintMonitor(label)
    lib.tLog("[LABEL] " .. monName .. " -> " .. invName)
end

function lib.removeLabel(index)
    local label = lib.state.labels[index]
    if label then
        -- Clear monitor
        local mon = peripheral.wrap(label.monitor)
        if mon then
            mon.setBackgroundColor(colors.black)
            mon.clear()
        end
        table.remove(lib.state.labels, index)
        lib.saveLabels()
        lib.tLog("[LABEL] Removed " .. label.monitor)
    end
end

-- ============================================================
--  Aliases: nombres amigables para inventarios
-- ============================================================

function lib.shortName(invName)
    return invName:match(":(.+)") or invName
end

function lib.getAlias(invName)
    return lib.state.aliases[invName] or lib.shortName(invName)
end

function lib.setAlias(invName, alias)
    if alias and alias ~= "" then
        lib.state.aliases[invName] = alias
    else
        lib.state.aliases[invName] = nil
    end
    lib.saveLabels()
    -- Refresh any painted monitors that show this inventory
    for _, label in ipairs(lib.state.labels) do
        if label.inventory == invName then
            lib.paintMonitor(label)
        end
    end
end

-- ============================================================
--  Enhanced stats (ephemeral, RAM only)
-- ============================================================

function lib.recordMovement(itemName, count)
    if count <= 0 then return end
    table.insert(lib.state.stats.movementLog, {
        time = os.clock(), item = itemName, count = count,
    })
    lib.state.stats.itemCounts[itemName] = (lib.state.stats.itemCounts[itemName] or 0) + count
    -- Trim old entries (keep last 10 minutes)
    local cutoff = os.clock() - 600
    while #lib.state.stats.movementLog > 0 and lib.state.stats.movementLog[1].time < cutoff do
        table.remove(lib.state.stats.movementLog, 1)
    end
end

function lib.getItemsPerMinute()
    local now = os.clock()
    local oneMinAgo = now - 60
    local count = 0
    for _, entry in ipairs(lib.state.stats.movementLog) do
        if entry.time >= oneMinAgo then
            count = count + entry.count
        end
    end
    return count
end

function lib.getTopItems(n)
    n = n or 5
    local sorted = {}
    for name, total in pairs(lib.state.stats.itemCounts) do
        table.insert(sorted, { name = name, count = total })
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local result = {}
    for i = 1, math.min(n, #sorted) do
        table.insert(result, sorted[i])
    end
    return result
end

-- ============================================================
--  Favorites
-- ============================================================

function lib.toggleFavorite(invName)
    if lib.state.favorites[invName] then
        lib.state.favorites[invName] = nil
    else
        lib.state.favorites[invName] = true
    end
    lib.saveLabels()
end

function lib.isFavorite(invName)
    return lib.state.favorites[invName] == true
end

-- ============================================================
--  Undo
-- ============================================================

function lib.undoTransfer(entry)
    if not entry or not entry.undoable then return 0 end
    local fromP = peripheral.wrap(entry.to)
    if not fromP or not fromP.list then return 0 end
    local moved = 0
    if entry.item == "*" then
        -- Undo all: move everything back
        local ok, items = pcall(fromP.list)
        if ok and items then
            for slot, item in pairs(items) do
                local okM, r = pcall(fromP.pushItems, entry.from, slot, item.count)
                if okM and r then moved = moved + r end
            end
        end
    else
        moved = lib.moveItems(fromP, entry.from, entry.item, entry.moved)
    end
    if moved > 0 then
        lib.addHistory(entry.to, entry.from, entry.item, entry.moved, moved)
        -- Mark original entry as no longer undoable
        entry.undoable = false
        lib.saveHistory()
        lib.tLog("[UNDO] " .. moved .. "x " .. lib.shortName(entry.item) .. " -> " .. lib.shortName(entry.from))
    end
    return moved
end

-- ============================================================
--  Disconnect detection
-- ============================================================

function lib.checkDisconnected()
    lib.state.disconnected = {}
    local available = {}
    for _, name in ipairs(peripheral.getNames()) do
        available[name] = true
    end
    -- Check inventories used by rules
    for _, rule in ipairs(lib.state.rules) do
        if not available[rule.from] then
            lib.state.disconnected[rule.from] = true
        end
        if not available[rule.to] then
            lib.state.disconnected[rule.to] = true
        end
    end
    -- Check inventories used by tasks
    for _, task in ipairs(lib.state.tasks) do
        if task.from and not available[task.from] then
            lib.state.disconnected[task.from] = true
        end
        if task.to and not available[task.to] then
            lib.state.disconnected[task.to] = true
        end
    end
    -- Check worker
    if lib.state.workerActive then
        if lib.state.workerFrom and not available[lib.state.workerFrom] then
            lib.state.disconnected[lib.state.workerFrom] = true
        end
        if lib.state.workerTo and not available[lib.state.workerTo] then
            lib.state.disconnected[lib.state.workerTo] = true
        end
    end
    return lib.state.disconnected
end

return lib
