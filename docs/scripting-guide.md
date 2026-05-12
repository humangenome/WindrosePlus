# WindrosePlus Scripting Guide

Write Lua mods that add commands, react to player events, and run scheduled tasks. Mods run inside the same UE4SS Lua state as WindrosePlus core.

---

## Folder Structure

```
WindrosePlus/
  Mods/
    my-mod/
      mod.json          # manifest (required)
      init.lua          # entry point
      helpers.lua       # optional additional files
```

Mods are loaded in alphabetical order by folder name. Each mod is wrapped in `pcall` -- one broken mod won't crash others, but may leave partial state.

The `Mods/` directory is created automatically on first run.

---

## Manifest (mod.json)

```json
{
    "name": "My Mod",
    "version": "1.0.0",
    "author": "YourName",
    "description": "What this mod does",
    "main": "init.lua"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | No | folder name | Display name in logs |
| `version` | No | `?` | Semver version string |
| `author` | No | `?` | Author name |
| `description` | No | - | Short description |
| `main` | No | `init.lua` | Entry point Lua file |

---

## API Reference

All API functions are on `WindrosePlus.API`. Store a local reference at the top of your mod:

```lua
local API = WindrosePlus.API
```

### Commands

```lua
API.registerCommand(name, handler, description, usage)
```

Register an RCON command. The handler receives an `args` table (string array, 1-indexed) and must return a string response.

```lua
API.registerCommand("wp.ping", function(args)
    return "pong"
end, "Test connectivity", "wp.ping")
```

Commands registered by mods appear in `wp.help` alongside built-in commands.

### Events

```lua
API.onPlayerJoin(function(player)
    -- player = { name = "PlayerName", x = 100, y = 200, z = 50 }
end)

API.onPlayerLeave(function(player)
    -- same structure
end)
```

Player events fire when the player list changes between tick polls. Join fires for new names; leave fires for names that disappeared. Multiple callbacks can be registered.

### Tick Callbacks

```lua
API.registerTickCallback(function()
    -- runs every 10 seconds
end, 10000)  -- interval in milliseconds (default: 5000)
```

Tick callbacks run on the main game thread during the 5-second polling loop. Keep them fast -- long-running work blocks the server.

### Delayed UE4SS Hooks

```lua
API.registerHookWhenAvailable(path, preHook, postHook, options)
```

Register a UE4SS hook immediately if possible, or retry for Blueprint/game functions that exist before their function pointer is hookable. This is useful for reverse-engineering server-side game surfaces that may only become hookable after the world finishes loading.

```lua
local handle = API.registerHookWhenAvailable(
    "/Script/R5.R5BuildingCenterStorageComponent:OnInventoryViewChanged",
    function(context)
        API.log("debug", "StorageProbe", "storage view changed")
    end,
    {
        intervalMs = 5000,
        maxAttempts = 24,
        onRegistered = function(h)
            API.log("info", "StorageProbe", "hooked after " .. h.attempts .. " attempt(s)")
        end
    }
)
```

`postHook` is optional. You may pass the options table as the third argument when you only need one callback:

```lua
API.registerHookWhenAvailable("/Script/R5.SomeClass:SomeFunction", function(context)
    -- keep hook work fast
end, { maxAttempts = 12 })
```

The returned handle includes `path`, `attempts`, `registered`, `failed`, `cancelled`, `lastError`, `preHookId`, `postHookId`, and `cancel()`. Call `handle.cancel()` only when you want to stop future retries; already-registered hooks remain owned by UE4SS for the life of this Lua state.

### Data Access

```lua
-- Current online players (array of {name, x, y, z})
local players = API.getPlayers()

-- Server info table (name, version, etc.)
local info = API.getServerInfo()

-- Read a config value from windrose_plus.json
local value = API.getConfig("section", "key")

-- True when 0 players are connected
local idle = API.isIdle()

-- WindrosePlus version string
local ver = API.VERSION
```

### Logging

```lua
API.log("info", "MyMod", "Something happened")
```

Levels: `debug`, `info`, `warn`, `error`. Logs go to the UE4SS console and log file.

---

## Hot Reload

WindrosePlus polls the `Mods/` directory every 30 seconds for file changes (new, modified, or deleted `.lua` and `.json` files). When a change is detected, the entire WindrosePlus mod restarts via UE4SS's `RestartMod()`.

You can also trigger a manual reload via the `wp.reload` RCON command.

**What happens on reload:**
- All Lua state is torn down and re-initialized
- All mods re-execute their `init.lua` from scratch
- Commands, event callbacks, and tick callbacks are re-registered
- UE4SS shared variables (if used) persist across reloads

**Development workflow:**
1. Edit your mod files
2. Wait up to 30 seconds (or run `wp.reload`)
3. Check UE4SS console for load errors

---

## Example: Scheduled Announcements

A mod that broadcasts a reminder to the server log every 5 minutes when players are online.

```
Mods/announcements/mod.json
```
```json
{
    "name": "Announcements",
    "version": "1.0.0",
    "author": "YourName",
    "description": "Periodic server announcements",
    "main": "init.lua"
}
```

```
Mods/announcements/init.lua
```
```lua
local API = WindrosePlus.API

local messages = {
    "Join our Discord: discord.gg/example",
    "Server restarts daily at 4 AM EST",
    "Report bugs in the #support channel",
}
local index = 1

API.registerTickCallback(function()
    if API.isIdle() then return end
    API.log("info", "Announce", messages[index])
    index = index % #messages + 1
end, 300000)  -- 5 minutes
```

---

## Example: Player Stats Tracking

Track total playtime and join count per player, persisted to a JSON file.

```lua
local API = WindrosePlus.API
local json = require("modules.json")

local STATS_FILE = "windrose_plus_data\\player_stats.json"
local stats = {}

-- Load existing stats
local f = io.open(STATS_FILE, "r")
if f then
    local ok, data = pcall(json.decode, f:read("*a"))
    f:close()
    if ok then stats = data end
end

local function save()
    local f = io.open(STATS_FILE, "w")
    if f then f:write(json.encode(stats)); f:close() end
end

API.onPlayerJoin(function(player)
    if not stats[player.name] then
        stats[player.name] = { joins = 0, totalMinutes = 0 }
    end
    stats[player.name].joins = stats[player.name].joins + 1
    stats[player.name].lastJoin = os.time()
    save()
end)

API.onPlayerLeave(function(player)
    local s = stats[player.name]
    if s and s.lastJoin then
        s.totalMinutes = s.totalMinutes + math.floor((os.time() - s.lastJoin) / 60)
        s.lastJoin = nil
        save()
    end
end)

API.registerCommand("wp.stats", function(args)
    if args[1] then
        local s = stats[args[1]]
        if not s then return args[1] .. ": no data" end
        return args[1] .. ": " .. s.joins .. " joins, " .. s.totalMinutes .. " min total"
    end
    local lines = {"Player Stats:"}
    for name, s in pairs(stats) do
        table.insert(lines, "  " .. name .. ": " .. s.joins .. " joins, " .. s.totalMinutes .. "m")
    end
    return #lines > 1 and table.concat(lines, "\n") or "No stats yet"
end, "Show player stats", "wp.stats [player]")
```

---

## Example: Custom Economy

Simple currency system where players earn coins over time and can check their balance.

```lua
local API = WindrosePlus.API
local json = require("modules.json")

local WALLET_FILE = "windrose_plus_data\\wallets.json"
local wallets = {}

local f = io.open(WALLET_FILE, "r")
if f then
    local ok, data = pcall(json.decode, f:read("*a"))
    f:close()
    if ok then wallets = data end
end

local function save()
    local f = io.open(WALLET_FILE, "w")
    if f then f:write(json.encode(wallets)); f:close() end
end

-- Award 10 coins every 5 minutes to online players
API.registerTickCallback(function()
    local players = API.getPlayers()
    for _, p in ipairs(players) do
        wallets[p.name] = (wallets[p.name] or 0) + 10
    end
    if #players > 0 then save() end
end, 300000)

API.registerCommand("wp.balance", function(args)
    local name = args[1]
    if not name then
        local players = API.getPlayers()
        if #players == 0 then return "No players online" end
        local lines = {}
        for _, p in ipairs(players) do
            table.insert(lines, p.name .. ": " .. (wallets[p.name] or 0) .. " coins")
        end
        return table.concat(lines, "\n")
    end
    return name .. ": " .. (wallets[name] or 0) .. " coins"
end, "Check coin balance", "wp.balance [player]")
```

---

## Publishing and Sharing Mods

A mod is a self-contained folder. To share it:

1. Zip the folder (e.g., `my-mod/` containing `mod.json` and `init.lua`)
2. Distribute the zip
3. Users extract it into their `WindrosePlus/Mods/` directory
4. Mod loads automatically on next server start or hot-reload cycle

No registry, package manager, or build step is needed.

---

## Limitations


**Game thread only.** All Lua code runs on the game thread. Long-running operations (file I/O, `io.popen`) block the server tick. Keep tick callbacks under a few milliseconds.

**No sandbox.** Mods run in the same Lua state as WindrosePlus core. A mod can access `FindAllOf`, `RegisterHook`, and other UE4SS globals directly, but these are not guaranteed stable across UE4SS versions. Prefer the `WindrosePlus.API` functions.

**No native UFunctions.** Windrose (R5BL) exposes zero Lua-callable UFunctions. All game data access is through property reads on UE4 objects. Use `pcall` liberally -- properties may not exist on all builds.

**Alphabetical load order.** Mods load in alphabetical order by folder name. If mod B depends on mod A, name the folders to ensure correct ordering (e.g., `01-core`, `02-economy`).

**State does not survive reload.** When hot-reload triggers, all Lua state is destroyed and rebuilt. Persist anything important to files. UE4SS shared variables (via `ModRef:SetSharedVariable`) are an exception -- they survive `RestartMod()`.

**Memory pressure.** Large data structures in Lua can contribute to memory and tick pressure inside the game process. Avoid caching large datasets in memory.
