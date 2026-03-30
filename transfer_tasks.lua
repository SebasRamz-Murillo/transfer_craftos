-- ============================================================
--  transfer_tasks.lua
--  CRUD de tareas + orquestador de ejecucion.
--
--  Una "tarea" es una accion de inventario programable:
--    - Mover X items de A a B (una vez o en loop)
--    - Vaciar todo de A a B (una vez o en loop)
--    - Con intervalo configurable
--    - Con prioridad (orden de ejecucion)
--    - Habilitada/deshabilitada
--
--  Tipos de tarea:
--    "transfer"  -> mover item especifico, cantidad fija
--    "drain"     -> vaciar todo de origen a destino
-- ============================================================

local lib = require("transfer_lib")
local tasks = {}

-- ============================================================
--  Persistencia
-- ============================================================

function tasks.save()
    local data = {}
    for _, t in ipairs(lib.state.tasks) do
        table.insert(data, {
            name     = t.name,
            type     = t.type,
            from     = t.from,
            to       = t.to,
            item     = t.item,
            cantidad = t.cantidad,
            interval = t.interval,
            loop     = t.loop,
            enabled  = t.enabled,
            priority = t.priority,
        })
    end
    local file = fs.open(lib.TASKS_FILE, "w")
    file.write(textutils.serialise(data))
    file.close()
end

function tasks.load()
    if fs.exists(lib.TASKS_FILE) then
        local file = fs.open(lib.TASKS_FILE, "r")
        local data = textutils.unserialise(file.readAll())
        file.close()
        if data then
            for _, t in ipairs(data) do
                t.lastRun = 0
                t.status  = "idle"       -- idle | running | done | error
                t.lastResult = nil
            end
            lib.state.tasks = data
        end
    end
end

-- ============================================================
--  CRUD
-- ============================================================

function tasks.create(opts)
    local t = {
        name     = opts.name or ("Tarea #" .. (#lib.state.tasks + 1)),
        type     = opts.type or "transfer",   -- "transfer" | "drain"
        from     = opts.from,
        to       = opts.to,
        item     = opts.item or "*",           -- "*" = todo
        cantidad = opts.cantidad or 0,         -- 0 = todo lo disponible
        interval = opts.interval or 10,        -- segundos entre ejecuciones
        loop     = opts.loop ~= false,         -- true = repetir, false = una vez
        enabled  = true,
        priority = opts.priority or (#lib.state.tasks + 1),
        -- Runtime (no se guardan)
        lastRun    = 0,
        status     = "idle",
        lastResult = nil,
    }
    table.insert(lib.state.tasks, t)
    tasks.sortByPriority()
    tasks.save()
    lib.tLog("[TASK] Creada: " .. t.name)
    return t
end

function tasks.update(index, opts)
    local t = lib.state.tasks[index]
    if not t then return false end
    for k, v in pairs(opts) do
        if k ~= "lastRun" and k ~= "status" and k ~= "lastResult" then
            t[k] = v
        end
    end
    tasks.sortByPriority()
    tasks.save()
    lib.tLog("[TASK] Actualizada: " .. t.name)
    return true
end

function tasks.delete(index)
    local t = lib.state.tasks[index]
    if not t then return false end
    local name = t.name
    table.remove(lib.state.tasks, index)
    tasks.save()
    lib.tLog("[TASK] Eliminada: " .. name)
    return true
end

function tasks.toggle(index)
    local t = lib.state.tasks[index]
    if not t then return false end
    t.enabled = not t.enabled
    tasks.save()
    lib.tLog("[TASK] " .. t.name .. ": " .. (t.enabled and "ON" or "OFF"))
    return true
end

function tasks.sortByPriority()
    table.sort(lib.state.tasks, function(a, b) return a.priority < b.priority end)
end

function tasks.getByIndex(index)
    return lib.state.tasks[index]
end

function tasks.count()
    return #lib.state.tasks
end

function tasks.countEnabled()
    local n = 0
    for _, t in ipairs(lib.state.tasks) do
        if t.enabled then n = n + 1 end
    end
    return n
end

-- ============================================================
--  Ejecucion de una tarea individual
-- ============================================================

function tasks.execute(t)
    local fromP = peripheral.wrap(t.from)
    if not fromP or not fromP.list then
        t.status = "error"
        t.lastResult = { moved = 0, err = "Origen no disponible" }
        return 0
    end

    t.status = "running"
    local moved = 0

    if t.type == "drain" or t.item == "*" then
        -- Vaciar todo
        local ok, raw = pcall(fromP.list)
        if ok and raw then
            for slot, item in pairs(raw) do
                local okM, r = pcall(fromP.pushItems, t.to, slot, item.count)
                if okM and r then moved = moved + r end
            end
        end
    else
        -- Item especifico
        local qty = t.cantidad == 0 and 99999 or t.cantidad
        moved = lib.moveItems(fromP, t.to, t.item, qty)
    end

    t.lastRun = os.clock()
    t.lastResult = { moved = moved }

    if moved > 0 then
        t.status = "done"
        local shortItem = t.item == "*" and "todo" or (t.item:match(":(.+)") or t.item)
        lib.tLog("[TASK] " .. t.name .. ": " .. moved .. "x " .. shortItem)
        lib.addHistory(t.from, t.to, t.item, t.cantidad, moved)
    else
        t.status = "idle"
    end

    -- Si es una-sola-vez y ya corrio, deshabilitar
    if not t.loop and moved > 0 then
        t.enabled = false
        tasks.save()
        lib.tLog("[TASK] " .. t.name .. " completada (una vez)")
    end

    return moved
end

-- ============================================================
--  Loop del orquestador (corre en parallel)
-- ============================================================

function tasks.loop()
    while lib.state.screen ~= "exit" do
        sleep(1)
        local now = os.clock()
        for _, t in ipairs(lib.state.tasks) do
            if t.enabled and t.status ~= "running" then
                local lastRun = t.lastRun or 0
                if now - lastRun >= t.interval then
                    tasks.execute(t)
                end
            end
        end
    end
end

return tasks
