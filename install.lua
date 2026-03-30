-- install.lua  v5.1
-- Descarga todos los archivos de transfer desde GitHub
-- Uso: wget run https://raw.githubusercontent.com/SebasRamz-Murillo/transfer_craftos/main/install.lua

local repo = "https://raw.githubusercontent.com/SebasRamz-Murillo/transfer_craftos/main/"

local files = {
    "transfer_lib.lua",
    "transfer_tasks.lua",
    "transfer_worker.lua",
    "transfer_ui.lua",
    "transfer.lua",
}

print("=== Instalando Transfer v5.1 Multi-Monitor ===")
print()
print("Monitores: 14(CONTROL) 10(TAREAS) 13(INVENTARIO)")
print("           12(DASHBOARD) 11(ACTIVIDAD)")
print()

local ok_count = 0
for _, name in ipairs(files) do
    write("  " .. name .. " ... ")
    if fs.exists(name) then fs.delete(name) end
    local ok = pcall(function() shell.run("wget", repo .. name, name) end)
    if ok and fs.exists(name) then
        print("OK")
        ok_count = ok_count + 1
    else
        print("FALLO")
    end
end

print()
if ok_count == #files then
    print("Listo! " .. ok_count .. "/" .. #files .. " archivos instalados.")
    print("Ejecuta: transfer")
else
    print("ADVERTENCIA: " .. ok_count .. "/" .. #files .. " archivos.")
    print("Verifica tu conexion HTTP.")
end
