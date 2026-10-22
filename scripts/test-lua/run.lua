-- Offline tests for the Lua mod (WindrosePlus/Scripts), with UE4SS stubbed.
-- Run from the repository root: lua5.4 scripts/test-lua/run.lua
-- The mod builds Windows paths with "\\"; on Linux those are plain characters in a
-- file name, so the tests create files with those exact names in a temp folder.

package.path = "./WindrosePlus/Scripts/?.lua;" .. package.path

local failed, passed = 0, 0
local function case(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("ok   " .. name)
    else failed = failed + 1; print("FAIL " .. name .. " : " .. tostring(err)) end
end
local function check(cond, msg) if not cond then error(msg, 2) end end

local function tempDir()
    local p = os.tmpname()
    os.remove(p)
    assert(os.execute('mkdir -p "' .. p .. '"'))
    return p
end
local function writeFile(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

-- UE4SS globals the modules touch while loading or registering.
_G.LoopAsync = function() end
_G.ExecuteInGameThread = function(f) f() end
_G.ExecuteWithDelay = function() end
_G.RegisterHook = function() end
_G.NotifyOnNewObject = function() end
_G.StaticFindObject = function() return nil end
_G.FindFirstOf = function() return nil end
_G.FindAllOf = function() return nil end
_G.WindrosePlus = { _modules = {}, state = {}, _isConnected = function() return true end }

-- ---------------------------------------------------------------- mods loader
local Mods = require("modules.mods")

local function freshMods(dir)
    Mods._modsDir = dir
    Mods._loaded = {}
    Mods._fileSnapshots = {}
end

case("mods: nothing is loaded without mods_registry.json", function()
    local d = tempDir()
    writeFile(d .. "\\good\\mod.json", '{"name":"Good","main":"init.lua"}')
    writeFile(d .. "\\good\\init.lua", "WP_TEST_GOOD = (WP_TEST_GOOD or 0) + 1")
    freshMods(d)
    Mods._scanAndLoad()
    check(Mods.getLoadedCount() == 0, "loaded " .. Mods.getLoadedCount())
end)

local modDir
case("mods: a folder listed in mods_registry.json loads", function()
    modDir = tempDir()
    writeFile(modDir .. "\\mods_registry.json", '["good"]')
    writeFile(modDir .. "\\good\\mod.json", '{"name":"Good","version":"1.0","main":"init.lua"}')
    writeFile(modDir .. "\\good\\init.lua", "WP_TEST_GOOD = (WP_TEST_GOOD or 0) + 1 -- abc\n")
    WP_TEST_GOOD = 0
    freshMods(modDir)
    Mods._scanAndLoad()
    Mods._takeSnapshot()
    check(Mods.getLoadedCount() == 1 and WP_TEST_GOOD == 1, "loaded " .. Mods.getLoadedCount() .. ", ran " .. tostring(WP_TEST_GOOD))
end)

case("mods: no change reported when nothing changed", function()
    check(Mods.checkForChanges() == false, "reported a change")
end)

case("mods: an edit that keeps the length and the first and last byte counts as a change", function()
    writeFile(modDir .. "\\good\\init.lua", "WP_TEST_GOOD = (WP_TEST_GOOD or 0) + 1 -- abd\n")
    check(Mods.checkForChanges() == true, "edit not noticed")
end)

case("mods: a main file named in mod.json is watched too", function()
    local d = tempDir()
    writeFile(d .. "\\mods_registry.json", '["other"]')
    writeFile(d .. "\\other\\mod.json", '{"name":"Other","main":"start.lua"}')
    writeFile(d .. "\\other\\start.lua", "WP_TEST_OTHER = 1 -- x")
    freshMods(d)
    Mods._scanAndLoad()
    Mods._takeSnapshot()
    check(Mods.getLoadedCount() == 1, "not loaded")
    writeFile(d .. "\\other\\start.lua", "WP_TEST_OTHER = 1 -- y")
    check(Mods.checkForChanges() == true, "edit to start.lua not noticed")
end)

-- ---------------------------------------------------------------- wp.tp
local Admin = require("modules.admin")

local function fstr(s) return { ToString = function() return s end } end
local function valid(t) t.IsValid = function() return true end; return t end
local function player(name, id)
    local pawn = valid({ loc = { X = 0, Y = 0, Z = 100 } })
    pawn.GetFullName = function() return "BP_R5Character_C /Game/Maps/Main.Main:PersistentLevel.BP_R5Character_C_" .. id end
    pawn.K2_GetActorLocation = function(self) return self.loc end
    pawn.K2_SetActorLocation = function(self, l) self.loc = { X = l.X, Y = l.Y, Z = l.Z }; self.moved = true; return true end
    local ps = valid({ PlayerNamePrivate = fstr(name), PlayerId = id })
    return valid({ PlayerState = ps, Pawn = pawn })
end

local online = {}
_G.FindAllOf = function(class) if class == "PlayerController" then return online end return nil end

local gameDir = tempDir() .. "/"
assert(os.execute('mkdir -p "' .. gameDir .. 'windrose_plus_data"'))
local cfgStub = setmetatable({}, { __index = function() return function() return nil end end })
pcall(Admin.init, cfgStub, gameDir)
if not Admin._commands["wp.tp"] then Admin._registerCommands() end

local function moved(p) return p.Pawn.moved == true end
local function reset() for _, p in ipairs(online) do p.Pawn.moved = nil end end

case("wp.tp: x y z with no name and two players online moves nobody", function()
    online = { player("Alice", 1), player("Bob", 2) }
    local status, msg = Admin.execute("wp.tp", { "100", "200", "300" })
    check(not moved(online[1]) and not moved(online[2]), "a player was moved: " .. tostring(msg))
    check(tostring(msg):find("2 players are online", 1, true), "message: " .. tostring(msg))
end)

case("wp.tp: x y with no name and two players online moves nobody", function()
    reset()
    Admin.execute("wp.tp", { "100", "200" })
    check(not moved(online[1]) and not moved(online[2]), "a player was moved")
end)

case("wp.tp: all x y z moves everyone", function()
    reset()
    Admin.execute("wp.tp", { "all", "100", "200", "300" })
    check(moved(online[1]) and moved(online[2]), "not everyone moved")
    check(online[2].Pawn.loc.Z == 300, "z " .. tostring(online[2].Pawn.loc.Z))
end)

case("wp.tp: a named player moves alone", function()
    reset()
    Admin.execute("wp.tp", { "Alice", "5", "6", "7" })
    check(moved(online[1]) and not moved(online[2]), "wrong players moved")
end)

case("wp.tp: with one player online no name is needed", function()
    online = { player("Solo", 3) }
    Admin.execute("wp.tp", { "100", "200" })
    check(moved(online[1]) and online[1].Pawn.loc.Z == 100, "not moved, or z changed")
end)

-- ---------------------------------------------------------------- wp.status / wp.kick
case("wp.status lists cooking speed and harvest yield", function()
    online = {}
    local cfg = {}
    for _, k in ipairs({"Loot", "Xp", "StackSize", "CraftEfficiency", "CropSpeed", "Weight", "CookingSpeed", "HarvestYield"}) do
        cfg["get" .. k .. "Multiplier"] = function() return 2 end
    end
    local saved = Admin._config
    Admin._config = cfg
    local _, msg = Admin.execute("wp.status", {})
    Admin._config = saved
    check(tostring(msg):find("Cooking Speed: 2x", 1, true) and tostring(msg):find("Harvest Yield: 2x", 1, true), tostring(msg))
end)

case("wp.kick finds a player name with spaces", function()
    online = { player("Some Player", 7) }
    local status, msg = Admin.execute("wp.kick", { "Some", "Player", "griefing", "the", "dock" })
    check(tostring(msg):find("Some Player was not kicked", 1, true), tostring(msg))
end)

case("wp.kick takes a quoted name when nobody online matches", function()
    online = {}
    local _, msg = Admin.execute("wp.kick", { '"Gone', 'Player"', "reason" })
    check(tostring(msg):find("Gone Player was not kicked", 1, true), tostring(msg))
end)

-- ---------------------------------------------------------------- json
case("json: NaN and infinity are written as null", function()
    local json = require("modules.json")
    local out = json.encode({ x = 0/0, y = math.huge, z = 1.5 })
    check(out:find('"x":null', 1, true) and out:find('"y":null', 1, true) and out:find('"z":1.5', 1, true), out)
end)

-- ---------------------------------------------------------------- RCON spool
local Rcon = require("modules.rcon")
local spool = tempDir()
local enabled = true
Rcon._spoolDir = spool
Rcon._gameDir = tempDir() .. "/"
Rcon._config = {
    reload = function() end,
    getRconPassword = function() return "secret-pass" end,
    isRconEnabled = function() return enabled end,
}
local ran = {}
Rcon._admin = { execute = function(cmd, args) ran[#ran + 1] = cmd; return "ok", "done " .. cmd end }
local function readFile(path) local f = io.open(path, "rb"); if not f then return nil end; local t = f:read("a"); f:close(); return t end
local function queue(names) writeFile(spool .. "\\pending_commands.txt", table.concat(names, "\r\n") .. "\r\n") end

case("rcon: a pending line that is a path is ignored and its target survives", function()
    local victim = spool .. "\\..\\victim.txt"
    writeFile(victim, "keep me")
    queue({ "..\\victim.txt" })
    Rcon._processCommands()
    check(readFile(victim) == "keep me", "the file named in the line was deleted")
end)

case("rcon: a command runs when RCON is on and the password matches", function()
    ran = {}
    writeFile(spool .. "\\cmd_t1.json", '{"id":"t1","command":"wp.ping","password":"secret-pass"}')
    queue({ "cmd_t1.json" })
    Rcon._processCommands()
    check(#ran == 1 and (readFile(spool .. "\\res_t1.json") or ""):find('"status":"ok"', 1, true), "did not run: " .. tostring(readFile(spool .. "\\res_t1.json")))
end)

case("rcon: with rcon.enabled off a matching password runs nothing", function()
    ran = {}
    enabled = false
    writeFile(spool .. "\\cmd_t2.json", '{"id":"t2","command":"wp.ping","password":"secret-pass"}')
    queue({ "cmd_t2.json" })
    Rcon._processCommands()
    enabled = true
    check(#ran == 0, "the command ran")
    check((readFile(spool .. "\\res_t2.json") or ""):find("RCON is off", 1, true), tostring(readFile(spool .. "\\res_t2.json")))
end)

case("rcon: a command that is not text gets an error, not a retry loop", function()
    ran = {}
    writeFile(spool .. "\\cmd_t3.json", '{"id":"t3","command":123,"password":"secret-pass"}')
    queue({ "cmd_t3.json" })
    Rcon._processCommands()
    check(readFile(spool .. "\\cmd_t3.json") == nil, "the command file is still there")
    check((readFile(spool .. "\\res_t3.json") or ""):find("Malformed command", 1, true), tostring(readFile(spool .. "\\res_t3.json")))
    check(readFile(spool .. "\\pending_commands.txt") == nil, "it was queued again")
end)

-- ---------------------------------------------------------------- config reload hook
case("config: listeners run after a changed file that parsed, not after a broken one", function()
    local Config = require("modules.config")
    local cfgDir = tempDir()
    Config._path = cfgDir .. "\\windrose_plus.json"
    Config._lastContent, Config._changeListeners = nil, {}
    writeFile(Config._path, '{"rcon":{"enabled":true}}')
    Config.reload()
    local calls = 0
    Config.onChange(function() calls = calls + 1 end)
    writeFile(Config._path, '{"rcon":{"enabled":tr')
    Config.reload()
    check(calls == 0, "a broken file called the listeners")
    writeFile(Config._path, '{"rcon":{"enabled":true},"query":{"enabled":true}}')
    Config.reload()
    check(calls == 1, "the next good save did not call them (" .. calls .. ")")
    Config.reload()
    check(calls == 1, "an unchanged reload called them again")
end)

-- ---------------------------------------------------------------- writer switches (main.lua)
case("main: livemap.enabled / poiscan.enabled = false switch the writers off", function()
    local f = assert(io.open("WindrosePlus/Scripts/main.lua", "rb")); local text = f:read("a"); f:close()
    local line = text:match("(local function _writerEnabled%(f%)[^\n]*)")
    check(line, "_writerEnabled not found in main.lua")
    check(text:find("_liveMapEnabled = _writerEnabled(Config.isLiveMapEnabled)", 1, true), "livemap does not use it")
    check(text:find("_poiScanEnabled = _writerEnabled(Config.isPOIScanEnabled)", 1, true), "poiscan does not use it")
    local w = assert(load(line .. " return _writerEnabled"))()
    check(w(function() return false end) == false, "false read as on")
    check(w(function() return true end) == true, "true read as off")
    check(w(nil) == true, "a missing function is not on")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
