-- WindrosePlus Config Module
-- Loads and manages windrose_plus.json configuration

local json = require("modules.json")
local Log = require("modules.log")
local Events = require("modules.events")

local Config = {}
Config._data = nil
Config._path = nil

function Config.init(gameDir)
    Config._path = gameDir .. "\\windrose_plus.json"
    Config.reload()
end

function Config.reload()
    local file = io.open(Config._path, "r")
    if not file then
        Log.info("Config", "No config found, creating default at: " .. Config._path)
        Config._createDefault()
        file = io.open(Config._path, "r")
        if not file then
            Log.error("Config", "Cannot create config file")
            Config._data = Config._defaults()
            return
        end
    end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        -- Normalize legacy aliases before merging defaults so old keys carry their values forward
        data = Config._normalizeAliases(data)
        -- Merge with defaults so missing keys don't cause nil errors
        Config._data = Config._mergeDefaults(data, Config._defaults())
        Log.info("Config", "Config loaded successfully")
        Events.record("config.load", {
            path = Config._path,
            multipliers = Config._data.multipliers,
            features = Config._data.features,
            rcon_enabled = Config._data.rcon and Config._data.rcon.enabled or false,
            query_enabled = Config._data.query and Config._data.query.enabled,
            log_level = Config._data.debug and Config._data.debug.log_level,
            byte_size = #content,
        })
    else
        Log.error("Config", "Failed to parse config: " .. tostring(data))
        Log.warn("Config", "Using defaults")
        Config._data = Config._defaults()
        Events.record("config.load.fail", {
            path = Config._path,
            reason = tostring(data),
            byte_size = #content,
        })
    end
end

-- Translate legacy multiplier keys to their canonical names so downstream
-- getters can read a single key. Mutates and returns the input table.
function Config._normalizeAliases(data)
    if type(data) ~= "table" or type(data.multipliers) ~= "table" then return data end
    local m = data.multipliers
    if m.craft_cost ~= nil then
        if m.craft_efficiency == nil then
            m.craft_efficiency = m.craft_cost
        elseif tonumber(m.craft_efficiency) ~= tonumber(m.craft_cost) then
            Log.warn("Config", "Both craft_efficiency and craft_cost set with different values; using craft_efficiency=" .. tostring(m.craft_efficiency))
        end
        m.craft_cost = nil
    end
    return data
end

function Config.get(section, key)
    if not Config._data then return nil end
    if not Config._data[section] then return nil end
    if key then
        return Config._data[section][key]
    end
    return Config._data[section]
end

function Config.getRconPort()
    return Config.get("rcon", "port") or 27320
end

function Config.getRconPassword()
    return Config.get("rcon", "password") or ""
end

function Config.isRconEnabled()
    local enabled = Config.get("rcon", "enabled")
    local password = Config.getRconPassword()
    -- RCON only enabled if explicitly enabled AND password is set
    if enabled == true and (password == "" or password == "changeme") then
        Log.warn("Config", "RCON enabled but password is " .. (password == "" and "empty" or "\"changeme\"") .. " — RCON disabled for security")
    end
    return enabled == true and password ~= "" and password ~= "changeme"
end

function Config.isQueryEnabled()
    return Config.get("query", "enabled") ~= false
end

function Config.getQueryInterval()
    return Config.get("query", "interval_ms") or 5000
end

-- Clamp a float value to a range, logging a warning if clamped
function Config._clampFloat(val, default, min, max, name)
    local v = tonumber(val)
    if not v then return default end
    if v < min then
        Log.warn("Config", name .. " clamped from " .. v .. " to " .. min .. " (minimum)")
        return min
    end
    if v > max then
        Log.warn("Config", name .. " clamped from " .. v .. " to " .. max .. " (maximum)")
        return max
    end
    return v
end

function Config.getXpMultiplier()
    return Config._clampFloat(Config.get("multipliers", "xp"), 1.0, 0.1, 100.0, "xp")
end

function Config.getLootMultiplier()
    return Config._clampFloat(Config.get("multipliers", "loot"), 1.0, 0.1, 100.0, "loot")
end

function Config.getStackSizeMultiplier()
    return Config._clampFloat(Config.get("multipliers", "stack_size"), 1.0, 0.1, 100.0, "stack_size")
end

function Config.getCraftEfficiencyMultiplier()
    return Config._clampFloat(Config.get("multipliers", "craft_efficiency"), 1.0, 0.1, 100.0, "craft_efficiency")
end
-- Back-compat function alias for any downstream caller that still uses the old name
Config.getCraftCostMultiplier = Config.getCraftEfficiencyMultiplier

function Config.getCropSpeedMultiplier()
    return Config._clampFloat(Config.get("multipliers", "crop_speed"), 1.0, 0.1, 100.0, "crop_speed")
end

function Config.getWeightMultiplier()
    return Config._clampFloat(Config.get("multipliers", "weight"), 1.0, 0.1, 10.0, "weight")
end

function Config.getInventorySizeMultiplier()
    return Config._clampFloat(Config.get("multipliers", "inventory_size"), 1.0, 0.5, 10.0, "inventory_size")
end

function Config.getPointsPerLevelMultiplier()
    -- Disabled until Windrose exposes a safe progression path. The PAK builder
    -- also skips this key because it can corrupt character progression saves.
    return 1.0
end

function Config.getCookingSpeedMultiplier()
    return Config._clampFloat(Config.get("multipliers", "cooking_speed"), 1.0, 0.1, 100.0, "cooking_speed")
end

function Config.getHarvestYieldMultiplier()
    return Config._clampFloat(Config.get("multipliers", "harvest_yield"), 1.0, 0.1, 100.0, "harvest_yield")
end

function Config.getAdminSteamIds()
    return Config.get("admin", "steam_ids") or {}
end

function Config.isAdmin(steamId)
    local admins = Config.getAdminSteamIds()
    for _, id in ipairs(admins) do
        if tostring(id) == tostring(steamId) then
            return true
        end
    end
    return false
end

function Config.isFeatureEnabled(feature)
    return Config.get("features", feature) == true
end

function Config._defaults()
    return {
        server = { http_port = 8780, bind_ip = "" },
        rcon = { enabled = false, port = 27320, password = "" },
        query = { enabled = true, interval_ms = 5000 },
        admin = { steam_ids = {} },
        multipliers = { xp = 1.0, loot = 1.0, stack_size = 1.0, craft_efficiency = 1.0, crop_speed = 1.0, weight = 1.0, inventory_size = 1.0, cooking_speed = 1.0, harvest_yield = 1.0 },
        features = { unlock_all_recipes = false, unlock_all_ships = false },
        debug = { log_level = "info" }
    }
end

-- Deep merge user config with defaults (defaults fill missing keys)
function Config._mergeDefaults(user, defaults)
    local result = {}
    for k, v in pairs(defaults) do
        if type(v) == "table" and type(user[k]) == "table" then
            result[k] = Config._mergeDefaults(user[k], v)
        elseif user[k] ~= nil then
            result[k] = user[k]
        else
            result[k] = v
        end
    end
    -- Also include keys from user that aren't in defaults
    for k, v in pairs(user) do
        if result[k] == nil then
            result[k] = v
        end
    end
    return result
end

function Config._createDefault()
    local defaults = Config._defaults()
    -- Set a friendlier default for first-time users
    defaults.rcon.enabled = true
    defaults.rcon.password = "changeme"
    local content = json.encode(defaults)
    local file = io.open(Config._path, "w")
    if not file then return end
    file:write(content)
    file:close()
end

return Config
