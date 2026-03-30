-- ============================================================
--  install.lua  v5.1
--  Descarga todos los archivos de Transfer v5.1
--  Uso: wget run https://raw.githubusercontent.com/SebasRamz-Murillo/transfer_craftos/main/install.lua
-- ============================================================

local REPO = "https://raw.githubusercontent.com/SebasRamz-Murillo/transfer_craftos/main/"

local files = {
    "transfer.lua",
    "transfer_lib.lua",
    "transfer_tasks.lua",
    "transfer_worker.lua",
    "transfer_ui.lua",
}

print("=== Transfer v5.1 Installer ===")
print("")

for _, file in ipairs(files) do
    local url = REPO .. file
    print("Descargando: " .. file)
    if fs.exists(file) then fs.delete(file) end
    local ok, err = pcall(shell.run, "wget", url, file)
    if not ok then
        print("  ERROR: " .. tostring(err))
    else
        print("  OK")
    end
end

print("")
print("=== Instalacion completa ===")
print("")
print("Monitores requeridos (wired modem):")
print("  monitor_14 (3x3) = CONTROL")
print("  monitor_10 (3x3) = AUTOMATIZAR")
print("  monitor_13 (3x3) = INVENTARIO")
print("  monitor_12 (2x7) = DASHBOARD (techo)")
print("  monitor_11 (2x7) = ACTIVIDAD (techo)")
print("")
print("Ejecuta: transfer")
