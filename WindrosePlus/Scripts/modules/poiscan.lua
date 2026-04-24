-- WindrosePlus POI Scanner
-- Walks R5POIOverlapVolume / R5POIAudioVolume actors (the canonical POI markers)
-- and writes pois.json with world coords + parsed island/POI metadata.
--
-- These zone actors exist for every generated POI on every island, regardless
-- of whether the player has triggered the spawn. The actor name encodes:
--   ...PersistentLevel.<WorldId>|I|<IslandId>|P<PoiSubType>|v<x>|v<y>|v<z>|<seed>|OSA|<n>
-- where the v-prefixed values are local-island coords (decoded) and the actor's
-- world transform gives the absolute position.

local json = require("modules.json")
local Log = require("modules.log")

local POIScan = {}
POIScan._path = nil
POIScan._tmpPath = nil
POIScan._classesPath = nil
POIScan._triggerPath = nil
POIScan._refreshInterval = 4 * 60 * 60   -- POIs are static; refresh every 4h
POIScan._lastWrite = 0
POIScan._wroteOnce = false
POIScan._discovered = {}                  -- class -> count (for refining patterns)
POIScan._discoveredCap = 500

-- Class-name patterns we treat as POI sources.
-- Order matters — first match wins for the kind label.
POIScan._poiClasses = {
    { pat = "R5POIOverlapVolume", kind = "overlap" },
    { pat = "R5POIAudioVolume",   kind = "audio"   },
}

-- Class names we ALSO want to capture as discovery candidates so we can refine
-- the pattern set later. These don't necessarily produce POI entries (most are
-- just the player-triggered actor instances), but logging them helps.
POIScan._discoveryPatterns = {
    "POI", "Camp", "Quest", "Marker", "Mine", "Ruin", "Dungeon", "Cave",
    "Altar", "Wreck", "Tortuga", "Outpost", "Pool", "Boss", "Stargazer",
    "Tower", "Sanctuary", "Treasure", "Hut", "Farm", "Smuggler", "Brethren",
    "Buccaneer", "Trade_", "Vendor", "Shipwreck", "Firebowl", "Corrupted",
    "PannoRuins", "FireSanctuary", "AncientTable",
}

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function isDiscoveryCandidate(s)
    for _, p in ipairs(POIScan._discoveryPatterns) do
        if s:find(p, 1, true) then return true end
    end
    return false
end

local function classifyPoi(fullName)
    -- Returns { kind, classToken } if this actor is a POI volume, else nil.
    -- classToken is the bare class name we matched against (R5POIOverlapVolume etc.).
    for _, c in ipairs(POIScan._poiClasses) do
        if fullName:find(c.pat, 1, true) then
            return c.kind, c.pat
        end
    end
    return nil, nil
end

-- Parse the embedded |I|<island>|P<sub>|v<x>|v<y>|v<z>|<seed>|OSA|<n> structure.
-- Returns { islandId, poiSubType, localX, localY, localZ, seed, osaIndex }
-- Any missing field is left nil.
local function parseEncodedName(fullName)
    local out = {}
    local _, _, island = fullName:find("|I|(%d+)|")
    if island then out.islandId = tonumber(island) end
    local _, _, sub = fullName:find("|P(%d+)|")
    if sub then out.poiSubType = tonumber(sub) end
    -- Coordinate triplet — may include negatives, so capture optional sign.
    local x, y, z = fullName:match("|v(%-?%d+)|v(%-?%d+)|v(%-?%d+)|")
    if x then
        out.localX = tonumber(x)
        out.localY = tonumber(y)
        out.localZ = tonumber(z)
    end
    local _, _, seed = fullName:find("|(%d+)|OSA|")
    if seed then out.seed = tonumber(seed) end
    local _, _, osa = fullName:find("|OSA|(%d+)$")
    if osa then out.osaIndex = tonumber(osa) end
    return out
end

-- Try several UE4 patterns to get the actor's world transform.
local function getWorldLocation(actor)
    local x, y, z
    -- 1. K2_GetActorLocation — canonical UE4 BlueprintCallable
    pcall(function()
        local loc = actor:K2_GetActorLocation()
        if loc then x, y, z = loc.X, loc.Y, loc.Z end
    end)
    if x and (x ~= 0 or y ~= 0) then return x, y, z end
    -- 2. ActorLocation (some types expose this property directly)
    pcall(function()
        local loc = actor.ActorLocation
        if loc then x, y, z = loc.X, loc.Y, loc.Z end
    end)
    if x and (x ~= 0 or y ~= 0) then return x, y, z end
    -- 3. RootComponent world location via component transform
    pcall(function()
        local root = actor.RootComponent
        if root and root:IsValid() then
            local loc = root:K2_GetComponentLocation()
            if loc then x, y, z = loc.X, loc.Y, loc.Z end
        end
    end)
    if x and (x ~= 0 or y ~= 0) then return x, y, z end
    -- 4. ReplicatedMovement.Location (works for replicated movable actors)
    pcall(function()
        local rm = actor.ReplicatedMovement
        if rm then
            local loc = rm.Location
            if loc then x, y, z = loc.X, loc.Y, loc.Z end
        end
    end)
    if x and (x ~= 0 or y ~= 0) then return x, y, z end
    -- 5. RootComponent.RelativeLocation (last resort — often 0 for parented volumes)
    pcall(function()
        local root = actor.RootComponent
        if root and root:IsValid() then
            local rel = root.RelativeLocation
            if rel then x, y, z = rel.X, rel.Y, rel.Z end
        end
    end)
    return x, y, z
end

local function extractClassName(fullName)
    -- "R5POIOverlapVolume /Game/.../foo|I|13|P1|..." → "R5POIOverlapVolume"
    -- "BP_Tortuga_Wardrobe_02_C /Game/..." → "BP_Tortuga_Wardrobe_02_C"
    local first = fullName:match("^([%w_]+)") or fullName
    return first
end

function POIScan.init(gameDir, config)
    local dataDir = gameDir .. "windrose_plus_data"
    POIScan._path = dataDir .. "\\pois.json"
    POIScan._tmpPath = dataDir .. "\\pois.json.tmp"
    POIScan._classesPath = dataDir .. "\\poi_discovered_classes.json"
    POIScan._triggerPath = dataDir .. "\\poiscan_refresh"
    Log.info("POIScan", "POI writer ready (R5POI*Volume scanner)")
end

function POIScan.writeIfDue()
    if not POIScan._path then return end

    -- Manual refresh trigger (drop a file at <dataDir>\poiscan_refresh)
    local triggered = false
    local f = io.open(POIScan._triggerPath, "r")
    if f then
        f:close()
        os.remove(POIScan._triggerPath)
        triggered = true
    end

    -- First scan only happens after a player has connected (the world isn't
    -- streamed in until then). Subsequent scans run on the long interval.
    if not POIScan._wroteOnce then
        if not (WindrosePlus and WindrosePlus.state.playerCount > 0) then return end
    elseif not triggered then
        local now = os.time()
        if (now - POIScan._lastWrite) < POIScan._refreshInterval then return end
    end

    POIScan._scanAndWrite()
end

function POIScan._scanAndWrite()
    -- Single FindAllOf("Actor") walk + Lua-side filter. UE4SS doesn't reliably
    -- resolve short subclass names like "R5POIOverlapVolume" via FindAllOf, but
    -- the Actor walk reaches them (verified empirically via discovery output).
    local pois = {}
    local kindCounts = {}
    local islandCounts = {}
    local subTypeCounts = {}
    local missingPosCount = 0
    local newDiscoveries = false
    local actorsScanned = 0
    local actorsMatched = 0

    print("[POIScan] starting scan...")
    local actors
    local ok = pcall(function() actors = FindAllOf("Actor") end)
    if not ok or not actors then
        Log.warn("POIScan", "FindAllOf(Actor) failed or returned nil")
        return
    end

    for _, a in ipairs(actors) do
        pcall(function()
            if not a:IsValid() then return end
            actorsScanned = actorsScanned + 1
            local fn = a:GetFullName()
            local className = extractClassName(fn)

            -- Discovery log for everything POI-ish
            if isDiscoveryCandidate(className) then
                local prev = POIScan._discovered[className]
                if prev == nil and countKeys(POIScan._discovered) < POIScan._discoveredCap then
                    POIScan._discovered[className] = 1
                    newDiscoveries = true
                elseif prev ~= nil then
                    POIScan._discovered[className] = prev + 1
                end
            end

            -- Hard POI classification (R5POIOverlapVolume / R5POIAudioVolume)
            local kind = nil
            for _, c in ipairs(POIScan._poiClasses) do
                if className == c.pat then kind = c.kind; break end
            end
            if not kind then return end

            actorsMatched = actorsMatched + 1
            local meta = parseEncodedName(fn)
            local x, y, z = getWorldLocation(a)
            if not x then missingPosCount = missingPosCount + 1 end

            table.insert(pois, {
                kind = kind,
                class = className,
                islandId = meta.islandId,
                poiSubType = meta.poiSubType,
                x = x, y = y, z = z,
                localX = meta.localX, localY = meta.localY, localZ = meta.localZ,
                seed = meta.seed,
                osaIndex = meta.osaIndex,
                poiId = fn,
            })
            kindCounts[kind] = (kindCounts[kind] or 0) + 1
            if meta.islandId then
                local k = "I" .. tostring(meta.islandId)
                islandCounts[k] = (islandCounts[k] or 0) + 1
            end
            if meta.poiSubType then
                local k = "P" .. tostring(meta.poiSubType)
                subTypeCounts[k] = (subTypeCounts[k] or 0) + 1
            end
        end)
    end

    print(string.format("[POIScan] loop done: scanned=%d matched=%d pois=%d", actorsScanned, actorsMatched, #pois))

    local payload
    local encOk, encErr = pcall(function()
        payload = json.encode({
            pois = pois,
            kind_counts = kindCounts,
            island_counts = islandCounts,
            sub_type_counts = subTypeCounts,
            total_pois = #pois,
            actors_scanned = actorsScanned,
            actors_matched = actorsMatched,
            missing_position = missingPosCount,
            timestamp = os.time(),
        })
    end)
    if not encOk then
        Log.warn("POIScan", "json.encode failed: " .. tostring(encErr))
        print("[POIScan] json.encode failed: " .. tostring(encErr))
        return
    end
    print(string.format("[POIScan] payload encoded, %d bytes", payload and #payload or 0))

    local writeOk, writeErr = pcall(function()
        local f = io.open(POIScan._tmpPath, "w")
        if not f then error("io.open returned nil for " .. tostring(POIScan._tmpPath)) end
        f:write(payload)
        f:close()
        os.remove(POIScan._path)
        os.rename(POIScan._tmpPath, POIScan._path)
    end)
    if not writeOk then
        Log.warn("POIScan", "file write failed: " .. tostring(writeErr))
        print("[POIScan] file write failed: " .. tostring(writeErr))
        return
    end
    print("[POIScan] file written")

    POIScan._wroteOnce = true
    POIScan._lastWrite = os.time()

    if newDiscoveries then
        local sorted = {}
        for cn, count in pairs(POIScan._discovered) do
            table.insert(sorted, { class = cn, count = count })
        end
        table.sort(sorted, function(a, b) return a.count > b.count end)
        local cf = io.open(POIScan._classesPath, "w")
        if cf then
            cf:write(json.encode({ classes = sorted, last_updated = os.time() }))
            cf:close()
        end
    end

    Log.info("POIScan", string.format(
        "Wrote %d POIs (%d matched / %d scanned, %d islands, %d sub-types, %d missing pos)",
        #pois, actorsMatched, actorsScanned, countKeys(islandCounts), countKeys(subTypeCounts), missingPosCount))
end

return POIScan
