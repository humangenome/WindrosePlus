# Windrose+ Command Reference

All commands are executed via RCON. Console commands are not supported (HookProcessConsoleExec crashes Windrose dedicated servers).



---

## Server

### wp.help

Show all commands or get detailed help for a specific command.

```
Usage: wp.help [command|all]
```

`wp.help` shows non-hidden commands grouped by category. `wp.help all` includes debug commands. `wp.help status` shows detailed usage for a single command.

```
> wp.help status
wp.status - Show server status and multipliers
Usage: wp.status
```

### wp.status

Show server status including player count, all multipliers, and version.

```
Usage: wp.status
```

```
> wp.status
Players: 3
Loot: 2x
XP: 3x
Stack Size: 5x
Craft Efficiency: 2x
Crop Speed: 2x
Weight: 5x
Windrose+ v1.0.0
```

### wp.version

Show WindrosePlus version.

```
Usage: wp.version
```

```
> wp.version
Windrose+ v1.0.0
```

### wp.config

Show current config values including multipliers, RCON status, and loaded mod count.

```
Usage: wp.config
```

```
> wp.config
WindrosePlus Config:
  Loot: 2x
  XP: 3x
  Stack Size: 5x
  Craft Efficiency: 2x
  Crop Speed: 2x
  Weight: 5x
  RCON: enabled
  Mods: 1
```

### wp.multipliers

Show all gameplay multipliers.

```
Usage: wp.multipliers
```

```
> wp.multipliers
Multipliers:
  Loot: 2x
  XP: 3x
  Stack Size: 5x
  Craft Efficiency: 2x
  Crop Speed: 2x
  Weight: 5x
```

### wp.uptime

Show how long the server process has been running.

```
Usage: wp.uptime
```

```
> wp.uptime
Uptime: 2d 14h 32m
```

### wp.mods

List all loaded third-party mods with version and author.

```
Usage: wp.mods
```

```
> wp.mods
Loaded mods (2):
  example-welcome v1.0 by HumanGenome
  discord-relay v0.3 by CaptainMorgan
```

### wp.reload

Reload config from disk. Changes to `windrose_plus.json` take effect immediately without a server restart.

```
Usage: wp.reload
```

```
> wp.reload
Config reloaded
```

---

## Players

### wp.players

List all online players with their world positions.

```
Usage: wp.players
```

```
> wp.players
Online (2):
  1. HumanGenome @ 14520, -8340, 150
  2. CaptainMorgan @ 6200, 1100, 85
```

### wp.pos

Get world coordinates for one or all players. Accepts `[player]` argument.

```
Usage: wp.pos [player]
```

```
> wp.pos Human
HumanGenome: X=14520.3 Y=-8340.1 Z=150.0
```

### wp.health

Read health values for one or all players. Accepts `[player]` argument.

```
Usage: wp.health [player]
```

```
> wp.health
HumanGenome: 85/100 HP
CaptainMorgan: 100/100 HP
```

### wp.stamina

Read stamina, hunger, and thirst component values for one or all players. Accepts `[player]` argument.

```
Usage: wp.stamina [player]
```

```
> wp.stamina Human
HumanGenome:
  StaminaComponent.CurrentStamina = 72
  StaminaComponent.MaxStamina = 100
  HungerComponent.CurrentHunger = 55
  HungerComponent.MaxHunger = 100
  ThirstComponent.CurrentThirst = 80
  ThirstComponent.MaxThirst = 100
```

### wp.playerinfo

Consolidated player info showing position, health, alive status, and session time. Accepts `[player]` argument.

```
Usage: wp.playerinfo [player]
```

```
> wp.playerinfo HumanGenome
HumanGenome:
  Position: 14520, -8340, 150
  Health: 85/100
  Alive: Yes
  Session: 2h 15m
```

### wp.playtime

Show how long a player has been online this session. Accepts `[player]` argument.

```
Usage: wp.playtime [player]
```

```
> wp.playtime
HumanGenome: 2h 15m
CaptainMorgan: 0h 42m
```

### wp.givestats

Record a stat/talent compensation note in `windrose_plus_data\stat_grants_queue.log`.

This is audit-only. It does **not** change the character in-game and it does not repair `RewardLevel < CurrentLevel` crashes. Use the dashboard Character Repair page for the known progression-drift repair workflow.

```
Usage: wp.givestats <player> <stat_count> [talent_count]
```

```
> wp.givestats HumanGenome 3 2
Recorded audit note: HumanGenome +3 stat +2 talent. This does not change the character in-game.
```

---

## World

### wp.time


```
Usage: wp.time
```

```
> wp.time
R5GameMode.TimeOfDay = 14.5
R5GameMode.DayCycleDuration = 1800
R5GameMode.NightCycleDuration = 600
```

### wp.creatures

Count all spawned creatures grouped by type. Useful for diagnosing mob-related lag.

```
Usage: wp.creatures
```

```
> wp.creatures
Creatures (147 total):
  Wolf: 32
  Deer: 28
  Boar: 24
  Bear: 12
  Rabbit: 18
  Fish: 33
```

### wp.entities

Count total entities by UE4 type. Useful for diagnosing server lag.

```
Usage: wp.entities
```

```
> wp.entities
Entity Counts:
  Pawn: 152
  R5Character: 3
  R5MineralNode: 89
  PlayerController: 3
  GameState: 1
```

### wp.weather

Read current weather and environmental values from the game state.

```
Usage: wp.weather
```

```
> wp.weather
R5GameMode.WindSpeed = 12.5
R5GameMode.WaveHeight = 2.1
R5GameMode.TemperatureMultiplier = 1.0
```

---

## Diagnostics

### wp.perf

Show server performance metrics including player count, memory usage, and uptime.

```
Usage: wp.perf
```

```
> wp.perf
Server Performance:
  Players: 3
  Memory: 4821 MB
  Uptime: 14h 32m
```

### wp.memory

Show detailed memory usage for the server process (working set, virtual, page file).

```
Usage: wp.memory
```

```
> wp.memory
Memory Usage:
  Working Set: 4821 MB
  Virtual: 8192 MB
  Page File: 5120 MB
```

### wp.connections

Show network connection info including active players, zombie controllers, server mode, and time since last player.

```
Usage: wp.connections
```

```
> wp.connections
Connections:
  Active: 2
  Zombie Controllers: 1
  Mode: active
  Last Player: 0s ago
```

---

## Admin

### wp.heal

Restore one or all players to full health. Accepts `[player]` argument.

```
Usage: wp.heal [player]
```

```
> wp.heal
Healed 3 player(s) to full

> wp.heal HumanGenome
Healed humangenome to full
```

### wp.god

Toggle invulnerability for one or all players. Accepts `[player]` argument.

```
Usage: wp.god [player]
```

```
> wp.god HumanGenome
HumanGenome: god ON

> wp.god HumanGenome
HumanGenome: god OFF
```

### wp.fly

Toggle fly mode for one or all players. Accepts `[player]` argument.

```
Usage: wp.fly [player]
```

```
> wp.fly HumanGenome
HumanGenome: fly ON

> wp.fly HumanGenome
HumanGenome: fly OFF
```

### wp.kick

Disconnect a player from the server.

```
Usage: wp.kick <player>
```

```
> wp.kick HumanGenome
Kicked humangenome

> wp.kick John Smith
Kicked john smith
```

### wp.speed

Set movement speed multiplier for one or all players. Accepts `[player]` argument.


```
Usage: wp.speed [player] <multiplier>
```

Multiplier range: 0 to 20. Default is 1.0.

```
> wp.speed 2.0
Speed set to 2.0x for 3 player(s)

> wp.speed HumanGenome 1.5
Speed set to 1.5x for humangenome
```

---

## Debug

These commands are hidden from `wp.help` by default. Use `wp.help all` to see them.

### wp.inspect

Inspect a UE4 object type -- shows instance count and full names of the first 3 instances.

```
Usage: wp.inspect <TypeName>
```

```
> wp.inspect R5Character
R5Character: 2 instance(s)
  R5Character /Game/Maps/WorldMap.WorldMap:PersistentLevel.R5Character_0
  R5Character /Game/Maps/WorldMap.WorldMap:PersistentLevel.R5Character_1
```

### wp.discover

Brute-force probe all known property names on a UE4 type and report any that return values.

```
Usage: wp.discover <TypeName>
```

```
> wp.discover R5GameMode
R5GameMode discovered properties:
  XPMultiplier = 3
  LootMultiplier = 2
  MaxPlayers = 32
  DayCycleDuration = 1800
```

### wp.props

List all discoverable properties on the first instance of a UE4 type. Optionally filter by name.

```
Usage: wp.props <TypeName> [filter]
```

```
> wp.props R5GameMode multiplier
R5GameMode properties:
  XPMultiplier = 3
  LootMultiplier = 2
  StackSizeMultiplier = 5
  CraftCostMultiplier = 0.5
```

### wp.gm

Read a single property from R5GameMode by name.

```
Usage: wp.gm <property>
```

```
> wp.gm MaxPlayers
MaxPlayers = 32
```

### wp.settings

List all readable R5GameMode settings. Optionally filter by property name.

```
Usage: wp.settings [filter]
```

```
> wp.settings speed
R5GameMode Settings:
  DayNightCycleSpeed = 1
  CookingSpeed = 1
  SmeltingSpeed = 1
```

### wp.probe_player

Dump all name-related properties from R5PlayerState, PlayerController, and R5Character for connected players. Used for reverse-engineering player identity fields.

```
Usage: wp.probe_player
```

```
> wp.probe_player
--- R5PlayerState #1 ---
FullName: R5PlayerState /Game/Maps/WorldMap.WorldMap:PersistentLevel.R5PlayerState_0
  PlayerNamePrivate = [str] HumanGenome
  PlayerId = 1
--- PlayerController #1 ---
FullName: PlayerController /Game/Maps/WorldMap.WorldMap:PersistentLevel.PlayerController_0
  NetPlayerIndex = 0
--- R5Character #1 ---
FullName: R5Character /Game/Maps/WorldMap.WorldMap:PersistentLevel.R5Character_0
```

---

## Map

### wp.mapgen

Generate a heightmap from landscape actors for the live map viewer. Must be run on a fresh server boot before any mod hot-reload (UE4SS cache issues prevent landscape detection after `RestartMod`).

```
Usage: wp.mapgen
```

```
> wp.mapgen
Heightmap exported: 4 landscapes, 16384 vertices
```

### wp.mapexport

Trigger the C++ HeightmapExporter mod to export raw terrain heightfield data. This writes binary `.bin` files to `windrose_plus_data/heightmaps/` which are then processed into map tiles by `windrose_plus/tools/generateTiles.ps1`.

```
Usage: wp.mapexport
```

```
> wp.mapexport
Heightmap export triggered — check windrose_plus_data/heightmaps/ for output
```

---

## HTTP API Endpoints

The web dashboard exposes a REST API for external tools and integrations. All endpoints except `/api/health` require cookie-based authentication (login via the dashboard with your RCON password).

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET | `/api/health` | No | Health check — returns `{"status": "ok", "version": "...", "timestamp": ...}` |
| GET | `/api/status` | Yes | Server status: player list, multipliers, server info |
| GET | `/api/livemap` | Yes | Live map data: player positions, mobs, resource nodes |
| GET | `/api/config` | Yes | Current config (RCON password masked) |
| GET | `/api/commands` | Yes | Command documentation for console autocomplete |
| GET | `/api/mapinfo` | Yes | Map coordinate metadata for tile rendering |
| GET | `/api/mods` | Yes | Installed third-party mods |
| GET | `/api/rcon/log` | Yes | Recent RCON command audit log |
| POST | `/api/rcon` | Yes | Execute an RCON command |
| POST | `/api/character-repair` | Yes | Upload a local SaveProfiles zip and download a repaired zip for known progression drift |

### POST /api/rcon

Execute a command via the RCON interface.

**Request body** (JSON):
```json
{
    "password": "your_rcon_password",
    "command": "wp.status"
}
```

**Response** (JSON):
```json
{
    "status": "ok",
    "message": "Players: 3\nLoot: 2x\nXP: 3x\nWindrose+ v1.0.0"
}
```

Rate limited to 1 request per second per client IP.
