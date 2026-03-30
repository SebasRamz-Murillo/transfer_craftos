-- ============================================================
--  transfer_ui.lua  v5.1
--  Sistema multi-monitor con contextos independientes.
--  5 monitores: 3 interactivos (3x3) + 2 dashboards (2x7)
-- ============================================================

local lib    = require("transfer_lib")
local tasks  = require("transfer_tasks")
local worker = require("transfer_worker")

local ui = {}
local st = lib.state

-- ============================================================
--  Monitor Context: cada monitor tiene su propio contexto
-- ============================================================

local function newCtx(monPeriph, monName, label, scale)
    if not monPeriph then return nil end
    local ctx = {}
    ctx.mon     = monPeriph
    ctx.monName = monName
    ctx.label   = label
    ctx.dirty   = true

    monPeriph.setTextScale(scale or 0.5)
    ctx.W, ctx.H = monPeriph.getSize()
    ctx.buttons = {}
    ctx.nav = {
        screen       = "menu",
        page         = 1,
        perPage      = math.max(1, math.floor((ctx.H - 8) / 3)),
        fromInv      = nil,
        toInv        = nil,
        selectedItem = nil,
        cantidad     = 0,
        searchText   = "",
        items        = {},
        filteredItems = {},
        bulkResult   = nil,
        _taskType    = nil,
        _taskLoop    = true,
        _taskInterval = 10,
    }

    function ctx:clear(bg)
        self.mon.setBackgroundColor(bg or colors.black)
        self.mon.clear()
        self.buttons = {}
    end

    function ctx:write(x, y, text, fg, bg)
        self.mon.setCursorPos(x, y)
        if fg then self.mon.setTextColor(fg) end
        if bg then self.mon.setBackgroundColor(bg) end
        self.mon.write(text)
    end

    function ctx:fill(x, y, w, h, bg)
        self.mon.setBackgroundColor(bg)
        for row = y, y + h - 1 do
            self.mon.setCursorPos(x, row)
            self.mon.write(string.rep(" ", w))
        end
    end

    function ctx:btn(x, y, w, h, label, fg, bg, action)
        self:fill(x, y, w, h, bg)
        local tx = x + math.floor((w - #label) / 2)
        local ty = y + math.floor(h / 2)
        if tx < x then tx = x end
        self:write(tx, ty, label, fg, bg)
        table.insert(self.buttons, {
            x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1,
            action = action,
        })
    end

    function ctx:header(title)
        self:fill(1, 1, self.W, 2, colors.gray)
        self:write(2, 1, self.label, colors.yellow, colors.gray)
        self:write(2, 2, title, colors.white, colors.gray)
        if self.nav.screen ~= "menu" then
            self:btn(self.W - 11, 1, 12, 2, "< MENU", colors.white, colors.red, function()
                self.nav.screen = "menu"
                self.nav.page = 1
                self.nav.searchText = ""
            end)
        end
    end

    function ctx:footer(text)
        self:fill(1, self.H, self.W, 1, colors.gray)
        self:write(2, self.H, text or "", colors.lightGray, colors.gray)
    end

    function ctx:paginate(totalItems)
        local tp = math.ceil(totalItems / self.nav.perPage)
        if tp <= 1 then return end
        local y = self.H - 2
        self:fill(1, y, self.W, 2, colors.black)
        if self.nav.page > 1 then
            self:btn(2, y, 10, 2, "< PREV", colors.white, colors.cyan, function()
                self.nav.page = self.nav.page - 1
            end)
        end
        self:write(math.floor(self.W / 2) - 3, y, self.nav.page .. "/" .. tp, colors.gray, colors.black)
        if self.nav.page < tp then
            self:btn(self.W - 11, y, 10, 2, "NEXT >", colors.white, colors.cyan, function()
                self.nav.page = self.nav.page + 1
            end)
        end
    end

    function ctx:handleTouch(x, y)
        for _, b in ipairs(self.buttons) do
            if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
                b.action()
                self.dirty = true
                return true
            end
        end
        return false
    end

    return ctx
end

-- ============================================================
--  Componentes compartidos
-- ============================================================

local function compSelectInv(ctx, title, onSelect, filterOut)
    ctx:header(title)
    local invs = st.inventories
    if #invs == 0 then
        ctx:write(2, 5, "No hay inventarios", colors.red, colors.black)
        ctx:footer("Conecta inventarios con cables")
        return
    end
    local pp = ctx.nav.perPage
    local si = (ctx.nav.page - 1) * pp + 1
    local ei = math.min(ctx.nav.page * pp, #invs)
    local y = 4
    for i = si, ei do
        local inv = invs[i]
        local name = inv.name
        if #name > ctx.W - 6 then name = name:sub(1, ctx.W - 8) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        local fg = colors.white
        if filterOut and inv.name == filterOut then bg = colors.brown; fg = colors.red end
        ctx:btn(2, y, ctx.W - 2, 3, "", fg, bg, function()
            if filterOut and inv.name == filterOut then return end
            onSelect(inv)
        end)
        ctx:write(4, y + 1, name, fg, bg)
        ctx:write(ctx.W - 9, y + 1, inv.size .. " sl", colors.lightGray, bg)
        y = y + 4
    end
    ctx:paginate(#invs)
    ctx:footer(#invs .. " inventarios")
end

local function compItemList(ctx, title, onSelect)
    ctx:header(title)
    local n = ctx.nav
    if n.searchText ~= "" then
        ctx:write(2, 3, "Filtro: " .. n.searchText, colors.yellow, colors.black)
    end
    ctx:btn(ctx.W - 13, 3, 12, 1, "BUSCAR", colors.white, colors.orange, function()
        n._returnScreen = n.screen
        n.screen = n.screen .. "_search"
    end)
    local di = n.filteredItems
    if #di == 0 then
        ctx:write(2, 5, n.searchText ~= "" and "Sin resultados" or "Vacio", colors.orange, colors.black)
        return
    end
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #di)
    local y = 5
    for i = si, ei do
        local item = di[i]
        local sn = item.name:match(":(.+)") or item.name
        if #sn > ctx.W - 6 then sn = sn:sub(1, ctx.W - 8) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 3, "", colors.white, bg, function() onSelect(item) end)
        ctx:write(4, y, sn, colors.white, bg)
        ctx:write(4, y + 1, "x" .. item.total, colors.yellow, bg)
        y = y + 4
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items")
end

local function compKeyboard(ctx, onConfirm)
    local n = ctx.nav
    local keys = { "A B C D E F G H I", "J K L M N O P Q R", "S T U V W X Y Z _" }
    local y = ctx.H - 8
    ctx:fill(2, y - 2, ctx.W - 2, 2, colors.gray)
    local disp = n.searchText == "" and "Escribe para filtrar..." or n.searchText
    ctx:write(3, y - 1, disp, n.searchText == "" and colors.lightGray or colors.yellow, colors.gray)
    for row, line in ipairs(keys) do
        local col = 2
        for char in line:gmatch("%S+") do
            ctx:btn(col, y + (row - 1) * 2, 3, 2, char, colors.white, colors.blue, function()
                n.searchText = n.searchText .. char:lower()
                lib.applyFilter(n)
            end)
            col = col + 4
        end
    end
    local sy = y + #keys * 2
    ctx:btn(2, sy, 8, 2, "BORRAR", colors.white, colors.orange, function()
        if #n.searchText > 0 then n.searchText = n.searchText:sub(1, -2); lib.applyFilter(n) end
    end)
    ctx:btn(12, sy, 8, 2, "LIMPIAR", colors.white, colors.red, function()
        n.searchText = ""; lib.applyFilter(n)
    end)
    ctx:btn(22, sy, 8, 2, "OK", colors.white, colors.green, function()
        if onConfirm then onConfirm() end
    end)
end

local function compQtySelector(ctx, title, maxQty, allowZero, onConfirm)
    ctx:header(title)
    local n = ctx.nav
    local sn = n.selectedItem and (n.selectedItem.name:match(":(.+)") or n.selectedItem.name) or "?"
    ctx:write(2, 4, "Item: " .. sn, colors.white, colors.black)
    if maxQty > 0 then ctx:write(2, 5, "Disponible: " .. maxQty, colors.gray, colors.black) end
    ctx:fill(3, 7, ctx.W - 4, 3, colors.gray)
    local qs = n.cantidad == 0 and "TODO" or tostring(n.cantidad)
    ctx:write(math.floor(ctx.W / 2) - math.floor(#qs / 2), 8, qs, colors.yellow, colors.gray)
    local y = 11
    local lo = allowZero and 0 or 1
    ctx:btn(2, y, 7, 2, "-1",  colors.white, colors.red, function() n.cantidad = math.max(lo, n.cantidad - 1) end)
    ctx:btn(11, y, 7, 2, "-10", colors.white, colors.red, function() n.cantidad = math.max(lo, n.cantidad - 10) end)
    ctx:btn(20, y, 7, 2, "-64", colors.white, colors.red, function() n.cantidad = math.max(lo, n.cantidad - 64) end)
    y = y + 3
    local hi = maxQty > 0 and maxQty or 99999
    ctx:btn(2, y, 7, 2, "+1",  colors.white, colors.green, function() n.cantidad = math.min(hi, n.cantidad + 1) end)
    ctx:btn(11, y, 7, 2, "+10", colors.white, colors.green, function() n.cantidad = math.min(hi, n.cantidad + 10) end)
    ctx:btn(20, y, 7, 2, "+64", colors.white, colors.green, function() n.cantidad = math.min(hi, n.cantidad + 64) end)
    y = y + 3
    ctx:btn(2, y, 10, 2, "TODO", colors.white, colors.purple, function() n.cantidad = allowZero and 0 or maxQty end)
    if maxQty > 0 then
        ctx:btn(14, y, 10, 2, "1 STACK", colors.white, colors.purple, function() n.cantidad = math.min(64, maxQty) end)
    end
    y = y + 3
    if allowZero then ctx:write(2, y, "0 = todo lo disponible", colors.gray, colors.black); y = y + 1 end
    y = y + 1
    ctx:btn(3, y, ctx.W - 4, 3, "SIGUIENTE >>", colors.white, colors.blue, function()
        lib.refreshInventories()
        if onConfirm then onConfirm() end
    end)
end

-- Helper: format elapsed time
local function fmtElapsed(secs)
    if secs < 60 then return math.floor(secs) .. "s"
    elseif secs < 3600 then return math.floor(secs / 60) .. "m " .. math.floor(secs % 60) .. "s"
    else return math.floor(secs / 3600) .. "h " .. math.floor((secs % 3600) / 60) .. "m" end
end

-- Helper: short name
local function sn(name) return name:match(":(.+)") or name end

-- ============================================================
--  MONITOR 14: CONTROL (3x3, interactivo)
--  Transferir, Vaciar, Worker
-- ============================================================
local scr14 = {}

function scr14.menu(ctx)
    ctx:header("Menu Principal")
    local y = 4
    ctx:write(2, y, "Transferencias", colors.lightGray, colors.black); y = y + 2
    ctx:btn(3, y, ctx.W - 4, 3, "TRANSFERIR ITEM", colors.white, colors.green, function()
        lib.refreshInventories(); ctx.nav.screen = "xfer_from"; ctx.nav.page = 1
    end); y = y + 4
    ctx:btn(3, y, ctx.W - 4, 3, "VACIAR INVENTARIO", colors.white, colors.orange, function()
        lib.refreshInventories(); ctx.nav.screen = "bulk_from"; ctx.nav.page = 1
    end); y = y + 4
    ctx:btn(3, y, ctx.W - 4, 3, "WORKER (LOOP)", colors.black, colors.yellow, function()
        lib.refreshInventories(); ctx.nav.screen = "wk_from"; ctx.nav.page = 1
    end); y = y + 4
    -- Worker status
    if st.workerActive then
        local ws = st.workerStats
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, "Worker ACTIVO", colors.white, colors.green)
        ctx:write(3, y + 1, "Ciclos:" .. ws.cycles .. " Items:" .. ws.totalMoved, colors.yellow, colors.green)
        y = y + 3
        ctx:btn(3, y, ctx.W - 4, 2, "VER WORKER", colors.black, colors.lime, function()
            ctx.nav.screen = "wk_running"
        end)
    end
    ctx:footer("Inv: " .. #st.inventories)
end

-- Transfer flow
function scr14.xfer_from(ctx)
    compSelectInv(ctx, "Transferir: Origen", function(inv)
        ctx.nav.fromInv = inv
        ctx.nav.items = lib.getItems(inv)
        ctx.nav.searchText = ""
        lib.applyFilter(ctx.nav)
        ctx.nav.screen = "xfer_item"; ctx.nav.page = 1
    end)
end

function scr14.xfer_item(ctx)
    compItemList(ctx, "Seleccionar Item", function(item)
        ctx.nav.selectedItem = item
        ctx.nav.cantidad = item.total
        ctx.nav.screen = "xfer_qty"
    end)
end

function scr14.xfer_item_search(ctx)
    ctx:header("Buscar Item")
    local n = ctx.nav
    local y = 4
    for i = 1, math.min(3, #n.filteredItems) do
        local item = n.filteredItems[i]
        ctx:write(3, y, sn(item.name) .. " x" .. item.total, colors.lightGray, colors.black)
        y = y + 1
    end
    if #n.filteredItems > 3 then ctx:write(3, y, "+" .. (#n.filteredItems - 3) .. " mas", colors.gray, colors.black) end
    compKeyboard(ctx, function() n.screen = "xfer_item" end)
end

function scr14.xfer_qty(ctx)
    compQtySelector(ctx, "Cantidad", ctx.nav.selectedItem.total, false, function()
        ctx.nav.screen = "xfer_to"; ctx.nav.page = 1
    end)
end

function scr14.xfer_to(ctx)
    compSelectInv(ctx, "Transferir: Destino", function(inv)
        ctx.nav.toInv = inv
        ctx.nav.screen = "xfer_confirm"
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr14.xfer_confirm(ctx)
    ctx:header("Confirmar")
    local n = ctx.nav
    local si = sn(n.selectedItem.name)
    local y = 4
    ctx:write(2, y, "Item: " .. si, colors.white, colors.black); y = y + 1
    ctx:write(2, y, "Cant: " .. n.cantidad, colors.yellow, colors.black); y = y + 2
    ctx:write(2, y, "De: " .. n.fromInv.name, colors.lime, colors.black); y = y + 1
    ctx:write(2, y, "A:  " .. n.toInv.name, colors.cyan, colors.black); y = y + 3
    ctx:btn(2, y, math.floor(ctx.W / 2) - 2, 3, "CANCELAR", colors.white, colors.red, function()
        n.screen = "menu"
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 3, "EJECUTAR", colors.white, colors.green, function()
        n.screen = "xfer_exec"
    end)
end

function scr14.xfer_exec(ctx)
    ctx:header("Transfiriendo...")
    local n = ctx.nav
    ctx:write(2, 5, "Moviendo...", colors.yellow, colors.black)
    local movido = lib.moveItems(n.fromInv.peripheral, n.toInv.name, n.selectedItem.name, n.cantidad)
    n._moved = movido
    if movido > 0 then
        lib.tLog("OK: " .. movido .. "x " .. sn(n.selectedItem.name) .. " -> " .. n.toInv.name)
    else
        lib.tLog("ERROR: No se movio " .. sn(n.selectedItem.name))
    end
    lib.addHistory(n.fromInv.name, n.toInv.name, n.selectedItem.name, n.cantidad, movido)
    n.screen = "xfer_result"
end

function scr14.xfer_result(ctx)
    ctx:header("Resultado")
    local n = ctx.nav
    local y = 5
    if n._moved >= n.cantidad then
        ctx:fill(2, y, ctx.W - 2, 3, colors.green)
        ctx:write(4, y + 1, "LISTO! " .. n._moved .. "/" .. n.cantidad, colors.white, colors.green)
    elseif n._moved > 0 then
        ctx:fill(2, y, ctx.W - 2, 3, colors.orange)
        ctx:write(4, y + 1, "PARCIAL: " .. n._moved .. "/" .. n.cantidad, colors.white, colors.orange)
    else
        ctx:fill(2, y, ctx.W - 2, 3, colors.red)
        ctx:write(4, y + 1, "FALLO: 0 items", colors.white, colors.red)
    end
    y = y + 5
    ctx:btn(3, y, ctx.W - 4, 3, "VOLVER", colors.white, colors.blue, function()
        n.screen = "menu"; n.fromInv = nil; n.toInv = nil; n.selectedItem = nil; n.page = 1
    end)
end

-- Bulk flow
function scr14.bulk_from(ctx)
    compSelectInv(ctx, "Vaciar: Origen", function(inv)
        ctx.nav.fromInv = inv; ctx.nav.screen = "bulk_to"; ctx.nav.page = 1
    end)
end

function scr14.bulk_to(ctx)
    compSelectInv(ctx, "Vaciar: Destino", function(inv)
        ctx.nav.toInv = inv; ctx.nav.screen = "bulk_confirm"
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr14.bulk_confirm(ctx)
    ctx:header("Vaciar Inventario")
    local n = ctx.nav
    local items = lib.getItems(n.fromInv)
    local total = 0
    for _, item in ipairs(items) do total = total + item.total end
    local y = 4
    ctx:write(2, y, "ORIGEN:", colors.gray, colors.black); y = y + 1
    ctx:write(3, y, n.fromInv.name, colors.lime, colors.black); y = y + 1
    ctx:write(3, y, #items .. " tipos | " .. total .. " items", colors.yellow, colors.black); y = y + 2
    ctx:write(2, y, "DESTINO:", colors.gray, colors.black); y = y + 1
    ctx:write(3, y, n.toInv.name, colors.cyan, colors.black); y = y + 2
    ctx:fill(2, y, ctx.W - 2, 2, colors.orange)
    ctx:write(3, y, "Se moveran TODOS los items", colors.white, colors.orange); y = y + 4
    ctx:btn(2, y, math.floor(ctx.W / 2) - 2, 3, "CANCELAR", colors.white, colors.red, function() n.screen = "menu" end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 3, "VACIAR", colors.white, colors.green, function()
        n.screen = "bulk_exec"
    end)
end

function scr14.bulk_exec(ctx)
    ctx:header("Vaciando...")
    ctx:write(2, 4, "Transfiriendo...", colors.yellow, colors.black)
    local n = ctx.nav
    local result = lib.moveAllItems(n.fromInv, n.toInv, function(prog)
        ctx:fill(1, 5, ctx.W, ctx.H - 6, colors.black)
        local pct = prog.total > 0 and math.floor(prog.processed / prog.total * 100) or 0
        local bw = ctx.W - 6
        local filled = math.floor(bw * pct / 100)
        ctx:write(2, 6, "Progreso:", colors.gray, colors.black)
        ctx:fill(3, 7, bw, 2, colors.gray)
        if filled > 0 then ctx:fill(3, 7, filled, 2, colors.green) end
        ctx:write(math.floor(ctx.W / 2) - 2, 7, pct .. "%", colors.white, colors.gray)
        ctx:write(3, 10, "Slots: " .. prog.processed .. "/" .. prog.total, colors.lightGray, colors.black)
        ctx:write(3, 11, "Items: " .. prog.moved, colors.yellow, colors.black)
        if prog.current then ctx:write(3, 13, "Moviendo: " .. sn(prog.current), colors.cyan, colors.black) end
        if prog.destFull then
            ctx:fill(2, 15, ctx.W - 2, 1, colors.red)
            ctx:write(3, 15, "DESTINO LLENO!", colors.white, colors.red)
        end
        ctx:footer("No tocar...")
    end)
    n.bulkResult = result
    lib.tLog("LISTO: Vaciado " .. n.fromInv.name .. " -> " .. result.total .. " items")
    for _, item in ipairs(result.items) do
        if item.moved > 0 then lib.addHistory(n.fromInv.name, n.toInv.name, item.name, item.moved + item.failed, item.moved) end
    end
    n.screen = "bulk_result"
end

function scr14.bulk_result(ctx)
    ctx:header("Resultado")
    local r = ctx.nav.bulkResult
    local y = 4
    if r.destFull then
        ctx:fill(2, y, ctx.W - 2, 3, colors.orange)
        ctx:write(3, y, "DESTINO LLENO", colors.white, colors.orange)
        ctx:write(3, y + 1, r.total .. "/" .. r.totalOriginal .. " items", colors.white, colors.orange)
    elseif r.total > 0 then
        ctx:fill(2, y, ctx.W - 2, 3, colors.green)
        ctx:write(3, y, "COMPLETADO!", colors.white, colors.green)
        ctx:write(3, y + 1, r.total .. " items movidos", colors.yellow, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 3, colors.red)
        ctx:write(3, y + 1, "FALLO: 0 items", colors.white, colors.red)
    end
    y = y + 4
    local maxD = math.min(#r.items, ctx.H - y - 5)
    for i = 1, maxD do
        local it = r.items[i]
        local n2 = sn(it.name)
        if #n2 > ctx.W - 15 then n2 = n2:sub(1, ctx.W - 17) .. ".." end
        ctx:write(3, y, n2, colors.white, colors.black)
        ctx:write(ctx.W - #("x" .. it.moved) - 2, y, "x" .. it.moved, it.failed > 0 and colors.orange or colors.lime, colors.black)
        y = y + 1
    end
    y = y + 2
    ctx:btn(3, y, ctx.W - 4, 3, "VOLVER", colors.white, colors.blue, function()
        ctx.nav.screen = "menu"; ctx.nav.fromInv = nil; ctx.nav.toInv = nil
    end)
end

-- Worker flow
function scr14.wk_from(ctx)
    compSelectInv(ctx, "Worker: Origen", function(inv)
        ctx.nav.fromInv = inv; ctx.nav.screen = "wk_to"; ctx.nav.page = 1
    end)
end

function scr14.wk_to(ctx)
    compSelectInv(ctx, "Worker: Destino", function(inv)
        ctx.nav.toInv = inv; ctx.nav.screen = "wk_interval"
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr14.wk_interval(ctx)
    ctx:header("Worker: Intervalo")
    local y = 4
    ctx:write(2, y, "Cada cuantos segundos?", colors.lightGray, colors.black); y = y + 2
    ctx:fill(2, y, ctx.W - 2, 3, colors.gray)
    ctx:write(math.floor(ctx.W / 2) - 3, y + 1, st.workerInterval .. " seg", colors.yellow, colors.gray); y = y + 4
    local presets = { 1, 2, 5, 10, 15, 30, 60 }
    local bw = math.floor((ctx.W - 4) / #presets)
    for idx, val in ipairs(presets) do
        local bx = 2 + (idx - 1) * bw
        ctx:btn(bx, y, bw - 1, 3, tostring(val), colors.white, val == st.workerInterval and colors.green or colors.blue, function()
            st.workerInterval = val
        end)
    end
    y = y + 4
    ctx:btn(2, y, 8, 3, "- 1s", colors.white, colors.orange, function() st.workerInterval = math.max(1, st.workerInterval - 1) end)
    ctx:btn(ctx.W - 9, y, 8, 3, "+ 1s", colors.white, colors.cyan, function() st.workerInterval = math.min(300, st.workerInterval + 1) end)
    y = y + 4
    ctx:btn(3, y, ctx.W - 4, 3, "CONTINUAR", colors.white, colors.green, function() ctx.nav.screen = "wk_confirm" end)
end

function scr14.wk_confirm(ctx)
    ctx:header("Worker: Confirmar")
    local n = ctx.nav; local y = 4
    ctx:write(2, y, "ORIGEN:", colors.gray, colors.black); y = y + 1
    ctx:write(3, y, n.fromInv.name, colors.lime, colors.black); y = y + 2
    ctx:write(2, y, "DESTINO:", colors.gray, colors.black); y = y + 1
    ctx:write(3, y, n.toInv.name, colors.cyan, colors.black); y = y + 2
    ctx:write(2, y, "Cada " .. st.workerInterval .. " segundos", colors.yellow, colors.black); y = y + 2
    ctx:fill(2, y, ctx.W - 2, 2, colors.yellow)
    ctx:write(3, y, "Vaciara TODO de forma CONTINUA", colors.black, colors.yellow); y = y + 4
    ctx:btn(2, y, math.floor(ctx.W / 2) - 2, 3, "CANCELAR", colors.white, colors.red, function() n.screen = "menu" end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 3, "INICIAR", colors.black, colors.lime, function()
        worker.start(n.fromInv, n.toInv, st.workerInterval)
        n.screen = "wk_running"
    end)
end

function scr14.wk_running(ctx)
    ctx:header("Worker ACTIVO")
    local ws = st.workerStats; local y = 4
    local el = fmtElapsed(os.clock() - ws.startTime)
    if st.workerActive then
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, "ACTIVO", colors.white, colors.green)
        ctx:write(ctx.W - #el - 3, y, el, colors.white, colors.green)
        ctx:write(3, y + 1, "c/" .. st.workerInterval .. "s", colors.yellow, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 2, colors.red)
        ctx:write(3, y, "PAUSADO", colors.white, colors.red)
        ctx:write(ctx.W - #el - 3, y, el, colors.white, colors.red)
    end
    y = y + 3
    local fn = st.workerFrom and st.workerFrom.name or "?"
    local tn = st.workerTo and st.workerTo.name or "?"
    if #fn > ctx.W - 8 then fn = fn:sub(1, ctx.W - 10) .. ".." end
    if #tn > ctx.W - 8 then tn = tn:sub(1, ctx.W - 10) .. ".." end
    ctx:write(2, y, "De: " .. fn, colors.lime, colors.black); y = y + 1
    ctx:write(2, y, "A:  " .. tn, colors.cyan, colors.black); y = y + 2
    ctx:fill(2, y, ctx.W - 2, 3, colors.gray)
    ctx:write(3, y, "Ciclos: " .. ws.cycles, colors.white, colors.gray)
    ctx:write(3, y + 1, "Items: " .. ws.totalMoved, colors.yellow, colors.gray)
    ctx:write(3, y + 2, ws.destFull and "DESTINO LLENO!" or "OK", ws.destFull and colors.red or colors.lime, colors.gray)
    y = y + 4
    if #ws.lastItems > 0 then
        ctx:write(2, y, "Ultimo ciclo:", colors.gray, colors.black); y = y + 1
        for i = 1, math.min(#ws.lastItems, ctx.H - y - 5) do
            local it = ws.lastItems[i]
            ctx:write(3, y, sn(it.name), colors.white, colors.black)
            ctx:write(ctx.W - #("x" .. it.moved) - 2, y, "x" .. it.moved, colors.lime, colors.black)
            y = y + 1
        end
    end
    local by = ctx.H - 4
    if st.workerActive then
        ctx:btn(2, by, math.floor(ctx.W / 2) - 2, 3, "PAUSAR", colors.white, colors.orange, function() worker.pause() end)
        ctx:btn(math.floor(ctx.W / 2) + 1, by, math.floor(ctx.W / 2) - 1, 3, "DETENER", colors.white, colors.red, function()
            worker.stop(); ctx.nav.screen = "wk_stopped"
        end)
    else
        ctx:btn(2, by, math.floor(ctx.W / 2) - 2, 3, "REANUDAR", colors.black, colors.lime, function() worker.resume() end)
        ctx:btn(math.floor(ctx.W / 2) + 1, by, math.floor(ctx.W / 2) - 1, 3, "DETENER", colors.white, colors.red, function()
            ctx.nav.screen = "wk_stopped"
        end)
    end
end

function scr14.wk_stopped(ctx)
    ctx:header("Worker Detenido")
    local ws = st.workerStats; local y = 4
    ctx:fill(2, y, ctx.W - 2, 4, colors.gray)
    ctx:write(3, y, "RESUMEN", colors.yellow, colors.gray)
    ctx:write(3, y + 1, "Tiempo: " .. fmtElapsed(os.clock() - ws.startTime), colors.white, colors.gray)
    ctx:write(3, y + 2, "Ciclos: " .. ws.cycles, colors.white, colors.gray)
    ctx:write(3, y + 3, "Items: " .. ws.totalMoved, colors.lime, colors.gray)
    y = y + 6
    ctx:btn(2, y, math.floor(ctx.W / 2) - 2, 3, "REINICIAR", colors.black, colors.yellow, function()
        worker.restart(); ctx.nav.screen = "wk_running"
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 3, "MENU", colors.white, colors.blue, function()
        st.workerActive = false; st.workerFrom = nil; st.workerTo = nil
        ctx.nav.screen = "menu"
    end)
end

-- ============================================================
--  MONITOR 10: AUTOMATIZAR (3x3, interactivo)
--  Tareas CRUD + Reglas
-- ============================================================
local scr10 = {}

function scr10.menu(ctx)
    ctx:header("Automatizacion")
    local y = 4
    ctx:btn(3, y, ctx.W - 4, 3, "TAREAS (" .. tasks.countEnabled() .. "/" .. tasks.count() .. ")", colors.white, colors.blue, function()
        ctx.nav.screen = "tasks_list"; ctx.nav.page = 1
    end); y = y + 4
    ctx:btn(3, y, ctx.W - 4, 3, "REGLAS (" .. #st.rules .. ")", colors.white, colors.purple, function()
        ctx.nav.screen = "rules_list"; ctx.nav.page = 1
    end); y = y + 4
    -- Quick status
    if tasks.count() > 0 then
        ctx:write(2, y, "Tareas activas:", colors.gray, colors.black); y = y + 1
        for i, t in ipairs(st.tasks) do
            if i > 5 then break end
            local sc = colors.lightGray
            if t.status == "running" then sc = colors.yellow
            elseif t.status == "done" then sc = colors.lime
            elseif t.status == "error" then sc = colors.red end
            local lbl = (t.enabled and "+" or "-") .. " " .. t.name:sub(1, ctx.W - 6)
            ctx:write(3, y, lbl, sc, colors.black); y = y + 1
        end
    end
    local rs = st.rulesRunning and "ON" or "OFF"
    ctx:footer("Reglas: " .. rs .. " | Tareas: " .. tasks.countEnabled())
end

-- Tasks list
function scr10.tasks_list(ctx)
    ctx:header("Tareas")
    ctx:btn(2, 3, 14, 2, "+ NUEVA", colors.white, colors.green, function()
        lib.refreshInventories(); ctx.nav.screen = "task_type"; ctx.nav.page = 1
    end)
    if tasks.count() == 0 then
        ctx:write(2, 7, "No hay tareas.", colors.gray, colors.black); return
    end
    local y = 6; local n = ctx.nav
    local si = (n.page - 1) * n.perPage + 1
    local ei = math.min(n.page * n.perPage, #st.tasks)
    for i = si, ei do
        if y + 4 > ctx.H - 3 then break end
        local t = st.tasks[i]
        local bg = t.enabled and colors.gray or colors.brown
        local sc = colors.lightGray
        if t.status == "running" then sc = colors.yellow
        elseif t.status == "done" then sc = colors.lime
        elseif t.status == "error" then sc = colors.red end
        local tp = t.type == "drain" and "VACIAR" or "MOVER"
        local lp = t.loop and ("c/" .. t.interval .. "s") or "1vez"
        ctx:fill(2, y, ctx.W - 14, 3, bg)
        ctx:write(3, y, "#" .. i .. " " .. t.name:sub(1, ctx.W - 22), colors.white, bg)
        ctx:write(3, y + 1, tp .. " | " .. lp, colors.yellow, bg)
        ctx:write(3, y + 2, t.status, sc, bg)
        ctx:btn(ctx.W - 12, y, 5, 3, t.enabled and "ON" or "OFF", colors.white, t.enabled and colors.green or colors.red, function()
            tasks.toggle(i)
        end)
        ctx:btn(ctx.W - 6, y, 5, 3, "DEL", colors.white, colors.red, function() tasks.delete(i) end)
        y = y + 4
    end
    ctx:paginate(tasks.count())
    ctx:footer(tasks.countEnabled() .. "/" .. tasks.count() .. " activas")
end

-- Task creation flow
function scr10.task_type(ctx)
    ctx:header("Tarea: Tipo")
    local y = 5
    ctx:btn(3, y, ctx.W - 4, 3, "TRANSFERIR ITEM", colors.white, colors.green, function()
        ctx.nav._taskType = "transfer"; ctx.nav.screen = "task_from"; ctx.nav.page = 1
    end); y = y + 4
    ctx:btn(3, y, ctx.W - 4, 3, "VACIAR INVENTARIO", colors.white, colors.orange, function()
        ctx.nav._taskType = "drain"; ctx.nav.screen = "task_from"; ctx.nav.page = 1
    end)
end

function scr10.task_from(ctx)
    compSelectInv(ctx, "Tarea: Origen", function(inv)
        ctx.nav.fromInv = inv
        if ctx.nav._taskType == "drain" then
            ctx.nav.screen = "task_to"; ctx.nav.page = 1
        else
            ctx.nav.items = lib.getItems(inv)
            ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
            ctx.nav.screen = "task_item"; ctx.nav.page = 1
        end
    end)
end

function scr10.task_item(ctx)
    compItemList(ctx, "Tarea: Item", function(item)
        ctx.nav.selectedItem = item; ctx.nav.cantidad = 0
        ctx.nav.screen = "task_qty"
    end)
end

function scr10.task_item_search(ctx)
    ctx:header("Buscar Item")
    local n = ctx.nav; local y = 4
    for i = 1, math.min(3, #n.filteredItems) do
        ctx:write(3, y, sn(n.filteredItems[i].name) .. " x" .. n.filteredItems[i].total, colors.lightGray, colors.black)
        y = y + 1
    end
    compKeyboard(ctx, function() n.screen = "task_item" end)
end

function scr10.task_qty(ctx)
    compQtySelector(ctx, "Tarea: Cantidad", ctx.nav.selectedItem.total, true, function()
        ctx.nav.screen = "task_to"; ctx.nav.page = 1
    end)
end

function scr10.task_to(ctx)
    compSelectInv(ctx, "Tarea: Destino", function(inv)
        ctx.nav.toInv = inv; ctx.nav.screen = "task_config"
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr10.task_config(ctx)
    ctx:header("Tarea: Configurar")
    local n = ctx.nav; local y = 4
    local tp = n._taskType == "drain" and "VACIAR" or "TRANSFERIR"
    local it = n._taskType == "drain" and "todo" or (n.selectedItem and sn(n.selectedItem.name) or "?")
    ctx:fill(2, y, ctx.W - 2, 3, colors.gray)
    ctx:write(3, y, tp .. ": " .. it, colors.white, colors.gray)
    ctx:write(3, y + 1, n.fromInv.name:sub(1, 15), colors.lime, colors.gray)
    ctx:write(3, y + 2, "-> " .. n.toInv.name:sub(1, 15), colors.cyan, colors.gray)
    y = y + 4
    ctx:write(2, y, "Repetir?", colors.lightGray, colors.black); y = y + 1
    ctx:btn(2, y, math.floor(ctx.W / 2) - 2, 3, "LOOP", colors.white, n._taskLoop and colors.green or colors.gray, function() n._taskLoop = true end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 3, "1 VEZ", colors.white, (not n._taskLoop) and colors.green or colors.gray, function() n._taskLoop = false end)
    y = y + 4
    if n._taskLoop then
        ctx:write(2, y, "Intervalo:", colors.lightGray, colors.black); y = y + 1
        local ints = { 5, 10, 30, 60 }
        local bw = math.floor((ctx.W - 4) / #ints)
        for idx, val in ipairs(ints) do
            local bx = 2 + (idx - 1) * bw
            local lbl = val < 60 and (val .. "s") or (math.floor(val / 60) .. "m")
            ctx:btn(bx, y, bw - 1, 3, lbl, colors.white, n._taskInterval == val and colors.green or colors.blue, function()
                n._taskInterval = val
            end)
        end
        y = y + 4
    end
    ctx:btn(3, y, ctx.W - 4, 3, "CREAR TAREA", colors.black, colors.lime, function()
        local iname = n._taskType == "drain" and "*" or (n.selectedItem and n.selectedItem.name or "*")
        tasks.create({
            name     = sn(iname):sub(1, 10) .. ">" .. n.toInv.name:sub(1, 8),
            type     = n._taskType,
            from     = n.fromInv.name,
            to       = n.toInv.name,
            item     = iname,
            cantidad = n._taskType == "drain" and 0 or (n.cantidad or 0),
            interval = n._taskInterval or 10,
            loop     = n._taskLoop ~= false,
        })
        n.screen = "tasks_list"; n.fromInv = nil; n.toInv = nil; n.selectedItem = nil; n.page = 1
    end)
end

-- Rules
function scr10.rules_list(ctx)
    ctx:header("Reglas Automaticas")
    local tl = st.rulesRunning and "AUTO:ON" or "AUTO:OFF"
    local tc = st.rulesRunning and colors.green or colors.red
    ctx:btn(ctx.W - 12, 3, 11, 2, tl, colors.white, tc, function()
        st.rulesRunning = not st.rulesRunning
        lib.tLog("Reglas: " .. (st.rulesRunning and "ON" or "OFF"))
    end)
    ctx:btn(2, 3, 12, 2, "+ NUEVA", colors.white, colors.green, function()
        lib.refreshInventories(); ctx.nav.screen = "rule_from"; ctx.nav.page = 1
    end)
    if #st.rules == 0 then ctx:write(2, 7, "No hay reglas.", colors.gray, colors.black); return end
    local y = 6
    for i, rule in ipairs(st.rules) do
        if y + 4 > ctx.H - 2 then break end
        local si2 = rule.item == "*" and "TODO" or sn(rule.item)
        local bg = rule.enabled and colors.gray or colors.brown
        ctx:fill(2, y, ctx.W - 14, 3, bg)
        ctx:write(3, y, "#" .. i .. " " .. si2, colors.white, bg)
        ctx:write(3, y + 1, rule.from:sub(1, 10) .. ">" .. rule.to:sub(1, 10), colors.lightGray, bg)
        ctx:write(3, y + 2, rule.interval .. "s", colors.yellow, bg)
        ctx:btn(ctx.W - 12, y, 5, 3, rule.enabled and "ON" or "OFF", colors.white, rule.enabled and colors.green or colors.red, function()
            rule.enabled = not rule.enabled; lib.saveRules()
        end)
        ctx:btn(ctx.W - 6, y, 5, 3, "DEL", colors.white, colors.red, function()
            table.remove(st.rules, i); lib.saveRules(); lib.tLog("Regla #" .. i .. " eliminada")
        end)
        y = y + 4
    end
    ctx:footer(#st.rules .. " reglas")
end

function scr10.rule_from(ctx)
    compSelectInv(ctx, "Regla: Origen", function(inv)
        ctx.nav.fromInv = inv
        ctx.nav.items = lib.getItems(inv); ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
        ctx.nav.screen = "rule_item"; ctx.nav.page = 1
    end)
end

function scr10.rule_item(ctx)
    ctx:header("Regla: Que mover?")
    local y = 4
    ctx:btn(2, y, ctx.W - 2, 3, "MOVER TODO (*)", colors.white, colors.purple, function()
        ctx.nav.selectedItem = { name = "*", total = 0 }
        lib.refreshInventories(); ctx.nav.screen = "rule_to"; ctx.nav.page = 1
    end)
    y = y + 4
    local di = ctx.nav.filteredItems
    local pp = ctx.nav.perPage
    local si = (ctx.nav.page - 1) * pp + 1
    local ei = math.min(ctx.nav.page * pp, #di)
    for i = si, ei do
        if y + 3 > ctx.H - 3 then break end
        local item = di[i]
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 3, "", colors.white, bg, function()
            ctx.nav.selectedItem = item; lib.refreshInventories()
            ctx.nav.screen = "rule_to"; ctx.nav.page = 1
        end)
        ctx:write(4, y + 1, sn(item.name) .. " x" .. item.total, colors.white, bg)
        y = y + 4
    end
    ctx:paginate(#di)
end

function scr10.rule_to(ctx)
    compSelectInv(ctx, "Regla: Destino", function(inv)
        ctx.nav.toInv = inv; ctx.nav.screen = "rule_interval"
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr10.rule_interval(ctx)
    ctx:header("Regla: Intervalo")
    local si2 = ctx.nav.selectedItem.name == "*" and "TODO" or sn(ctx.nav.selectedItem.name)
    ctx:write(2, 4, si2 .. ": " .. ctx.nav.fromInv.name:sub(1, 12), colors.white, colors.black)
    ctx:write(2, 5, "  -> " .. ctx.nav.toInv.name:sub(1, 12), colors.cyan, colors.black)
    local y = 7
    local ints = { 5, 10, 30, 60 }
    for _, secs in ipairs(ints) do
        local lbl = secs < 60 and (secs .. " seg") or ((secs / 60) .. " min")
        ctx:btn(2, y, ctx.W - 2, 2, lbl, colors.white, colors.blue, function()
            table.insert(st.rules, {
                from = ctx.nav.fromInv.name, to = ctx.nav.toInv.name,
                item = ctx.nav.selectedItem.name, cantidad = 0,
                interval = secs, enabled = true, lastRun = 0,
            })
            lib.saveRules()
            lib.tLog("Regla #" .. #st.rules .. " creada: " .. si2 .. " c/" .. secs .. "s")
            ctx.nav.screen = "rules_list"; ctx.nav.fromInv = nil; ctx.nav.toInv = nil; ctx.nav.page = 1
        end)
        y = y + 3
    end
end

-- ============================================================
--  MONITOR 13: INVENTARIO (3x3, interactivo)
--  Explorar inventarios, buscar items, historial
-- ============================================================
local scr13 = {}

function scr13.menu(ctx)
    ctx:header("Inventarios")
    local y = 4
    ctx:btn(3, y, ctx.W - 4, 3, "EXPLORAR INVENTARIOS", colors.white, colors.cyan, function()
        lib.refreshInventories(); ctx.nav.screen = "inv_list"; ctx.nav.page = 1
    end); y = y + 4
    ctx:btn(3, y, ctx.W - 4, 3, "BUSCAR ITEM", colors.white, colors.orange, function()
        lib.refreshInventories(); ctx.nav.screen = "search_all"; ctx.nav.page = 1
        -- Build global item list
        local all = {}
        local map = {}
        for _, inv in ipairs(st.inventories) do
            local items = lib.getItems(inv)
            for _, item in ipairs(items) do
                if not map[item.name] then
                    map[item.name] = { name = item.name, total = 0, locations = {} }
                end
                map[item.name].total = map[item.name].total + item.total
                table.insert(map[item.name].locations, inv.name)
            end
        end
        for _, v in pairs(map) do table.insert(all, v) end
        table.sort(all, function(a, b) return a.name < b.name end)
        ctx.nav.items = all; ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
    end); y = y + 4
    ctx:btn(3, y, ctx.W - 4, 3, "HISTORIAL (" .. #st.history .. ")", colors.white, colors.purple, function()
        ctx.nav.screen = "history"; ctx.nav.page = 1
    end); y = y + 4
    -- Quick inventory summary
    ctx:write(2, y, #st.inventories .. " inventarios conectados", colors.gray, colors.black); y = y + 2
    for i = 1, math.min(#st.inventories, ctx.H - y - 2) do
        local inv = st.inventories[i]
        local used, total = lib.getInventoryFill(inv)
        local pct = total > 0 and math.floor(used / total * 100) or 0
        local col = pct > 90 and colors.red or (pct > 60 and colors.yellow or colors.lime)
        local name = inv.name:sub(1, ctx.W - 12)
        ctx:write(3, y, name, colors.white, colors.black)
        ctx:write(ctx.W - 5, y, pct .. "%", col, colors.black)
        y = y + 1
    end
end

function scr13.inv_list(ctx)
    compSelectInv(ctx, "Selecciona Inventario", function(inv)
        ctx.nav.fromInv = inv
        ctx.nav.items = lib.getItems(inv)
        ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
        ctx.nav.screen = "inv_detail"; ctx.nav.page = 1
    end)
end

function scr13.inv_detail(ctx)
    ctx:header("Contenido")
    local inv = ctx.nav.fromInv
    local name = inv.name
    if #name > ctx.W - 4 then name = name:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, 3, name, colors.cyan, colors.black)
    local di = ctx.nav.filteredItems
    if #di == 0 then ctx:write(2, 5, "Vacio", colors.gray, colors.black); return end
    local pp = ctx.nav.perPage
    local si = (ctx.nav.page - 1) * pp + 1
    local ei = math.min(ctx.nav.page * pp, #di)
    local y = 5
    for i = si, ei do
        local item = di[i]
        local n2 = sn(item.name)
        if #n2 > ctx.W - 12 then n2 = n2:sub(1, ctx.W - 14) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:fill(2, y, ctx.W - 2, 2, bg)
        ctx:write(3, y, n2, colors.white, bg)
        ctx:write(ctx.W - #("x" .. item.total) - 2, y, "x" .. item.total, colors.yellow, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " tipos")
end

function scr13.search_all(ctx)
    ctx:header("Buscar Item Global")
    local n = ctx.nav
    if n.searchText ~= "" then
        ctx:write(2, 3, "Filtro: " .. n.searchText, colors.yellow, colors.black)
    end
    ctx:btn(ctx.W - 13, 3, 12, 1, "TECLADO", colors.white, colors.orange, function()
        n.screen = "search_kb"
    end)
    local di = n.filteredItems
    if #di == 0 then ctx:write(2, 5, "Sin resultados", colors.gray, colors.black); return end
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #di)
    local y = 5
    for i = si, ei do
        local item = di[i]
        local n2 = sn(item.name)
        if #n2 > ctx.W - 12 then n2 = n2:sub(1, ctx.W - 14) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:fill(2, y, ctx.W - 2, 3, bg)
        ctx:write(3, y, n2, colors.white, bg)
        ctx:write(ctx.W - #("x" .. item.total) - 2, y, "x" .. item.total, colors.yellow, bg)
        if item.locations then
            local locs = #item.locations .. " inv"
            ctx:write(3, y + 1, locs, colors.lightGray, bg)
        end
        y = y + 4
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items encontrados")
end

function scr13.search_kb(ctx)
    ctx:header("Buscar")
    local n = ctx.nav; local y = 4
    for i = 1, math.min(3, #n.filteredItems) do
        ctx:write(3, y, sn(n.filteredItems[i].name) .. " x" .. n.filteredItems[i].total, colors.lightGray, colors.black)
        y = y + 1
    end
    compKeyboard(ctx, function() n.screen = "search_all" end)
end

function scr13.history(ctx)
    ctx:header("Historial")
    if #st.history == 0 then ctx:write(2, 5, "Sin historial.", colors.gray, colors.black); return end
    ctx:btn(ctx.W - 13, 3, 12, 2, "LIMPIAR", colors.white, colors.red, function()
        st.history = {}; lib.saveHistory(); lib.tLog("Historial limpiado")
    end)
    local n = ctx.nav
    local si = (n.page - 1) * n.perPage + 1
    local ei = math.min(n.page * n.perPage, #st.history)
    local y = 6
    for i = si, ei do
        local h = st.history[i]
        local si2 = h.item == "*" and "todo" or sn(h.item)
        local ok = h.moved >= h.requested
        local bg = (i % 2 == 0) and colors.gray or colors.black
        ctx:fill(2, y, ctx.W - 2, 3, bg)
        ctx:write(3, y, h.time .. " " .. (ok and "OK" or "PARC"), ok and colors.lime or colors.orange, bg)
        ctx:write(3, y + 1, h.moved .. "x " .. si2, colors.white, bg)
        ctx:write(3, y + 2, h.from:sub(1, 8) .. ">" .. h.to:sub(1, 8), colors.lightGray, bg)
        y = y + 4
    end
    ctx:paginate(#st.history)
    ctx:footer(#st.history .. " registros")
end

-- ============================================================
--  MONITOR 12: DASHBOARD (2x7, techo, auto-refresh)
-- ============================================================

local function renderDashboard(ctx)
    ctx:clear(colors.black)
    ctx:fill(1, 1, ctx.W, 2, colors.blue)
    ctx:write(2, 1, "DASHBOARD", colors.white, colors.blue)
    ctx:write(2, 2, fmtElapsed(os.clock() - st.startTime) .. " uptime", colors.lightGray, colors.blue)

    local y = 4

    -- Inventarios con barras de llenado
    ctx:write(2, y, "INVENTARIOS", colors.yellow, colors.black); y = y + 1
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(2, y, "Nombre", colors.white, colors.gray)
    ctx:write(ctx.W - 8, y, "Uso", colors.white, colors.gray); y = y + 1

    for i, inv in ipairs(st.inventories) do
        if y >= ctx.H - 25 then break end
        local used, total = lib.getInventoryFill(inv)
        local pct = total > 0 and math.floor(used / total * 100) or 0
        local barW = math.max(1, ctx.W - 18)
        local filled = math.max(0, math.floor(barW * pct / 100))
        local name = inv.name:sub(1, 14)

        local col = pct > 90 and colors.red or (pct > 60 and colors.orange or colors.green)
        ctx:write(2, y, name, colors.white, colors.black)
        ctx:fill(16, y, barW, 1, colors.gray)
        if filled > 0 then ctx:fill(16, y, filled, 1, col) end
        ctx:write(ctx.W - 4, y, pct .. "%", col, colors.black)
        y = y + 1
    end

    if #st.inventories == 0 then
        ctx:write(3, y, "Sin inventarios", colors.gray, colors.black)
        y = y + 1
    end
    y = y + 1

    -- Worker status
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(2, y, "WORKER", colors.yellow, colors.gray); y = y + 1
    if st.workerActive then
        local ws = st.workerStats
        ctx:write(3, y, "ACTIVO", colors.lime, colors.black)
        ctx:write(12, y, "Ciclos:" .. ws.cycles, colors.white, colors.black); y = y + 1
        ctx:write(3, y, "Items:" .. ws.totalMoved, colors.yellow, colors.black)
        if ws.destFull then ctx:write(20, y, "LLENO!", colors.red, colors.black) end; y = y + 1
        local fn = st.workerFrom and st.workerFrom.name:sub(1, 12) or "?"
        local tn = st.workerTo and st.workerTo.name:sub(1, 12) or "?"
        ctx:write(3, y, fn .. " > " .. tn, colors.lightGray, colors.black); y = y + 1
    else
        ctx:write(3, y, "Inactivo", colors.gray, colors.black); y = y + 1
    end
    y = y + 1

    -- Tareas
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(2, y, "TAREAS", colors.yellow, colors.gray); y = y + 1
    if tasks.count() == 0 then
        ctx:write(3, y, "Sin tareas", colors.gray, colors.black); y = y + 1
    else
        for i, t in ipairs(st.tasks) do
            if y >= ctx.H - 8 then break end
            local sc = t.enabled and (t.status == "done" and colors.lime or colors.white) or colors.gray
            if t.status == "error" then sc = colors.red end
            ctx:write(3, y, (t.enabled and "+" or "-") .. " " .. t.name:sub(1, ctx.W - 10), sc, colors.black)
            local lr = t.lastResult and t.lastResult.moved or 0
            if lr > 0 then ctx:write(ctx.W - 6, y, ">" .. lr, colors.cyan, colors.black) end
            y = y + 1
        end
    end
    y = y + 1

    -- Reglas
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(2, y, "REGLAS " .. (st.rulesRunning and "(ON)" or "(OFF)"), colors.yellow, colors.gray); y = y + 1
    if #st.rules == 0 then
        ctx:write(3, y, "Sin reglas", colors.gray, colors.black); y = y + 1
    else
        for i, r in ipairs(st.rules) do
            if y >= ctx.H - 3 then break end
            local si2 = r.item == "*" and "*" or sn(r.item):sub(1, 8)
            local sc = r.enabled and colors.white or colors.gray
            ctx:write(3, y, si2 .. " c/" .. r.interval .. "s", sc, colors.black)
            y = y + 1
        end
    end
    y = y + 1

    -- Sistema
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(2, y, "SISTEMA", colors.yellow, colors.gray); y = y + 1
    ctx:write(3, y, "Perifericos: " .. #peripheral.getNames(), colors.white, colors.black); y = y + 1
    ctx:write(3, y, "Inventarios: " .. #st.inventories, colors.white, colors.black); y = y + 1
    ctx:write(3, y, "Reglas: " .. #st.rules .. " Tareas: " .. tasks.count(), colors.white, colors.black)
end

-- ============================================================
--  MONITOR 11: ACTIVIDAD (2x7, techo, auto-refresh)
-- ============================================================

local function renderActivity(ctx)
    ctx:clear(colors.black)
    ctx:fill(1, 1, ctx.W, 2, colors.purple)
    ctx:write(2, 1, "ACTIVIDAD", colors.white, colors.purple)
    local time = textutils.formatTime(os.time(), true)
    ctx:write(ctx.W - #time - 1, 1, time, colors.lightGray, colors.purple)
    ctx:write(2, 2, "Dia " .. os.day(), colors.lightGray, colors.purple)

    local y = 4

    -- Stats
    ctx:fill(2, y, ctx.W - 2, 4, colors.gray)
    ctx:write(3, y, "ESTADISTICAS", colors.yellow, colors.gray)
    ctx:write(3, y + 1, "Transferencias: " .. st.totalTransfers, colors.white, colors.gray)
    ctx:write(3, y + 2, "Items movidos: " .. st.totalMoved, colors.lime, colors.gray)
    ctx:write(3, y + 3, "Errores: " .. st.totalErrors, st.totalErrors > 0 and colors.red or colors.white, colors.gray)
    y = y + 6

    -- Feed de actividad
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(2, y, "LOG EN VIVO", colors.yellow, colors.gray); y = y + 1

    local log = lib.termLog
    local maxLines = ctx.H - y - 1
    for i = 1, math.min(#log, maxLines) do
        local l = log[i]
        local col = colors.lightGray
        if l:find("ERROR") then col = colors.red
        elseif l:find("AUTO") or l:find("TASK") then col = colors.cyan
        elseif l:find("WORKER") then col = colors.yellow
        elseif l:find("OK") or l:find("LISTO") then col = colors.lime end
        local text = l:sub(1, ctx.W - 2)
        ctx:write(2, y, text, col, colors.black)
        y = y + 1
    end

    if #log == 0 then
        ctx:write(3, y, "Esperando actividad...", colors.gray, colors.black)
    end
end

-- ============================================================
--  Inicializacion y API publica
-- ============================================================

ui.monitors = {}

function ui.init()
    local ids = lib.MON_IDS
    local labels = {
        control = "CONTROL", tasks = "AUTOMATIZAR", browse = "INVENTARIO",
        dashboard = "DASHBOARD", activity = "ACTIVIDAD",
    }
    local scales = {
        control = 0.5, tasks = 0.5, browse = 0.5,
        dashboard = 0.5, activity = 0.5,
    }
    local screenTables = {
        control = scr14, tasks = scr10, browse = scr13,
    }

    for key, id in pairs(ids) do
        local mon = peripheral.wrap(id)
        if mon then
            local ctx = newCtx(mon, id, labels[key], scales[key])
            if ctx then
                ctx.screens = screenTables[key] or nil
                ui.monitors[key] = ctx
                lib.tLog("Monitor OK: " .. key .. " (" .. id .. ") " .. ctx.W .. "x" .. ctx.H)
            end
        else
            lib.tLog("WARN: Monitor no encontrado: " .. id)
        end
    end
    return true
end

function ui.renderMonitor(key)
    local m = ui.monitors[key]
    if not m then return end

    if m.screens then
        -- Interactive monitor
        m:clear()
        local fn = m.screens[m.nav.screen]
        if fn then fn(m) end
    elseif key == "dashboard" then
        renderDashboard(m)
    elseif key == "activity" then
        renderActivity(m)
    end
    m.dirty = false
end

function ui.renderAll()
    for key in pairs(ui.monitors) do
        ui.renderMonitor(key)
    end
end

function ui.renderDirty()
    for key, m in pairs(ui.monitors) do
        if m.dirty then ui.renderMonitor(key) end
    end
end

function ui.handleTouch(side, x, y)
    for key, m in pairs(ui.monitors) do
        if m.monName == side then
            if m.screens and m:handleTouch(x, y) then
                ui.renderMonitor(key)
                return true
            end
        end
    end
    return false
end

function ui.markDirty(key)
    if key then
        if ui.monitors[key] then ui.monitors[key].dirty = true end
    else
        for _, m in pairs(ui.monitors) do m.dirty = true end
    end
end

return ui
