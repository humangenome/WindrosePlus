-- WindrosePlus Event Bus
-- Lets add-ons subscribe to game events:
--
--   local sub = WindrosePlus.API.on("ship.captain", function(payload, meta) ... end)
--   sub.cancel()
--
-- Events come from two places:
--   * Lua (API.emit, e.g. player.join / player.leave from the Query diff), dispatched right away
--   * registered event sources: an optional native (C++) mod captures events in native hooks on the game thread and
--     queues them; its Lua side registers a poll function with API.registerEventSource(name, poll), and this module
--     drains it from its own LoopAsync.
--
-- Handlers always run on the LoopAsync (async) thread, never inside game hooks: running Lua in a hook while loops
-- run in the same Lua state is not serialized by UE4SS and can crash the server. Native events therefore reach
-- handlers with a delay of up to one poll interval, in order and without loss (bounded queue; overflow is
-- reported as "events.dropped").

local Log = require("modules.log")

local Bus = {}

local POLL_MS_DEFAULT = 100
local POLL_MS_MIN = 50
local IDLE_POLL_MS = 500
local MAX_PER_DRAIN = 500
local MAX_CONSECUTIVE_ERRORS = 10
local WARN_INTERVAL_S = 60

local _subs = {}            -- event name -> list of subscriber records
local _nextId = 0
local _seq = 0
local _gen = 0              -- bumped on every startLoop(); old loops stop when it changes
local _stats = { emitted = 0, native = 0, dropped = 0, handler_errors = 0, poll_errors = 0 }
local _sources = {}         -- list of { name, poll, version, errors, lastWarn, owner }
local _cfg = { pollMs = POLL_MS_DEFAULT, isIdle = nil }

-- Name of the add-on currently being loaded (set by the Mods loader) for attribution in logs
Bus.currentOwner = nil

local function warn(sub, msg)
    local now = os.time()
    if now - (sub.lastWarn or 0) >= WARN_INTERVAL_S then
        sub.lastWarn = now
        Log.warn(sub.owner or "Events", msg)
    end
end

--- Subscribe to an event. Returns a handle with cancel().
-- opts.key: re-subscribing with the same owner, event and key replaces the old subscriber (reload safety)
-- opts.source: owner name for logs (defaults to the add-on being loaded)
function Bus.on(ev, fn, opts)
    if type(ev) ~= "string" or ev == "" then error("API.on: event name must be a string", 2) end
    if type(fn) ~= "function" then error("API.on: handler must be a function", 2) end
    opts = type(opts) == "table" and opts or {}

    local list = _subs[ev]
    if not list then list = {}; _subs[ev] = list end

    local owner = opts.source or Bus.currentOwner or "?"
    if opts.key ~= nil then
        for i = #list, 1, -1 do
            local s = list[i]
            if s.key == opts.key and s.owner == owner then
                s.cancelled = true
                table.remove(list, i)
            end
        end
    end

    _nextId = _nextId + 1
    local sub = { id = _nextId, event = ev, fn = fn, owner = owner, key = opts.key, once = opts.once and true or false,
                  calls = 0, errors = 0, consecutiveErrors = 0, cancelled = false }
    function sub.cancel()
        if sub.cancelled then return end
        sub.cancelled = true
        local l = _subs[ev]
        if not l then return end
        for i = #l, 1, -1 do
            if l[i] == sub then table.remove(l, i) end
        end
    end
    table.insert(list, sub)
    return sub
end

function Bus.once(ev, fn, opts)
    opts = type(opts) == "table" and opts or {}
    opts.once = true
    return Bus.on(ev, fn, opts)
end

local function dispatch(ev, payload, meta)
    local list = _subs[ev]
    if not list or #list == 0 then return end
    -- Copy first: handlers may subscribe or cancel during dispatch
    local snapshot = {}
    for i, s in ipairs(list) do snapshot[i] = s end
    for _, sub in ipairs(snapshot) do
        if not sub.cancelled and type(sub.fn) == "function" then
            if sub.once then sub.cancel() end
            sub.calls = sub.calls + 1
            local ok, err = pcall(sub.fn, payload, meta)
            if ok then
                sub.consecutiveErrors = 0
            else
                sub.errors = sub.errors + 1
                sub.consecutiveErrors = sub.consecutiveErrors + 1
                _stats.handler_errors = _stats.handler_errors + 1
                warn(sub, string.format("handler for '%s' failed: %s", ev, tostring(err)))
                if sub.consecutiveErrors >= MAX_CONSECUTIVE_ERRORS then
                    Log.error(sub.owner or "Events",
                        string.format("handler for '%s' disabled after %d consecutive errors", ev, sub.consecutiveErrors))
                    sub.cancel()
                end
            end
        end
    end
end

--- Emit an event from Lua. payload must be a plain table (no UObjects).
function Bus.emit(ev, payload, source)
    _seq = _seq + 1
    _stats.emitted = _stats.emitted + 1
    dispatch(ev, payload or {}, { ev = ev, ts_unix = os.time(), seq = _seq, source = source or "lua" })
end

--- Snapshot of subscriptions, sources and counters, e.g. for a debug command.
function Bus.list()
    local out = { events = {}, stats = {}, sources = {} }
    for ev, list in pairs(_subs) do
        local owners = {}
        for _, s in ipairs(list) do owners[#owners + 1] = s.owner end
        out.events[ev] = owners
    end
    for k, v in pairs(_stats) do out.stats[k] = v end
    for _, src in ipairs(_sources) do
        out.sources[#out.sources + 1] = { name = src.name, version = src.version, owner = src.owner, errors = src.errors }
    end
    return out
end

-- Drain one source: poll(max) returns { {ev=, seq=, ts=, ...payload fields}, ... } plus the number of events the
-- source had to drop since the last poll.
local function drainSource(src)
    local ok, events, dropped = pcall(src.poll, MAX_PER_DRAIN)
    if not ok then
        src.errors = src.errors + 1
        _stats.poll_errors = _stats.poll_errors + 1
        warn(src, string.format("event source '%s' failed (%d so far): %s", src.name, src.errors, tostring(events)))
        return
    end
    if type(dropped) == "number" and dropped > 0 then
        _stats.dropped = _stats.dropped + dropped
        Bus.emit("events.dropped", { count = dropped, source = src.name }, "native")
    end
    if type(events) ~= "table" then return end
    for _, e in ipairs(events) do
        local ev = e.ev
        if type(ev) == "string" then
            _stats.native = _stats.native + 1
            local meta = { ev = ev, ts_unix = e.ts or os.time(), seq = e.seq, source = "native" }
            e.ev, e.seq, e.ts = nil, nil, nil
            _seq = _seq + 1
            dispatch(ev, e, meta)
        end
    end
end

local function startLoop()
    local pollMs = _cfg.pollMs
    _gen = _gen + 1
    local myGen = _gen
    if type(LoopAsync) ~= "function" then
        Log.warn("Events", "LoopAsync not available, event sources are not polled")
        return
    end
    local idleEvery = math.max(1, math.floor(IDLE_POLL_MS / pollMs))
    local tick = 0
    LoopAsync(pollMs, function()
        if myGen ~= _gen then return true end
        tick = tick + 1
        local ok, err = pcall(function()
            -- Nobody online: poll every IDLE_POLL_MS only (the sources' queues stay bounded meanwhile)
            if type(_cfg.isIdle) == "function" and _cfg.isIdle() and tick % idleEvery ~= 0 then return end
            for _, src in ipairs(_sources) do drainSource(src) end
        end)
        if not ok then Log.warn("Events", "drain failed: " .. tostring(err)) end
        return false
    end)
    Log.info("Events", string.format("polling event sources every %d ms", pollMs))
end

--- Poll interval (events.poll_ms) and an optional isIdle() that slows polling while nobody is online.
function Bus.configure(pollMs, isIdle)
    _cfg.pollMs = math.max(POLL_MS_MIN, tonumber(pollMs) or POLL_MS_DEFAULT)
    _cfg.isIdle = isIdle
end

--- Register an event source, e.g. the Lua side of a native mod: poll(max) returns queued events and a dropped count.
-- Registering the same name again replaces it. opts.version: shown in API.listEvents.
function Bus.registerSource(name, poll, opts)
    if type(name) ~= "string" or name == "" then error("API.registerEventSource: name must be a string", 2) end
    if type(poll) ~= "function" then error("API.registerEventSource: poll must be a function", 2) end
    opts = type(opts) == "table" and opts or {}
    local src = { name = name, poll = poll, version = opts.version and tostring(opts.version) or nil,
                  owner = Bus.currentOwner or name, errors = 0, lastWarn = 0 }
    for i, s in ipairs(_sources) do
        if s.name == name then _sources[i] = src; return end
    end
    _sources[#_sources + 1] = src
    Log.info("Events", "event source registered: " .. name .. (src.version and (" (" .. src.version .. ")") or ""))
    if #_sources == 1 then startLoop() end
end

return Bus
