-- ============================================================
--  transfer_ui.lua
--  Todas las pantallas del monitor tactil.
-- ============================================================

local lib    = require("transfer_lib")
local tasks  = require("transfer_tasks")
local worker = require("transfer_worker")

local ui = {}

-- Shortcuts locales
local st          = lib.state
local mClear      = lib.mClear
local mWrite      = lib.mWrite
local mFill       = lib.mFill
local addButton   = lib.addButton
local drawHeader  = lib.drawHeader
local drawFooter  = lib.drawFooter
local drawPagination = lib.drawPagination

-- ============================================================
--  Pantalla: Menu principal
-- ============================================================

local function drawMenu()
    drawHeader("Menu Principal")

    local y = 4
    mWrite(2, y, "Que deseas hacer?", colors.lightGray, colors.black)
    y = y + 2

    addButton(3, y, lib.W - 4, 3, "TRANSFERIR", colors.white, colors.green, function()
        lib.refreshInventories()
        st.screen = "select_from"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "VACIAR INVENTARIO", colors.white, colors.orange, function()
        lib.refreshInventories()
        st.screen = "bulk_from"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "WORKER (VACIAR LOOP)", colors.black, colors.yellow, function()
        lib.refreshInventories()
        st.screen = "worker_from"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "TAREAS", colors.white, colors.blue, function()
        st.screen = "tasks_list"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "REGLAS AUTOMATICAS", colors.white, colors.purple, function()
        st.screen = "rules_list"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "HISTORIAL", colors.white, colors.cyan, function()
        st.screen = "history"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "VER INVENTARIOS", colors.white, colors.gray, function()
        lib.refreshInventories()
        st.screen = "view_invs"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "SALIR", colors.white, colors.red, function()
        st.screen = "exit"
    end)

    local rulesStatus = st.rulesRunning and "ON" or "OFF"
    drawFooter("Reglas: " .. #st.rules .. " (" .. rulesStatus .. ") | Tareas: " .. tasks.countEnabled() .. "/" .. tasks.count() .. " | Inv: " .. #st.inventories)
end

-- ============================================================
--  Pantalla: Seleccionar inventario (generica)
-- ============================================================

local function drawSelectInv(title, nextScreen, targetField)
    drawHeader(title)

    if #st.inventories == 0 then
        mWrite(2, 5, "No hay inventarios", colors.red, colors.black)
        mWrite(2, 6, "en la red.", colors.red, colors.black)
        drawFooter("Conecta inventarios con cables")
        return
    end

    local startIdx = (st.page - 1) * st.perPage + 1
    local endIdx = math.min(st.page * st.perPage, #st.inventories)

    local y = 4
    for i = startIdx, endIdx do
        local inv = st.inventories[i]
        local shortName = inv.name
        if #shortName > lib.W - 6 then shortName = shortName:sub(1, lib.W - 8) .. ".." end

        local bg = (i % 2 == 0) and colors.blue or colors.gray
        local fg = colors.white

        if st.fromInv and inv.name == st.fromInv.name and targetField == "toInv" then
            bg = colors.brown
            fg = colors.red
        end

        addButton(2, y, lib.W - 2, 3, "", fg, bg, function()
            if st.fromInv and inv.name == st.fromInv.name and targetField == "toInv" then
                return
            end
            st[targetField] = inv
            st.screen = nextScreen
            st.page = 1
            if nextScreen == "select_item" then
                st.items = lib.getItems(inv)
                st.searchText = ""
                lib.applyFilter()
            end
        end)
        mWrite(4, y + 1, shortName, fg, bg)
        mWrite(lib.W - 9, y + 1, inv.size .. " slots", colors.lightGray, bg)

        y = y + 4
    end

    drawPagination(#st.inventories)
    drawFooter(#st.inventories .. " inventarios")
end

-- ============================================================
--  Pantalla: Seleccionar item
-- ============================================================

local function drawSelectItem()
    drawHeader("Seleccionar Item")

    local fromShort = st.fromInv.name
    if #fromShort > lib.W - 8 then fromShort = fromShort:sub(1, lib.W - 10) .. ".." end
    mWrite(2, 3, "De: " .. fromShort, colors.cyan, colors.black)

    addButton(lib.W - 13, 3, 12, 1, "BUSCAR", colors.white, colors.orange, function()
        st.screen = "search_item"
    end)

    if st.searchText ~= "" then
        mWrite(2, 4, "Filtro: " .. st.searchText, colors.yellow, colors.black)
    end

    local displayItems = st.filteredItems

    if #displayItems == 0 then
        mWrite(2, 6, st.searchText ~= "" and "Sin resultados" or "Inventario vacio", colors.orange, colors.black)
        drawFooter("")
        return
    end

    local startIdx = (st.page - 1) * st.perPage + 1
    local endIdx = math.min(st.page * st.perPage, #displayItems)

    local y = 5
    for i = startIdx, endIdx do
        local item = displayItems[i]
        local shortName = item.name:match(":(.+)") or item.name
        if #shortName > lib.W - 6 then shortName = shortName:sub(1, lib.W - 8) .. ".." end

        local bg = (i % 2 == 0) and colors.blue or colors.gray

        addButton(2, y, lib.W - 2, 3, "", colors.white, bg, function()
            st.selectedItem = item
            st.cantidad = item.total
            st.screen = "select_qty"
        end)
        mWrite(4, y, shortName, colors.white, bg)
        mWrite(4, y + 1, "Cantidad: " .. item.total, colors.yellow, bg)

        y = y + 4
    end

    drawPagination(#displayItems)
    drawFooter(#displayItems .. " items" .. (st.searchText ~= "" and " (filtrado)" or ""))
end

-- ============================================================
--  Pantalla: Busqueda con teclado
-- ============================================================

local function drawSearchItem()
    drawHeader("Buscar Item")

    local y = 4
    for i = 1, math.min(3, #st.filteredItems) do
        local item = st.filteredItems[i]
        local shortName = item.name:match(":(.+)") or item.name
        mWrite(3, y, shortName .. " x" .. item.total, colors.lightGray, colors.black)
        y = y + 1
    end
    if #st.filteredItems > 3 then
        mWrite(3, y, "... +" .. (#st.filteredItems - 3) .. " mas", colors.gray, colors.black)
    end

    lib.drawKeyboard(function()
        st.screen = "select_item"
    end)
end

-- ============================================================
--  Pantalla: Seleccionar cantidad
-- ============================================================

local function drawSelectQty()
    drawHeader("Cantidad")

    local shortName = st.selectedItem.name:match(":(.+)") or st.selectedItem.name
    local maxQty = st.selectedItem.total

    mWrite(2, 4, "Item: " .. shortName, colors.white, colors.black)
    mWrite(2, 5, "Disponible: " .. maxQty, colors.gray, colors.black)

    mFill(3, 7, lib.W - 4, 3, colors.gray)
    local qtyStr = tostring(st.cantidad)
    mWrite(math.floor(lib.W / 2) - math.floor(#qtyStr / 2), 8, qtyStr, colors.yellow, colors.gray)

    local y = 11
    addButton(2, y, 7, 2, "-1", colors.white, colors.red, function()
        st.cantidad = math.max(1, st.cantidad - 1)
    end)
    addButton(11, y, 7, 2, "-10", colors.white, colors.red, function()
        st.cantidad = math.max(1, st.cantidad - 10)
    end)
    addButton(20, y, 7, 2, "-64", colors.white, colors.red, function()
        st.cantidad = math.max(1, st.cantidad - 64)
    end)

    y = y + 3
    addButton(2, y, 7, 2, "+1", colors.white, colors.green, function()
        st.cantidad = math.min(maxQty, st.cantidad + 1)
    end)
    addButton(11, y, 7, 2, "+10", colors.white, colors.green, function()
        st.cantidad = math.min(maxQty, st.cantidad + 10)
    end)
    addButton(20, y, 7, 2, "+64", colors.white, colors.green, function()
        st.cantidad = math.min(maxQty, st.cantidad + 64)
    end)

    y = y + 3
    addButton(2, y, 10, 2, "TODO", colors.white, colors.purple, function()
        st.cantidad = maxQty
    end)
    addButton(14, y, 10, 2, "1 STACK", colors.white, colors.purple, function()
        st.cantidad = math.min(64, maxQty)
    end)

    y = y + 3
    addButton(3, y, lib.W - 4, 3, "SIGUIENTE >>", colors.white, colors.blue, function()
        lib.refreshInventories()
        st.screen = "select_to"
        st.page = 1
    end)
end

-- ============================================================
--  Pantalla: Confirmar transferencia
-- ============================================================

local function drawConfirm()
    drawHeader("Confirmar")

    local shortItem = st.selectedItem.name:match(":(.+)") or st.selectedItem.name
    local fromShort = st.fromInv.name
    local toShort = st.toInv.name
    if #fromShort > lib.W - 6 then fromShort = fromShort:sub(1, lib.W - 8) .. ".." end
    if #toShort > lib.W - 6 then toShort = toShort:sub(1, lib.W - 8) .. ".." end

    local y = 4
    mWrite(2, y, "Item:", colors.gray, colors.black)
    mWrite(9, y, shortItem, colors.white, colors.black)
    y = y + 1
    mWrite(2, y, "Cant:", colors.gray, colors.black)
    mWrite(9, y, tostring(st.cantidad), colors.yellow, colors.black)
    y = y + 2
    mWrite(2, y, "DE:", colors.gray, colors.black)
    y = y + 1
    mWrite(3, y, fromShort, colors.lime, colors.black)
    y = y + 2
    mWrite(2, y, "A:", colors.gray, colors.black)
    y = y + 1
    mWrite(3, y, toShort, colors.cyan, colors.black)

    y = y + 3
    addButton(2, y, math.floor(lib.W / 2) - 2, 3, "CANCELAR", colors.white, colors.red, function()
        st.screen = "menu"
    end)
    addButton(math.floor(lib.W / 2) + 1, y, math.floor(lib.W / 2) - 1, 3, "EJECUTAR", colors.white, colors.green, function()
        st.screen = "executing"
    end)

    y = y + 4
    addButton(3, y, lib.W - 4, 2, "GUARDAR COMO REGLA", colors.white, colors.orange, function()
        local rule = {
            from     = st.fromInv.name,
            to       = st.toInv.name,
            item     = st.selectedItem.name,
            cantidad = st.cantidad,
            interval = 10,
            enabled  = true,
        }
        table.insert(st.rules, rule)
        lib.saveRules()
        lib.tLog("Regla #" .. #st.rules .. " creada")
        st.screen = "executing"
    end)

    y = y + 3
    addButton(3, y, lib.W - 4, 2, "GUARDAR COMO TAREA", colors.white, colors.blue, function()
        tasks.create({
            name     = (st.selectedItem.name:match(":(.+)") or st.selectedItem.name):sub(1, 12) .. " > " .. st.toInv.name:sub(1, 10),
            type     = "transfer",
            from     = st.fromInv.name,
            to       = st.toInv.name,
            item     = st.selectedItem.name,
            cantidad = st.cantidad,
            interval = 10,
            loop     = true,
        })
        st.screen = "executing"
    end)
end

-- ============================================================
--  Pantalla: Ejecutando transferencia
-- ============================================================

local function drawExecuting()
    drawHeader("Transfiriendo...")
    mWrite(2, 5, "Moviendo items...", colors.yellow, colors.black)

    local movido = lib.moveItems(st.fromInv.peripheral, st.toInv.name, st.selectedItem.name, st.cantidad)
    st.movedCount = movido
    st.message = movido .. "/" .. st.cantidad

    local shortItem = st.selectedItem.name:match(":(.+)") or st.selectedItem.name
    if movido > 0 then
        lib.tLog("OK: " .. movido .. "x " .. shortItem .. " -> " .. st.toInv.name)
    else
        lib.tLog("ERROR: No se movio " .. shortItem)
    end
    lib.addHistory(st.fromInv.name, st.toInv.name, st.selectedItem.name, st.cantidad, movido)
    lib.drawTerminal()

    st.screen = "result"
end

-- ============================================================
--  Pantalla: Resultado
-- ============================================================

local function drawResult()
    drawHeader("Resultado")

    local y = 5

    if st.movedCount >= st.cantidad then
        mFill(2, y, lib.W - 2, 3, colors.green)
        mWrite(4, y + 1, "LISTO! " .. st.message, colors.white, colors.green)
    elseif st.movedCount > 0 then
        mFill(2, y, lib.W - 2, 3, colors.orange)
        mWrite(4, y + 1, "PARCIAL: " .. st.message, colors.white, colors.orange)
    else
        mFill(2, y, lib.W - 2, 3, colors.red)
        mWrite(4, y + 1, "FALLO: 0 items", colors.white, colors.red)
    end

    y = y + 5
    addButton(3, y, lib.W - 4, 3, "NUEVA TRANSFERENCIA", colors.white, colors.blue, function()
        st.screen = "menu"
        st.fromInv = nil
        st.toInv = nil
        st.selectedItem = nil
        st.searchText = ""
        st.page = 1
    end)
end

-- ============================================================
--  Pantallas: Reglas automaticas
-- ============================================================

local function drawRulesList()
    drawHeader("Reglas Automaticas")

    local toggleLabel = st.rulesRunning and "AUTO: ON" or "AUTO: OFF"
    local toggleColor = st.rulesRunning and colors.green or colors.red
    addButton(lib.W - 13, 3, 12, 2, toggleLabel, colors.white, toggleColor, function()
        st.rulesRunning = not st.rulesRunning
        lib.tLog("Reglas auto: " .. (st.rulesRunning and "ON" or "OFF"))
    end)

    addButton(2, 3, 14, 2, "+ NUEVA REGLA", colors.white, colors.green, function()
        lib.refreshInventories()
        st.screen = "rule_new_from"
        st.page = 1
    end)

    if #st.rules == 0 then
        mWrite(2, 7, "No hay reglas.", colors.gray, colors.black)
        mWrite(2, 8, "Crea una con + NUEVA REGLA", colors.gray, colors.black)
        drawFooter("")
        return
    end

    local y = 6
    for i, rule in ipairs(st.rules) do
        if y + 4 > lib.H - 2 then break end

        local shortItem = rule.item == "*" and "TODO" or (rule.item:match(":(.+)") or rule.item)
        local fromShort = rule.from:sub(1, 12)
        local toShort = rule.to:sub(1, 12)
        local qty = rule.cantidad == 0 and "all" or tostring(rule.cantidad)

        local bg = rule.enabled and colors.gray or colors.brown

        mFill(2, y, lib.W - 14, 3, bg)
        mWrite(3, y, "#" .. i .. " " .. shortItem .. " x" .. qty, colors.white, bg)
        mWrite(3, y + 1, fromShort .. " > " .. toShort, colors.lightGray, bg)
        mWrite(3, y + 2, rule.interval .. "s", colors.yellow, bg)

        local eLbl = rule.enabled and "ON" or "OFF"
        local eCol = rule.enabled and colors.green or colors.red
        addButton(lib.W - 12, y, 5, 3, eLbl, colors.white, eCol, function()
            rule.enabled = not rule.enabled
            lib.saveRules()
        end)

        addButton(lib.W - 6, y, 5, 3, "DEL", colors.white, colors.red, function()
            table.remove(st.rules, i)
            lib.saveRules()
            lib.tLog("Regla #" .. i .. " eliminada")
        end)

        y = y + 4
    end

    drawFooter(#st.rules .. " reglas")
end

local function drawRuleNewItem()
    drawHeader("Regla: Que mover?")

    local y = 4
    addButton(2, y, lib.W - 2, 3, "MOVER TODO (*)", colors.white, colors.purple, function()
        st.selectedItem = { name = "*", total = 0 }
        st.screen = "rule_new_to"
        st.page = 1
        lib.refreshInventories()
    end)
    y = y + 4

    mWrite(2, y, "O elige un item especifico:", colors.gray, colors.black)
    y = y + 2

    if not st.items or #st.items == 0 then
        st.items = lib.getItems(st.fromInv)
        st.searchText = ""
        lib.applyFilter()
    end

    local startIdx = (st.page - 1) * st.perPage + 1
    local displayItems = st.filteredItems
    local endIdx = math.min(st.page * st.perPage, #displayItems)

    for i = startIdx, endIdx do
        if y + 3 > lib.H - 3 then break end
        local item = displayItems[i]
        local shortName = item.name:match(":(.+)") or item.name
        if #shortName > lib.W - 6 then shortName = shortName:sub(1, lib.W - 8) .. ".." end

        local bg = (i % 2 == 0) and colors.blue or colors.gray
        addButton(2, y, lib.W - 2, 3, "", colors.white, bg, function()
            st.selectedItem = item
            st.screen = "rule_new_to"
            st.page = 1
            lib.refreshInventories()
        end)
        mWrite(4, y + 1, shortName .. " x" .. item.total, colors.white, bg)
        y = y + 4
    end

    drawPagination(#displayItems)
end

local function drawRuleNewInterval()
    drawHeader("Regla: Intervalo")

    local shortItem = st.selectedItem.name == "*" and "TODO" or (st.selectedItem.name:match(":(.+)") or st.selectedItem.name)

    mWrite(2, 4, "Item: " .. shortItem, colors.white, colors.black)
    mWrite(2, 5, st.fromInv.name, colors.lime, colors.black)
    mWrite(2, 6, "  ->  " .. st.toInv.name, colors.cyan, colors.black)

    local y = 8
    mWrite(2, y, "Cada cuantos segundos?", colors.gray, colors.black)
    y = y + 2

    local intervals = { 5, 10, 30, 60 }
    for _, secs in ipairs(intervals) do
        local label = secs .. " seg"
        if secs >= 60 then label = (secs / 60) .. " min" end

        addButton(2, y, lib.W - 2, 2, label, colors.white, colors.blue, function()
            local rule = {
                from     = st.fromInv.name,
                to       = st.toInv.name,
                item     = st.selectedItem.name,
                cantidad = 0,
                interval = secs,
                enabled  = true,
                lastRun  = 0,
            }
            table.insert(st.rules, rule)
            lib.saveRules()
            lib.tLog("Regla #" .. #st.rules .. " creada: " .. shortItem .. " cada " .. secs .. "s")

            st.screen = "rules_list"
            st.fromInv = nil
            st.toInv = nil
            st.selectedItem = nil
            st.page = 1
        end)
        y = y + 3
    end
end

-- ============================================================
--  Pantalla: Historial
-- ============================================================

local function drawHistory()
    drawHeader("Historial")

    if #st.history == 0 then
        mWrite(2, 5, "Sin historial.", colors.gray, colors.black)
        drawFooter("")
        return
    end

    addButton(lib.W - 13, 3, 12, 2, "LIMPIAR", colors.white, colors.red, function()
        st.history = {}
        lib.saveHistory()
        lib.tLog("Historial limpiado")
    end)

    local startIdx = (st.page - 1) * st.perPage + 1
    local endIdx = math.min(st.page * st.perPage, #st.history)

    local y = 6
    for i = startIdx, endIdx do
        local h = st.history[i]
        local shortItem = h.item == "*" and "todo" or (h.item:match(":(.+)") or h.item)
        local fromShort = h.from:sub(1, 10)
        local toShort = h.to:sub(1, 10)
        local status = h.moved >= h.requested and "OK" or "PARCIAL"
        local statusCol = h.moved >= h.requested and colors.lime or colors.orange

        local bg = (i % 2 == 0) and colors.gray or colors.black
        mFill(2, y, lib.W - 2, 3, bg)
        mWrite(3, y, h.time .. " " .. status, statusCol, bg)
        mWrite(3, y + 1, h.moved .. "x " .. shortItem, colors.white, bg)
        mWrite(3, y + 2, fromShort .. " > " .. toShort, colors.lightGray, bg)

        y = y + 4
    end

    drawPagination(#st.history)
    drawFooter(#st.history .. " registros")
end

-- ============================================================
--  Pantallas: Bulk (vaciar inventario)
-- ============================================================

local function drawBulkConfirm()
    drawHeader("Vaciar Inventario")

    local fromShort = st.fromInv.name
    local toShort = st.toInv.name
    if #fromShort > lib.W - 6 then fromShort = fromShort:sub(1, lib.W - 8) .. ".." end
    if #toShort > lib.W - 6 then toShort = toShort:sub(1, lib.W - 8) .. ".." end

    local y = 4

    local items = lib.getItems(st.fromInv)
    local totalItems = 0
    for _, item in ipairs(items) do totalItems = totalItems + item.total end

    mWrite(2, y, "ORIGEN:", colors.gray, colors.black)
    y = y + 1
    mWrite(3, y, fromShort, colors.lime, colors.black)
    y = y + 1
    mWrite(3, y, #items .. " tipos | " .. totalItems .. " items total", colors.yellow, colors.black)

    y = y + 2
    mWrite(2, y, "DESTINO:", colors.gray, colors.black)
    y = y + 1
    mWrite(3, y, toShort, colors.cyan, colors.black)

    y = y + 2
    mFill(2, y, lib.W - 2, 2, colors.orange)
    mWrite(3, y, "Se moveran TODOS los items", colors.white, colors.orange)
    mWrite(3, y + 1, "del origen al destino", colors.yellow, colors.orange)

    y = y + 4
    addButton(2, y, math.floor(lib.W / 2) - 2, 3, "CANCELAR", colors.white, colors.red, function()
        st.screen = "menu"
    end)
    addButton(math.floor(lib.W / 2) + 1, y, math.floor(lib.W / 2) - 1, 3, "VACIAR", colors.white, colors.green, function()
        st.screen = "bulk_executing"
    end)
end

local function drawBulkExecuting()
    drawHeader("Vaciando...")
    mWrite(2, 4, "Transfiriendo todos los items...", colors.yellow, colors.black)

    local result = lib.moveAllItems(st.fromInv, st.toInv)
    st.bulkResult = result

    lib.tLog("LISTO: Vaciado " .. st.fromInv.name)
    lib.tLog("  -> " .. result.total .. " items movidos a " .. st.toInv.name)
    if result.destFull then
        lib.tLog("  WARN: Destino se lleno!")
    end

    for _, item in ipairs(result.items) do
        if item.moved > 0 then
            lib.addHistory(st.fromInv.name, st.toInv.name, item.name, item.moved + item.failed, item.moved)
        end
    end

    lib.drawTerminal()
    st.screen = "bulk_result"
end

local function drawBulkResult()
    drawHeader("Resultado")

    local r = st.bulkResult
    local y = 4

    if r.destFull then
        mFill(2, y, lib.W - 2, 3, colors.orange)
        mWrite(3, y, "DESTINO LLENO", colors.white, colors.orange)
        mWrite(3, y + 1, "Transferencia parcial", colors.yellow, colors.orange)
        mWrite(3, y + 2, r.total .. "/" .. r.totalOriginal .. " items", colors.white, colors.orange)
    elseif r.total > 0 then
        mFill(2, y, lib.W - 2, 3, colors.green)
        mWrite(3, y, "COMPLETADO!", colors.white, colors.green)
        mWrite(3, y + 1, r.total .. " items movidos", colors.yellow, colors.green)
        mWrite(3, y + 2, r.slots .. " slots procesados", colors.white, colors.green)
    else
        mFill(2, y, lib.W - 2, 3, colors.red)
        mWrite(3, y + 1, "FALLO: 0 items movidos", colors.white, colors.red)
    end

    y = y + 4

    mWrite(2, y, "Detalle:", colors.gray, colors.black)
    y = y + 1

    local maxDetail = math.min(#r.items, lib.H - y - 5)
    for i = 1, maxDetail do
        local item = r.items[i]
        local shortName = item.name:match(":(.+)") or item.name
        if #shortName > lib.W - 18 then shortName = shortName:sub(1, lib.W - 20) .. ".." end

        local statusCol = colors.lime
        local statusText = "x" .. item.moved

        if item.failed > 0 then
            statusCol = colors.orange
            statusText = item.moved .. "/" .. (item.moved + item.failed)
        end

        mWrite(3, y, shortName, colors.white, colors.black)
        mWrite(lib.W - #statusText - 2, y, statusText, statusCol, colors.black)
        y = y + 1
    end

    if #r.items > maxDetail then
        mWrite(3, y, "... +" .. (#r.items - maxDetail) .. " mas", colors.gray, colors.black)
        y = y + 1
    end

    y = y + 2
    addButton(3, y, lib.W - 4, 3, "VOLVER AL MENU", colors.white, colors.blue, function()
        st.screen = "menu"
        st.fromInv = nil
        st.toInv = nil
        st.page = 1
    end)
end

-- ============================================================
--  Pantalla: Ver inventarios
-- ============================================================

local function drawViewInvs()
    drawHeader("Inventarios en Red")

    if #st.inventories == 0 then
        mWrite(2, 5, "Ninguno encontrado", colors.red, colors.black)
        drawFooter("")
        return
    end

    local startIdx = (st.page - 1) * st.perPage + 1
    local endIdx = math.min(st.page * st.perPage, #st.inventories)

    local y = 4
    for i = startIdx, endIdx do
        local inv = st.inventories[i]
        local shortName = inv.name
        if #shortName > lib.W - 6 then shortName = shortName:sub(1, lib.W - 8) .. ".." end

        local bg = (i % 2 == 0) and colors.blue or colors.gray
        mFill(2, y, lib.W - 2, 3, bg)
        mWrite(4, y + 1, shortName, colors.white, bg)
        mWrite(lib.W - 9, y + 1, inv.size .. " slots", colors.lightGray, bg)
        y = y + 4
    end

    drawPagination(#st.inventories)
    drawFooter(#st.inventories .. " total")
end

-- ============================================================
--  Pantallas: Worker
-- ============================================================

local function drawWorkerInterval()
    drawHeader("Worker: Intervalo")

    local y = 4
    mWrite(2, y, "Cada cuantos segundos", colors.lightGray, colors.black)
    y = y + 1
    mWrite(2, y, "revisar el inventario?", colors.lightGray, colors.black)
    y = y + 2

    mFill(2, y, lib.W - 2, 3, colors.gray)
    local valStr = tostring(st.workerInterval) .. " seg"
    mWrite(math.floor(lib.W / 2) - math.floor(#valStr / 2), y + 1, valStr, colors.yellow, colors.gray)
    y = y + 4

    local presets = { 1, 2, 5, 10, 15, 30, 60 }
    local btnW = math.floor((lib.W - 4) / #presets)

    for idx, val in ipairs(presets) do
        local bx = 2 + (idx - 1) * btnW
        local bg = val == st.workerInterval and colors.green or colors.blue
        addButton(bx, y, btnW - 1, 3, tostring(val), colors.white, bg, function()
            st.workerInterval = val
        end)
    end
    y = y + 4

    addButton(2, y, 8, 3, "- 1s", colors.white, colors.orange, function()
        st.workerInterval = math.max(1, st.workerInterval - 1)
    end)
    addButton(lib.W - 9, y, 8, 3, "+ 1s", colors.white, colors.cyan, function()
        st.workerInterval = math.min(300, st.workerInterval + 1)
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "CONTINUAR", colors.white, colors.green, function()
        st.screen = "worker_confirm"
    end)
end

local function drawWorkerConfirm()
    drawHeader("Worker: Confirmar")

    local fromShort = st.fromInv.name
    local toShort = st.toInv.name
    if #fromShort > lib.W - 6 then fromShort = fromShort:sub(1, lib.W - 8) .. ".." end
    if #toShort > lib.W - 6 then toShort = toShort:sub(1, lib.W - 8) .. ".." end

    local y = 4

    mWrite(2, y, "ORIGEN (vaciar):", colors.gray, colors.black)
    y = y + 1
    mWrite(3, y, fromShort, colors.lime, colors.black)
    y = y + 2

    mWrite(2, y, "DESTINO:", colors.gray, colors.black)
    y = y + 1
    mWrite(3, y, toShort, colors.cyan, colors.black)
    y = y + 2

    mWrite(2, y, "INTERVALO:", colors.gray, colors.black)
    y = y + 1
    mWrite(3, y, "Cada " .. st.workerInterval .. " segundos", colors.yellow, colors.black)
    y = y + 2

    mFill(2, y, lib.W - 2, 3, colors.yellow)
    mWrite(3, y, "El worker vaciara TODO", colors.black, colors.yellow)
    mWrite(3, y + 1, "del origen al destino", colors.black, colors.yellow)
    mWrite(3, y + 2, "de forma CONTINUA", colors.black, colors.yellow)
    y = y + 4

    addButton(2, y, math.floor(lib.W / 2) - 2, 3, "CANCELAR", colors.white, colors.red, function()
        st.screen = "menu"
        st.fromInv = nil
        st.toInv = nil
    end)
    addButton(math.floor(lib.W / 2) + 1, y, math.floor(lib.W / 2) - 1, 3, "INICIAR", colors.black, colors.lime, function()
        worker.start(st.fromInv, st.toInv, st.workerInterval)
        st.screen = "worker_running"
    end)
end

local function drawWorkerRunning()
    drawHeader("Worker ACTIVO")

    local ws = st.workerStats
    local y = 4

    local elapsed = os.clock() - ws.startTime
    local elapsedStr
    if elapsed < 60 then
        elapsedStr = math.floor(elapsed) .. "s"
    elseif elapsed < 3600 then
        elapsedStr = math.floor(elapsed / 60) .. "m " .. math.floor(elapsed % 60) .. "s"
    else
        elapsedStr = math.floor(elapsed / 3600) .. "h " .. math.floor((elapsed % 3600) / 60) .. "m"
    end

    if st.workerActive then
        mFill(2, y, lib.W - 2, 2, colors.green)
        mWrite(3, y, "ACTIVO", colors.white, colors.green)
        mWrite(lib.W - #elapsedStr - 3, y, elapsedStr, colors.white, colors.green)
        mWrite(3, y + 1, "Ciclo cada " .. st.workerInterval .. "s", colors.yellow, colors.green)
    else
        mFill(2, y, lib.W - 2, 2, colors.red)
        mWrite(3, y, "PAUSADO", colors.white, colors.red)
        mWrite(lib.W - #elapsedStr - 3, y, elapsedStr, colors.white, colors.red)
    end
    y = y + 3

    local fromShort = st.workerFrom and st.workerFrom.name or "?"
    local toShort = st.workerTo and st.workerTo.name or "?"
    if #fromShort > lib.W - 10 then fromShort = fromShort:sub(1, lib.W - 12) .. ".." end
    if #toShort > lib.W - 10 then toShort = toShort:sub(1, lib.W - 12) .. ".." end

    mWrite(2, y, "De:", colors.gray, colors.black)
    mWrite(6, y, fromShort, colors.lime, colors.black)
    y = y + 1
    mWrite(2, y, "A:", colors.gray, colors.black)
    mWrite(6, y, toShort, colors.cyan, colors.black)
    y = y + 2

    mFill(2, y, lib.W - 2, 4, colors.gray)
    mWrite(3, y, "Ciclos: " .. ws.cycles, colors.white, colors.gray)
    mWrite(3, y + 1, "Items movidos: " .. ws.totalMoved, colors.yellow, colors.gray)

    if ws.destFull then
        mWrite(3, y + 2, "DESTINO LLENO!", colors.red, colors.gray)
        mWrite(3, y + 3, "Esperando espacio...", colors.orange, colors.gray)
    else
        mWrite(3, y + 2, "Destino: OK", colors.lime, colors.gray)
        local nextCycle = st.workerActive and "Siguiente ciclo pronto..." or "Pausado"
        mWrite(3, y + 3, nextCycle, colors.lightGray, colors.gray)
    end
    y = y + 5

    if #ws.lastItems > 0 then
        mWrite(2, y, "Ultimo ciclo:", colors.gray, colors.black)
        y = y + 1
        local maxShow = math.min(#ws.lastItems, lib.H - y - 5)
        for i = 1, maxShow do
            local item = ws.lastItems[i]
            local shortName = item.name:match(":(.+)") or item.name
            if #shortName > lib.W - 15 then shortName = shortName:sub(1, lib.W - 17) .. ".." end
            mWrite(3, y, shortName, colors.white, colors.black)
            mWrite(lib.W - #("x" .. item.moved) - 2, y, "x" .. item.moved, colors.lime, colors.black)
            y = y + 1
        end
        if #ws.lastItems > maxShow then
            mWrite(3, y, "... +" .. (#ws.lastItems - maxShow) .. " mas", colors.gray, colors.black)
        end
    else
        mWrite(2, y, "Esperando primer ciclo...", colors.gray, colors.black)
    end

    local btnY = lib.H - 4
    if st.workerActive then
        addButton(2, btnY, math.floor(lib.W / 2) - 2, 3, "PAUSAR", colors.white, colors.orange, function()
            worker.pause()
        end)
        addButton(math.floor(lib.W / 2) + 1, btnY, math.floor(lib.W / 2) - 1, 3, "DETENER", colors.white, colors.red, function()
            worker.stop()
            st.screen = "worker_stopped"
        end)
    else
        addButton(2, btnY, math.floor(lib.W / 2) - 2, 3, "REANUDAR", colors.black, colors.lime, function()
            worker.resume()
        end)
        addButton(math.floor(lib.W / 2) + 1, btnY, math.floor(lib.W / 2) - 1, 3, "DETENER", colors.white, colors.red, function()
            st.screen = "worker_stopped"
        end)
    end
end

local function drawWorkerStopped()
    drawHeader("Worker Detenido")

    local ws = st.workerStats
    local y = 4

    local elapsed = os.clock() - ws.startTime
    local elapsedStr
    if elapsed < 60 then
        elapsedStr = math.floor(elapsed) .. " segundos"
    elseif elapsed < 3600 then
        elapsedStr = math.floor(elapsed / 60) .. "m " .. math.floor(elapsed % 60) .. "s"
    else
        elapsedStr = math.floor(elapsed / 3600) .. "h " .. math.floor((elapsed % 3600) / 60) .. "m"
    end

    mFill(2, y, lib.W - 2, 5, colors.gray)
    mWrite(3, y, "RESUMEN DEL WORKER", colors.yellow, colors.gray)
    mWrite(3, y + 1, "Tiempo activo: " .. elapsedStr, colors.white, colors.gray)
    mWrite(3, y + 2, "Ciclos: " .. ws.cycles, colors.white, colors.gray)
    mWrite(3, y + 3, "Total items: " .. ws.totalMoved, colors.lime, colors.gray)
    if ws.destFull then
        mWrite(3, y + 4, "Destino se lleno", colors.orange, colors.gray)
    end
    y = y + 7

    addButton(2, y, math.floor(lib.W / 2) - 2, 3, "REINICIAR", colors.black, colors.yellow, function()
        worker.restart()
        st.screen = "worker_running"
    end)
    addButton(math.floor(lib.W / 2) + 1, y, math.floor(lib.W / 2) - 1, 3, "MENU", colors.white, colors.blue, function()
        st.workerActive = false
        st.workerFrom = nil
        st.workerTo = nil
        st.fromInv = nil
        st.toInv = nil
        st.screen = "menu"
    end)
end

-- ============================================================
--  Pantallas: TAREAS (CRUD)
-- ============================================================

local function drawTasksList()
    drawHeader("Tareas")

    addButton(2, 3, 14, 2, "+ NUEVA TAREA", colors.white, colors.green, function()
        lib.refreshInventories()
        st.screen = "task_new_type"
        st.page = 1
    end)

    if tasks.count() == 0 then
        mWrite(2, 7, "No hay tareas.", colors.gray, colors.black)
        mWrite(2, 8, "Crea una con + NUEVA TAREA", colors.gray, colors.black)
        drawFooter("")
        return
    end

    local y = 6
    local startIdx = (st.page - 1) * st.perPage + 1
    local endIdx = math.min(st.page * st.perPage, #st.tasks)

    for i = startIdx, endIdx do
        if y + 4 > lib.H - 3 then break end
        local t = st.tasks[i]

        local shortName = t.name
        if #shortName > lib.W - 20 then shortName = shortName:sub(1, lib.W - 22) .. ".." end

        local typeLabel = t.type == "drain" and "VACIAR" or "MOVER"
        local loopLabel = t.loop and ("c/" .. t.interval .. "s") or "1 vez"

        local statusCol = colors.lightGray
        if t.status == "running" then statusCol = colors.yellow
        elseif t.status == "done" then statusCol = colors.lime
        elseif t.status == "error" then statusCol = colors.red
        end

        local bg = t.enabled and colors.gray or colors.brown

        mFill(2, y, lib.W - 14, 4, bg)
        mWrite(3, y, "#" .. i .. " " .. shortName, colors.white, bg)
        mWrite(3, y + 1, typeLabel .. " | " .. loopLabel, colors.yellow, bg)

        local fromShort = t.from:sub(1, 10)
        local toShort = t.to:sub(1, 10)
        mWrite(3, y + 2, fromShort .. " > " .. toShort, colors.lightGray, bg)

        -- Status dot
        mWrite(3, y + 3, t.status, statusCol, bg)
        if t.lastResult and t.lastResult.moved then
            mWrite(15, y + 3, "ult:" .. t.lastResult.moved, colors.cyan, bg)
        end

        -- Toggle ON/OFF
        local eLbl = t.enabled and "ON" or "OFF"
        local eCol = t.enabled and colors.green or colors.red
        addButton(lib.W - 12, y, 5, 4, eLbl, colors.white, eCol, function()
            tasks.toggle(i)
        end)

        -- Delete
        addButton(lib.W - 6, y, 5, 4, "DEL", colors.white, colors.red, function()
            tasks.delete(i)
        end)

        y = y + 5
    end

    drawPagination(tasks.count())
    drawFooter(tasks.countEnabled() .. "/" .. tasks.count() .. " activas")
end

-- === Crear tarea: tipo ===
local function drawTaskNewType()
    drawHeader("Tarea: Tipo")

    local y = 4
    mWrite(2, y, "Que tipo de tarea?", colors.lightGray, colors.black)
    y = y + 2

    addButton(3, y, lib.W - 4, 3, "TRANSFERIR ITEM", colors.white, colors.green, function()
        st._taskType = "transfer"
        st.screen = "task_new_from"
        st.page = 1
    end)
    y = y + 4

    addButton(3, y, lib.W - 4, 3, "VACIAR INVENTARIO", colors.white, colors.orange, function()
        st._taskType = "drain"
        st.screen = "task_new_from"
        st.page = 1
    end)
    y = y + 4

    mFill(2, y, lib.W - 2, 3, colors.gray)
    mWrite(3, y, "TRANSFERIR = item especifico", colors.lightGray, colors.gray)
    mWrite(3, y + 1, "VACIAR = todo del inventario", colors.lightGray, colors.gray)
end

-- === Crear tarea: seleccionar item (solo si transfer) ===
local function drawTaskNewItem()
    drawHeader("Tarea: Que Item?")

    if not st.items or #st.items == 0 then
        st.items = lib.getItems(st.fromInv)
        st.searchText = ""
        lib.applyFilter()
    end

    -- Boton buscar
    addButton(lib.W - 13, 3, 12, 1, "BUSCAR", colors.white, colors.orange, function()
        st.screen = "task_search_item"
    end)

    if st.searchText ~= "" then
        mWrite(2, 4, "Filtro: " .. st.searchText, colors.yellow, colors.black)
    end

    local displayItems = st.filteredItems

    if #displayItems == 0 then
        mWrite(2, 6, st.searchText ~= "" and "Sin resultados" or "Inventario vacio", colors.orange, colors.black)
        drawFooter("")
        return
    end

    local startIdx = (st.page - 1) * st.perPage + 1
    local endIdx = math.min(st.page * st.perPage, #displayItems)

    local y = 5
    for i = startIdx, endIdx do
        local item = displayItems[i]
        local shortName = item.name:match(":(.+)") or item.name
        if #shortName > lib.W - 6 then shortName = shortName:sub(1, lib.W - 8) .. ".." end

        local bg = (i % 2 == 0) and colors.blue or colors.gray

        addButton(2, y, lib.W - 2, 3, "", colors.white, bg, function()
            st.selectedItem = item
            st.cantidad = item.total
            st.screen = "task_new_qty"
        end)
        mWrite(4, y, shortName, colors.white, bg)
        mWrite(4, y + 1, "x" .. item.total, colors.yellow, bg)

        y = y + 4
    end

    drawPagination(#displayItems)
    drawFooter(#displayItems .. " items")
end

-- === Crear tarea: buscar item con teclado ===
local function drawTaskSearchItem()
    drawHeader("Buscar Item")

    local y = 4
    for i = 1, math.min(3, #st.filteredItems) do
        local item = st.filteredItems[i]
        local shortName = item.name:match(":(.+)") or item.name
        mWrite(3, y, shortName .. " x" .. item.total, colors.lightGray, colors.black)
        y = y + 1
    end
    if #st.filteredItems > 3 then
        mWrite(3, y, "... +" .. (#st.filteredItems - 3) .. " mas", colors.gray, colors.black)
    end

    lib.drawKeyboard(function()
        st.screen = "task_new_item"
    end)
end

-- === Crear tarea: cantidad (solo si transfer) ===
local function drawTaskNewQty()
    drawHeader("Tarea: Cantidad")

    local shortName = st.selectedItem.name:match(":(.+)") or st.selectedItem.name
    local maxQty = st.selectedItem.total

    mWrite(2, 4, "Item: " .. shortName, colors.white, colors.black)
    mWrite(2, 5, "Disponible ahora: " .. maxQty, colors.gray, colors.black)

    mFill(3, 7, lib.W - 4, 3, colors.gray)
    local qtyStr = tostring(st.cantidad)
    mWrite(math.floor(lib.W / 2) - math.floor(#qtyStr / 2), 8, qtyStr, colors.yellow, colors.gray)

    local y = 11
    addButton(2, y, 7, 2, "-1", colors.white, colors.red, function()
        st.cantidad = math.max(0, st.cantidad - 1)
    end)
    addButton(11, y, 7, 2, "-10", colors.white, colors.red, function()
        st.cantidad = math.max(0, st.cantidad - 10)
    end)
    addButton(20, y, 7, 2, "-64", colors.white, colors.red, function()
        st.cantidad = math.max(0, st.cantidad - 64)
    end)

    y = y + 3
    addButton(2, y, 7, 2, "+1", colors.white, colors.green, function()
        st.cantidad = st.cantidad + 1
    end)
    addButton(11, y, 7, 2, "+10", colors.white, colors.green, function()
        st.cantidad = st.cantidad + 10
    end)
    addButton(20, y, 7, 2, "+64", colors.white, colors.green, function()
        st.cantidad = st.cantidad + 64
    end)

    y = y + 3
    addButton(2, y, 10, 2, "TODO (0)", colors.white, colors.purple, function()
        st.cantidad = 0
    end)
    addButton(14, y, 10, 2, "1 STACK", colors.white, colors.purple, function()
        st.cantidad = 64
    end)

    y = y + 3
    mWrite(2, y, "0 = todo lo disponible", colors.gray, colors.black)

    y = y + 2
    addButton(3, y, lib.W - 4, 3, "SIGUIENTE >>", colors.white, colors.blue, function()
        lib.refreshInventories()
        st.screen = "task_new_to"
        st.page = 1
    end)
end

-- === Crear tarea: intervalo y loop ===
local function drawTaskNewConfig()
    drawHeader("Tarea: Configurar")

    local y = 4

    -- Resumen hasta ahora
    local typeLabel = st._taskType == "drain" and "VACIAR" or "TRANSFERIR"
    local itemLabel = st._taskType == "drain" and "todo" or (st.selectedItem and (st.selectedItem.name:match(":(.+)") or st.selectedItem.name) or "?")
    local fromShort = st.fromInv.name:sub(1, 15)
    local toShort = st.toInv.name:sub(1, 15)

    mFill(2, y, lib.W - 2, 4, colors.gray)
    mWrite(3, y, typeLabel .. ": " .. itemLabel, colors.white, colors.gray)
    if st._taskType == "transfer" then
        local qLabel = st.cantidad == 0 and "todo" or ("x" .. st.cantidad)
        mWrite(3, y + 1, "Cantidad: " .. qLabel, colors.yellow, colors.gray)
    end
    mWrite(3, y + 2, fromShort, colors.lime, colors.gray)
    mWrite(3, y + 3, "  -> " .. toShort, colors.cyan, colors.gray)
    y = y + 6

    -- Loop?
    mWrite(2, y, "Repetir?", colors.lightGray, colors.black)
    y = y + 2

    local loopOn = st._taskLoop ~= false
    addButton(2, y, math.floor(lib.W / 2) - 2, 3, "EN LOOP", colors.white, loopOn and colors.green or colors.gray, function()
        st._taskLoop = true
    end)
    addButton(math.floor(lib.W / 2) + 1, y, math.floor(lib.W / 2) - 1, 3, "UNA VEZ", colors.white, (not loopOn) and colors.green or colors.gray, function()
        st._taskLoop = false
    end)
    y = y + 4

    -- Intervalo
    if st._taskLoop ~= false then
        mWrite(2, y, "Intervalo:", colors.lightGray, colors.black)
        y = y + 1

        local intervals = { 5, 10, 30, 60, 120 }
        local btnW = math.floor((lib.W - 4) / #intervals)
        for idx, val in ipairs(intervals) do
            local bx = 2 + (idx - 1) * btnW
            local label = val < 60 and (val .. "s") or (math.floor(val / 60) .. "m")
            local bg = (st._taskInterval or 10) == val and colors.green or colors.blue
            addButton(bx, y, btnW - 1, 3, label, colors.white, bg, function()
                st._taskInterval = val
            end)
        end
        y = y + 4
    end

    -- Crear
    addButton(3, y, lib.W - 4, 3, "CREAR TAREA", colors.black, colors.lime, function()
        local itemName = st._taskType == "drain" and "*" or (st.selectedItem and st.selectedItem.name or "*")
        local shortItem = itemName == "*" and "todo" or (itemName:match(":(.+)") or itemName)
        local autoName = shortItem:sub(1, 12) .. " > " .. st.toInv.name:sub(1, 10)

        tasks.create({
            name     = autoName,
            type     = st._taskType,
            from     = st.fromInv.name,
            to       = st.toInv.name,
            item     = itemName,
            cantidad = st._taskType == "drain" and 0 or (st.cantidad or 0),
            interval = st._taskInterval or 10,
            loop     = st._taskLoop ~= false,
        })

        -- Reset temp
        st._taskType = nil
        st._taskLoop = nil
        st._taskInterval = nil
        st.fromInv = nil
        st.toInv = nil
        st.selectedItem = nil
        st.screen = "tasks_list"
        st.page = 1
    end)
end

-- ============================================================
--  Tabla de pantallas
-- ============================================================

function ui.getScreens()
    return {
        menu              = drawMenu,
        -- Transfer manual
        select_from       = function() drawSelectInv("Origen: De donde?", "select_item", "fromInv") end,
        select_item       = drawSelectItem,
        search_item       = drawSearchItem,
        select_qty        = drawSelectQty,
        select_to         = function() drawSelectInv("Destino: A donde?", "confirm", "toInv") end,
        confirm           = drawConfirm,
        executing         = drawExecuting,
        result            = drawResult,
        -- Bulk (vaciar)
        bulk_from         = function() drawSelectInv("Vaciar: Origen", "bulk_to", "fromInv") end,
        bulk_to           = function() drawSelectInv("Vaciar: Destino", "bulk_confirm", "toInv") end,
        bulk_confirm      = drawBulkConfirm,
        bulk_executing    = drawBulkExecuting,
        bulk_result       = drawBulkResult,
        -- Reglas
        rules_list        = drawRulesList,
        rule_new_from     = function() drawSelectInv("Regla: Origen", "rule_new_item", "fromInv") end,
        rule_new_item     = drawRuleNewItem,
        rule_new_to       = function() drawSelectInv("Regla: Destino", "rule_new_interval", "toInv") end,
        rule_new_interval = drawRuleNewInterval,
        -- Historial
        history           = drawHistory,
        -- Ver inventarios
        view_invs         = drawViewInvs,
        -- Worker
        worker_from       = function() drawSelectInv("Worker: Origen", "worker_to", "fromInv") end,
        worker_to         = function() drawSelectInv("Worker: Destino", "worker_interval", "toInv") end,
        worker_interval   = drawWorkerInterval,
        worker_confirm    = drawWorkerConfirm,
        worker_running    = drawWorkerRunning,
        worker_stopped    = drawWorkerStopped,
        -- Tareas CRUD
        tasks_list        = drawTasksList,
        task_new_type     = drawTaskNewType,
        task_new_from     = function() drawSelectInv("Tarea: Origen", st._taskType == "drain" and "task_new_to" or "task_new_item", "fromInv") end,
        task_new_item     = drawTaskNewItem,
        task_search_item  = drawTaskSearchItem,
        task_new_qty      = drawTaskNewQty,
        task_new_to       = function() drawSelectInv("Tarea: Destino", "task_new_config", "toInv") end,
        task_new_config   = drawTaskNewConfig,
    }
end

-- ============================================================
--  Render
-- ============================================================

function ui.render()
    lib.buttons = {}
    mClear(colors.black)

    local screens = ui.getScreens()
    local fn = screens[st.screen]
    if fn then fn() end
end

function ui.handleTouch(x, y)
    for _, btn in ipairs(lib.buttons) do
        if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
            btn.action()
            return true
        end
    end
    return false
end

return ui
