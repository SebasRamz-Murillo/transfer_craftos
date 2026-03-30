-- ============================================================
--  transfer_lib.lua  v5.1
--  Capa de datos: estado, persistencia, inventarios, movimiento
-- ============================================================

local lib = {}

lib.RULES_FILE   = "transfer_rules.dat"
lib.TASKS_FILE   = "transfer_tasks.dat"
lib.HISTORY_FILE = "transfer_history.dat"
lib.MAX_HISTORY  = 100

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
    table.sort(lib.state.inventories, function(a, b) return a.name < b.name end)
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

function lib.getInventoryFill(inv)
    local ok, raw = pcall(inv.peripheral.list)
    if not ok or not raw then return 0, inv.size end
    local used = 0
    for _ in pairs(raw) do used = used + 1 end
    return used, inv.size
end

-- ============================================================
--  Movimiento
-- ============================================================

function lib.moveItems(fromPeripheral, toName, itemName, cantidad)
    local ok, raw = pcall(fromPeripheral.list)
    if not ok or not raw then return 0 end
    local movido = 0
    for slot, item in pairs(raw) do
        if item.name == itemName then
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
        return { total = 0, totalOriginal = 0, slots = 0, totalSlots = 0, items = {}, destFull = false }
    end
    local totalSlots, totalItems = 0, 0
    local summary = {}
    for _, item in pairs(raw) do
        totalSlots = totalSlots + 1
        totalItems = totalItems + item.count
        if not summary[item.name] then summary[item.name] = { moved = 0, failed = 0 } end
    end
    local processed, movidoTotal, destFull = 0, 0, false
    for slot, item in pairs(raw) do
        processed = processed + 1
        if onProgress then
            onProgress({
                processed = processed, total = totalSlots,
                moved = movidoTotal, totalItems = totalItems,
                current = item.name, destFull = destFull, summary = summary,
            })
        end
        local okM, result = pcall(fromInv.peripheral.pushItems, toInv.name, slot, item.count)
        local moved = (okM and result) and result or 0
        summary[item.name].moved = summary[item.name].moved + moved
        if moved < item.count then
            summary[item.name].failed = summary[item.name].failed + (item.count - moved)
            if moved == 0 then destFull = true end
        end
        movidoTotal = movidoTotal + moved
        if destFull then
            local ns, ni = next(raw, slot)
            if ns then
                local okN, rN = pcall(fromInv.peripheral.pushItems, toInv.name, ns, 1)
                if not okN or not rN or rN == 0 then break
                else
                    destFull = false
                    movidoTotal = movidoTotal + rN
                    summary[ni.name].moved = summary[ni.name].moved + rN
                    if rN < ni.count then summary[ni.name].failed = summary[ni.name].failed + (ni.count - rN) end
                    processed = processed + 1
                end
            end
        end
        sleep(0.05)
    end
    local itemList = {}
    for name, data in pairs(summary) do
        table.insert(itemList, { name = name, moved = data.moved, failed = data.failed })
    end
    table.sort(itemList, function(a, b) return a.moved > b.moved end)
    return {
        total = movidoTotal, totalOriginal = totalItems,
        slots = processed, totalSlots = totalSlots,
        items = itemList, destFull = destFull,
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

function lib.saveHistory()
    local f = fs.open(lib.HISTORY_FILE, "w")
    f.write(textutils.serialise(lib.state.history))
    f.close()
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
    })
    if #lib.state.history > lib.MAX_HISTORY then table.remove(lib.state.history) end
    lib.saveHistory()
    lib.state.totalTransfers = lib.state.totalTransfers + 1
    lib.state.totalMoved = lib.state.totalMoved + moved
end

-- ============================================================
--  Reglas
-- ============================================================

function lib.saveRules()
    local f = fs.open(lib.RULES_FILE, "w")
    f.write(textutils.serialise(lib.state.rules))
    f.close()
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
    else
        total = lib.moveItems(fromP, rule.to, rule.item, rule.cantidad == 0 and 99999 or rule.cantidad)
    end
    return total
end

return lib
