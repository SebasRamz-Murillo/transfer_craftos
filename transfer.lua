-- ============================================================
--  transfer.lua  v5.0
--  Main: carga modulos, inicia loops en paralelo.
--
--  Archivos:
--    transfer_lib.lua    = utilidades, inventarios, dibujo
--    transfer_tasks.lua  = CRUD de tareas + orquestador
--    transfer_worker.lua = worker de vaciado continuo
--    transfer_ui.lua     = todas las pantallas del monitor
--    transfer.lua        = este archivo (main)
-- ============================================================

local lib    = require("transfer_lib")
local tasks  = require("transfer_tasks")
local worker = require("transfer_worker")
local ui     = require("transfer_ui")

-- Shortcuts
local st = lib.state

-- ============================================================
--  Loops
-- ============================================================

-- Loop del monitor (eventos tactiles)
local function monitorLoop()
    while st.screen ~= "exit" do
        local event, side, x, y = os.pullEvent()
        if event == "monitor_touch" and side == lib.MONITOR_SIDE then
            ui.handleTouch(x, y)
            ui.render()
            lib.drawTerminal()
        elseif event == "peripheral" or event == "peripheral_detach" then
            lib.refreshInventories()
            ui.render()
        elseif event == "worker_update" then
            -- Evento lanzado por el workerLoop para refrescar UI
            if st.screen == "worker_running" then
                ui.render()
            end
        end
    end
end

-- Loop de reglas automaticas
local function rulesLoop()
    while st.screen ~= "exit" do
        sleep(1)
        if st.rulesRunning then
            local now = os.clock()
            for _, rule in ipairs(st.rules) do
                if rule.enabled then
                    local lastRun = rule.lastRun or 0
                    if now - lastRun >= rule.interval then
                        rule.lastRun = now
                        local moved = lib.executeRule(rule)
                        if moved > 0 then
                            local shortItem = rule.item == "*" and "todo" or (rule.item:match(":(.+)") or rule.item)
                            lib.tLog("[AUTO] " .. moved .. "x " .. shortItem)
                            lib.addHistory(rule.from, rule.to, rule.item, rule.cantidad, moved)
                            lib.drawTerminal()
                        end
                    end
                end
            end
        end
    end
end

-- Loop de refresco del terminal
local function terminalLoop()
    while st.screen ~= "exit" do
        lib.drawTerminal()
        sleep(5)
    end
end

-- ============================================================
--  Main
-- ============================================================

local function main()
    term.clear()
    term.setCursorPos(1, 1)

    -- Init monitor
    if not lib.init() then return end

    -- Cargar datos persistentes
    lib.loadRules()
    lib.loadHistory()
    tasks.load()

    lib.tLog("Transfer v5.0 iniciado")
    lib.tLog("Monitor: " .. lib.MONITOR_SIDE .. " (" .. lib.W .. "x" .. lib.H .. ")")

    lib.refreshInventories()
    lib.tLog("Inventarios: " .. #st.inventories)
    lib.tLog("Reglas: " .. #st.rules)
    lib.tLog("Tareas: " .. tasks.count())

    -- Render inicial
    ui.render()
    lib.drawTerminal()

    -- Loops en paralelo
    parallel.waitForAny(
        monitorLoop,
        rulesLoop,
        tasks.loop,
        worker.loop,
        terminalLoop
    )

    -- Cleanup
    lib.mClear(colors.black)
    lib.mWrite(2, 2, "Transfer cerrado", colors.gray, colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    print("Transfer cerrado.")
end

local ok, err = pcall(main)
if not ok then
    print("Error: " .. tostring(err))
    if lib.mon then
        lib.mClear(colors.black)
        lib.mWrite(2, 2, "ERROR:", colors.red, colors.black)
        lib.mWrite(2, 3, tostring(err):sub(1, (lib.W > 0 and lib.W - 2 or 50)), colors.white, colors.black)
    end
end
