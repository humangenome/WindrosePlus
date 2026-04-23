# Changelog

## [1.0.13] - 2026-04-23

### Fixed

- **Added dashboard Bind IP support ([#26](https://github.com/HumanGenome/WindrosePlus/issues/26)).** Multi-IP hosts can now pass `-BindIp` to `start_dashboard.bat` or set `server.bind_ip` in `windrose_plus.json`.
- **Fixed type-specific INI rebuild detection ([#15](https://github.com/HumanGenome/WindrosePlus/issues/15)).** `windrose_plus.food.ini`, `windrose_plus.weapons.ini`, `windrose_plus.gear.ini`, and `windrose_plus.entities.ini` are now honored even when no root `windrose_plus.ini` exists.
- **Made empty CurveTable extraction caches fail loudly ([#22](https://github.com/HumanGenome/WindrosePlus/issues/22)).** Failed or incompatible `retoc` extraction no longer degrades into "No CurveTable changes needed"; the builder clears empty caches, retries extraction, and surfaces the retoc output.

### Changed

- **Documented save-safety and full-disable recovery steps ([#25](https://github.com/HumanGenome/WindrosePlus/issues/25)).** README and config reference now warn about inventory-affecting PAK edits, conflicting PAK mods, and how to fully disable Windrose+ for recovery testing.
- **Added Windrose Server Manager to integrations ([#8](https://github.com/HumanGenome/WindrosePlus/issues/8)).**

## [1.0.12] - 2026-04-23

### Changed

- **Moved Idle CPU Limiter opt-in to `windrose_plus.json`.** Self-hosted admins can now set `performance.idle_cpu_limiter_enabled` and `performance.idle_cpu_limit_percent` instead of creating marker files by hand. The installer still honors the old marker files for compatibility.
- **Documented CPU limiter setup for normal server owners.** README and config reference now show the exact JSON block to enable or disable the limiter and explain when to raise the idle CPU percent.

## [1.0.11] - 2026-04-23

### Fixed

- **Avoided accidental idle CPU limiter re-enables on upgrade.** Self-hosted installs now require either `windrose_plus_data\idle_cpu_limiter_enabled` or a custom `idle_cpu_limiter_cpu_rate.txt` before the installer enables the limiter. Fresh and upgraded installs remain disabled unless the server owner opts in.
- **Made multiplier PAK no-op handling explicit.** `points_per_level` is ignored when deciding whether a multiplier PAK is expected, stale multiplier PAKs are removed when there are no active PAK-backed multipliers, and active non-default multipliers now fail loudly if no files were modified.
- **Reloaded RCON config before password checks.** Dashboard/RCON password changes now apply on the next command instead of requiring a server restart.

### Changed

- Release packaging now fetches the bundled C++ mod DLLs from a pinned release tag and verifies SHA-256 hashes before building the public ZIP.

## [1.0.10] - 2026-04-23

### Fixed

- **Made the idle CPU limiter boot and rejoin safe ([#23](https://github.com/HumanGenome/WindrosePlus/issues/23)).** The opt-in limiter now waits for real Windrose server readiness (`Login finished successfully` plus `Initialized as an R5P2P listen server`) and for fresh post-boot `server_status.json` writes before applying the idle CPU cap. It also watches the dedicated-server log for early P2P/ICE connection activity and lifts the cap immediately when a player starts connecting, instead of waiting for `player_count` to flip. On the tested Survival Servers admin host this preserved ~`2%` idle CPU with no join/login kick on capped idle rejoin.

## [1.0.9] - 2026-04-23

### Fixed

- **Made the idle CPU limiter opt-in after slow-load/time-out reports ([#23](https://github.com/HumanGenome/WindrosePlus/issues/23)).** The limiter used Windrose+'s `player_count` status to decide when the server was idle, but Windrose can still report zero players while someone is connecting, loading a character, or finishing the tutorial. That meant the server could stay under the low idle CPU cap during the join path and time out before the player became visible. Installs and upgrades now create `windrose_plus_data\idle_cpu_limiter_disabled` by default unless the host already has a custom `idle_cpu_limiter_cpu_rate.txt`, and hosts can opt in by deleting the disabled marker.

### Changed

- **Documented manual limiter controls.** `windrose_plus_data\idle_cpu_limiter_disabled` disables the limiter, and `windrose_plus_data\idle_cpu_limiter_cpu_rate.txt` can raise or lower the cap for hosts that explicitly opt in.

## [1.0.8] - 2026-04-23

### Fixed

- **`points_per_level` multiplier disabled — character-corruption crash ([#20](https://github.com/HumanGenome/WindrosePlus/issues/20), [#4](https://github.com/HumanGenome/WindrosePlus/issues/4)).** Patching `TalentPointsReward` / `StatPointsReward` / `PointsReward` / `SkillPoints` / `AttributePoints` in `DA_HeroLevels.json` caused the engine's `R5BLPlayer_ValidateData` rule to fail `RewardLevel < CurrentLevel`, crashing the server with `R5GameProblems.cpp:211` the moment the affected character tried to join. Isolated to a single-file PAK with `pts=3` alone on a virgin world — still crashes. `MultiplierPakBuilder.ps1` now skips the `points_per_level` patch path entirely; config still accepts the key for future re-enablement but applies no modifications. `wp.givestats` remains the supported way to grant extra points.
- **Surface AV-quarantine as the cause when `repak.exe` / `retoc.exe` are missing ([#19](https://github.com/HumanGenome/WindrosePlus/issues/19)).** `WindrosePlus-BuildPak.ps1` now detects a missing binary under `tools\bin\` and explicitly calls out Windows Defender / third-party AV quarantine as the most likely cause, with allowlist instructions.
- **Idle Windrose servers no longer burn full CPU cores while waiting for players.** Replaced the old affinity-based idle optimizer with a C++ `IdleCpuLimiter` UE4SS mod that applies a Windows Job Object CPU hard cap only while the server is confirmed idle. The default idle cap is 2% total CPU, the cap is lifted automatically when players are present, the process keeps its full CPU affinity mask, and the limiter fails open if player status is missing or stale.
- **Removed the Lua affinity signal path.** Windrose+ no longer writes affinity request files or changes process affinity when servers enter idle/active mode.
- **Fixed idle status recursion.** The zero-player transition no longer re-enters the status writer repeatedly, and idle status checks now stay frequent enough to lift the CPU cap quickly when activity appears.

### Added

- **Bundled `IdleCpuLimiter.dll` in releases and the installer.** Fresh installs and upgrades now place it under `ue4ss\Mods\IdleCpuLimiter\dlls\main.dll` and enable it in `mods.txt`.

### Known Issues

- **`stack_size` multiplier has no in-game effect ([#17](https://github.com/HumanGenome/WindrosePlus/issues/17)).** Server-side PAK patching of `InventoryItemGppData.MaxCountInSlot` is overridden by client-side caps; the knob requires a matching client mod to take effect. The setting is still accepted in config for server operators who distribute a matching client PAK, but it will not change stack caps for vanilla clients.

## [1.0.7] - 2026-04-19

### Fixed

- **`MultiplierPakBuilder.ps1` crash on large `GrowthDuration` values ([#7](https://github.com/HumanGenome/WindrosePlus/issues/7)).** The crop-speed patcher cast the divided duration to `[int]` (Int32, max ~2.1 billion). Windrose stores some growth durations in game-time units that exceed that ceiling — the one reported hit 21 billion — so the cast threw `InvalidCastIConvertible` and aborted the build. Same fix applied to `Exp` (levels with huge XP requirements) and `CookingProcessDuration` so long production timers can't trip the same ceiling. All three now use `[long]` (Int64).
- **`wp.speed` refused to match players whose name contains a space ([#5](https://github.com/HumanGenome/WindrosePlus/issues/5)).** Handler assumed `args[1]` was the whole name and `args[2]` was the multiplier, so RCON whitespace-tokenizing "John Smith 1.5" into three args left `args[2] = "Smith"` which `tonumber` rejected. Now peels the multiplier off the trailing arg and joins everything before it as the name — same pattern already used by `wp.givestats`.
- **`wp.speed 1.0` did not visibly restore normal speed until server restart ([#5](https://github.com/HumanGenome/WindrosePlus/issues/5)).** `CheatMovementSpeedModifer` isn't replicated — setting it server-side updated server prediction but the client kept running at the old speed. Handler now caches each pawn's original `MaxWalkSpeed` on first touch and writes `MaxWalkSpeed = base * mult` alongside the cheat modifier, so `wp.speed <player> 1.0` takes effect immediately.

## [1.0.6] - 2026-04-18

### Fixed

- **Stale version / invite code in `/status` after a Windrose game patch.** The query module loaded `R5\ServerDescription.json` once at server boot and cached the parsed values in memory, so when Windrose stamped a new `DeploymentId` into that file after a game update the HTTP endpoint kept reporting the old version until the dedicated server was restarted a second time. `_collectAndWrite` now re-reads the file every cycle, so `version`, `invite_code`, `name`, `password_protected`, and `max_players` reflect whatever is currently on disk within one status tick (5s active, 30s idle). The read is guarded by the existing `pcall(json.decode, …)`, so a mid-write race with the game leaves the previous cached values intact for that cycle.

## [1.0.5] - 2026-04-18

### Added

- **New `harvest_yield` multiplier.** Scales `Amount.Min`/`Amount.Max` on every entry inside `ResourcesSpawners/` JSON assets, so harvesting a resource node (berries, ore, wood, herbs, etc.) drops more (or fewer) items per interaction. Independent of `loot` (chest/enemy drops) and `crop_speed` (farm growth time). Range `0.1`–`100.0`, defaults to `1.0`. Surfaces in `wp.config`, `wp.status`, `server_status.json`, and the dashboard. Min stays at `1` after rounding so a low multiplier can't zero out a node.

### Notes

Issue [#4](https://github.com/HumanGenome/WindrosePlus/issues/4) (per-level stat rewards skipped when XP gain crosses multiple levels) remains open. The required engine-level catchup hook on `R5HeroLevelUpComponent` is still risky to register inside Windrose's UE4SS host (other RegisterHook attempts have crashed the server in earlier dev passes), so the fix stays deferred. `wp.givestats` (added in 1.0.4) is the manual compensation path; it still records to `windrose_plus_data/stat_grants_queue.log` for audit.

## [1.0.4] - 2026-04-18

### Added

- **`wp.givestats <player> <stat_count> [talent_count]` admin command.** Records stat/talent point grant requests to a per-server queue file (`windrose_plus_data/stat_grants_queue.log`) so server owners can audit who needs compensation for [#4](https://github.com/HumanGenome/WindrosePlus/issues/4) — characters that level up multiple times in a single XP gain only fire one stat-point reward, even though they cleared several levels at once. Each invocation appends a timestamped JSON entry; the in-game application of those points lands in v1.0.5 alongside the level-up catchup hook (see notes below). Range `1`–`100` per axis. Player names with spaces are supported.
- **Append-only `windrose_plus_data/events.log`.** Line-delimited JSON records every player join and leave so external server-management tools can `tail -F` the file without polling the HTTP API or scraping the dashboard. Each entry has `ts`, `type`, `player`, and best-effort `x`/`y`/`z` (coordinates are populated only when the join/leave poller resolved a pawn position — they may be missing for very fast disconnects). Events derive from the same poll-based detector that powers the in-game player list, so a transient query miss can produce a spurious leave/rejoin pair; consumers should treat sub-second flips as noise. Existing in-process `WindrosePlus.API.onPlayerJoin` / `onPlayerLeave` callbacks are unchanged — this is an additive file-based channel for tools that don't run inside Lua.

### Notes for the next release

Issue [#4](https://github.com/HumanGenome/WindrosePlus/issues/4) (per-level stat rewards skipped when XP gain crosses multiple levels) is a base-game level-up event firing once per XP packet. The fix needs an in-game catchup hook on `R5HeroLevelUpComponent` to walk the levels gained and award the missed `StatPointsReward` / `TalentPointsReward` values one at a time. Until that lands, `wp.givestats` is the manual compensation path.

## [1.0.3] - 2026-04-18

### Fixed

- **`loot` multiplier was duplicating equipment drops ([#3](https://github.com/HumanGenome/WindrosePlus/issues/3)).** The PAK builder scaled every entry in every loot table, including weapons, armor, jewelry, and other one-of-a-kind gear. With `loot = 4`, a chest that should drop 1 sword dropped 4. The patcher now skips entries whose `LootItem` path lives under `InventoryItems/Equipments/` so only stackable resources scale.
- **`stack_size` multiplier was making explicitly-unstackable items stackable ([#3](https://github.com/HumanGenome/WindrosePlus/issues/3)).** The previous check (`MaxCountInSlot > 0`) treated `1` as "stack of one, scale it." Items the game intends to be unique — gear, jewelry, ship cannons, lore notes — were turning into stackable inventory. The check is now `> 1`, so original stack=1 items stay unstackable.

### Added

- **New `cooking_speed` multiplier.** Divides `CookingProcessDuration` on every Recipe in the PAK, which speeds up alchemy elixirs, fermentation, smelting, and any other timed production. Value is a multiplier just like `crop_speed` (`2.0` = half the time). Range `0.1`–`100.0`. Defaults to `1.0`. Surfaces in `wp.config`, `wp.status`, `server_status.json`, and the dashboard.

### Changed

- PAK builder now reads back temp-dir JSON via explicit BOM-less UTF-8 instead of `Get-Content -Raw`. Prevents Windows PowerShell 5.1 from mis-decoding files that an earlier multiplier already wrote, which would have caused `cooking_speed` and `points_per_level` to corrupt prior `craft_cost` / `xp` edits in mixed-shell setups.
- PAK builder clamps every multiplier input to a minimum of `0.01` defensively so passing `0` or a negative value can't divide-by-zero or collapse durations to garbage. Lua already clamps; this hardens the standalone `WindrosePlus-BuildPak.ps1` entry path.
- Dropped a dead `"Character"` filter in the `inventory_size` patcher. It scanned 877 files and matched zero — confirmed against the live game PAK. Net effect: faster builds, no behavior change.

## [1.0.2] - 2026-04-18

### Fixed

- **"Encoding errors" on Windows PowerShell 5.1** (the shell still shipped by default on Windows and on Nitrado hosts). Several bundled scripts and installer output contained em-dash characters in UTF-8 files without a byte-order-mark. Without a BOM, Windows PowerShell falls back to the legacy ANSI codepage and mangles those bytes into parse or display errors — the symptom some users worked around by manually swapping `powershell` for `pwsh` in their launchers. All bundled `.ps1` files now ship with a UTF-8 BOM so both `powershell` (5.1) and `pwsh` (7+) parse them correctly.
- **JSON output from the PAK builder had a BOM on 5.1 but not on 7.** `Set-Content -Encoding UTF8` means "with BOM" on Windows PowerShell and "no BOM" on PowerShell 7 — a long-standing platform gotcha that made PAK contents subtly differ between shells. All JSON writes now emit BOM-less UTF-8 regardless of which shell runs them.

### Changed

- `StartWindrosePlusServer.bat` and `server/start_windrose_plus.bat` prefer PowerShell 7 (`pwsh`) when it's on PATH and fall back to Windows PowerShell 5.1 (`powershell`) otherwise. Both work correctly after the encoding fix above; the preference just picks the newer shell when available.

## [1.0.1] - 2026-04-17

### Fixed

- **Multipliers not applying to the game ([#2](https://github.com/HumanGenome/WindrosePlus/issues/2)).** Editing `windrose_plus.json` updated `wp.config` / `wp.status` but gameplay stayed at defaults because the override PAK the game loads at startup was never being rebuilt. Multiplier edits (and `.ini` edits) now need the rebuild step before launch — `StartWindrosePlusServer.bat` at the server root handles it automatically, or you can call `tools/WindrosePlus-BuildPak.ps1 -ServerDir "<gameDir>"` from your own launcher. Hash cache makes the no-change case a ~millisecond no-op.
- PAK builder now applies `inventory_size` and `points_per_level` multipliers in addition to the existing six. Both were parsed from config previously but never patched into the game files.

### Added

- `tools/bin/repak.exe` and `tools/bin/retoc.exe` are bundled in the release zip. No internet access or manual tool install required for the PAK rebuild step.
- Dashboard shows a "config changed — restart to apply" banner when it detects a stale PAK.
- `GET /api/pak-status` endpoint reports PAK freshness for tooling.
- Build-input hash cache (`R5\Content\Paks\.windroseplus_build.hash`) lets repeat launches of the wrapper exit in a fraction of a second when nothing has changed. Bumps to the bundled tools, the game pak, or the WindrosePlus version all invalidate it automatically.

### Changed

- Dashboard re-reads `windrose_plus.json` on every auth attempt instead of caching it at startup, so RCON password changes take effect without restarting the dashboard. Includes a short retry loop for transient read races.
- `[Multipliers]` in `windrose_plus.ini` now emits a warning and is ignored. Put multipliers in `windrose_plus.json` so the in-game `wp.config` stays honest about what's actually applied.
- `WindrosePlus-BuildPak.ps1` now fails loud with non-zero exit on any error and will not delete an existing override PAK unless invoked with the explicit `-RemoveStalePak` flag.

## [1.0.0] - 2026-04-15

Initial public release.

### What's included

- **8 multipliers** — loot, XP, stack size, craft cost, crop speed, weight, inventory size, points per level
- **2,400+ INI settings** — player stats, talents, weapons, food, gear, creatures, co-op scaling
- **30 admin commands** — server monitoring, player info, entity counts, diagnostics, config management
- **Web dashboard** — password-protected console with autocomplete and Sea Chart live map
- **Live map** — real-time player and mob positions, auto-generated terrain tiles
- **CPU optimization** — idle servers use fewer cores, full restore on player connect
- **Lua mod API** — custom commands, player events, tick callbacks, hot-reload
- **Automated installer** — auto-detects game folder, downloads UE4SS, preserves configs on update

[1.0.13]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.13
[1.0.12]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.12
[1.0.11]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.11
[1.0.10]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.10
[1.0.9]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.9
[1.0.8]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.8
[1.0.7]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.7
[1.0.4]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.4
[1.0.3]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.3
[1.0.2]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.2
[1.0.1]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.1
[1.0.0]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.0
