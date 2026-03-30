-- ============================================================
--  line_follower.lua  v2.0
--  Turtle seguidor de linea de cobblestone
--
--  Dos modos de operacion:
--    SCAN   - Recorre la linea, detecta cobblestone, y GRABA
--             cada movimiento en un archivo de ruta
--    REPLAY - Ejecuta la ruta grabada a maxima velocidad
--             sin necesidad de inspeccionar bloques
--
--  Recoge items del camino en ambos modos
-- ============================================================

local TARGET_BLOCK  = "minecraft:cobblestone"
local ROUTE_FILE    = "routes/%s.route"   -- %s = nombre de ruta
local FUEL_WARNING  = 100
local SEARCH_TIMEOUT = 60

-- ============================================================
--  Utilidades
-- ============================================================
local function log(msg)
    local time = textutils.formatTime(os.time(), true)
    print(string.format("[%s] %s", time, msg))
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
    end
    if fuel <= 0 then
        log("SIN FUEL - Intentando recargar...")
        for slot = 1, 16 do
            turtle.select(slot)
            if turtle.refuel(1) then
                log("Recargado desde slot " .. slot)
                turtle.select(1)
                return true
            end
        end
        turtle.select(1)
        log("ERROR: Sin combustible")
        return false
    end
    return true
end

local function collectItems()
    turtle.suck()
    turtle.suckDown()
    turtle.suckUp()
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
--  Acciones atomicas (las que se graban)
--  Cada accion es un string corto serializable
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
--  Sistema de rutas - guardar / cargar
-- ============================================================

local function ensureRouteDir()
    if not fs.exists("routes") then
        fs.makeDir("routes")
    end
end

local function getRoutePath(name)
    return string.format(ROUTE_FILE, name)
end

local function saveRoute(name, steps, loop)
    ensureRouteDir()
    local path = getRoutePath(name)
    local data = {
        name     = name,
        block    = TARGET_BLOCK,
        steps    = steps,
        loop     = loop,
        total    = #steps,
        created  = os.day() .. ":" .. textutils.formatTime(os.time(), true),
    }
    local file = fs.open(path, "w")
    file.write(textutils.serialise(data))
    file.close()
    log("Ruta guardada: " .. path .. " (" .. #steps .. " acciones)")
end

local function loadRoute(name)
    local path = getRoutePath(name)
    if not fs.exists(path) then
        return nil, "Archivo no encontrado: " .. path
    end
    local file = fs.open(path, "r")
    local content = file.readAll()
    file.close()
    local data = textutils.unserialise(content)
    if not data or not data.steps then
        return nil, "Archivo corrupto"
    end
    return data
end

local function listRoutes()
    ensureRouteDir()
    local files = fs.list("routes")
    local routes = {}
    for _, f in ipairs(files) do
        if f:match("%.route$") then
            table.insert(routes, f:gsub("%.route$", ""))
        end
    end
    return routes
end

-- ============================================================
--  MODO SCAN - Recorre la linea y graba movimientos
-- ============================================================

--- Intenta una secuencia de movimientos.
--- Si el bloque debajo al final es cobblestone, retorna las acciones.
--- Si no, deshace todo y retorna nil.
local function trySequence(actions, undoActions)
    for i, act in ipairs(actions) do
        if not ACTIONS[act]() then
            -- Fallo al ejecutar, deshacer lo que se hizo
            for j = i - 1, 1, -1 do
                ACTIONS[undoActions[j]]()
            end
            return false
        end
    end
    -- Verificar cobblestone debajo
    if isTarget(turtle.inspectDown) then
        return true
    end
    -- No era cobblestone, deshacer todo
    for j = #undoActions, 1, -1 do
        ACTIONS[undoActions[j]]()
    end
    return false
end

--- Prueba todas las direcciones posibles y retorna la secuencia ganadora
local function scanFindNext()
    -- Definir todas las jugadas posibles:
    -- { acciones_a_ejecutar, acciones_para_deshacer, nombre }
    local moves = {
        -- Mismo nivel
        { {"F"},             {"B"},             "adelante"         },
        { {"TL", "F"},       {"B", "TR"},       "izquierda"        },
        { {"TR", "F"},       {"B", "TL"},       "derecha"          },
        -- Subir
        { {"U", "F"},        {"B", "D"},        "subir+adelante"   },
        { {"TL", "U", "F"},  {"B", "D", "TR"},  "subir+izquierda"  },
        { {"TR", "U", "F"},  {"B", "D", "TL"},  "subir+derecha"    },
        -- Bajar
        { {"F", "D"},        {"U", "B"},        "bajar+adelante"   },
        { {"TL", "F", "D"},  {"U", "B", "TR"},  "bajar+izquierda"  },
        { {"TR", "F", "D"},  {"U", "B", "TL"},  "bajar+derecha"    },
        -- U-turn
        { {"TR", "TR", "F"}, {"B", "TL", "TL"}, "U-turn"           },
    }

    for _, move in ipairs(moves) do
        if trySequence(move[1], move[2]) then
            return move[1], move[3]
        end
    end

    return nil, nil
end

--- Busqueda expandida cuando pierde la linea
local function searchForLine()
    log("Linea perdida - buscando...")
    local startTime = os.clock()

    while true do
        -- Girar 360 probando cada direccion con variantes de altura
        for _ = 1, 4 do
            local seq = scanFindNext()
            if seq then
                log("Linea re-encontrada!")
                return seq
            end
            turtle.turnRight()
        end

        -- Expandir: moverse un bloque
        local moved = false
        for _ = 1, 4 do
            if safeForward() then
                if isTarget(turtle.inspectDown) then
                    log("Linea encontrada expandiendo!")
                    return {}  -- Ya estamos sobre ella
                end
                moved = true
                break
            end
            turtle.turnRight()
        end

        if not moved then
            safeUp()
            log("Subiendo para buscar...")
        end

        if os.clock() - startTime > SEARCH_TIMEOUT then
            log("Busqueda extendida... (Ctrl+T para detener)")
            startTime = os.clock()
        end

        if not checkFuel() then return nil end
        sleep(0.2)
    end
end

local function runScan(routeName, isLoop)
    log("=== MODO SCAN ===")
    log("Ruta: " .. routeName)

    if not isTarget(turtle.inspectDown) then
        log("No hay cobblestone debajo! Buscando...")
        local seq = searchForLine()
        if not seq then
            log("No se encontro la linea. Abortando.")
            return
        end
    end

    log("Linea detectada - escaneando ruta...")
    log("Presiona Ctrl+T para detener y guardar")
    print("")

    local allSteps = {}  -- Todas las acciones grabadas
    local stepCount = 0

    while true do
        if not checkFuel() then break end

        collectItems()

        local actions, dirName = scanFindNext()

        if actions then
            -- Grabar todas las acciones de este movimiento
            for _, act in ipairs(actions) do
                table.insert(allSteps, act)
            end
            stepCount = stepCount + 1

            if stepCount % 25 == 0 then
                local fuel_str = turtle.getFuelLevel()
                if fuel_str ~= "unlimited" then fuel_str = tostring(fuel_str) end
                log("Paso " .. stepCount .. " | " .. dirName .. " | Acciones: " .. #allSteps .. " | Fuel: " .. fuel_str)
            end
        else
            -- Preguntar si quiere guardar lo que tiene
            log("No se encontro siguiente bloque.")
            log("Fin de la linea detectado con " .. #allSteps .. " acciones.")
            break
        end

        sleep(0.05)
    end

    if #allSteps > 0 then
        saveRoute(routeName, allSteps, isLoop)
        log("")
        log("SCAN COMPLETO")
        log("  Pasos logicos : " .. stepCount)
        log("  Acciones total: " .. #allSteps)
        log("  Guardado en   : " .. getRoutePath(routeName))
        if isLoop then
            log("  Modo          : LOOP (se repite infinito)")
        end
    else
        log("No se grabo ninguna accion.")
    end
end

-- ============================================================
--  MODO REPLAY - Ejecuta ruta grabada a maxima velocidad
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
    log("Presiona Ctrl+T para detener")
    print("")

    local totalRuns = 0

    while true do
        totalRuns = totalRuns + 1
        if data.loop then
            log("--- Vuelta #" .. totalRuns .. " ---")
        end

        for i, act in ipairs(data.steps) do
            if not checkFuel() then
                log("Sin fuel en accion " .. i .. "/" .. data.total)
                return
            end

            local fn = ACTIONS[act]
            if not fn then
                log("ERROR: Accion desconocida '" .. act .. "' en posicion " .. i)
                return
            end

            -- Ejecutar la accion (reintentar si falla por mob)
            local ok = false
            for attempt = 1, 5 do
                ok = fn()
                if ok then break end
                sleep(0.2)
            end

            if not ok then
                log("FALLO en accion " .. i .. "/" .. data.total .. " (" .. act .. ")")
                log("Reintentando despues de pausa...")
                sleep(2)
                ok = fn()
                if not ok then
                    log("No se pudo ejecutar. Ruta bloqueada.")
                    log("Tip: Ejecuta SCAN de nuevo si la ruta cambio.")
                    return
                end
            end

            -- Recoger items cada ciertos pasos
            if i % 3 == 0 then
                collectItems()
            end

            -- Progreso cada 100 acciones
            if i % 100 == 0 then
                local fuel_str = turtle.getFuelLevel()
                if fuel_str ~= "unlimited" then fuel_str = tostring(fuel_str) end
                log("Progreso: " .. i .. "/" .. data.total .. " | Fuel: " .. fuel_str)
            end

            -- Sin delay para maxima velocidad
            -- (CraftOS ya limita a ~20 acciones/segundo por el server tick)
        end

        collectItems()  -- Recoger al final de cada vuelta

        if not data.loop then
            log("Ruta completada! (" .. data.total .. " acciones)")
            break
        end

        log("Vuelta #" .. totalRuns .. " completada")
    end
end

-- ============================================================
--  MENU PRINCIPAL
-- ============================================================

local function drawHeader()
    term.clear()
    term.setCursorPos(1, 1)
    print("========================================")
    print("  TURTLE SEGUIDOR DE LINEA v2.0")
    print("  Bloque: " .. TARGET_BLOCK)
    print("========================================")

    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" then
        print("  Fuel: " .. fuel)
    end
    print("")
end

local function inputText(prompt)
    write(prompt)
    return read()
end

local function menuScan()
    drawHeader()
    print("=== NUEVO ESCANEO ===")
    print("")

    local name = inputText("Nombre de la ruta: ")
    if name == "" then
        name = "ruta1"
    end
    -- Limpiar nombre
    name = name:gsub("[^%w_%-]", "_")

    -- Verificar si existe
    local existing = loadRoute(name)
    if existing then
        print("")
        print("Ya existe una ruta '" .. name .. "' con " .. existing.total .. " acciones.")
        local confirm = inputText("Sobreescribir? (s/n): ")
        if confirm:lower() ~= "s" then
            log("Cancelado.")
            return
        end
    end

    print("")
    local loopInput = inputText("Es ruta ciclica/loop? (s/n): ")
    local isLoop = loopInput:lower() == "s"

    print("")
    print("Coloca la turtle sobre la linea de cobblestone")
    print("mirando en la direccion del camino.")
    print("")
    local ready = inputText("Listo para escanear? (Enter): ")

    runScan(name, isLoop)

    print("")
    inputText("Enter para volver al menu...")
end

local function menuReplay()
    drawHeader()
    print("=== EJECUTAR RUTA ===")
    print("")

    local routes = listRoutes()

    if #routes == 0 then
        print("No hay rutas guardadas.")
        print("Primero ejecuta un SCAN.")
        print("")
        inputText("Enter para volver...")
        return
    end

    print("Rutas disponibles:")
    print("")
    for i, name in ipairs(routes) do
        local data = loadRoute(name)
        local info = ""
        if data then
            info = " (" .. data.total .. " acciones"
            if data.loop then info = info .. ", loop" end
            info = info .. ")"
        end
        print("  " .. i .. ". " .. name .. info)
    end
    print("")

    local choice = inputText("Numero o nombre de ruta: ")
    local routeName

    -- Intentar como numero
    local num = tonumber(choice)
    if num and routes[num] then
        routeName = routes[num]
    else
        routeName = choice
    end

    if routeName == "" then return end

    print("")
    print("Coloca la turtle en el PUNTO DE INICIO de la ruta,")
    print("mirando en la MISMA DIRECCION que cuando se escaneo.")
    print("")
    inputText("Listo? (Enter): ")

    runReplay(routeName)

    print("")
    inputText("Enter para volver al menu...")
end

local function menuList()
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
                print(string.format("  %d. %s", i, data.name))
                print(string.format("     Acciones: %d | Loop: %s", data.total, data.loop and "Si" or "No"))
                if data.created then
                    print(string.format("     Creada: %s", data.created))
                end
                print("")
            end
        end
    end

    print("")
    local del = inputText("Borrar ruta? (nombre o Enter para salir): ")
    if del ~= "" then
        del = del:gsub("[^%w_%-]", "_")
        local path = getRoutePath(del)
        if fs.exists(path) then
            fs.delete(path)
            log("Ruta '" .. del .. "' borrada.")
        else
            log("Ruta no encontrada: " .. del)
        end
        sleep(1)
    end
end

local function mainMenu()
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
            menuList()
        elseif choice == "4" then
            drawHeader()
            print("Hasta luego!")
            return
        end
    end
end

-- ============================================================
--  Ejecucion con manejo de errores
-- ============================================================
local ok, err = pcall(mainMenu)
if not ok then
    print("")
    print("Error: " .. tostring(err))
    print("El programa se detuvo inesperadamente")
end
