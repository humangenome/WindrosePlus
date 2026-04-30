-- WindrosePlus Live Map Module
-- Writes player/mob positions to livemap_data.json
-- UObject access dispatched to game thread via ExecuteInGameThread

local json = require("modules.json")
local Log = require("modules.log")

local LiveMap = {}
LiveMap._path = nil
LiveMap._tmpPath = nil
LiveMap._playerInterval = 5
LiveMap._entityInterval = 30
LiveMap._lastPlayerWrite = 0
LiveMap._lastEntityWrite = 0
LiveMap._cachedMobs = {}
LiveMap._cachedNodes = {}
LiveMap._lastEntityCollect = 0
LiveMap._entityCacheTTL = 120  -- clear stale entity cache after 2x entity interval
LiveMap._wroteEmpty = false
LiveMap._lastSnapshot = nil
LiveMap._lastSnapshotTs = 0
LiveMap._pendingContent = nil
LiveMap._forceRequested = false  -- consumed by writeIfDue on the game-thread dispatch path

local function cloneTable(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = cloneTable(v)
    end
    return out
end

function LiveMap.init(gameDir, config)
    local dataDir = gameDir .. "windrose_plus_data"
    local f = io.open(dataDir .. '\\test_dir', 'w'); if f then f:close(); os.remove(dataDir .. '\\test_dir') end
    LiveMap._path = dataDir .. "\\livemap_data.json"
    LiveMap._tmpPath = dataDir .. "\\livemap_data.json.tmp"
    if config and config.getLiveMapPlayerInterval then
        LiveMap._playerInterval = config.getLiveMapPlayerInterval() / 1000
    end
    if config and config.getLiveMapEntityInterval then
        LiveMap._entityInterval = config.getLiveMapEntityInterval() / 1000
    end
    LiveMap._entityCacheTTL = math.max(60, LiveMap._entityInterval * 4)
    Log.info("LiveMap", "Position writer ready (player=" .. LiveMap._playerInterval .. "s, entity=" .. LiveMap._entityInterval .. "s)")
end

function LiveMap.writeIfDue()
    -- Always refresh the player snapshot first. Reading the cached
    -- WindrosePlus.state.playerCount here would self-deadlock when the Query
    -- writer is disabled — Query is what normally updates it, so a stale 0
    -- would short-circuit LiveMap forever once it wrote the first empty
    -- snapshot, even after a player joined.
    local Query = WindrosePlus._modules and WindrosePlus._modules.Query
    local allPlayers = Query and Query.getPlayers() or {}
    local liveCount = #allPlayers
    if WindrosePlus and WindrosePlus.updatePlayerCount then
        pcall(WindrosePlus.updatePlayerCount, liveCount)
    end

    -- When no players, write one final empty update then stop writing the
    -- file (we still poll the player list above, just don't burn disk I/O).
    if liveCount == 0 then
        if not LiveMap._wroteEmpty then
            LiveMap._wroteEmpty = true
            LiveMap._cachedMobs = {}
            LiveMap._cachedNodes = {}
            LiveMap._collectAndWrite(false, allPlayers) -- write empty data
        end
        return
    end
    LiveMap._wroteEmpty = false

    local now = os.time()
    -- Honor a pending force-write request (e.g. set from wp.tp). Consume the flag
    -- here on the game-thread-dispatched path so UObject collection never runs
    -- from the RCON command-processing thread.
    local forced = LiveMap._forceRequested
    if forced then LiveMap._forceRequested = false end
    local playersDue = forced or (now - LiveMap._lastPlayerWrite >= LiveMap._playerInterval)
    local entitiesDue = forced or (now - LiveMap._lastEntityWrite >= LiveMap._entityInterval)

    if not playersDue then return end
    LiveMap._lastPlayerWrite = now

    -- Expire stale entity cache if not refreshed within TTL
    if (now - LiveMap._lastEntityCollect) > LiveMap._entityCacheTTL then
        LiveMap._cachedMobs = {}
        LiveMap._cachedNodes = {}
    end

    local collectEntities = entitiesDue
    if collectEntities then
        LiveMap._lastEntityWrite = now
    end

    LiveMap._collectAndWrite(collectEntities, allPlayers)
end

-- Request that the next writeIfDue tick force a write regardless of interval timing.
-- Safe to call from any thread (RCON command handlers, async tasks) — only sets a flag.
-- The actual UObject collection happens in writeIfDue on the game-thread-dispatched path.
function LiveMap.requestForceWrite()
    LiveMap._forceRequested = true
end

function LiveMap._collectAndWrite(collectEntities, prefetchedPlayers)
    -- Use the player list passed in by writeIfDue (saves a redundant
    -- Query.getPlayers() iteration). Falls back to a fresh query if called
    -- without a prefetched list (defensive — current callers always pass one).
    local allPlayers = prefetchedPlayers
    if not allPlayers then
        local Query = WindrosePlus._modules and WindrosePlus._modules.Query
        allPlayers = Query and Query.getPlayers() or {}
    end
    local players = {}
    for _, p in ipairs(allPlayers) do
        if p.x then table.insert(players, p) end
    end

    -- Mobs and nodes only collected on the slower interval; use cache otherwise
    local mobs = LiveMap._cachedMobs
    local nodes = LiveMap._cachedNodes

    if collectEntities then
        mobs = {}
        nodes = {}
        local pawns = FindAllOf("Pawn")
        if pawns then
            for _, pawn in ipairs(pawns) do
                if pawn:IsValid() then
                    local fn = pawn:GetFullName()
                    if not fn:find("R5Character") and not fn:find("PlayerController") then
                        local m = {}
                        pcall(function()
                            local parts = fn:match("BP_[^_]+_([^_]+)")
                            if parts then
                                m.name = parts
                            else
                                m.name = fn:match("BP_([^_]+)") or "Mob"
                            end
                        end)
                        -- K2_GetActorLocation() walks attachment hierarchy and returns
                        -- true world coords; ReplicatedMovement.Location reads (0,0,0)
                        -- for actors attached to moving parents (ships, etc.).
                        pcall(function()
                            local loc = pawn:K2_GetActorLocation()
                            if loc then m.x = loc.X; m.y = loc.Y; m.z = loc.Z end
                        end)
                        if not m.x then
                            pcall(function()
                                local loc = pawn.ReplicatedMovement.Location
                                if loc then m.x = loc.X; m.y = loc.Y; m.z = loc.Z end
                            end)
                        end
                        if m.x then table.insert(mobs, m) end
                    end
                end
            end
        end

        local minerals = FindAllOf("R5MineralNode")
        if minerals then
            for _, node in ipairs(minerals) do
                if node:IsValid() then
                    local n = { name = "Mineral" }
                    pcall(function()
                        local fn = node:GetFullName()
                        n.name = fn:match("BP_([^_]+)") or "Mineral"
                    end)
                    pcall(function()
                        local loc = node:K2_GetActorLocation()
                        if loc then n.x = loc.X; n.y = loc.Y; n.z = loc.Z end
                    end)
                    if not n.x then
                        pcall(function()
                            local loc = node.ReplicatedMovement.Location
                            if loc then n.x = loc.X; n.y = loc.Y; n.z = loc.Z end
                        end)
                    end
                    if not n.x then
                        pcall(function()
                            local root = node.RootComponent
                            if root and root:IsValid() then
                                local rel = root.RelativeLocation
                                if rel then n.x = rel.X; n.y = rel.Y; n.z = rel.Z end
                            end
                        end)
                    end
                    if n.x then table.insert(nodes, n) end
                end
            end
        end

        -- Update cache and timestamp
        LiveMap._cachedMobs = mobs
        LiveMap._cachedNodes = nodes
        LiveMap._lastEntityCollect = os.time()
    end

    local payload = {
        players = players,
        mobs = mobs,
        nodes = nodes,
        player_count = #players,
        mob_count = #mobs,
        node_count = #nodes,
        timestamp = os.time()
    }
    LiveMap._lastSnapshot = cloneTable(payload)
    LiveMap._lastSnapshotTs = payload.timestamp
    LiveMap._writePayload(payload)
end

function LiveMap._writeContent(content)
    if not LiveMap._tmpPath or not LiveMap._path then return false end
    local file = io.open(LiveMap._tmpPath, "w")
    if not file then return false end
    file:write(content)
    file:close()
    os.remove(LiveMap._path)
    os.rename(LiveMap._tmpPath, LiveMap._path)
    return true
end

function LiveMap.flushPendingWrite()
    local content = LiveMap._pendingContent
    if not content then return end
    LiveMap._pendingContent = nil
    if not LiveMap._writeContent(content) then
        LiveMap._pendingContent = content
    end
end

function LiveMap._writePayload(payload)
    LiveMap._pendingContent = json.encode(payload)
end

function LiveMap.writeDegraded(reason)
    local now = os.time()
    if now - LiveMap._lastPlayerWrite < LiveMap._playerInterval then return end
    LiveMap._lastPlayerWrite = now
    local payload
    if LiveMap._lastSnapshot then
        payload = cloneTable(LiveMap._lastSnapshot)
        payload.timestamp = now
        payload.degraded = true
        payload.degraded_reason = reason or "execute_in_game_thread_starved"
        payload.cache_age_sec = now - (LiveMap._lastSnapshotTs or now)
    else
        payload = {
            players = {},
            mobs = {},
            nodes = {},
            player_count = 0,
            mob_count = 0,
            node_count = 0,
            timestamp = now,
            degraded = true,
            degraded_reason = reason or "execute_in_game_thread_starved"
        }
    end
    if WindrosePlus and WindrosePlus.setMode then
        pcall(WindrosePlus.setMode, "degraded")
    end
    LiveMap._writePayload(payload)
    LiveMap.flushPendingWrite()
end

-- Force an immediate write (used by future dashboard/API refresh flows)
function LiveMap.forceWrite()
    LiveMap._lastPlayerWrite = os.time()
    LiveMap._lastEntityWrite = os.time()
    LiveMap._wroteEmpty = false
    LiveMap._collectAndWrite(true, nil)
end

return LiveMap
