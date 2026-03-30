-- ============================================================
--  transfer_worker.lua
--  Worker: vaciado continuo de inventario (loop dedicado)
-- ============================================================

local lib = require("transfer_lib")
local worker = {}

-- ============================================================
--  Ejecutar un ciclo de vaciado
-- ============================================================

local function runCycle()
    local st = lib.state
    if not st.workerFrom or not st.workerTo then return end

    local fromP = peripheral.wrap(st.workerFrom.name)
    if not fromP or not fromP.list then return end

    local ok, raw = pcall(fromP.list)
    if not ok or not raw then return end

    local cycleMoved = 0
    local itemMap = {}
    local destFull = false

    for slot, item in pairs(raw) do
        local okM, result = pcall(fromP.pushItems, st.workerTo.name, slot, item.count)
        local moved = (okM and result) and result or 0

        if moved > 0 then
            cycleMoved = cycleMoved + moved
            if not itemMap[item.name] then
                itemMap[item.name] = { name = item.name, moved = 0 }
            end
            itemMap[item.name].moved = itemMap[item.name].moved + moved
        end

        if moved == 0 and item.count > 0 then
            destFull = true
        end
    end

    -- Convertir a lista
    local itemList = {}
    for _, data in pairs(itemMap) do
        table.insert(itemList, data)
    end
    table.sort(itemList, function(a, b) return a.moved > b.moved end)

    -- Actualizar stats
    local ws = st.workerStats
    ws.cycles = ws.cycles + 1
    ws.totalMoved = ws.totalMoved + cycleMoved
    ws.lastItems = itemList
    ws.destFull = destFull

    if cycleMoved > 0 then
        lib.tLog("[WORKER] Ciclo #" .. ws.cycles .. ": " .. cycleMoved .. " items")
        lib.addHistory(st.workerFrom.name, st.workerTo.name, "*", cycleMoved, cycleMoved)
    end
end

-- ============================================================
--  Loop principal del worker (corre en parallel)
-- ============================================================

function worker.loop()
    local lastRun = 0
    while lib.state.screen ~= "exit" do
        sleep(1)
        if lib.state.workerActive and lib.state.workerFrom and lib.state.workerTo then
            local now = os.clock()
            if now - lastRun >= lib.state.workerInterval then
                lastRun = now
                runCycle()

                -- Refrescar monitor si estamos en la pantalla worker
                if lib.state.screen == "worker_running" then
                    -- El render se hara desde el monitorLoop via un flag
                    os.queueEvent("worker_update")
                end
                lib.drawTerminal()
            end
        end
    end
end

-- ============================================================
--  Utilidades para el UI
-- ============================================================

function worker.start(fromInv, toInv, interval)
    lib.state.workerFrom = fromInv
    lib.state.workerTo = toInv
    lib.state.workerInterval = interval
    lib.state.workerActive = true
    lib.state.workerStats = {
        cycles = 0,
        totalMoved = 0,
        startTime = os.clock(),
        lastItems = {},
        destFull = false,
    }
    lib.tLog("[WORKER] Iniciado: " .. fromInv.name .. " -> " .. toInv.name)
    lib.tLog("[WORKER] Intervalo: " .. interval .. "s")
end

function worker.stop()
    local ws = lib.state.workerStats
    lib.state.workerActive = false
    lib.tLog("[WORKER] Detenido. Total: " .. ws.totalMoved .. " items en " .. ws.cycles .. " ciclos")
end

function worker.pause()
    lib.state.workerActive = false
    lib.tLog("[WORKER] Pausado")
end

function worker.resume()
    lib.state.workerActive = true
    lib.tLog("[WORKER] Reanudado")
end

function worker.restart()
    lib.state.workerStats = {
        cycles = 0,
        totalMoved = 0,
        startTime = os.clock(),
        lastItems = {},
        destFull = false,
    }
    lib.state.workerActive = true
    lib.tLog("[WORKER] Reiniciado")
end

function worker.isActive()
    return lib.state.workerActive
end

return worker
