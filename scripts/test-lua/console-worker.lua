-- One pass of the mod's real console worker over a game folder's command files: modules/rcon.lua with the real
-- admin.lua, config.lua and events.lua, UE4SS stubbed, and one made-up player whose address and account IDs are
-- known (scripts/Test-DashboardConsole.ps1 looks for them in the answers). That test runs the real dashboard
-- server on the same folder, so a command sent to the dashboard goes through the same files and code as on a server.
-- Run: lua scripts/test-lua/console-worker.lua <game folder>
local gameDir = assert(arg[1], "usage: console-worker.lua <game folder>")
local repo = (arg[0]:match("^(.-)[\\/]?scripts[\\/]test%-lua[\\/]console%-worker%.lua$") or ".")
if repo == "" then repo = "." end
package.path = repo .. "/WindrosePlus/Scripts/?.lua;" .. package.path

-- The mod writes Windows paths. On Linux, where this can be tried by hand, they are turned into real folders;
-- on Windows (CI) nothing changes.
if package.config:sub(1, 1) == "/" then
    local function fix(p) return type(p) == "string" and (p:gsub("\\", "/")) or p end
    local open, remove, rename = io.open, os.remove, os.rename
    io.open = function(p, m) return open(fix(p), m) end
    os.remove = function(p) return remove(fix(p)) end
    os.rename = function(a, b) return rename(fix(a), fix(b)) end
end
if not gameDir:match("[\\/]$") then gameDir = gameDir .. "\\" end

local IDENTITY = {
    ip = "203.0.113.7",
    steam = "76561198000000002",
    epic = "0123456789abcdef0123456789abcdef",
}

local function fstr(s) return { ToString = function() return s end } end
local function valid(t) t.IsValid = function() return true end; return t end
local playerState = valid({
    GetFullName = function() return "R5PlayerState /Game/Maps/Main.Main:PersistentLevel.R5PlayerState_1" end,
    PlayerNamePrivate = fstr("Alice"), PlayerId = 7,
    SavedNetworkAddress = fstr(IDENTITY.ip .. ":7777"), UniqueId = fstr("STEAM:" .. IDENTITY.steam),
    EpicAccountId = fstr(IDENTITY.epic),
})
local controller = valid({ GetFullName = function() return "PlayerController_1" end, NetPlayerIndex = 0 })
local gameMode = valid({ XPMultiplier = 2, SavedNetworkAddress = IDENTITY.ip, ServerNote = "admin at " .. IDENTITY.ip })

_G.LoopAsync = function() end
_G.ExecuteInGameThread = function(f) f() end
_G.ExecuteWithDelay = function() end
_G.RegisterHook = function() end
_G.NotifyOnNewObject = function() end
_G.StaticFindObject = function() return nil end
_G.FindFirstOf = function() return nil end
_G.FindAllOf = function(class)
    if class == "R5PlayerState" then return { playerState } end
    if class == "PlayerController" then return { controller } end
    if class == "R5GameMode" then return { gameMode } end
    return nil
end
_G.WindrosePlus = { VERSION = "test", _modules = {}, state = {}, _isConnected = function() return true end,
                    isIdle = function() return false end }

local Events = require("modules.events")
local Config = require("modules.config")
local Admin = require("modules.admin")
local Rcon = require("modules.rcon")
pcall(Events.init, gameDir)
Config.init(gameDir)
Admin.init(Config, gameDir)
Rcon.init(gameDir, Config, Admin)
Rcon._processCommands()
Rcon._flushHistoryBuffer()
