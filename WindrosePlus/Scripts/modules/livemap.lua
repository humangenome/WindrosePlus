-- WindrosePlus Live Map Module
-- Writes player/mob positions to livemap_data.json
-- UObject access dispatched to game thread via ExecuteInGameThread

local json = require("modules.json")
local Log = require("modules.log")

local LiveMap = {}
LiveMap._path = nil
LiveMap._tmpPath = nil
LiveMap._playerInterval = 3
LiveMap._entityInterval = 15
LiveMap._lastPlayerWrite = 0
LiveMap._lastEntityWrite = 0
LiveMap._cachedMobs = {}
LiveMap._cachedNodes = {}
LiveMap._lastEntityCollect = 0
LiveMap._entityCacheTTL = 60   -- clear stale entity cache after 60 seconds
LiveMap._wroteEmpty = false

function LiveMap.init(gameDir, config)
    local dataDir = gameDir .. "windrose_plus_data"
    local f = io.open(dataDir .. '\\test_dir', 'w'); if f then f:close(); os.remove(dataDir .. '\\test_dir') end
    LiveMap._path = dataDir .. "\\livemap_data.json"
    LiveMap._tmpPath = dataDir .. "\\livemap_data.json.tmp"
    Log.info("LiveMap", "Position writer ready")
end

function LiveMap.writeIfDue()
    -- When no players, write one final empty update then stop
    if WindrosePlus and WindrosePlus.state.playerCount == 0 then
        if not LiveMap._wroteEmpty then
            LiveMap._wroteEmpty = true
            LiveMap._cachedMobs = {}
            LiveMap._cachedNodes = {}
            LiveMap._collectAndWrite(false) -- write empty data
        end
        return
    end
    LiveMap._wroteEmpty = false

    local now = os.time()
    local playersDue = (now - LiveMap._lastPlayerWrite >= LiveMap._playerInterval)
    local entitiesDue = (now - LiveMap._lastEntityWrite >= LiveMap._entityInterval)

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

    LiveMap._collectAndWrite(collectEntities)
end

function LiveMap._collectAndWrite(collectEntities)
    -- Use Query.getPlayers() for connected players, filter to those with positions
    local Query = WindrosePlus._modules and WindrosePlus._modules.Query
    local allPlayers = Query and Query.getPlayers() or {}
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
                        pcall(function()
                            local loc = pawn.ReplicatedMovement.Location
                            if loc then m.x = loc.X; m.y = loc.Y; m.z = loc.Z end
                        end)
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
                        local loc = node.ReplicatedMovement.Location
                        if loc then n.x = loc.X; n.y = loc.Y; n.z = loc.Z end
                    end)
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

    local data = json.encode({
        players = players,
        mobs = mobs,
        nodes = nodes,
        player_count = #players,
        mob_count = #mobs,
        node_count = #nodes,
        timestamp = os.time()
    })
    local file = io.open(LiveMap._tmpPath, "w")
    if not file then return end
    file:write(data)
    file:close()
    os.remove(LiveMap._path)
    os.rename(LiveMap._tmpPath, LiveMap._path)
end

return LiveMap
