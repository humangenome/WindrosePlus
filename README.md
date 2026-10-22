<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/windroseplus-landscape-dark.png">
    <img src="docs/brand/windroseplus-landscape.png" alt="Windrose+" width="550">
  </picture>
</p>

# Windrose+

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![UE4SS](https://img.shields.io/badge/UE4SS-experimental-blue.svg)](https://github.com/UE4SS-RE/RE-UE4SS)
[![Windrose](https://img.shields.io/badge/Windrose-Dedicated_Server-darkgreen.svg)](https://store.steampowered.com/app/3041230/)
[![No Client Mods](https://img.shields.io/badge/Client_Mods-Not_Required-brightgreen.svg)](#features)

Everything your Windrose dedicated server is missing: multipliers, a live map, an admin console, a status feed for monitoring tools, and mod support. Server-side only, no client mods required.

_Windrose+ is a community project and is not affiliated with or endorsed by the developers of Windrose._

> **[Rent a Windrose server](https://www.survivalservers.com/services/game_servers/windrose/?utm_source=github&utm_medium=readme&utm_campaign=windrose_plus)**. Survival Servers game servers come with Windrose+ already installed.

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Using Windrose+](#using-windrose)
- [Contributing](#contributing)
- [License](#license)

---

## Features

### Live Sea Chart
A real-time map of your server showing island terrain, player and creature positions, points of interest found by the POI scanner, and a searchable item catalog. Item detail pages include rarity, tier, stack, stats, effects, crafting recipes and stations, trader offers, building costs, research unlocks, where the item drops, and map links for sources that match a POI scanner marker.

![Sea Chart with the Layers panel open](docs/screenshots/seachart.png)

The Items panel browses every item in the game with group/type/rarity/tier filters and click-through to recipes, trader offers, and map source hits. The dashboard builds this catalog on your server from your own copy of the game (`tools/WindrosePlus-BuildCatalog.ps1`, about a minute, written to `windrose_plus_data\catalog\v1`), so it always matches the game version you run and rebuilds itself after a game update. Nothing from the game ships with Windrose+. Each item shows an icon for its kind (food, armour, ship weapon and so on).

![Items panel with an item open](docs/screenshots/seachart-items.png)

### Admin Console (RCON)
Run commands from a web dashboard with autocomplete. Check who's online, view server stats, monitor performance, and manage your server remotely. 32 built-in commands, plus 12 debug commands listed by `wp.help all`.

![Console](docs/screenshots/console.png)

### Server Status
Windrose dedicated servers don't answer standard server queries, so external tools can't read player counts or status. Windrose+ writes the server's status to `windrose_plus_data\server_status.json` every 5 seconds (every 30 with nobody online), and the dashboard serves it at `/api/status` (login or `X-RCON-Password` required), so monitoring tools and bots can read it. It does not make the server answer server-browser queries.

```json
{
  "server": {
    "name": "My Windrose Server",
    "game": "Windrose",
    "version": "0.10.0.9.32",
    "windrose_plus": "1.3.22",
    "invite_code": "a1b2c3d4",
    "password_protected": false,
    "max_players": 10,
    "player_count": 2,
    "game_port": 7777
  },
  "players": [
    { "name": "HumanGenome", "player_id": 12, "session_id": "player:12", "actor_id": "BP_R5Character_C_2147418445", "alive": true, "x": 14520, "y": -8340 },
    { "name": "CaptainMorgan", "player_id": 17, "session_id": "player:17", "actor_id": "BP_R5Character_C_2147418362", "alive": true, "x": 6200, "y": 1100 }
  ],
  "perf": { "world_time": 1834.5 },
  "multipliers": {
    "xp": 3.0, "loot": 2.0,
    "craft_efficiency": 2.0, "cooking_speed": 2.0, "harvest_yield": 2.0
  },
  "timestamp": 1792000000
}
```

`player_id` / `session_id` are server-local live-session identifiers from Windrose's `PlayerState.PlayerId`. They are useful for disambiguating two online players with the same display name, but they are not persistent Steam IDs and should not be used for permanent bans.

### 2,400+ Server Settings & Multipliers
Adjust XP, loot, crafting costs, cooking/smelting speed, harvest yield, and more through a simple JSON file. Go deeper with 2,400+ individual INI settings for player stats, weapons, food effects, creature stats, co-op scaling, swimming, and rest bonuses.

**Active multipliers** (`windrose_plus.json`):
```json
{
  "xp": 3.0,
  "loot": 2.0,
  "craft_efficiency": 2.0,
  "cooking_speed": 2.0,
  "harvest_yield": 2.0
}
```

**Player Stats** (`windrose_plus.ini`):
```ini
[PlayerStats]
MaxHealth = 320
MaxStamina = 150
StaminaRegRate = 40
MaxPosture = 40
Armor = 0
MaxWeight = 99999
```

**Food Effects** (`windrose_plus.food.ini`):
```ini
[Food_Drink]
Food_Drink_Coffee_T03_Duration = 1800
Food_Drink_Coffee_T03_Endurance = 20
Food_Drink_Coffee_T03_MaxHealth = 160
Food_Drink_Coffee_T03_Mobility = 20

[Alchemy_Potions]
Alchemy_Potion_Healing_Base_HealthRestoreRatio = 0.35
Alchemy_Potion_Healing_Great_HealthRestoreRatio = 0.8
```

#### Multiplier PAK safety

A handful of multiplier keys are disabled, a few more are gated behind explicit opt-in, and there's a safe path for recovery if a PAK ever causes trouble.

- **Disabled keys.** `points_per_level`, `stack_size`, `weight`, `inventory_size`, and `crop_speed` are parsed for backward compatibility but no longer write PAK changes; they were disabled after crash reports from the character, inventory, and crop validators. `wp.givestats` records an audit note only and does not change a character in-game.
- **Save-state risk.** `inventory_size`, `stack_size`, `weight`, and other inventory-affecting PAK edits can become part of player save state once a character logs in. Take an out-of-band save backup before enabling them. Windrose+ refuses to build these high-risk multiplier PAKs when another installed PAK also edits inventory assets and removes the existing generated multiplier PAK on that failure, unless `WINDROSEPLUS_ALLOW_PAK_CONFLICTS=1` is set.
- **Emergency multiplier-PAK disable.** Set `WINDROSEPLUS_DISABLE_MULTIPLIER_PAK=1` before `StartWindrosePlusServer.bat`. The wrapper removes/skips `R5\Content\Paks\WindrosePlus_Multipliers_P.pak` and `windrose_plus_data\.windroseplus_multiplier_history.json` while keeping the dashboard, RCON, Sea Chart, mods loader, and CurveTable PAKs available. Non-default values in `windrose_plus.json` / `windrose_plus.harvest.ini` will not apply until the env var is removed and the server is started through the wrapper again.
- **Full recovery / disable.** Stop the server, rename `R5\Binaries\Win64\dwmapi.dll`, delete or move the generated overrides (`WindrosePlus_Multipliers_P.pak`, plus `WindrosePlus_CurveTables_P.pak` / `.utoc` / `.ucas`, all three parts of the CurveTable container), then delete `windrose_plus_data\.windroseplus_build.hash`. Removing settings from `windrose_plus.json` alone is not enough because UE4SS and existing PAK overrides can still load. Restore a save backup from before the inventory-affecting PAK change, confirm the character can join, then re-enable PAK overrides one at a time.

### Mod Support
Add custom commands, scheduled tasks and player join/leave hooks in Lua. Put a mod folder in `WindrosePlus/Mods/` and add its name to `Mods/mods_registry.json`; edits reload within 30 seconds without restarting the server.

**For modders:** full API reference, manifest format, and examples are in [docs/scripting-guide.md](docs/scripting-guide.md). Admin command list: [docs/commands.md](docs/commands.md). Config keys: [docs/config-reference.md](docs/config-reference.md). Research notes on server-side storage hooks: [docs/research/storage-hook-research.md](docs/research/storage-hook-research.md).

Ships with an example mod:

```lua
-- example-welcome/init.lua
local API = WindrosePlus.API

API.onPlayerJoin(function(player)
    API.log("info", "Welcome", player.name .. " joined the server")
end)

API.onPlayerLeave(function(player)
    API.log("info", "Welcome", player.name .. " left the server")
end)

API.registerCommand("wp.greet", function(args)
    local players = API.getPlayers()
    local names = {}
    for _, p in ipairs(players) do table.insert(names, p.name) end
    return "Ahoy, " .. table.concat(names, ", ") .. "!"
end, "Greet all online players")
```

### Server Activity Log
Windrose+ records server-side activity to `windrose_plus_data\logs\YYYY-MM-DD.log` for review and external tooling. Files are line-delimited JSON, append-only, and rolled daily; they survive server restarts and crashes.

Recorded events:

| `ev`                | Fires on                                              |
|---------------------|--------------------------------------------------------|
| `mod.boot`          | Windrose+ initializes (version, game dir, hook avail.) |
| `config.load`       | `windrose_plus.json` is loaded or reloaded             |
| `config.load.fail`  | Config parse fails, defaults are used                  |
| `player.join`       | A player connects                                      |
| `player.leave`      | A player disconnects                                   |
| `admin.command`     | Any `wp.*` command runs (caller, args, result, ms)     |
| `heartbeat`         | Every 5 minutes: uptime, mode, player count, config    |

Each line carries a fixed envelope: `ts` (UTC ISO-8601), `ts_unix`, `sid` (per-boot session id), `ev`, and `payload`. External tools (and mods, via `WindrosePlus.API.logEvent(ev, payload)`) can tail the current day's file or read past days for replay.

Quick queries with `jq`:

```bash
# What multipliers were active during the corruption window?
jq 'select(.ev=="heartbeat") | {ts, mult: .payload.multipliers}' logs/2026-04-27.log

# Who ran which admin commands?
jq 'select(.ev=="admin.command") | {ts, admin_user, command, status}' logs/2026-04-27.log
```

## Installation

You need a Windrose Dedicated Server already set up on Windows. If you do not have one yet, you can start with [SurvivalServers.com Windrose hosting](https://www.survivalservers.com/services/game_servers/windrose/?utm_source=github&utm_medium=readme_install&utm_campaign=windrose_plus) with Windrose+ pre-installed, or install the official Windrose Dedicated Server tool yourself and extract Windrose+ into that server folder.

### Step 1: Download and Install

1. Download `WindrosePlus.zip` from the latest [GitHub Release](https://github.com/HumanGenome/WindrosePlus/releases/latest). Do not use GitHub's "Source code" zip for installation; generated tool binaries such as `tools/bin/repak.exe` and `tools/bin/retoc.exe` are added to the release asset only.
2. Extract the zip into your Windrose Dedicated Server folder (e.g. `C:\WindroseServer\`).
3. Open PowerShell in that folder and run:

```powershell
.\install.ps1
```

If PowerShell refuses to run it (scripts are blocked by default on Windows, and a zip downloaded with a browser is marked as from the internet), run `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` instead.

This downloads UE4SS (the exact build Windrose+ is tested with, checked against its SHA-256), installs the mod, and sets up the dashboard. Reinstalling keeps your configs and mods; it does rewrite `ue4ss\UE4SS-settings.ini` with the settings Windrose needs, so copy that file first if you changed it. If the server already has a different UE4SS build, the installer swaps in the tested loader files and keeps your mods and settings; run `.\install.ps1 -KeepCurrentUE4SS` to leave yours in place.

### Step 2: Start Your Server

Edits to `multipliers` in `windrose_plus.json` or to any `.ini` file need to be baked into a game override PAK before the server launches; otherwise the game loads the unmodified defaults. That rebuild step is what `tools/WindrosePlus-BuildPak.ps1` does.

**The easy way:** run `StartWindrosePlusServer.bat` (installed at your server root). It runs the rebuild step if anything changed (no-op in milliseconds otherwise), then launches `WindroseServer.exe`.

If you need to recover from a bad PAK or test without multipliers, see [Multiplier PAK safety](#multiplier-pak-safety).

**If you already have your own launcher**, add one line before whatever calls `WindroseServer.exe`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<gameDir>\windrose_plus\tools\WindrosePlus-BuildPak.ps1" -ServerDir "<gameDir>" -RemoveStalePak
```

Non-zero exit means the build failed, so don't launch the game.

Windrose+ loads automatically either way.

> **Note:** If the server folder is under `Program Files`, run the installer and the server as Administrator so they can write there. The dashboard needs Administrator rights (or a URL reservation) to listen on every network address; without them it listens on localhost only.

To start the web dashboard, open a second terminal in your game server folder and run:

```powershell
windrose_plus\start_dashboard.bat
```

The dashboard URL and RCON password are shown in the console. On first run, a `windrose_plus.json` config file is created with defaults.

By default the dashboard listens on all interfaces when PowerShell is elevated, then falls back to localhost if Windows blocks the wildcard listener. Multi-IP hosts can bind it to one address:

```powershell
windrose_plus\start_dashboard.bat -BindIp 192.0.2.10
```

You can also set `"server": { "bind_ip": "192.0.2.10" }` in `windrose_plus.json`.

### Hosting panels and Docker

Some hosting panels and Docker images install Windrose+ for you from the latest release. To stay on one version, use that release's own download, `https://github.com/HumanGenome/WindrosePlus/releases/download/<tag>/WindrosePlus.zip` (for example `v1.3.25` as the tag), and check it against the `SHA256SUMS.txt` published with that release (from v1.3.25 on).

---

## Using Windrose+

### Configuring Your Server

Windrose+ has two config files:

- **`windrose_plus.json`** (basic): multipliers, the RCON and dashboard password, the dashboard port, and Sea Chart options. Created automatically on first launch. Edit this for everyday changes.
- **`windrose_plus.ini`** (advanced): player base stats, weapon damage, food effects, creature stats, talents, combat tuning. Optional: copy `windrose_plus\config\windrose_plus.default.ini` to `windrose_plus.ini` if you want to customize.

Example `windrose_plus.json`:

```json
{
    "multipliers": {
        "loot": 2.0,
        "xp": 3.0,
        "craft_efficiency": 2.0,
        "cooking_speed": 2.0,
        "harvest_yield": 2.0
    },
    "rcon": {
        "enabled": true,
        "password": "your-password-here"
    },
    "server": {
        "http_port": 8780,
        "bind_ip": ""
    },
    "livemap": {
        "public": {
            "enabled": false,
            "token": ""
        }
    }
}
```

Multiplier and `.ini` edits need the override PAK rebuilt before the next launch. See [Step 2](#step-2-start-your-server) for the rebuild command (`StartWindrosePlusServer.bat` handles it for you). The RCON password and Sea Chart options are read live and take effect without a rebuild.

See [docs/config-reference.md](docs/config-reference.md) for every advanced INI setting.

### Dashboard

Open the dashboard in your browser to manage your server. It includes a command console with autocomplete and a live Sea Chart showing terrain, players, mobs, points of interest, and item drop sources in real time.

The dashboard asks for the RCON password from every browser, including one on the server itself. Scripts and other tools send the same password in an `X-RCON-Password` header ([HTTP API](docs/commands.md#http-api-endpoints)). If you put the dashboard behind a reverse proxy on the same machine that does its own login, set `"server": { "trust_loopback": true }` to let it through.

If you want friends to see the Sea Chart without the dashboard password, enable the optional map-only view:

```json
{
  "livemap": {
    "public": {
      "enabled": true,
      "token": "optional-share-token"
    }
  }
}
```

Then share `/public-map` or `/public-map?token=optional-share-token`. This exposes only the map view, public map data, tiles, and catalog assets; the console, config, and admin APIs still require the dashboard login.

Sea Chart can also render optional runtime save overlays when another local tool writes `windrose_plus_data/runtime_overlay.json`. That file is intentionally separate from the dashboard core: if it is absent, the map still loads terrain, players, POI scanner markers, resources, and item data normally; if present, `/api/runtime-overlay` and the token-gated public map path render chest state, buildings, saved player positions, fog reveal, and quest blackboard layers from the same JSON schema.

### Commands

Type `wp.help` in the console to see all available commands. Common ones:

| Command | What it does |
|---------|-------------|
| `wp.status` | Server info and active multipliers |
| `wp.players` | Who's online and where |
| `wp.config` | Current settings |
| `wp.creatures` | What's spawned on the map |
| `wp.memory` | Server memory usage |
| `wp.doctor` | Support snapshot and config warnings |

Full reference: [docs/commands.md](docs/commands.md)

### Advanced: INI Settings

For fine-grained control beyond multipliers, Windrose+ supports 2,400+ individual settings across player stats, weapons, food, gear, and creatures.

Copy any `.default.ini` from the `config/` folder, rename it (drop `.default`), and edit only the values you want to change. Full reference: [docs/config-reference.md](docs/config-reference.md)

Type-specific files such as `windrose_plus.food.ini` and `windrose_plus.weapons.ini` can be used without creating a root `windrose_plus.ini`. `StartWindrosePlusServer.bat` includes those files in the rebuild hash, so edits trigger a new PAK build on the next launch.

### Mods

Windrose+ supports custom Lua mods. Put a folder with a `mod.json` and your script into `WindrosePlus/Mods/`, then add the folder name to `Mods/mods_registry.json` (a JSON array such as `["my-mod"]`; `install.ps1` writes it for the mod folders it finds). Edits to a listed mod reload within 30 seconds.

See [docs/scripting-guide.md](docs/scripting-guide.md) for the API and examples.

---

<details>
<summary><strong>Troubleshooting</strong></summary>

- **Server crashes on startup** - Check `UE4SS-settings.ini`. The current Windrose-safe defaults keep `HookProcessInternal = 1`, `HookEngineTick = 0`, `HookUObjectProcessEvent = 0`, and `DefaultExecuteInGameThreadMethod = EngineTick`. Older guidance to enable `HookEngineTick` or switch the dispatcher to `ProcessEvent` is no longer correct.
- **RCON not working** - Set a real password in `windrose_plus.json` (not blank, not `changeme`).
- **Dashboard commands time out except `wp.help`** - Fully stop the game process and dashboard, then start them again. If you launched with `StartWindrosePlusServer.bat`, closing the console window can leave `WindroseServer-Win64-Shipping.exe` running in the background; stop it in Task Manager before relaunching.
- **No map data** - Windrose loads the world when the first player joins, so the terrain export runs then. The dashboard must be running to draw the tiles. If the Sea Chart still says "not ready", check `windrose_plus_data\map_generation_status.json`; it records whether tile generation is running, complete, or failed. The item catalog can load before terrain is ready, but "show on map" source links need the POI scanner's markers, which appear after the first player joins.
- **Items panel says the catalog is not built** - The dashboard builds it from the game files when it starts; the log is `windrose_plus_data\catalog\build.log`. It needs `tools\bin\repak.exe` (and `retoc.exe` for stat values), which antivirus sometimes quarantines. Rebuild by hand with `windrose_plus\tools\WindrosePlus-BuildCatalog.ps1 -GameDir <server folder> -Force`.
- **Server crashes a few seconds after start now and then** - UE4SS's sample mods (CheatManagerEnablerMod, ConsoleCommandsMod, ConsoleEnablerMod, BPML_GenericFunctions, BPModLoaderMod, Keybinds) cause it on Windrose. The v1.3.22 installer switches them off; on an older install set each of those lines to 0 in `R5\Binaries\Win64\ue4ss\Mods\mods.txt` and restart.
- **Sea Chart shows islands from another world** - Before v1.3.18 the terrain export was never redone after a world change. Run `wp.mapexport` while a player is online; it exports the current world and rebuilds the tiles. From v1.3.18 a world change is picked up on the first player join.
- **Sea Chart is a quarter turn off the in-game map** - Fixed in v1.3.22. The chart is drawn like the in-game map: world X to the right, world Y down, so compass north (world -Y) is at the top. v1.3.16 to v1.3.21 put world +X at the top instead. Tiles built by those versions (`"orientation": "north-up"` in `windrose_plus_data\map_coords.json`) are turned back as the chart draws them, so updating is enough; `wp.mapgen` rebuilds them in the new layout whenever convenient. Hard-refresh the page after updating.
- **CurveTable PAK fails with a retoc error** - Run `windrose_plus\tools\WindrosePlus-BuildPak.ps1 -ForceExtract` once so the cache is rebuilt and the full retoc error is shown. If the message mentions `ScriptObjects`, update Windrose+: very old builds passed only one `.utoc` file to retoc instead of the full `R5\Content\Paks` folder.
- **INI settings apply only on v1.3.16 or newer** - Up to v1.3.15 the CurveTable override was written as a legacy `.pak`. Windrose keeps those assets in an IoStore container, and UE5 resolves them from the container, so the override was built and verified correctly but never reached the running game. Nothing in `windrose_plus.ini` (or the weapons / food / gear / entities files) took effect. v1.3.16 writes the override as an IoStore container instead. Update, then start the server through `StartWindrosePlusServer.bat` so the container is rebuilt.
- **Food / weapon / gear INI changes build but do not show in-game** - The game reads CurveTable overrides only when the process starts, and the container cannot be replaced while the server is running. Fully stop every `WindroseServer-Win64-Shipping.exe` process, run the server through `StartWindrosePlusServer.bat`, and confirm the builder prints `CurveTables PAK` plus `Patched ... values (verified)`. The last verified patch set is written to `windrose_plus_data\.windroseplus_curvetables_manifest.json` and summarized by `/api/pak-status`. To verify the food asset is inside the generated container, run `windrose_plus\tools\bin\retoc.exe list R5\Content\Paks\WindrosePlus_CurveTables_P.utoc | findstr /i CT_Food_GE_Values`.
- **Multiplier PAK / save issues / full recovery** - See [Multiplier PAK safety](#multiplier-pak-safety) for the disable env var, recovery steps, and save-backup guidance.

</details>

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Disclaimer

Windrose+ is a community project and is not affiliated with or endorsed by the developers of Windrose. Use at your own discretion and in accordance with the [Windrose EULA](https://playwindrose.com/eula/).

---

## License

MIT. See [LICENSE](LICENSE).

## Credits

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) - Unreal Engine scripting and modding framework
- [rxi/json.lua](https://github.com/rxi/json.lua) - Pure Lua JSON library (MIT)
- Item and map icons were made for Windrose+ and are MIT licensed like the rest of the repository.
