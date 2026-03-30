-- ============================================================
--  transfer.lua  v5.1
--  Main: carga modulos, inicia 5 monitores, loops en paralelo
--
--  Monitores:
--    14 (3x3) CONTROL    = Transferir, Vaciar, Worker
--    10 (3x3) AUTOMATIZAR = Tareas, Reglas
--    13 (3x3) INVENTARIO  = Explorar, Buscar, Historial
--    12 (2x7) DASHBOARD   = Status en vivo (techo)
--    11 (2x7) ACTIVIDAD   = Feed de eventos (techo)
-- ============================================================

local lib    = require("transfer_lib")
local tasks  = require("transfer_tasks")
local worker = require("transfer_worker")
local ui     = require("transfer_ui")

local st = lib.state

-- ============================================================
--  Loops
-- ============================================================

-- Touch events (interactive monitors)
local function touchLoop()
    while st.running do
        local _, side, x, y = os.pullEvent("monitor_touch")
        ui.handleTouch(side, x, y)
    end
end

-- Dashboard + Activity auto-refresh
local function refreshLoop()
    while st.running do
        ui.markDirty("dashboard")
        ui.markDirty("activity")
        ui.renderMonitor("dashboard")
        ui.renderMonitor("activity")
        sleep(3)
    end
end

-- Auto rules
local function rulesLoop()
    while st.running do
        sleep(1)
        if st.rulesRunning then
            local now = os.clock()
            for _, rule in ipairs(st.rules) do
                if rule.enabled then
                    local lr = rule.lastRun or 0
                    if now - lr >= rule.interval then
                        rule.lastRun = now
                        local moved = lib.executeRule(rule)
                        if moved > 0 then
                            local si = rule.item == "*" and "todo" or (rule.item:match(":(.+)") or rule.item)
                            lib.tLog("[AUTO] " .. moved .. "x " .. si)
                            lib.addHistory(rule.from, rule.to, rule.item, rule.cantidad, moved)
                        end
                    end
                end
            end
        end
    end
end

-- Terminal display
local function terminalLoop()
    while st.running do
        lib.drawTerminal()
        sleep(5)
    end
end

-- Worker update handler
local function workerEventLoop()
    while st.running do
        os.pullEvent("worker_update")
        -- Refresh control monitor if showing worker screen
        local ctrl = ui.monitors.control
        if ctrl and ctrl.nav.screen:find("^wk_") then
            ui.markDirty("control")
            ui.renderMonitor("control")
        end
        -- Dashboards get refreshed in refreshLoop
    end
end

-- Log update handler (refresh activity on new log entries)
local function logEventLoop()
    while st.running do
        os.pullEvent("log_update")
        -- Activity monitor will catch up on next refreshLoop cycle
        -- But for faster feedback, render immediately
        ui.markDirty("activity")
        ui.renderMonitor("activity")
    end
end

-- ============================================================
--  Main
-- ============================================================

local function main()
    term.clear()
    term.setCursorPos(1, 1)
    st.startTime = os.clock()

    -- Init
    lib.loadRules()
    lib.loadHistory()
    tasks.load()
    lib.refreshInventories()

    lib.tLog("Transfer v5.1 Multi-Monitor")
    lib.tLog("Inventarios: " .. #st.inventories)
    lib.tLog("Reglas: " .. #st.rules)
    lib.tLog("Tareas: " .. tasks.count())

    -- Init monitors
    ui.init()

    -- Render inicial
    ui.renderAll()
    lib.drawTerminal()

    lib.tLog("Sistema listo. Monitores activos.")

    -- Loops en paralelo
    parallel.waitForAny(
        touchLoop,
        refreshLoop,
        rulesLoop,
        tasks.loop,
        worker.loop,
        terminalLoop,
        workerEventLoop,
        logEventLoop
    )

    -- Cleanup
    for _, m in pairs(ui.monitors) do
        m:clear(colors.black)
        m:write(2, 2, "Transfer cerrado", colors.gray, colors.black)
    end
    term.clear()
    term.setCursorPos(1, 1)
    print("Transfer cerrado.")
end

local ok, err = pcall(main)
if not ok then
    print("Error: " .. tostring(err))
    for _, m in pairs(ui.monitors or {}) do
        pcall(function()
            m:clear(colors.black)
            m:write(2, 2, "ERROR:", colors.red, colors.black)
            m:write(2, 3, tostring(err):sub(1, 40), colors.white, colors.black)
        end)
    end
end
