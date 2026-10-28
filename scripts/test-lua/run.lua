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

-- deferred answers: the handler returns { deferred = token } and answers later through Rcon.completeDeferred
local Events = require("modules.events")
local records = {}
local realRecord = Events.record
Events.record = function(_, rec) records[#records + 1] = rec end
local deferredToken = "mymod:1"
Rcon._admin = { execute = function(cmd) ran[#ran + 1] = cmd; return "deferred", deferredToken, { timeout = 30 } end }

case("rcon: a deferred command answers later, capped at 10 s, and gets its activity record then", function()
    ran, records = {}, {}
    writeFile(spool .. "\\cmd_d1.json", '{"id":"d1","command":"wp.later","password":"secret-pass"}')
    queue({ "cmd_d1.json" })
    Rcon._processCommands()
    local d = Rcon._deferred[deferredToken]
    check(d and readFile(spool .. "\\res_d1.json") == nil, "answered or dropped right away")
    check(d.expires - d.started <= 10, "timeout not capped at 10 s: " .. (d.expires - d.started))
    check(#records == 0, "recorded before the answer")
    check(Rcon.completeDeferred(deferredToken, true, "later done") == true, "completeDeferred refused")
    check((readFile(spool .. "\\res_d1.json") or ""):find("later done", 1, true), tostring(readFile(spool .. "\\res_d1.json")))
    check(#records == 1 and records[1].status == "ok" and records[1].command == "wp.later", "no activity record on answer")
end)

case("rcon: a second command with a pending token is refused, the first still answers", function()
    ran, records = {}, {}
    writeFile(spool .. "\\cmd_d2.json", '{"id":"d2","command":"wp.later","password":"secret-pass"}')
    queue({ "cmd_d2.json" })
    Rcon._processCommands()
    writeFile(spool .. "\\cmd_d3.json", '{"id":"d3","command":"wp.later","password":"secret-pass"}')
    queue({ "cmd_d3.json" })
    Rcon._processCommands()
    check((readFile(spool .. "\\res_d3.json") or ""):find("same deferred token", 1, true), tostring(readFile(spool .. "\\res_d3.json")))
    check(Rcon.completeDeferred(deferredToken, "ok", "first") == true, "the first command lost its slot")
    check((readFile(spool .. "\\res_d2.json") or ""):find("first", 1, true), tostring(readFile(spool .. "\\res_d2.json")))
    check(#records == 2, "expected records for the refusal and the answer, got " .. #records)
end)

case("rcon: a timed-out deferred command gets its activity record", function()
    records = {}
    Rcon._deferred["mymod:t"] = { finish = function() end, id = "dt", command = "wp.slow", resolved = "wp.slow",
                                  admin = "test", started = os.time() - 10, expires = os.time() - 1 }
    local d = Rcon._deferred["mymod:t"]; Rcon._deferred["mymod:t"] = nil
    Rcon._answerDeferred(d, "error", "No answer in time")
    check(#records == 1 and records[1].status == "error" and records[1].message == "No answer in time", "no record on timeout")
end)
Events.record = realRecord

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

-- ---------------------------------------------------------------- subcommands (admin.lua)
-- Own command table for these cases; the built-in commands registered above are restored afterwards.
local savedCommands, savedGameDir = Admin._commands, Admin._gameDir
Admin._commands = {}
Admin._gameDir = tempDir() .. "/"
local subCalls = {}
Admin.register("wp.give", nil, "Spawn items through palms or bushes", nil, {
    category = "admin",
    subcommands = {
        { name = "item", usage = "<player> <item> [count]", description = "Arm a palm",
          handler = function(args, caller) subCalls[#subCalls + 1] = { args, caller }; return "armed " .. tostring(args[2]) end },
        { name = "status", description = "Armed palms", handler = function() return "nothing armed" end },
        { name = "list items", usage = "<filter>", description = "Find item names",
          handler = function(args) return "items matching " .. tostring(args[1]) end },
        { name = "list tables", usage = "<filter>", description = "Find loot tables",
          handler = function(args) return "tables matching " .. tostring(args[1]) end },
        { name = "later", description = "Deferred", handler = function() return { deferred = "t1", timeout = 3 } end },
        { name = "boom", description = "Fails", handler = function() error("kaputt") end },
    },
})
-- subcommands without handlers: the main handler gets every call
Admin.register("wp.yield", function(args) return "main " .. table.concat(args, " ") end, "Gathering yield", nil, {
    subcommands = { { name = "set", usage = "<factor>", description = "Set the factor" }, { name = "off", description = "Off" } },
})
Admin.register("wp.status", function() return "status ok" end, "Show server status", "wp.status")
local function answer(cmd, args) return select(2, Admin.execute(cmd, args)) end

case("subcommands: dispatch, caller, case, two words, longest match", function()
    local st, msg = Admin.execute("wp.give", { "item", "Dummy", "Wood", "5" }, { accountId = "ACC-ONE" })
    check(st == "ok" and msg == "armed Wood" and subCalls[1][1][1] == "Dummy", "sub handler did not get the words after it")
    check(subCalls[1][2].accountId == "ACC-ONE", "caller did not reach the sub handler")
    check(answer("wp.give", { "STATUS" }) == "nothing armed", "match is not case-insensitive")
    check(answer("wp.give", { "list", "tables", "palm" }) == "tables matching palm", "two-word subcommand")
    check(answer("wp.give", { "list", "items", "iron" }) == "items matching iron", "longest match")
end)

case("subcommands: bare command lists them, unknown ones are errors with the list", function()
    local st, msg = Admin.execute("wp.give", { "list" })
    check(st == "error" and msg:find("Unknown subcommand: wp.give list"), "first word alone matched")
    st, msg = Admin.execute("wp.give", {})
    check(st == "ok" and msg:find("^wp.give %- Spawn items") and msg:find("wp.give list tables <filter>"), "no list: " .. tostring(msg))
    st, msg = Admin.execute("wp.give", { "nope" })
    check(st == "error" and msg:find("Unknown subcommand: wp.give nope") and msg:find("wp.give status"), "no error list")
end)

case("subcommands: deferred, errors, short name, main handler fallback, old-style commands", function()
    local st, msg, opts = Admin.execute("wp.give", { "later" })
    check(st == "deferred" and msg == "t1" and opts.timeout == 3, "deferred lost")
    st, msg = Admin.execute("give", { "boom" })
    check(st == "error" and msg:find("kaputt"), "short name or handler error")
    check(answer("wp.yield", { "set", "2" }) == "main set 2", "main handler fallback")
    check(answer("wp.status", { "x" }) == "status ok", "old-style command changed")
end)

case("subcommands: generated usage and aligned help", function()
    check(Admin._commands["wp.give"].usage == "wp.give <item|status|list|later|boom>", Admin._commands["wp.give"].usage)
    local help = Admin.helpText("wp.give", Admin._commands["wp.give"])
    check(help:find("\n  wp.give item <player> <item> %[count%]  +Arm a palm") and help:find("\n  wp.give status +Armed palms"), help)
    check(Admin.helpText("wp.status", Admin._commands["wp.status"]) == "wp.status - Show server status\nUsage: wp.status", "old-style help changed")
    Admin.register("wp.ex", nil, "With examples", nil, { subcommands = { { name = "a", handler = function() return "a" end } }, examples = { "wp.ex a   does a" } })
    check(answer("wp.ex", {}):find("\nExamples:\n  wp.ex a   does a", 1, true), "examples missing")
end)

case("subcommands: setSubcommands describes, keeps the handler", function()
    check(Admin.setSubcommands("wp.none", { { name = "x" } }) == false, "unknown command accepted")
    check(Admin.setSubcommands("wp.status", { { name = "full", description = "everything", handler = function() return "hijacked" end } }) == true, "refused")
    check(answer("wp.status", { "full" }) == "status ok" and answer("wp.status", {}) == "status ok", "handler replaced")
    check(Admin.helpText("wp.status", Admin._commands["wp.status"]):find("wp.status full +everything"), "tree missing in help")
end)

case("subcommands: commands.json lists them without handlers", function()
    Admin.writeCommandsJson()
    local f = io.open(Admin._gameDir .. "windrose_plus_data\\commands.json", "r")
    local data = f and require("modules.json").decode(f:read("a")); if f then f:close() end
    local give
    for _, c in ipairs(data and data.commands or {}) do if c.name == "wp.give" then give = c end end
    check(give and give.usage == "wp.give <item|status|list|later|boom>" and give.description:find("Spawn"), "usage/description")
    check(#give.subcommands == 6 and give.subcommands[3].name == "list items" and give.subcommands[3].usage == "<filter>", "subcommands")
    check(give.subcommands[1].handler == nil, "handler in the file")
end)

case("subcommands: names are trimmed and lowered, bad entries dropped", function()
    local subs = Admin.normalizeSubcommands({ { name = "  Lapse   Stop " }, { name = "" }, "x", { usage = "no name" } })
    check(subs and #subs == 1 and subs[1].name == "lapse stop" and #subs[1].words == 2, "normalize")
    check(Admin.normalizeSubcommands({}) == nil, "empty list")
end)
Admin._commands, Admin._gameDir = savedCommands, savedGameDir

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

-- ---------------------------------------------------------------- event bus
local Bus = require("modules.eventbus")
local loops = {}
local realLoopAsync = _G.LoopAsync
_G.LoopAsync = function(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } end
Bus.configure(100, function() return false end)

case("events: API.emit reaches handlers at once, without a source or a poll loop", function()
    local got
    local sub = Bus.on("test.ping", function(p, meta) got = { p = p, meta = meta } end)
    Bus.emit("test.ping", { n = 1 }, "lua")
    sub.cancel()
    check(got and got.p.n == 1 and got.meta.source == "lua", "handler not called")
    check(#loops == 0, "a poll loop started without a source")
end)

case("events: the first registered source starts the poll loop, once", function()
    local queue = { { ev = "test.native", seq = 7, ts = 1, value = "x" } }
    local seen
    Bus.on("test.native", function(p, meta) seen = { p = p, meta = meta } end)
    Bus.registerSource("TestSource", function() local q = queue; queue = {}; return q, 0 end, { version = "1.0" })
    check(#loops == 1 and loops[1].ms == 100, "loop not started at the configured interval")
    Bus.registerSource("TestSource", function() local q = queue; queue = {}; return q, 0 end)
    check(#loops == 1, "registering the same name again started a second loop")
    loops[1].fn()
    check(seen and seen.p.value == "x" and seen.meta.source == "native" and seen.meta.seq == 7, "event not delivered")
    check(seen.p.ev == nil and seen.p.seq == nil, "bookkeeping fields left in the payload")
    local info = Bus.list()
    check(#info.sources == 1 and info.sources[1].name == "TestSource", "source not listed once")
end)

case("events: a source's dropped count becomes events.dropped", function()
    local dropped
    Bus.on("events.dropped", function(p) dropped = p end)
    Bus.registerSource("TestSource", function() return {}, 3 end)
    loops[1].fn()
    check(dropped and dropped.count == 3 and dropped.source == "TestSource", "events.dropped missing")
end)
_G.LoopAsync = realLoopAsync

-- ---------------------------------------------------------------- terrain guard (modules/terrain.lua)
-- The HeightmapExporter rewrites terrain_v17.json on every export; one taken in the lobby
-- (no world loaded) is 74 bytes with no landscape pieces. A test server lost its good
-- terrain to one on 2026-10-12. The samples are the contract's own (scripts/contract/samples).
local Terrain = require("modules.terrain")
local function readFile(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("a"); f:close(); return t
end
local GOOD_TERRAIN = assert(readFile("scripts/contract/samples/terrain_v17.json"))
local EMPTY_TERRAIN = assert(readFile("scripts/contract/samples/terrain_v17.empty.json"))
local GOOD_TERRAIN_2 = GOOD_TERRAIN:gsub('"maxZ":3120.25', '"maxZ":3333.5')

case("terrain: the lobby export counts as no terrain, a real export counts", function()
    check(#EMPTY_TERRAIN < 200 and not Terrain.textLooksValid(EMPTY_TERRAIN), "the empty export counted as terrain")
    check(Terrain.textLooksValid(GOOD_TERRAIN), "a real export did not count")
    check(not Terrain.looksValid(tempDir() .. "\\nothing.json"), "a missing file counted")
end)

case("terrain: an empty export never replaces a good terrain file", function()
    local dir = tempDir()
    writeFile(Terrain.path(dir), GOOD_TERRAIN)
    check(Terrain.keepGood(dir), "no good copy kept before the export")
    writeFile(Terrain.path(dir), EMPTY_TERRAIN)            -- the exporter, in the lobby
    check(Terrain.restoreGood(dir), "the good terrain was not put back")
    check(readFile(Terrain.path(dir)) == GOOD_TERRAIN, "the terrain file is not the good one")
    check(readFile(Terrain.path(dir) .. ".tmp") == nil, "a .tmp file was left")
end)

case("terrain: an empty export never becomes the good copy", function()
    local dir = tempDir()
    writeFile(Terrain.path(dir), GOOD_TERRAIN)
    Terrain.keepGood(dir)
    writeFile(Terrain.path(dir), EMPTY_TERRAIN)
    check(Terrain.keepGood(dir), "keepGood forgot the good copy")
    check(readFile(Terrain.goodPath(dir)) == GOOD_TERRAIN, "the empty export was kept as the good copy")
end)

case("terrain: a new real export becomes the good copy and is left alone", function()
    local dir = tempDir()
    writeFile(Terrain.path(dir), GOOD_TERRAIN)
    Terrain.keepGood(dir)
    writeFile(Terrain.path(dir), GOOD_TERRAIN_2)
    check(not Terrain.restoreGood(dir), "a real export was replaced")
    check(readFile(Terrain.path(dir)) == GOOD_TERRAIN_2, "the new export was changed")
    Terrain.keepGood(dir)
    check(readFile(Terrain.goodPath(dir)) == GOOD_TERRAIN_2, "the good copy is still the old export")
end)

case("terrain: with no good copy an empty export stays until the next player's export", function()
    local dir = tempDir()
    writeFile(Terrain.path(dir), EMPTY_TERRAIN)
    check(not Terrain.keepGood(dir), "a good copy appeared from nothing")
    check(not Terrain.restoreGood(dir), "restoreGood claimed a restore")
    check(readFile(Terrain.path(dir)) == EMPTY_TERRAIN, "the file was changed")
end)

case("terrain: main.lua keeps the good copy before every export and puts it back after an empty one", function()
    local src = assert(readFile("WindrosePlus/Scripts/main.lua"))
    local fn = src:match("local function requestTerrainExport%(reason%)(.-)\nend\n")
    check(fn, "requestTerrainExport not found")
    local keep, done = fn:find("Terrain.keepGood%(dir%)"), fn:find("export_heightmap_done")
    check(keep and done and keep < done, "keepGood does not run before the old export is cleared")
    check(fn:find('reason == "world%-changed"') and fn:find("os.remove%(Terrain.goodPath%(dir%)%)"), "a world change keeps the old world's terrain as the good copy")
    local gen = src:match("local function checkAndTriggerTileGen%(%)(.-)\nend\n")
    check(gen and select(2, gen:gsub("Terrain.restoreGood%(dir%)", "")) == 2, "restoreGood is not called after an export and at boot")
    check(src:find('os.remove%(mapDataDir%(%) .. "\\\\export_heightmap_trigger"%)'), "a trigger left from before a restart is not removed at load")
    check(not src:find('raw:find%(\'"h":1\''), "main.lua still has its own copy of the terrain check")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
