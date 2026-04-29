-- WindrosePlus Query Module
-- Writes server status to server_status.json
-- UObject access dispatched to game thread via ExecuteInGameThread

local json = require("modules.json")
local Log = require("modules.log")

local Query = {}
Query._statusPath = nil
Query._tmpPath = nil
Query._config = nil
Query._interval = 5
Query._idleInterval = 30
Query._lastWrite = 0
Query._serverInfo = nil
Query._lastStatus = nil
Query._lastStatusTs = 0
Query._pendingContent = nil

local function cloneTable(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = cloneTable(v)
    end
    return out
end

function Query.init(gameDir, config)
    local dataDir = gameDir .. "windrose_plus_data"
    local f = io.open(dataDir .. '\\test_dir', 'w'); if f then f:close(); os.remove(dataDir .. '\\test_dir') end
    Query._statusPath = dataDir .. "\\server_status.json"
    Query._tmpPath = dataDir .. "\\server_status.json.tmp"
    Query._gameDir = gameDir
    Query._config = config
    Query._interval = (config.getQueryInterval() or 5000) / 1000
    Query._idleInterval = ((config.getQueryIdleInterval and config.getQueryIdleInterval()) or 30000) / 1000
    Query._loadServerDescription(gameDir)
    Log.info("Query", "Status path: " .. Query._statusPath)
    Log.info("Query", "Status writer ready (active=" .. Query._interval .. "s, idle=" .. Query._idleInterval .. "s)")
end

function Query._loadServerDescription(gameDir)
    local f = io.open(gameDir .. "\\R5\\ServerDescription.json", "r")
    if not f then return end
    local ok, data = pcall(json.decode, f:read("*a"))
    f:close()
    if ok and data then
        local desc = data.ServerDescription_Persistent or {}
        Query._serverInfo = {
            name = desc.ServerName or "",
            invite_code = desc.InviteCode or "",
            password_protected = desc.IsPasswordProtected or false,
            max_players = desc.MaxPlayerCount or 10,
            version = (data.DeploymentId or ""):match("^([%d%.]+)") or "unknown"
        }
    end
end

function Query.writeIfDue()
    local now = os.time()
    -- Use longer interval when idle
    local interval = Query._interval
    if WindrosePlus and WindrosePlus.isIdle() then
        interval = Query._idleInterval
    end
    if now - Query._lastWrite < interval then return end
    Query._lastWrite = now
    Query._collectAndWrite()
end

-- Force an immediate write (used when player count drops to 0 so dashboards update promptly)
function Query.forceWrite()
    Query._lastWrite = os.time()
    Query._collectAndWrite()
end

function Query._multipliers()
    local cfg = Query._config or {}
    return {
        xp = cfg.getXpMultiplier and cfg.getXpMultiplier() or 1,
        loot = cfg.getLootMultiplier and cfg.getLootMultiplier() or 1,
        stack_size = cfg.getStackSizeMultiplier and cfg.getStackSizeMultiplier() or 1,
        craft_efficiency = cfg.getCraftEfficiencyMultiplier and cfg.getCraftEfficiencyMultiplier() or 1,
        craft_cost = cfg.getCraftEfficiencyMultiplier and cfg.getCraftEfficiencyMultiplier() or 1, -- DEPRECATED, removed in v1.2 (kept for old dashboards)
        crop_speed = cfg.getCropSpeedMultiplier and cfg.getCropSpeedMultiplier() or 1,
        weight = cfg.getWeightMultiplier and cfg.getWeightMultiplier() or 1,
        inventory_size = cfg.getInventorySizeMultiplier and cfg.getInventorySizeMultiplier() or 1,
        cooking_speed = cfg.getCookingSpeedMultiplier and cfg.getCookingSpeedMultiplier() or 1,
        harvest_yield = cfg.getHarvestYieldMultiplier and cfg.getHarvestYieldMultiplier() or 1
    }
end

function Query._writeContent(content)
    if not Query._tmpPath or not Query._statusPath then return false end
    local file = io.open(Query._tmpPath, "w")
    if not file then return false end
    file:write(content)
    file:close()
    os.remove(Query._statusPath)
    os.rename(Query._tmpPath, Query._statusPath)
    return true
end

function Query.flushPendingWrite()
    local content = Query._pendingContent
    if not content then return end
    Query._pendingContent = nil
    if not Query._writeContent(content) then
        Query._pendingContent = content
    end
end

function Query._writeStatus(status)
    Query._pendingContent = json.encode(status)
end

function Query._degradedEmpty(reason)
    if Query._gameDir then
        Query._loadServerDescription(Query._gameDir)
    end
    local si = Query._serverInfo or {}
    local cachedCount = 0
    if WindrosePlus and WindrosePlus.state then
        cachedCount = tonumber(WindrosePlus.state.playerCount) or 0
    end
    return {
        server = {
            name = si.name or "",
            game = "Windrose",
            version = si.version or "unknown",
            windrose_plus = WindrosePlus and WindrosePlus.VERSION or "1.0.0",
            invite_code = si.invite_code or "",
            password_protected = si.password_protected or false,
            max_players = si.max_players or 10,
            player_count = cachedCount,
            game_port = Query._config and Query._config.getGamePort and Query._config.getGamePort() or nil
        },
        players = {},
        perf = {},
        multipliers = Query._multipliers(),
        timestamp = os.time(),
        mode = "degraded",
        degraded = true,
        degraded_reason = reason or "execute_in_game_thread_starved"
    }
end

function Query.writeDegraded(reason)
    local now = os.time()
    if now - Query._lastWrite < Query._interval then return end
    Query._lastWrite = now
    local status
    if Query._lastStatus then
        status = cloneTable(Query._lastStatus)
        status.timestamp = now
        status.mode = "degraded"
        status.degraded = true
        status.degraded_reason = reason or "execute_in_game_thread_starved"
        status.cache_age_sec = now - (Query._lastStatusTs or now)
    else
        status = Query._degradedEmpty(reason)
    end
    if WindrosePlus and WindrosePlus.setMode then
        pcall(WindrosePlus.setMode, "degraded")
    end
    Query._writeStatus(status)
    Query.flushPendingWrite()
end

-- Delegate to shared helper in WindrosePlus global
function Query._isConnected(pc)
    return WindrosePlus._isConnected(pc)
end

function Query.getPlayers()
    local players = {}
    local pcs = FindAllOf("PlayerController")
    if not pcs then return players end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() and Query._isConnected(pc) then
            local p = { alive = true }

            pcall(function()
                local ps = pc.PlayerState
                if ps and ps:IsValid() then
                    pcall(function()
                        local val = ps.PlayerNamePrivate
                        if val then
                            local sok, str = pcall(function() return val:ToString() end)
                            if sok and str and str ~= "" then
                                p.name = str
                            end
                        end
                    end)
                    if not p.name then
                        pcall(function()
                            local pid = ps.PlayerId
                            if pid then p.name = "Player " .. tostring(pid) end
                        end)
                    end
                end
            end)

            if not p.name then p.name = "Player" end

            pcall(function()
                local pawn = pc.Pawn
                if pawn and pawn:IsValid() then
                    pcall(function()
                        local loc = pawn.ReplicatedMovement.Location
                        if loc then p.x = loc.X; p.y = loc.Y; p.z = loc.Z end
                    end)
                    pcall(function()
                        local hc = pawn.HealthComponent
                        if hc and hc:IsValid() then
                            local hp = hc.CurrentHealth
                            if hp and tonumber(tostring(hp)) == 0 then
                                p.alive = false
                            end
                        end
                    end)
                end
            end)

            table.insert(players, p)
        end
    end
    return players
end

function Query._collectAndWrite()
    -- Refresh cached server info so version/invite-code updates (e.g. after a game
    -- patch rewrites DeploymentId) propagate without needing a full server restart
    if Query._gameDir then
        Query._loadServerDescription(Query._gameDir)
    end
    local players = Query.getPlayers()
    local si = Query._serverInfo or {}

    -- Mark boot complete on first successful write (server is fully loaded)
    if WindrosePlus and not WindrosePlus.state.bootComplete then
        WindrosePlus.state.bootComplete = true
    end

    -- Update global player count and fire join/leave events
    if WindrosePlus then
        WindrosePlus.updatePlayerCount(#players)
        if WindrosePlus._firePlayerEvents then
            pcall(WindrosePlus._firePlayerEvents, players)
        end
        -- Auto-trigger map export on first player
        if WindrosePlus._checkMapExport then
            pcall(WindrosePlus._checkMapExport)
        end
        -- Auto-trigger tile generation after heightmap export
        if WindrosePlus._checkTileGen then
            pcall(WindrosePlus._checkTileGen)
        end
    end

    -- Skip perf collection when idle
    local perf = {}
    if not (WindrosePlus and WindrosePlus.isIdle()) then
        pcall(function()
            local states = FindAllOf("GameState") or FindAllOf("GameStateBase")
            if states then
                for _, gs in ipairs(states) do
                    if gs:IsValid() then
                        pcall(function()
                            local wt = gs.ReplicatedWorldTimeSeconds
                            if wt then perf.world_time = tonumber(tostring(wt)) end
                        end)
                    end
                end
            end
        end)
    end

    local status = {
        server = {
            name = si.name or "",
            game = "Windrose",
            version = si.version or "unknown",
            windrose_plus = WindrosePlus and WindrosePlus.VERSION or "1.0.0",
            invite_code = si.invite_code or "",
            password_protected = si.password_protected or false,
            max_players = si.max_players or 10,
            player_count = #players,
            game_port = Query._config.getGamePort and Query._config.getGamePort() or nil
        },
        players = players,
        perf = perf,
        multipliers = Query._multipliers(),
        timestamp = os.time()
    }
    Query._lastStatus = cloneTable(status)
    Query._lastStatusTs = status.timestamp
    Query._writeStatus(status)
end

return Query
