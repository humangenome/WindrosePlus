-- WindrosePlus Config Module
-- Loads and manages windrose_plus.json configuration

local json = require("modules.json")
local Log = require("modules.log")

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
        -- Merge with defaults so missing keys don't cause nil errors
        Config._data = Config._mergeDefaults(data, Config._defaults())
        Log.info("Config", "Config loaded successfully")
    else
        Log.error("Config", "Failed to parse config: " .. tostring(data))
        Log.warn("Config", "Using defaults")
        Config._data = Config._defaults()
    end
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

function Config.getCraftCostMultiplier()
    return Config._clampFloat(Config.get("multipliers", "craft_cost"), 1.0, 0.1, 100.0, "craft_cost")
end

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
    return Config._clampFloat(Config.get("multipliers", "points_per_level"), 1.0, 1.0, 10.0, "points_per_level")
end

function Config.getCookingSpeedMultiplier()
    return Config._clampFloat(Config.get("multipliers", "cooking_speed"), 1.0, 0.1, 100.0, "cooking_speed")
end

function Config.getHarvestYieldMultiplier()
    return Config._clampFloat(Config.get("multipliers", "harvest_yield"), 1.0, 0.1, 100.0, "harvest_yield")
end

function Config.isIdleCpuLimiterEnabled()
    return Config.get("performance", "idle_cpu_limiter_enabled") == true
end

function Config.getIdleCpuLimitPercent()
    return Config._clampFloat(Config.get("performance", "idle_cpu_limit_percent"), 2.0, 1.0, 100.0, "idle_cpu_limit_percent")
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
        multipliers = { xp = 1.0, loot = 1.0, stack_size = 1.0, craft_cost = 1.0, crop_speed = 1.0, weight = 1.0, inventory_size = 1.0, points_per_level = 1.0, cooking_speed = 1.0, harvest_yield = 1.0 },
        performance = { idle_cpu_limiter_enabled = false, idle_cpu_limit_percent = 2.0 },
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
