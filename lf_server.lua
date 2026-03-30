-- ============================================================
--  lf_server.lua  v3.0
--  Computadora central - SERVIDOR
--
--  Recibe reportes de todas las turtles via wireless modem
--  Muestra dashboard en monitor grande con:
--    - Lista de turtles con estado, fuel, posicion
--    - Mapa visual 2D (vista cenital) con posiciones GPS
--    - Log de eventos
-- ============================================================

local PROTOCOL     = "linefollower"
local REFRESH_RATE = 0.5    -- Segundos entre refrescos de pantalla
local OFFLINE_TIME = 30     -- Segundos sin reporte = offline

-- ============================================================
--  Estado global
-- ============================================================
local turtles = {}   -- [id] = { label, fuel, pos, state, route, ... }
local eventLog = {}  -- Ultimos N eventos
local MAX_LOG = 50

-- Mapa: guardamos posiciones historicas por turtle
local mapTrails = {} -- [id] = { {x,z}, {x,z}, ... }
local mapCenter = nil
local mapZoom   = 1  -- 1 bloque = 1 pixel

local monitor = nil
local monW, monH = 0, 0

-- ============================================================
--  Utilidades
-- ============================================================
local function timestamp()
    return textutils.formatTime(os.time(), true)
end

local function addLog(msg)
    table.insert(eventLog, 1, "[" .. timestamp() .. "] " .. msg)
    if #eventLog > MAX_LOG then
        table.remove(eventLog)
    end
end

local function findMonitor()
    local mon = peripheral.find("monitor")
    if mon then
        mon.setTextScale(0.5)
        monW, monH = mon.getSize()
        return mon
    end
    return nil
end

local function findModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
            rednet.open(side)
            return side
        end
    end
    return nil
end

-- ============================================================
--  Colores por estado
-- ============================================================
local stateColors = {
    online        = colors.green,
    scanning      = colors.yellow,
    scan_start    = colors.yellow,
    scan_complete = colors.lime,
    replaying     = colors.cyan,
    replay_start  = colors.cyan,
    replay_lap    = colors.blue,
    replay_done   = colors.lime,
    searching     = colors.orange,
    found         = colors.green,
    offline       = colors.gray,
    error         = colors.red,
    warning       = colors.orange,
}

local stateLabels = {
    online        = "EN LINEA",
    scanning      = "ESCANEANDO",
    scan_start    = "INICIO SCAN",
    scan_complete = "SCAN LISTO",
    replaying     = "REPLAY",
    replay_start  = "INICIO REPLAY",
    replay_lap    = "VUELTA OK",
    replay_done   = "REPLAY LISTO",
    searching     = "BUSCANDO...",
    found         = "ENCONTRADO",
    offline       = "OFFLINE",
    error         = "ERROR",
    warning       = "ADVERTENCIA",
}

-- Colores unicos por turtle (para el mapa)
local turtleColors = {
    colors.red, colors.blue, colors.green, colors.yellow,
    colors.magenta, colors.orange, colors.cyan, colors.pink,
    colors.lime, colors.purple, colors.lightBlue, colors.white,
}

local function getTurtleColor(id)
    local idx = (id % #turtleColors) + 1
    return turtleColors[idx]
end

-- ============================================================
--  Procesar mensaje de turtle
-- ============================================================
local function processMessage(senderId, msg)
    if type(msg) ~= "table" or not msg.type then return end

    local id = msg.id or senderId
    if not turtles[id] then
        turtles[id] = {
            label = "Turtle-" .. id,
            fuel  = 0,
            pos   = nil,
            state = "online",
            route = "",
            lastSeen = os.clock(),
            extra = {},
        }
        mapTrails[id] = {}
        addLog("Nueva turtle conectada: " .. (msg.label or ("ID:" .. id)))
    end

    local t = turtles[id]
    t.label    = msg.label or t.label
    t.fuel     = msg.fuel or t.fuel
    t.lastSeen = os.clock()

    if msg.pos then
        t.pos = msg.pos
        -- Agregar al trail del mapa
        local trail = mapTrails[id]
        local last = trail[#trail]
        if not last or last.x ~= msg.pos.x or last.z ~= msg.pos.z or last.y ~= msg.pos.y then
            table.insert(trail, { x = msg.pos.x, y = msg.pos.y, z = msg.pos.z })
        end
        -- Actualizar centro del mapa si no existe
        if not mapCenter then
            mapCenter = { x = msg.pos.x, z = msg.pos.z }
        end
    end

    local data = msg.data or {}

    if msg.type == "status" then
        t.state = data.state or t.state
        t.route = data.route or t.route
        t.extra = data
        if data.state then
            addLog(t.label .. ": " .. (stateLabels[data.state] or data.state))
        end
    elseif msg.type == "progress" then
        t.state = data.state or t.state
        t.route = data.route or t.route
        t.extra = data
    elseif msg.type == "warning" then
        t.state = "warning"
        addLog("WARN " .. t.label .. ": " .. (data.msg or "?"))
    elseif msg.type == "error" then
        t.state = "error"
        addLog("ERROR " .. t.label .. ": " .. (data.msg or "?"))
    end
end

-- ============================================================
--  Marcar turtles offline
-- ============================================================
local function checkOffline()
    local now = os.clock()
    for id, t in pairs(turtles) do
        if t.state ~= "offline" and (now - t.lastSeen) > OFFLINE_TIME then
            t.state = "offline"
            addLog(t.label .. " se desconecto")
        end
    end
end

-- ============================================================
--  DIBUJAR MONITOR
-- ============================================================

--- Escribe texto en el monitor con color
local function mWrite(mon, x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    if fg then mon.setTextColor(fg) end
    if bg then mon.setBackgroundColor(bg) end
    mon.write(text)
end

--- Dibuja una linea horizontal
local function mHLine(mon, y, char, fg, bg)
    mWrite(mon, 1, y, string.rep(char or "-", monW), fg or colors.gray, bg or colors.black)
end

--- Panel de lista de turtles (mitad izquierda)
local function drawTurtlePanel(mon)
    local panelW = math.floor(monW * 0.45)
    local y = 1

    -- Titulo
    mWrite(mon, 1, y, " TURTLES ", colors.white, colors.gray)
    mWrite(mon, 10, y, string.rep(" ", panelW - 9), colors.white, colors.gray)
    y = y + 1

    -- Header
    mon.setBackgroundColor(colors.black)
    mWrite(mon, 1, y, "ID", colors.lightGray)
    mWrite(mon, 5, y, "NOMBRE", colors.lightGray)
    mWrite(mon, 18, y, "ESTADO", colors.lightGray)
    mWrite(mon, 31, y, "FUEL", colors.lightGray)
    mWrite(mon, 38, y, "POS", colors.lightGray)
    y = y + 1
    mHLine(mon, y, "-")
    y = y + 1

    -- Ordenar turtles por ID
    local sortedIds = {}
    for id, _ in pairs(turtles) do
        table.insert(sortedIds, id)
    end
    table.sort(sortedIds)

    for _, id in ipairs(sortedIds) do
        if y > monH - MAX_LOG / 3 then break end
        local t = turtles[id]
        local stateCol = stateColors[t.state] or colors.white
        local stateText = stateLabels[t.state] or t.state or "?"

        mon.setBackgroundColor(colors.black)
        mWrite(mon, 1, y, string.format("%-3d", id), getTurtleColor(id))
        mWrite(mon, 5, y, string.sub(t.label, 1, 12), colors.white)
        mWrite(mon, 18, y, string.sub(stateText, 1, 12), stateCol)

        -- Fuel
        local fuelStr = "?"
        if t.fuel then
            if t.fuel == "unlimited" then
                fuelStr = "INF"
            else
                fuelStr = tostring(t.fuel)
            end
        end
        local fuelCol = colors.green
        if type(t.fuel) == "number" then
            if t.fuel < 100 then fuelCol = colors.red
            elseif t.fuel < 500 then fuelCol = colors.orange end
        end
        mWrite(mon, 31, y, string.sub(fuelStr, 1, 6), fuelCol)

        -- Posicion
        if t.pos then
            local posStr = t.pos.x .. "," .. t.pos.y .. "," .. t.pos.z
            mWrite(mon, 38, y, string.sub(posStr, 1, panelW - 38), colors.lightGray)
        else
            mWrite(mon, 38, y, "???", colors.gray)
        end

        -- Linea extra: ruta y progreso
        y = y + 1
        if y <= monH then
            mon.setBackgroundColor(colors.black)
            local extra = ""
            if t.route and t.route ~= "" then
                extra = "  Ruta: " .. t.route
            end
            if t.extra then
                if t.extra.pct then
                    extra = extra .. " [" .. t.extra.pct .. "%]"
                elseif t.extra.step then
                    extra = extra .. " [paso " .. t.extra.step .. "]"
                end
                if t.extra.run then
                    extra = extra .. " vuelta#" .. t.extra.run
                end
                if t.extra.items and t.extra.items > 0 then
                    extra = extra .. " items:" .. t.extra.items
                end
            end
            if extra ~= "" then
                mWrite(mon, 5, y, string.sub(extra, 1, panelW - 5), colors.gray)
            end
        end

        y = y + 1
    end

    return y
end

--- Panel del mapa (mitad derecha)
local function drawMapPanel(mon)
    local mapX = math.floor(monW * 0.46) + 1
    local mapW = monW - mapX + 1
    local mapH = math.floor(monH * 0.65)

    -- Titulo
    mWrite(mon, mapX, 1, " MAPA GPS ", colors.white, colors.gray)
    mWrite(mon, mapX + 10, 1, string.rep(" ", mapW - 10), colors.white, colors.gray)

    -- Fondo del mapa
    for y = 2, mapH + 1 do
        mWrite(mon, mapX, y, string.rep(" ", mapW), colors.gray, colors.black)
    end

    if not mapCenter then
        mWrite(mon, mapX + 2, math.floor(mapH / 2) + 2, "Sin datos GPS", colors.gray, colors.black)
        return
    end

    -- Calcular auto-zoom basado en las posiciones
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for id, trail in pairs(mapTrails) do
        for _, p in ipairs(trail) do
            if p.x < minX then minX = p.x end
            if p.x > maxX then maxX = p.x end
            if p.z < minZ then minZ = p.z end
            if p.z > maxZ then maxZ = p.z end
        end
        local t = turtles[id]
        if t and t.pos then
            if t.pos.x < minX then minX = t.pos.x end
            if t.pos.x > maxX then maxX = t.pos.x end
            if t.pos.z < minZ then minZ = t.pos.z end
            if t.pos.z > maxZ then maxZ = t.pos.z end
        end
    end

    if minX == math.huge then return end

    -- Agregar margen
    local margin = 5
    minX = minX - margin
    maxX = maxX + margin
    minZ = minZ - margin
    maxZ = maxZ + margin

    local rangeX = maxX - minX
    local rangeZ = maxZ - minZ
    if rangeX < 1 then rangeX = 1 end
    if rangeZ < 1 then rangeZ = 1 end

    -- Funcion para convertir coords mundo a coords monitor
    local function worldToScreen(wx, wz)
        local sx = math.floor((wx - minX) / rangeX * (mapW - 1)) + mapX
        local sy = math.floor((wz - minZ) / rangeZ * (mapH - 1)) + 2
        return sx, sy
    end

    -- Dibujar trails
    for id, trail in pairs(mapTrails) do
        local col = getTurtleColor(id)
        for _, p in ipairs(trail) do
            local sx, sy = worldToScreen(p.x, p.z)
            if sx >= mapX and sx < mapX + mapW and sy >= 2 and sy <= mapH + 1 then
                mon.setCursorPos(sx, sy)
                mon.setBackgroundColor(col)
                mon.setTextColor(col)
                mon.write(".")
            end
        end
    end

    -- Dibujar posiciones actuales (encima de los trails)
    for id, t in pairs(turtles) do
        if t.pos and t.state ~= "offline" then
            local sx, sy = worldToScreen(t.pos.x, t.pos.z)
            if sx >= mapX and sx < mapX + mapW and sy >= 2 and sy <= mapH + 1 then
                mon.setCursorPos(sx, sy)
                mon.setBackgroundColor(getTurtleColor(id))
                mon.setTextColor(colors.white)
                mon.write("T")
            end
            -- Label debajo
            if sy + 1 <= mapH + 1 then
                local lbl = string.sub(t.label, 1, 6)
                if sx + #lbl - 1 < mapX + mapW then
                    mWrite(mon, sx, sy + 1, lbl, getTurtleColor(id), colors.black)
                end
            end
        end
    end

    -- Coordenadas en esquinas
    mon.setBackgroundColor(colors.black)
    mWrite(mon, mapX, mapH + 2, string.format("X:%d..%d Z:%d..%d", minX + margin, maxX - margin, minZ + margin, maxZ - margin), colors.gray)
end

--- Panel del log (parte inferior)
local function drawLogPanel(mon, startY)
    local logY = math.max(startY, math.floor(monH * 0.66))

    mWrite(mon, 1, logY, " LOG ", colors.white, colors.gray)
    mWrite(mon, 6, logY, string.rep(" ", monW - 5), colors.white, colors.gray)
    logY = logY + 1

    mon.setBackgroundColor(colors.black)
    local maxLines = monH - logY
    for i = 1, math.min(#eventLog, maxLines) do
        mWrite(mon, 1, logY + i - 1, string.sub(eventLog[i], 1, monW), colors.lightGray)
    end
end

--- Dibujo completo del monitor
local function drawMonitor()
    if not monitor then return end

    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    -- Header
    mWrite(monitor, 1, 1, "", colors.white, colors.black)

    local lastY = drawTurtlePanel(monitor)
    drawMapPanel(monitor)
    drawLogPanel(monitor, lastY + 1)
end

-- ============================================================
--  Terminal (consola del servidor)
-- ============================================================
local function drawTerminal()
    term.clear()
    term.setCursorPos(1, 1)
    print("========================================")
    print("  LINE FOLLOWER - SERVIDOR CENTRAL")
    print("  Protocolo: " .. PROTOCOL)
    print("========================================")

    local count = 0
    local online = 0
    for id, t in pairs(turtles) do
        count = count + 1
        if t.state ~= "offline" then online = online + 1 end
    end
    print("  Turtles: " .. online .. "/" .. count .. " online")
    print("  Monitor: " .. (monitor and (monW .. "x" .. monH) or "No encontrado"))
    print("")
    print("  Ultimos eventos:")
    for i = 1, math.min(#eventLog, 10) do
        print("    " .. eventLog[i])
    end
    print("")
    print("  Ctrl+T para detener")
end

-- ============================================================
--  LOOPS PRINCIPALES
-- ============================================================

--- Loop receptor de mensajes
local function receiverLoop()
    while true do
        local senderId, msg = rednet.receive(PROTOCOL, REFRESH_RATE)
        if senderId then
            processMessage(senderId, msg)
        end
    end
end

--- Loop de refresco de pantalla
local function displayLoop()
    while true do
        checkOffline()
        drawMonitor()
        drawTerminal()
        sleep(REFRESH_RATE)
    end
end

-- ============================================================
--  MAIN
-- ============================================================
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("Iniciando servidor Line Follower...")

    -- Buscar modem
    local modemSide = findModem()
    if not modemSide then
        print("ERROR: No se encontro modem wireless!")
        print("Conecta un wireless modem a la computadora.")
        return
    end
    print("Modem: " .. modemSide)

    -- Buscar monitor
    monitor = findMonitor()
    if monitor then
        print("Monitor: " .. monW .. "x" .. monH)
    else
        print("WARN: No se encontro monitor")
        print("Solo se mostrara info en la terminal.")
    end

    print("")
    addLog("Servidor iniciado")
    addLog("Esperando turtles en protocolo '" .. PROTOCOL .. "'...")

    print("Servidor listo. Esperando turtles...")
    print("Ctrl+T para detener")
    sleep(1)

    -- Ejecutar ambos loops en paralelo
    parallel.waitForAny(receiverLoop, displayLoop)
end

local ok, err = pcall(main)
if not ok then
    print("Error: " .. tostring(err))
end
