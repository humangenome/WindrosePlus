-- WindrosePlus Mods Loader
-- Loads the Lua mods listed in WindrosePlus/Mods/mods_registry.json, a JSON array of
-- folder names (["my-mod"]); each folder needs a mod.json. Lua here cannot list a
-- folder without opening a command window, so the list is explicit; install.ps1
-- writes it for the mod folders it finds. Hot-reload via UE4SS RestartMod when a
-- listed mod's files or the list change.

local json = require("modules.json")
local Log = require("modules.log")

local Mods = {}

-- FNV-1a over the whole file, so any edit counts as a change (up to v1.3.24 only
-- the length and the first and last byte were compared).
local function contentSignature(content)
    local h = 2166136261
    for i = 1, #content do
        h = ((h ~ content:byte(i)) * 16777619) & 0xffffffff
    end
    return #content .. ":" .. h
end

Mods._modsDir = nil
Mods._loaded = {}
Mods._fileSnapshots = {} -- filename -> mtime string for change detection

function Mods.init(gameDir)
    -- Mods live alongside Scripts in the WindrosePlus mod folder
    -- UE4SS CWD is R5/Binaries/Win64, build path relative to known structure
    -- __SCRIPT_DIRECTORY__ or similar UE4SS globals may not exist, so use relative path
    local modsDir = ".\\ue4ss\\Mods\\WindrosePlus\\Mods"

    -- Verify the directory exists by trying to open a test file in it
    local testFile = modsDir .. "\\.wp_dirtest"
    local f = io.open(testFile, "w")
    if f then
        f:close()
        os.remove(testFile)
        Mods._modsDir = modsDir
    else
        -- Try alternate known paths
        local alts = {
            "Mods\\WindrosePlus\\Mods",
            "..\\Mods\\WindrosePlus\\Mods",
        }
        for _, alt in ipairs(alts) do
            local tf = io.open(alt .. "\\.wp_dirtest", "w")
            if tf then
                tf:close()
                os.remove(alt .. "\\.wp_dirtest")
                Mods._modsDir = alt
                break
            end
        end
    end

    if not Mods._modsDir then
        Log.warn("Mods", "Could not determine Mods directory")
        return
    end

    -- Scan and load mods
    Mods._scanAndLoad()

    -- Take initial file snapshot for change detection
    Mods._takeSnapshot()
end

function Mods._scanAndLoad()
    if not Mods._modsDir then return end

    -- Discover mod subdirectories without io.popen (avoids CMD window flash)
    -- Read the mod registry file that lists installed mod directory names
    local dirs = {}
    local registryPath = Mods._modsDir .. "\\mods_registry.json"
    local regFile = io.open(registryPath, "r")
    if regFile then
        local content = regFile:read("*a")
        regFile:close()
        local ok, data = pcall(json.decode, content)
        if ok and type(data) == "table" then
            for _, name in ipairs(data) do
                -- Verify the mod.json actually exists before loading
                local f = io.open(Mods._modsDir .. "\\" .. name .. "\\mod.json", "r")
                if f then
                    f:close()
                    table.insert(dirs, name)
                end
            end
        end
    end

    table.sort(dirs)

    for _, dirname in ipairs(dirs) do
        Mods._loadMod(dirname)
    end
end

function Mods._loadMod(dirname)
    local modDir = Mods._modsDir .. "\\" .. dirname
    local manifestPath = modDir .. "\\mod.json"

    -- Read manifest
    local file = io.open(manifestPath, "r")
    if not file then
        Log.debug("Mods", "Skipping " .. dirname .. " (no mod.json)")
        return
    end
    local content = file:read("*a")
    file:close()

    local ok, manifest = pcall(json.decode, content)
    if not ok or type(manifest) ~= "table" then
        Log.warn("Mods", "Invalid mod.json in " .. dirname)
        return
    end

    local mainFile = manifest.main or "init.lua"
    local mainPath = modDir .. "\\" .. mainFile

    -- Check main file exists
    local f = io.open(mainPath, "r")
    if not f then
        Log.warn("Mods", dirname .. ": main file not found: " .. mainFile)
        return
    end
    f:close()

    -- Load with error isolation
    local loadOk, loadErr = pcall(dofile, mainPath)
    if loadOk then
        table.insert(Mods._loaded, {
            name = manifest.name or dirname,
            version = manifest.version or "?",
            author = manifest.author or "?",
            dir = dirname
        })
        Log.info("Mods", "Loaded: " .. (manifest.name or dirname) .. " v" .. (manifest.version or "?"))
    else
        Log.error("Mods", dirname .. " failed to load: " .. tostring(loadErr))
    end
end

function Mods._takeSnapshot()
    if not Mods._modsDir then return end
    Mods._fileSnapshots = {}

    -- Snapshot mod files by reading content hashes (pure Lua, no forfiles/CMD)
    -- For each loaded mod, check known files: mod.json + main file
    for _, mod in ipairs(Mods._loaded) do
        local modDir = Mods._modsDir .. "\\" .. mod.dir
        local filesToCheck = {
            modDir .. "\\mod.json",
            modDir .. "\\init.lua",
            modDir .. "\\main.lua",
        }
        -- The manifest may name another main file.
        local mf = io.open(modDir .. "\\mod.json", "r")
        if mf then
            local ok, manifest = pcall(json.decode, mf:read("*a") or "")
            mf:close()
            if ok and type(manifest) == "table" and type(manifest.main) == "string"
                and manifest.main ~= "init.lua" and manifest.main ~= "main.lua" then
                table.insert(filesToCheck, modDir .. "\\" .. manifest.main)
            end
        end
        for _, path in ipairs(filesToCheck) do
            local f = io.open(path, "rb")
            if f then
                local content = f:read("*a")
                f:close()
                if content then
                    Mods._fileSnapshots[path] = contentSignature(content)
                end
            end
        end
    end

    -- Also check the registry file itself
    local regPath = Mods._modsDir .. "\\mods_registry.json"
    local rf = io.open(regPath, "rb")
    if rf then
        local content = rf:read("*a")
        rf:close()
        if content then
            Mods._fileSnapshots[regPath] = contentSignature(content)
        end
    end
end

function Mods.checkForChanges()
    if not Mods._modsDir then return false end

    local oldSnapshots = Mods._fileSnapshots
    Mods._takeSnapshot()

    -- Compare snapshots
    for path, timestamp in pairs(Mods._fileSnapshots) do
        if oldSnapshots[path] ~= timestamp then
            Log.info("Mods", "Changed: " .. path)
            return true
        end
    end

    -- Check for new files
    for path in pairs(Mods._fileSnapshots) do
        if not oldSnapshots[path] then
            Log.info("Mods", "New file: " .. path)
            return true
        end
    end

    -- Check for deleted files
    for path in pairs(oldSnapshots) do
        if not Mods._fileSnapshots[path] then
            Log.info("Mods", "Deleted: " .. path)
            return true
        end
    end

    return false
end

function Mods.getLoadedCount()
    return #Mods._loaded
end

function Mods.getLoadedMods()
    return Mods._loaded
end

return Mods
