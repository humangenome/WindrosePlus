-- Windrose+ entry point
-- Loads all modules, manages idle/active mode, drives update loops

-- Global namespace — shared with all modules and third-party mods
--
-- VERSION below is rewritten from the git tag by .github/workflows/release.yml
-- at release time. The literal here is the development default and may lag the
-- latest CHANGELOG entry between tagged releases — that's flagged as a
-- non-blocking warning by .github/workflows/version-check.yml.
WindrosePlus = {
    VERSION = "1.0.16",
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

-- RegisterHook on player movement — fires on game thread, flips mode to active.
-- Writers used to run here at 1 Hz; removed — they were redoing disk I/O +
-- FindAllOf walks that the periodic driver already covers at its own cadence.
local lastHookTime = 0

-- Fast tick.beat (30s cadence). The 5-min heartbeat captures full state, but
-- when a crash kills the Lua VM it leaves a gap of up to 5 minutes between the
-- last heartbeat and the next mod.boot — too wide to localise the fault.
-- A 30s beat narrows time-of-death to <30s and records last_hook_age (seconds
-- since the last player movement hook fired), so crash forensics can
-- distinguish "died mid-tick under load" from "died while idle" from
-- "died while a player was actively moving."
local function _writeTickBeat()
    local now = os.time()
    Events.record("tick.beat", {
        uptime_sec = now - _bootTime,
        mode = WindrosePlus.state.mode,
        player_count = WindrosePlus.state.playerCount,
        last_hook_age_sec = (lastHookTime > 0) and (now - lastHookTime) or -1,
    })
end
LoopAsync(30000, function() pcall(_writeTickBeat); return false end)
-- ServerSaveMoveInput fires for every moving actor — players, mobs, and NPCs.
-- Without a player-pawn check, idle-server NPC AI keeps the mode flag stuck on
-- "active" through the night, which invalidates the safety claim that idle-mode
-- writers do zero UObject reads (see #43).
RegisterHook("/Script/R5.R5MovementComponent:ServerSaveMoveInput", function(self)
    -- The hook can fire before WindrosePlus is fully initialised (e.g., during
    -- early map load) or after a partial RestartMod. A nil-table dereference
    -- here escapes UE4SS as a fatal callback exception. See #41. Guard every
    -- field the body touches, not just isIdle — a partial table with isIdle
    -- but missing state or setMode would still throw downstream.
    if type(WindrosePlus) ~= "table"
       or type(WindrosePlus.isIdle) ~= "function"
       or type(WindrosePlus.setMode) ~= "function"
       or type(WindrosePlus.state) ~= "table" then return end
    local isPlayerPawn = false
    pcall(function()
        local pawn = self:GetOwner()
        if pawn and pawn:IsValid() and pawn.IsPlayerControlled then
            isPlayerPawn = pawn:IsPlayerControlled()
        end
    end)
    if not isPlayerPawn then return end
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
--
-- Idle-server starvation guard: on a dedicated server with no players, the
-- game thread ticks very slowly and ExecuteInGameThread queues can sit
-- undrained for minutes. If a pending dispatch is older than the stale
-- threshold, force-clear and run the function directly on the async thread.
-- In idle mode the writers do effectively zero UObject reads (no players, no
-- scanning), so the original game-thread race risk doesn't apply.
local _pendingTicks = {}
local _pendingSince = {}
local _stalePendingSeconds = 30

local function dispatchTick(fn)
    -- Tick callbacks resolve their target lazily through WindrosePlus._modules.
    -- A failed module init or a Lua GC pass on a captured upvalue can land us
    -- here with fn=nil; pcall(nil) raises LUA_ERRRUN and escapes UE4SS as a
    -- STATUS_FATAL_USER_CALLBACK_EXCEPTION. Guarding here is cheap insurance.
    if type(fn) ~= "function" then return end
    if not _hasExecuteInGameThread then
        pcall(fn)
        return
    end
    if _pendingTicks[fn] then
        local age = os.time() - (_pendingSince[fn] or 0)
        if age < _stalePendingSeconds then return end
        -- Queue starved — drop the entry and wait for the next LoopAsync cycle.
        -- Running the writer here on the async thread can race UE GC if mode
        -- has been falsely set to "active" by a non-player pawn (see #43), so
        -- we trade a delayed write for crash safety.
        _pendingTicks[fn] = nil
        _pendingSince[fn] = nil
        return
    end
    _pendingTicks[fn] = true
    _pendingSince[fn] = os.time()
    -- ExecuteInGameThread can throw if neither EngineTick nor ProcessEvent
    -- hooks are available, and the global itself can transiently be nil during
    -- UE4SS init/shutdown. Resolve the global INSIDE the pcall boundary so a
    -- nil lookup becomes a trappable Lua error instead of escaping into the
    -- UE4SS callback dispatcher as STATUS_FATAL_USER_CALLBACK_EXCEPTION.
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            _pendingTicks[fn] = nil
            _pendingSince[fn] = nil
            pcall(fn)
        end)
    end)
    if not ok then
        _pendingTicks[fn] = nil
        _pendingSince[fn] = nil
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

if Rcon and Config.isRconEnabled() then
    if Query   then Rcon.registerTickCallback(function() dispatchTick(_writer("Query"))   end) end
    if LiveMap then Rcon.registerTickCallback(function() dispatchTick(_writer("LiveMap")) end) end
    if POIScan then Rcon.registerTickCallback(function() dispatchTick(_writer("POIScan")) end) end
    Rcon.registerTickCallback(function() dispatchTick(runModTicks) end)
else
    -- RCON disabled — standalone heartbeat
    if (Query or LiveMap or POIScan) and LoopAsync then
        LoopAsync(5000, function()
            if Query   then dispatchTick(_writer("Query"))   end
            if LiveMap then dispatchTick(_writer("LiveMap")) end
            if POIScan then dispatchTick(_writer("POIScan")) end
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
