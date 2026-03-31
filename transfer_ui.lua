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

-- Pending action for deferred execution
ui.pendingAction = nil

function ui.queueAction(action)
    ui.pendingAction = action
    os.queueEvent("pending_action")
end

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
        perPage      = math.max(1, math.floor((ctx.H - 6) / 2)),
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
        history      = {},
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
        self:fill(1, 1, self.W, 1, colors.gray)
        local titleText = self.label .. ":" .. title
        if #titleText > self.W - 10 then titleText = title end
        self:write(2, 1, titleText, colors.yellow, colors.gray)
        if self.nav.screen ~= "menu" then
            self:btn(self.W - 4, 1, 4, 1, "<", colors.white, colors.red, function()
                self.nav.searchText = ""
                self:goBack()
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
        local y = self.H - 1
        self:fill(1, y, self.W, 1, colors.black)
        if self.nav.page > 1 then
            self:btn(2, y, 6, 1, "< P", colors.white, colors.cyan, function()
                self.nav.page = self.nav.page - 1
            end)
        end
        self:write(math.floor(self.W / 2) - 2, y, self.nav.page .. "/" .. tp, colors.gray, colors.black)
        if self.nav.page < tp then
            self:btn(self.W - 6, y, 6, 1, "N >", colors.white, colors.cyan, function()
                self.nav.page = self.nav.page + 1
            end)
        end
    end

    function ctx:handleTouch(x, y)
        -- Reverse iterate: last-added buttons (paginate, footer) have priority
        for i = #self.buttons, 1, -1 do
            local b = self.buttons[i]
            if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
                b.action()
                self.dirty = true
                return true
            end
        end
        return false
    end

    -- Navigation helpers
    function ctx:goTo(screen)
        table.insert(self.nav.history, self.nav.screen)
        if #self.nav.history > 20 then table.remove(self.nav.history, 1) end
        self.nav.screen = screen
        self.nav.page = 1
    end

    function ctx:goBack()
        if #self.nav.history > 0 then
            self.nav.screen = table.remove(self.nav.history)
            self.nav.page = 1
        else
            self.nav.screen = "menu"
        end
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
        ctx:write(2, 3, "No hay inventarios", colors.red, colors.black)
        ctx:footer("Conecta inventarios")
        return
    end
    local pp = ctx.nav.perPage
    local si = (ctx.nav.page - 1) * pp + 1
    local ei = math.min(ctx.nav.page * pp, #invs)
    local y = 3
    for i = si, ei do
        local inv = invs[i]
        local name = lib.getAlias(inv.name)
        if #name > ctx.W - 8 then name = name:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        local fg = colors.white
        if filterOut and inv.name == filterOut then bg = colors.brown; fg = colors.red end
        ctx:btn(2, y, ctx.W - 2, 2, "", fg, bg, function()
            if filterOut and inv.name == filterOut then return end
            onSelect(inv)
        end)
        ctx:write(4, y, name, fg, bg)
        local used, total = lib.getInventoryFill(inv)
        local pct = total > 0 and math.floor(used / total * 100) or 0
        local fillCol = pct > 90 and colors.red or (pct > 60 and colors.orange or colors.lightGray)
        ctx:write(ctx.W - 8, y, pct .. "% " .. total .. "s", fillCol, bg)
        y = y + 3
    end
    ctx:paginate(#invs)
    ctx:footer(#invs .. " inv")
end

local function compItemList(ctx, title, onSelect)
    ctx:header(title)
    local n = ctx.nav
    if n.searchText ~= "" then
        ctx:write(2, 2, "Filt:" .. n.searchText, colors.yellow, colors.black)
    end
    ctx:btn(ctx.W - 8, 2, 8, 1, "BUSCAR", colors.white, colors.orange, function()
        n._returnScreen = n.screen
        n.screen = n.screen .. "_search"
    end)
    local di = n.filteredItems
    if #di == 0 then
        ctx:write(2, 4, n.searchText ~= "" and "Sin res." or "Vacio", colors.orange, colors.black)
        return
    end
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #di)
    local y = 3
    for i = si, ei do
        local item = di[i]
        local sn = item.name:match(":(.+)") or item.name
        if #sn > ctx.W - 8 then sn = sn:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function() onSelect(item) end)
        ctx:write(4, y, sn .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items")
end

local function compKeyboard(ctx, onConfirm)
    local n = ctx.nav
    local keys = { "A B C D E F G", "H I J K L M N", "O P Q R S T U", "V W X Y Z _", "1 2 3 4 5 6 7", "8 9 0" }
    -- Dynamic y: keys rows + 1 action row + 1 input display + 1 padding
    local kbHeight = #keys + 3
    local y = ctx.H - kbHeight
    ctx:fill(2, y - 1, ctx.W - 2, 1, colors.gray)
    local disp = n.searchText == "" and "Buscar..." or n.searchText
    if #disp > ctx.W - 6 then disp = disp:sub(1, ctx.W - 9) .. ".." end
    ctx:write(3, y - 1, disp, n.searchText == "" and colors.lightGray or colors.yellow, colors.gray)
    for row, line in ipairs(keys) do
        local col = 2
        for char in line:gmatch("%S+") do
            ctx:btn(col, y + (row - 1), 2, 1, char, colors.white, colors.blue, function()
                n.searchText = n.searchText .. char:lower()
                lib.applyFilter(n)
            end)
            col = col + 3
        end
    end
    local sy = y + #keys
    local bw = math.floor((ctx.W - 4) / 3)
    ctx:btn(2, sy, bw, 1, "DEL", colors.white, colors.orange, function()
        if #n.searchText > 0 then n.searchText = n.searchText:sub(1, -2); lib.applyFilter(n) end
    end)
    ctx:btn(2 + bw, sy, bw, 1, "CLR", colors.white, colors.red, function()
        n.searchText = ""; lib.applyFilter(n)
    end)
    ctx:btn(2 + 2*bw, sy, bw, 1, "OK", colors.white, colors.green, function()
        if onConfirm then onConfirm() end
    end)
end

local function compQtySelector(ctx, title, maxQty, allowZero, onConfirm)
    ctx:header(title)
    local n = ctx.nav
    local sn = n.selectedItem and (n.selectedItem.name:match(":(.+)") or n.selectedItem.name) or "?"
    if #sn > ctx.W - 6 then sn = sn:sub(1, ctx.W - 8) .. ".." end
    ctx:write(2, 2, "Item: " .. sn, colors.white, colors.black)
    if maxQty > 0 then ctx:write(2, 3, "Avail: " .. maxQty, colors.gray, colors.black) end
    ctx:fill(2, 4, ctx.W - 2, 2, colors.gray)
    local qs = n.cantidad == 0 and "ALL" or tostring(n.cantidad)
    ctx:write(math.floor(ctx.W / 2) - math.floor(#qs / 2), 4, qs, colors.yellow, colors.gray)
    local y = 6
    local lo = allowZero and 0 or 1
    local bw = math.floor((ctx.W - 4) / 3)
    ctx:btn(2, y, bw, 1, "-1",  colors.white, colors.red, function() n.cantidad = math.max(lo, n.cantidad - 1) end)
    ctx:btn(2 + bw, y, bw, 1, "-10", colors.white, colors.red, function() n.cantidad = math.max(lo, n.cantidad - 10) end)
    ctx:btn(2 + 2*bw, y, bw, 1, "-64", colors.white, colors.red, function() n.cantidad = math.max(lo, n.cantidad - 64) end)
    y = y + 2
    local hi = maxQty > 0 and maxQty or lib.MAX_QUANTITY
    ctx:btn(2, y, bw, 1, "+1",  colors.white, colors.green, function() n.cantidad = math.min(hi, n.cantidad + 1) end)
    ctx:btn(2 + bw, y, bw, 1, "+10", colors.white, colors.green, function() n.cantidad = math.min(hi, n.cantidad + 10) end)
    ctx:btn(2 + 2*bw, y, bw, 1, "+64", colors.white, colors.green, function() n.cantidad = math.min(hi, n.cantidad + 64) end)
    y = y + 2
    ctx:btn(2, y, math.floor((ctx.W - 3) / 2), 1, "ALL", colors.white, colors.purple, function() n.cantidad = allowZero and 0 or maxQty end)
    if maxQty > 0 then
        ctx:btn(2 + math.floor((ctx.W - 3) / 2) + 1, y, math.floor((ctx.W - 3) / 2), 1, "STK", colors.white, colors.purple, function() n.cantidad = math.min(64, maxQty) end)
    end
    y = y + 2
    ctx:btn(2, y, ctx.W - 2, 1, "NEXT >>", colors.white, colors.blue, function()
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
    ctx:header("Menu")
    local y = 2
    local hw = math.floor((ctx.W - 3) / 2)
    ctx:btn(2, y, hw, 2, "TRANSFER", colors.white, colors.green, function()
        lib.refreshInventories(); ctx:goTo("xfer_from")
    end)
    ctx:btn(2 + hw + 1, y, hw, 2, "EMPTY", colors.white, colors.orange, function()
        lib.refreshInventories(); ctx:goTo("bulk_from")
    end); y = y + 3
    ctx:btn(2, y, hw, 2, "WORKER", colors.black, colors.yellow, function()
        lib.refreshInventories(); ctx:goTo("wk_from")
    end)
    ctx:btn(2 + hw + 1, y, hw, 2, "GROUP", colors.white, colors.purple, function()
        ctx:goTo("grp_confirm")
    end); y = y + 3
    -- Refresh button
    ctx:btn(2, y, ctx.W - 2, 1, "REFRESH INV", colors.black, colors.lightGray, function()
        lib.refreshInventories()
        lib.tLog("[SYS] Refresh: " .. #st.inventories .. " inv")
    end)
    -- Worker status
    if st.workerActive then
        local ws = st.workerStats
        y = ctx.H - 3
        ctx:fill(2, y, ctx.W - 2, 1, colors.green)
        ctx:write(3, y, "W:" .. ws.cycles .. " mv:" .. ws.totalMoved, colors.white, colors.green)
        y = y + 1
        ctx:btn(2, y, ctx.W - 2, 1, "VIEW WK", colors.black, colors.lime, function()
            ctx:goTo("wk_running")
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
        ctx:goTo("xfer_item")
    end)
end

function scr14.xfer_item(ctx)
    compItemList(ctx, "Seleccionar Item", function(item)
        ctx.nav.selectedItem = item
        ctx.nav.cantidad = item.total
        ctx:goTo("xfer_qty")
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
        ctx:goTo("xfer_to")
    end)
end

function scr14.xfer_to(ctx)
    compSelectInv(ctx, "Transferir: Destino", function(inv)
        ctx.nav.toInv = inv
        ctx:goTo("xfer_confirm")
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr14.xfer_confirm(ctx)
    ctx:header("Confirm")
    local n = ctx.nav
    local si = sn(n.selectedItem.name)
    if #si > ctx.W - 8 then si = si:sub(1, ctx.W - 10) .. ".." end
    local y = 2
    ctx:write(2, y, "I:" .. si, colors.white, colors.black); y = y + 1
    ctx:write(2, y, "Q:" .. n.cantidad, colors.yellow, colors.black)
    local fi = lib.getAlias(n.fromInv.name)
    if #fi > ctx.W - 4 then fi = fi:sub(1, ctx.W - 6) .. ".." end
    y = y + 1
    ctx:write(2, y, "F:" .. fi, colors.lime, colors.black)
    local ti = lib.getAlias(n.toInv.name)
    if #ti > ctx.W - 4 then ti = ti:sub(1, ctx.W - 6) .. ".." end
    y = y + 1
    ctx:write(2, y, "T:" .. ti, colors.cyan, colors.black); y = y + 2
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 2, "CANCEL", colors.white, colors.red, function()
        n.screen = "menu"; n.history = {}
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "RUN", colors.white, colors.green, function()
        ctx:goTo("xfer_exec")
    end)
end

function scr14.xfer_exec(ctx)
    ctx:header("Running...")
    local n = ctx.nav
    ctx:write(2, 3, "Processing...", colors.yellow, colors.black)
    ui.queueAction({
        type = "xfer",
        ctx = ctx,
        fromInv = n.fromInv,
        toInv = n.toInv,
        selectedItem = n.selectedItem,
        cantidad = n.cantidad,
    })
end

function scr14.xfer_result(ctx)
    ctx:header("Result")
    local n = ctx.nav
    local y = 2
    if n._moved >= n.cantidad then
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, "OK " .. n._moved .. "/" .. n.cantidad, colors.white, colors.green)
    elseif n._moved > 0 then
        ctx:fill(2, y, ctx.W - 2, 2, colors.orange)
        ctx:write(3, y, "PART " .. n._moved .. "/" .. n.cantidad, colors.white, colors.orange)
    else
        ctx:fill(2, y, ctx.W - 2, 2, colors.red)
        ctx:write(3, y, "FAIL", colors.white, colors.red)
    end
    y = ctx.H - 2
    ctx:btn(2, y, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
        n.screen = "menu"; n.history = {}; n.fromInv = nil; n.toInv = nil; n.selectedItem = nil; n.page = 1
    end)
end

-- Bulk flow
function scr14.bulk_from(ctx)
    compSelectInv(ctx, "Vaciar: Origen", function(inv)
        ctx.nav.fromInv = inv; ctx:goTo("bulk_to")
    end)
end

function scr14.bulk_to(ctx)
    compSelectInv(ctx, "Vaciar: Destino", function(inv)
        ctx.nav.toInv = inv; ctx:goTo("bulk_confirm")
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr14.bulk_confirm(ctx)
    ctx:header("Empty")
    local n = ctx.nav
    local items = lib.getItems(n.fromInv)
    local total = 0
    for _, item in ipairs(items) do total = total + item.total end
    local y = 2
    ctx:write(2, y, "FROM:", colors.gray, colors.black)
    local from = lib.getAlias(n.fromInv.name)
    if #from > ctx.W - 8 then from = from:sub(1, ctx.W - 10) .. ".." end
    y = y + 1
    ctx:write(3, y, from, colors.lime, colors.black)
    y = y + 1
    ctx:write(3, y, #items .. "t " .. total .. "i", colors.yellow, colors.black)
    y = y + 1
    ctx:write(2, y, "TO:", colors.gray, colors.black)
    local to = lib.getAlias(n.toInv.name)
    if #to > ctx.W - 8 then to = to:sub(1, ctx.W - 10) .. ".." end
    y = y + 1
    ctx:write(3, y, to, colors.cyan, colors.black); y = y + 2
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 2, "CANCEL", colors.white, colors.red, function() n.screen = "menu"; n.history = {} end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "EMPTY", colors.white, colors.green, function()
        ctx:goTo("bulk_exec")
    end)
end

function scr14.bulk_exec(ctx)
    ctx:header("Running...")
    ctx:write(2, 2, "XFR...", colors.yellow, colors.black)
    local n = ctx.nav
    ui.queueAction({
        type = "bulk",
        ctx = ctx,
        fromInv = n.fromInv,
        toInv = n.toInv,
    })
end

function scr14.bulk_result(ctx)
    ctx:header("Result")
    local r = ctx.nav.bulkResult
    local y = 2
    if r.destFull then
        ctx:fill(2, y, ctx.W - 2, 2, colors.orange)
        ctx:write(3, y, "FULL " .. r.total .. "/" .. r.totalOriginal, colors.white, colors.orange)
    elseif r.total > 0 then
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, "OK " .. r.total .. " items", colors.white, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 2, colors.red)
        ctx:write(3, y, "FAIL", colors.white, colors.red)
    end
    y = y + 2
    local maxD = math.min(#r.items, ctx.H - y - 3)
    for i = 1, maxD do
        local it = r.items[i]
        local n2 = sn(it.name)
        if #n2 > ctx.W - 8 then n2 = n2:sub(1, ctx.W - 10) .. ".." end
        ctx:write(2, y, n2, colors.white, colors.black)
        local mv = "x" .. it.moved
        ctx:write(ctx.W - #mv - 1, y, mv, it.failed > 0 and colors.orange or colors.lime, colors.black)
        y = y + 1
    end
    y = ctx.H - 2
    ctx:btn(2, y, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
        ctx.nav.screen = "menu"; ctx.nav.history = {}; ctx.nav.fromInv = nil; ctx.nav.toInv = nil
    end)
end

-- Group flow
function scr14.grp_confirm(ctx)
    ctx:header("Agrupar")
    local y = 2
    ctx:write(2, y, "Consolida items:", colors.white, colors.black); y = y + 1
    ctx:write(2, y, "Mueve cada item al", colors.lightGray, colors.black); y = y + 1
    ctx:write(2, y, "inv con MAS de ese", colors.lightGray, colors.black); y = y + 1
    ctx:write(2, y, "tipo.", colors.lightGray, colors.black); y = y + 2
    ctx:fill(2, y, ctx.W - 2, 1, colors.yellow)
    ctx:write(3, y, "Afecta TODOS los inv", colors.black, colors.yellow); y = y + 2
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 2, "CANCEL", colors.white, colors.red, function()
        ctx.nav.screen = "menu"; ctx.nav.history = {}
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "RUN", colors.white, colors.green, function()
        ctx:goTo("grp_exec")
    end)
end

function scr14.grp_exec(ctx)
    ctx:header("Grouping...")
    ctx:write(2, 3, "Scanning...", colors.yellow, colors.black)
    ui.queueAction({ type = "group", ctx = ctx })
end

function scr14.grp_result(ctx)
    ctx:header("Result")
    local r = ctx.nav._grpResult
    if not r then
        ctx:write(2, 3, "No data", colors.red, colors.black)
        ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
            ctx.nav.screen = "menu"; ctx.nav.history = {}
        end)
        return
    end
    local y = 2
    if r.totalMoved > 0 then
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, r.itemsGrouped .. " items agrup.", colors.white, colors.green)
        ctx:write(3, y + 1, r.totalMoved .. " movidos", colors.yellow, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 2, colors.orange)
        ctx:write(3, y, "Ya organizado", colors.white, colors.orange)
    end
    y = y + 3
    local maxD = math.min(#r.details, ctx.H - y - 3)
    for i = 1, maxD do
        local d = r.details[i]
        local nm = d.name
        if #nm > ctx.W - 8 then nm = nm:sub(1, ctx.W - 10) .. ".." end
        ctx:write(2, y, nm .. " x" .. d.moved, colors.white, colors.black)
        y = y + 1
    end
    if #r.details > maxD then
        ctx:write(2, y, "+" .. (#r.details - maxD) .. " mas", colors.gray, colors.black)
    end
    ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
        ctx.nav.screen = "menu"; ctx.nav.history = {}
    end)
end

-- Worker flow
function scr14.wk_from(ctx)
    compSelectInv(ctx, "Worker: Origen", function(inv)
        ctx.nav.fromInv = inv; ctx:goTo("wk_to")
    end)
end

function scr14.wk_to(ctx)
    compSelectInv(ctx, "Worker: Destino", function(inv)
        ctx.nav.toInv = inv; ctx:goTo("wk_interval")
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr14.wk_interval(ctx)
    ctx:header("Worker: Secs")
    local y = 2
    ctx:write(2, y, st.workerInterval .. "s", colors.yellow, colors.black); y = y + 1
    local presets = { 1, 2, 5, 10, 15, 30, 60 }
    local bw = math.floor((ctx.W - 2) / 7)
    for idx, val in ipairs(presets) do
        local bx = 2 + (idx - 1) * bw
        ctx:btn(bx, y, bw - 1, 1, tostring(val), colors.white, val == st.workerInterval and colors.green or colors.blue, function()
            st.workerInterval = val
        end)
    end
    y = y + 2
    ctx:btn(2, y, math.floor((ctx.W - 2) / 2), 1, "-", colors.white, colors.orange, function() st.workerInterval = math.max(1, st.workerInterval - 1) end)
    ctx:btn(2 + math.floor((ctx.W - 2) / 2), y, math.floor((ctx.W - 2) / 2), 1, "+", colors.white, colors.cyan, function() st.workerInterval = math.min(300, st.workerInterval + 1) end)
    y = y + 2
    ctx:btn(2, y, ctx.W - 2, 2, "NEXT", colors.white, colors.green, function() ctx:goTo("wk_confirm") end)
end

function scr14.wk_confirm(ctx)
    ctx:header("Worker: Confirmar")
    local n = ctx.nav; local y = 2
    ctx:write(2, y, "ORIGEN:", colors.gray, colors.black); y = y + 1
    ctx:write(3, y, lib.getAlias(n.fromInv.name), colors.lime, colors.black); y = y + 2
    ctx:write(2, y, "DESTINO:", colors.gray, colors.black); y = y + 1
    ctx:write(3, y, lib.getAlias(n.toInv.name), colors.cyan, colors.black); y = y + 2
    ctx:write(2, y, "Cada " .. st.workerInterval .. " segundos", colors.yellow, colors.black); y = y + 2
    ctx:fill(2, y, ctx.W - 2, 2, colors.yellow)
    ctx:write(3, y, "VACIA TODO CONTINUO", colors.black, colors.yellow); y = y + 3
    ctx:btn(2, y, math.floor(ctx.W / 2) - 2, 2, "CANCELAR", colors.white, colors.red, function() n.screen = "menu"; n.history = {} end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "INICIAR", colors.black, colors.lime, function()
        worker.start(n.fromInv, n.toInv, st.workerInterval)
        ctx:goTo("wk_running")
    end)
end

function scr14.wk_running(ctx)
    ctx:header("Worker")
    local ws = st.workerStats; local y = 2
    local el = fmtElapsed(os.clock() - ws.startTime)
    if st.workerActive then
        ctx:fill(2, y, ctx.W - 2, 1, colors.green)
        ctx:write(3, y, "RUN " .. el, colors.white, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 1, colors.red)
        ctx:write(3, y, "PAUSED " .. el, colors.white, colors.red)
    end
    y = y + 2
    local fn = st.workerFrom and lib.getAlias(st.workerFrom.name) or "?"
    local tn = st.workerTo and lib.getAlias(st.workerTo.name) or "?"
    if #fn > ctx.W - 4 then fn = fn:sub(1, ctx.W - 6) .. ".." end
    if #tn > ctx.W - 4 then tn = tn:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, y, "F:" .. fn, colors.lime, colors.black); y = y + 1
    ctx:write(2, y, "T:" .. tn, colors.cyan, colors.black); y = y + 1
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, "C:" .. ws.cycles .. " M:" .. ws.totalMoved, colors.white, colors.gray)
    y = y + 2
    if #ws.lastItems > 0 then
        ctx:write(2, y, "Last:", colors.gray, colors.black); y = y + 1
        for i = 1, math.min(2, #ws.lastItems) do
            local it = ws.lastItems[i]
            local n2 = sn(it.name)
            if #n2 > ctx.W - 8 then n2 = n2:sub(1, ctx.W - 10) .. ".." end
            ctx:write(3, y, n2 .. " x" .. it.moved, colors.white, colors.black)
            y = y + 1
        end
    end
    local by = ctx.H - 2
    if st.workerActive then
        ctx:btn(2, by, math.floor(ctx.W / 2) - 1, 2, "PAUSE", colors.white, colors.orange, function() worker.pause() end)
        ctx:btn(math.floor(ctx.W / 2) + 1, by, math.floor(ctx.W / 2) - 1, 2, "STOP", colors.white, colors.red, function()
            worker.stop(); ctx:goTo("wk_stopped")
        end)
    else
        ctx:btn(2, by, math.floor(ctx.W / 2) - 1, 2, "RES", colors.black, colors.lime, function() worker.resume() end)
        ctx:btn(math.floor(ctx.W / 2) + 1, by, math.floor(ctx.W / 2) - 1, 2, "STOP", colors.white, colors.red, function()
            worker.stop(); ctx:goTo("wk_stopped")
        end)
    end
end

function scr14.wk_stopped(ctx)
    ctx:header("Worker: Stop")
    local ws = st.workerStats; local y = 2
    ctx:fill(2, y, ctx.W - 2, 2, colors.gray)
    ctx:write(3, y, "T:" .. fmtElapsed(os.clock() - ws.startTime), colors.white, colors.gray)
    ctx:write(3, y + 1, "C:" .. ws.cycles .. " M:" .. ws.totalMoved, colors.lime, colors.gray)
    y = y + 3
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 2, "REST", colors.black, colors.yellow, function()
        worker.restart(); ctx:goTo("wk_running")
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "MENU", colors.white, colors.blue, function()
        st.workerActive = false; st.workerFrom = nil; st.workerTo = nil
        ctx.nav.screen = "menu"; ctx.nav.history = {}
    end)
end

-- ============================================================
--  MONITOR 10: AUTOMATIZAR (3x3, interactivo)
--  Tareas CRUD + Reglas
-- ============================================================
local scr10 = {}

function scr10.menu(ctx)
    ctx:header("Auto")
    local tstats = tasks.countEnabled() .. "/" .. tasks.count()
    local rstats = #st.rules
    local y = 2
    ctx:btn(2, y, ctx.W - 2, 2, "TASKS(" .. tstats .. ")", colors.white, colors.blue, function()
        ctx:goTo("tasks_list")
    end); y = y + 3
    ctx:btn(2, y, ctx.W - 2, 2, "RULES(" .. rstats .. ")", colors.white, colors.purple, function()
        ctx:goTo("rules_list")
    end); y = y + 3
    ctx:btn(2, y, ctx.W - 2, 1, "REFRESH INV", colors.black, colors.lightGray, function()
        lib.refreshInventories()
        lib.tLog("[SYS] Refresh: " .. #st.inventories .. " inv")
    end)
    local rs = st.rulesRunning and "ON" or "OFF"
    ctx:footer("Rules:" .. rs .. " Inv:" .. #st.inventories)
end

-- Tasks list
function scr10.tasks_list(ctx)
    ctx:header("Tasks")
    ctx:btn(2, 2, ctx.W - 2, 1, "+NEW", colors.white, colors.green, function()
        lib.refreshInventories(); ctx:goTo("task_type")
    end)
    if tasks.count() == 0 then
        ctx:write(2, 4, "Empty", colors.gray, colors.black); return
    end
    local y = 4; local n = ctx.nav
    local si = (n.page - 1) * n.perPage + 1
    local ei = math.min(n.page * n.perPage, #st.tasks)
    for i = si, ei do
        if y + 2 > ctx.H - 2 then break end
        local idx = i  -- capture index for closures
        local t = st.tasks[i]
        local bg = t.enabled and colors.gray or colors.brown
        local sc = colors.white
        if t.status == "running" then sc = colors.yellow
        elseif t.status == "done" then sc = colors.lime
        elseif t.status == "error" then sc = colors.red end
        local tp = t.type == "drain" and "E" or "M"
        local lp = t.loop and ("c/" .. t.interval .. "s") or "1x"
        local nm = t.name
        if #nm > ctx.W - 16 then nm = nm:sub(1, ctx.W - 18) .. ".." end
        ctx:fill(2, y, ctx.W - 11, 2, bg)
        ctx:write(3, y, nm, colors.white, bg)
        ctx:write(3, y + 1, tp .. "|" .. lp .. "|" .. t.status:sub(1, 1), sc, bg)
        local bw = 4
        ctx:btn(ctx.W - 10, y, bw, 2, t.enabled and "ON" or "OF", colors.white, t.enabled and colors.green or colors.red, function()
            tasks.toggle(idx)
        end)
        ctx:btn(ctx.W - 5, y, 4, 2, "X", colors.white, colors.red, function()
            tasks.delete(idx)
        end)
        y = y + 3
    end
    ctx:paginate(tasks.count())
    ctx:footer(tasks.countEnabled() .. "/" .. tasks.count())
end

-- Task creation flow
function scr10.task_type(ctx)
    ctx:header("Tarea: Tipo")
    local y = 3
    ctx:btn(3, y, ctx.W - 4, 2, "TRANSFERIR ITEM", colors.white, colors.green, function()
        ctx.nav._taskType = "transfer"; ctx:goTo("task_from")
    end); y = y + 3
    ctx:btn(3, y, ctx.W - 4, 2, "VACIAR INVENTARIO", colors.white, colors.orange, function()
        ctx.nav._taskType = "drain"; ctx:goTo("task_from")
    end)
end

function scr10.task_from(ctx)
    compSelectInv(ctx, "Tarea: Origen", function(inv)
        ctx.nav.fromInv = inv
        if ctx.nav._taskType == "drain" then
            ctx:goTo("task_to")
        else
            ctx.nav.items = lib.getItems(inv)
            ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
            ctx:goTo("task_item")
        end
    end)
end

function scr10.task_item(ctx)
    compItemList(ctx, "Tarea: Item", function(item)
        ctx.nav.selectedItem = item; ctx.nav.cantidad = 0
        ctx:goTo("task_qty")
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
        ctx:goTo("task_to")
    end)
end

function scr10.task_to(ctx)
    compSelectInv(ctx, "Tarea: Destino", function(inv)
        ctx.nav.toInv = inv; ctx:goTo("task_config")
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr10.task_config(ctx)
    ctx:header("Config")
    local n = ctx.nav; local y = 2
    local tp = n._taskType == "drain" and "E" or "M"
    local it = n._taskType == "drain" and "all" or (n.selectedItem and sn(n.selectedItem.name) or "?")
    if #it > ctx.W - 6 then it = it:sub(1, ctx.W - 8) .. ".." end
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, tp .. ":" .. it, colors.white, colors.gray)
    y = y + 2
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 1, "LOOP", colors.white, n._taskLoop and colors.green or colors.gray, function() n._taskLoop = true end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 1, "1X", colors.white, (not n._taskLoop) and colors.green or colors.gray, function() n._taskLoop = false end)
    y = y + 2
    if n._taskLoop then
        ctx:write(2, y, "Ival:", colors.lightGray, colors.black); y = y + 1
        local ints = { 5, 10, 30, 60 }
        local bw = math.floor((ctx.W - 2) / 4)
        for idx, val in ipairs(ints) do
            local bx = 2 + (idx - 1) * bw
            ctx:btn(bx, y, bw - 1, 1, tostring(val), colors.white, n._taskInterval == val and colors.green or colors.blue, function()
                n._taskInterval = val
            end)
        end
        y = y + 2
    end
    ctx:btn(2, y, ctx.W - 2, 1, "CREATE", colors.black, colors.lime, function()
        local iname = n._taskType == "drain" and "*" or (n.selectedItem and n.selectedItem.name or "*")
        tasks.create({
            name     = sn(iname):sub(1, 8) .. ">" .. lib.shortName(n.toInv.name):sub(1, 8),
            type     = n._taskType,
            from     = n.fromInv.name,
            to       = n.toInv.name,
            item     = iname,
            cantidad = n._taskType == "drain" and 0 or (n.cantidad or 0),
            interval = n._taskInterval or 10,
            loop     = n._taskLoop ~= false,
        })
        n.screen = "tasks_list"; n.history = {}; n.fromInv = nil; n.toInv = nil; n.selectedItem = nil; n.page = 1
    end)
end

-- Rules
function scr10.rules_list(ctx)
    ctx:header("Rules")
    local tl = st.rulesRunning and "ON" or "OFF"
    local tc = st.rulesRunning and colors.green or colors.red
    ctx:btn(ctx.W - 5, 2, 5, 1, tl, colors.white, tc, function()
        st.rulesRunning = not st.rulesRunning
        lib.tLog("Rules: " .. (st.rulesRunning and "ON" or "OFF"))
    end)
    ctx:btn(2, 2, 5, 1, "+NEW", colors.white, colors.green, function()
        lib.refreshInventories(); ctx:goTo("rule_from")
    end)
    if #st.rules == 0 then ctx:write(2, 4, "Empty", colors.gray, colors.black); return end
    local y = 4
    local n = ctx.nav
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #st.rules)
    for i = si, ei do
        if y + 2 > ctx.H - 2 then break end
        local idx = i  -- capture index for closures
        local rule = st.rules[i]
        local si2 = rule.item == "*" and "ALL" or sn(rule.item)
        if #si2 > ctx.W - 14 then si2 = si2:sub(1, ctx.W - 16) .. ".." end
        local bg = rule.enabled and colors.gray or colors.brown
        ctx:fill(2, y, ctx.W - 10, 2, bg)
        ctx:write(3, y, si2, colors.white, bg)
        local route = lib.shortName(rule.from):sub(1, 6) .. ">" .. lib.shortName(rule.to):sub(1, 6)
        ctx:write(3, y + 1, rule.interval .. "s " .. route, colors.yellow, bg)
        ctx:btn(ctx.W - 9, y, 4, 2, rule.enabled and "ON" or "OF", colors.white, rule.enabled and colors.green or colors.red, function()
            st.rules[idx].enabled = not st.rules[idx].enabled; lib.saveRules()
        end)
        ctx:btn(ctx.W - 4, y, 4, 2, "X", colors.white, colors.red, function()
            table.remove(st.rules, idx)
            lib.saveRules()
            lib.tLog("Regla eliminada")
        end)
        y = y + 3
    end
    ctx:paginate(#st.rules)
    ctx:footer(#st.rules .. " rules")
end

function scr10.rule_from(ctx)
    compSelectInv(ctx, "Regla: Origen", function(inv)
        ctx.nav.fromInv = inv
        ctx.nav.items = lib.getItems(inv); ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
        ctx:goTo("rule_item")
    end)
end

function scr10.rule_item(ctx)
    ctx:header("Regla: Que mover?")
    local y = 3
    ctx:btn(2, y, ctx.W - 2, 2, "MOVER TODO (*)", colors.white, colors.purple, function()
        ctx.nav.selectedItem = { name = "*", total = 0 }
        lib.refreshInventories(); ctx:goTo("rule_to")
    end)
    y = y + 3
    local di = ctx.nav.filteredItems
    local pp = ctx.nav.perPage
    local si = (ctx.nav.page - 1) * pp + 1
    local ei = math.min(ctx.nav.page * pp, #di)
    for i = si, ei do
        if y + 2 > ctx.H - 3 then break end
        local item = di[i]
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            ctx.nav.selectedItem = item; lib.refreshInventories()
            ctx:goTo("rule_to")
        end)
        ctx:write(4, y + 1, sn(item.name) .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
end

function scr10.rule_to(ctx)
    compSelectInv(ctx, "Regla: Destino", function(inv)
        ctx.nav.toInv = inv; ctx:goTo("rule_interval")
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr10.rule_interval(ctx)
    ctx:header("Regla: Intervalo")
    local si2 = ctx.nav.selectedItem.name == "*" and "TODO" or sn(ctx.nav.selectedItem.name)
    ctx:write(2, 3, si2 .. ": " .. lib.getAlias(ctx.nav.fromInv.name):sub(1, 12), colors.white, colors.black)
    ctx:write(2, 4, "  -> " .. lib.getAlias(ctx.nav.toInv.name):sub(1, 12), colors.cyan, colors.black)
    local y = 6
    local ints = { 5, 10, 30, 60 }
    for _, secs in ipairs(ints) do
        local lbl = secs < 60 and (secs .. " seg") or ((secs / 60) .. " min")
        ctx:btn(2, y, ctx.W - 2, 1, lbl, colors.white, colors.blue, function()
            table.insert(st.rules, {
                from = ctx.nav.fromInv.name, to = ctx.nav.toInv.name,
                item = ctx.nav.selectedItem.name, cantidad = 0,
                interval = secs, enabled = true, lastRun = 0,
            })
            lib.saveRules()
            lib.tLog("Regla #" .. #st.rules .. " creada: " .. si2 .. " c/" .. secs .. "s")
            ctx.nav.screen = "rules_list"; ctx.nav.history = {}; ctx.nav.fromInv = nil; ctx.nav.toInv = nil; ctx.nav.page = 1
        end)
        y = y + 2
    end
end

-- ============================================================
--  MONITOR 13: INVENTARIO (3x3, interactivo)
--  Explorar inventarios, buscar items, historial
-- ============================================================
local scr13 = {}

function scr13.menu(ctx)
    ctx:header("Inv")
    local y = 2
    local hw = math.floor((ctx.W - 3) / 2)
    ctx:btn(2, y, hw, 2, "BROWSE", colors.white, colors.cyan, function()
        lib.refreshInventories(); ctx:goTo("inv_list")
    end)
    ctx:btn(2 + hw + 1, y, hw, 2, "FIND", colors.white, colors.orange, function()
        lib.refreshInventories(); ctx:goTo("search_all")
        local all, map = {}, {}
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
    end); y = y + 3
    ctx:btn(2, y, hw, 2, "HISTORY", colors.white, colors.purple, function()
        ctx:goTo("history")
    end)
    ctx:btn(2 + hw + 1, y, hw, 2, "RENAME", colors.white, colors.blue, function()
        lib.refreshInventories(); ctx:goTo("rename_list")
    end); y = y + 3
    ctx:btn(2, y, hw, 2, "LABELS", colors.black, colors.yellow, function()
        ctx:goTo("labels_menu")
    end)
    ctx:btn(2 + hw + 1, y, hw, 2, "REFRESH", colors.black, colors.lightGray, function()
        lib.refreshInventories()
        lib.tLog("[SYS] Refresh: " .. #st.inventories .. " inv")
    end)
    ctx:footer(#st.inventories .. " inv | " .. #st.labels .. " labels")
end

function scr13.inv_list(ctx)
    compSelectInv(ctx, "Selecciona Inventario", function(inv)
        ctx.nav.fromInv = inv
        ctx.nav.items = lib.getItems(inv)
        ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
        ctx:goTo("inv_detail")
    end)
end

function scr13.inv_detail(ctx)
    ctx:header("Items")
    local inv = ctx.nav.fromInv
    local name = lib.getAlias(inv.name)
    if #name > ctx.W - 4 then name = name:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, 2, name, colors.cyan, colors.black)
    local di = ctx.nav.filteredItems
    if #di == 0 then ctx:write(2, 4, "Empty", colors.gray, colors.black); return end
    local pp = ctx.nav.perPage
    local si = (ctx.nav.page - 1) * pp + 1
    local ei = math.min(ctx.nav.page * pp, #di)
    local y = 3
    for i = si, ei do
        local item = di[i]
        local n2 = sn(item.name)
        if #n2 > ctx.W - 8 then n2 = n2:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:fill(2, y, ctx.W - 2, 2, bg)
        ctx:write(3, y, n2 .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items")
end

function scr13.search_all(ctx)
    ctx:header("Search")
    local n = ctx.nav
    if n.searchText ~= "" then
        ctx:write(2, 2, "Filt:" .. n.searchText, colors.yellow, colors.black)
    end
    ctx:btn(ctx.W - 8, 2, 8, 1, "KBD", colors.white, colors.orange, function()
        n.screen = "search_kb"
    end)
    local di = n.filteredItems
    if #di == 0 then ctx:write(2, 4, "No match", colors.gray, colors.black); return end
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #di)
    local y = 3
    for i = si, ei do
        local item = di[i]
        local n2 = sn(item.name)
        if #n2 > ctx.W - 12 then n2 = n2:sub(1, ctx.W - 14) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:fill(2, y, ctx.W - 2, 2, bg)
        ctx:write(3, y, n2 .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " found")
end

function scr13.search_kb(ctx)
    ctx:header("Type")
    local n = ctx.nav; local y = 2
    for i = 1, math.min(2, #n.filteredItems) do
        local nm = sn(n.filteredItems[i].name)
        if #nm > ctx.W - 4 then nm = nm:sub(1, ctx.W - 6) .. ".." end
        ctx:write(3, y, nm, colors.lightGray, colors.black)
        y = y + 1
    end
    compKeyboard(ctx, function() n.screen = "search_all" end)
end

function scr13.history(ctx)
    ctx:header("History")
    if #st.history == 0 then ctx:write(2, 3, "Empty", colors.gray, colors.black); return end
    ctx:btn(ctx.W - 7, 2, 7, 1, "CLR", colors.white, colors.red, function()
        st.history = {}; lib.saveHistory(); lib.tLog("History cleared")
    end)
    local n = ctx.nav
    local si = (n.page - 1) * n.perPage + 1
    local ei = math.min(n.page * n.perPage, #st.history)
    local y = 3
    for i = si, ei do
        local h = st.history[i]
        local si2 = h.item == "*" and "all" or sn(h.item)
        if #si2 > ctx.W - 10 then si2 = si2:sub(1, ctx.W - 12) .. ".." end
        local ok = h.moved >= h.requested
        local bg = (i % 2 == 0) and colors.gray or colors.black
        ctx:fill(2, y, ctx.W - 2, 2, bg)
        ctx:write(3, y, si2 .. " " .. h.moved .. "x", colors.white, bg)
        local route = lib.shortName(h.from):sub(1, 8) .. ">" .. lib.shortName(h.to):sub(1, 8)
        ctx:write(3, y + 1, h.time .. " " .. route, ok and colors.lime or colors.orange, bg)
        y = y + 3
    end
    ctx:paginate(#st.history)
    ctx:footer(#st.history .. " registros")
end

-- Labels management
local LABEL_COLORS = {
    { name = "Red",     col = colors.red },
    { name = "Blue",    col = colors.blue },
    { name = "Green",   col = colors.green },
    { name = "Yellow",  col = colors.yellow },
    { name = "Orange",  col = colors.orange },
    { name = "Purple",  col = colors.purple },
    { name = "Cyan",    col = colors.cyan },
    { name = "Lime",    col = colors.lime },
    { name = "Pink",    col = colors.pink },
    { name = "White",   col = colors.white },
    { name = "LtBlue",  col = colors.lightBlue },
    { name = "Magenta", col = colors.magenta },
    { name = "Brown",   col = colors.brown },
    { name = "LtGray",  col = colors.lightGray },
}

function scr13.labels_menu(ctx)
    ctx:header("Labels")
    ctx:btn(2, 2, ctx.W - 2, 1, "+ NEW LABEL", colors.white, colors.green, function()
        ctx.nav._extraMons = lib.getExtraMonitors()
        ctx:goTo("label_mon")
    end)
    if #st.labels == 0 then
        ctx:write(2, 4, "No labels", colors.gray, colors.black)
        ctx:footer("Paint monitors!")
        return
    end
    local y = 4
    local n = ctx.nav
    local si = (n.page - 1) * n.perPage + 1
    local ei = math.min(n.page * n.perPage, #st.labels)
    for i = si, ei do
        if y + 2 > ctx.H - 2 then break end
        local idx = i  -- capture index for closures
        local lb = st.labels[i]
        local col = lb.color or colors.blue
        local invAlias = lib.getAlias(lb.inventory)
        if #invAlias > ctx.W - 12 then invAlias = invAlias:sub(1, ctx.W - 14) .. ".." end
        ctx:fill(2, y, ctx.W - 6, 2, col)
        local fg = lib.contrastFg(col)
        ctx:write(3, y, invAlias, fg, col)
        local mn = lb.monitor
        if #mn > ctx.W - 8 then mn = mn:sub(1, ctx.W - 10) .. ".." end
        ctx:write(3, y + 1, mn, fg, col)
        ctx:btn(ctx.W - 4, y, 4, 2, "X", colors.white, colors.red, function()
            lib.removeLabel(idx)
        end)
        y = y + 3
    end
    ctx:paginate(#st.labels)
    ctx:footer(#st.labels .. " labels")
end

function scr13.label_mon(ctx)
    ctx:header("Label: Monitor")
    local mons = ctx.nav._extraMons or {}
    if #mons == 0 then
        ctx:write(2, 3, "No hay monitores", colors.red, colors.black)
        ctx:write(2, 4, "extra en la red", colors.red, colors.black)
        ctx:footer("Conecta mas monitores")
        return
    end
    local n = ctx.nav
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #mons)
    local y = 3
    for i = si, ei do
        local mn = mons[i]
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        -- Check if already labeled
        local used = false
        for _, lb in ipairs(st.labels) do
            if lb.monitor == mn then used = true; break end
        end
        if used then bg = colors.brown end
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            ctx.nav._selMon = mn
            lib.refreshInventories()
            ctx:goTo("label_inv")
        end)
        local display = mn
        if #display > ctx.W - 4 then display = display:sub(1, ctx.W - 6) .. ".." end
        ctx:write(4, y, display, colors.white, bg)
        if used then ctx:write(ctx.W - 5, y, "USED", colors.red, bg) end
        y = y + 3
    end
    ctx:paginate(#mons)
    ctx:footer(#mons .. " monitors")
end

function scr13.label_inv(ctx)
    compSelectInv(ctx, "Label: Inventario", function(inv)
        ctx.nav._selInv = inv.name
        ctx:goTo("label_color")
    end)
end

function scr13.label_color(ctx)
    ctx:header("Label: Color")
    local n = ctx.nav
    local y = 2
    local cols = 3
    local bw = math.floor((ctx.W - 2) / cols)
    for i, entry in ipairs(LABEL_COLORS) do
        local row = math.floor((i - 1) / cols)
        local col2 = ((i - 1) % cols)
        local bx = 2 + col2 * bw
        local by = y + row * 2
        if by + 1 > ctx.H - 2 then break end
        local fg = lib.contrastFg(entry.col)
        ctx:btn(bx, by, bw - 1, 2, entry.name:sub(1, bw - 2), fg, entry.col, function()
            lib.addLabel(n._selMon, n._selInv, entry.col)
            n.screen = "labels_menu"; n.history = {}; n.page = 1
            n._selMon = nil; n._selInv = nil; n._extraMons = nil
        end)
    end
end

-- Rename inventories
function scr13.rename_list(ctx)
    ctx:header("Rename")
    local invs = st.inventories
    if #invs == 0 then
        ctx:write(2, 3, "No inventarios", colors.red, colors.black)
        return
    end
    local n = ctx.nav
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #invs)
    local y = 3
    for i = si, ei do
        local inv = invs[i]
        local alias = st.aliases[inv.name]
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            n._renameInv = inv.name
            n.searchText = alias or ""
            n.screen = "rename_kb"
        end)
        local display = alias or lib.shortName(inv.name)
        if #display > ctx.W - 4 then display = display:sub(1, ctx.W - 6) .. ".." end
        ctx:write(4, y, display, colors.white, bg)
        if alias then
            local orig = lib.shortName(inv.name)
            if #orig > ctx.W - 4 then orig = orig:sub(1, ctx.W - 6) .. ".." end
            ctx:write(4, y + 1, orig, colors.lightGray, bg)
        end
        y = y + 3
    end
    ctx:paginate(#invs)
    ctx:footer("Select to rename")
end

function scr13.rename_kb(ctx)
    ctx:header("Rename")
    local n = ctx.nav
    local orig = n._renameInv or "?"
    if #orig > ctx.W - 4 then orig = orig:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, 2, orig, colors.gray, colors.black)
    compKeyboard(ctx, function()
        if n.searchText ~= "" then
            lib.setAlias(n._renameInv, n.searchText)
            lib.tLog("[ALIAS] " .. n._renameInv:sub(1, 12) .. " = " .. n.searchText)
        else
            lib.setAlias(n._renameInv, nil)
            lib.tLog("[ALIAS] Removed for " .. n._renameInv:sub(1, 12))
        end
        n.screen = "rename_list"; n.history = {}; n.page = 1; n._renameInv = nil; n.searchText = ""
    end)
end

-- ============================================================
--  MONITOR 12: DASHBOARD (2x7, techo, auto-refresh)
-- ============================================================

local function renderDashboard(ctx)
    ctx:clear(colors.black)
    ctx:fill(1, 1, ctx.W, 1, colors.blue)
    ctx:write(2, 1, "DB " .. fmtElapsed(os.clock() - st.startTime), colors.white, colors.blue)

    local y = 2

    -- Inventarios - condensed (uses cached fill data)
    lib.refreshFillCache()
    ctx:write(2, y, "INV", colors.yellow, colors.black); y = y + 1
    for i, inv in ipairs(st.inventories) do
        if y >= ctx.H - 3 then break end
        local used, total = lib.getInventoryFill(inv)
        local pct = total > 0 and math.floor(used / total * 100) or 0
        local shortName = lib.getAlias(inv.name):sub(1, 10)
        local col = pct > 90 and colors.red or (pct > 60 and colors.orange or colors.green)
        ctx:write(2, y, shortName .. " " .. pct .. "%", col, colors.black)
        y = y + 1
    end

    if #st.inventories == 0 then
        ctx:write(2, y, "None", colors.gray, colors.black); y = y + 1
    end
    y = y + 1

    -- Worker status
    if st.workerActive then
        local ws = st.workerStats
        ctx:write(2, y, "WK:" .. ws.cycles .. "c " .. ws.totalMoved .. "i", colors.lime, colors.black); y = y + 1
    else
        ctx:write(2, y, "WK:off", colors.gray, colors.black); y = y + 1
    end

    -- Tasks
    if tasks.count() > 0 then
        ctx:write(2, y, "TSK:" .. tasks.countEnabled() .. "/" .. tasks.count(), colors.cyan, colors.black); y = y + 1
    end
    y = y + 1

    -- Recent activity
    local log = lib.termLog
    local maxLines = ctx.H - y
    for i = 1, math.min(#log, maxLines) do
        local l = log[i]
        local col = colors.lightGray
        if l:find("ERROR") then col = colors.red
        elseif l:find("OK") or l:find("LISTO") then col = colors.lime end
        local text = l:sub(1, ctx.W - 2)
        ctx:write(2, y, text, col, colors.black)
        y = y + 1
    end
end

local function renderActivity(ctx)
    ctx:clear(colors.black)
    ctx:fill(1, 1, ctx.W, 1, colors.purple)
    ctx:write(2, 1, "ACT " .. textutils.formatTime(os.time(), true), colors.white, colors.purple)

    local y = 2

    -- Stats
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, "XFR:" .. st.totalTransfers .. " M:" .. st.totalMoved, colors.yellow, colors.gray)
    y = y + 2

    -- Log
    local log = lib.termLog
    local maxLines = ctx.H - y
    for i = 1, math.min(#log, maxLines) do
        local l = log[i]
        local col = colors.lightGray
        if l:find("ERROR") then col = colors.red
        elseif l:find("OK") or l:find("LISTO") then col = colors.lime end
        local text = l:sub(1, ctx.W - 2)
        ctx:write(2, y, text, col, colors.black)
        y = y + 1
    end
end

ui.monitors = {}

function ui.init()
    local ids = lib.MON_IDS
    local labels = {
        control = "CONTROL", tasks = "AUTOMATIZAR", browse = "INVENTARIO",
        dashboard = "DASHBOARD", activity = "ACTIVIDAD",
    }
    local scales = {
        control = 1.0, tasks = 1.0, browse = 1.0,
        dashboard = 1.0, activity = 1.0,
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

function ui.processPending()
    if not ui.pendingAction then return end
    local action = ui.pendingAction
    ui.pendingAction = nil

    if action.type == "xfer" then
        local movido = lib.moveItems(action.fromInv.peripheral, action.toInv.name, action.selectedItem.name, action.cantidad)
        action.ctx.nav._moved = movido
        if movido > 0 then
            lib.tLog("OK: " .. movido .. "x " .. sn(action.selectedItem.name) .. " -> " .. lib.getAlias(action.toInv.name))
        else
            lib.tLog("ERROR: No se movio " .. sn(action.selectedItem.name))
        end
        lib.addHistory(action.fromInv.name, action.toInv.name, action.selectedItem.name, action.cantidad, movido)
        action.ctx.nav.screen = "xfer_result"
    elseif action.type == "bulk" then
        local result = lib.moveAllItems(action.fromInv, action.toInv, function(prog)
            local ctx = action.ctx
            ctx:fill(1, 3, ctx.W, ctx.H - 4, colors.black)
            local pct = prog.total > 0 and math.floor(prog.processed / prog.total * 100) or 0
            local bw = ctx.W - 4
            local filled = math.floor(bw * pct / 100)
            ctx:write(2, 4, "Prog:", colors.gray, colors.black)
            ctx:fill(2, 5, bw, 1, colors.gray)
            if filled > 0 then ctx:fill(2, 5, filled, 1, colors.green) end
            ctx:write(math.floor(ctx.W / 2) - 1, 5, pct .. "%", colors.white, colors.gray)
            ctx:write(2, 6, "Mv:" .. prog.moved, colors.yellow, colors.black)
            if prog.current then
                local cur = sn(prog.current)
                if #cur > ctx.W - 6 then cur = cur:sub(1, ctx.W - 8) .. ".." end
                ctx:write(2, 7, cur, colors.cyan, colors.black)
            end
            if prog.destFull then
                ctx:fill(2, 8, ctx.W - 2, 1, colors.red)
                ctx:write(3, 8, "FULL!", colors.white, colors.red)
            end
            ctx:footer("Wait...")
        end)
        action.ctx.nav.bulkResult = result
        lib.tLog("OK: " .. lib.getAlias(action.fromInv.name) .. " -> " .. result.total .. " items")
        for _, item in ipairs(result.items) do
            if item.moved > 0 then lib.addHistory(action.fromInv.name, action.toInv.name, item.name, item.moved + item.failed, item.moved) end
        end
        action.ctx.nav.screen = "bulk_result"
    elseif action.type == "group" then
        local result = lib.groupItems(function(prog)
            local ctx = action.ctx
            ctx:fill(1, 3, ctx.W, ctx.H - 4, colors.black)
            local pct = prog.total > 0 and math.floor(prog.processed / prog.total * 100) or 0
            local bw = ctx.W - 4
            local filled = math.floor(bw * pct / 100)
            ctx:fill(2, 4, bw, 1, colors.gray)
            if filled > 0 then ctx:fill(2, 4, filled, 1, colors.purple) end
            ctx:write(math.floor(ctx.W / 2) - 1, 4, pct .. "%", colors.white, colors.gray)
            ctx:write(2, 6, "Mv:" .. prog.moved .. " Grp:" .. prog.grouped, colors.yellow, colors.black)
            if prog.current then
                local cur = (prog.current:match(":(.+)") or prog.current)
                if #cur > ctx.W - 4 then cur = cur:sub(1, ctx.W - 6) .. ".." end
                ctx:write(2, 7, cur, colors.cyan, colors.black)
            end
            ctx:footer("Grouping...")
        end)
        action.ctx.nav._grpResult = result
        action.ctx.nav.screen = "grp_result"
    end
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
