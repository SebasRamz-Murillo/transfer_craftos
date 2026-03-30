-- ============================================================
--  lf_mapper.lua  v3.0
--  Turtle MAPPER — Escanea la infraestructura completa
--
--  Sigue el camino de stone, detecta intersecciones,
--  entradas a cobblestone, estaciones, inventarios.
--  Registra todo con coordenadas GPS exactas.
--
--  Genera un archivo de mapa que las turtles de trabajo usan.
-- ============================================================

-- === CONFIG ===
local PROTOCOL       = "linefollower"
local MAP_FILE       = "map/infrastructure.map"

-- Bloques que definen cada tipo de camino
local BLOCKS = {
    stone_path    = "minecraft:stone",
    cobble_path   = "minecraft:cobblestone",
    cobble_stairs = "minecraft:cobblestone_stairs",
    station_chest = "minecraft:chest",
    chiseled      = "minecraft:chiseled_stone_bricks",
    drawer        = "storagedrawers:",  -- prefijo, hay variantes
}

-- Punto de inicio del scan
local START_POS = { x = 118, y = 75, z = -19 }

-- ============================================================
--  Estado global
-- ============================================================
local mapData = {
    version    = 3,
    created    = nil,
    stone      = {          -- Camino principal de stone
        nodes  = {},        -- [i] = {x,y,z, type, connections, poi}
        graph  = {},        -- ["x,y,z"] = node_index
    },
    cobble     = {},        -- [route_id] = { nodes, graph, entry, exit }
    stations   = {},        -- [i] = {x,y,z, chestDir, id}
    inventories = {},       -- [i] = {x,y,z, blockDir, type}
    intersections = {},     -- [i] = {x,y,z, paths={"stone","cobble_1",...}}
    pois       = {},        -- Puntos de interes generales
}

local visited = {}          -- ["x,y,z"] = true
local modemSide = nil

-- Orientacion de la turtle (necesario para saber hacia donde mira)
-- 0=norte(-Z), 1=este(+X), 2=sur(+Z), 3=oeste(-X)
local facing = nil

-- ============================================================
--  Utilidades
-- ============================================================
local function log(msg)
    local time = textutils.formatTime(os.time(), true)
    print(string.format("[%s] %s", time, msg))
end

local function posKey(x, y, z)
    return x .. "," .. y .. "," .. z
end

local function getGPS()
    local x, y, z = gps.locate(2)
    if x then
        return { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    end
    return nil
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

local function report(msgType, data)
    if not modemSide then return end
    rednet.broadcast({
        type  = msgType,
        id    = os.getComputerID(),
        label = os.getComputerLabel() or "Mapper",
        fuel  = turtle.getFuelLevel(),
        pos   = getGPS(),
        data  = data or {},
    }, PROTOCOL)
end

-- ============================================================
--  Orientacion — Detectar hacia donde mira la turtle
-- ============================================================

--- Detecta la orientacion usando GPS: se mueve, mide delta, retrocede.
local function detectFacing()
    local pos1 = getGPS()
    if not pos1 then
        log("ERROR: GPS no disponible")
        return nil
    end

    -- Intentar moverse adelante
    if turtle.forward() then
        local pos2 = getGPS()
        turtle.back()

        if not pos2 then return nil end

        local dx = pos2.x - pos1.x
        local dz = pos2.z - pos1.z

        if dz == -1 then return 0 end      -- Norte (-Z)
        if dx == 1  then return 1 end      -- Este (+X)
        if dz == 1  then return 2 end      -- Sur (+Z)
        if dx == -1 then return 3 end      -- Oeste (-X)
    end

    -- Si no pudo avanzar, girar e intentar de nuevo
    turtle.turnRight()
    if turtle.forward() then
        local pos2 = getGPS()
        turtle.back()
        turtle.turnLeft()  -- Volver a orientacion original

        if not pos2 then return nil end

        local dx = pos2.x - pos1.x
        local dz = pos2.z - pos1.z

        -- Nos movimos hacia la DERECHA de donde mira
        -- Si la derecha es norte, nosotros miramos oeste, etc
        if dz == -1 then return 3 end   -- derecha=norte → miramos oeste
        if dx == 1  then return 0 end   -- derecha=este → miramos norte
        if dz == 1  then return 1 end   -- derecha=sur → miramos este
        if dx == -1 then return 2 end   -- derecha=oeste → miramos sur
    else
        turtle.turnLeft()
    end

    return nil
end

--- Actualiza facing despues de un giro
local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
end

local function turnAround()
    turnRight()
    turnRight()
end

--- Retorna la posicion del bloque que esta en la direccion dada
--- relativa a pos, segun facing
local function getAdjacentPos(pos, relDir)
    -- relDir: "front", "back", "left", "right"
    local absFacing = facing
    if relDir == "back"  then absFacing = (facing + 2) % 4
    elseif relDir == "left"  then absFacing = (facing - 1) % 4
    elseif relDir == "right" then absFacing = (facing + 1) % 4
    end

    if absFacing == 0 then return { x=pos.x, y=pos.y, z=pos.z-1 }
    elseif absFacing == 1 then return { x=pos.x+1, y=pos.y, z=pos.z }
    elseif absFacing == 2 then return { x=pos.x, y=pos.y, z=pos.z+1 }
    elseif absFacing == 3 then return { x=pos.x-1, y=pos.y, z=pos.z }
    end
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
--  Inspeccion de bloques
-- ============================================================

--- Chequea si un bloque coincide con un patron (string o prefijo)
local function blockMatches(data, pattern)
    if not data then return false end
    -- Si el patron termina en ":", es un prefijo
    if pattern:sub(-1) == ":" then
        return data.name:sub(1, #pattern) == pattern
    end
    return data.name == pattern
end

--- Inspecciona las 6 direcciones y retorna info detallada
local function scanSurroundings(pos)
    local result = {
        down  = { ok = false, data = nil },
        up    = { ok = false, data = nil },
        front = { ok = false, data = nil },
        back  = { ok = false, data = nil },
        left  = { ok = false, data = nil },
        right = { ok = false, data = nil },
    }

    -- Abajo y arriba
    local ok, data
    ok, data = turtle.inspectDown()
    result.down = { ok = ok, data = data }
    ok, data = turtle.inspectUp()
    result.up = { ok = ok, data = data }

    -- Frente
    ok, data = turtle.inspect()
    result.front = { ok = ok, data = data }

    -- Derecha
    turnRight()
    ok, data = turtle.inspect()
    result.right = { ok = ok, data = data }

    -- Atras
    turnRight()
    ok, data = turtle.inspect()
    result.back = { ok = ok, data = data }

    -- Izquierda
    turnRight()
    ok, data = turtle.inspect()
    result.left = { ok = ok, data = data }

    -- Volver a orientacion original
    turnRight()

    return result
end

--- Identifica que tiene cada direccion basado en el scan
local function classifyBlock(scanData)
    if not scanData.ok or not scanData.data then return "air" end
    local name = scanData.data.name

    if name == BLOCKS.stone_path     then return "stone" end
    if name == BLOCKS.cobble_path    then return "cobble" end
    if name == BLOCKS.cobble_stairs  then return "cobble_stairs" end
    if name == BLOCKS.chiseled       then return "chiseled" end
    if name == BLOCKS.station_chest  then return "chest" end
    if blockMatches(scanData.data, BLOCKS.drawer) then return "drawer" end

    return "other:" .. name
end

-- ============================================================
--  Deteccion de Puntos de Interes (POI)
-- ============================================================

--- Detecta si la posicion actual es una estacion de carga
local function detectStation(pos, surr)
    -- Una estacion tiene un cofre en alguna direccion
    local dirs = {"front", "left", "right", "back"}
    for _, dir in ipairs(dirs) do
        if classifyBlock(surr[dir]) == "chest" then
            local chestPos = getAdjacentPos(pos, dir)
            local station = {
                x = pos.x, y = pos.y, z = pos.z,
                chestX = chestPos.x, chestY = chestPos.y, chestZ = chestPos.z,
                chestDir = dir,
                id = #mapData.stations + 1,
            }
            table.insert(mapData.stations, station)
            log("  ESTACION #" .. station.id .. " en " .. posKey(pos.x, pos.y, pos.z) .. " cofre:" .. dir)
            report("poi", { type = "station", station = station })
            return station
        end
    end
    -- Tambien chequear cofre arriba (por si el cofre esta encima)
    if classifyBlock(surr.up) == "chest" then
        local station = {
            x = pos.x, y = pos.y, z = pos.z,
            chestX = pos.x, chestY = pos.y + 1, chestZ = pos.z,
            chestDir = "up",
            id = #mapData.stations + 1,
        }
        table.insert(mapData.stations, station)
        log("  ESTACION #" .. station.id .. " en " .. posKey(pos.x, pos.y, pos.z) .. " cofre:arriba")
        report("poi", { type = "station", station = station })
        return station
    end
    return nil
end

--- Detecta si hay un inventario de drawer (recolecci on)
local function detectInventory(pos, surr)
    local dirs = {"front", "left", "right", "back", "up", "down"}
    for _, dir in ipairs(dirs) do
        if classifyBlock(surr[dir]) == "drawer" then
            local invPos = pos
            if dir == "up" then
                invPos = { x = pos.x, y = pos.y + 1, z = pos.z }
            elseif dir == "down" then
                invPos = { x = pos.x, y = pos.y - 1, z = pos.z }
            else
                invPos = getAdjacentPos(pos, dir)
            end

            local inv = {
                x = pos.x, y = pos.y, z = pos.z,
                drawerX = invPos.x, drawerY = invPos.y, drawerZ = invPos.z,
                drawerDir = dir,
                blockName = surr[dir].data.name,
                id = #mapData.inventories + 1,
            }
            table.insert(mapData.inventories, inv)
            log("  INVENTARIO #" .. inv.id .. " en " .. posKey(pos.x, pos.y, pos.z) .. " drawer:" .. dir)
            report("poi", { type = "inventory", inventory = inv })
            return inv
        end
    end
    return nil
end

--- Detecta chiseled stone brick (marcador)
local function detectChiseled(pos, surr)
    local dirs = {"front", "left", "right", "back", "up", "down"}
    for _, dir in ipairs(dirs) do
        if classifyBlock(surr[dir]) == "chiseled" then
            return dir
        end
    end
    return nil
end

-- ============================================================
--  Deteccion de direcciones validas de camino
-- ============================================================

--- Cuenta cuantas direcciones de camino hay (para detectar intersecciones)
--- Retorna tabla de direcciones con camino del tipo dado
local function findPathDirs(pos, surr, pathBlock)
    local validDirs = {}

    -- Para cada direccion horizontal, chequear si hay camino
    -- El camino esta DEBAJO de donde camina la turtle
    -- Entonces tenemos que ver: si avanzo en esa dir, hay pathBlock debajo?
    -- PERO tambien el bloque de esa dir no debe estar bloqueado

    local dirs = {
        { name = "front", turn = 0 },
        { name = "right", turn = 1 },
        { name = "back",  turn = 2 },
        { name = "left",  turn = 3 },
    }

    for _, d in ipairs(dirs) do
        local blocked = surr[d.name].ok  -- hay bloque = bloqueado
        local blockType = classifyBlock(surr[d.name])

        -- Si el bloque ES el tipo de camino, puede ser una subida
        local isPathRamp = (blockType == pathBlock) or
                          (pathBlock == "cobble" and blockType == "cobble_stairs")

        if not blocked then
            -- Camino libre: podemos avanzar. Verificar si hay piso de camino adelante.
            -- No podemos inspectDown sin movernos, asi que registramos como "posible"
            table.insert(validDirs, {
                name = d.name,
                turn = d.turn,
                type = "flat",  -- posiblemente plano
            })
        elseif isPathRamp then
            -- Bloque de camino enfrente = probable subida
            table.insert(validDirs, {
                name = d.name,
                turn = d.turn,
                type = "ramp_up",
            })
        end
    end

    return validDirs
end

-- ============================================================
--  SCANNER PRINCIPAL — Sigue un tipo de camino
-- ============================================================

--- Escanea un camino completo siguiendo un tipo de bloque
--- pathType: "stone" o "cobble"
--- Returns: tabla de nodos con toda la info
local function scanPath(pathType, routeId)
    local pathBlock = (pathType == "stone") and "stone" or "cobble"
    local nodes = {}
    local graph = {}
    local nodeCount = 0
    local stepsWithoutPath = 0
    local maxLost = 15

    log("--- Escaneando camino de " .. pathType .. " ---")
    report("status", { state = "scanning_" .. pathType, route = routeId })

    -- Verificar que estamos sobre el camino correcto
    local startPos = getGPS()
    if not startPos then
        log("ERROR: Sin GPS")
        return nil
    end

    local ok, downData = turtle.inspectDown()
    local downType = ok and classifyBlock({ ok = ok, data = downData }) or "air"

    if downType ~= pathBlock and downType ~= "cobble_stairs" then
        log("WARN: No estoy sobre " .. pathType .. " (estoy sobre: " .. downType .. ")")
        log("Buscando camino cercano...")
    end

    -- Loop principal de escaneo
    while true do
        local pos = getGPS()
        if not pos then
            log("ERROR: Perdi GPS")
            break
        end

        local key = posKey(pos.x, pos.y, pos.z)

        -- Si ya visitamos esta posicion, terminamos (loop detectado)
        if visited[key] then
            log("Posicion ya visitada: " .. key .. " — loop o fin de camino")
            -- Registrar como conexion de vuelta
            if graph[key] then
                log("Circuito cerrado detectado")
            end
            break
        end

        visited[key] = true

        -- Escanear alrededores
        local surr = scanSurroundings(pos)

        -- Clasificar bloque de abajo
        local floorType = classifyBlock(surr.down)

        -- Crear nodo
        nodeCount = nodeCount + 1
        local node = {
            idx   = nodeCount,
            x     = pos.x,
            y     = pos.y,
            z     = pos.z,
            floor = floorType,
            facing = facing,
            poi   = {},  -- puntos de interes en este nodo
        }

        -- Detectar POIs
        local station = detectStation(pos, surr)
        if station then
            table.insert(node.poi, { type = "station", id = station.id })
        end

        local inventory = detectInventory(pos, surr)
        if inventory then
            table.insert(node.poi, { type = "inventory", id = inventory.id })
        end

        local chiDir = detectChiseled(pos, surr)
        if chiDir then
            table.insert(node.poi, { type = "chiseled", dir = chiDir })
        end

        -- Detectar intersecciones (entradas a otros caminos)
        -- Si estamos en stone y hay cobblestone al lado, es una entrada
        if pathType == "stone" then
            local dirs = {"front", "left", "right", "back"}
            for _, dir in ipairs(dirs) do
                local bt = classifyBlock(surr[dir])
                if bt == "cobble" or bt == "cobble_stairs" then
                    local adjPos = getAdjacentPos(pos, dir)
                    local inter = {
                        x = pos.x, y = pos.y, z = pos.z,
                        toX = adjPos.x, toY = adjPos.y, toZ = adjPos.z,
                        dir = dir,
                        facing = facing,
                        fromPath = "stone",
                        toPath = "cobble",
                        id = #mapData.intersections + 1,
                    }
                    table.insert(mapData.intersections, inter)
                    table.insert(node.poi, { type = "intersection", id = inter.id, to = "cobble" })
                    log("  INTERSECCION #" .. inter.id .. " stone->cobble en " .. key .. " dir:" .. dir)
                    report("poi", { type = "intersection", inter = inter })
                end
            end
        end

        -- Guardar nodo
        table.insert(nodes, node)
        graph[key] = nodeCount

        -- Reportar progreso
        if nodeCount % 10 == 0 then
            local fuel = turtle.getFuelLevel()
            if fuel ~= "unlimited" then fuel = tostring(fuel) end
            log("Nodo " .. nodeCount .. " | " .. key .. " | Fuel: " .. fuel)
            report("progress", {
                state = "scanning",
                path  = pathType,
                node  = nodeCount,
                pos   = pos,
            })
        end

        -- Fuel check
        local fuel = turtle.getFuelLevel()
        if fuel ~= "unlimited" and fuel < 50 then
            log("WARN: Fuel critico (" .. fuel .. ") — deteniendo scan")
            break
        end

        -- ========================================
        --  Decidir siguiente movimiento
        -- ========================================

        -- Verificar si el bloque de abajo es el camino correcto
        local onPath = (floorType == pathBlock) or
                       (pathBlock == "cobble" and floorType == "cobble_stairs")

        if not onPath then
            stepsWithoutPath = stepsWithoutPath + 1
            if stepsWithoutPath > maxLost then
                log("Perdi el camino hace " .. stepsWithoutPath .. " pasos — fin")
                break
            end
        else
            stepsWithoutPath = 0
        end

        -- Buscar siguiente bloque de camino
        local moved = false

        -- Prioridad 1: Adelante (si no hay bloque bloqueando)
        if not surr.front.ok then
            -- Camino libre adelante, intentar
            if safeForward() then
                local checkOk, checkData = turtle.inspectDown()
                local checkType = checkOk and classifyBlock({ ok = checkOk, data = checkData }) or "air"
                if checkType == pathBlock or (pathBlock == "cobble" and checkType == "cobble_stairs") then
                    moved = true
                else
                    -- No es camino, retroceder
                    turtle.back()
                end
            end
        elseif classifyBlock(surr.front) == pathBlock or
               (pathBlock == "cobble" and classifyBlock(surr.front) == "cobble_stairs") then
            -- Bloque de camino enfrente = subida
            if safeUp() then
                if safeForward() then
                    moved = true
                else
                    safeDown()
                end
            end
        end

        -- Prioridad 2: Izquierda
        if not moved then
            turnLeft()
            if not turtle.detect() then
                if safeForward() then
                    local checkOk, checkData = turtle.inspectDown()
                    local checkType = checkOk and classifyBlock({ ok = checkOk, data = checkData }) or "air"
                    if checkType == pathBlock or (pathBlock == "cobble" and checkType == "cobble_stairs") then
                        moved = true
                    else
                        turtle.back()
                    end
                end
            elseif classifyBlock({ ok = turtle.inspect() }) == pathBlock then
                if safeUp() then
                    if safeForward() then
                        moved = true
                    else
                        safeDown()
                    end
                end
            end
            if not moved then
                turnRight()  -- Deshacer
            end
        end

        -- Prioridad 3: Derecha
        if not moved then
            turnRight()
            if not turtle.detect() then
                if safeForward() then
                    local checkOk, checkData = turtle.inspectDown()
                    local checkType = checkOk and classifyBlock({ ok = checkOk, data = checkData }) or "air"
                    if checkType == pathBlock or (pathBlock == "cobble" and checkType == "cobble_stairs") then
                        moved = true
                    else
                        turtle.back()
                    end
                end
            elseif classifyBlock({ ok = turtle.inspect() }) == pathBlock then
                if safeUp() then
                    if safeForward() then
                        moved = true
                    else
                        safeDown()
                    end
                end
            end
            if not moved then
                turnLeft()  -- Deshacer
            end
        end

        -- Prioridad 4: Bajar (rampa descendente)
        if not moved then
            if not surr.front.ok then
                if safeForward() then
                    if safeDown() then
                        local checkOk, checkData = turtle.inspectDown()
                        local checkType = checkOk and classifyBlock({ ok = checkOk, data = checkData }) or "air"
                        if checkType == pathBlock or (pathBlock == "cobble" and checkType == "cobble_stairs") then
                            moved = true
                        else
                            safeUp()
                            turtle.back()
                        end
                    else
                        turtle.back()
                    end
                end
            end
        end

        -- Prioridad 5: Bajar + izquierda/derecha
        if not moved then
            for _, turnDir in ipairs({"left", "right"}) do
                if turnDir == "left" then turnLeft() else turnRight() end
                if not turtle.detect() then
                    if safeForward() then
                        if safeDown() then
                            local checkOk, checkData = turtle.inspectDown()
                            local checkType = checkOk and classifyBlock({ ok = checkOk, data = checkData }) or "air"
                            if checkType == pathBlock or (pathBlock == "cobble" and checkType == "cobble_stairs") then
                                moved = true
                                break
                            else
                                safeUp()
                                turtle.back()
                            end
                        else
                            turtle.back()
                        end
                    end
                end
                if not moved then
                    if turnDir == "left" then turnRight() else turnLeft() end
                end
            end
        end

        if not moved then
            log("No encuentro siguiente bloque de " .. pathType .. " — fin de camino")
            break
        end

        sleep(0.05)
    end

    return { nodes = nodes, graph = graph, total = nodeCount }
end

-- ============================================================
--  Guardar / cargar mapa
-- ============================================================

local function saveMap()
    if not fs.exists("map") then fs.makeDir("map") end
    mapData.created = os.day() .. ":" .. textutils.formatTime(os.time(), true)

    local file = fs.open(MAP_FILE, "w")
    file.write(textutils.serialise(mapData))
    file.close()
    log("Mapa guardado en: " .. MAP_FILE)
end

local function loadMap()
    if not fs.exists(MAP_FILE) then return false end
    local file = fs.open(MAP_FILE, "r")
    local content = file.readAll()
    file.close()
    local data = textutils.unserialise(content)
    if data then
        mapData = data
        return true
    end
    return false
end

-- ============================================================
--  PROGRAMA PRINCIPAL
-- ============================================================

local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("========================================")
    print("  INFRASTRUCTURE MAPPER v3.0")
    print("  ID: " .. os.getComputerID())
    print("========================================")
    print("")

    -- Modem
    if findModem() then
        log("Modem: " .. modemSide)
    else
        log("WARN: Sin modem, sin reportes wireless")
    end

    -- GPS
    local pos = getGPS()
    if not pos then
        log("ERROR: GPS no disponible. Necesito GPS para mapear.")
        return
    end
    log("GPS: " .. pos.x .. ", " .. pos.y .. ", " .. pos.z)

    -- Fuel
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" then
        log("Fuel: " .. fuel)
        if fuel < 200 then
            log("WARN: Recomiendo al menos 200 de fuel para mapear")
        end
    end

    -- Detectar facing
    log("Detectando orientacion...")
    facing = detectFacing()
    if facing == nil then
        log("ERROR: No pude detectar orientacion. Asegurate de tener espacio para moverme.")
        return
    end
    local facingNames = {"Norte(-Z)", "Este(+X)", "Sur(+Z)", "Oeste(-X)"}
    log("Orientacion: " .. facingNames[facing + 1])

    print("")
    report("status", { state = "mapper_ready", pos = pos, facing = facing })

    -- Menu
    write("Opciones:\n")
    write("  1. Escanear camino de STONE (principal)\n")
    write("  2. Escanear camino de COBBLESTONE (recoleccion)\n")
    write("  3. Escanear TODO (stone + todas las entradas cobble)\n")
    write("  4. Ver mapa guardado\n")
    write("  5. Salir\n")
    write("\nOpcion: ")
    local choice = read()

    if choice == "1" then
        -- Scan stone
        log("Iniciando scan de stone...")
        log("Coloca la turtle sobre el camino de stone.")
        write("Enter cuando este lista: ")
        read()

        facing = detectFacing()
        log("Facing: " .. facingNames[facing + 1])

        local result = scanPath("stone", "main")
        if result then
            mapData.stone = result
            saveMap()
            log("")
            log("=== SCAN STONE COMPLETO ===")
            log("  Nodos: " .. result.total)
            log("  Estaciones: " .. #mapData.stations)
            log("  Intersecciones: " .. #mapData.intersections)
            report("status", { state = "scan_complete", path = "stone", nodes = result.total })
        end

    elseif choice == "2" then
        -- Scan cobblestone
        log("Iniciando scan de cobblestone...")
        log("Coloca la turtle sobre el camino de cobblestone.")
        write("Enter cuando este lista: ")
        read()

        facing = detectFacing()
        log("Facing: " .. facingNames[facing + 1])

        local routeId = "cobble_1"
        local result = scanPath("cobble", routeId)
        if result then
            mapData.cobble[routeId] = result
            saveMap()
            log("")
            log("=== SCAN COBBLESTONE COMPLETO ===")
            log("  Nodos: " .. result.total)
            log("  Inventarios: " .. #mapData.inventories)
            report("status", { state = "scan_complete", path = "cobble", nodes = result.total })
        end

    elseif choice == "3" then
        -- Scan completo
        log("=== SCAN COMPLETO DE INFRAESTRUCTURA ===")
        log("Primero escaneare el camino de STONE...")
        write("Turtle sobre stone, enter para iniciar: ")
        read()

        facing = detectFacing()
        log("Facing: " .. facingNames[facing + 1])

        -- Fase 1: Stone
        local stoneResult = scanPath("stone", "main")
        if stoneResult then
            mapData.stone = stoneResult
            log("")
            log("Stone: " .. stoneResult.total .. " nodos")
            log("Intersecciones encontradas: " .. #mapData.intersections)
        end

        -- Fase 2: Cobblestone (navegar a cada interseccion detectada)
        if #mapData.intersections > 0 then
            log("")
            log("Encontre " .. #mapData.intersections .. " entrada(s) a cobblestone")

            for i, inter in ipairs(mapData.intersections) do
                if inter.toPath == "cobble" then
                    log("")
                    log("--- Entrada cobble #" .. i .. " en " .. posKey(inter.x, inter.y, inter.z) .. " ---")
                    log("Necesito que me lleves a esa entrada.")
                    log("Coords: " .. inter.toX .. ", " .. inter.toY .. ", " .. inter.toZ)
                    write("Enter cuando este en la entrada: ")
                    read()

                    -- Resetear visited para el nuevo camino
                    -- (no resetear las posiciones de stone)
                    facing = detectFacing()
                    log("Facing: " .. facingNames[facing + 1])

                    local routeId = "cobble_" .. i
                    local cobbleResult = scanPath("cobble", routeId)
                    if cobbleResult then
                        mapData.cobble[routeId] = cobbleResult
                        cobbleResult.entryIntersection = i
                        log("Cobble ruta " .. routeId .. ": " .. cobbleResult.total .. " nodos")
                    end
                end
            end
        else
            log("No se encontraron entradas a cobblestone desde stone")
        end

        -- Guardar todo
        saveMap()

        log("")
        log("========================================")
        log("  MAPEO COMPLETO")
        log("  Stone: " .. (mapData.stone.total or 0) .. " nodos")
        local cobbleTotal = 0
        for _, route in pairs(mapData.cobble) do
            cobbleTotal = cobbleTotal + (route.total or 0)
        end
        log("  Cobble: " .. cobbleTotal .. " nodos")
        log("  Estaciones: " .. #mapData.stations)
        log("  Inventarios: " .. #mapData.inventories)
        log("  Intersecciones: " .. #mapData.intersections)
        log("  Archivo: " .. MAP_FILE)
        log("========================================")

        report("status", {
            state = "map_complete",
            stone_nodes = mapData.stone.total or 0,
            cobble_nodes = cobbleTotal,
            stations = #mapData.stations,
            inventories = #mapData.inventories,
            intersections = #mapData.intersections,
        })

    elseif choice == "4" then
        -- Ver mapa
        if loadMap() then
            log("Mapa cargado:")
            log("  Stone: " .. (mapData.stone.total or 0) .. " nodos")
            log("  Estaciones: " .. #mapData.stations)
            log("  Inventarios: " .. #mapData.inventories)
            log("  Intersecciones: " .. #mapData.intersections)

            if #mapData.stations > 0 then
                print("")
                print("Estaciones:")
                for _, s in ipairs(mapData.stations) do
                    print(string.format("  #%d: %d,%d,%d cofre:%s",
                        s.id, s.x, s.y, s.z, s.chestDir))
                end
            end

            if #mapData.intersections > 0 then
                print("")
                print("Intersecciones:")
                for _, inter in ipairs(mapData.intersections) do
                    print(string.format("  #%d: %d,%d,%d → %s dir:%s",
                        inter.id, inter.x, inter.y, inter.z, inter.toPath, inter.dir))
                end
            end

            if #mapData.inventories > 0 then
                print("")
                print("Inventarios:")
                for _, inv in ipairs(mapData.inventories) do
                    print(string.format("  #%d: %d,%d,%d drawer:%s",
                        inv.id, inv.x, inv.y, inv.z, inv.drawerDir))
                end
            end
        else
            log("No hay mapa guardado. Ejecuta un scan primero.")
        end

    elseif choice == "5" then
        log("Saliendo...")
        return
    end

    print("")
    write("Enter para salir...")
    read()
end

-- ============================================================
local ok, err = pcall(main)
if not ok then
    print("Error: " .. tostring(err))
    report("error", { msg = tostring(err) })
end
