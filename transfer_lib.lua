-- ============================================================
--  transfer_lib.lua
--  Utilidades compartidas: inventarios, movimiento, historial,
--  log de terminal, dibujo basico de monitor.
-- ============================================================

local lib = {}

-- ============================================================
--  Configuracion
-- ============================================================
lib.MONITOR_SIDE   = "top"
lib.RULES_FILE     = "transfer_rules.dat"
lib.TASKS_FILE     = "transfer_tasks.dat"
lib.HISTORY_FILE   = "transfer_history.dat"
lib.MAX_HISTORY    = 100

-- ============================================================
--  Estado global compartido
-- ============================================================
lib.state = {
    screen        = "menu",
    inventories   = {},
    fromInv       = nil,
    toInv         = nil,
    items         = {},
    filteredItems = {},
    selectedItem  = nil,
    cantidad      = 0,
    page          = 1,
    perPage       = 6,        -- se recalcula en init
    message       = "",
    movedCount    = 0,
    searchText    = "",
    rules         = {},
    tasks         = {},
    history       = {},
    rulesRunning  = true,
    -- Worker
    workerActive   = false,
    workerFrom     = nil,
    workerTo       = nil,
    workerInterval = 5,
    workerStats    = { cycles = 0, totalMoved = 0, startTime = 0, lastItems = {}, destFull = false },
}

-- ============================================================
--  Monitor y terminal (refs, se asignan en init)
-- ============================================================
lib.mon = nil
lib.W   = 0
lib.H   = 0

-- ============================================================
--  Terminal log
-- ============================================================
local termLog    = {}
local MAX_TERM   = 50

function lib.tLog(msg)
    local time = textutils.formatTime(os.time(), true)
    local line = "[" .. time .. "] " .. msg
    table.insert(termLog, 1, line)
    if #termLog > MAX_TERM then table.remove(termLog) end
end

function lib.drawTerminal()
    term.clear()
    term.setCursorPos(1, 1)
    local tW, tH = term.getSize()

    term.setTextColor(colors.yellow)
    print("=== TRANSFER v5.0 === Monitor: " .. lib.MONITOR_SIDE)
    term.setTextColor(colors.gray)
    print("Inv: " .. #lib.state.inventories ..
          " | Reglas: " .. #lib.state.rules ..
          " | Tareas: " .. #lib.state.tasks ..
          " | Ctrl+T = salir")
    print(string.rep("-", tW))
    term.setTextColor(colors.white)

    local maxLines = tH - 4
    for i = 1, math.min(#termLog, maxLines) do
        term.setCursorPos(1, 3 + i)
        local line = termLog[i]
        if line:find("ERROR") then
            term.setTextColor(colors.red)
        elseif line:find("AUTO") or line:find("TASK") then
            term.setTextColor(colors.cyan)
        elseif line:find("WORKER") then
            term.setTextColor(colors.yellow)
        elseif line:find("OK") or line:find("LISTO") then
            term.setTextColor(colors.lime)
        else
            term.setTextColor(colors.lightGray)
        end
        print(line:sub(1, tW))
    end
    term.setTextColor(colors.white)
end

-- ============================================================
--  Monitor: utilidades de dibujo
-- ============================================================
lib.buttons = {}

function lib.mClear(bg)
    lib.mon.setBackgroundColor(bg or colors.black)
    lib.mon.clear()
end

function lib.mWrite(x, y, text, fg, bg)
    lib.mon.setCursorPos(x, y)
    if fg then lib.mon.setTextColor(fg) end
    if bg then lib.mon.setBackgroundColor(bg) end
    lib.mon.write(text)
end

function lib.mFill(x, y, w, h, bg)
    lib.mon.setBackgroundColor(bg)
    for row = y, y + h - 1 do
        lib.mon.setCursorPos(x, row)
        lib.mon.write(string.rep(" ", w))
    end
end

function lib.addButton(x, y, w, h, label, fg, bg, action)
    lib.mFill(x, y, w, h, bg)
    local textX = x + math.floor((w - #label) / 2)
    local textY = y + math.floor(h / 2)
    if textX < x then textX = x end
    lib.mWrite(textX, textY, label, fg, bg)
    table.insert(lib.buttons, {
        x1 = x, y1 = y,
        x2 = x + w - 1, y2 = y + h - 1,
        action = action,
    })
end

function lib.drawHeader(title)
    lib.mFill(1, 1, lib.W, 2, colors.gray)
    lib.mWrite(2, 1, "TRANSFER", colors.yellow, colors.gray)
    lib.mWrite(2, 2, title, colors.white, colors.gray)

    if lib.state.screen ~= "menu" then
        lib.addButton(lib.W - 11, 1, 12, 2, "< MENU", colors.white, colors.red, function()
            lib.state.screen = "menu"
            lib.state.page = 1
            lib.state.searchText = ""
        end)
    end
end

function lib.drawFooter(text)
    lib.mFill(1, lib.H, lib.W, 1, colors.gray)
    lib.mWrite(2, lib.H, text or "", colors.lightGray, colors.gray)
end

function lib.drawPagination(totalItems)
    local totalPages = math.ceil(totalItems / lib.state.perPage)
    if totalPages <= 1 then return end

    local y = lib.H - 2
    lib.mFill(1, y, lib.W, 2, colors.black)

    if lib.state.page > 1 then
        lib.addButton(2, y, 10, 2, "< PREV", colors.white, colors.cyan, function()
            lib.state.page = lib.state.page - 1
        end)
    end

    lib.mWrite(math.floor(lib.W / 2) - 3, y, lib.state.page .. "/" .. totalPages, colors.gray, colors.black)

    if lib.state.page < totalPages then
        lib.addButton(lib.W - 11, y, 10, 2, "NEXT >", colors.white, colors.cyan, function()
            lib.state.page = lib.state.page + 1
        end)
    end
end

-- ============================================================
--  Inventarios
-- ============================================================

function lib.refreshInventories()
    lib.state.inventories = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ok, wrapped = pcall(peripheral.wrap, name)
        if ok and wrapped and wrapped.list and wrapped.pushItems then
            local size = 0
            pcall(function() size = wrapped.size() end)
            table.insert(lib.state.inventories, {
                name = name,
                size = size,
                peripheral = wrapped,
            })
        end
    end
    table.sort(lib.state.inventories, function(a, b) return a.name < b.name end)
end

function lib.getItems(inv)
    local ok, raw = pcall(inv.peripheral.list)
    if not ok or not raw then return {} end

    local grouped = {}
    local order = {}

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
    for _, key in ipairs(order) do
        table.insert(items, grouped[key])
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

-- ============================================================
--  Movimiento de items
-- ============================================================

function lib.moveItems(fromPeripheral, toName, itemName, cantidad)
    local ok, raw = pcall(fromPeripheral.list)
    if not ok or not raw then return 0 end
    local movido = 0

    for slot, item in pairs(raw) do
        if item.name == itemName then
            local mover = math.min(item.count, cantidad - movido)
            local okM, result = pcall(fromPeripheral.pushItems, toName, slot, mover)
            if okM and result and result > 0 then
                movido = movido + result
            end
            if movido >= cantidad then break end
        end
    end
    return movido
end

function lib.moveAllItems(fromInv, toInv)
    local ok, raw = pcall(fromInv.peripheral.list)
    if not ok or not raw then return { total = 0, items = {}, destFull = false, totalOriginal = 0, slots = 0, totalSlots = 0 } end

    local totalSlots = 0
    local totalItems = 0
    local itemSummary = {}

    for slot, item in pairs(raw) do
        totalSlots = totalSlots + 1
        totalItems = totalItems + item.count
        if not itemSummary[item.name] then
            itemSummary[item.name] = { moved = 0, failed = 0 }
        end
    end

    local processedSlots = 0
    local movidoTotal = 0
    local destFull = false

    local function updateProgress(currentItem)
        lib.mFill(1, 5, lib.W, lib.H - 6, colors.black)

        local pct = totalSlots > 0 and math.floor(processedSlots / totalSlots * 100) or 0
        local barW = lib.W - 6
        local filled = math.floor(barW * pct / 100)

        lib.mWrite(2, 6, "Progreso:", colors.gray, colors.black)
        lib.mFill(3, 7, barW, 2, colors.gray)
        if filled > 0 then
            lib.mFill(3, 7, filled, 2, colors.green)
        end
        local pctStr = pct .. "%"
        lib.mWrite(math.floor(lib.W / 2) - math.floor(#pctStr / 2), 7, pctStr,
            colors.white, filled > math.floor(lib.W / 2) and colors.green or colors.gray)

        lib.mWrite(3, 10, "Slots: " .. processedSlots .. "/" .. totalSlots, colors.lightGray, colors.black)
        lib.mWrite(3, 11, "Items movidos: " .. movidoTotal, colors.yellow, colors.black)

        if currentItem then
            local shortName = currentItem:match(":(.+)") or currentItem
            lib.mWrite(3, 13, "Moviendo: " .. shortName, colors.cyan, colors.black)
        end

        if destFull then
            lib.mFill(2, 15, lib.W - 2, 2, colors.red)
            lib.mWrite(3, 15, "DESTINO LLENO!", colors.white, colors.red)
            lib.mWrite(3, 16, "Algunos items no se movieron", colors.yellow, colors.red)
        end

        local y = 18
        for name, data in pairs(itemSummary) do
            if data.moved > 0 and y < lib.H - 1 then
                local shortName = name:match(":(.+)") or name
                if #shortName > lib.W - 15 then shortName = shortName:sub(1, lib.W - 17) .. ".." end
                local statusCol = data.failed > 0 and colors.orange or colors.lime
                lib.mWrite(3, y, shortName, colors.white, colors.black)
                lib.mWrite(lib.W - 10, y, "x" .. data.moved, statusCol, colors.black)
                y = y + 1
            end
        end

        lib.drawFooter("Transfiriendo... no tocar")
    end

    for slot, item in pairs(raw) do
        processedSlots = processedSlots + 1
        updateProgress(item.name)

        local okM, result = pcall(fromInv.peripheral.pushItems, toInv.name, slot, item.count)
        local moved = (okM and result) and result or 0

        itemSummary[item.name].moved = itemSummary[item.name].moved + moved

        if moved < item.count then
            itemSummary[item.name].failed = itemSummary[item.name].failed + (item.count - moved)
            if moved == 0 then
                destFull = true
            end
        end

        movidoTotal = movidoTotal + moved

        if destFull then
            local nextSlot, nextItem = next(raw, slot)
            if nextSlot then
                local okN, resultN = pcall(fromInv.peripheral.pushItems, toInv.name, nextSlot, 1)
                if not okN or not resultN or resultN == 0 then
                    lib.tLog("ERROR: Destino lleno, abortando")
                    break
                else
                    destFull = false
                    movidoTotal = movidoTotal + resultN
                    itemSummary[nextItem.name].moved = itemSummary[nextItem.name].moved + resultN
                    if resultN < nextItem.count then
                        itemSummary[nextItem.name].failed = itemSummary[nextItem.name].failed + (nextItem.count - resultN)
                    end
                    processedSlots = processedSlots + 1
                end
            end
        end

        sleep(0.05)
    end

    updateProgress(nil)

    local itemList = {}
    for name, data in pairs(itemSummary) do
        table.insert(itemList, {
            name = name,
            moved = data.moved,
            failed = data.failed,
        })
    end
    table.sort(itemList, function(a, b) return a.moved > b.moved end)

    return {
        total = movidoTotal,
        totalOriginal = totalItems,
        slots = processedSlots,
        totalSlots = totalSlots,
        items = itemList,
        destFull = destFull,
    }
end

-- ============================================================
--  Filtro / busqueda
-- ============================================================

function lib.applyFilter()
    local st = lib.state
    if st.searchText == "" then
        st.filteredItems = st.items
    else
        st.filteredItems = {}
        local search = st.searchText:lower()
        for _, item in ipairs(st.items) do
            local shortName = (item.name:match(":(.+)") or item.name):lower()
            if shortName:find(search, 1, true) then
                table.insert(st.filteredItems, item)
            end
        end
    end
    st.page = 1
end

-- ============================================================
--  Historial (persistente)
-- ============================================================

function lib.saveHistory()
    local file = fs.open(lib.HISTORY_FILE, "w")
    file.write(textutils.serialise(lib.state.history))
    file.close()
end

function lib.loadHistory()
    if fs.exists(lib.HISTORY_FILE) then
        local file = fs.open(lib.HISTORY_FILE, "r")
        local data = textutils.unserialise(file.readAll())
        file.close()
        if data then lib.state.history = data end
    end
end

function lib.addHistory(from, to, item, requested, moved)
    table.insert(lib.state.history, 1, {
        from = from,
        to = to,
        item = item,
        requested = requested,
        moved = moved,
        time = textutils.formatTime(os.time(), true),
        day = os.day(),
    })
    if #lib.state.history > lib.MAX_HISTORY then
        table.remove(lib.state.history)
    end
    lib.saveHistory()
end

-- ============================================================
--  Reglas automaticas (persistente)
-- ============================================================

function lib.saveRules()
    local file = fs.open(lib.RULES_FILE, "w")
    file.write(textutils.serialise(lib.state.rules))
    file.close()
end

function lib.loadRules()
    if fs.exists(lib.RULES_FILE) then
        local file = fs.open(lib.RULES_FILE, "r")
        local data = textutils.unserialise(file.readAll())
        file.close()
        if data then lib.state.rules = data end
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

-- ============================================================
--  Teclado virtual
-- ============================================================

function lib.drawKeyboard(onConfirm)
    local keys = {
        "A B C D E F G H I",
        "J K L M N O P Q R",
        "S T U V W X Y Z _",
    }

    local y = lib.H - 8

    lib.mFill(2, y - 2, lib.W - 2, 2, colors.gray)
    local display = lib.state.searchText
    if display == "" then display = "Escribe para filtrar..." end
    lib.mWrite(3, y - 1, display, lib.state.searchText == "" and colors.lightGray or colors.yellow, colors.gray)

    for row, line in ipairs(keys) do
        local col = 2
        for char in line:gmatch("%S+") do
            lib.addButton(col, y + (row - 1) * 2, 3, 2, char, colors.white, colors.blue, function()
                lib.state.searchText = lib.state.searchText .. char:lower()
                lib.applyFilter()
            end)
            col = col + 4
        end
    end

    local specialY = y + #keys * 2
    lib.addButton(2, specialY, 8, 2, "BORRAR", colors.white, colors.orange, function()
        if #lib.state.searchText > 0 then
            lib.state.searchText = lib.state.searchText:sub(1, -2)
            lib.applyFilter()
        end
    end)
    lib.addButton(12, specialY, 8, 2, "LIMPIAR", colors.white, colors.red, function()
        lib.state.searchText = ""
        lib.applyFilter()
    end)
    lib.addButton(22, specialY, 8, 2, "OK", colors.white, colors.green, function()
        if onConfirm then onConfirm() end
    end)
end

-- ============================================================
--  Inicializacion
-- ============================================================

function lib.init()
    lib.mon = peripheral.wrap(lib.MONITOR_SIDE)
    if not lib.mon then
        print("ERROR: No hay monitor en '" .. lib.MONITOR_SIDE .. "'")
        return false
    end
    lib.mon.setTextScale(0.5)
    lib.W, lib.H = lib.mon.getSize()
    lib.state.perPage = math.floor((lib.H - 8) / 3)
    return true
end

return lib
