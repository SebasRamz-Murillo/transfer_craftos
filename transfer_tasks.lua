-- ============================================================
--  transfer_tasks.lua  v5.1
--  CRUD de tareas + orquestador
-- ============================================================

local lib = require("transfer_lib")
local tasks = {}

function tasks.save()
    local data = {}
    for _, t in ipairs(lib.state.tasks) do
        table.insert(data, {
            name = t.name, type = t.type, from = t.from, to = t.to,
            item = t.item, cantidad = t.cantidad, interval = t.interval,
            loop = t.loop, enabled = t.enabled, priority = t.priority,
        })
    end
    lib.safeWrite(lib.TASKS_FILE, data)
end

function tasks.load()
    if fs.exists(lib.TASKS_FILE) then
        local f = fs.open(lib.TASKS_FILE, "r")
        local d = textutils.unserialise(f.readAll())
        f.close()
        if d then
            for _, t in ipairs(d) do
                t.lastRun = 0
                t.status = "idle"
                t.lastResult = nil
            end
            lib.state.tasks = d
        end
    end
end

function tasks.create(opts)
    local t = {
        name     = opts.name or ("Tarea #" .. (#lib.state.tasks + 1)),
        type     = opts.type or "transfer",
        from     = opts.from,
        to       = opts.to,
        item     = opts.item or "*",
        cantidad = opts.cantidad or 0,
        interval = opts.interval or 10,
        loop     = opts.loop ~= false,
        enabled  = true,
        priority = opts.priority or (#lib.state.tasks + 1),
        lastRun  = 0, status = "idle", lastResult = nil,
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
        if k ~= "lastRun" and k ~= "status" and k ~= "lastResult" then t[k] = v end
    end
    tasks.sortByPriority()
    tasks.save()
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
    table.sort(lib.state.tasks, function(a, b) return (a.priority or 99) < (b.priority or 99) end)
end

function tasks.count()    return #lib.state.tasks end
function tasks.countEnabled()
    local n = 0
    for _, t in ipairs(lib.state.tasks) do if t.enabled then n = n + 1 end end
    return n
end

-- Collect: search all inventories (except dest) for an item and move to dest
function tasks.executeCollect(t)
    t.status = "running"
    local moved = 0
    local qty = t.cantidad == 0 and lib.MAX_QUANTITY or t.cantidad
    for _, inv in ipairs(lib.state.inventories) do
        if inv.name ~= t.to then
            local m = lib.moveItems(inv.peripheral, t.to, t.item, qty - moved)
            moved = moved + m
            if moved >= qty then break end
        end
    end
    return moved
end

function tasks.execute(t)
    -- Collect type searches all inventories
    if t.type == "collect" then
        local moved = tasks.executeCollect(t)
        t.lastRun = os.clock()
        t.lastResult = { moved = moved }
        if moved > 0 then
            t.status = "done"
            local si = t.item:match(":(.+)") or t.item
            lib.tLog("[TASK] " .. t.name .. ": " .. moved .. "x " .. si .. " (collect)")
            lib.addHistory("*", t.to, t.item, t.cantidad, moved)
        else
            t.status = "idle"
        end
        if not t.loop and moved > 0 then
            t.enabled = false; tasks.save()
        end
        return moved
    end

    -- Normal transfer/drain
    local fromP = peripheral.wrap(t.from)
    if not fromP or not fromP.list then
        t.status = "error"
        t.lastResult = { moved = 0, err = "Origen no disponible" }
        lib.state.totalErrors = lib.state.totalErrors + 1
        return 0
    end
    t.status = "running"
    local moved = 0
    if t.type == "drain" or t.item == "*" then
        local ok, raw = pcall(fromP.list)
        if ok and raw then
            for slot, item in pairs(raw) do
                local okM, r = pcall(fromP.pushItems, t.to, slot, item.count)
                if okM and r then moved = moved + r end
            end
        end
    else
        local qty = t.cantidad == 0 and lib.MAX_QUANTITY or t.cantidad
        moved = lib.moveItems(fromP, t.to, t.item, qty)
    end
    t.lastRun = os.clock()
    t.lastResult = { moved = moved }
    if moved > 0 then
        t.status = "done"
        local si = t.item == "*" and "todo" or (t.item:match(":(.+)") or t.item)
        lib.tLog("[TASK] " .. t.name .. ": " .. moved .. "x " .. si)
        lib.addHistory(t.from, t.to, t.item, t.cantidad, moved)
    else
        t.status = "idle"
    end
    if not t.loop and moved > 0 then
        t.enabled = false
        tasks.save()
    end
    return moved
end

function tasks.loop()
    while lib.state.running do
        sleep(1)
        local now = os.clock()
        for _, t in ipairs(lib.state.tasks) do
            if t.enabled and t.status ~= "running" then
                local lr = t.lastRun or 0
                if now - lr >= t.interval then tasks.execute(t) end
            end
        end
    end
end

return tasks
