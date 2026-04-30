# Changelog

## [1.1.9] - 2026-04-29

### Added

- **SEA CHART click-to-teleport.** The dashboard now adds a TELEPORT action on each online player row. Arm a player, click the SEA CHART, and Windrose+ sends `wp.tp` with a heightmap-derived Z so the player lands above the selected terrain.
- **`wp.tp [player] <x> <y> [z]`.** Adds an admin teleport command using `K2_SetActorLocation(..., bTeleport=true)`. Dashboard calls always send Z to avoid ambiguous numeric player names; manual RCON callers can still omit Z to preserve the player's current height.
- **`/api/terrain_height?x=&y=`.** Adds a dashboard API endpoint that samples the exported heightmap files and returns ground Z for click-to-teleport.

### Fixed

- **On-ship player and pawn positions no longer render at world origin.** Query and LiveMap now prefer `K2_GetActorLocation()` before falling back to `ReplicatedMovement.Location`, fixing player, AI ship, crew, and mineral marker positions when actors are attached to moving parents.
- **Teleport-triggered map refresh stays on the safe writer path.** `wp.tp` now requests the next LiveMap write through a flag consumed by `LiveMap.writeIfDue()` instead of collecting UObjects directly from the RCON command handler.

## [1.1.8] - 2026-04-29

Targets [#33](https://github.com/HumanGenome/WindrosePlus/issues/33), the GPortal-class ship/AI rubber-banding that disappears when Windrose+ is disabled.

### Fixed
- **Removed the movement hot-path hook.** Windrose+ no longer registers `R5MovementComponent:ServerSaveMoveInput`, which UE4SS has to bridge into Lua on every player movement RPC before the callback body can return. Active/idle mode now comes from the periodic Query/LiveMap player poll, avoiding that per-movement game-thread tax entirely.
- **Moved normal Query/LiveMap file writes off the game-thread closure.** UObject reads still happen on the game thread, but the JSON payload is queued and flushed by the async driver on the next tick. This keeps `server_status.json` and `livemap_data.json` current without doing disk I/O on the simulation thread.

## [1.1.7] - 2026-04-29

Targets [#46](https://github.com/HumanGenome/WindrosePlus/issues/46) and the same dashboard-stale reports in [#47](https://github.com/HumanGenome/WindrosePlus/issues/47). Affected hosts boot Windrose+ v1.1.6 cleanly, keep the RCON loop alive, and keep writing `tick.beat`, but `server_status.json` and `livemap_data.json` never appear. @kohanis instrumented the dispatcher and confirmed the key failure mode: `pcall(ExecuteInGameThread, fn)` returns `ok=true`, but the queued closure body never runs. That leaves `mode` stuck on `boot` and the dashboard waiting for a server ledger forever.

### Fixed

- **Degraded snapshots for starved `ExecuteInGameThread` queues.** `dispatchTick` now requires two consecutive stale observations before declaring a writer starved. When that happens, Query and LiveMap no longer run their UObject-reading collectors on the async RCON thread. Instead, they write file-only degraded snapshots with `degraded=true`, `mode="degraded"` for status, `degraded_reason="execute_in_game_thread_starved"`, and `cache_age_sec` when a last-known good snapshot exists. If no good snapshot was ever written, the fallback writes an empty no-UObject snapshot so dashboards stop showing "Awaiting server ledger" indefinitely.
- **Stale queued closures are cancelled.** Each writer dispatch carries a generation token. Once a writer enters degraded mode, any old `ExecuteInGameThread` closure that eventually drains sees the generation mismatch and returns without writing over the degraded snapshot.
- **POIScan and third-party tick callbacks stay safe.** POIScan is suppressed in degraded mode instead of walking actors off-thread. `runModTicks` is excluded from the degraded fallback entirely, so third-party callbacks registered through `WindrosePlus.API.registerTickCallback` keep the original game-thread semantics. If the UE4SS queue is starved, those callbacks resume only if the queue starts draining again or the server is restarted.
- **Added `LiveMap.forceWrite()`.** The force-write helper from @brazerZa's #48 contribution is included for future dashboard/API refresh flows; the RCON-command callsite from that PR is intentionally not included because it would still collect UObjects from the async thread on affected hosts.

## [1.1.6] - 2026-04-28

Targeted at the server-stutter cohort tracked in [#33](https://github.com/HumanGenome/WindrosePlus/issues/33). Eight-plus self-hosted operators have reported game-thread stutter / rubber-banding when 2+ players are online; @James-Wilkinson narrowed the cause with a controlled experiment on GPortal — disabling the runtime mod after applying multipliers eliminated the lag while leaving the PAK patches in place, proving the writer dispatch path was the culprit. This release reduces the per-tick cost via interval relaxation and gives constrained hosts an explicit lever to disable individual writers.

A more invasive async-handoff refactor (move JSON encode + file I/O off the game thread to a `LoopAsync` flusher) was prototyped and dropped during pre-release review — Lua 5.1 does not give cross-OS-thread happens-before guarantees for table-field publication, and UE4SS does not expose a VM lock to bridge that. Revisiting in a future release with a native queue or mutex.

### Added

- **Per-writer enable flags + interval overrides.** `[query] enabled / interval_ms / idle_interval_ms`, `[livemap] enabled / player_interval_ms / entity_interval_ms`, and `[poiscan] enabled / refresh_seconds` are now honored in `windrose_plus.json`. Constrained hosts (low-tier shared, single-vCore slices, GPortal-style) can disable individual writers to drop the per-tick game-thread cost while keeping RCON, admin commands, multipliers, and the mods loader running. Defaults: query active 5s / idle 30s, livemap player 5s / entity 30s, poiscan refresh 4h. Existing configs that explicitly set old keys keep working — Lua defaults fill missing sections.

### Changed

- **LiveMap default intervals relaxed.** Player position writes 3s → 5s, entity (mob/node) collection 15s → 30s. Cuts the per-tick `FindAllOf("Pawn")` walk frequency in half on busy servers without a visible UI difference — the dashboard's live map polls at 5s anyway. Customers who explicitly set the old shorter intervals via panel config keep them.
- **LiveMap drives `WindrosePlus.updatePlayerCount` independently of Query.** Previously the player-count flag (which gates idle/active mode and the LiveMap zero-player short-circuit) was only updated inside `Query._collectAndWrite`. With Query disabled but LiveMap enabled, that flag would freeze and LiveMap would never see the zero-player drop. LiveMap now updates the count from the same `Query.getPlayers()` call it already makes, so each writer is independent of the others' enable state.

### Panel-side

- **WindrosePlus mod redeploy: force on version mismatch.** The deploy gate previously skipped extraction when the zip md5 matched the stored hash and key files existed. A stale `windrose_plus_version.txt` next to the game root could persist past a deploy if the prior extract had partially failed, leaving customers reporting "stuck on v0.2.0" or similar. The gate now also checks `windrose_plus_version.txt` against `$windrosePlusReleaseTag` and forces a full redeploy when they disagree. Fixes the recent ticket cluster: 759505, 759523, 759529, 759537, 759540, 759542.

## [1.1.5] - 2026-04-28

### Fixed

- **`DefaultExecuteInGameThreadMethod = ProcessEvent` (set in v1.1.4) prevented unrelated UE4SS mods from loading.** With `HookUObjectProcessEvent = 0` — required to keep UE4SS' `ProcessEvent` detour out of the Windrose Shipping binary — the ProcessEvent dispatch path is also unavailable, and any UE4SS mod that calls `ExecuteInGameThread` without its own fallback (observed: `BPModLoaderMod`, `ConsoleEnablerMod`) errors out at script load. WindrosePlus survived because of the runtime fallback added in the same release (`_hasExecuteInGameThread = false` flips to direct dispatch on first failure), but customers running stacked UE4SS mods lost them. Reverted `DefaultExecuteInGameThreadMethod` to `EngineTick`. WindrosePlus's pcall-wrapped dispatcher catches the `ExecuteInGameThread` unavailable case the same way it caught it under ProcessEvent, so the v1.1.4 crash fixes from #41 still apply. Caught by the v1.1.4 → v1.1.5 smoke test before the SurvivalServers-side pin was bumped.

## [1.1.4] - 2026-04-28

### Fixed

- **Server crashes within 1–5 minutes of player activity ([#41](https://github.com/HumanGenome/WindrosePlus/issues/41)).** Three contributing causes were identified, all surfacing as `UE4SS.dll!UnknownFunction` at the top of the callstack. (1) `dispatchTick` could be invoked with `fn = nil` after a `RestartMod` or Lua GC pass dropped a captured upvalue; the resulting `LUA_ERRRUN` from `pcall(nil)` escaped UE4SS' own callback dispatcher as a fatal exception. The dispatcher now early-returns when `fn` is not a function, and the tick callbacks for `Query`, `LiveMap`, and `POIScan` resolve their writers lazily through `WindrosePlus._modules` at call time instead of capturing the function reference at registration time. (2) The `R5MovementComponent:ServerSaveMoveInput` `RegisterHook` callback could fire before `WindrosePlus` was fully initialised (early map load) or after a partial RestartMod, dereferencing a nil table inside a UE4SS callback dispatcher. The handler now guards against a missing `WindrosePlus`, `state`, `isIdle`, or `setMode` before any work. (3) `HookEngineTick = 1` and `DefaultExecuteInGameThreadMethod = EngineTick` are unsafe on the Windrose Shipping binary — UE4SS cannot reliably install the `UEngine::Tick` detour and `ExecuteInGameThread` dispatch can fault in C++ where no Lua `pcall` can catch it. `UE4SS-settings.ini` now disables the EngineTick hook and switches dispatch to `ProcessEvent`. Thanks to @Daxolion for the diagnosis and patch set, and to @joshua88wa, @haws1290, and @krautech for the crash reports.

### Added

- **Crash precursor heartbeat in the activity log.** The 5-minute `heartbeat` event is now joined by a 30-second `tick.beat` event that records `uptime_sec`, `mode`, `player_count`, and `last_hook_age_sec` (seconds since the last `ServerSaveMoveInput` player-pawn fire). When the Lua VM dies, the gap between the last `tick.beat` and the next `mod.boot` localises time-of-death to within 30 seconds, and `last_hook_age_sec` distinguishes "crashed mid-tick under load" from "crashed while idle" from "crashed while a player was actively moving." Adds ~1.3 MB/day to the log.
- **`module.load.fail` event for module init failures.** When a Windrose+ module's `init()` raises during boot, the failure now surfaces in the activity log with the module name and error message, alongside the existing `Log.warn` console line. Reduces the need to cross-reference UE4SS.log for boot errors when the activity log is writable.
- **`alive` flag on `player.join` / `player.leave`.** The query module already collects the corpse-state flag for each connected player; piping it through to the join/leave events is a free signal for rubber-banding-at-sea ([#42](https://github.com/HumanGenome/WindrosePlus/issues/42)) and save-corruption forensics where the character should be alive but the server saw `CurrentHealth = 0` at connect time.
- **`install.ps1` now creates `windrose_plus_data\logs\` explicitly.** Lua cannot reliably create directories on locked-down hosts, so the events module had been falling back to writing the daily log into `windrose_plus_data\` next to the legacy `events.log` whenever the subdirectory was missing. Fresh installs (and reinstalls) now have the directory pre-created so the log lands in the documented location.

## [1.1.3] - 2026-04-28

### Changed

- **Character repair tool: dead-end message replaced with actionable guidance.** When the uploaded save has spent or allocated progression nodes, `Safe` mode (correctly) refuses to edit it automatically. Previously the customer-facing response just said "Safe mode will not edit it automatically" and stopped, which left users with no path forward. The message now points users to send the same zip to their server admin or hosting support so a deeper repair can be run manually.

## [1.1.2] - 2026-04-27

### Fixed

- **Idle-server async-thread crash from NPC movement keeping mode stuck on "active" ([#43](https://github.com/HumanGenome/WindrosePlus/issues/43)).** `R5MovementComponent:ServerSaveMoveInput` fires for every moving pawn including mobs and NPCs, not just players. Without an `IsPlayerControlled` check, idle-server NPC AI kept the mode flag pinned to "active" through the night, which invalidated the safety claim that idle-mode writers do zero UObject reads — when the `ExecuteInGameThread` queue starved past the 30 s threshold, the stale-guard fallback ran the writer directly on the async thread and raced UE GC, producing access violations inside `UE4SS.dll`. Three companion changes harden the same path: (1) the stale-guard fallback now drops the entry instead of executing the writer on the async thread, trading a delayed write for crash safety; (2) when `ExecuteInGameThread` itself throws at runtime, `_hasExecuteInGameThread` is now set to `false` so subsequent dispatches use the direct path immediately instead of re-throwing every tick; (3) the standalone-heartbeat `LoopAsync` call is nil-guarded for degraded UE4SS modes. Thanks to @Numa26210 for the diagnosis and patch set.

## [1.1.1] - 2026-04-27

### Added

- **Server Activity Log.** Windrose+ now writes a structured server-side activity record to `windrose_plus_data\logs\YYYY-MM-DD.log` (line-delimited JSON, append-only, daily roll). Captures `mod.boot`, `config.load` / `config.load.fail`, `player.join`, `player.leave`, `admin.command` (with caller, args, status, and duration), and a 5-minute `heartbeat` snapshotting active multipliers, mode, and player count. Each entry carries a per-boot `sid` (session id) so a single restart cycle can be isolated. Mods can append their own entries with `WindrosePlus.API.logEvent(name, payload)`.

### Removed

- **`windrose_plus_data\events.log`** is no longer written. Player join/leave records that previously landed there are now part of the Server Activity Log under `windrose_plus_data\logs\YYYY-MM-DD.log`. External tooling that tailed the old single-file path needs to point at the new dated files instead.

## [1.1.0] - 2026-04-26

### Changed

- **Renamed the `craft_cost` multiplier to `craft_efficiency` ([#40](https://github.com/HumanGenome/WindrosePlus/issues/40)).** The implementation has always interpreted higher values as cheaper recipes (`2.0` halves ingredient counts, `0.5` doubles them) — same convention as `xp`, `loot`, and `crop_speed` where higher means a better outcome for the player. Older docs described the same setting as cost scaling, which led readers to set `0.5` expecting half cost and instead getting double cost. The rename closes that gap. The legacy key `craft_cost` is still accepted with identical semantics, so existing configs keep working without edits.

  ```
  Old key (still works)     New key (recommended)        Effect
  craft_cost = 2.0          craft_efficiency = 2.0       Recipes cost half (more efficient)
  craft_cost = 0.5          craft_efficiency = 0.5       Recipes cost double (less efficient)
  ```

### Fixed

- **PAK builder no longer hard-fails when a CurveTable row pattern doesn't match a row in the live game pak ([#39](https://github.com/HumanGenome/WindrosePlus/issues/39)).** When Windrose ships a game update that renames a row name, every customer with an `.ini` override targeting that row had their server unable to start. The builder now emits a warning, drops the unmatched pattern, and continues with the rest of the table. If every override for a table is unmatched, the table is skipped entirely. Thanks to ismenc for the diagnostic output that pinpointed `HealthModifier` in `CT_Mob_StatCorrection_CoopBased` as the renamed row.

### Documentation

- Added `xp` to the cross-server portability warning in the README ([#16](https://github.com/HumanGenome/WindrosePlus/issues/16)). Characters levelled with non-default `xp` may fail to join other servers running stock multipliers, in the same client-authoritative bucket as `stack_size`. Keep `xp = 1` if you expect cross-server portability.

## [1.0.21] - 2026-04-26

### Fixed

- **Idle servers no longer crash with `STATUS_FATAL_USER_CALLBACK_EXCEPTION` after ~9 minutes ([#36](https://github.com/HumanGenome/WindrosePlus/issues/36)).** `dispatchTick` scheduled writers via `pcall(ExecuteInGameThread, function() ... end)`, which resolves the `ExecuteInGameThread` global *before* entering the protected boundary. When the global was transiently nil (UE4SS init/shutdown windows, or any path that left the dispatcher unresolved), `pcall` itself threw and the error escaped into UE4SS' callback dispatcher, which terminated the host process. The schedule call is now wrapped inside the `pcall`'s protected function, so a nil global becomes a trappable Lua error and the writer falls through to the existing direct-execution fallback. Thanks to @manuelVo for the diagnosis and patch.

## [1.0.20] - 2026-04-25

### Fixed

- **Sea-chart no longer turns blood-red when tiles are missing.** The Leaflet `errorTileUrl` literal in the dashboard decoded to `rgba(255, 0, 0, 127)` — a 50%-opacity red pixel — instead of the transparent placeholder the surrounding code assumed. Whenever a zoom level had no rendered tiles (e.g. only zoom 6 exists on disk and the viewport requests zoom 1), Leaflet stretched the 1×1 red pixel across every empty tile slot and the map area went solid crimson. Replaced with a verified transparent 1×1 PNG so missing tiles fall through to the `#seachart-map` background instead of painting the panel red.

## [1.0.19] - 2026-04-25

### Changed

- **Character repair is now an inline modal under the player list.** The standalone `/repair` page has been removed. The repair entry point is a small "Repair character save" link beneath the player list on the main dashboard; clicking it pops a modal styled to match the rest of the UI (Cinzel/Cormorant fonts, gold-on-dark palette, dashed upload area). The repair flow itself is unchanged — same `/api/character-repair` POST, same 200 MB cap, same safe-mode-only behavior, same downloaded `windrose-save-repaired.zip`.

## [1.0.18] - 2026-04-25

### Fixed

- **Status writer no longer stalls on idle dedicated servers.** With zero players online, the game thread ticks very slowly. The `dispatchTick` coalescer queued each writer (`Query.writeIfDue`, `LiveMap.writeIfDue`, `POIScan.writeIfDue`, mod ticks) onto the game thread via `ExecuteInGameThread`, then refused to queue another until the previous one drained. On idle servers the queue would sit undrained for minutes, all subsequent ticks would skip, and `server_status.json` (plus the dashboard's WP version line) would freeze at whatever the last successful drain wrote. The dispatcher now treats a 30-second-old pending entry as a starved queue, force-clears it, and runs the writer directly on the async thread — safe in idle mode because the writers do effectively zero UObject reads when no players are online.

## [1.0.17] - 2026-04-25

### Added

- **`wp.jump` and `wp.gravity` admin commands.** Per-player JumpZVelocity and GravityScale multipliers, same UX as `wp.speed` (range 0.1–20 / 0–10 respectively, supports player names with spaces). Thanks to @dnirchi for the contribution ([#27](https://github.com/HumanGenome/WindrosePlus/pull/27)).

### Fixed

- **Movement cheats now survive death/respawn.** `wp.speed`, `wp.jump`, and `wp.gravity` previously lost their effect when the pawn was destroyed and respawned with blueprint defaults. A self-terminating 2 s ticker re-applies any active multiplier on pawn-identity change (the only signal that's a real respawn rather than a transient sprint/crouch state shift). The ticker stops itself when no multipliers are active and consumes zero CPU when idle.
- **`harvest_yield` multiplier now applies to mineral nodes ([#29](https://github.com/HumanGenome/WindrosePlus/issues/29)).** Copper, iron, and other mineral foliage are loot-table-driven (`LootTables/Foliage/DA_LT_Mineral_*.json`), which the previous `ResourcesSpawners/`-only filter missed. Berries, wood, and other gatherable spawners were unaffected. The harvest pass now also walks mineral loot tables using the same Min/Max schema as the loot pass; if both `loot` and `harvest_yield` are non-default, the multipliers stack on minerals (e.g. `loot=2, harvest_yield=2` → 4× mineral yield).
- **`wp.version` and dashboard now report the correct version.** The Lua `WindrosePlus.VERSION` constant and the PowerShell `$Version` banner literal both shipped at `"1.0.14"` in v1.0.15 and v1.0.16, so live `wp.version` output and the dashboard's WP-version line both lied. Both literals are now stamped from the git tag at release time by a new release-pipeline step that hard-fails if either substitution misses, so a future refactor renaming the constant is caught at release time instead of shipping a mis-stamped zip. Thanks to @t04glovern for the contribution ([#30](https://github.com/HumanGenome/WindrosePlus/pull/30)).

## [1.0.16] - 2026-04-24

### Fixed

- **Removed disk I/O and UObject walks from the per-player movement hook.** `ServerSaveMoveInput` no longer drives `Query.forceWrite`, `LiveMap.writeIfDue`, or `POIScan.writeIfDue` directly. Those writers ran on the game thread once per second whenever any player was moving, performing `FindAllOf("PlayerController")` / `FindAllOf("Pawn")` / `FindAllOf("R5MineralNode")` walks plus 4 disk operations per write — visible as tick-time hitches on populated servers. The hook now only flips active-mode state; the existing 2 s `LoopAsync` loop drives writes.
- **Inverted Query idle cadence.** `Query._idleInterval` was 2 s while the active interval was 5 s, so empty servers wrote `server_status.json` and re-read `ServerDescription.json` 2.5x more often than populated ones. Idle interval is now 30 s; active stays at 5 s.
- **Dispatched UObject reads to the game thread.** `Query.writeIfDue`, `LiveMap.writeIfDue`, and `POIScan.writeIfDue` are now scheduled via UE4SS `ExecuteInGameThread` from the async loop, with per-writer coalescing so a backed-up game thread cannot queue duplicate work. Previously these ran directly on UE4SS' async thread and could race the game thread's iteration of `FindAllOf` results — most races silently returned nil under `pcall`, but races against in-flight GC could crash the server.
- **POIScan no longer retries a failed scan every tick.** Added an in-flight guard so the game-thread and async-thread paths cannot run the scan simultaneously, plus a 60 s backoff after any failed scan. Previously a single failed `json.encode` or `io.open` would re-run the full `FindAllOf("Actor")` walk on every subsequent tick (game thread 1 Hz + async loop 0.5 Hz) until a successful scan landed. Manual trigger files still bypass the refresh-interval gate but no longer bypass the backoff, so a stuck trigger cannot spam scans.
- **POIScan write integrity.** `_scanAndWrite` now checks return values from `f:close`, `os.rename`, and the trigger-file `os.remove`, so a silent write failure can't mark the scan as succeeded and a stuck trigger file is logged instead of looping.
- **Idle-transition force-write actually runs now.** `WindrosePlus.updatePlayerCount` referenced an undefined `Query` global (the local `Query` declaration appears later in the file), so the active→idle transition write was a silent no-op since the function was added. Now resolved through `WindrosePlus._modules.Query` at call time, so 0-player dashboards reflect the empty state within ~2 s of the last player leaving instead of waiting for the next idle write.

## [1.0.15] - 2026-04-24

### Removed

- **Idle CPU Limiter is gone.** The bundled `IdleCpuLimiter` C++ mod, the out-of-process `WindrosePlusLimiterAgent.ps1` release agent, and the `performance.idle_cpu_limiter_enabled` / `performance.idle_cpu_limit_percent` config keys have all been removed. The Windows Job Object CPU-rate cap could not be made safe against Windrose's boot/handshake burst: any cap low enough to meaningfully reduce idle CPU was also low enough to time out connecting players, and lifting the cap via in-process sentinel polling or a parallel TCP-watcher agent did not close the race reliably on loaded hosts. Idle Windrose servers will once again use normal CPU; plan capacity accordingly. `install.ps1` now actively removes any leftover `IdleCpuLimiter` UE4SS mod directory, `idle_cpu_limiter_*` sentinel files under `windrose_plus_data\`, and any `IdleCpuLimiter` entry in `mods.txt` from prior versions. Existing `windrose_plus.json` files that still contain a `performance` block are ignored safely.

## [1.0.14] - 2026-04-23

### Added

- **Out-of-process Idle CPU Limiter release agent (`tools/WindrosePlusLimiterAgent.ps1`).** Watches inbound TCP connections on the game port and toggles the DLL's disable sentinel so the cap is lifted before a connecting client times out. The agent runs at normal priority outside the capped job, eliminating the race where the DLL's in-process release checks are themselves throttled to the idle rate. Opt-in: launch manually alongside the server or wire into your own start script.

### Changed

- **Disabled `stack_size`, `weight`, and `inventory_size` multiplier PAK patching.** Production servers with any of these three multipliers crashed repeatedly with the same `R5BLBusinessRule.h:374` "Inventory.Module.Default" validator crash signature as the previously-disabled `points_per_level` path. Even the narrow `MaxCountInSlot > 1` guard for stack_size (issue #3) did not prevent the engine's inventory-module validator from rejecting the resulting state at runtime. The multipliers remain accepted in config for forward compatibility but are no-ops in the PAK builder until a validator-aware patch path exists AND a character-save sanitizer can safely undo saved inflated state. Safe multipliers that still function: `loot`, `xp`, `craft_cost`, `crop_speed`, `cooking_speed`, `harvest_yield`.

### Fixed

- **Added dashboard Character Repair for known progression drift ([#24](https://github.com/HumanGenome/WindrosePlus/issues/24)).** The authenticated dashboard now has a `/repair` page that accepts a zipped local `SaveProfiles` folder, runs a bundled fail-closed repair tool, and returns `windrose-save-repaired.zip`. Safe mode only fixes the known no-spend `RewardLevel < CurrentLevel` drift and refuses spent-point or unknown save shapes instead of hand-editing BSON.
- **Stopped presenting `wp.givestats` / `points_per_level` as working point grants ([#18](https://github.com/HumanGenome/WindrosePlus/issues/18)).** `wp.givestats` now says exactly what it does: records an audit note only. `points_per_level` is documented and kept as a disabled/no-op compatibility key because its PAK path can corrupt progression saves.
- **Prevented high-risk inventory multiplier builds from combining with conflicting PAK mods ([#25](https://github.com/HumanGenome/WindrosePlus/issues/25)).** When `inventory_size`, `stack_size`, or `weight` is non-default, the PAK builder now scans installed third-party PAKs before writing `WindrosePlus_Multipliers_P.pak`. If another PAK also contains inventory assets, the build stops with a restore-from-backup warning and removes any existing generated multiplier PAK so a stale high-risk override cannot load. Advanced admins can set `WINDROSEPLUS_ALLOW_PAK_CONFLICTS=1` after testing the exact PAK combination.
- **Made dashboard RCON timeouts diagnosable instead of generic ([#13](https://github.com/HumanGenome/WindrosePlus/issues/13)).** The Lua command worker now writes a heartbeat, recovers a stale `pending_commands.processing` batch after restart, and records command-worker errors. The dashboard writes command files atomically and reports whether the worker is missing, stale, failed to consume a command, or consumed it without returning a response.
- **Fixed Sea Chart tile generation on Linux/Docker installs ([#21](https://github.com/HumanGenome/WindrosePlus/issues/21)).** The map export path now includes the normal installed `windrose_plus\tools\generateTiles.ps1` location, the dashboard records `map_generation_status.json`, and tile rendering no longer depends on `System.Drawing`, which is not reliable under Linux PowerShell. PNG tiles are written by a bundled cross-platform renderer instead.
- **Fixed CurveTable extraction missing the global ScriptObjects container ([#22](https://github.com/HumanGenome/WindrosePlus/issues/22)).** The builder now invokes `retoc to-legacy` against the full `R5\Content\Paks` directory instead of only `pakchunk0-WindowsServer.utoc`, so retoc can see companion containers such as `global.utoc` when converting CurveTable assets.

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

- **`points_per_level` multiplier disabled — character-corruption crash ([#20](https://github.com/HumanGenome/WindrosePlus/issues/20), [#4](https://github.com/HumanGenome/WindrosePlus/issues/4)).** Patching `TalentPointsReward` / `StatPointsReward` / `PointsReward` / `SkillPoints` / `AttributePoints` in `DA_HeroLevels.json` caused the engine's `R5BLPlayer_ValidateData` rule to fail `RewardLevel < CurrentLevel`, crashing the server with `R5GameProblems.cpp:211` the moment the affected character tried to join. Isolated to a single-file PAK with `pts=3` alone on a virgin world — still crashes. `MultiplierPakBuilder.ps1` now skips the `points_per_level` patch path entirely; config still accepts the key for compatibility but applies no modifications.
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

Issue [#4](https://github.com/HumanGenome/WindrosePlus/issues/4) (per-level stat rewards skipped when XP gain crosses multiple levels) remains open. The required engine-level catchup hook on `R5HeroLevelUpComponent` is still risky to register inside Windrose's UE4SS host (other RegisterHook attempts have crashed the server in earlier dev passes), so the fix stays deferred. `wp.givestats` (added in 1.0.4) records compensation notes to `windrose_plus_data/stat_grants_queue.log` for audit only.

## [1.0.4] - 2026-04-18

### Added

- **`wp.givestats <player> <stat_count> [talent_count]` admin command.** Records stat/talent point compensation notes to a per-server queue file (`windrose_plus_data/stat_grants_queue.log`) so server owners can audit who needs compensation for [#4](https://github.com/HumanGenome/WindrosePlus/issues/4) — characters that level up multiple times in a single XP gain only fire one stat-point reward, even though they cleared several levels at once. This command is audit-only and does not change the character in-game. Range `1`–`100` per axis. Player names with spaces are supported.
- **Append-only `windrose_plus_data/events.log`.** Line-delimited JSON records every player join and leave so external server-management tools can `tail -F` the file without polling the HTTP API or scraping the dashboard. Each entry has `ts`, `type`, `player`, and best-effort `x`/`y`/`z` (coordinates are populated only when the join/leave poller resolved a pawn position — they may be missing for very fast disconnects). Events derive from the same poll-based detector that powers the in-game player list, so a transient query miss can produce a spurious leave/rejoin pair; consumers should treat sub-second flips as noise. Existing in-process `WindrosePlus.API.onPlayerJoin` / `onPlayerLeave` callbacks are unchanged — this is an additive file-based channel for tools that don't run inside Lua.

### Notes for the next release

Issue [#4](https://github.com/HumanGenome/WindrosePlus/issues/4) (per-level stat rewards skipped when XP gain crosses multiple levels) is a base-game level-up event firing once per XP packet. The fix needs an in-game catchup hook on `R5HeroLevelUpComponent` to walk the levels gained and award the missed `StatPointsReward` / `TalentPointsReward` values one at a time. Until that lands, `wp.givestats` is only an audit trail for manual follow-up.

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

- **7 active multipliers** — loot, XP, stack size, craft cost, crop speed, weight, inventory size
- **2,400+ INI settings** — player stats, talents, weapons, food, gear, creatures, co-op scaling
- **30 admin commands** — server monitoring, player info, entity counts, diagnostics, config management
- **Web dashboard** — password-protected console with autocomplete and Sea Chart live map
- **Live map** — real-time player and mob positions, auto-generated terrain tiles
- **CPU optimization** — idle servers use fewer cores, full restore on player connect
- **Lua mod API** — custom commands, player events, tick callbacks, hot-reload
- **Automated installer** — auto-detects game folder, downloads UE4SS, preserves configs on update

[1.0.14]: https://github.com/HumanGenome/WindrosePlus/releases/tag/v1.0.14
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
