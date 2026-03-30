-- install.lua
-- Descarga todos los archivos de transfer desde GitHub

local repo = "https://raw.githubusercontent.com/SebasRamz-Murillo/transfer_craftos/main/"

local files = {
    "transfer_lib.lua",
    "transfer_tasks.lua",
    "transfer_worker.lua",
    "transfer_ui.lua",
    "transfer.lua",
}

print("=== Instalando Transfer v5.0 ===")
print()

for _, name in ipairs(files) do
    local url = repo .. name
    write("Descargando " .. name .. "... ")

    if fs.exists(name) then
        fs.delete(name)
    end

    local ok, err = pcall(function()
        shell.run("wget", url, name)
    end)

    if ok and fs.exists(name) then
        print("OK")
    else
        print("ERROR")
        print("  " .. tostring(err))
    end
end

print()
print("Listo! Ejecuta: transfer")
