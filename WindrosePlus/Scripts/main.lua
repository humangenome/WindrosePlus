-- Windrose+ entry point
-- Loads all modules, manages idle/active mode, drives update loops

-- Global namespace — shared with all modules and third-party mods
--
-- VERSION below is rewritten from the git tag by .github/workflows/release.yml
-- at release time. The literal here is the development default and may lag the
-- latest CHANGELOG entry between tagged releases.
WindrosePlus = {
    VERSION = "1.1.24",
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
local Events = require("modules.events")
local EventBus = require("modules.eventbus")

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

-- Sentinel files used to confirm a candidate path is the Windrose game root.
-- pakchunk0-WindowsServer.pak has been the dedicated-server pak filename
-- across every Windrose engine version we have shipped against. The shipping
-- exe is the next-most-stable check. R5\ServerDescription.json only exists
-- after the server's first start, so it is checked last.
local function _isGameRoot(root)
    local sentinels = {
        root .. "R5\\Content\\Paks\\pakchunk0-WindowsServer.pak",
        root .. "R5\\Binaries\\Win64\\WindroseServer-Win64-Shipping.exe",
        root .. "R5\\ServerDescription.json",
    }
    for _, p in ipairs(sentinels) do
        local f = io.open(p, "r")
        if f then f:close(); return true end
    end
    return false
end

local function detectGameDir()
    -- Get absolute path from Lua debug info (UE4SS provides full script path)
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local src = info.source:gsub("^@", "")
        -- Script is at: <game_root>/R5/Binaries/Win64/ue4ss/Mods/WindrosePlus/Scripts/main.lua
        -- Walk up 7 levels to get game root
        local gameRoot = src:match("^(.+)[/\\]R5[/\\]Binaries[/\\]Win64[/\\]ue4ss[/\\]Mods[/\\]WindrosePlus[/\\]Scripts[/\\]")
        if gameRoot and _isGameRoot(gameRoot .. "\\") then
            return gameRoot .. "\\"
        end
    end

    -- Fallback: probe relative paths
    local testPaths = { "..\\..\\..\\..\\", "..\\..\\..\\", "..\\..\\" }
    for _, rel in ipairs(testPaths) do
        if _isGameRoot(rel) then return rel end
    end
    Log.warn("Core", "Could not detect game directory")
    return ".\\"
end

local gameDir = detectGameDir()
WindrosePlus._gameDir = gameDir
Log.info("Core", "Game dir: " .. gameDir)

-- Bring up the server activity log before any module init. From this point
-- forward, server-state changes (boot, config, admin commands, joins/leaves,
-- heartbeats) are appended to windrose_plus_data\logs\YYYY-MM-DD.log.
Events.init(gameDir)
Events.record("mod.boot", {
    version = WindrosePlus.VERSION,
    game_dir = gameDir,
    lua_version = _VERSION,
    has_execute_in_game_thread = type(ExecuteInGameThread) == "function",
    has_register_hook = type(RegisterHook) == "function",
})
WindrosePlus._modules.Events = Events
WindrosePlus.API.logEvent = function(ev, payload) Events.record(ev, payload) end

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
    -- Surface module-load failures into the activity log so post-mortem doesn't
    -- require digging through UE4SS.log alongside the events log.
    pcall(function() Events.record("module.load.fail", { module = name, err = tostring(result) }) end)
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

-- ------------
-- Sea Chart map pipeline
--
--   wp.mapexport  the HeightmapExporter C++ mod reads the live world's landscape
--                 into windrose_plus_data\terrain_v17.json + heightmaps\, then
--                 the tiles are rebuilt from it automatically.
--   wp.mapgen     rebuilds the Sea Chart tiles from the terrain already on disk
--                 (the dashboard runs tools\generateTiles.ps1 for us).
--   wp.mapprobe   writes a landscape diagnostic to terrain_probe.json (debug).
--
-- The terrain export is tied to the world it came from (WorldIslandId in
-- R5\ServerDescription.json, recorded in windrose_plus_data\map_world.txt), so a
-- new or switched world re-exports on its first player instead of showing the
-- old world's islands.
-- ------------

local function mapDataDir()
    return gameDir .. "windrose_plus_data"
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function readFirstLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if line then line = line:gsub("%s+$", "") end
    if line == "" then return nil end
    return line
end

local function writeSmallFile(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

-- An export taken while the server sits in its lobby map (no player online yet)
-- has no landscape components, so treat a terrain file without a single
-- heightfield as missing.
local function terrainLooksValid(path)
    local f = io.open(path, "r")
    if not f then return false end
    local raw = f:read("*a")
    f:close()
    return raw ~= nil and #raw > 200 and raw:find('"h":1', 1, true) ~= nil
end

local function currentWorldId()
    local f = io.open(gameDir .. "R5\\ServerDescription.json", "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    local id = raw and raw:match('"WorldIslandId"%s*:%s*"([^"]*)"')
    if id == nil or id == "" then return nil end
    return id
end

local _pendingTileGenAfterExport = false

local function requestTerrainExport(reason)
    local dir = mapDataDir()
    -- Clear the old completion marker so the watcher waits for this export.
    os.remove(dir .. "\\export_heightmap_done")
    if not writeSmallFile(dir .. "\\export_heightmap_trigger", reason or "export") then
        return false
    end
    _pendingTileGenAfterExport = true
    local worldId = currentWorldId()
    if worldId then writeSmallFile(dir .. "\\map_world.txt", worldId .. "\n") end
    return true
end

local function findTileGenerator()
    local candidates = {
        gameDir .. "windrose_plus\\tools\\generateTiles.ps1",
        gameDir .. "R5\\Binaries\\Win64\\ue4ss\\Mods\\WindrosePlus\\tools\\generateTiles.ps1",
        gameDir .. "tools\\generateTiles.ps1",
        gameDir .. "windrose_plus_http\\generateTiles.ps1",
    }
    for _, path in ipairs(candidates) do
        if fileExists(path) then return path end
    end
    return nil
end

-- The dashboard HTTP server watches for this file and runs generateTiles.ps1
-- (os.execute from UE4SS Lua can deadlock the game thread).
local function requestTileGeneration()
    local ps1 = findTileGenerator()
    if not ps1 then return false, "generateTiles.ps1 not found" end
    if not writeSmallFile(mapDataDir() .. "\\generate_tiles_trigger", ps1 .. "\n" .. gameDir .. "\n") then
        return false, "could not write the tile generation trigger"
    end
    return true
end

if Admin then
    Admin._commands["wp.mapgen"] = {
        description = "Rebuild the Sea Chart tiles from the exported terrain",
        usage = "wp.mapgen",
        category = "map",
        handler = function(args)
            if not terrainLooksValid(mapDataDir() .. "\\terrain_v17.json") then
                return "No terrain export for this world yet. It runs by itself when the first player joins, or run wp.mapexport while someone is online."
            end
            local ok, err = requestTileGeneration()
            if not ok then return "Error: " .. tostring(err) end
            return "Tile rebuild requested. The dashboard regenerates the Sea Chart in the background (about a minute); refresh the page when windrose_plus_data\\map_generation_status.json says complete."
        end
    }

    Admin._commands["wp.mapexport"] = {
        description = "Export the live world's terrain and rebuild the Sea Chart",
        usage = "wp.mapexport",
        category = "map",
        handler = function(args)
            if (WindrosePlus.state.playerCount or 0) == 0 then
                return "No players online. Windrose loads the world when the first player joins, so an export now would come back empty. Run wp.mapexport while someone is on the server."
            end
            if not requestTerrainExport("export") then
                return "Error: could not write the export trigger"
            end
            return "Terrain export requested. The HeightmapExporter mod picks it up within a few seconds, then the Sea Chart tiles are rebuilt automatically."
        end
    }

    if MapGen then
        Admin._commands["wp.mapprobe"] = {
            description = "Write a landscape diagnostic to terrain_probe.json",
            usage = "wp.mapprobe",
            hidden = true, category = "debug",
            handler = function(args)
                local status, message = MapGen.generate()
                return message
            end
        }
    end
end

-- Re-export commands.json so the map commands (and any mod commands
-- registered via API.registerCommand above) are in the dashboard's view.
if Admin and Admin.writeCommandsJson then Admin.writeCommandsJson() end

-- First player online: export terrain if there is none yet, or if the terrain
-- on disk belongs to a different world than the one now loaded.
local _mapExportChecked = false
local function checkAndTriggerMapExport()
    if _mapExportChecked then return end
    if WindrosePlus.state.playerCount == 0 then return end
    _mapExportChecked = true

    local dir = mapDataDir()
    local haveTerrain = terrainLooksValid(dir .. "\\terrain_v17.json") and fileExists(dir .. "\\export_heightmap_done")
    local worldId = currentWorldId()
    local recordedWorld = readFirstLine(dir .. "\\map_world.txt")

    if haveTerrain then
        if worldId and recordedWorld and recordedWorld ~= worldId then
            Log.info("Core", "World changed since the last terrain export (" .. recordedWorld .. " -> " .. worldId .. "); re-exporting the Sea Chart")
            requestTerrainExport("world-changed")
        elseif worldId and not recordedWorld then
            -- Terrain from before world tracking: adopt it for the current world.
            writeSmallFile(dir .. "\\map_world.txt", worldId .. "\n")
        end
        return
    end

    if requestTerrainExport("auto") then
        Log.info("Core", "Auto-triggered heightmap export (first player, no terrain for this world)")
    end
end
WindrosePlus._checkMapExport = checkAndTriggerMapExport

-- Rebuild tiles when an export finishes, or once at boot when terrain exists
-- but no tiles were ever generated.
local _initialTileCheckDone = false
local function checkAndTriggerTileGen()
    local dir = mapDataDir()
    if not fileExists(dir .. "\\export_heightmap_done") then return end

    if _pendingTileGenAfterExport then
        _pendingTileGenAfterExport = false
        _initialTileCheckDone = true
        if not terrainLooksValid(dir .. "\\terrain_v17.json") then
            Log.warn("Core", "Heightmap export finished with no terrain (world not loaded yet?); Sea Chart tiles left as they were")
            return
        end
        local ok, err = requestTileGeneration()
        if ok then
            Log.info("Core", "Heightmap export complete; tile generation requested")
        else
            Log.warn("Core", "Heightmap export done but tiles not requested: " .. tostring(err))
        end
        return
    end

    if _initialTileCheckDone then return end
    _initialTileCheckDone = true
    if fileExists(dir .. "\\map_coords.json") then return end
    if not terrainLooksValid(dir .. "\\terrain_v17.json") then return end
    local ok, err = requestTileGeneration()
    if ok then
        Log.info("Core", "Terrain export found without tiles; tile generation requested")
    else
        Log.warn("Core", "Heightmap export done but tiles not requested: " .. tostring(err))
    end
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

-- Deferred answers for mod commands: a handler that has to wait (e.g. for a game-thread task of a native mod) returns
-- { deferred = token [, timeout = seconds] [, timeout_message = text] } and answers later with
-- API.completeDeferred(token, ok, message). Tokens are strings; prefix them with the mod name to keep them unique.
-- Only RCON (dashboard, spool clients) can wait; check API.deferredSupported() first and answer directly otherwise.
if Rcon and Admin then Admin.deferredSupported = true end
WindrosePlus.API.deferredSupported = function()
    return Admin ~= nil and Admin.deferredSupported == true
end
WindrosePlus.API.deferredMaxSeconds = function()
    return Rcon and Rcon._deferredMaxSec or 0
end
WindrosePlus.API.completeDeferred = function(token, ok, message)
    local sToken = tostring(token)
    local handled = false
    if Rcon and Rcon.completeDeferred then
        handled = Rcon.completeDeferred(sToken, ok, message)
    end
    -- Other callers of API.executeCommand (e.g. an in-game console add-on) wait for their own tokens here
    EventBus.emit("command.completed", { token = sToken, ok = ok == true or ok == "ok", message = message }, "core")
    return handled
end

-- Command registration for mods. opts (optional): { hidden = true } keeps the command out of wp.help and
-- commands.json (wp.help all shows it), { category = "debug" } groups it in wp.help (default "server"),
-- { subcommands = { { name = "item", usage = "<player> <item> [count]", description = "...", handler = fn }, ... } }
-- registers subcommands: a subcommand's handler(args, caller) gets the words after it; without a handler the
-- command's own handler gets every call. A bare command answers its subcommand list, an unknown subcommand is an
-- error. usage may then be nil (generated). handler may be nil when every subcommand has its own.
-- { examples = { "line", ... } } adds lines under wp.help <command> (worked examples, notes).
WindrosePlus.API.registerCommand = function(name, handler, description, usage, opts)
    if Admin then
        Admin.register(name, handler, description, usage, opts)
        Log.info("API", "Mod command registered: " .. name)
        if Admin.writeCommandsJson then Admin.writeCommandsJson() end
    end
end

-- All registered commands (built-in and mods): { { name, usage, description, category, hidden, subcommands }, ... }
-- by name (subcommands = { { name, usage, description }, ... } or nil)
WindrosePlus.API.listCommands = function()
    local out = {}
    if Admin then
        for name, cmd in pairs(Admin._commands) do
            out[#out + 1] = { name = name, usage = cmd.usage or name, description = cmd.description or "",
                              category = cmd.category or "server", hidden = cmd.hidden == true,
                              subcommands = cmd.subcommands and (function()
                                  local subs = {}
                                  for _, sub in ipairs(cmd.subcommands) do
                                      subs[#subs + 1] = { name = sub.name, usage = sub.usage, description = sub.description }
                                  end
                                  return subs
                              end)() or nil }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Run a command like RCON does. args: table or string. Returns status ("ok", "error" or "deferred"), message, opts.
-- "deferred": message is the token; the answer arrives as event command.completed { token, ok, message }, or
-- never (then give up after opts.timeout seconds, default 10). Access control is the caller's job.
-- caller (optional): { accountId, name } of an in-game caller, handed to the command handler as its second argument
-- (handlers can tailor answers or checks); nil = RCON-level access.
WindrosePlus.API.executeCommand = function(command, args, caller)
    if not Admin then return "error", "Admin module not loaded" end
    if type(args) == "string" then
        local list = {}
        for part in args:gmatch("%S+") do list[#list + 1] = part end
        args = list
    end
    local ok, status, message, opts = pcall(Admin.execute, tostring(command), type(args) == "table" and args or {},
                                            type(caller) == "table" and caller or nil)
    if not ok then return "error", tostring(status) end
    return status, message, opts
end

-- Describe the subcommands of an existing command (e.g. a built-in one) for wp.help, commands.json and in-game
-- consoles, without replacing its handler: subs = { { name, usage, description }, ... }. Returns true or false, reason.
WindrosePlus.API.setSubcommands = function(name, subs)
    if not Admin then return false, "Admin module not loaded" end
    return Admin.setSubcommands(name, subs)
end

-- Tick callback registration for mods
local _modTickCallbacks = {}
WindrosePlus.API.registerTickCallback = function(fn, intervalMs)
    table.insert(_modTickCallbacks, { fn = fn, interval = (intervalMs or 5000) / 1000, lastRun = 0 })
end

-- Some Blueprint-backed UFunctions exist before their native function pointer is
-- ready for UE4SS hooks. This helper retries registration for mods that want to
-- hook late-discovered game surfaces without hand-rolling LoopAsync timers.
WindrosePlus.API.registerHookWhenAvailable = function(path, preHook, postHook, options)
    if type(postHook) == "table" and options == nil then
        options = postHook
        postHook = nil
    end
    if type(options) ~= "table" then options = {} end

    local handle = {
        path = path,
        attempts = 0,
        registered = false,
        failed = false,
        cancelled = false,
        lastError = nil,
        preHookId = nil,
        postHookId = nil,
    }

    function handle.cancel()
        handle.cancelled = true
    end

    local source = tostring(options.logSource or "API")
    local intervalMs = tonumber(options.intervalMs) or 5000
    local maxAttempts = tonumber(options.maxAttempts) or 24
    if intervalMs < 250 then intervalMs = 250 end
    if maxAttempts < 1 then maxAttempts = 1 end

    local function fail(message)
        handle.failed = true
        handle.lastError = tostring(message)
        Log.warn(source, "Hook unavailable: " .. tostring(path) .. " (" .. handle.lastError .. ")")
        if type(options.onFailed) == "function" then pcall(options.onFailed, handle) end
        return true
    end

    local function tryRegister()
        if handle.cancelled or handle.registered or handle.failed then return true end
        if type(path) ~= "string" or path == "" then return fail("invalid hook path") end
        if type(preHook) ~= "function" and type(postHook) ~= "function" then return fail("missing hook callback") end

        handle.attempts = handle.attempts + 1
        if type(RegisterHook) ~= "function" then
            handle.lastError = "RegisterHook not available"
        else
            local ok, id1, id2
            if type(postHook) == "function" then
                ok, id1, id2 = pcall(RegisterHook, path, preHook, postHook)
            else
                ok, id1, id2 = pcall(RegisterHook, path, preHook)
            end
            if ok then
                handle.registered = true
                handle.preHookId = id1
                handle.postHookId = id2
                Log.info(source, "Hook registered: " .. path .. " after " .. handle.attempts .. " attempt(s)")
                if type(options.onRegistered) == "function" then pcall(options.onRegistered, handle) end
                return true
            end
            handle.lastError = tostring(id1)
        end

        if handle.attempts >= maxAttempts then
            return fail(handle.lastError or "max attempts reached")
        end
        return false
    end

    local done = tryRegister()
    if not done and type(LoopAsync) == "function" then
        LoopAsync(intervalMs, tryRegister)
    elseif not done then
        fail("LoopAsync not available")
    end

    return handle
end

-- Event subscriptions (modules/eventbus.lua): add-ons call API.on("ship.captain", fn) etc.
WindrosePlus.API.on = EventBus.on
WindrosePlus.API.once = EventBus.once
WindrosePlus.API.emit = function(ev, payload) EventBus.emit(ev, payload, "lua") end
WindrosePlus.API.listEvents = EventBus.list

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
            EventBus.emit("player.join", player)
        end
    end

    -- Detect leaves
    for name, player in pairs(_lastKnownPlayers) do
        if not currentNames[name] then
            for _, cb in ipairs(_playerLeaveCallbacks) do
                pcall(cb, player)
            end
            EventBus.emit("player.leave", player)
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
            -- Same nil-guard as dispatchTick: a third-party mod that registered
            -- a tick callback and was later unloaded leaves a stale entry whose
            -- fn can be nil after Lua GC. pcall(nil) escapes UE4SS as a fatal
            -- callback exception. See #41.
            if type(entry.fn) == "function" then pcall(entry.fn) end
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

-- Player join/leave events (server activity log).
-- alive=false at join time = player resurrected on a corpse (server forced
-- respawn while connecting). alive=false at leave = player died offline or in
-- the same tick they disconnected. Useful signal for rubber-banding-at-sea (#42)
-- and for save-corruption forensics where the character should be alive.
WindrosePlus.API.onPlayerJoin(function(p)
    Events.record("player.join", { name = p.name, x = p.x, y = p.y, z = p.z, alive = p.alive })
end)
WindrosePlus.API.onPlayerLeave(function(p)
    Events.record("player.leave", { name = p.name, x = p.x, y = p.y, z = p.z, alive = p.alive })
end)

-- Heartbeat: every 5 minutes, snapshot server state so a later investigator
-- can reconstruct what multipliers / config were active during any window
-- without needing to find the last config.load entry.
local _bootTime = os.time()
local _lastHeartbeat = 0
local function _writeHeartbeat()
    local now = os.time()
    if now - _lastHeartbeat < 300 then return end
    _lastHeartbeat = now
    local cfg = Config and Config._data or {}
    Events.record("heartbeat", {
        uptime_sec = now - _bootTime,
        mode = WindrosePlus.state.mode,
        player_count = WindrosePlus.state.playerCount,
        last_player_seen = WindrosePlus.state.lastPlayerSeen,
        multipliers = cfg.multipliers,
        rcon_enabled = cfg.rcon and cfg.rcon.enabled or false,
    })
end
LoopAsync(60000, function() pcall(_writeHeartbeat); return false end)
-- Fire one immediate heartbeat on boot so the first line after mod.boot
-- already carries the active config snapshot.
pcall(_writeHeartbeat)

-- ------------
-- Update drivers
-- ------------

-- Fast tick.beat (30s cadence). The 5-min heartbeat captures full state, but
-- when a crash kills the Lua VM it leaves a gap of up to 5 minutes between
-- the last heartbeat and the next mod.boot, too wide to localise the fault.
-- A 30s beat narrows time-of-death to <30s and records the age of the last
-- player detected by the periodic Query/LiveMap poll.
local function _writeTickBeat()
    local now = os.time()
    local lastPlayerSeen = WindrosePlus.state.lastPlayerSeen or 0
    Events.record("tick.beat", {
        uptime_sec = now - _bootTime,
        mode = WindrosePlus.state.mode,
        player_count = WindrosePlus.state.playerCount,
        last_player_age_sec = (lastPlayerSeen > 0) and (now - lastPlayerSeen) or -1,
    })
end
LoopAsync(30000, function() pcall(_writeTickBeat); return false end)

-- Do not hook ServerSaveMoveInput. UE4SS still crosses the Lua bridge for
-- every movement RPC before our Lua body can return, which is enough to cause
-- ship/AI rubber-banding on constrained hosts (#33). Periodic Query/LiveMap
-- polling updates player count and active/idle state without that hot-path
-- hook overhead.

-- Writers touch UObjects (FindAllOf, property reads). UE4SS's LoopAsync runs on
-- a dedicated async thread, which races with game-thread GC / spawn / destroy.
-- When a viable UE4SS dispatcher hook is enabled, dispatch each writer's UObject
-- collection to the game thread via ExecuteInGameThread, then flush queued JSON
-- file writes from the async driver on the next tick so disk I/O does not run on
-- the simulation thread (#33).
local function _readUe4ssSettings()
    -- Derive the settings path from debug.getinfo INSTEAD of gameDir so that a
    -- regression in game-dir detection (e.g. a future engine bump that
    -- invalidates our sentinels) does not silently flip ExecuteInGameThread
    -- detection from "hooks disabled" to "hooks unknown / assumed available".
    -- That flip is dangerous: if hooks really are disabled, queued closures
    -- never drain and every UObject-touching writer starves at #46.
    local candidates = {}
    local info = debug.getinfo(1, "S")
    if info and info.source then
        local src = info.source:gsub("^@", "")
        -- Specific: standard layout, .../R5/Binaries/Win64/ue4ss/Mods/...
        local ue4ssDir = src:match("^(.+[/\\]R5[/\\]Binaries[/\\]Win64[/\\]ue4ss)[/\\]Mods[/\\]")
        if ue4ssDir then
            candidates[#candidates + 1] = ue4ssDir .. "\\UE4SS-settings.ini"
        end
        -- Generic: covers any UE4SS install where the loader folder is named
        -- something other than "ue4ss" (e.g. uppercase "UE4SS", or a future
        -- rename). The settings file always lives next to the Mods folder.
        local modsParent = src:match("^(.+)[/\\]Mods[/\\]")
        if modsParent and modsParent ~= ue4ssDir then
            candidates[#candidates + 1] = modsParent .. "\\UE4SS-settings.ini"
        end
    end
    candidates[#candidates + 1] = gameDir .. "R5\\Binaries\\Win64\\ue4ss\\UE4SS-settings.ini"
    candidates[#candidates + 1] = ".\\UE4SS-settings.ini"

    local raw
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            raw = f:read("*a")
            f:close()
            break
        end
    end
    if not raw then return nil end
    local out = {}
    for line in raw:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*([^;]*)")
        if key then
            out[key:lower()] = tostring(value or ""):match("^%s*(.-)%s*$")
        end
    end
    return out
end

local function _settingEnabled(settings, key)
    if not settings then return nil end
    local v = settings[key:lower()]
    if v == nil then return nil end
    v = tostring(v):lower():match("^%s*(.-)%s*$")
    if v == "1" or v == "true" or v == "yes" or v == "on" then return true end
    if v == "0" or v == "false" or v == "no" or v == "off" then return false end
    return nil
end

local function _detectExecuteInGameThread()
    if type(ExecuteInGameThread) ~= "function" then
        return false, "global_missing"
    end
    local settings = _readUe4ssSettings()
    if not settings then
        return true, nil
    end
    local method = tostring(settings.defaultexecuteingamethreadmethod or "enginetick"):lower()
    local engineTick = _settingEnabled(settings, "HookEngineTick")
    local processEvent = _settingEnabled(settings, "HookUObjectProcessEvent")

    if method == "enginetick" and engineTick == false then
        return false, "EngineTick dispatch selected but HookEngineTick=0"
    end
    if method == "processevent" and processEvent == false then
        return false, "ProcessEvent dispatch selected but HookUObjectProcessEvent=0"
    end
    if engineTick == false and processEvent == false then
        return false, "all ExecuteInGameThread dispatcher hooks disabled"
    end
    return true, nil
end

local _hasExecuteInGameThread, _executeInGameThreadReason = _detectExecuteInGameThread()
if not _hasExecuteInGameThread then
    Log.warn("Core", "ExecuteInGameThread unavailable (" .. tostring(_executeInGameThreadReason) .. ") — writers will run directly")
end

-- Per-writer coalescing: if a dispatch is already pending (not yet drained by
-- the game thread), skip queuing another one. Prevents unbounded action-vector
-- growth when the game thread is momentarily slow.
--
-- Queue-starvation guard: on some UE4SS/R5 combinations, ExecuteInGameThread
-- accepts a closure but never drains it (#46). The fallback below never runs a
-- UObject-reading writer on the async thread. Query and LiveMap emit degraded
-- file-only snapshots, POIScan is suppressed, and third-party mod ticks stay on
-- the original game-thread path.
local _pendingTicks = {}
local _pendingSince = {}
local _consecutiveStales = {}
local _degraded = {}
local _generation = {}
local _stalePendingSeconds = 10
local _stalePendingRequired = 2
local _degradableWriters = { Query = true, LiveMap = true, POIScan = true }

-- UE4SS enters one Lua VM for this mod. These dispatch tables are only touched
-- from Lua callbacks in that VM; the generation token protects against late
-- game-thread closures after the async loop has dropped or degraded a pending
-- dispatch.
local function _writerModule(name)
    return WindrosePlus and WindrosePlus._modules and WindrosePlus._modules[name] or nil
end

local function _writeDegraded(name)
    local reason = "execute_in_game_thread_starved"
    if name == "Query" then
        local m = _writerModule("Query")
        if m and m.writeDegraded then pcall(m.writeDegraded, reason) end
    elseif name == "LiveMap" then
        local m = _writerModule("LiveMap")
        if m and m.writeDegraded then pcall(m.writeDegraded, reason) end
    end
end

local function _enterDegraded(key, name)
    _pendingTicks[key] = nil
    _pendingSince[key] = nil
    _consecutiveStales[key] = 0
    _degraded[key] = true
    _generation[key] = (_generation[key] or 0) + 1
    if name == "POIScan" then
        Log.warn("Core", "ExecuteInGameThread queue starved (#46) — POIScan suppressed in degraded mode")
    else
        Log.warn("Core", "ExecuteInGameThread queue starved (#46) — " .. tostring(name) .. " in degraded mode")
        _writeDegraded(name)
    end
end

local function dispatchTick(fn, name)
    -- Tick callbacks resolve their target lazily through WindrosePlus._modules.
    -- A failed module init or a Lua GC pass on a captured upvalue can land us
    -- here with fn=nil; pcall(nil) raises LUA_ERRRUN and escapes UE4SS as a
    -- STATUS_FATAL_USER_CALLBACK_EXCEPTION. Guarding here is cheap insurance.
    if type(fn) ~= "function" then return end
    local key = name or fn
    if not _hasExecuteInGameThread then
        pcall(fn)
        return
    end
    if _degraded[key] then
        _writeDegraded(name)
        return
    end
    if _pendingTicks[key] then
        local age = os.time() - (_pendingSince[key] or 0)
        if age < _stalePendingSeconds then return end
        if _degradableWriters[name] then
            _consecutiveStales[key] = (_consecutiveStales[key] or 0) + 1
            _generation[key] = (_generation[key] or 0) + 1
            if _consecutiveStales[key] >= _stalePendingRequired then
                _enterDegraded(key, name)
                return
            end
        end
        -- One stale observation can be a healthy but overloaded game thread.
        -- Drop this pending marker and give ExecuteInGameThread one more chance.
        _pendingTicks[key] = nil
        _pendingSince[key] = nil
        return
    end
    _pendingTicks[key] = true
    _pendingSince[key] = os.time()
    local capturedGen = _generation[key] or 0
    -- ExecuteInGameThread can throw if neither EngineTick nor ProcessEvent
    -- hooks are available, and the global itself can transiently be nil during
    -- UE4SS init/shutdown. Resolve the global INSIDE the pcall boundary so a
    -- nil lookup becomes a trappable Lua error instead of escaping into the
    -- UE4SS callback dispatcher as STATUS_FATAL_USER_CALLBACK_EXCEPTION.
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            if (_generation[key] or 0) ~= capturedGen then return end
            _pendingTicks[key] = nil
            _pendingSince[key] = nil
            _consecutiveStales[key] = 0
            pcall(fn)
        end)
    end)
    if not ok then
        _pendingTicks[key] = nil
        _pendingSince[key] = nil
        -- Mark the dispatcher dead so subsequent dispatches use the direct
        -- path immediately instead of re-throwing every tick. The next
        -- LoopAsync cycle runs the writer through the
        -- `_hasExecuteInGameThread = false` branch above.
        _hasExecuteInGameThread = false
        Log.warn("Core", "ExecuteInGameThread lost — falling back to direct dispatch: " .. tostring(err))
    end
end

-- Lazy module resolution: pulls the writer through WindrosePlus._modules at
-- call time so a Lua GC pass or RestartMod (which can drop captured upvalues)
-- doesn't strand a stale function reference inside the tick closure. See #41.
-- Full type-guard on WindrosePlus too — the standalone LoopAsync path doesn't
-- run through Rcon's pcall'd dispatch, so an exception here would escape into
-- UE4SS' callback dispatcher.
local function _writer(name)
    if type(WindrosePlus) ~= "table" or type(WindrosePlus._modules) ~= "table" then return nil end
    local m = WindrosePlus._modules[name]
    return m and m.writeIfDue
end

local function _flushPendingWriter(name)
    local m = _writerModule(name)
    if m and type(m.flushPendingWrite) == "function" then
        pcall(m.flushPendingWrite)
    end
end

local function _dispatchWriter(name)
    _flushPendingWriter(name)
    dispatchTick(_writer(name), name)
    _flushPendingWriter(name)
end

-- Per-writer enable flags. Constrained hosts can disable individual writers
-- via [livemap].enabled / [query].enabled / [poiscan].enabled in the config
-- to drop the per-tick game-thread cost while keeping RCON, admin commands,
-- multipliers, and the mods loader running. See #33.
local _queryEnabled   = Config.isQueryEnabled()
local _liveMapEnabled = type(Config.isLiveMapEnabled) == "function" and Config.isLiveMapEnabled() or true
local _poiScanEnabled = type(Config.isPOIScanEnabled) == "function" and Config.isPOIScanEnabled() or true
Log.info("Core", string.format("Writers: query=%s livemap=%s poiscan=%s",
    tostring(_queryEnabled), tostring(_liveMapEnabled), tostring(_poiScanEnabled)))

if Rcon and Config.isRconEnabled() then
    if Query   and _queryEnabled   then Rcon.registerTickCallback(function() _dispatchWriter("Query")   end) end
    if LiveMap and _liveMapEnabled then Rcon.registerTickCallback(function() _dispatchWriter("LiveMap") end) end
    if POIScan and _poiScanEnabled then Rcon.registerTickCallback(function() dispatchTick(_writer("POIScan"), "POIScan") end) end
    Rcon.registerTickCallback(function() dispatchTick(runModTicks, "RunModTicks") end)
else
    -- RCON disabled — standalone heartbeat
    if (Query or LiveMap or POIScan) and LoopAsync then
        LoopAsync(5000, function()
            if Query   and _queryEnabled   then _dispatchWriter("Query")   end
            if LiveMap and _liveMapEnabled then _dispatchWriter("LiveMap") end
            if POIScan and _poiScanEnabled then dispatchTick(_writer("POIScan"), "POIScan") end
            dispatchTick(runModTicks, "RunModTicks")
            return false
        end)
    end
end

-- Event bus: dispatches Lua events and drains native events of an optional C++ mod (WPNative.PollEvents)
EventBus.start(Config.get("events", "poll_ms") or 100, WindrosePlus.API.isIdle)

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
