-- Windrose+ entry point
-- Loads all modules, manages idle/active mode, drives update loops

-- Global namespace — shared with all modules and third-party mods
WindrosePlus = {
    VERSION = "1.0.14",
    state = {
        playerCount = 0,
        mode = "boot",           -- starts as "boot", transitions to "idle" or "active"
        bootComplete = false,   -- set true after first successful query write (server fully loaded)
        lastPlayerSeen = 0,      -- os.time() when last player was detected
        _idleTransitionCount = 0 -- consecutive 0-player writes before transitioning
    },
    API = {},       -- public API for third-party mods
    _modules = {},  -- internal module registry
}

local Log = require("modules.log")

print("[Windrose+] v" .. WindrosePlus.VERSION .. " loaded\n")

-- ------------
-- Shared helpers
-- ------------

function WindrosePlus.safecall(fn, context)
    local ok, result = pcall(fn)
    if not ok then
        Log.debug(context or "Core", tostring(result))
    end
    return ok, result
end

-- Shared: check if a PlayerController is truly connected (not a zombie)
-- Disconnected players lose their pawn and stop updating ping
function WindrosePlus._isConnected(pc)
    local hasPawn = false
    pcall(function()
        local pawn = pc.Pawn
        if pawn and pawn:IsValid() then hasPawn = true end
    end)
    if hasPawn then return true end

    local hasActivePing = false
    pcall(function()
        local ps = pc.PlayerState
        if ps and ps:IsValid() then
            local ping = ps.CompressedPing
            if ping and tonumber(tostring(ping)) and tonumber(tostring(ping)) > 0 then
                hasActivePing = true
            end
        end
    end)
    return hasActivePing
end

function WindrosePlus.setMode(newMode)
    if WindrosePlus.state.mode ~= newMode then
        WindrosePlus.state.mode = newMode
        Log.info("Core", "Mode: " .. newMode)
    end
end

function WindrosePlus.updatePlayerCount(count)
    WindrosePlus.state.playerCount = count
    if count > 0 then
        WindrosePlus.state.lastPlayerSeen = os.time()
        WindrosePlus.state._idleTransitionCount = 0
        WindrosePlus.setMode("active")
    else
        WindrosePlus.state._idleTransitionCount = WindrosePlus.state._idleTransitionCount + 1
        -- Transition to idle after 6 consecutive 0-player writes (~30s)
        -- Higher threshold prevents false idle during player connect/disconnect lag
        if WindrosePlus.state._idleTransitionCount >= 6 then
            local wasIdle = WindrosePlus.isIdle()
            WindrosePlus.setMode("idle")
            -- Force immediate status write so dashboards see 0 players right away
            -- (otherwise the 30s idle interval delays the update). Resolve Query
            -- via _modules so it's looked up at call time — the top-level `local
            -- Query` is declared later in this file and isn't visible here.
            local Q = WindrosePlus._modules and WindrosePlus._modules.Query
            if not wasIdle and Q and Q.forceWrite then pcall(Q.forceWrite) end
        end
    end
end

function WindrosePlus.isIdle()
    return WindrosePlus.state.mode == "idle"
end

-- ------------
-- Game directory detection
-- ------------

local function detectGameDir()
    -- Get absolute path from Lua debug info (UE4SS provides full script path)
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local src = info.source:gsub("^@", "")
        -- Script is at: <game_root>/R5/Binaries/Win64/ue4ss/Mods/WindrosePlus/Scripts/main.lua
        -- Walk up 7 levels to get game root
        local gameRoot = src:match("^(.+)[/\\]R5[/\\]Binaries[/\\]Win64[/\\]ue4ss[/\\]Mods[/\\]WindrosePlus[/\\]Scripts[/\\]")
        if gameRoot then
            local f = io.open(gameRoot .. "\\R5\\ServerDescription.json", "r")
            if f then f:close(); return gameRoot .. "\\" end
        end
    end

    -- Fallback: probe relative paths
    local testPaths = { "..\\..\\..\\..\\", "..\\..\\..\\", "..\\..\\" }
    for _, rel in ipairs(testPaths) do
        local f = io.open(rel .. "R5\\ServerDescription.json", "r")
        if f then f:close(); return rel end
    end
    Log.warn("Core", "Could not detect game directory")
    return ".\\"
end

local gameDir = detectGameDir()
WindrosePlus._gameDir = gameDir
Log.info("Core", "Game dir: " .. gameDir)

-- ------------
-- Module loading
-- ------------

local function loadModule(name, loader)
    local ok, result = pcall(loader)
    if ok then
        WindrosePlus._modules[name] = result
        return result
    end
    Log.warn("Core", name .. " failed: " .. tostring(result))
    return nil
end

-- Set log level from config (after config loads)
local Config = loadModule("Config", function()
    local m = require("modules.config"); m.init(gameDir); return m
end)
if not Config then Log.error("Core", "Config required"); return end

local logLevel = Config.get("debug", "log_level")
if logLevel then Log.setLevel(logLevel) end

local Admin = loadModule("Admin", function()
    local m = require("modules.admin"); m.init(Config, gameDir); return m
end)

local Query = loadModule("Query", function()
    local m = require("modules.query"); m.init(gameDir, Config); return m
end)

local Rcon = loadModule("RCON", function()
    local m = require("modules.rcon"); m.init(gameDir, Config, Admin); return m
end)

local LiveMap = loadModule("LiveMap", function()
    local m = require("modules.livemap"); m.init(gameDir, Config); return m
end)

local MapGen = loadModule("MapGen", function()
    local m = require("modules.mapgen"); m.init(gameDir, Config); return m
end)

local POIScan = loadModule("POIScan", function()
    local m = require("modules.poiscan"); m.init(gameDir, Config); return m
end)

-- Register wp.mapgen command
if Admin and MapGen then
    Admin._commands["wp.mapgen"] = {
        description = "Generate heightmap for the live map viewer",
        usage = "wp.mapgen",
        handler = function(args)
            local status, message = MapGen.generate()
            return message
        end
    }
end

-- Register wp.mapexport command (triggers C++ HeightmapExporter mod)
if Admin then
    Admin._commands["wp.mapexport"] = {
        description = "Trigger terrain heightmap export for map tiles",
        usage = "wp.mapexport",
        handler = function(args)
            local dataDir = (WindrosePlus._modules.MapGen and WindrosePlus._modules.MapGen._gameDir or ".\\") .. "windrose_plus_data"
            local triggerPath = dataDir .. "\\export_heightmap_trigger"
            local f = io.open(triggerPath, "w")
            if f then
                f:write("export")
                f:close()
                return "Heightmap export triggered. The C++ mod will process this within 5 seconds."
            else
                return "Error: could not write trigger file"
            end
        end
    }
end

-- Auto-trigger heightmap export on first player connection if no map exists
local _mapExportTriggered = false
local function checkAndTriggerMapExport()
    if _mapExportTriggered then return end
    if WindrosePlus.state.playerCount == 0 then return end

    local dataDir = gameDir .. "windrose_plus_data"
    -- Check if terrain data already exists (try opening a known heightmap file)
    local checkPath = dataDir .. "\\heightmaps\\hf_l10_s0_0.bin"
    local f = io.open(checkPath, "r")
    if f then
        f:close()
        _mapExportTriggered = true -- map exists, don't trigger
        return
    end

    -- No map data — trigger export
    local triggerPath = dataDir .. "\\export_heightmap_trigger"
    local f = io.open(triggerPath, "w")
    if f then
        f:write("auto")
        f:close()
        Log.info("Core", "Auto-triggered heightmap export (first player, no cached map)")
    end
    _mapExportTriggered = true
end
WindrosePlus._checkMapExport = checkAndTriggerMapExport

-- Watch for heightmap export completion and trigger tile generation
local _tileGenTriggered = false
local function checkAndTriggerTileGen()
    if _tileGenTriggered then return end

    local dataDir = gameDir .. "windrose_plus_data"
    local donePath = dataDir .. "\\export_heightmap_done"
    local coordsPath = dataDir .. "\\map_coords.json"

    -- Check if export finished but tiles not yet generated
    local doneFile = io.open(donePath, "r")
    if not doneFile then return end
    doneFile:close()

    -- Check if tiles already exist
    local coordsFile = io.open(coordsPath, "r")
    if coordsFile then
        coordsFile:close()
        _tileGenTriggered = true
        return
    end

    -- Run tile generator (check tools/ first, then windrose_plus_http/ for alt deploy layouts)
    local candidates = {
        gameDir .. "windrose_plus\\tools\\generateTiles.ps1",
        gameDir .. "tools\\generateTiles.ps1",
        gameDir .. "windrose_plus_http\\generateTiles.ps1",
    }
    local ps1 = nil
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then f:close(); ps1 = path; break end
    end

    if ps1 then
        Log.info("Core", "Heightmap export complete — writing tile generation trigger...")
        -- Write a trigger file instead of os.execute — the dashboard HTTP server picks it up
        local triggerPath = dataDir .. "\\generate_tiles_trigger"
        local tf = io.open(triggerPath, "w")
        if tf then
            tf:write(ps1 .. "\n" .. gameDir .. "\n")
            tf:close()
        end
    else
        Log.warn("Core", "Heightmap export done but generateTiles.ps1 not found")
    end
    _tileGenTriggered = true
end
WindrosePlus._checkTileGen = checkAndTriggerTileGen

-- ------------
-- Public API for third-party mods (must be set up BEFORE loading mods)
-- ------------

WindrosePlus.API.VERSION = WindrosePlus.VERSION
WindrosePlus.API.log = function(level, source, msg) Log[level](source, msg) end

WindrosePlus.API.getPlayers = function()
    if Query then return Query.getPlayers() end
    return {}
end

WindrosePlus.API.getServerInfo = function()
    if Query and Query._serverInfo then return Query._serverInfo end
    return {}
end

WindrosePlus.API.getConfig = function(section, key)
    return Config.get(section, key)
end

WindrosePlus.API.isIdle = function()
    return WindrosePlus.isIdle()
end

-- Command registration for mods
WindrosePlus.API.registerCommand = function(name, handler, description, usage)
    if Admin then
        Admin._commands[name] = {
            description = description or "",
            usage = usage or name,
            handler = handler
        }
        Log.info("API", "Mod command registered: " .. name)
    end
end

-- Tick callback registration for mods
local _modTickCallbacks = {}
WindrosePlus.API.registerTickCallback = function(fn, intervalMs)
    table.insert(_modTickCallbacks, { fn = fn, interval = (intervalMs or 5000) / 1000, lastRun = 0 })
end

-- Player join/leave event callbacks
local _playerJoinCallbacks = {}
local _playerLeaveCallbacks = {}
local _lastKnownPlayers = {}

WindrosePlus.API.onPlayerJoin = function(fn)
    table.insert(_playerJoinCallbacks, fn)
end

WindrosePlus.API.onPlayerLeave = function(fn)
    table.insert(_playerLeaveCallbacks, fn)
end

local function firePlayerEvents(currentPlayers)
    local currentNames = {}
    for _, p in ipairs(currentPlayers) do
        if p.name then currentNames[p.name] = p end
    end

    -- Detect joins
    for name, player in pairs(currentNames) do
        if not _lastKnownPlayers[name] then
            for _, cb in ipairs(_playerJoinCallbacks) do
                pcall(cb, player)
            end
        end
    end

    -- Detect leaves
    for name, player in pairs(_lastKnownPlayers) do
        if not currentNames[name] then
            for _, cb in ipairs(_playerLeaveCallbacks) do
                pcall(cb, player)
            end
        end
    end

    _lastKnownPlayers = currentNames
end

-- Expose firePlayerEvents so Query can call it after collecting players
WindrosePlus._firePlayerEvents = firePlayerEvents

-- Run mod tick callbacks
local function runModTicks()
    local now = os.time()
    for _, entry in ipairs(_modTickCallbacks) do
        if now - entry.lastRun >= entry.interval then
            entry.lastRun = now
            pcall(entry.fn)
        end
    end
end

-- Load third-party mods (AFTER API is populated so mods can use it)
local Mods = loadModule("Mods", function()
    local m = require("modules.mods"); m.init(gameDir); return m
end)

-- Track player session join times for wp.playtime command
if Admin then
    WindrosePlus.API.onPlayerJoin(function(player)
        if player.name then
            Admin._playerJoinTimes[player.name] = os.time()
        end
    end)
    WindrosePlus.API.onPlayerLeave(function(player)
        if player.name then
            Admin._playerJoinTimes[player.name] = nil
        end
    end)
end

-- Append-only structured event log (windrose_plus_data\events.log).
-- Line-delimited JSON, best-effort coordinates (pawn location only available
-- when the join/leave poll resolved a position). External managers tail the
-- file; in-process callers should still use WindrosePlus.API.onPlayerJoin/Leave.
local _eventsLogPath = gameDir .. "windrose_plus_data\\events.log"
local _eventsJson = require("modules.json")
local _eventsLogOk = false
do
    local probe = io.open(_eventsLogPath, "a")
    if probe then
        probe:close()
        _eventsLogOk = true
        Log.info("Events", "Logging to " .. _eventsLogPath)
    else
        Log.warn("Events", "Cannot open " .. _eventsLogPath .. " — events.log disabled (check windrose_plus_data is writable)")
    end
end
local function _appendEvent(eventType, player)
    if not _eventsLogOk then return end
    local entry = {
        ts = os.time(),
        type = eventType,
        player = player.name or "Player",
        x = player.x, y = player.y, z = player.z
    }
    local ok, line = pcall(_eventsJson.encode, entry)
    if not ok then return end
    local f = io.open(_eventsLogPath, "a")
    if not f then
        _eventsLogOk = false
        Log.warn("Events", "Lost write access to " .. _eventsLogPath .. " — disabling")
        return
    end
    f:write(line .. "\n")
    f:close()
end
WindrosePlus.API.onPlayerJoin(function(p) pcall(_appendEvent, "join", p) end)
WindrosePlus.API.onPlayerLeave(function(p) pcall(_appendEvent, "leave", p) end)

-- ------------
-- Update drivers
-- ------------

-- RegisterHook on player movement — fires on game thread, flips mode to active.
-- Writers used to run here at 1 Hz; removed — they were redoing disk I/O +
-- FindAllOf walks that the periodic driver already covers at its own cadence.
local lastHookTime = 0
RegisterHook("/Script/R5.R5MovementComponent:ServerSaveMoveInput", function()
    local now = os.time()
    if now - lastHookTime < 1 then return end
    lastHookTime = now
    if WindrosePlus.isIdle() then
        WindrosePlus.setMode("active")
    end
end)

-- Writers touch UObjects (FindAllOf, property reads). UE4SS's LoopAsync runs on
-- a dedicated async thread, which races with game-thread GC / spawn / destroy.
-- We dispatch each writer tick to the game thread via ExecuteInGameThread.
-- JSON encode + disk writes run on the game thread too — payloads are small
-- (~5-50 KB), so the tick cost is negligible compared to the cost of racing
-- UObject iteration.
local _hasExecuteInGameThread = type(ExecuteInGameThread) == "function"
if not _hasExecuteInGameThread then
    Log.warn("Core", "ExecuteInGameThread not available — writers will run on async thread (UObject races possible)")
end

-- Per-writer coalescing: if a dispatch is already pending (not yet drained by
-- the game thread), skip queuing another one. Prevents unbounded action-vector
-- growth when the game thread is momentarily slow.
local _pendingTicks = {}

local function dispatchTick(fn)
    if not _hasExecuteInGameThread then
        pcall(fn)
        return
    end
    if _pendingTicks[fn] then return end
    _pendingTicks[fn] = true
    -- ExecuteInGameThread can throw if neither EngineTick nor ProcessEvent
    -- hooks are available; guard the schedule call itself.
    local ok, err = pcall(ExecuteInGameThread, function()
        _pendingTicks[fn] = nil
        pcall(fn)
    end)
    if not ok then
        _pendingTicks[fn] = nil
        Log.warn("Core", "ExecuteInGameThread dispatch failed: " .. tostring(err))
        pcall(fn)
    end
end

if Rcon and Config.isRconEnabled() then
    if Query   then Rcon.registerTickCallback(function() dispatchTick(Query.writeIfDue) end) end
    if LiveMap then Rcon.registerTickCallback(function() dispatchTick(LiveMap.writeIfDue) end) end
    if POIScan then Rcon.registerTickCallback(function() dispatchTick(POIScan.writeIfDue) end) end
    Rcon.registerTickCallback(function() dispatchTick(runModTicks) end)
else
    -- RCON disabled — standalone heartbeat
    if Query or LiveMap or POIScan then
        LoopAsync(5000, function()
            if Query   then dispatchTick(Query.writeIfDue) end
            if LiveMap then dispatchTick(LiveMap.writeIfDue) end
            if POIScan then dispatchTick(POIScan.writeIfDue) end
            dispatchTick(runModTicks)
            return false
        end)
    end
end

-- File watcher for mod hot-reload (polls every 30s — not urgent with 0 players)
if Mods then
    LoopAsync(30000, function()
        local changed = Mods.checkForChanges()
        if changed then
            Log.info("Core", "Mod files changed, restarting...")
            -- UE4SS native hot-reload — preserves shared variables
            if RestartMod then
                RestartMod("WindrosePlus")
            else
                Log.warn("Core", "RestartMod not available — restart server to load changes")
            end
        end
        return false
    end)
end

-- ------------
-- Startup complete
-- ------------

-- Module load summary
local _modStatus = {}
for _, name in ipairs({"Config", "Admin", "Query", "RCON", "LiveMap", "MapGen", "POIScan", "Mods"}) do
    _modStatus[#_modStatus + 1] = name .. " " .. (WindrosePlus._modules[name] and "OK" or "-")
end
Log.info("Core", "Modules: " .. table.concat(_modStatus, ", "))
if Rcon and Config.isRconEnabled() then
    Log.info("Core", "RCON: " .. gameDir .. "windrose_plus_data\\rcon\\cmd_<id>.json")
else
    Log.info("Core", "RCON disabled — set password in windrose_plus.json")
end
if Mods then
    local count = Mods.getLoadedCount()
    if count > 0 then
        Log.info("Core", count .. " mod(s) loaded from Mods/")
    end
end
Log.info("Core", "Mode: idle (waiting for players)")
