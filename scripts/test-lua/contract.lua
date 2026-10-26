-- Contract samples: runs the mod's real data-file writers offline (UE4SS stubbed) and copies what they write
-- into an output folder, one file per contract, for scripts/contract/check-data-files.py to check against
-- scripts/contract/schemas. Hosts and tools read these files directly (the dashboard server, panels that
-- host Windrose+), so a change in their shape breaks them even when the HTTP routes stay the same.
--
-- Run from the repository root:  lua5.4 scripts/test-lua/contract.lua <output folder>
--
-- The mod builds Windows paths with "\\"; on Linux those are plain characters in a file name, so every
-- file the mod writes lands in one temp folder under a name with backslashes in it (as in run.lua).

package.path = "./WindrosePlus/Scripts/?.lua;" .. package.path

local outDir = arg[1]
if not outDir or outDir == "" then
    io.stderr:write("usage: lua5.4 scripts/test-lua/contract.lua <output folder>\n")
    os.exit(2)
end
assert(os.execute('mkdir -p "' .. outDir .. '"'))

local failed = 0
local function fail(msg) failed = failed + 1; print("FAIL " .. msg) end

local function tempDir()
    local p = os.tmpname()
    os.remove(p)
    assert(os.execute('mkdir -p "' .. p .. '"'))
    return p
end
local function writeFile(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function collect(from, name)
    local text = readFile(from)
    if not text then fail("the mod wrote no " .. name); return end
    writeFile(outDir .. "/" .. name, text)
    print("ok   " .. name .. " (" .. #text .. " bytes)")
end

-- ---------------------------------------------------------------- the game folder
local game = tempDir() .. "/"
local data = game .. "windrose_plus_data"
-- The settings file in the shape a host panel writes on every start (install.ps1 creates the same keys).
writeFile(game .. "\\windrose_plus.json", [[{
    "server": { "http_port": 27318, "game_port": 27315, "stop_with_game": true },
    "rcon": { "enabled": true, "password": "contract-pass-123" },
    "query": { "enabled": true, "interval_ms": 5000 },
    "admin": { "steam_ids": [] },
    "multipliers": { "xp": 2, "loot": 1.5, "stack_size": 1, "craft_efficiency": 1, "craft_cost": 1, "crop_speed": 1,
        "weight": 1, "inventory_size": 1, "points_per_level": 1, "cooking_speed": 2, "harvest_yield": 1 }
}]])
writeFile(game .. "\\R5\\ServerDescription.json", [[{
    "DeploymentId": "0.10.0.9.32-contract",
    "ServerDescription_Persistent": { "ServerName": "Contract Test Server", "InviteCode": "abc123ef",
        "IsPasswordProtected": false, "MaxPlayerCount": 8 }
}]])

-- ---------------------------------------------------------------- UE4SS and the mod's own globals
_G.LoopAsync = function() end
_G.ExecuteInGameThread = function(f) f() end
_G.ExecuteWithDelay = function() end
_G.RegisterHook = function() end
_G.NotifyOnNewObject = function() end
_G.StaticFindObject = function() return nil end
_G.FindFirstOf = function() return nil end
_G.WindrosePlus = {
    VERSION = "9.9.9-contract",
    _modules = {},
    state = { playerCount = 0 },
    _isConnected = function() return true end,
    isIdle = function() return false end,
    updatePlayerCount = function(n) WindrosePlus.state.playerCount = n end,
    setMode = function() end,
}

local function fstr(s) return { ToString = function() return s end } end
local function valid(t) t.IsValid = function() return true end; return t end
local function vec(x, y, z) return { X = x, Y = y, Z = z } end
local function actor(fullName, x, y, z)
    local a = valid({ loc = vec(x, y, z) })
    a.GetFullName = function() return fullName end
    a.K2_GetActorLocation = function(self) return self.loc end
    return a
end
local function player(name, id, x, y, z)
    local pawn = actor("BP_R5Character_C /Game/Maps/Main.Main:PersistentLevel.BP_R5Character_C_" .. id, x, y, z)
    local ps = valid({ PlayerNamePrivate = fstr(name), PlayerId = id })
    return valid({ PlayerState = ps, Pawn = pawn })
end

local world = { PlayerController = {}, Pawn = {}, R5MineralNode = {}, Actor = {}, GameState = {} }
_G.FindAllOf = function(class) return world[class] end

local function populate()
    -- one name with a non-English letter: data files are UTF-8
    world.PlayerController = { player("Jörg", 101, 12000.5, -34000.25, 150), player("Ana", 102, -5000, 8000, 210.75) }
    world.Pawn = {
        actor("BP_Creature_Crab_C /Game/Maps/Main.Main:PersistentLevel.BP_Creature_Crab_C_7", 1000, 2000, 30),
        actor("BP_Skeleton_C /Game/Maps/Main.Main:PersistentLevel.BP_Skeleton_C_3", -3000, 4000, 55),
    }
    world.R5MineralNode = { actor("BP_IronNode_C /Game/Maps/Main.Main:PersistentLevel.BP_IronNode_C_1", 500, 600, 70) }
    world.Actor = {
        actor("R5POIOverlapVolume /Game/Maps/Main.Main:PersistentLevel.POI|I|12|P3|v100|v-200|v30|987654|OSA|4", 15000, -22000, 40),
        actor("R5POIAudioVolume /Game/Maps/Main.Main:PersistentLevel.Audio|I|12|P3|v10|v20|v0|987654|OSA|5", 15100, -22100, 0),
        actor("BP_MarkerModel_Quest_C /Game/Maps/Main.Main:PersistentLevel.BP_MarkerModel_Quest_C_2", -8000, 9000, 12),
        actor("BP_Camp_Smuggler_C /Game/Maps/Main.Main:PersistentLevel.BP_Camp_Smuggler_C_1", 100, 100, 1),
    }
    local gs = valid({ ReplicatedWorldTimeSeconds = 4321.5 })
    world.GameState = { gs }
end

-- ---------------------------------------------------------------- the modules
local Config = require("modules.config")
local Events = require("modules.events")
local Query = require("modules.query")
local LiveMap = require("modules.livemap")
local POIScan = require("modules.poiscan")
local Admin = require("modules.admin")
local Rcon = require("modules.rcon")
WindrosePlus._modules = { Config = Config, Query = Query, LiveMap = LiveMap, Admin = Admin, Rcon = Rcon }

Config.init(game)
if Config.getGamePort == nil then
    Config.getGamePort = function() return Config.get("server", "game_port") end
end
Events.init(game)
Query.init(game, Config)
LiveMap.init(game, Config)
POIScan.init(game, Config)
Admin.init(Config, game)
Rcon.init(game, Config, Admin)
if not Config.isRconEnabled() then fail("the mod does not see RCON as on from the panel's windrose_plus.json") end

-- ---------------------------------------------------------------- an empty server first
Query._collectAndWrite(); Query.flushPendingWrite()
collect(data .. "\\server_status.json", "server_status.empty.json")
LiveMap._collectAndWrite(true, Query.getPlayers()); LiveMap.flushPendingWrite()
collect(data .. "\\livemap_data.json", "livemap_data.empty.json")

-- ---------------------------------------------------------------- two players, creatures, POIs
populate()
Query._collectAndWrite(); Query.flushPendingWrite()
collect(data .. "\\server_status.json", "server_status.json")
LiveMap._collectAndWrite(true, Query.getPlayers()); LiveMap.flushPendingWrite()
collect(data .. "\\livemap_data.json", "livemap_data.json")
do
    local text = readFile(data .. "\\livemap_data.json") or ""
    if not text:find('"name":"Crab"', 1, true) or not text:find('"name":"Skeleton"', 1, true) or text:find('/Game/', 1, true) then
        fail("creature names are not the last word of their class (BP_Creature_Crab_C -> Crab, BP_Skeleton_C -> Skeleton)")
    end
end
POIScan._scanAndWrite()
collect(data .. "\\pois.json", "pois.json")
collect(data .. "\\poi_discovered_classes.json", "poi_discovered_classes.json")
collect(data .. "\\commands.json", "commands.json")

-- when the game thread stops answering, the writers keep the files fresh in a degraded mode
Query._lastWrite = 0
Query.writeDegraded("execute_in_game_thread_starved")
collect(data .. "\\server_status.json", "server_status.degraded.json")
if LiveMap.writeDegraded then
    LiveMap._lastWrite = 0
    LiveMap.writeDegraded("execute_in_game_thread_starved")
    LiveMap.flushPendingWrite()
    collect(data .. "\\livemap_data.json", "livemap_data.degraded.json")
end

-- ---------------------------------------------------------------- a console command through the spool,
-- written the way a host panel writes it (cmd_api_<ms>_<hex>.json plus a line in pending_commands.txt)
local spool = data .. "\\rcon"
local id = "api_1761500000000_a1b2c3"
writeFile(spool .. "\\cmd_" .. id .. ".json", string.format(
    '{"id":"%s","command":"wp.version","args":[],"password":"contract-pass-123","timestamp":%d,"admin_user":"API"}',
    id, os.time()))
writeFile(spool .. "\\pending_commands.txt", "\239\187\191cmd_" .. id .. ".json\r\n")
collect(spool .. "\\cmd_" .. id .. ".json", "rcon_command.json")
Rcon._processCommands()
collect(spool .. "\\res_" .. id .. ".json", "rcon_response.json")
if readFile(spool .. "\\cmd_" .. id .. ".json") then fail("the command file was not removed after its answer") end
-- and one the dashboard server writes (cmd_ps_*), with a wrong password: answered, never run
local psId = "ps_1761500000001_0f0f0f"
writeFile(spool .. "\\cmd_" .. psId .. ".json", string.format(
    '{"id":"%s","command":"wp.status","args":[],"password":"wrong","timestamp":%d,"admin_user":"dashboard"}', psId, os.time()))
writeFile(spool .. "\\pending_commands.txt", "cmd_" .. psId .. ".json\r\n")
collect(spool .. "\\cmd_" .. psId .. ".json", "rcon_command.dashboard.json")
Rcon._processCommands()
collect(spool .. "\\res_" .. psId .. ".json", "rcon_response.refused.json")
Rcon._flushHistoryBuffer()
collect(data .. "\\console_history.json", "console_history.json")
collect(data .. "\\rcon_status.json", "rcon_status.json")

-- ---------------------------------------------------------------- the activity log
Events.record("player.join", { name = "Jörg", player_id = 101 })
Events.record("server.idle", {})
local logPath = data .. "\\logs\\" .. os.date("!%Y-%m-%d") .. ".log"
if not readFile(logPath) then logPath = data .. "\\" .. os.date("!%Y-%m-%d") .. ".log" end
collect(logPath, "activity.log")

-- ---------------------------------------------------------------- the panel's own file, as the mod read it
collect(game .. "\\windrose_plus.json", "windrose_plus.json")

if failed > 0 then print(failed .. " failed"); os.exit(1) end
print("contract samples written to " .. outDir)
