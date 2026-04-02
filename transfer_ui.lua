-- ============================================================
--  transfer_ui.lua  v5.3
--  Sistema multi-monitor con contextos independientes.
--  5 monitores: 3 interactivos (3x3) + 2 dashboards (2x7)
--  Enterprise: restock, categories, audit, lock, quick send, KPIs
-- ============================================================

local lib     = require("transfer_lib")
local tasks   = require("transfer_tasks")
local worker  = require("transfer_worker")
local alerts  = require("transfer_alerts")
local restock = require("transfer_restock")

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
        perPage      = math.max(1, math.floor((ctx.H - 3) / 3)),
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
        -- Favorite star
        local isFav = lib.isFavorite(inv.name)
        ctx:btn(2, y, ctx.W - 2, 2, "", fg, bg, function()
            if filterOut and inv.name == filterOut then return end
            onSelect(inv)
        end)
        if isFav then
            ctx:write(3, y, "*", colors.yellow, bg)
            ctx:write(5, y, name, fg, bg)
        else
            ctx:write(4, y, name, fg, bg)
        end
        local used, total = lib.getInventoryFill(inv)
        local pct = total > 0 and math.floor(used / total * 100) or 0
        local fillCol = pct > 90 and colors.red or (pct > 60 and colors.orange or colors.lightGray)
        ctx:write(ctx.W - 8, y, pct .. "% " .. total .. "s", fillCol, bg)
        -- Category tag + Disconnect indicator
        local cat = lib.getCategory(inv.name)
        if cat then
            local catCol = lib.CATEGORY_COLORS[cat] or colors.lightGray
            ctx:write(3, y + 1, cat:sub(1, 3), catCol, bg)
        end
        if st.disconnected[inv.name] then
            ctx:write(ctx.W - 2, y + 1, "DC", colors.red, bg)
        end
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
        local sname = item.name:match(":(.+)") or item.name
        if #sname > ctx.W - 8 then sname = sname:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function() onSelect(item) end)
        ctx:write(4, y, sname .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items")
end

local function compKeyboard(ctx, onConfirm)
    local n = ctx.nav
    local keys = { "A B C D E F G", "H I J K L M N", "O P Q R S T U", "V W X Y Z _", "1 2 3 4 5 6 7", "8 9 0 * : ." }
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
    local sname = n.selectedItem and (n.selectedItem.name:match(":(.+)") or n.selectedItem.name) or "?"
    if #sname > ctx.W - 6 then sname = sname:sub(1, ctx.W - 8) .. ".." end
    ctx:write(2, 2, "Item: " .. sname, colors.white, colors.black)
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

-- ============================================================
--  Help pages (shared component)
-- ============================================================

local HELP_PAGES = {
    control = {
        { title = "CONTROL", lines = {
            "Este monitor maneja",
            "operaciones manuales.",
            "",
            "TRANSFER: Mueve un item",
            "de un inv a otro.",
            "Selecciona origen, item,",
            "cantidad y destino.",
            "",
            "EMPTY: Vacia todo un",
            "inventario a otro.",
        }},
        { title = "CONTROL 2", lines = {
            "WORKER: Vaciado continuo",
            "y automatico. Repite cada",
            "N segundos. Util para",
            "granjas o maquinas.",
            "",
            "GROUP: Consolida items.",
            "Mueve cada tipo de item",
            "al inv que ya tiene mas",
            "de ese tipo. Organiza",
            "tu almacen.",
        }},
        { title = "CONTROL 3", lines = {
            "UNDO: Despues de transfer",
            "o empty, puedes revertir",
            "la operacion con el boton",
            "UNDO en la pantalla de",
            "resultado.",
            "",
            "REFRESH: Actualiza la",
            "lista de inventarios",
            "conectados a la red.",
        }},
    },
    tasks = {
        { title = "AUTOMATIZAR", lines = {
            "Automatiza movimientos",
            "de items con tareas y",
            "reglas periodicas.",
            "",
            "TASKS: Tareas con mas",
            "opciones. Loop o 1 vez,",
            "intervalo, nombre, y",
            "programacion por hora.",
        }},
        { title = "TASKS: Tipos", lines = {
            "TRANSFERIR: Mueve un item",
            "especifico entre dos inv.",
            "",
            "VACIAR: Mueve todo el",
            "contenido de un inv.",
            "",
            "RECOLECTAR: Busca un item",
            "en TODOS los inv y lo",
            "lleva a un destino.",
        }},
        { title = "MULTI SELECT", lines = {
            "MULTI ITEMS: Selecciona",
            "varios items de un inv.",
            "Crea una tarea por cada",
            "item seleccionado.",
            "",
            "Toca items para marcar/",
            "desmarcar. Luego elige",
            "destino y configuracion.",
        }},
        { title = "RULES", lines = {
            "RULES: Reglas simples.",
            "Mueve items cada N segs.",
            "ON/OFF global con boton.",
            "",
            "Soporta patrones glob:",
            "  *ore* = cualquier mena",
            "  *ingot* = cualquier",
            "  lingote",
        }},
        { title = "ALERTS", lines = {
            "ALERTS: Monitorea stock.",
            "Alerta cuando un item",
            "sube o baja de un umbral.",
            "",
            "Puede activar redstone",
            "en un lado del computer.",
            "Util para saber cuando",
            "falta material.",
        }},
        { title = "RESTOCK", lines = {
            "RESTOCK: Mantiene stock",
            "automaticamente.",
            "",
            "Define MIN y MAX para",
            "un item en un inventario.",
            "Cuando baja del minimo,",
            "busca en otros inv y",
            "llena hasta el maximo.",
            "",
            "Ideal para maquinas que",
            "consumen materiales.",
        }},
        { title = "SCHEDULE", lines = {
            "Las tareas pueden tener",
            "un horario de Minecraft.",
            "",
            "SET SCHEDULE en la config",
            "de tarea. Ejemplo: 6.0",
            "= amanecer, 18.0 = noche",
            "",
            "Se ejecuta 1 vez por dia",
            "de juego al pasar la hora",
        }},
        { title = "PATTERNS", lines = {
            "Usa patrones con * para",
            "coincidir multiples items",
            "",
            "Ejemplos:",
            "  *ore*    -> iron_ore,",
            "             gold_ore...",
            "  *ingot*  -> iron_ingot",
            "  *diamond*-> todo con",
            "             diamond",
        }},
    },
    browse = {
        { title = "INVENTARIO", lines = {
            "Explora y administra",
            "tus inventarios.",
            "",
            "BROWSE: Ve el contenido",
            "de cada inventario.",
            "",
            "FIND: Busca un item en",
            "TODOS los inventarios",
            "conectados a la red.",
        }},
        { title = "INVENTARIO 2", lines = {
            "HISTORY: Historial de",
            "transferencias. Puedes",
            "deshacer con el boton <-",
            "",
            "RENAME: Nombra tus inv",
            "con nombres amigables.",
            "Se muestra en todas las",
            "pantallas.",
        }},
        { title = "INVENTARIO 3", lines = {
            "LABELS: Pinta monitores",
            "externos con el nombre",
            "de un inventario y un",
            "color. Decorativo!",
            "",
            "SETTINGS:",
            "  Compact: 1 linea/item",
            "  Favorites: Marca inv",
            "  para que aparezcan",
            "  primero en las listas.",
        }},
        { title = "QUICK SEND", lines = {
            "QUICK SEND: Desde Browse",
            "toca >> junto a un item",
            "para enviarlo directo a",
            "otro inventario.",
            "",
            "Elige cantidad y destino",
            "sin salir de la vista",
            "de inventario.",
        }},
        { title = "CATEGORIES", lines = {
            "CATEGORIES: Clasifica tus",
            "inventarios en zonas:",
            "",
            "  ENT = Entrada",
            "  ALM = Almacen",
            "  PRO = Produccion",
            "  SAL = Salida",
            "",
            "Se muestra con color en",
            "listas y dashboard.",
        }},
        { title = "AUDIT LOG", lines = {
            "AUDIT: Registro permanente",
            "de todas las operaciones.",
            "Sobrevive reinicios.",
            "",
            "Filtra por tipo:",
            "  XFER, TASK, RSTK, ALRT",
            "",
            "Mantiene las ultimas 500",
            "entradas en disco.",
        }},
        { title = "LOCK / PIN", lines = {
            "LOCK: Protege el sistema",
            "con un PIN de 4 digitos.",
            "",
            "Configurar en SETTINGS >",
            "SET PIN. Cuando se activa",
            "bloquea todos los",
            "monitores.",
            "",
            "Desbloquea ingresando el",
            "PIN en monitor CONTROL.",
        }},
    },
}

local function compHelp(ctx, monKey)
    local pages = HELP_PAGES[monKey]
    if not pages then return end
    local n = ctx.nav
    local pageIdx = n._helpPage or 1
    if pageIdx > #pages then pageIdx = #pages end
    local page = pages[pageIdx]
    ctx:header("? " .. page.title)
    local y = 3
    for _, line in ipairs(page.lines) do
        if y >= ctx.H - 2 then break end
        local col = colors.white
        if line == "" then col = colors.black
        elseif line:sub(1, 2) == "  " then col = colors.yellow
        end
        ctx:write(2, y, line, col, colors.black)
        y = y + 1
    end
    -- Pagination
    local by = ctx.H - 1
    if #pages > 1 then
        if pageIdx > 1 then
            ctx:btn(2, by, 6, 1, "< ANT", colors.white, colors.cyan, function()
                n._helpPage = pageIdx - 1
            end)
        end
        ctx:write(math.floor(ctx.W / 2) - 2, by, pageIdx .. "/" .. #pages, colors.gray, colors.black)
        if pageIdx < #pages then
            ctx:btn(ctx.W - 6, by, 6, 1, "SIG >", colors.white, colors.cyan, function()
                n._helpPage = pageIdx + 1
            end)
        end
    end
    ctx:footer("Tap < para volver")
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
    -- Help button on header
    ctx:btn(ctx.W - 8, 1, 3, 1, "?", colors.yellow, colors.blue, function()
        ctx.nav._helpPage = 1; ctx:goTo("help")
    end)
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
    -- Disconnect warning
    local discCount = 0
    for _ in pairs(st.disconnected) do discCount = discCount + 1 end
    if discCount > 0 then
        ctx:footer(discCount .. " DISCONNECTED!")
    else
        ctx:footer("Inv: " .. #st.inventories)
    end
end

-- Help
function scr14.help(ctx) compHelp(ctx, "control") end

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
    y = y + 3
    -- Undo button
    if n._moved > 0 and n._lastHistoryIdx then
        ctx:btn(2, y, ctx.W - 2, 1, "UNDO", colors.white, colors.orange, function()
            local entry = st.history[1]
            if entry and entry.undoable then
                ui.queueAction({ type = "undo", ctx = ctx, entry = entry })
            end
        end)
        y = y + 2
    end
    ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
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
    local hasFullItems = r.fullItems and #r.fullItems > 0
    if r.destFull then
        ctx:fill(2, y, ctx.W - 2, 2, colors.red)
        ctx:write(3, y, "INV FULL " .. r.total .. "/" .. r.totalOriginal, colors.white, colors.red)
    elseif hasFullItems then
        ctx:fill(2, y, ctx.W - 2, 2, colors.orange)
        ctx:write(3, y, "PARCIAL " .. r.total .. "/" .. r.totalOriginal, colors.white, colors.orange)
    elseif r.total > 0 then
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, "OK " .. r.total .. " items", colors.white, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 2, colors.red)
        ctx:write(3, y, "FAIL 0 items", colors.white, colors.red)
    end
    y = y + 2

    -- Show items that need more space
    if hasFullItems then
        ctx:fill(2, y, ctx.W - 2, 1, colors.yellow)
        ctx:write(3, y, "SIN ESPACIO:", colors.black, colors.yellow)
        y = y + 1
        local maxFull = math.min(#r.fullItems, 3)
        for i = 1, maxFull do
            local nm = r.fullItems[i]
            if #nm > ctx.W - 4 then nm = nm:sub(1, ctx.W - 6) .. ".." end
            ctx:write(3, y, nm, colors.red, colors.black)
            y = y + 1
        end
        if #r.fullItems > maxFull then
            ctx:write(3, y, "+" .. (#r.fullItems - maxFull) .. " mas", colors.gray, colors.black)
            y = y + 1
        end
    end

    -- Item detail list
    local maxD = math.min(#r.items, ctx.H - y - 4)
    for i = 1, maxD do
        local it = r.items[i]
        local n2 = sn(it.name)
        if #n2 > ctx.W - 8 then n2 = n2:sub(1, ctx.W - 10) .. ".." end
        ctx:write(2, y, n2, colors.white, colors.black)
        local mv = "x" .. it.moved
        ctx:write(ctx.W - #mv - 1, y, mv, it.failed > 0 and colors.orange or colors.lime, colors.black)
        y = y + 1
    end

    -- Undo button
    if r.total > 0 then
        ctx:btn(2, ctx.H - 4, ctx.W - 2, 1, "UNDO", colors.white, colors.orange, function()
            local entry = st.history[1]
            if entry and entry.undoable then
                ui.queueAction({ type = "undo", ctx = ctx, entry = entry })
            end
        end)
    end

    ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
        ctx.nav.screen = "menu"; ctx.nav.history = {}; ctx.nav.fromInv = nil; ctx.nav.toInv = nil
    end)
end

-- Undo result
function scr14.undo_result(ctx)
    ctx:header("Undo")
    local n = ctx.nav
    local y = 3
    if n._undoMoved and n._undoMoved > 0 then
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, "UNDO OK: " .. n._undoMoved .. " items", colors.white, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 2, colors.red)
        ctx:write(3, y, "UNDO FAIL", colors.white, colors.red)
    end
    ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
        n.screen = "menu"; n.history = {}
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
--  Tareas CRUD + Reglas + Alertas
-- ============================================================
local scr10 = {}

function scr10.menu(ctx)
    ctx:header("Auto")
    -- Help button on header
    ctx:btn(ctx.W - 8, 1, 3, 1, "?", colors.yellow, colors.blue, function()
        ctx.nav._helpPage = 1; ctx:goTo("help")
    end)
    local tstats = tasks.countEnabled() .. "/" .. tasks.count()
    local rstats = #st.rules
    local astats = alerts.count()
    local y = 2
    ctx:btn(2, y, ctx.W - 2, 2, "TASKS(" .. tstats .. ")", colors.white, colors.blue, function()
        ctx:goTo("tasks_list")
    end); y = y + 3
    ctx:btn(2, y, ctx.W - 2, 2, "RULES(" .. rstats .. ")", colors.white, colors.purple, function()
        ctx:goTo("rules_list")
    end); y = y + 3
    -- Alerts with triggered count
    local triggered = alerts.countTriggered()
    local alertColor = triggered > 0 and colors.red or colors.orange
    local alertLabel = "ALERTS(" .. astats .. ")"
    if triggered > 0 then alertLabel = alertLabel .. " !" .. triggered end
    local hw = math.floor((ctx.W - 3) / 2)
    ctx:btn(2, y, hw, 2, alertLabel, colors.white, alertColor, function()
        ctx:goTo("alerts_list")
    end)
    -- Restock button
    local rLabel = "RESTOCK(" .. restock.count() .. ")"
    local pulling = restock.countPulling()
    local rColor = pulling > 0 and colors.lime or colors.cyan
    ctx:btn(2 + hw + 1, y, hw, 2, rLabel, colors.white, rColor, function()
        ctx:goTo("restock_list")
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
        local idx = i
        local t = st.tasks[i]
        local bg = t.enabled and colors.gray or colors.brown
        local sc = colors.white
        if t.status == "running" then sc = colors.yellow
        elseif t.status == "done" then sc = colors.lime
        elseif t.status == "error" then sc = colors.red end
        local tp = t.type == "drain" and "E" or (t.type == "collect" and "C" or "M")
        local lp = t.loop and ("c/" .. t.interval .. "s") or "1x"
        if t.scheduleTime then lp = "@" .. string.format("%.1f", t.scheduleTime) end
        local nm = t.name
        if #nm > ctx.W - 16 then nm = nm:sub(1, ctx.W - 18) .. ".." end
        ctx:fill(2, y, ctx.W - 11, 2, bg)
        ctx:write(3, y, nm, colors.white, bg)
        local fromDisp = t.from == "*" and "ALL" or lib.getAlias(t.from):sub(1, 6)
        local route = fromDisp .. ">" .. lib.getAlias(t.to):sub(1, 6)
        ctx:write(3, y + 1, tp .. "|" .. lp .. " " .. route, sc, bg)
        local bw = 4
        ctx:btn(ctx.W - 10, y, bw, 2, t.enabled and "ON" or "OF", colors.white, t.enabled and colors.green or colors.red, function()
            tasks.toggle(idx)
        end)
        ctx:btn(ctx.W - 5, y, 4, 2, "X", colors.white, colors.red, function()
            ctx.nav._deleteIdx = idx
            ctx.nav._deleteType = "task"
            ctx.nav._deleteName = t.name
            ctx:goTo("confirm_delete")
        end)
        y = y + 3
    end
    ctx:paginate(tasks.count())
    ctx:footer(tasks.countEnabled() .. "/" .. tasks.count())
end

-- Delete confirmation screen
function scr10.confirm_delete(ctx)
    ctx:header("Confirmar")
    local n = ctx.nav
    local y = 3
    ctx:fill(2, y, ctx.W - 2, 2, colors.red)
    ctx:write(3, y, "ELIMINAR?", colors.white, colors.red)
    y = y + 3
    local name = n._deleteName or "?"
    if #name > ctx.W - 4 then name = name:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, y, name, colors.yellow, colors.black)
    y = y + 1
    ctx:write(2, y, "Tipo: " .. (n._deleteType or "?"), colors.gray, colors.black)
    y = y + 2
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 2, "NO", colors.white, colors.green, function()
        ctx:goBack()
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "SI", colors.white, colors.red, function()
        if n._deleteType == "task" then
            tasks.delete(n._deleteIdx)
            n.screen = "tasks_list"; n.history = {}; n.page = 1
        elseif n._deleteType == "rule" then
            table.remove(st.rules, n._deleteIdx)
            lib.saveRules()
            lib.tLog("Regla eliminada")
            n.screen = "rules_list"; n.history = {}; n.page = 1
        elseif n._deleteType == "alert" then
            alerts.delete(n._deleteIdx)
            n.screen = "alerts_list"; n.history = {}; n.page = 1
        elseif n._deleteType == "restock" then
            restock.delete(n._deleteIdx)
            n.screen = "restock_list"; n.history = {}; n.page = 1
        end
        n._deleteIdx = nil; n._deleteType = nil; n._deleteName = nil
    end)
end

-- Help
function scr10.help(ctx) compHelp(ctx, "tasks") end

-- Task creation flow
function scr10.task_type(ctx)
    ctx:header("Tarea: Tipo")
    local y = 3
    ctx:btn(3, y, ctx.W - 4, 2, "TRANSFERIR ITEM", colors.white, colors.green, function()
        ctx.nav._taskType = "transfer"; ctx:goTo("task_from")
    end); y = y + 3
    ctx:btn(3, y, ctx.W - 4, 2, "VACIAR INVENTARIO", colors.white, colors.orange, function()
        ctx.nav._taskType = "drain"; ctx:goTo("task_from")
    end); y = y + 3
    ctx:btn(3, y, ctx.W - 4, 2, "RECOLECTAR ITEM", colors.white, colors.cyan, function()
        ctx.nav._taskType = "collect"; ctx:goTo("collect_item")
    end); y = y + 3
    ctx:btn(3, y, ctx.W - 4, 2, "MULTI ITEMS", colors.black, colors.lime, function()
        ctx.nav._multiSelected = {}
        lib.refreshInventories()
        ctx:goTo("multi_from")
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
    ctx:header("Tarea: Item")
    local n = ctx.nav
    -- Pattern input button
    ctx:btn(2, 2, ctx.W - 2, 1, "PATTERN (*ore*)", colors.black, colors.yellow, function()
        n.searchText = ""
        ctx:goTo("task_pattern")
    end)
    -- Search
    if n.searchText ~= "" then
        ctx:write(2, 3, "Filt:" .. n.searchText, colors.yellow, colors.black)
    end
    ctx:btn(ctx.W - 8, 3, 8, 1, "BUSCAR", colors.white, colors.orange, function()
        n._returnScreen = n.screen
        n.screen = "task_item_search"
    end)
    local di = n.filteredItems
    if #di == 0 then
        ctx:write(2, 5, n.searchText ~= "" and "Sin res." or "Vacio", colors.orange, colors.black)
        return
    end
    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #di)
    local y = 4
    for i = si, ei do
        local item = di[i]
        local sname = item.name:match(":(.+)") or item.name
        if #sname > ctx.W - 8 then sname = sname:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            n.selectedItem = item; n.cantidad = 0
            ctx:goTo("task_qty")
        end)
        ctx:write(4, y, sname .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items")
end

-- Pattern input for tasks
function scr10.task_pattern(ctx)
    ctx:header("Pattern")
    local n = ctx.nav
    ctx:write(2, 2, "Ej: *ore* *ingot*", colors.gray, colors.black)
    compKeyboard(ctx, function()
        if n.searchText ~= "" then
            n.selectedItem = { name = n.searchText, total = 0 }
            n.cantidad = 0
            n.searchText = ""
            ctx:goTo("task_to")
        end
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
    local tp = n._taskType == "drain" and "E" or (n._taskType == "collect" and "C" or "M")
    local it = (n._taskType == "drain") and "all" or (n.selectedItem and sn(n.selectedItem.name) or "?")
    if #it > ctx.W - 6 then it = it:sub(1, ctx.W - 8) .. ".." end
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, tp .. ":" .. it, colors.white, colors.gray)
    y = y + 1
    -- Name
    local autoName = n._taskName or (sn(n._taskType == "drain" and "*" or (n.selectedItem and n.selectedItem.name or "*")):sub(1, 8) .. ">" .. lib.getAlias(n.toInv.name):sub(1, 8))
    if not n._taskName then n._taskName = autoName end
    local dispName = n._taskName
    if #dispName > ctx.W - 6 then dispName = dispName:sub(1, ctx.W - 8) .. ".." end
    ctx:write(2, y, "Name: " .. dispName, colors.yellow, colors.black)
    ctx:btn(ctx.W - 7, y, 7, 1, "EDIT", colors.white, colors.orange, function()
        n.searchText = n._taskName or ""
        ctx:goTo("task_name")
    end)
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
    -- Schedule time option
    ctx:btn(2, y, ctx.W - 2, 1, n._taskSchedule and ("SCHED @" .. string.format("%.1f", n._taskSchedule)) or "SET SCHEDULE", colors.white, n._taskSchedule and colors.green or colors.gray, function()
        ctx:goTo("task_schedule")
    end)
    y = y + 2
    ctx:btn(2, y, ctx.W - 2, 1, "CREATE", colors.black, colors.lime, function()
        local iname = n._taskType == "drain" and "*" or (n.selectedItem and n.selectedItem.name or "*")
        local fromName = n._taskType == "collect" and "*" or n.fromInv.name
        tasks.create({
            name     = n._taskName or (sn(iname):sub(1, 8) .. ">" .. lib.getAlias(n.toInv.name):sub(1, 8)),
            type     = n._taskType,
            from     = fromName,
            to       = n.toInv.name,
            item     = iname,
            cantidad = n._taskType == "drain" and 0 or (n.cantidad or 0),
            interval = n._taskInterval or 10,
            loop     = n._taskLoop ~= false,
            scheduleTime = n._taskSchedule,
        })
        n.screen = "tasks_list"; n.history = {}; n.fromInv = nil; n.toInv = nil
        n.selectedItem = nil; n.page = 1; n._taskName = nil; n._taskSchedule = nil
    end)
end

-- Schedule time picker
function scr10.task_schedule(ctx)
    ctx:header("Horario")
    local n = ctx.nav
    if not n._taskSchedule then n._taskSchedule = 6.0 end
    local y = 3
    local timeStr = string.format("%.1f", n._taskSchedule)
    ctx:fill(2, y, ctx.W - 2, 2, colors.gray)
    ctx:write(math.floor(ctx.W / 2) - math.floor(#timeStr / 2), y, timeStr, colors.yellow, colors.gray)
    ctx:write(3, y + 1, "(game time 0-24)", colors.lightGray, colors.gray)
    y = y + 3
    -- Presets
    local presets = { {6, "6:00"}, {8, "8:00"}, {12, "12:00"}, {18, "18:00"}, {0, "0:00"} }
    local bw = math.floor((ctx.W - 2) / #presets)
    for idx, p in ipairs(presets) do
        local bx = 2 + (idx - 1) * bw
        ctx:btn(bx, y, bw - 1, 1, p[2], colors.white, n._taskSchedule == p[1] and colors.green or colors.blue, function()
            n._taskSchedule = p[1]
        end)
    end
    y = y + 2
    -- Fine adjust
    local hw = math.floor((ctx.W - 4) / 4)
    ctx:btn(2, y, hw, 1, "-1h", colors.white, colors.red, function() n._taskSchedule = (n._taskSchedule - 1) % 24 end)
    ctx:btn(2 + hw, y, hw, 1, "-0.5", colors.white, colors.red, function() n._taskSchedule = (n._taskSchedule - 0.5) % 24 end)
    ctx:btn(2 + 2*hw, y, hw, 1, "+0.5", colors.white, colors.green, function() n._taskSchedule = (n._taskSchedule + 0.5) % 24 end)
    ctx:btn(2 + 3*hw, y, hw, 1, "+1h", colors.white, colors.green, function() n._taskSchedule = (n._taskSchedule + 1) % 24 end)
    y = y + 2
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 1, "CLEAR", colors.white, colors.red, function()
        n._taskSchedule = nil
        ctx:goBack()
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 1, "SET", colors.white, colors.green, function()
        ctx:goBack()
    end)
end

-- Task name editor
function scr10.task_name(ctx)
    ctx:header("Nombre")
    local n = ctx.nav
    compKeyboard(ctx, function()
        n._taskName = n.searchText ~= "" and n.searchText or nil
        n.searchText = ""
        ctx:goBack()
    end)
end

-- Collect flow
function scr10.collect_item(ctx)
    ctx:header("Recolectar: Item")
    local n = ctx.nav
    -- Pattern input button
    ctx:btn(2, 2, math.floor(ctx.W / 2) - 1, 1, "PATTERN", colors.black, colors.yellow, function()
        n.searchText = ""
        n._collectScanned = nil
        ctx:goTo("collect_pattern")
    end)
    -- Build global item list
    if not n._collectScanned then
        local map = {}
        for _, inv in ipairs(st.inventories) do
            local items = lib.getItems(inv)
            for _, item in ipairs(items) do
                if not map[item.name] then
                    map[item.name] = { name = item.name, total = 0 }
                end
                map[item.name].total = map[item.name].total + item.total
            end
        end
        local all = {}
        for _, v in pairs(map) do table.insert(all, v) end
        table.sort(all, function(a, b) return a.name < b.name end)
        n.items = all; n.searchText = ""; lib.applyFilter(n)
        n._collectScanned = true
    end
    -- Search
    if n.searchText ~= "" then
        ctx:write(2, 3, "Filt:" .. n.searchText, colors.yellow, colors.black)
    end
    ctx:btn(ctx.W - 8, 2, 8, 1, "BUSCAR", colors.white, colors.orange, function()
        n.screen = "collect_item_search"
    end)
    local di = n.filteredItems
    if #di == 0 then
        ctx:write(2, 5, n.searchText ~= "" and "Sin res." or "Vacio", colors.orange, colors.black)
        return
    end
    local pp = n.perPage
    local si2 = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #di)
    local y = 4
    for i = si2, ei do
        local item = di[i]
        local name = sn(item.name)
        if #name > ctx.W - 8 then name = name:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            n.selectedItem = item
            n.cantidad = 0
            n._collectScanned = nil
            ctx:goTo("collect_to")
        end)
        ctx:write(4, y, name .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items en red")
end

-- Pattern input for collect
function scr10.collect_pattern(ctx)
    ctx:header("Pattern")
    local n = ctx.nav
    ctx:write(2, 2, "Ej: *ore* *ingot*", colors.gray, colors.black)
    compKeyboard(ctx, function()
        if n.searchText ~= "" then
            n.selectedItem = { name = n.searchText, total = 0 }
            n.cantidad = 0
            n.searchText = ""
            ctx:goTo("collect_to")
        end
    end)
end

function scr10.collect_item_search(ctx)
    ctx:header("Buscar Item")
    local n = ctx.nav; local y = 4
    for i = 1, math.min(3, #n.filteredItems) do
        ctx:write(3, y, sn(n.filteredItems[i].name) .. " x" .. n.filteredItems[i].total, colors.lightGray, colors.black)
        y = y + 1
    end
    compKeyboard(ctx, function() n.screen = "collect_item" end)
end

function scr10.collect_to(ctx)
    compSelectInv(ctx, "Recolectar: Destino", function(inv)
        ctx.nav.toInv = inv
        ctx.nav.fromInv = { name = "*", size = 0 }
        ctx:goTo("task_config")
    end)
end

-- ============================================================
-- Multi-item selection flow
-- ============================================================

-- Step 1: Pick source inventory
function scr10.multi_from(ctx)
    compSelectInv(ctx, "Multi: Origen", function(inv)
        ctx.nav.fromInv = inv
        ctx.nav.items = lib.getItems(inv)
        ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
        ctx.nav._multiSelected = {}
        ctx:goTo("multi_items")
    end)
end

-- Step 2: Toggle-select multiple items
function scr10.multi_items(ctx)
    ctx:header("Multi: Items")
    local n = ctx.nav
    local sel = n._multiSelected or {}
    local selCount = 0
    for _ in pairs(sel) do selCount = selCount + 1 end

    -- Search button
    if n.searchText ~= "" then
        ctx:write(2, 2, "Filt:" .. n.searchText, colors.yellow, colors.black)
    end
    ctx:btn(ctx.W - 8, 2, 8, 1, "BUSCAR", colors.white, colors.orange, function()
        n.screen = "multi_items_search"
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
        local isSelected = sel[item.name] ~= nil
        local sname = item.name:match(":(.+)") or item.name
        if #sname > ctx.W - 10 then sname = sname:sub(1, ctx.W - 12) .. ".." end
        local bg = isSelected and colors.green or ((i % 2 == 0) and colors.blue or colors.gray)
        local fg = isSelected and colors.white or colors.white
        local mark = isSelected and "[X] " or "[ ] "
        ctx:btn(2, y, ctx.W - 2, 2, "", fg, bg, function()
            if sel[item.name] then
                sel[item.name] = nil
            else
                sel[item.name] = { name = item.name, total = item.total }
            end
        end)
        ctx:write(3, y, mark .. sname, fg, bg)
        ctx:write(ctx.W - #tostring(item.total) - 2, y + 1, "x" .. item.total, colors.yellow, bg)
        y = y + 3
    end
    ctx:paginate(#di)

    -- Bottom: SELECT ALL / NEXT
    local by = ctx.H
    if selCount > 0 then
        local hw = math.floor((ctx.W - 3) / 2)
        ctx:btn(2, by, hw, 1, "ALL(" .. #di .. ")", colors.white, colors.purple, function()
            for _, item in ipairs(di) do
                sel[item.name] = { name = item.name, total = item.total }
            end
        end)
        ctx:btn(2 + hw + 1, by, hw, 1, selCount .. " NEXT>", colors.black, colors.lime, function()
            lib.refreshInventories()
            ctx:goTo("multi_to")
        end)
    else
        ctx:btn(2, by, ctx.W - 2, 1, "SELECT ALL", colors.white, colors.purple, function()
            for _, item in ipairs(di) do
                sel[item.name] = { name = item.name, total = item.total }
            end
        end)
    end
end

function scr10.multi_items_search(ctx)
    ctx:header("Buscar Item")
    local n = ctx.nav; local y = 4
    for i = 1, math.min(3, #n.filteredItems) do
        ctx:write(3, y, sn(n.filteredItems[i].name) .. " x" .. n.filteredItems[i].total, colors.lightGray, colors.black)
        y = y + 1
    end
    compKeyboard(ctx, function() n.screen = "multi_items" end)
end

-- Step 3: Pick destination
function scr10.multi_to(ctx)
    compSelectInv(ctx, "Multi: Destino", function(inv)
        ctx.nav.toInv = inv
        ctx:goTo("multi_config")
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

-- Step 4: Configure and create tasks
function scr10.multi_config(ctx)
    ctx:header("Multi: Config")
    local n = ctx.nav
    local sel = n._multiSelected or {}
    local selCount = 0
    for _ in pairs(sel) do selCount = selCount + 1 end

    local y = 2
    ctx:write(2, y, selCount .. " items seleccionados", colors.white, colors.black)
    y = y + 1
    ctx:write(2, y, "De: " .. lib.getAlias(n.fromInv.name):sub(1, ctx.W - 6), colors.lime, colors.black)
    y = y + 1
    ctx:write(2, y, "A:  " .. lib.getAlias(n.toInv.name):sub(1, ctx.W - 6), colors.cyan, colors.black)
    y = y + 2

    -- Loop / 1x
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

    -- Show selected items preview
    ctx:write(2, y, "Items:", colors.gray, colors.black); y = y + 1
    local count = 0
    for name, data in pairs(sel) do
        if y >= ctx.H - 3 then
            ctx:write(2, y, "+" .. (selCount - count) .. " mas...", colors.gray, colors.black)
            break
        end
        ctx:write(3, y, sn(name):sub(1, ctx.W - 4), colors.lightGray, colors.black)
        y = y + 1
        count = count + 1
    end

    -- Create button
    ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "CREAR " .. selCount .. " TAREAS", colors.black, colors.lime, function()
        local created = 0
        for name, data in pairs(sel) do
            local shortItem = sn(name):sub(1, 6)
            tasks.create({
                name     = shortItem .. ">" .. lib.getAlias(n.toInv.name):sub(1, 6),
                type     = "transfer",
                from     = n.fromInv.name,
                to       = n.toInv.name,
                item     = name,
                cantidad = 0,
                interval = n._taskInterval or 10,
                loop     = n._taskLoop ~= false,
            })
            created = created + 1
        end
        lib.tLog("[MULTI] " .. created .. " tareas creadas")
        n.screen = "multi_result"; n.history = {}
        n._multiCreated = created
    end)
end

-- Step 5: Result
function scr10.multi_result(ctx)
    ctx:header("Multi: Listo")
    local n = ctx.nav
    local y = 3
    ctx:fill(2, y, ctx.W - 2, 2, colors.green)
    ctx:write(3, y, (n._multiCreated or 0) .. " tareas creadas!", colors.white, colors.green)
    y = y + 3
    ctx:write(2, y, "Las tareas se ejecutan", colors.lightGray, colors.black); y = y + 1
    ctx:write(2, y, "automaticamente segun", colors.lightGray, colors.black); y = y + 1
    ctx:write(2, y, "su configuracion.", colors.lightGray, colors.black)

    ctx:btn(2, ctx.H - 4, ctx.W - 2, 1, "VER TAREAS", colors.white, colors.blue, function()
        n.screen = "tasks_list"; n.history = {}; n.page = 1
        n._multiSelected = nil; n._multiCreated = nil
    end)
    ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "MENU", colors.white, colors.gray, function()
        n.screen = "menu"; n.history = {}
        n._multiSelected = nil; n._multiCreated = nil
    end)
end

-- ============================================================
-- Rules
-- ============================================================
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
        local idx = i
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
            ctx.nav._deleteIdx = idx
            ctx.nav._deleteType = "rule"
            ctx.nav._deleteName = si2
            ctx:goTo("confirm_delete")
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
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 2, "TODO (*)", colors.white, colors.purple, function()
        ctx.nav.selectedItem = { name = "*", total = 0 }
        lib.refreshInventories(); ctx:goTo("rule_to")
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "PATTERN", colors.black, colors.yellow, function()
        ctx.nav.searchText = ""
        ctx:goTo("rule_pattern")
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

-- Pattern input for rules
function scr10.rule_pattern(ctx)
    ctx:header("Pattern")
    local n = ctx.nav
    ctx:write(2, 2, "Ej: *ore* *ingot*", colors.gray, colors.black)
    compKeyboard(ctx, function()
        if n.searchText ~= "" then
            n.selectedItem = { name = n.searchText, total = 0 }
            n.searchText = ""
            lib.refreshInventories()
            ctx:goTo("rule_to")
        end
    end)
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
-- Alerts
-- ============================================================
function scr10.alerts_list(ctx)
    ctx:header("Alerts")
    ctx:btn(2, 2, ctx.W - 2, 1, "+NEW ALERT", colors.white, colors.green, function()
        lib.refreshInventories(); ctx:goTo("alert_inv")
    end)
    if alerts.count() == 0 then
        ctx:write(2, 4, "No alerts", colors.gray, colors.black)
        ctx:footer("Monitor stock levels")
        return
    end
    local y = 4; local n = ctx.nav
    local al = st.alerts
    local si = (n.page - 1) * n.perPage + 1
    local ei = math.min(n.page * n.perPage, #al)
    for i = si, ei do
        if y + 2 > ctx.H - 2 then break end
        local idx = i
        local a = al[i]
        local itemName = sn(a.item)
        if #itemName > ctx.W - 16 then itemName = itemName:sub(1, ctx.W - 18) .. ".." end
        local bg = a.triggered and colors.red or (a.enabled and colors.gray or colors.brown)
        ctx:fill(2, y, ctx.W - 10, 2, bg)
        ctx:write(3, y, itemName, colors.white, bg)
        local cond = (a.below and "<" or ">") .. a.threshold
        local inv = lib.getAlias(a.inventory):sub(1, 8)
        ctx:write(3, y + 1, cond .. " " .. inv, a.triggered and colors.yellow or colors.lightGray, bg)
        if a.redstoneSide then
            ctx:write(ctx.W - 12, y + 1, "R:" .. a.redstoneSide:sub(1, 3), colors.orange, bg)
        end
        ctx:btn(ctx.W - 9, y, 4, 2, a.enabled and "ON" or "OF", colors.white, a.enabled and colors.green or colors.red, function()
            alerts.toggle(idx)
        end)
        ctx:btn(ctx.W - 4, y, 4, 2, "X", colors.white, colors.red, function()
            ctx.nav._deleteIdx = idx
            ctx.nav._deleteType = "alert"
            ctx.nav._deleteName = itemName
            ctx:goTo("confirm_delete")
        end)
        y = y + 3
    end
    ctx:paginate(#al)
    local triggered = alerts.countTriggered()
    local footerText = #al .. " alerts"
    if triggered > 0 then footerText = footerText .. " | " .. triggered .. " ACTIVE" end
    ctx:footer(footerText)
end

-- Alert creation flow
function scr10.alert_inv(ctx)
    compSelectInv(ctx, "Alert: Inventario", function(inv)
        ctx.nav._alertInv = inv.name
        ctx.nav.items = lib.getItems(inv)
        ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
        ctx:goTo("alert_item")
    end)
end

function scr10.alert_item(ctx)
    ctx:header("Alert: Item")
    local n = ctx.nav
    -- Pattern button
    ctx:btn(2, 2, math.floor(ctx.W / 2) - 1, 1, "PATTERN", colors.black, colors.yellow, function()
        n.searchText = ""
        ctx:goTo("alert_pattern")
    end)
    ctx:btn(ctx.W - 8, 2, 8, 1, "BUSCAR", colors.white, colors.orange, function()
        n.screen = "alert_item_search"
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
        local sname = item.name:match(":(.+)") or item.name
        if #sname > ctx.W - 8 then sname = sname:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            n._alertItem = item.name
            n._alertThreshold = 10
            n._alertBelow = true
            n._alertRedstone = nil
            ctx:goTo("alert_config")
        end)
        ctx:write(4, y, sname .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items")
end

function scr10.alert_pattern(ctx)
    ctx:header("Pattern")
    local n = ctx.nav
    ctx:write(2, 2, "Ej: *diamond* *ore*", colors.gray, colors.black)
    compKeyboard(ctx, function()
        if n.searchText ~= "" then
            n._alertItem = n.searchText
            n._alertThreshold = 10
            n._alertBelow = true
            n._alertRedstone = nil
            n.searchText = ""
            ctx:goTo("alert_config")
        end
    end)
end

function scr10.alert_item_search(ctx)
    ctx:header("Buscar Item")
    local n = ctx.nav; local y = 4
    for i = 1, math.min(3, #n.filteredItems) do
        ctx:write(3, y, sn(n.filteredItems[i].name) .. " x" .. n.filteredItems[i].total, colors.lightGray, colors.black)
        y = y + 1
    end
    compKeyboard(ctx, function() n.screen = "alert_item" end)
end

function scr10.alert_config(ctx)
    ctx:header("Alert Config")
    local n = ctx.nav
    local y = 2
    local itemDisp = sn(n._alertItem or "?")
    if #itemDisp > ctx.W - 4 then itemDisp = itemDisp:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, y, "Item: " .. itemDisp, colors.white, colors.black)
    y = y + 1
    ctx:write(2, y, "Inv: " .. lib.getAlias(n._alertInv or "?"):sub(1, ctx.W - 8), colors.cyan, colors.black)
    y = y + 2
    -- Condition
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 1, "BELOW <", colors.white, n._alertBelow and colors.green or colors.gray, function() n._alertBelow = true end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 1, "ABOVE >", colors.white, (not n._alertBelow) and colors.green or colors.gray, function() n._alertBelow = false end)
    y = y + 2
    -- Threshold
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, "Threshold: " .. n._alertThreshold, colors.yellow, colors.gray)
    y = y + 1
    local bw = math.floor((ctx.W - 4) / 4)
    ctx:btn(2, y, bw, 1, "-1", colors.white, colors.red, function() n._alertThreshold = math.max(1, n._alertThreshold - 1) end)
    ctx:btn(2 + bw, y, bw, 1, "-10", colors.white, colors.red, function() n._alertThreshold = math.max(1, n._alertThreshold - 10) end)
    ctx:btn(2 + 2*bw, y, bw, 1, "+10", colors.white, colors.green, function() n._alertThreshold = n._alertThreshold + 10 end)
    ctx:btn(2 + 3*bw, y, bw, 1, "+64", colors.white, colors.green, function() n._alertThreshold = n._alertThreshold + 64 end)
    y = y + 2
    -- Redstone
    local rLabel = n._alertRedstone and ("RS:" .. n._alertRedstone) or "NO REDSTONE"
    ctx:btn(2, y, ctx.W - 2, 1, rLabel, colors.white, n._alertRedstone and colors.orange or colors.gray, function()
        ctx:goTo("alert_redstone")
    end)
    y = y + 2
    -- Create
    ctx:btn(2, y, ctx.W - 2, 1, "CREATE ALERT", colors.black, colors.lime, function()
        alerts.create({
            inventory = n._alertInv,
            item = n._alertItem,
            threshold = n._alertThreshold,
            below = n._alertBelow,
            redstoneSide = n._alertRedstone,
        })
        n.screen = "alerts_list"; n.history = {}; n.page = 1
        n._alertInv = nil; n._alertItem = nil
    end)
end

function scr10.alert_redstone(ctx)
    ctx:header("Redstone Side")
    local n = ctx.nav
    local sides = { "top", "bottom", "left", "right", "front", "back" }
    local y = 3
    ctx:btn(2, y, ctx.W - 2, 1, "NONE", colors.white, n._alertRedstone == nil and colors.green or colors.gray, function()
        n._alertRedstone = nil
        ctx:goBack()
    end)
    y = y + 2
    for _, side in ipairs(sides) do
        ctx:btn(2, y, ctx.W - 2, 1, side:upper(), colors.white, n._alertRedstone == side and colors.green or colors.blue, function()
            n._alertRedstone = side
            ctx:goBack()
        end)
        y = y + 2
    end
end

-- ============================================================
-- Restock management
-- ============================================================

function scr10.restock_list(ctx)
    ctx:header("Restock")
    ctx:btn(2, 2, ctx.W - 2, 1, "+NEW RESTOCK", colors.white, colors.green, function()
        lib.refreshInventories(); ctx:goTo("restock_inv")
    end)
    if restock.count() == 0 then
        ctx:write(2, 4, "No restock rules", colors.gray, colors.black)
        ctx:footer("Mantener stock auto")
        return
    end
    local y = 4; local n = ctx.nav
    local rs = st.restocks
    local si = (n.page - 1) * n.perPage + 1
    local ei = math.min(n.page * n.perPage, #rs)
    for i = si, ei do
        if y + 2 > ctx.H - 2 then break end
        local idx = i
        local r = rs[i]
        local itemName = sn(r.item)
        if #itemName > ctx.W - 16 then itemName = itemName:sub(1, ctx.W - 18) .. ".." end
        local statusCol = colors.gray
        if r.status == "satisfied" then statusCol = colors.green
        elseif r.status == "pulling" then statusCol = colors.yellow
        elseif r.status == "error" then statusCol = colors.red end
        local bg = r.enabled and colors.gray or colors.brown
        ctx:fill(2, y, ctx.W - 10, 2, bg)
        ctx:write(3, y, itemName, colors.white, bg)
        local inv = lib.getAlias(r.inventory):sub(1, 8)
        ctx:write(3, y + 1, r.minStock .. "-" .. r.maxStock .. " " .. inv, statusCol, bg)
        if r.lastPulled > 0 then
            ctx:write(ctx.W - 14, y, "+" .. r.lastPulled, colors.lime, bg)
        end
        ctx:btn(ctx.W - 9, y, 4, 2, r.enabled and "ON" or "OF", colors.white, r.enabled and colors.green or colors.red, function()
            restock.toggle(idx)
        end)
        ctx:btn(ctx.W - 4, y, 4, 2, "X", colors.white, colors.red, function()
            ctx.nav._deleteIdx = idx
            ctx.nav._deleteType = "restock"
            ctx.nav._deleteName = itemName
            ctx:goTo("confirm_delete")
        end)
        y = y + 3
    end
    ctx:paginate(#rs)
    local pulling = restock.countPulling()
    local footerText = #rs .. " rules"
    if pulling > 0 then footerText = footerText .. " | " .. pulling .. " active" end
    ctx:footer(footerText)
end

-- Restock creation: pick target inventory
function scr10.restock_inv(ctx)
    compSelectInv(ctx, "Restock: Inventario", function(inv)
        ctx.nav._restockInv = inv.name
        ctx.nav.items = lib.getItems(inv)
        ctx.nav.searchText = ""; lib.applyFilter(ctx.nav)
        ctx:goTo("restock_item")
    end)
end

-- Restock: pick item
function scr10.restock_item(ctx)
    ctx:header("Restock: Item")
    local n = ctx.nav
    -- Pattern button
    ctx:btn(2, 2, math.floor(ctx.W / 2) - 1, 1, "PATTERN", colors.black, colors.yellow, function()
        n.searchText = ""
        ctx:goTo("restock_pattern")
    end)
    ctx:btn(ctx.W - 8, 2, 8, 1, "BUSCAR", colors.white, colors.orange, function()
        n.screen = "restock_item_search"
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
        local sname = item.name:match(":(.+)") or item.name
        if #sname > ctx.W - 8 then sname = sname:sub(1, ctx.W - 10) .. ".." end
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            n._restockItem = item.name
            n._restockMin = 16
            n._restockMax = 64
            ctx:goTo("restock_config")
        end)
        ctx:write(4, y, sname .. " x" .. item.total, colors.white, bg)
        y = y + 3
    end
    ctx:paginate(#di)
    ctx:footer(#di .. " items")
end

function scr10.restock_pattern(ctx)
    ctx:header("Pattern")
    local n = ctx.nav
    ctx:write(2, 2, "Ej: *ingot* *ore*", colors.gray, colors.black)
    compKeyboard(ctx, function()
        if n.searchText ~= "" then
            n._restockItem = n.searchText
            n._restockMin = 16
            n._restockMax = 64
            n.searchText = ""
            ctx:goTo("restock_config")
        end
    end)
end

function scr10.restock_item_search(ctx)
    ctx:header("Buscar Item")
    local n = ctx.nav; local y = 4
    for i = 1, math.min(3, #n.filteredItems) do
        ctx:write(3, y, sn(n.filteredItems[i].name) .. " x" .. n.filteredItems[i].total, colors.lightGray, colors.black)
        y = y + 1
    end
    compKeyboard(ctx, function() n.screen = "restock_item" end)
end

-- Restock config: min/max thresholds
function scr10.restock_config(ctx)
    ctx:header("Restock: Config")
    local n = ctx.nav
    local y = 2
    local itemDisp = sn(n._restockItem or "?")
    if #itemDisp > ctx.W - 4 then itemDisp = itemDisp:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, y, "Item: " .. itemDisp, colors.white, colors.black)
    y = y + 1
    ctx:write(2, y, "Inv: " .. lib.getAlias(n._restockInv or "?"):sub(1, ctx.W - 8), colors.cyan, colors.black)
    y = y + 2
    -- Min stock
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, "MIN: " .. n._restockMin, colors.yellow, colors.gray)
    y = y + 1
    local bw = math.floor((ctx.W - 4) / 4)
    ctx:btn(2, y, bw, 1, "-1", colors.white, colors.red, function() n._restockMin = math.max(1, n._restockMin - 1) end)
    ctx:btn(2 + bw, y, bw, 1, "-16", colors.white, colors.red, function() n._restockMin = math.max(1, n._restockMin - 16) end)
    ctx:btn(2 + 2*bw, y, bw, 1, "+16", colors.white, colors.green, function() n._restockMin = n._restockMin + 16 end)
    ctx:btn(2 + 3*bw, y, bw, 1, "+64", colors.white, colors.green, function() n._restockMin = n._restockMin + 64 end)
    y = y + 2
    -- Max stock
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, "MAX: " .. n._restockMax, colors.yellow, colors.gray)
    y = y + 1
    ctx:btn(2, y, bw, 1, "-1", colors.white, colors.red, function() n._restockMax = math.max(n._restockMin + 1, n._restockMax - 1) end)
    ctx:btn(2 + bw, y, bw, 1, "-64", colors.white, colors.red, function() n._restockMax = math.max(n._restockMin + 1, n._restockMax - 64) end)
    ctx:btn(2 + 2*bw, y, bw, 1, "+64", colors.white, colors.green, function() n._restockMax = n._restockMax + 64 end)
    ctx:btn(2 + 3*bw, y, bw, 1, "+256", colors.white, colors.green, function() n._restockMax = n._restockMax + 256 end)
    y = y + 2
    -- Create
    ctx:btn(2, y, ctx.W - 2, 1, "CREATE RESTOCK", colors.black, colors.lime, function()
        restock.create({
            inventory = n._restockInv,
            item = n._restockItem,
            minStock = n._restockMin,
            maxStock = n._restockMax,
        })
        lib.audit("RESTOCK_CREATE", { item = n._restockItem, inv = n._restockInv, min = n._restockMin, max = n._restockMax })
        n.screen = "restock_list"; n.history = {}; n.page = 1
        n._restockInv = nil; n._restockItem = nil
    end)
end

-- ============================================================
--  MONITOR 13: INVENTARIO (3x3, interactivo)
--  Explorar inventarios, buscar items, historial, favorites
-- ============================================================
local scr13 = {}

-- Help
function scr13.help(ctx) compHelp(ctx, "browse") end

function scr13.menu(ctx)
    ctx:header("Inv")
    -- Help button on header
    ctx:btn(ctx.W - 8, 1, 3, 1, "?", colors.yellow, colors.blue, function()
        ctx.nav._helpPage = 1; ctx:goTo("help")
    end)
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
    ctx:btn(2 + hw + 1, y, hw, 2, "AUDIT", colors.white, colors.purple, function()
        ctx:goTo("audit_log")
    end); y = y + 3
    ctx:btn(2, y, hw, 2, "CATEGORIES", colors.white, colors.blue, function()
        lib.refreshInventories(); ctx:goTo("cat_list")
    end)
    ctx:btn(2 + hw + 1, y, hw, 2, "SETTINGS", colors.white, colors.gray, function()
        ctx:goTo("settings")
    end)
    ctx:footer(#st.inventories .. " inv | " .. #st.labels .. " labels")
end

-- Settings screen
function scr13.settings(ctx)
    ctx:header("Settings")
    local y = 3
    local hw = math.floor((ctx.W - 3) / 2)
    -- Compact mode
    ctx:btn(2, y, hw, 1, "COMPACT:" .. (st.compactMode and "ON" or "OFF"), colors.white, st.compactMode and colors.green or colors.gray, function()
        st.compactMode = not st.compactMode
        lib.saveLabels()
    end)
    -- Lock PIN
    local lockLabel = st.lockPin and "LOCK:ON" or "LOCK:OFF"
    ctx:btn(2 + hw + 1, y, hw, 1, lockLabel, colors.white, st.lockPin and colors.red or colors.gray, function()
        ctx.nav._pinEntry = ""
        ctx:goTo("pin_setup")
    end)
    y = y + 2
    -- Favorites + Refresh
    ctx:btn(2, y, hw, 1, "FAVORITES", colors.black, colors.yellow, function()
        lib.refreshInventories(); ctx:goTo("favorites")
    end)
    ctx:btn(2 + hw + 1, y, hw, 1, "REFRESH", colors.black, colors.lightGray, function()
        lib.refreshInventories()
        lib.tLog("[SYS] Refresh: " .. #st.inventories .. " inv")
    end)
    y = y + 2
    -- Lock now button (if PIN is set)
    if st.lockPin then
        ctx:btn(2, y, ctx.W - 2, 1, "LOCK NOW", colors.white, colors.red, function()
            lib.lock()
            lib.tLog("[LOCK] System locked")
            lib.audit("LOCK", {})
        end)
        y = y + 2
    end
    -- Stats
    ctx:write(2, y, "Items/min: " .. lib.getItemsPerMinute(), colors.cyan, colors.black)
    y = y + 1
    ctx:write(2, y, "Items/hour: " .. lib.getItemsPerHour(), colors.cyan, colors.black)
    y = y + 1
    ctx:write(2, y, "Storage: " .. lib.getStorageUtilization() .. "%", colors.cyan, colors.black)
    y = y + 1
    ctx:write(2, y, "XFR:" .. st.totalTransfers .. " Moved:" .. st.totalMoved, colors.cyan, colors.black)
end

-- Favorites toggle
function scr13.favorites(ctx)
    ctx:header("Favorites")
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
        local isFav = lib.isFavorite(inv.name)
        local bg = isFav and colors.yellow or colors.gray
        local fg = isFav and colors.black or colors.white
        local name = lib.getAlias(inv.name)
        if #name > ctx.W - 6 then name = name:sub(1, ctx.W - 8) .. ".." end
        ctx:btn(2, y, ctx.W - 2, 2, "", fg, bg, function()
            lib.toggleFavorite(inv.name)
            lib.refreshInventories()
        end)
        ctx:write(4, y, (isFav and "* " or "  ") .. name, fg, bg)
        y = y + 3
    end
    ctx:paginate(#invs)
    ctx:footer("Tap to toggle fav")
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
    if st.compactMode then
        -- Compact: 1 line per item
        local compactPP = ctx.H - 5
        si = (ctx.nav.page - 1) * compactPP + 1
        ei = math.min(ctx.nav.page * compactPP, #di)
        for i = si, ei do
            local item = di[i]
            local n2 = sn(item.name)
            if #n2 > ctx.W - 8 then n2 = n2:sub(1, ctx.W - 10) .. ".." end
            local col = (i % 2 == 0) and colors.lightGray or colors.white
            ctx:write(2, y, n2, col, colors.black)
            ctx:write(ctx.W - #tostring(item.total) - 1, y, tostring(item.total), colors.yellow, colors.black)
            y = y + 1
        end
        local tp = math.ceil(#di / compactPP)
        if tp > 1 then
            ctx:fill(1, ctx.H - 1, ctx.W, 1, colors.black)
            if ctx.nav.page > 1 then
                ctx:btn(2, ctx.H - 1, 6, 1, "< P", colors.white, colors.cyan, function() ctx.nav.page = ctx.nav.page - 1 end)
            end
            ctx:write(math.floor(ctx.W / 2) - 2, ctx.H - 1, ctx.nav.page .. "/" .. tp, colors.gray, colors.black)
            if ctx.nav.page < tp then
                ctx:btn(ctx.W - 6, ctx.H - 1, 6, 1, "N >", colors.white, colors.cyan, function() ctx.nav.page = ctx.nav.page + 1 end)
            end
        end
    else
        for i = si, ei do
            local item = di[i]
            local n2 = sn(item.name)
            if #n2 > ctx.W - 12 then n2 = n2:sub(1, ctx.W - 14) .. ".." end
            local bg = (i % 2 == 0) and colors.blue or colors.gray
            -- Main item area (clickable for quick send)
            ctx:btn(2, y, ctx.W - 7, 2, "", colors.white, bg, function()
                ctx.nav.selectedItem = item
                ctx.nav.cantidad = item.total
                lib.refreshInventories()
                ctx:goTo("send_qty")
            end)
            ctx:write(3, y, n2 .. " x" .. item.total, colors.white, bg)
            -- Send arrow button
            ctx:btn(ctx.W - 4, y, 4, 2, ">>", colors.black, colors.lime, function()
                ctx.nav.selectedItem = item
                ctx.nav.cantidad = item.total
                lib.refreshInventories()
                ctx:goTo("send_qty")
            end)
            y = y + 3
        end
        ctx:paginate(#di)
    end
    ctx:footer(#di .. " items | tap to send")
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
        local bg = (i % 2 == 0) and colors.gray or colors.black
        ctx:fill(2, y, ctx.W - 2, 2, bg)
        ctx:write(3, y, si2 .. " " .. h.moved .. "x", colors.white, bg)
        local fromH = h.from == "*" and "ALL" or lib.shortName(h.from):sub(1, 8)
        local route = fromH .. ">" .. lib.shortName(h.to):sub(1, 8)
        local undoMark = h.undoable and " [U]" or ""
        ctx:write(3, y + 1, h.time .. " " .. route .. undoMark, (h.moved >= h.requested) and colors.lime or colors.orange, bg)
        -- Undo button for undoable entries
        if h.undoable then
            local idx = i
            ctx:btn(ctx.W - 4, y, 4, 2, "<-", colors.white, colors.orange, function()
                local entry = st.history[idx]
                if entry and entry.undoable then
                    ui.queueAction({ type = "undo_history", ctx = ctx, entry = entry })
                end
            end)
        end
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
        local idx = i
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
-- Quick Send from browse: send item directly from inv_detail
-- ============================================================

function scr13.send_qty(ctx)
    compQtySelector(ctx, "Enviar: Cantidad", ctx.nav.selectedItem.total, false, function()
        ctx:goTo("send_to")
    end)
end

function scr13.send_to(ctx)
    compSelectInv(ctx, "Enviar: Destino", function(inv)
        ctx.nav.toInv = inv
        ctx:goTo("send_confirm")
    end, ctx.nav.fromInv and ctx.nav.fromInv.name)
end

function scr13.send_confirm(ctx)
    ctx:header("Enviar")
    local n = ctx.nav
    local y = 2
    local si = sn(n.selectedItem.name)
    if #si > ctx.W - 4 then si = si:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, y, "Item: " .. si, colors.white, colors.black); y = y + 1
    ctx:write(2, y, "Qty: " .. n.cantidad, colors.yellow, colors.black); y = y + 1
    ctx:write(2, y, "De: " .. lib.getAlias(n.fromInv.name):sub(1, ctx.W - 6), colors.lime, colors.black); y = y + 1
    ctx:write(2, y, "A:  " .. lib.getAlias(n.toInv.name):sub(1, ctx.W - 6), colors.cyan, colors.black); y = y + 2
    ctx:btn(2, y, math.floor(ctx.W / 2) - 1, 2, "CANCEL", colors.white, colors.red, function()
        ctx:goBack()
    end)
    ctx:btn(math.floor(ctx.W / 2) + 1, y, math.floor(ctx.W / 2) - 1, 2, "SEND", colors.white, colors.green, function()
        ctx:goTo("send_exec")
    end)
end

function scr13.send_exec(ctx)
    ctx:header("Enviando...")
    ctx:write(2, 3, "Processing...", colors.yellow, colors.black)
    ui.queueAction({
        type = "send",
        ctx = ctx,
        fromInv = ctx.nav.fromInv,
        toInv = ctx.nav.toInv,
        selectedItem = ctx.nav.selectedItem,
        cantidad = ctx.nav.cantidad,
    })
end

function scr13.send_result(ctx)
    ctx:header("Resultado")
    local n = ctx.nav
    local y = 3
    if n._sendMoved and n._sendMoved > 0 then
        ctx:fill(2, y, ctx.W - 2, 2, colors.green)
        ctx:write(3, y, "OK " .. n._sendMoved .. " enviados", colors.white, colors.green)
    else
        ctx:fill(2, y, ctx.W - 2, 2, colors.red)
        ctx:write(3, y, "ERROR: 0 enviados", colors.white, colors.red)
    end
    y = y + 3
    -- Undo
    if n._sendMoved and n._sendMoved > 0 then
        ctx:btn(2, y, ctx.W - 2, 1, "UNDO", colors.white, colors.orange, function()
            local entry = st.history[1]
            if entry and entry.undoable then
                ui.queueAction({ type = "undo", ctx = ctx, entry = entry })
            end
        end)
        y = y + 2
    end
    ctx:btn(2, ctx.H - 2, ctx.W - 2, 2, "BACK", colors.white, colors.blue, function()
        n.screen = "menu"; n.history = {}; n.fromInv = nil; n.toInv = nil; n.selectedItem = nil
    end)
end

-- ============================================================
-- Categories management
-- ============================================================

function scr13.cat_list(ctx)
    ctx:header("Categories")
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
        local cat = lib.getCategory(inv.name)
        local bg = (i % 2 == 0) and colors.blue or colors.gray
        local catColor = cat and (lib.CATEGORY_COLORS[cat] or colors.white) or colors.lightGray
        local catDisp = cat or "---"
        local name = lib.getAlias(inv.name)
        if #name > ctx.W - 12 then name = name:sub(1, ctx.W - 14) .. ".." end
        ctx:btn(2, y, ctx.W - 2, 2, "", colors.white, bg, function()
            n._catInv = inv.name
            ctx:goTo("cat_select")
        end)
        ctx:write(3, y, name, colors.white, bg)
        ctx:write(3, y + 1, catDisp, catColor, bg)
        y = y + 3
    end
    ctx:paginate(#invs)
    ctx:footer("Tap to set zone")
end

function scr13.cat_select(ctx)
    ctx:header("Zona")
    local n = ctx.nav
    local invName = lib.getAlias(n._catInv or "?")
    if #invName > ctx.W - 4 then invName = invName:sub(1, ctx.W - 6) .. ".." end
    ctx:write(2, 2, invName, colors.cyan, colors.black)
    local y = 4
    -- None option
    ctx:btn(2, y, ctx.W - 2, 1, "NONE", colors.white, lib.getCategory(n._catInv) == nil and colors.green or colors.gray, function()
        lib.setCategory(n._catInv, nil)
        lib.audit("CATEGORY", { inv = n._catInv, cat = "NONE" })
        ctx:goBack()
    end)
    y = y + 2
    for _, cat in ipairs(lib.CATEGORIES) do
        local col = lib.CATEGORY_COLORS[cat] or colors.blue
        local fg = lib.contrastFg(col)
        local current = lib.getCategory(n._catInv) == cat
        ctx:btn(2, y, ctx.W - 2, 2, cat, fg, current and colors.green or col, function()
            lib.setCategory(n._catInv, cat)
            lib.audit("CATEGORY", { inv = n._catInv, cat = cat })
            ctx:goBack()
        end)
        y = y + 3
    end
end

-- ============================================================
-- Audit Log viewer
-- ============================================================

function scr13.audit_log(ctx)
    ctx:header("Audit Log")
    local al = st.auditLog
    if #al == 0 then
        ctx:write(2, 3, "No audit entries", colors.gray, colors.black)
        ctx:footer("Operations recorded here")
        return
    end
    -- Filter buttons
    local n = ctx.nav
    local filter = n._auditFilter or "ALL"
    local filters = { "ALL", "XFER", "TASK", "RSTK", "ALRT" }
    local fbw = math.floor((ctx.W - 2) / #filters)
    for idx, f in ipairs(filters) do
        local bx = 2 + (idx - 1) * fbw
        ctx:btn(bx, 2, fbw - 1, 1, f, colors.white, filter == f and colors.green or colors.blue, function()
            n._auditFilter = f; n.page = 1
        end)
    end

    -- Filter entries
    local filtered = {}
    for _, entry in ipairs(al) do
        local show = true
        if filter == "XFER" then show = entry.action == "TRANSFER"
        elseif filter == "TASK" then show = entry.action == "TASK"
        elseif filter == "RSTK" then show = entry.action == "RESTOCK" or entry.action == "RESTOCK_CREATE"
        elseif filter == "ALRT" then show = entry.action == "ALERT"
        end
        if show then table.insert(filtered, entry) end
    end

    local pp = n.perPage
    local si = (n.page - 1) * pp + 1
    local ei = math.min(n.page * pp, #filtered)
    local y = 3
    for i = si, ei do
        local e = filtered[i]
        local bg = (i % 2 == 0) and colors.gray or colors.black
        ctx:fill(2, y, ctx.W - 2, 2, bg)
        -- Action type color
        local actCol = colors.white
        if e.action == "TRANSFER" then actCol = colors.lime
        elseif e.action == "TASK" then actCol = colors.cyan
        elseif e.action == "RESTOCK" or e.action == "RESTOCK_CREATE" then actCol = colors.yellow
        elseif e.action == "ALERT" then actCol = colors.orange
        elseif e.action == "LOCK" then actCol = colors.red end
        ctx:write(3, y, e.action:sub(1, 8), actCol, bg)
        ctx:write(ctx.W - 7, y, e.time or "", colors.lightGray, bg)
        -- Details line
        local detail = ""
        if e.details then
            if e.details.item then detail = sn(e.details.item):sub(1, 10) end
            if e.details.moved then detail = detail .. " x" .. e.details.moved end
            if e.details.inv then detail = lib.getAlias(e.details.inv):sub(1, 12) end
            if e.details.cat then detail = detail .. " " .. e.details.cat end
        end
        if #detail > ctx.W - 4 then detail = detail:sub(1, ctx.W - 6) .. ".." end
        ctx:write(3, y + 1, detail, colors.lightGray, bg)
        y = y + 3
    end
    ctx:paginate(#filtered)
    ctx:footer(#filtered .. " / " .. #al .. " entries")
end

-- ============================================================
-- PIN setup and Lock screen
-- ============================================================

function scr13.pin_setup(ctx)
    ctx:header("PIN Setup")
    local n = ctx.nav
    local y = 3
    if st.lockPin then
        ctx:write(2, y, "PIN activo", colors.lime, colors.black)
        y = y + 1
        ctx:btn(2, y, ctx.W - 2, 1, "REMOVE PIN", colors.white, colors.red, function()
            lib.setPin(nil)
            lib.tLog("[LOCK] PIN removed")
            lib.audit("PIN_REMOVE", {})
            ctx:goBack()
        end)
        y = y + 2
        ctx:write(2, y, "O set new PIN:", colors.gray, colors.black)
        y = y + 1
    else
        ctx:write(2, y, "Set 4-digit PIN:", colors.white, colors.black)
        y = y + 1
    end
    -- PIN display
    local pinDisp = ""
    for i = 1, 4 do
        if i <= #(n._pinEntry or "") then pinDisp = pinDisp .. "* "
        else pinDisp = pinDisp .. "_ " end
    end
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(math.floor(ctx.W / 2) - 3, y, pinDisp, colors.yellow, colors.gray)
    y = y + 2
    -- Number pad (3x4 grid)
    local nums = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "OK" }
    local bw = math.floor((ctx.W - 4) / 3)
    for idx, num in ipairs(nums) do
        local row = math.floor((idx - 1) / 3)
        local col = (idx - 1) % 3
        local bx = 2 + col * (bw + 1)
        local by = y + row * 2
        if by > ctx.H - 2 then break end
        local bg = colors.blue
        if num == "CLR" then bg = colors.red
        elseif num == "OK" then bg = colors.green end
        ctx:btn(bx, by, bw, 1, num, colors.white, bg, function()
            if num == "CLR" then
                n._pinEntry = ""
            elseif num == "OK" then
                if #(n._pinEntry or "") == 4 then
                    lib.setPin(n._pinEntry)
                    lib.tLog("[LOCK] PIN set")
                    lib.audit("PIN_SET", {})
                    n._pinEntry = ""
                    ctx:goBack()
                end
            else
                if #(n._pinEntry or "") < 4 then
                    n._pinEntry = (n._pinEntry or "") .. num
                end
            end
        end)
    end
end

-- ============================================================
-- Lock screen renderer (used by all monitors when locked)
-- ============================================================

local function renderLockScreen(ctx, isControl)
    ctx:clear(colors.black)
    ctx:fill(1, 1, ctx.W, 1, colors.red)
    ctx:write(2, 1, "LOCKED", colors.white, colors.red)
    local y = math.floor(ctx.H / 2) - 2
    if y < 3 then y = 3 end
    ctx:write(math.floor(ctx.W / 2) - 4, y, "SISTEMA", colors.yellow, colors.black)
    ctx:write(math.floor(ctx.W / 2) - 5, y + 1, "BLOQUEADO", colors.yellow, colors.black)
    if isControl then
        -- PIN entry on control monitor
        y = y + 3
        local pinEntry = st._lockPinEntry or ""
        local pinDisp = ""
        for i = 1, 4 do
            if i <= #pinEntry then pinDisp = pinDisp .. "* "
            else pinDisp = pinDisp .. "_ " end
        end
        ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
        ctx:write(math.floor(ctx.W / 2) - 3, y, pinDisp, colors.yellow, colors.gray)
        y = y + 2
        -- Number pad
        local nums = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "OK" }
        local bw = math.floor((ctx.W - 4) / 3)
        for idx, num in ipairs(nums) do
            local row = math.floor((idx - 1) / 3)
            local col = (idx - 1) % 3
            local bx = 2 + col * (bw + 1)
            local by = y + row * 2
            if by > ctx.H - 1 then break end
            local bg = colors.blue
            if num == "CLR" then bg = colors.red
            elseif num == "OK" then bg = colors.green end
            ctx:btn(bx, by, bw, 1, num, colors.white, bg, function()
                if num == "CLR" then
                    st._lockPinEntry = ""
                elseif num == "OK" then
                    if lib.checkPin(st._lockPinEntry or "") then
                        lib.unlock()
                        st._lockPinEntry = ""
                        lib.tLog("[LOCK] System unlocked")
                        lib.audit("UNLOCK", {})
                    else
                        st._lockPinEntry = ""
                    end
                else
                    st._lockPinEntry = (st._lockPinEntry or "") .. num
                    if #st._lockPinEntry > 4 then st._lockPinEntry = num end
                end
            end)
        end
    else
        y = y + 3
        ctx:write(math.floor(ctx.W / 2) - 6, y, "Enter PIN on", colors.gray, colors.black)
        ctx:write(math.floor(ctx.W / 2) - 5, y + 1, "CONTROL mon", colors.gray, colors.black)
    end
end

-- ============================================================
--  MONITOR 12: DASHBOARD (2x7, techo, auto-refresh)
--  Enterprise KPIs: utilization, throughput, zones, restock
-- ============================================================

local function renderDashboard(ctx)
    -- Lock screen override
    if st.locked then
        renderLockScreen(ctx, false)
        return
    end

    ctx:clear(colors.black)
    ctx:fill(1, 1, ctx.W, 1, colors.blue)
    ctx:write(2, 1, "TRANSFER v5.3", colors.white, colors.blue)

    local y = 2

    -- KPI bar
    local util = lib.getStorageUtilization()
    local ipm = lib.getItemsPerMinute()
    local utilCol = util > 90 and colors.red or (util > 70 and colors.orange or colors.green)
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, util .. "% ", utilCol, colors.gray)
    ctx:write(3 + #tostring(util) + 2, y, ipm .. "/m", colors.yellow, colors.gray)
    ctx:write(ctx.W - 8, y, fmtElapsed(os.clock() - st.startTime), colors.lightGray, colors.gray)
    y = y + 1

    -- Warnings
    local discCount = 0
    for _ in pairs(st.disconnected) do discCount = discCount + 1 end
    if discCount > 0 then
        ctx:fill(2, y, ctx.W - 2, 1, colors.red)
        ctx:write(3, y, discCount .. " DISCONNECTED", colors.white, colors.red)
        y = y + 1
    end
    local triggered = alerts.countTriggered()
    if triggered > 0 then
        ctx:fill(2, y, ctx.W - 2, 1, colors.orange)
        ctx:write(3, y, triggered .. " ALERTS!", colors.white, colors.orange)
        y = y + 1
    end
    local pulling = restock.countPulling()
    if pulling > 0 then
        ctx:fill(2, y, ctx.W - 2, 1, colors.cyan)
        ctx:write(3, y, pulling .. " RESTOCKING", colors.white, colors.cyan)
        y = y + 1
    end

    -- Inventories with zone colors
    lib.refreshFillCache()
    for _, inv in ipairs(st.inventories) do
        if y >= ctx.H - 4 then break end
        local used, total = lib.getInventoryFill(inv)
        local pct = total > 0 and math.floor(used / total * 100) or 0
        local shortName = lib.getAlias(inv.name):sub(1, 8)
        local col = pct > 90 and colors.red or (pct > 60 and colors.orange or colors.green)
        local dc = st.disconnected[inv.name] and "!" or ""
        local cat = lib.getCategory(inv.name)
        local catMark = ""
        if cat then
            catMark = cat:sub(1, 1) .. " "
        end
        ctx:write(2, y, dc .. catMark .. shortName, col, colors.black)
        -- Mini bar
        local barW = ctx.W - 14 - #shortName
        if barW > 2 then
            local barX = ctx.W - barW - 2
            local filled = math.max(0, math.floor(barW * pct / 100))
            ctx:fill(barX, y, barW, 1, colors.gray)
            if filled > 0 then ctx:fill(barX, y, filled, 1, col) end
        end
        ctx:write(ctx.W - 4, y, pct .. "%", col, colors.black)
        y = y + 1
    end

    if #st.inventories == 0 then
        ctx:write(2, y, "No inv", colors.gray, colors.black); y = y + 1
    end
    y = y + 1

    -- Pipeline status
    local statusLine = ""
    if st.workerActive then statusLine = statusLine .. "WK " end
    if tasks.countEnabled() > 0 then statusLine = statusLine .. "T:" .. tasks.countEnabled() .. " " end
    if restock.countActive() > 0 then statusLine = statusLine .. "R:" .. restock.countActive() .. " " end
    if #st.rules > 0 then statusLine = statusLine .. "RL:" .. #st.rules end
    if statusLine ~= "" then
        ctx:write(2, y, statusLine, colors.cyan, colors.black)
        y = y + 1
    end

    -- Top items
    local topItems = lib.getTopItems(3)
    if #topItems > 0 then
        for _, ti in ipairs(topItems) do
            if y >= ctx.H then break end
            ctx:write(2, y, sn(ti.name):sub(1, ctx.W - 8) .. " " .. ti.count, colors.lightGray, colors.black)
            y = y + 1
        end
    end
end

local function renderActivity(ctx)
    ctx:clear(colors.black)
    ctx:fill(1, 1, ctx.W, 1, colors.purple)
    ctx:write(2, 1, "ACT " .. textutils.formatTime(os.time(), true), colors.white, colors.purple)

    local y = 2

    -- Enhanced stats bar
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    local ipm = lib.getItemsPerMinute()
    ctx:write(3, y, "XFR:" .. st.totalTransfers .. " " .. ipm .. "/m", colors.yellow, colors.gray)
    y = y + 1
    ctx:fill(2, y, ctx.W - 2, 1, colors.gray)
    ctx:write(3, y, "Moved:" .. st.totalMoved .. " Err:" .. st.totalErrors, colors.lightGray, colors.gray)
    y = y + 1

    -- Active alerts
    local triggered = alerts.countTriggered()
    if triggered > 0 then
        ctx:fill(2, y, ctx.W - 2, 1, colors.red)
        ctx:write(3, y, triggered .. " ALERTS ACTIVE", colors.white, colors.red)
        y = y + 1
    end

    -- Restock status
    local pulling = restock.countPulling()
    local restockActive = restock.countActive()
    if restockActive > 0 then
        ctx:fill(2, y, ctx.W - 2, 1, pulling > 0 and colors.green or colors.gray)
        local rstTxt = "RESTOCK:" .. restockActive
        if pulling > 0 then rstTxt = rstTxt .. " PULL:" .. pulling end
        ctx:write(3, y, rstTxt, colors.white, pulling > 0 and colors.green or colors.gray)
        y = y + 1
    end

    -- Pipeline summary
    local taskActive = 0
    for _, t in ipairs(st.tasks or {}) do
        if t.enabled then taskActive = taskActive + 1 end
    end
    if taskActive > 0 or st.rulesRunning then
        ctx:fill(2, y, ctx.W - 2, 1, colors.blue)
        local pipeTxt = ""
        if taskActive > 0 then pipeTxt = "TASKS:" .. taskActive end
        if st.rulesRunning then
            if #pipeTxt > 0 then pipeTxt = pipeTxt .. " " end
            pipeTxt = pipeTxt .. "RULES:ON"
        end
        ctx:write(3, y, pipeTxt, colors.white, colors.blue)
        y = y + 1
    end

    y = y + 1

    -- Log
    local log = lib.termLog
    local maxLines = ctx.H - y
    for i = 1, math.min(#log, maxLines) do
        local l = log[i]
        local col = colors.lightGray
        if l:find("ERROR") or l:find("WARN") then col = colors.red
        elseif l:find("ALERT") then col = colors.orange
        elseif l:find("RESTOCK") then col = colors.cyan
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
        action.ctx.nav._lastHistoryIdx = 1
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
            local fy = 8
            if prog.fullItems then
                local count = 0
                for name in pairs(prog.fullItems) do
                    if fy < ctx.H - 2 then
                        local nm = lib.shortName(name)
                        if #nm > ctx.W - 6 then nm = nm:sub(1, ctx.W - 8) .. ".." end
                        ctx:write(2, fy, "!" .. nm, colors.orange, colors.black)
                        fy = fy + 1
                        count = count + 1
                        if count >= 3 then break end
                    end
                end
            end
            if prog.destFull then
                ctx:fill(2, fy, ctx.W - 2, 1, colors.red)
                ctx:write(3, fy, "INV FULL!", colors.white, colors.red)
            end
            ctx:footer("Wait...")
        end)
        action.ctx.nav.bulkResult = result
        local bulkMsg = result.total .. " items -> " .. lib.getAlias(action.toInv.name)
        if result.fullItems and #result.fullItems > 0 then
            lib.tLog("[EMPTY] " .. bulkMsg .. " (" .. #result.fullItems .. " sin espacio)")
        else
            lib.tLog("[EMPTY] OK: " .. bulkMsg)
        end
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
    elseif action.type == "send" then
        local item = action.selectedItem or action.item
        local movido = lib.moveItems(action.fromInv.peripheral, action.toInv.name, item.name, action.cantidad)
        action.ctx.nav._sendMoved = movido
        if movido > 0 then
            lib.tLog("OK: " .. movido .. "x " .. sn(item.name) .. " >> " .. lib.getAlias(action.toInv.name))
        else
            lib.tLog("ERROR: No se envio " .. sn(item.name))
        end
        lib.addHistory(action.fromInv.name, action.toInv.name, item.name, action.cantidad, movido)
        lib.audit("SEND", { from = action.fromInv.name, to = action.toInv.name, item = item.name, qty = action.cantidad, moved = movido })
        action.ctx.nav.screen = "send_result"
    elseif action.type == "undo" or action.type == "undo_history" then
        local moved = lib.undoTransfer(action.entry)
        if action.type == "undo" then
            action.ctx.nav._undoMoved = moved
            action.ctx.nav.screen = "undo_result"
            action.ctx.nav.history = {}
        else
            -- Refresh history view
            action.ctx.dirty = true
        end
    end
end

function ui.renderMonitor(key)
    local m = ui.monitors[key]
    if not m then return end

    -- Lock screen: block all interactive monitors, show lock on dashboards too
    if st.locked then
        renderLockScreen(m, key == "control")
        m.dirty = false
        return
    end

    if m.screens then
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
            -- Lock screen interception
            if st.locked then
                if key == "control" then
                    -- Only allow PIN entry on control monitor
                    if m:handleTouch(x, y) then
                        -- Re-render all monitors (unlock affects all)
                        if not st.locked then
                            ui.renderAll()
                        else
                            ui.renderMonitor("control")
                        end
                        return true
                    end
                end
                -- Block touches on all other monitors when locked
                return false
            end

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
