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

Multipliers marked `(disabled)` are stored but not applied: the PAK builder skips
them because patching those values corrupts character saves. See
[Multipliers](config-reference.md#multipliers).

```
Usage: wp.status
```

```
> wp.status
Players: 3
Loot: 2x
XP: 3x
Stack Size: 5x (disabled)
Craft Efficiency: 2x
Crop Speed: 2x (disabled)
Weight: 5x (disabled)
Cooking Speed: 1x
Harvest Yield: 2x
WindrosePlus v1.3.25
```

### wp.version

Show WindrosePlus version.

```
Usage: wp.version
```

```
> wp.version
WindrosePlus v1.3.16
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
  Stack Size: 5x (disabled)
  Craft Efficiency: 2x
  Crop Speed: 2x (disabled)
  Weight: 5x (disabled)
  Cooking Speed: 1x
  Harvest Yield: 2x
  RCON: enabled
  Mods: 1
```

Multipliers marked `(disabled)` are stored but not applied. See
[Multipliers](config-reference.md#multipliers).

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
  Stack Size: 5x (disabled)
  Craft Efficiency: 2x
  Crop Speed: 2x (disabled)
  Weight: 5x (disabled)
  Cooking Speed: 1x
  Harvest Yield: 2x
```

Multipliers marked `(disabled)` are stored but not applied. See
[Multipliers](config-reference.md#multipliers).

### wp.uptime

Show how long the server process has been running.

```
Usage: wp.uptime
```

```
> wp.uptime
Uptime: 2d 14h 32m
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

List all online players with their world positions. Each entry shows the
actor ID (canonical, used by other commands like `wp.tp`) followed by the
player's display name in parentheses when known. When Windrose exposes
`PlayerState.PlayerId`, it also shows a session-local `player:<id>` token.

```
Usage: wp.players
```

```
> wp.players
Online (2):
  1. BP_R5Character_C_2147418445 (HumanGenome) [player:12] @ 14520, -8340, 150
  2. BP_R5Character_C_2147418362 (CaptainMorgan) [player:17] @ 6200, 1100, 85
```

The `player:<id>` token is only stable for the live session. It is useful for
targeting one of two online players with the same display name, but it is not a
persistent Steam ID.

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
HumanGenome  (BP_R5Character_C_2147418445)
  Player ID: 12
  Position: 14520, -8340, 150
  Status:    Alive
  Vitals:    HP 85/100
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

### Moderation (wp.kick / wp.ban / wp.unban / wp.listbans)

These four commands are handled by the `WindrosePlusNative` C++ mod, not by Lua. Windrose+ writes the request to `windrose_plus_data\wpn_command.txt` and the native mod picks it up within about a second. The ban list lives in `windrose_plus_data\wpn_bans.txt` and is re-checked every 10 seconds, so a banned name is removed again if it rejoins. The kick itself runs on the game thread (UE4SS's `ProcessInternal` callback), which only runs while a player is online; that is always the case for a kick. `wp.unban` and `wp.listbans` only touch the ban file and work on an empty server.

`WindrosePlusNative` is **not installed or enabled by the installer as of v1.3.16** while it is revalidated against the current Windrose dedicated-server build. Without it, `wp.kick` / `wp.ban` / `wp.unban` change nothing and answer `Kick and ban are not available on this server, so Alice was not kicked.` (or `banned` / `unbanned`), and `wp.listbans` reads an empty list. Windrose+ counts the mod as present when UE4SS would load it: `ue4ss\Mods\WindrosePlusNative\dlls\main.dll` exists and either `enabled.txt` is in that folder or `mods.txt` has `WindrosePlusNative : 1`. The examples below are the answers with the mod present. Confirm a kick took effect with `wp.players`.

#### wp.kick

Kick a connected player by name. Matching is exact and case-insensitive.

```
Usage: wp.kick <player> [reason]
```

```
> wp.kick Alice
Kick requested for Alice

> wp.kick Bob Griefing the build
Kick requested for Bob
```

#### wp.ban

Add a player to the ban list and kick them if they are online.

```
Usage: wp.ban <player> [reason]
```

```
> wp.ban Bob Repeated griefing
Ban requested for Bob
```

#### wp.unban

Remove a player from the ban list.

```
Usage: wp.unban <player>
```

```
> wp.unban Bob
Unban requested for Bob
```

#### wp.listbans

List every name in `windrose_plus_data\wpn_bans.txt`.

```
Usage: wp.listbans
```

```
> wp.listbans
Banned (2):
  1. Bob
  2. Carol
```

---

## World

### wp.time

Read the time-of-day values the game exposes (the `TimeOfDay`, day and night length properties it finds). Read only.

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

Show server performance metrics: player count and uptime. For memory, the mod can only see its own Lua heap (`wp.memory`); use Task Manager or your host's tools for the server process.

```
Usage: wp.perf
```

```
> wp.perf
Server Performance:
  Players: 3
  Memory: use wp.memory for cached data
  Uptime: 14h 32m
```

### wp.memory

Show the mod's own Lua memory. The server process's memory is not visible from inside the mod.

```
Usage: wp.memory
```

```
> wp.memory
Memory Usage:
  Lua Heap: 2048 KB
  Process memory: not available (use Task Manager or perfpoll)
```

### wp.doctor

Show a support snapshot with runtime capabilities, module load state, feature flags, player/controller health, and config warnings.

```
Usage: wp.doctor
```

```
> wp.doctor
WindrosePlus Doctor:
  Version: 1.1.12
  Mode: active
  Uptime: 0h 42m
  Players: 2 active, 1 zombie, 2 cached
  PlayerControllers: 3

Runtime:
  LoopAsync: yes
  ExecuteInGameThread: yes
  RegisterHook: yes
  RestartMod: yes

Warnings:
  - stack_size is configured as 5x but is disabled/no-op in current PAK builds
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

### wp.speed

Set movement speed multiplier for one or all players. Accepts `[player]` argument.
The player argument can be the display name, the actor ID shown by `wp.players`,
or the session-local `player:<id>` token.

```
Usage: wp.speed [player] <multiplier>
```

Multiplier range: 0 to 20. Default is 1.0.

```
> wp.speed 2.0
Speed set to 2.0x for 3 player(s)

> wp.speed HumanGenome 1.5
Speed set to 1.5x for humangenome

> wp.speed BP_R5Character_C_2147418445 4
Speed set to 4x for bp_r5character_c_2147418445

> wp.speed player:12 1.25
Speed set to 1.25x for player:12
```

### wp.jump

Set the jump-height multiplier (`JumpZVelocity`) for one or all players. Same player-argument forms as `wp.speed`.

```
Usage: wp.jump [player] <multiplier>
```

`1.0` is normal, `2.0` is double height.

```
> wp.jump 2.0
JumpZVelocity set to 2.0x for 3 player(s)

> wp.jump HumanGenome 3
JumpZVelocity set to 3x for humangenome
```

### wp.gravity

Set the gravity multiplier (`CharacterMovement.GravityScale`) for one or all players. Same player-argument forms as `wp.speed`.

```
Usage: wp.gravity [player] <multiplier>
```

`1.0` is normal, `0.3` is moon gravity.

```
> wp.gravity 0.3
GravityScale set to 0.3x for 3 player(s)

> wp.gravity HumanGenome 2
GravityScale set to 2x for humangenome
```

### wp.tp

Teleport a player to absolute world coordinates in Unreal units. The trailing two or three arguments are the coordinates; everything before them is treated as the (possibly multi-word) player name, the same disambiguation `wp.speed` uses.

```
Usage: wp.tp [player|all] <x> <y> [z]
```

If `z` is omitted the player's current Z is kept, which works for short hops but can drop you into terrain on a cross-map jump. The Sea Chart's click-to-teleport supplies a heightmap-derived Z for that case.

Without a name it moves the only player online; with more than one player online it refuses and asks for a name. `wp.tp all <x> <y> [z]` moves everyone.

```
> wp.tp HumanGenome 100000 200000 5000
HumanGenome: tp -> (100000, 200000, 5000) ret=true

> wp.tp 100000 200000
2 players are online. Name the player to teleport, or use wp.tp all <x> <y> [z] to move everyone.
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

### wp.fields

List the real `FProperty` fields on a UE4 type via class reflection, walking the superclass chain. Optionally filter by name. Unlike `wp.props`, this reads the class layout rather than probing a live instance, so it works on types with no instance loaded.

```
Usage: wp.fields <TypeName> [filter]
```

The filter accepts pipe-delimited terms (`Steam|Unique`) and matches case-insensitive substrings.

```
> wp.fields R5PlayerState Player
R5PlayerState fields matching "Player":
  PlayerNamePrivate  (StrProperty)
  PlayerId           (IntProperty)
```

### wp.methods

List the `UFunction`s on a UE4 type via class reflection, walking the superclass chain. Optionally filter by name. Same pipe-delimited filter syntax as `wp.fields`.

```
Usage: wp.methods <TypeName> [filter]
```

```
> wp.methods R5BuildingCenterStorageComponent transfer
R5BuildingCenterStorageComponent functions matching "transfer":
  (no matches)
```

### wp.peek

Read a single property on the first valid instance of a type, dereferencing through the common wrapper shapes UE4SS returns.

```
Usage: wp.peek <TypeName> <PropertyName>
```

```
> wp.peek R5PlayerState PlayerNamePrivate
R5PlayerState.PlayerNamePrivate = HumanGenome
```

### wp.modreload

Tear down and rebuild the Windrose+ Lua state through UE4SS `RestartMod`, so edits under `WindrosePlus/Scripts/` are picked up without restarting the game server. Requires a UE4SS build that exposes `RestartMod`. This only reloads Lua. It does not rebuild override PAKs, so `.ini` and multiplier edits still need a server restart through `StartWindrosePlusServer.bat`.

```
Usage: wp.modreload
```

```
> wp.modreload
WP+ mod restart triggered (Lua state will be torn down + rebuilt)
```

---

## Map

The Sea Chart is built in two steps: the `HeightmapExporter` C++ mod exports the live world's terrain to `windrose_plus_data\terrain_v17.json` and `windrose_plus_data\heightmaps\`, then the dashboard runs `windrose_plus\tools\generateTiles.ps1` to draw the tiles. Both run on their own the first time a player joins a world that has no terrain yet, and again when the server loads a different world (Windrose+ records the world's `WorldIslandId` in `windrose_plus_data\map_world.txt`). Tile generation needs the dashboard running. Progress and errors go to `windrose_plus_data\map_generation_status.json`.

### wp.mapexport

Export the live world's terrain and rebuild the Sea Chart tiles when the export finishes. Use it after switching worlds by hand, or when the chart shows islands that are not in your world.

```
Usage: wp.mapexport
```

```
> wp.mapexport
Terrain export requested. The HeightmapExporter mod picks it up within a few seconds, then the Sea Chart tiles are rebuilt automatically.
```

### wp.mapgen

Rebuild the Sea Chart tiles from the terrain already on disk, without a new export. Use it after updating Windrose+ when the release notes say the tiles changed.

```
Usage: wp.mapgen
```

```
> wp.mapgen
Tile rebuild requested. The dashboard regenerates the Sea Chart in the background (about a minute); refresh the page when windrose_plus_data\map_generation_status.json says complete.
```

Before v1.3.18, `wp.mapgen` only wrote a landscape diagnostic (`terrain_probe.json`) and did not touch the tiles. That diagnostic is now the hidden debug command `wp.mapprobe`.

### wp.mapprobe

Hidden debug command. Writes the landscape actors, components and map-related objects the server can see to `windrose_plus_data\terrain_probe.json`. It does not change the Sea Chart.

```
Usage: wp.mapprobe
```

### wp.nativeprobe

Hidden debug command that triggers the experimental `WindroseNativeProbe` C++
mod. The native probe is not auto-enabled by the installer; only enable it on a
non-production test server when collecting runtime research data.
It writes a read-only runtime reflection dump to
`windrose_plus_data/native_probe.json`. The JSON includes a full lightweight
`classIndex` for every matching class and a priority-ordered detailed `classes`
array for R5, player, inventory, storage, item, chat, and network research.

```
Usage: wp.nativeprobe
```

```
> wp.nativeprobe
Native probe requested. Check windrose_plus_data\native_probe.json after a few seconds.
```

---

## HTTP API Endpoints

The web dashboard exposes a REST API for external tools and integrations. Dashboard, admin, config, repair, and RCON endpoints need the RCON password: either the session cookie from logging in to the dashboard, or the password in an `X-RCON-Password` header (scripts and other tools). `POST /api/rcon` also accepts it as a `password` field in the JSON body. Ten wrong passwords from one address within five minutes block that address for the rest of the five minutes (HTTP 429). Requests from the server machine itself need the password too unless `server.trust_loopback` is set (see the config reference). `/api/health` is public for monitoring. Catalog assets are public because they contain generic game data, not player or admin data. The map-only public endpoints are available only when `livemap.public.enabled` is true in `windrose_plus.json`, and public runtime-overlay access follows the same public-map token rules.

Logging in (`POST /login` with a form field `password`) sets a cookie named `wp_session_<port>`, for example `wp_session_8780`, valid for 24 hours. Each dashboard on a machine has its own cookie, so being logged in to two servers on one address works. Changing the RCON password logs everyone out; `/logout` clears the cookie in that browser. A `POST` logged in by the cookie alone must be sent as `application/json` (the console) or `application/zip` (character repair), which keeps another web page from posting commands with your cookie; the `X-RCON-Password` header has no such rule. Request bodies have limits: 8 KB for the login, 64 KB for a console command, both sent within 10 seconds; larger requests get HTTP 413.

`server/routes.json` in every release lists every route the dashboard answers, with its method and login rule. Its `routes_version` goes up whenever a route is added or removed or a request or response format changes, so a tool built against these routes can compare it after an update. `tools/PAK_BUILDER_VERSION` goes up whenever the generated PAK output changes (new or renamed config keys, different files or fields patched, changed scaling or rounding, a new repak or retoc). Both numbers are also in `/api/health`.

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET | `/api/health` | No | Health check: returns `{"status": "ok", "version": "...", "routes_version": 2, "pak_builder_version": 2, "timestamp": ...}` |
| GET, POST | `/login` | No | Login page; a form field `password` sets the `wp_session_<port>` cookie |
| GET, POST | `/logout` | No | Clears this dashboard's cookie and goes back to the login page |
| GET | `/catalog/*` | No | Item catalog JSON for the Sea Chart item browser (built on the server from the game files, `windrose_plus_data\catalog\v1`; 503 while it is being built) and the Windrose+ item icons. |
| GET | `/vendor/*` | No | Bundled web libraries and fonts for the dashboard and Sea Chart |
| GET | `/public-map` | No (if enabled) | Map-only Sea Chart page. Requires `livemap.public.enabled`; if `livemap.public.token` is set, pass `?token=<token>` (or send it in an `X-WindrosePlus-Map-Token` header). |
| GET | `/public-map/tiles/{z}/{x}-{y}.png` | No (if enabled) | Sea Chart tiles for the public map. Same public-map rules. |
| GET | `/api/public/pois` | No (if enabled) | POI scanner markers for the public map. Same public-map rules. |
| GET | `/api/public/livemap` | No (if enabled) | Public player/creature map positions. Same public-map config/token rules as `/public-map`. |
| GET | `/api/public/mapinfo` | No (if enabled) | Public map coordinate metadata. Same public-map config/token rules as `/public-map`. |
| GET | `/api/public/runtime-overlay` | No (if enabled) | Public optional live save-state overlay for the Sea Chart. Same public-map config/token rules as `/public-map`. |
| GET | `/api/status` | Yes | Server status: player list, multipliers, server info |
| GET | `/api/livemap` | Yes | Live map data: player positions, mobs, resource nodes |
| GET | `/api/pois` | Yes | POI scanner markers |
| GET | `/livemap/tiles/{z}/{x}-{y}.png` | Yes | Sea Chart tiles. Asked for with `?v=<tileset_id>` from `map_coords.json`, they may be cached for a day |
| GET | `/api/terrain_height?x={x}&y={y}` | Yes | Ground height at a world position, from the exported heightmap (used by click-to-teleport) |
| GET | `/api/runtime-overlay` | Yes | Optional live save-state overlay for chests, buildings, saved player positions, fog reveal, and quest blackboard layers. |
| GET | `/api/config` | Yes | Current config (RCON password masked) |
| GET | `/api/commands` | Yes | Live command catalog for console autocomplete, sourced from the Lua side via `windrose_plus_data/commands.json`. |
| GET | `/api/pak-status` | Yes | Generated PAK status, stale-config detection, and recent CurveTable patch summary. |
| GET | `/api/mapinfo` | Yes | Map coordinate metadata for tile rendering |
| GET | `/api/rcon/log` | Yes | The newest console commands (up to 50) from the activity log, as a JSON array of `{timestamp, ip, command, status}` |
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
    "message": "Players: 3\nLoot: 2x\nXP: 3x\nWindrosePlus v1.3.16"
}
```

From a script:

```
curl -X POST http://localhost:8780/api/rcon -H "X-RCON-Password: your_rcon_password" -H "Content-Type: application/json" -d "{\"command\": \"wp.status\"}"
```
