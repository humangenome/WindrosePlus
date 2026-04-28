-- WindrosePlus Events Module
-- Server activity log. Append-only JSONL, daily-rotated, survives restarts.
-- Path: windrose_plus_data\logs\YYYY-MM-DD.log
-- One JSON object per line: {ts, ts_unix, sid, ev, payload}.

local json = require("modules.json")
local Log = require("modules.log")

local Events = {}
Events._dir = nil
Events._enabled = false
Events._currentDay = nil
Events._currentPath = nil
Events._sessionId = nil

local function _probeWritable(path)
    local probe = path .. "\\.events_probe"
    local f = io.open(probe, "w")
    if f then f:close(); os.remove(probe); return true end
    return false
end

function Events.init(gameDir)
    Events._dir = gameDir .. "windrose_plus_data\\logs"
    math.randomseed(os.time())
    Events._sessionId = string.format("%08x-%06x", os.time(), math.random(0, 0xFFFFFF))

    if not _probeWritable(Events._dir) then
        local parent = gameDir .. "windrose_plus_data"
        if not _probeWritable(parent) then
            Log.warn("Events", "windrose_plus_data not writable — activity log disabled")
            return
        end
        -- logs\ subdir not creatable from Lua; fall back to parent so we still
        -- capture a record. install.ps1 creates the subdir on fresh installs.
        Events._dir = parent
        Log.warn("Events", "logs\\ subdir missing — falling back to " .. parent)
    end

    local path = Events._currentLogPath()
    local f = io.open(path, "a")
    if not f then
        Log.warn("Events", "Cannot open " .. path .. " — activity log disabled")
        return
    end
    f:close()
    Events._enabled = true
    Log.info("Events", "Activity log: " .. path .. " (session " .. Events._sessionId .. ")")
end

function Events._currentLogPath()
    local day = os.date("!%Y-%m-%d")
    if day ~= Events._currentDay then
        Events._currentDay = day
        Events._currentPath = Events._dir .. "\\" .. day .. ".log"
    end
    return Events._currentPath
end

-- Record an event. Best-effort — never throws, never blocks.
function Events.record(ev, payload)
    if not Events._enabled then return end
    local entry = {
        ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        ts_unix = os.time(),
        sid = Events._sessionId,
        ev = ev,
        payload = payload or {},
    }
    local ok, line = pcall(json.encode, entry)
    if not ok then return end
    local f = io.open(Events._currentLogPath(), "a")
    if not f then
        Events._enabled = false
        Log.warn("Events", "Lost write access — activity log disabled")
        return
    end
    -- Single write call so concurrent appends from the async heartbeat thread
    -- and the game-thread player.join callback don't interleave a partial line.
    f:write(line .. "\n")
    f:close()
end

function Events.isEnabled()
    return Events._enabled
end

function Events.getSessionId()
    return Events._sessionId
end

return Events
