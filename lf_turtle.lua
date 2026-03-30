-- ============================================================
--  lf_turtle.lua  v3.0
--  Turtle seguidor de linea - CLIENTE
--
--  Escaneo inteligente: usa inspect() para pre-chequear
--  direcciones ANTES de mover, reduciendo movimientos basura.
--  Reporta posicion GPS y estado al servidor central.
--
--  Modos: SCAN | REPLAY
-- ============================================================

-- === CONFIG ===
local TARGET_BLOCK   = "minecraft:cobblestone"
local PROTOCOL       = "linefollower"
local ROUTE_DIR      = "routes"
local FUEL_WARNING   = 100
local REPORT_EVERY   = 3      -- Reportar posicion cada N pasos
local LABEL          = os.getComputerLabel() or ("Turtle-" .. os.getComputerID())

-- ============================================================
--  Utilidades
-- ============================================================
local modemSide = nil

local function log(msg)
    local time = textutils.formatTime(os.time(), true)
    print(string.format("[%s] %s", time, msg))
end

local function findModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
            modemSide = side
            rednet.open(side)
            return true
        end
    end
    return false
end

local function getGPS()
    local x, y, z = gps.locate(2)
    if x then
        return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    end
    return nil
end

--- Envia un mensaje al servidor central
local function report(msgType, data)
    if not modemSide then return end
    local payload = {
        type     = msgType,
        id       = os.getComputerID(),
        label    = LABEL,
        fuel     = turtle.getFuelLevel(),
        pos      = getGPS(),
        time     = os.clock(),
        data     = data or {},
    }
    rednet.broadcast(payload, PROTOCOL)
end

local function isTarget(inspectFn)
    local ok, data = inspectFn()
    return ok and data.name == TARGET_BLOCK
end

local function checkFuel()
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return true end
    if fuel < FUEL_WARNING then
        log("WARN: Fuel bajo (" .. fuel .. ")")
        report("warning", { msg = "Fuel bajo: " .. fuel })
    end
    if fuel <= 0 then
        for slot = 1, 16 do
            turtle.select(slot)
            if turtle.refuel(1) then
                log("Recargado desde slot " .. slot)
                turtle.select(1)
                return true
            end
        end
        turtle.select(1)
        report("error", { msg = "Sin combustible" })
        return false
    end
    return true
end

local function collectItems()
    turtle.suck()
    turtle.suckDown()
    turtle.suckUp()
end

local function countItems()
    local total = 0
    for slot = 1, 16 do
        total = total + turtle.getItemCount(slot)
    end
    return total
end

-- ============================================================
--  Movimiento seguro
-- ============================================================
local function safeForward()
    for _ = 1, 3 do
        if turtle.forward() then return true end
        turtle.attack()
        sleep(0.2)
    end
    return false
end

local function safeUp()
    for _ = 1, 3 do
        if turtle.up() then return true end
        turtle.attackUp()
        sleep(0.2)
    end
    return false
end

local function safeDown()
    for _ = 1, 3 do
        if turtle.down() then return true end
        turtle.attackDown()
        sleep(0.2)
    end
    return false
end

-- ============================================================
--  Acciones atomicas
-- ============================================================
local ACTIONS = {
    F  = function() return safeForward() end,
    B  = function() return turtle.back() end,
    U  = function() return safeUp() end,
    D  = function() return safeDown() end,
    TL = function() turtle.turnLeft()  return true end,
    TR = function() turtle.turnRight() return true end,
}

-- ============================================================
--  SCAN INTELIGENTE
--
--  Estrategia: usar inspect() para DESCARTAR direcciones
--  antes de intentar moverse. Solo mueve si hay chance real.
--
--  Regla clave: la turtle camina SOBRE cobblestone.
--  Despues de moverse, el bloque de abajo debe ser cobblestone.
--
--  Pre-checks:
--    - turtle.detect()   = hay bloque enfrente (no puedo avanzar)
--    - turtle.detectUp()  = hay bloque arriba (no puedo subir)
--    - turtle.inspect()   = puedo ver QUE bloque hay enfrente
--    - Si el bloque enfrente ES cobblestone, puede ser una subida
-- ============================================================

--- Busca el siguiente bloque de cobblestone de forma eficiente.
--- Retorna: acciones (tabla), nombre_direccion (string) | nil, nil
local function smartScanNext()
    -- ==============================================
    --  Fase 1: Chequear las 4 direcciones cardinales
    --  Para cada una, usar inspect para decidir que probar
    -- ==============================================
    local candidates = {}

    for turn = 0, 3 do
        local blocked   = turtle.detect()
        local frontIsCobble = false

        if not blocked then
            -- Camino libre: puedo intentar avanzar
            -- Caso PLANO: avanzar y cobble abajo
            table.insert(candidates, {
                priority = (turn == 0) and 1 or (10 + turn),
                actions  = {},  -- se arman despues con los giros
                test     = "flat",
                turns    = turn,
            })
            -- Caso BAJAR: avanzar + bajar (rampa descendente)
            table.insert(candidates, {
                priority = (turn == 0) and 3 or (20 + turn),
                test     = "down",
                turns    = turn,
            })
        else
            -- Hay bloque enfrente: revisar si ES cobblestone (subida)
            local ok, data = turtle.inspect()
            if ok and data.name == TARGET_BLOCK then
                frontIsCobble = true
            end
        end

        -- Caso SUBIR: si arriba esta libre Y (enfrente hay cobble O
        -- enfrente esta libre para subir+avanzar)
        if not turtle.detectUp() then
            if frontIsCobble then
                -- Cobblestone enfrente = probable subida
                table.insert(candidates, {
                    priority = (turn == 0) and 2 or (15 + turn),
                    test     = "up",
                    turns    = turn,
                })
            elseif not blocked then
                -- Libre arriba y enfrente: subir+avanzar posible
                table.insert(candidates, {
                    priority = (turn == 0) and 4 or (25 + turn),
                    test     = "up_free",
                    turns    = turn,
                })
            end
        end

        -- Girar para chequear siguiente direccion
        if turn < 3 then
            turtle.turnRight()
        end
    end

    -- Volver a la orientacion original (giramos 3 veces = falta 1)
    turtle.turnRight()

    -- Ordenar por prioridad
    table.sort(candidates, function(a, b) return a.priority < b.priority end)

    -- ==============================================
    --  Fase 2: Probar candidatos en orden de prioridad
    --  Ahora SI movemos, pero solo los que pasaron el pre-check
    -- ==============================================
    for _, cand in ipairs(candidates) do
        -- Aplicar giros necesarios
        local turnActions = {}
        if cand.turns == 1 then
            turtle.turnRight()
            turnActions = {"TR"}
        elseif cand.turns == 2 then
            turtle.turnRight()
            turtle.turnRight()
            turnActions = {"TR", "TR"}
        elseif cand.turns == 3 then
            turtle.turnLeft()
            turnActions = {"TL"}
        end

        local success = false
        local moveActions = {}

        if cand.test == "flat" then
            -- Avanzar, verificar cobble abajo
            if safeForward() then
                if isTarget(turtle.inspectDown) then
                    moveActions = {"F"}
                    success = true
                else
                    turtle.back()
                end
            end

        elseif cand.test == "down" then
            -- Avanzar + bajar
            if safeForward() then
                if safeDown() then
                    if isTarget(turtle.inspectDown) then
                        moveActions = {"F", "D"}
                        success = true
                    else
                        safeUp()
                        turtle.back()
                    end
                else
                    turtle.back()
                end
            end

        elseif cand.test == "up" then
            -- Subir + avanzar (cobblestone enfrente = escalera)
            if safeUp() then
                if safeForward() then
                    if isTarget(turtle.inspectDown) then
                        moveActions = {"U", "F"}
                        success = true
                    else
                        turtle.back()
                        safeDown()
                    end
                else
                    safeDown()
                end
            end

        elseif cand.test == "up_free" then
            -- Subir + avanzar (espacio libre)
            if safeUp() then
                if safeForward() then
                    if isTarget(turtle.inspectDown) then
                        moveActions = {"U", "F"}
                        success = true
                    else
                        turtle.back()
                        safeDown()
                    end
                else
                    safeDown()
                end
            end
        end

        if success then
            -- Combinar giros + movimiento
            local allActions = {}
            for _, a in ipairs(turnActions) do table.insert(allActions, a) end
            for _, a in ipairs(moveActions) do table.insert(allActions, a) end

            local dirNames = {"adelante", "derecha", "atras", "izquierda"}
            local dirName = dirNames[cand.turns + 1] or "?"
            if cand.test == "up" or cand.test == "up_free" then
                dirName = "subir+" .. dirName
            elseif cand.test == "down" then
                dirName = "bajar+" .. dirName
            end

            return allActions, dirName
        else
            -- Deshacer giros
            if cand.turns == 1 then
                turtle.turnLeft()
            elseif cand.turns == 2 then
                turtle.turnLeft()
                turtle.turnLeft()
            elseif cand.turns == 3 then
                turtle.turnRight()
            end
        end
    end

    return nil, nil
end

-- ============================================================
--  Sistema de rutas
-- ============================================================
local function ensureRouteDir()
    if not fs.exists(ROUTE_DIR) then fs.makeDir(ROUTE_DIR) end
end

local function getRoutePath(name)
    return ROUTE_DIR .. "/" .. name .. ".route"
end

local function saveRoute(name, steps, isLoop)
    ensureRouteDir()
    local path = getRoutePath(name)
    local data = {
        name    = name,
        block   = TARGET_BLOCK,
        steps   = steps,
        loop    = isLoop,
        total   = #steps,
        created = os.day() .. ":" .. textutils.formatTime(os.time(), true),
    }
    local file = fs.open(path, "w")
    file.write(textutils.serialise(data))
    file.close()
    log("Ruta guardada: " .. path .. " (" .. #steps .. " acciones)")
end

local function loadRoute(name)
    local path = getRoutePath(name)
    if not fs.exists(path) then return nil, "No encontrado: " .. path end
    local file = fs.open(path, "r")
    local content = file.readAll()
    file.close()
    local data = textutils.unserialise(content)
    if not data or not data.steps then return nil, "Archivo corrupto" end
    return data
end

local function listRoutes()
    ensureRouteDir()
    local files = fs.list(ROUTE_DIR)
    local routes = {}
    for _, f in ipairs(files) do
        if f:match("%.route$") then
            table.insert(routes, f:gsub("%.route$", ""))
        end
    end
    return routes
end

-- ============================================================
--  Busqueda cuando pierde la linea
-- ============================================================
local function searchForLine()
    log("Linea perdida - buscando...")
    report("status", { state = "searching" })
    local startTime = os.clock()

    while true do
        local actions, dirName = smartScanNext()
        if actions then
            log("Linea re-encontrada! (" .. dirName .. ")")
            report("status", { state = "found" })
            return actions
        end

        -- Expandir busqueda: intentar moverse a algun lado
        local moved = false
        for _ = 1, 4 do
            if not turtle.detect() then
                if safeForward() then
                    if isTarget(turtle.inspectDown) then
                        log("Linea encontrada expandiendo!")
                        return {}
                    end
                    moved = true
                    break
                end
            end
            turtle.turnRight()
        end

        if not moved then
            if not turtle.detectUp() then
                safeUp()
                log("Subiendo para buscar...")
            end
        end

        if os.clock() - startTime > SEARCH_TIMEOUT then
            log("Busqueda extendida... (Ctrl+T para detener)")
            report("warning", { msg = "Busqueda extendida" })
            startTime = os.clock()
        end

        if not checkFuel() then return nil end
        sleep(0.2)
    end
end

-- ============================================================
--  MODO SCAN
-- ============================================================
local function runScan(routeName, isLoop)
    log("=== MODO SCAN ===")
    log("Ruta: " .. routeName)
    report("status", { state = "scan_start", route = routeName })

    if not isTarget(turtle.inspectDown) then
        log("No hay cobblestone debajo! Buscando...")
        local seq = searchForLine()
        if not seq then
            log("No se encontro la linea.")
            return
        end
    end

    log("Linea detectada - escaneando...")
    log("Ctrl+T para detener y guardar")
    print("")

    local allSteps = {}
    local stepCount = 0
    local startPos = getGPS()

    report("status", { state = "scanning", route = routeName, startPos = startPos })

    while true do
        if not checkFuel() then break end

        collectItems()

        local actions, dirName = smartScanNext()

        if actions and #actions > 0 then
            for _, act in ipairs(actions) do
                table.insert(allSteps, act)
            end
            stepCount = stepCount + 1

            -- Reportar al servidor
            if stepCount % REPORT_EVERY == 0 then
                report("progress", {
                    state    = "scanning",
                    route    = routeName,
                    step     = stepCount,
                    actions  = #allSteps,
                    dir      = dirName,
                    items    = countItems(),
                })
            end

            if stepCount % 25 == 0 then
                local fuel_str = turtle.getFuelLevel()
                if fuel_str ~= "unlimited" then fuel_str = tostring(fuel_str) end
                log("Paso " .. stepCount .. " | " .. dirName .. " | Acciones: " .. #allSteps .. " | Fuel: " .. fuel_str)
            end
        elseif actions and #actions == 0 then
            -- searchForLine retorno {} (ya estamos en la linea)
            stepCount = stepCount + 1
        else
            log("Fin de la linea detectado.")
            break
        end

        sleep(0.05)
    end

    if #allSteps > 0 then
        saveRoute(routeName, allSteps, isLoop)
        report("status", {
            state    = "scan_complete",
            route    = routeName,
            steps    = stepCount,
            actions  = #allSteps,
            startPos = startPos,
            endPos   = getGPS(),
        })
        log("")
        log("SCAN COMPLETO")
        log("  Pasos   : " .. stepCount)
        log("  Acciones: " .. #allSteps)
    else
        log("No se grabo ninguna accion.")
    end
end

-- ============================================================
--  MODO REPLAY
-- ============================================================
local function runReplay(routeName)
    local data, err = loadRoute(routeName)
    if not data then
        log("Error: " .. err)
        return
    end

    log("=== MODO REPLAY ===")
    log("Ruta    : " .. data.name)
    log("Acciones: " .. data.total)
    log("Loop    : " .. (data.loop and "SI" or "NO"))
    log("Ctrl+T para detener")
    print("")

    report("status", { state = "replay_start", route = data.name, total = data.total, loop = data.loop })

    local totalRuns = 0

    while true do
        totalRuns = totalRuns + 1
        if data.loop then
            log("--- Vuelta #" .. totalRuns .. " ---")
        end

        report("status", { state = "replaying", route = data.name, run = totalRuns })

        for i, act in ipairs(data.steps) do
            if not checkFuel() then
                report("error", { msg = "Sin fuel en paso " .. i })
                return
            end

            local fn = ACTIONS[act]
            if not fn then
                log("ERROR: Accion desconocida '" .. act .. "'")
                return
            end

            local ok = false
            for _ = 1, 5 do
                ok = fn()
                if ok then break end
                sleep(0.2)
            end

            if not ok then
                log("BLOQUEADO en paso " .. i .. " (" .. act .. ")")
                report("warning", { msg = "Bloqueado en paso " .. i, action = act })
                sleep(2)
                ok = fn()
                if not ok then
                    log("Ruta bloqueada. Re-escanea si cambio.")
                    report("error", { msg = "Ruta bloqueada en paso " .. i })
                    return
                end
            end

            if i % 3 == 0 then collectItems() end

            -- Reportar al servidor
            if i % (REPORT_EVERY * 2) == 0 then
                report("progress", {
                    state   = "replaying",
                    route   = data.name,
                    step    = i,
                    total   = data.total,
                    run     = totalRuns,
                    items   = countItems(),
                    pct     = math.floor(i / data.total * 100),
                })
            end
        end

        collectItems()

        report("status", {
            state = "replay_lap",
            route = data.name,
            run   = totalRuns,
            items = countItems(),
        })

        if not data.loop then
            log("Ruta completada!")
            report("status", { state = "replay_done", route = data.name, runs = totalRuns })
            break
        end

        log("Vuelta #" .. totalRuns .. " completada")
    end
end

-- ============================================================
--  MENU
-- ============================================================
local function inputText(prompt)
    write(prompt)
    return read()
end

local function drawHeader()
    term.clear()
    term.setCursorPos(1, 1)
    print("========================================")
    print("  LINE FOLLOWER TURTLE v3.0")
    print("  ID: " .. os.getComputerID() .. " | " .. LABEL)
    print("========================================")
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" then
        print("  Fuel: " .. fuel)
    end
    local pos = getGPS()
    if pos then
        print("  GPS: " .. pos.x .. ", " .. pos.y .. ", " .. pos.z)
    else
        print("  GPS: No disponible")
    end
    print("  Modem: " .. (modemSide or "No encontrado"))
    print("")
end

local function menuScan()
    drawHeader()
    print("=== NUEVO ESCANEO ===")
    print("")
    local name = inputText("Nombre de la ruta: ")
    if name == "" then name = "ruta1" end
    name = name:gsub("[^%w_%-]", "_")

    local existing = loadRoute(name)
    if existing then
        print("Ya existe '" .. name .. "' (" .. existing.total .. " acciones)")
        local confirm = inputText("Sobreescribir? (s/n): ")
        if confirm:lower() ~= "s" then return end
    end

    print("")
    local loopInput = inputText("Ruta ciclica/loop? (s/n): ")
    local isLoop = loopInput:lower() == "s"

    print("")
    print("Coloca la turtle sobre cobblestone")
    print("mirando en la direccion del camino.")
    inputText("Enter para iniciar...")

    runScan(name, isLoop)
    inputText("Enter para volver al menu...")
end

local function menuReplay()
    drawHeader()
    print("=== EJECUTAR RUTA ===")
    print("")

    local routes = listRoutes()
    if #routes == 0 then
        print("No hay rutas guardadas.")
        inputText("Enter para volver...")
        return
    end

    print("Rutas disponibles:")
    print("")
    for i, name in ipairs(routes) do
        local data = loadRoute(name)
        local info = ""
        if data then
            info = " (" .. data.total .. " act"
            if data.loop then info = info .. ", loop" end
            info = info .. ")"
        end
        print("  " .. i .. ". " .. name .. info)
    end
    print("")

    local choice = inputText("Numero o nombre: ")
    local routeName
    local num = tonumber(choice)
    if num and routes[num] then
        routeName = routes[num]
    else
        routeName = choice
    end
    if routeName == "" then return end

    print("")
    print("Coloca la turtle en el INICIO de la ruta")
    print("mirando en la MISMA DIRECCION del scan.")
    inputText("Enter para iniciar...")

    runReplay(routeName)
    inputText("Enter para volver al menu...")
end

local function menuRoutes()
    drawHeader()
    print("=== RUTAS GUARDADAS ===")
    print("")
    local routes = listRoutes()
    if #routes == 0 then
        print("No hay rutas guardadas.")
    else
        for i, name in ipairs(routes) do
            local data = loadRoute(name)
            if data then
                print(string.format("  %d. %s (%d act, %s)",
                    i, data.name, data.total,
                    data.loop and "loop" or "una vez"))
            end
        end
    end
    print("")
    local del = inputText("Borrar ruta (nombre/Enter): ")
    if del ~= "" then
        del = del:gsub("[^%w_%-]", "_")
        local path = getRoutePath(del)
        if fs.exists(path) then
            fs.delete(path)
            log("Borrada: " .. del)
        else
            log("No encontrada: " .. del)
        end
        sleep(1)
    end
end

local function mainMenu()
    -- Buscar modem wireless
    if findModem() then
        log("Modem encontrado en: " .. modemSide)
    else
        log("WARN: No se encontro modem wireless")
        log("Funcionara sin reportar al servidor.")
    end

    -- Registrar con el servidor
    report("status", { state = "online" })

    while true do
        drawHeader()
        print("  1. SCAN   - Escanear nueva ruta")
        print("  2. REPLAY - Ejecutar ruta guardada")
        print("  3. RUTAS  - Ver/borrar rutas")
        print("  4. SALIR")
        print("")

        local choice = inputText("Opcion: ")

        if choice == "1" then
            menuScan()
        elseif choice == "2" then
            menuReplay()
        elseif choice == "3" then
            menuRoutes()
        elseif choice == "4" then
            report("status", { state = "offline" })
            drawHeader()
            print("Hasta luego!")
            return
        end
    end
end

-- ============================================================
local ok, err = pcall(mainMenu)
if not ok then
    print("Error: " .. tostring(err))
    report("error", { msg = tostring(err) })
end
