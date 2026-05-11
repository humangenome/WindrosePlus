-- WindrosePlus Admin Module
-- Server administration commands
-- Called via RCON file IPC only (console commands crash this server)
-- See docs/removed-commands.md for commands that were removed and why

local json = require("modules.json")
local Log = require("modules.log")

local Admin = {}
Admin._commands = {}
Admin._config = nil
Admin._gameDir = nil  -- populated by init() for file-IO commands (wp.givestats queue)
Admin._playerJoinTimes = {}  -- track session join times for wp.playtime
Admin._DEFAULT_PROCESS_NAME = "WindroseServer-Win64-Shipping.exe"
Admin._bootTime = os.time()  -- track server start for uptime (no wmic needed)

function Admin.init(config, gameDir)
    Admin._config = config
    Admin._gameDir = gameDir
    Admin._registerCommands()
    -- NOTE: RegisterConsoleCommandHandler requires HookProcessConsoleExec=1
    -- which crashes Windrose dedicated servers. Commands are RCON-only.
    Log.info("Admin", Admin._countCommands() .. " commands registered (RCON only)")
    Admin.writeCommandsJson()
end

-- Execute a command. Returns status ("ok"/"error") and message.
function Admin.execute(command, args)
    local cmd = Admin._commands[command] or Admin._commands["wp." .. command]
    if not cmd then
        return "error", "Unknown command: " .. command .. ". Use wp.help for list."
    end
    local ok, result = pcall(cmd.handler, args)
    if ok then
        return "ok", result or "OK"
    else
        return "error", tostring(result)
    end
end

-- Get the configured process name, falling back to the default
function Admin._getProcessName()
    if Admin._config then
        local cfgName = nil
        pcall(function()
            if WindrosePlus and WindrosePlus._modules and WindrosePlus._modules.Config then
                cfgName = WindrosePlus._modules.Config.get("server", "process_name")
            end
        end)
        if cfgName and cfgName ~= "" then return cfgName end
    end
    return Admin._DEFAULT_PROCESS_NAME
end

function Admin._countCommands()
    local n = 0
    for _ in pairs(Admin._commands) do n = n + 1 end
    return n
end

-- Write the current command registry to windrose_plus_data\commands.json so
-- the dashboard /api/commands route can serve the live list (including
-- mod-registered commands) instead of a hardcoded snapshot that goes stale.
function Admin.writeCommandsJson()
    if not Admin._gameDir then return end
    local dataDir = Admin._gameDir .. "windrose_plus_data"
    local out = {}
    for name, cmd in pairs(Admin._commands) do
        if not cmd.hidden then
            out[#out + 1] = {
                name = name,
                usage = cmd.usage or name,
                description = cmd.description or "",
                category = cmd.category or "server"
            }
        end
    end
    table.sort(out, function(a, b)
        if a.category == b.category then return a.name < b.name end
        return a.category < b.category
    end)
    local payload = { generatedAt = os.time(), count = #out, commands = out }
    local ok, encoded = pcall(json.encode, payload)
    if not ok then
        Log.warn("Admin", "writeCommandsJson encode failed: " .. tostring(encoded))
        return
    end
    local tmp = dataDir .. "\\commands.json.tmp"
    local final = dataDir .. "\\commands.json"
    local f = io.open(tmp, "w")
    if not f then
        Log.warn("Admin", "writeCommandsJson open failed for " .. tmp)
        return
    end
    f:write(encoded)
    f:close()
    os.remove(final)
    os.rename(tmp, final)
end

function Admin._registerCommands()

    -- =========================================
    -- General
    -- =========================================

    Admin._commands["wp.help"] = {
        description = "List all commands or get help for a specific command",
        usage = "wp.help [command|all]",
        category = "server",
        handler = function(args)
            -- Per-command help: wp.help status
            if args[1] and args[1]:lower() ~= "all" then
                local cmdName = args[1]:lower()
                if not cmdName:match("^wp%.") then cmdName = "wp." .. cmdName end
                local cmd = Admin._commands[cmdName]
                if cmd then
                    local lines = {cmdName .. " - " .. cmd.description}
                    table.insert(lines, "Usage: " .. cmd.usage)
                    if cmd.examples then
                        table.insert(lines, "Examples:")
                        for _, ex in ipairs(cmd.examples) do
                            table.insert(lines, "  " .. ex)
                        end
                    end
                    return table.concat(lines, "\n")
                end
                return "Unknown command: " .. cmdName
            end

            local showAll = args[1] and args[1]:lower() == "all"
            local categories = {
                {"server", "Server"},
                {"players", "Players"},
                {"world", "World"},
                {"diagnostics", "Diagnostics"},
                {"admin", "Admin"},
                {"debug", "Debug"},
            }
            local lines = {"WindrosePlus Commands:"}
            for _, cat in ipairs(categories) do
                local catId, catLabel = cat[1], cat[2]
                local cmds = {}
                local sorted = {}
                for name in pairs(Admin._commands) do table.insert(sorted, name) end
                table.sort(sorted)
                for _, name in ipairs(sorted) do
                    local cmd = Admin._commands[name]
                    if (cmd.category or "server") == catId and (not cmd.hidden or showAll) then
                        table.insert(cmds, cmd)
                        cmds[#cmds].name = name
                    end
                end
                if #cmds > 0 then
                    table.insert(lines, "\n[" .. catLabel .. "]")
                    for _, cmd in ipairs(cmds) do
                        table.insert(lines, "  " .. cmd.usage .. " - " .. cmd.description)
                    end
                end
            end
            if not showAll then
                table.insert(lines, "\nwp.help <command> for details. wp.help all for debug commands.")
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.status"] = {
        description = "Show server status and multipliers",
        usage = "wp.status",
        category = "server",
        handler = function(args)
            local playerCount = 0
            local pcs = FindAllOf("PlayerController")
            if pcs then
                for _, pc in ipairs(pcs) do
                    if pc:IsValid() and Admin._isConnected(pc) then playerCount = playerCount + 1 end
                end
            end
            local lines = {
                "Players: " .. playerCount,
                "Loot: " .. Admin._config.getLootMultiplier() .. "x",
                "XP: " .. Admin._config.getXpMultiplier() .. "x",
                "Stack Size: " .. Admin._config.getStackSizeMultiplier() .. "x",
                "Craft Efficiency: " .. Admin._config.getCraftEfficiencyMultiplier() .. "x",
                "Crop Speed: " .. Admin._config.getCropSpeedMultiplier() .. "x",
                "Weight: " .. Admin._config.getWeightMultiplier() .. "x",
                "WindrosePlus v" .. (WindrosePlus and WindrosePlus.VERSION or "?")
            }
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.players"] = {
        description = "List online players with positions",
        usage = "wp.players",
        category = "players",
        handler = function(args)
            local players = Admin._getPlayers()
            if #players == 0 then return "No players online" end
            local lines = {"Online (" .. #players .. "):"}
            for i, p in ipairs(players) do
                local posStr = ""
                if p.x then
                    posStr = string.format(" @ %.0f, %.0f, %.0f", p.x, p.y, p.z)
                end
                -- Show actor ID as canonical (per #61 / 227aa3c convention).
                -- Display name (if known) is shown as a parenthetical so users
                -- can recognize who's who at a glance.
                local label = p.actorName or p.name or "?"
                if p.displayName and p.displayName ~= label then
                    label = label .. " (" .. p.displayName .. ")"
                end
                table.insert(lines, "  " .. i .. ". " .. label .. posStr)
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.reload"] = {
        description = "Reload config from disk",
        usage = "wp.reload",
        category = "server",
        handler = function(args)
            Admin._config.reload()
            return "Config reloaded"
        end
    }

    Admin._commands["wp.version"] = {
        description = "Show version",
        usage = "wp.version",
        category = "server",
        handler = function(args) return "WindrosePlus v" .. (WindrosePlus and WindrosePlus.VERSION or "?") end
    }

    Admin._commands["wp.perf"] = {
        description = "Show server performance metrics",
        usage = "wp.perf",
        category = "diagnostics",
        handler = function(args)
            local lines = {"Server Performance:"}

            -- Player count (filtered for active connections)
            pcall(function()
                local pcs = FindAllOf("PlayerController")
                if pcs then
                    local n = 0
                    for _, pc in ipairs(pcs) do
                        if pc:IsValid() and Admin._isConnected(pc) then n = n + 1 end
                    end
                    table.insert(lines, "  Players: " .. n)
                end
            end)

            -- Memory: not available without wmic (would flash CMD window)
            table.insert(lines, "  Memory: use wp.memory for cached data")

            -- Uptime from Lua boot timestamp (no wmic needed)
            pcall(function()
                local diff = os.time() - Admin._bootTime
                local hours = math.floor(diff / 3600)
                local mins = math.floor((diff % 3600) / 60)
                table.insert(lines, "  Uptime: " .. hours .. "h " .. mins .. "m")
            end)

            if #lines == 1 then table.insert(lines, "  No metrics available") end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- Admin Actions
    -- =========================================

    -- =================================================================
    -- Movement cheats: wp.speed, wp.jump, wp.gravity
    --
    -- All three modify a per-player UCharacterMovementComponent float
    -- (plus the engine-level CheatMovementSpeedModifer for wp.speed —
    -- see Issue HumanGenome/WindrosePlus#5).
    --
    -- On respawn UE destroys the current pawn and spawns a fresh one
    -- with blueprint defaults — our one-shot writes to the old pawn are
    -- lost. A lightweight self-terminating ticker (`ensureMovementTicker`)
    -- dirty-checks each active multiplier every ~2s and re-applies when
    -- the live value diverges (respawn, or anything else that resets it).
    -- When no multipliers are active the ticker stops on its next wake
    -- and consumes zero CPU until the next set.
    -- =================================================================

    -- Per-cheat writers. `prop` is the primary field used for dirty-check.
    -- `apply` handles the actual write (wp.speed writes two fields so it
    -- keeps its dual-write behavior — cheat modifier + replicated max).
    Admin._movementCheats = {
        speed = {
            label = "Speed", prop = "MaxWalkSpeed", minMult = 0, maxMult = 20,
            apply = function(mc, mult, base)
                mc.CheatMovementSpeedModifer = mult
                if base then mc.MaxWalkSpeed = base * mult end
            end,
        },
        jump = {
            label = "JumpZVelocity", prop = "JumpZVelocity", minMult = 0.1, maxMult = 20,
            apply = function(mc, mult, base)
                if base then mc.JumpZVelocity = base * mult end
            end,
        },
        gravity = {
            label = "GravityScale", prop = "GravityScale", minMult = 0, maxMult = 10,
            apply = function(mc, mult, base)
                if base then mc.GravityScale = base * mult end
            end,
        },
    }

    -- Per-player baseline cache: {propName: {playerName: origValue}}.
    -- Blueprint defaults don't change across respawn, so the cache stays valid.
    Admin._origMovementProp = Admin._origMovementProp or {}

    -- Active multipliers for respawn re-application: {playerNameLower: {cheatName: mult}}.
    -- Populated when mult != 1.0, cleared when mult == 1.0.
    Admin._activeMovementMults = Admin._activeMovementMults or {}

    -- Last-applied pawn identity per (player, cheat). Used by the ticker to detect
    -- respawn (pawn object differs) without re-writing when values merely fluctuate.
    -- Value-based dirty-check caused client rubber-banding because UE transiently
    -- adjusts MaxWalkSpeed during state transitions (sprint/crouch/etc) and any
    -- re-write triggers ClientAdjustPosition corrections.
    Admin._lastAppliedPawn = Admin._lastAppliedPawn or {}

    local function getPlayerName(pc)
        local pName = nil
        pcall(function()
            local ps = pc.PlayerState
            if ps and ps:IsValid() then
                local val = ps.PlayerNamePrivate
                if val then
                    local ok, str = pcall(function() return val:ToString() end)
                    if ok and str then pName = str end
                end
            end
        end)
        return pName
    end

    local function getControlledPawn(pc)
        local pawn = nil
        pcall(function() pawn = pc.Pawn end)
        if not (pawn and pawn:IsValid()) then return nil, nil, nil end

        local fullName = nil
        local shortName = nil
        pcall(function()
            fullName = pawn:GetFullName()
            shortName = fullName and (fullName:match("([^%.]+)$") or fullName) or nil
        end)
        return pawn, shortName, fullName
    end

    -- Local alias to the module-level helper so movement-command and
    -- info-command targeting paths share one matcher and can't drift apart.
    local playerTargetMatches = Admin._playerTargetMatches

    local function captureBaseline(cheat, mc, key)
        local store = Admin._origMovementProp[cheat.prop]
        if not store then
            store = {}
            Admin._origMovementProp[cheat.prop] = store
        end
        if not store[key] then
            local ok, orig = pcall(function() return mc[cheat.prop] end)
            if ok and orig and orig > 0 then store[key] = orig end
        end
        return store[key]
    end

    -- Self-terminating 2s ticker: re-applies diverged multipliers, stops
    -- once the active map is empty. Only writes when dirty-check fails.
    local function ensureMovementTicker()
        if Admin._movementTickActive then return end
        Admin._movementTickActive = true
        LoopAsync(2000, function()
            if not next(Admin._activeMovementMults) then
                Admin._movementTickActive = false
                return true  -- stop the loop
            end
            local pcs = FindAllOf("PlayerController")
            if not pcs then return false end
            for _, pc in ipairs(pcs) do
                if pc:IsValid() then
                    pcall(function()
                        local pName = getPlayerName(pc)
                        if not pName then return end
                        local mults = Admin._activeMovementMults[pName:lower()]
                        if not mults or not next(mults) then return end
                        local pawn = pc.Pawn
                        if not (pawn and pawn:IsValid()) then return end
                        local mc = pawn.CharacterMovement or pawn.MovementComponent
                        if not (mc and mc:IsValid()) then return end
                        -- Pawn-identity dirty check: respawn produces a genuinely
                        -- different pawn instance (different GetFullName). Same pawn =
                        -- same identity = no re-apply, no rubber-banding.
                        local pawnId = nil
                        pcall(function() pawnId = pawn:GetFullName() end)
                        if pawnId then
                            local pKey = pName:lower()
                            for cheatName, mult in pairs(mults) do
                                local cheat = Admin._movementCheats[cheatName]
                                if cheat then
                                    local stateKey = pKey .. ":" .. cheatName
                                    if Admin._lastAppliedPawn[stateKey] ~= pawnId then
                                        local base = captureBaseline(cheat, mc, pName)
                                        if base then
                                            cheat.apply(mc, mult, base)
                                            Admin._lastAppliedPawn[stateKey] = pawnId
                                        end
                                    end
                                end
                            end
                        end
                    end)
                end
            end
            return false  -- keep looping
        end)
    end

    -- Shared implementation for wp.speed / wp.jump / wp.gravity.
    local function setMovementCheat(args, cheatName)
        local cheat = Admin._movementCheats[cheatName]
        if not cheat then return "Unknown cheat: " .. tostring(cheatName) end
        local n = #args
        if n < 1 then
            return "Usage: wp." .. cheatName .. " <multiplier> or wp." .. cheatName .. " <player> <multiplier>"
        end
        -- RCON splits on whitespace and player names can contain spaces.
        -- Treat the last arg as the multiplier; everything before joins as the name.
        -- Issue: HumanGenome/WindrosePlus#5
        local mult = tonumber(args[n])
        if not mult then
            return "Multiplier must be a number between " .. cheat.minMult .. " and " .. cheat.maxMult
        end
        if mult < cheat.minMult or mult > cheat.maxMult then
            return "Multiplier must be between " .. cheat.minMult .. " and " .. cheat.maxMult
        end
        local targetName = nil
        if n >= 2 then targetName = table.concat(args, " ", 1, n - 1):lower() end

        local pcs = FindAllOf("PlayerController")
        if not pcs then return "No players found" end

        local count = 0
        for _, pc in ipairs(pcs) do
            if pc:IsValid() then
                local pName = getPlayerName(pc)
                local pawn, pawnName, pawnFullName = getControlledPawn(pc)
                if playerTargetMatches(targetName, pName, pawnName, pawnFullName) then
                    pcall(function()
                        if pawn and pawn:IsValid() then
                            local mc = pawn.CharacterMovement or pawn.MovementComponent
                            if mc and mc:IsValid() then
                                local key = pName or pawnName or tostring(pc)
                                local base = captureBaseline(cheat, mc, key)
                                cheat.apply(mc, mult, base)
                                count = count + 1
                                -- Register for respawn re-application (keyed by player
                                -- name so it survives pc-object turnover). mult == 1.0
                                -- means "reset" — drop from the active map instead.
                                if pName then
                                    local pKey = pName:lower()
                                    local stateKey = pKey .. ":" .. cheatName
                                    if mult == 1.0 then
                                        if Admin._activeMovementMults[pKey] then
                                            Admin._activeMovementMults[pKey][cheatName] = nil
                                            if not next(Admin._activeMovementMults[pKey]) then
                                                Admin._activeMovementMults[pKey] = nil
                                            end
                                        end
                                        Admin._lastAppliedPawn[stateKey] = nil
                                    else
                                        Admin._activeMovementMults[pKey] = Admin._activeMovementMults[pKey] or {}
                                        Admin._activeMovementMults[pKey][cheatName] = mult
                                        -- Record the pawn we just wrote to so the ticker
                                        -- won't re-apply until the pawn identity changes.
                                        pcall(function() Admin._lastAppliedPawn[stateKey] = pawn:GetFullName() end)
                                    end
                                end
                            end
                        end
                    end)
                end
            end
        end
        if next(Admin._activeMovementMults) then ensureMovementTicker() end
        if targetName then
            return count > 0 and (cheat.label .. " set to " .. mult .. "x for " .. targetName)
                                or ("Player '" .. targetName .. "' not found")
        end
        return cheat.label .. " set to " .. mult .. "x for " .. count .. " player(s)"
    end

    Admin._commands["wp.speed"] = {
        description = "Set player movement speed multiplier",
        usage = "wp.speed [player] <multiplier>",
        category = "admin",
        examples = {"wp.speed 2.0", "wp.speed HumanGenome 1.5", "wp.speed BP_R5Character_C_2147418445 1.5"},
        playerArg = true,
        handler = function(args) return setMovementCheat(args, "speed") end,
    }

    Admin._commands["wp.jump"] = {
        description = "Set player jump height multiplier (JumpZVelocity; 1.0=normal, 2.0=double)",
        usage = "wp.jump [player] <multiplier>",
        category = "admin",
        examples = {"wp.jump 2.0", "wp.jump HumanGenome 3", "wp.jump BP_R5Character_C_2147418445 3"},
        playerArg = true,
        handler = function(args) return setMovementCheat(args, "jump") end,
    }

    Admin._commands["wp.gravity"] = {
        description = "Set player gravity multiplier (CharacterMovement.GravityScale; 1.0=normal, 0.3=moon)",
        usage = "wp.gravity [player] <multiplier>",
        category = "admin",
        examples = {"wp.gravity 0.3", "wp.gravity HumanGenome 2", "wp.gravity BP_R5Character_C_2147418445 0.3"},
        playerArg = true,
        handler = function(args) return setMovementCheat(args, "gravity") end,
    }

    Admin._commands["wp.health"] = {
        description = "Read player health",
        usage = "wp.health [player]",
        category = "players",
        playerArg = true,
        handler = function(args)
            -- Join all args as the player name so multi-word names ("Some Player") match.
            local targetName = (#args > 0) and table.concat(args, " ") or nil
            local players = Admin._findPlayersByName(targetName)
            if #players == 0 then return targetName and ("Player '" .. targetName .. "' not found") or "No players online" end

            -- Health lives on PlayerState.R5AttributeSet (GAS), NOT on
            -- HealthComponent. HealthComponent.CurrentHealth was a non-existent
            -- FProperty that UE4SS resolved to a UObject wrapper, producing
            -- "UObject: 0x..." output. Read from the AttributeSet's Health /
            -- MaxHealth FGameplayAttributeData structs instead.
            --
            -- Use p.playerState captured during _getPlayers' targeting pass
            -- rather than re-scanning R5Character actors. The re-scan path can
            -- silently fail when the pawn's PlayerState is detached during
            -- transitional states like ship boarding — even though the player
            -- is otherwise targetable through the controller (per maintainer
            -- review of PR #68).
            local lines = {}
            for _, p in ipairs(players) do
                local ps = p.playerState
                local attrSet = nil
                if Admin._isValidUObject(ps) then
                    pcall(function() attrSet = ps.R5AttributeSet end)
                end
                if Admin._isValidUObject(attrSet) then
                    local hp = Admin._readGameplayAttribute(attrSet, "Health")
                    local maxHp = Admin._readGameplayAttribute(attrSet, "MaxHealth")
                    local hpStr = hp and tostring(math.floor(hp + 0.5)) or "?"
                    local maxStr = maxHp and tostring(math.floor(maxHp + 0.5)) or "?"
                    table.insert(lines, p.name .. ": " .. hpStr .. "/" .. maxStr .. " HP")
                else
                    table.insert(lines, p.name .. ": No AttributeSet")
                end
            end
            return #lines > 0 and table.concat(lines, "\n") or "No health data"
        end
    }

    Admin._commands["wp.pos"] = {
        description = "Get player positions",
        usage = "wp.pos [player]",
        category = "players",
        playerArg = true,
        handler = function(args)
            -- Join all args as the player name so multi-word names ("Some Player") match.
            local targetName = (#args > 0) and table.concat(args, " ") or nil
            local players = Admin._findPlayersByName(targetName)
            if #players == 0 then return targetName and ("Player '" .. targetName .. "' not found") or "No players online" end
            local lines = {}
            for _, p in ipairs(players) do
                if p.x then
                    table.insert(lines, string.format("%s: X=%.1f Y=%.1f Z=%.1f", p.name, p.x, p.y, p.z))
                else
                    table.insert(lines, p.name .. ": position unknown")
                end
            end
            return table.concat(lines, "\n")
        end
    }

    -- Teleport an online player to absolute world coordinates (UU/cm).
    -- Z is optional — if omitted, player's current Z is preserved (works well for
    -- short hops; for cross-map jumps the SEA CHART click-to-teleport in the
    -- dashboard supplies a heightmap-derived Z so the player lands above terrain).
    Admin._commands["wp.tp"] = {
        description = "Teleport player to absolute world coordinates (X, Y, optional Z)",
        usage = "wp.tp [player] <x> <y> [z]",
        category = "admin",
        examples = {"wp.tp 100000 200000", "wp.tp HumanGenome 100000 200000 5000"},
        playerArg = true,
        handler = function(args)
            local n = #args
            if n < 2 then return "Usage: wp.tp [player] <x> <y> [z]" end

            -- Trailing 2 or 3 args are numeric coords; everything before is the (possibly
            -- multi-word) player name. Same disambiguation pattern as wp.speed.
            local last1 = tonumber(args[n])
            local last2 = n >= 2 and tonumber(args[n-1]) or nil
            local last3 = n >= 3 and tonumber(args[n-2]) or nil
            local x, y, z, nameEnd
            if last3 and last2 and last1 then
                x, y, z = last3, last2, last1
                nameEnd = n - 3
            elseif last2 and last1 then
                x, y = last2, last1
                nameEnd = n - 2
            else
                return "Need 2 or 3 trailing numeric coords (x y [z])"
            end
            local targetName = nameEnd > 0 and table.concat(args, " ", 1, nameEnd):lower() or nil

            local pcs = FindAllOf("PlayerController")
            if not pcs then return "No players found" end

            local results = {}
            local matched = 0
            local anyTeleported = false
            for _, pc in ipairs(pcs) do
                if pc:IsValid() then
                    local pName = getPlayerName(pc)
                    local pawn, pawnName, pawnFullName = getControlledPawn(pc)
                    if playerTargetMatches(targetName, pName, pawnName, pawnFullName) then
                        matched = matched + 1
                        pcall(function()
                            if not (pawn and pawn:IsValid()) then
                                table.insert(results, (pName or pawnName or "?") .. ": no pawn")
                                return
                            end

                            -- Use current Z if not given
                            local targetZ = z
                            if not targetZ then
                                local locOk, loc = pcall(function() return pawn:K2_GetActorLocation() end)
                                if locOk and loc and loc.Z then targetZ = loc.Z else targetZ = 0 end
                            end

                            local newLoc = { X = x, Y = y, Z = targetZ }
                            -- K2_SetActorLocation(NewLocation, bSweep, OutSweepHitResult, bTeleport)
                            -- bSweep=false: don't collide-test against world while moving
                            -- bTeleport=true: discontinuous move, signals to physics/replication
                            --   that this is intentional (vs. a desync, which would rubber-band)
                            local callOk, ret = pcall(function()
                                return pawn:K2_SetActorLocation(newLoc, false, {}, true)
                            end)
                            if not callOk then
                                table.insert(results, string.format("%s: ERR %s", pName or pawnName or "?", tostring(ret)))
                                return
                            end
                            anyTeleported = true
                            table.insert(results, string.format("%s: tp -> (%.0f, %.0f, %.0f) ret=%s",
                                pName or pawnName or "?", x, y, targetZ, tostring(ret)))
                        end)
                    end
                end
            end

            -- Request the next LiveMap tick force a write so the new player position
            -- reaches the dashboard immediately rather than waiting up to one
            -- _playerInterval. We only set a flag here — the actual UObject collection
            -- runs in writeIfDue on the game-thread-dispatched path, never from this
            -- RCON command-processing thread (preserves the dispatchTick / degraded-mode
            -- protection introduced for #33/#46).
            if anyTeleported then
                local LiveMap = WindrosePlus._modules and WindrosePlus._modules.LiveMap
                if LiveMap and LiveMap.requestForceWrite then
                    pcall(LiveMap.requestForceWrite)
                end
            end

            if matched == 0 then return "No matching player" end
            return table.concat(results, "\n")
        end,
    }

    -- =========================================
    -- Real-time Game Settings (modify UE4 objects live)
    -- =========================================

    Admin._commands["wp.time"] = {
        description = "Read current time of day values",
        usage = "wp.time",
        category = "world",
        handler = function(args)
            local types = {"R5GameMode", "R5GameState", "GameState", "WorldSettings"}
            local timeProps = {"TimeOfDay", "CurrentTimeOfDay", "DayCycleDuration",
                               "NightCycleDuration", "DayNightCycleSpeed", "DayLength", "NightLength"}
            local lines = {}
            for _, t in ipairs(types) do
                local objs = FindAllOf(t)
                if objs then
                    for _, obj in ipairs(objs) do
                        if obj:IsValid() then
                            for _, p in ipairs(timeProps) do
                                pcall(function()
                                    local v = obj[p]
                                    if v ~= nil then table.insert(lines, t .. "." .. p .. " = " .. tostring(v)) end
                                end)
                            end
                        end
                    end
                end
            end
            return #lines > 0 and table.concat(lines, "\n") or "No time properties found"
        end
    }

    Admin._commands["wp.stamina"] = {
        description = "Read stamina/hunger/thirst for players",
        usage = "wp.stamina [player]",
        category = "players",
        playerArg = true,
        handler = function(args)
            -- Aligned with sibling info commands (wp.health, wp.pos, wp.playerinfo,
            -- wp.playtime, wp.tp): use the shared _findPlayersByName helper for
            -- multi-word + display-name + actor-ID matching. The previous
            -- implementation only matched lowercase actor IDs exactly, so typing
            -- a player's display name never resolved.
            local targetName = (#args > 0) and table.concat(args, " ") or nil
            local players = Admin._findPlayersByName(targetName)
            if #players == 0 then return targetName and ("Player '" .. targetName .. "' not found") or "No players online" end

            local function fmt(v) return v and tostring(math.floor(v + 0.5)) or "?" end

            -- GAS attribute names tried in order. _readGameplayAttribute returns
            -- nil for unknown fields (and guards UObject wrappers per the Round
            -- 2 review fix), so probing candidate names is safe and forward-
            -- compatible with engine renames. First non-nil result wins.
            local function tryAttrs(attrSet, candidates)
                for _, name in ipairs(candidates) do
                    local v = Admin._readGameplayAttribute(attrSet, name)
                    if v ~= nil then return v end
                end
                return nil
            end

            local lines = {}
            for _, p in ipairs(players) do
                local ps = p.playerState
                local attrSet = nil
                if Admin._isValidUObject(ps) then
                    pcall(function() attrSet = ps.R5AttributeSet end)
                end

                local playerLines = {}
                if Admin._isValidUObject(attrSet) then
                    -- Stamina names confirmed via wp.playerinfo's working read path.
                    local stam = Admin._readGameplayAttribute(attrSet, "Stamina")
                    local maxStam = Admin._readGameplayAttribute(attrSet, "MaxStamina")
                    if stam or maxStam then
                        table.insert(playerLines, "  Stamina: " .. fmt(stam) .. "/" .. fmt(maxStam))
                    end
                    -- Hunger/Thirst names not yet confirmed against R5AttributeSet —
                    -- probe common UE GAS naming conventions. Whichever name the
                    -- engine actually exposes will surface; the rest return nil.
                    local hunger = tryAttrs(attrSet, {"Hunger", "Saturation", "Food", "FoodLevel"})
                    local maxHunger = tryAttrs(attrSet, {"MaxHunger", "MaxSaturation", "MaxFood", "MaxFoodLevel"})
                    if hunger or maxHunger then
                        table.insert(playerLines, "  Hunger:  " .. fmt(hunger) .. "/" .. fmt(maxHunger))
                    end
                    local thirst = tryAttrs(attrSet, {"Thirst", "Hydration", "Water", "WaterLevel"})
                    local maxThirst = tryAttrs(attrSet, {"MaxThirst", "MaxHydration", "MaxWater", "MaxWaterLevel"})
                    if thirst or maxThirst then
                        table.insert(playerLines, "  Thirst:  " .. fmt(thirst) .. "/" .. fmt(maxThirst))
                    end
                end

                -- Legacy fallback: pre-GAS builds may still expose vitals as
                -- ActorComponents on the pawn. Surfaces nothing on current
                -- GAS-based builds (where the AttributeSet path above hits).
                if #playerLines == 0 and Admin._isValidUObject(p.pawn) then
                    for _, comp in ipairs({"StaminaComponent", "HungerComponent", "ThirstComponent"}) do
                        pcall(function()
                            local c = p.pawn[comp]
                            if c and Admin._isValidUObject(c) then
                                local props = {"CurrentStamina", "MaxStamina",
                                               "CurrentHunger", "MaxHunger",
                                               "CurrentThirst", "MaxThirst"}
                                for _, prop in ipairs(props) do
                                    pcall(function()
                                        local v = c[prop]
                                        if v ~= nil then
                                            table.insert(playerLines, "  " .. comp .. "." .. prop .. " = " .. tostring(v))
                                        end
                                    end)
                                end
                            end
                        end)
                    end
                end

                if #playerLines > 0 then
                    table.insert(lines, p.name .. ":")
                    for _, l in ipairs(playerLines) do table.insert(lines, l) end
                else
                    table.insert(lines, p.name .. ": No vitals data")
                end
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.discover"] = {
        hidden = true, category = "debug",
        description = "Discover all properties on a UE4 type by brute-force probing",
        usage = "wp.discover <TypeName>",
        handler = function(args)
            if #args < 1 then return "Usage: wp.discover R5GameMode" end
            local typeName = args[1]
            local obj = Admin._findFirstValid(typeName)
            if not obj then return typeName .. ": not found" end

            local found = Admin._probeObject(obj)
            local lines = {typeName .. " discovered properties:"}
            for _, entry in ipairs(found) do
                table.insert(lines, "  " .. entry.name .. " = " .. entry.value)
            end
            if #lines == 1 then table.insert(lines, "  (none found — use wp.inspect for raw view)") end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.gm"] = {
        hidden = true, category = "debug",
        description = "Read any R5GameMode property",
        usage = "wp.gm <property>",
        handler = function(args)
            if #args < 1 then return "Usage: wp.gm <property>\nExample: wp.gm XPMultiplier\nUse wp.settings to see all properties" end
            local prop = args[1]
            local obj = Admin._findFirstValid("R5GameMode")
            if not obj then return "R5GameMode not found" end

            local ok, val = pcall(function() return obj[prop] end)
            if not ok then return prop .. ": not found" end
            if val == nil then return prop .. ": nil" end
            local display = tostring(val)
            pcall(function() local s = val:ToString(); if s and s ~= "" then display = s end end)
            return prop .. " = " .. display
        end
    }

    Admin._commands["wp.settings"] = {
        hidden = true, category = "debug",
        description = "List all R5GameMode settings with current values",
        usage = "wp.settings [filter]",
        handler = function(args)
            local filter = args[1] and args[1]:lower() or nil
            local obj = Admin._findFirstValid("R5GameMode")
            if not obj then return "R5GameMode not found" end

            local found = Admin._probeObject(obj, filter)
            local lines = {"R5GameMode Settings:"}
            for _, entry in ipairs(found) do
                table.insert(lines, "  " .. entry.name .. " = " .. entry.value)
            end
            if #lines == 1 then
                table.insert(lines, "  (No readable values — use wp.gm <property> to read individual values)")
            end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- Debug
    -- =========================================

    Admin._commands["wp.inspect"] = {
        hidden = true, category = "debug",
        description = "Inspect a UObject type (count + first instance details)",
        usage = "wp.inspect <TypeName>",
        handler = function(args)
            if #args < 1 then return "Usage: wp.inspect R5Character" end
            local typeName = args[1]
            local results = FindAllOf(typeName)
            if not results then return typeName .. ": not found" end
            local count = 0
            local details = {}
            for _, obj in ipairs(results) do
                if obj:IsValid() then
                    count = count + 1
                    if count <= 3 then
                        table.insert(details, obj:GetFullName())
                    end
                end
            end
            local lines = {typeName .. ": " .. count .. " instance(s)"}
            for _, d in ipairs(details) do table.insert(lines, "  " .. d) end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.props"] = {
        hidden = true, category = "debug",
        description = "List all properties on first instance of a UObject type",
        usage = "wp.props <TypeName> [filter]",
        handler = function(args)
            if #args < 1 then return "Usage: wp.props R5GameMode [filter]" end
            local typeName = args[1]
            local filter = args[2] and args[2]:lower() or nil
            local obj = Admin._findFirstValid(typeName)
            if not obj then return typeName .. ": not found" end

            local found = Admin._probeObject(obj, filter)
            local lines = {typeName .. " properties:"}
            for _, entry in ipairs(found) do
                table.insert(lines, "  " .. entry.name .. " = " .. entry.value)
            end
            if #lines == 1 then table.insert(lines, "  (no known properties found — try wp.inspect for raw view)") end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.probe_player"] = {
        hidden = true, category = "debug",
        description = "Probe all name-related properties on connected players",
        usage = "wp.probe_player",
        handler = function(args)
            local lines = {}
            -- Probe R5PlayerState
            local states = FindAllOf("R5PlayerState")
            if states then
                for i, ps in ipairs(states) do
                    if ps:IsValid() then
                        table.insert(lines, "--- R5PlayerState #" .. i .. " ---")
                        table.insert(lines, "FullName: " .. ps:GetFullName())
                        local props = {
                            "NickName", "PlayerName", "PlayerNamePrivate", "SavedNetworkAddress",
                            "UniqueId", "PlayerId", "PlayerIndex", "CompressedPing",
                            "DisplayName", "UserName", "AccountName", "CharacterName",
                            "SteamName", "PlatformName", "OnlineName", "Name",
                            "ServerNickName", "R5NickName", "R5PlayerName",
                            "PlayerNickName", "AccountId", "PlatformId", "SteamId",
                            "EpicAccountId", "PlatformAccountId", "UniqueNetId"
                        }
                        for _, prop in ipairs(props) do
                            local ok, val = pcall(function() return ps[prop] end)
                            if ok and val ~= nil then
                                -- Try :ToString() for FString/FText/FName types
                                local strOk, strVal = pcall(function() return val:ToString() end)
                                if strOk and strVal and strVal ~= "" then
                                    table.insert(lines, "  " .. prop .. " = [str] " .. strVal)
                                else
                                    table.insert(lines, "  " .. prop .. " = " .. tostring(val))
                                end
                            end
                        end
                    end
                end
            else
                table.insert(lines, "No R5PlayerState found")
            end

            -- Probe PlayerController
            local pcs = FindAllOf("PlayerController")
            if pcs then
                for i, pc in ipairs(pcs) do
                    if pc:IsValid() then
                        table.insert(lines, "--- PlayerController #" .. i .. " ---")
                        table.insert(lines, "FullName: " .. pc:GetFullName())
                        local props = {"PlayerState", "Player", "NetPlayerIndex"}
                        for _, prop in ipairs(props) do
                            local ok, val = pcall(function() return pc[prop] end)
                            if ok and val ~= nil then
                                table.insert(lines, "  " .. prop .. " = " .. tostring(val))
                            end
                        end
                    end
                end
            else
                table.insert(lines, "No PlayerController found")
            end

            -- Probe R5Character
            local chars = FindAllOf("R5Character")
            if chars then
                for i, char in ipairs(chars) do
                    if char:IsValid() then
                        table.insert(lines, "--- R5Character #" .. i .. " ---")
                        table.insert(lines, "FullName: " .. char:GetFullName())
                        local props = {"PlayerState", "Controller"}
                        for _, prop in ipairs(props) do
                            local ok, val = pcall(function() return char[prop] end)
                            if ok and val ~= nil then
                                table.insert(lines, "  " .. prop .. " = " .. tostring(val))
                            end
                        end
                    end
                end
            else
                table.insert(lines, "No R5Character found")
            end

            if #lines == 0 then return "No players connected" end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.fields"] = {
        hidden = true, category = "debug",
        description = "List real FProperty fields on a UE4 type via class reflection (walks superclass chain)",
        usage = "wp.fields <TypeName> [filter]",
        handler = function(args)
            if #args < 1 then return "Usage: wp.fields R5PlayerState [filter]" end
            local typeName = args[1]
            local filter = args[2] and args[2]:lower() or nil
            local obj = Admin._findFirstValid(typeName)
            if not obj then return typeName .. ": no live instance found (try wp.inspect first)" end

            local class
            local ok = pcall(function() class = obj:GetClass() end)
            if not ok or not class or not class:IsValid() then
                return "Failed to get class for " .. typeName
            end

            local lines = {typeName .. " fields (real FProperties via reflection):"}
            local apiTried = {}
            local seen = 0
            local cur = class

            while cur and cur:IsValid() do
                local cname = "?"
                pcall(function() cname = cur:GetFullName() end)

                local usedForEach = false
                pcall(function()
                    if type(cur.ForEachProperty) == "function" then
                        apiTried["ForEachProperty"] = true
                        cur:ForEachProperty(function(prop)
                            local pname, ptype = "?", "?"
                            pcall(function() pname = prop:GetFName():ToString() end)
                            pcall(function() ptype = prop:GetClass():GetFName():ToString() end)
                            if Admin._matchFilter(pname, ptype, filter) then
                                table.insert(lines, "  " .. pname .. " : " .. ptype .. "  [" .. cname .. "]")
                                seen = seen + 1
                            end
                        end)
                        usedForEach = true
                    end
                end)

                if not usedForEach then
                    pcall(function()
                        local child = cur.Children
                        apiTried["Children-walk"] = true
                        local guard = 0
                        while child and child:IsValid() and guard < 4096 do
                            local fname, ftype = "?", "?"
                            pcall(function() fname = child:GetFName():ToString() end)
                            pcall(function() ftype = child:GetClass():GetFName():ToString() end)
                            if Admin._matchFilter(fname, ftype, filter) then
                                table.insert(lines, "  " .. fname .. " : " .. ftype .. "  [" .. cname .. "]")
                                seen = seen + 1
                            end
                            local nxt
                            pcall(function() nxt = child.Next end)
                            child = nxt
                            guard = guard + 1
                        end
                    end)
                end

                local parent
                pcall(function() parent = cur:GetSuperStruct() end)
                if not parent or not parent:IsValid() then break end
                cur = parent
            end

            if seen == 0 then
                local apis = {}
                for k in pairs(apiTried) do table.insert(apis, k) end
                table.insert(lines, "  (no fields enumerable; tried: " .. (next(apis) and table.concat(apis, ", ") or "nothing") .. ")")
            else
                table.insert(lines, "(" .. seen .. " field(s) enumerated)")
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.methods"] = {
        hidden = true, category = "debug",
        description = "List UFunctions on a UE4 type via class reflection (walks superclass chain)",
        usage = "wp.methods <TypeName> [filter]",
        handler = function(args)
            if #args < 1 then return "Usage: wp.methods R5PlayerController [filter]" end
            local typeName = args[1]
            local filter = args[2] and args[2]:lower() or nil
            local obj = Admin._findFirstValid(typeName)
            if not obj then return typeName .. ": no live instance found (try wp.inspect first)" end

            local class
            local ok = pcall(function() class = obj:GetClass() end)
            if not ok or not class or not class:IsValid() then
                return "Failed to get class for " .. typeName
            end

            local lines = {typeName .. " methods (UFunctions via reflection):"}
            local apiTried = {}
            local seen = 0
            local cur = class

            while cur and cur:IsValid() do
                local cname = "?"
                pcall(function() cname = cur:GetFullName() end)

                local usedForEach = false
                pcall(function()
                    if type(cur.ForEachFunction) == "function" then
                        apiTried["ForEachFunction"] = true
                        cur:ForEachFunction(function(fn)
                            local fname = "?"
                            pcall(function() fname = fn:GetFName():ToString() end)
                            local nparms = nil
                            pcall(function() nparms = fn.NumParms end)
                            if Admin._matchFilter(fname, nil, filter) then
                                local suffix = nparms and ("  (NumParms=" .. tostring(nparms) .. ")") or ""
                                table.insert(lines, "  " .. fname .. suffix .. "  [" .. cname .. "]")
                                seen = seen + 1
                            end
                        end)
                        usedForEach = true
                    end
                end)

                if not usedForEach then
                    -- Children-walk fallback: filter to UFunction-classed children
                    pcall(function()
                        local child = cur.Children
                        apiTried["Children-walk"] = true
                        local guard = 0
                        while child and child:IsValid() and guard < 4096 do
                            local ftype = "?"
                            pcall(function() ftype = child:GetClass():GetFName():ToString() end)
                            if ftype == "Function" or ftype:find("Function") then
                                local fname = "?"
                                pcall(function() fname = child:GetFName():ToString() end)
                                if Admin._matchFilter(fname, nil, filter) then
                                    table.insert(lines, "  " .. fname .. "  [" .. cname .. "]")
                                    seen = seen + 1
                                end
                            end
                            local nxt
                            pcall(function() nxt = child.Next end)
                            child = nxt
                            guard = guard + 1
                        end
                    end)
                end

                local parent
                pcall(function() parent = cur:GetSuperStruct() end)
                if not parent or not parent:IsValid() then break end
                cur = parent
            end

            if seen == 0 then
                local apis = {}
                for k in pairs(apiTried) do table.insert(apis, k) end
                table.insert(lines, "  (no methods found; tried: " .. (next(apis) and table.concat(apis, ", ") or "nothing") .. ")")
                table.insert(lines, "  Note: Windrose docs say zero Lua-callable UFunctions on R5BL — this output may be empty by design.")
            else
                table.insert(lines, "(" .. seen .. " method(s) enumerated)")
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.modreload"] = {
        hidden = true, category = "debug",
        description = "Force WP+ Lua state restart (UE4SS RestartMod). Use to pick up Scripts/ changes without bouncing the server.",
        usage = "wp.modreload",
        handler = function(args)
            if not RestartMod then return "RestartMod not available in this UE4SS build" end
            local ok, err = pcall(function() RestartMod("WindrosePlus") end)
            if not ok then return "RestartMod failed: " .. tostring(err) end
            return "WP+ mod restart triggered (Lua state will be torn down + rebuilt)"
        end
    }

    Admin._commands["wp.peek"] = {
        hidden = true, category = "debug",
        description = "Read a property on the first valid instance of a type, with multi-way deref",
        usage = "wp.peek <TypeName> <PropertyName>",
        handler = function(args)
            if #args < 2 then return "Usage: wp.peek R5PlayerState UniqueId" end
            local typeName, propName = args[1], args[2]
            local obj = Admin._findFirstValid(typeName)
            if not obj then return typeName .. ": no live instance found" end

            local val
            local ok = pcall(function() val = obj[propName] end)
            if not ok then return propName .. ": access error" end
            if val == nil then return propName .. ": nil" end

            local lines = {typeName .. "." .. propName .. ":"}
            table.insert(lines, "  raw       = " .. tostring(val))
            pcall(function()
                local s = val:ToString()
                if s ~= nil then table.insert(lines, "  ToString  = " .. tostring(s)) end
            end)
            pcall(function()
                if type(val) == "userdata" and val.GetClass then
                    local c = val:GetClass()
                    if c and c:IsValid() then
                        table.insert(lines, "  Class     = " .. c:GetFullName())
                    end
                end
            end)
            pcall(function()
                if type(val) == "userdata" and val.GetFullName then
                    table.insert(lines, "  FullName  = " .. val:GetFullName())
                end
            end)
            -- For FUniqueNetIdRepl, the inner NetId might have a ToDebugString
            for _, m in ipairs({"ToDebugString", "ToString", "ToHexString"}) do
                pcall(function()
                    if type(val[m]) == "function" then
                        local s = val[m](val)
                        if s and tostring(s) ~= "" then
                            table.insert(lines, "  ." .. m .. " = " .. tostring(s))
                        end
                    end
                end)
            end
            -- Try common subfields used by UE4 NetId structs
            for _, sub in ipairs({"UniqueNetId", "Name", "Type", "Id", "Value"}) do
                pcall(function()
                    local sv = val[sub]
                    if sv ~= nil then
                        local sstr = tostring(sv)
                        pcall(function()
                            local s = sv:ToString()
                            if s and s ~= "" then sstr = "[str] " .. s end
                        end)
                        table.insert(lines, "  ." .. sub .. " = " .. sstr)
                    end
                end)
            end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- New Commands: Server Info
    -- =========================================

    -- Keys whose PAK patch path is currently disabled in the open-source builder
    -- (save-safety / engine-validator hazards). Mirrored from the wp.doctor
    -- block below. Suffix `(disabled)` on the wp.config / wp.multipliers echo
    -- when the customer has set a non-1 value, so the in-game output does not
    -- mislead operators into thinking a value is being applied when it is not.
    local _disabledMultiplierEcho = {
        stack_size = true, weight = true, inventory_size = true,
        points_per_level = true, crop_speed = true,
    }
    local function _fmtMultiplierLine(label, value, disabledKey)
        local s = "  " .. label .. ": " .. tostring(value) .. "x"
        if disabledKey and _disabledMultiplierEcho[disabledKey] and value ~= 1 then
            s = s .. " (disabled)"
        end
        return s
    end

    Admin._commands["wp.config"] = {
        description = "Show current config values",
        usage = "wp.config",
        category = "server",
        examples = {"wp.config"},
        handler = function(args)
            local lines = {"WindrosePlus Config:"}
            table.insert(lines, _fmtMultiplierLine("Loot", Admin._config.getLootMultiplier()))
            table.insert(lines, _fmtMultiplierLine("XP", Admin._config.getXpMultiplier()))
            table.insert(lines, _fmtMultiplierLine("Stack Size", Admin._config.getStackSizeMultiplier(), "stack_size"))
            table.insert(lines, _fmtMultiplierLine("Craft Efficiency", Admin._config.getCraftEfficiencyMultiplier()))
            table.insert(lines, _fmtMultiplierLine("Crop Speed", Admin._config.getCropSpeedMultiplier(), "crop_speed"))
            table.insert(lines, _fmtMultiplierLine("Weight", Admin._config.getWeightMultiplier(), "weight"))
            table.insert(lines, "  RCON: " .. (Admin._config.isRconEnabled() and "enabled" or "disabled"))
            local mods = WindrosePlus._modules.Mods
            if mods then
                table.insert(lines, "  Mods: " .. (mods.getLoadedCount and mods.getLoadedCount() or 0))
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.multipliers"] = {
        description = "Show all gameplay multipliers",
        usage = "wp.multipliers",
        category = "server",
        examples = {"wp.multipliers"},
        handler = function(args)
            local lines = {"Multipliers:"}
            table.insert(lines, _fmtMultiplierLine("Loot", Admin._config.getLootMultiplier()))
            table.insert(lines, _fmtMultiplierLine("XP", Admin._config.getXpMultiplier()))
            table.insert(lines, _fmtMultiplierLine("Stack Size", Admin._config.getStackSizeMultiplier(), "stack_size"))
            table.insert(lines, _fmtMultiplierLine("Craft Efficiency", Admin._config.getCraftEfficiencyMultiplier()))
            table.insert(lines, _fmtMultiplierLine("Crop Speed", Admin._config.getCropSpeedMultiplier(), "crop_speed"))
            table.insert(lines, _fmtMultiplierLine("Weight", Admin._config.getWeightMultiplier(), "weight"))
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.uptime"] = {
        description = "Show server uptime",
        usage = "wp.uptime",
        category = "server",
        examples = {"wp.uptime"},
        handler = function(args)
            -- Uptime from Lua boot timestamp (no wmic to avoid CMD window flash)
            local diff = os.time() - Admin._bootTime
            local days = math.floor(diff / 86400)
            local hours = math.floor((diff % 86400) / 3600)
            local mins = math.floor((diff % 3600) / 60)
            if days > 0 then
                return string.format("Uptime: %dd %dh %dm", days, hours, mins)
            else
                return string.format("Uptime: %dh %dm", hours, mins)
            end
        end
    }

    -- =========================================
    -- New Commands: Player Info
    -- =========================================

    Admin._commands["wp.playerinfo"] = {
        description = "Show consolidated player info (identity, vitals, stats, combat, progression)",
        usage = "wp.playerinfo [player]",
        category = "players",
        playerArg = true,
        examples = {"wp.playerinfo", "wp.playerinfo HumanGenome", "wp.playerinfo Some Player"},
        handler = function(args)
            -- Join all args as the player name so multi-word names match.
            local targetName = (#args > 0) and table.concat(args, " ") or nil
            local players = Admin._findPlayersByName(targetName)
            if #players == 0 then return targetName and ("Player '" .. targetName .. "' not found") or "No players online" end
            local lines = {}

            -- Helper: format a numeric value rounded to int, or "?" if nil
            local function fmtN(v) return v and tostring(math.floor(v + 0.5)) or "?" end
            -- Helper: format with width-aligned 3-char number
            local function fmtStat(label, v) return string.format("%-4s %3s", label, v and tostring(math.floor(v + 0.5)) or "?") end
            -- Helper: normalize whatever UE4SS returns for bAlive into a real bool.
            -- Some bindings return native booleans; some return 0/1 ints; some return
            -- string literals "true"/"false". Per maintainer review of PR #68.
            local function normalizeBool(v)
                if v == true or v == false then return v end
                if type(v) == "number" then return v ~= 0 end
                if type(v) == "string" then
                    local s = v:lower()
                    if s == "true" or s == "1" then return true end
                    if s == "false" or s == "0" then return false end
                end
                return nil
            end

            for _, p in ipairs(players) do
                -- Reuse pawn + playerState captured during _getPlayers' targeting
                -- pass instead of re-scanning R5Character actors. The re-scan path
                -- can silently fail when the pawn's PlayerState is detached during
                -- transitional states like ship boarding — even though the player
                -- is targetable via PlayerController (per maintainer review of #68).
                local pawn = p.pawn
                local ps = p.playerState
                local attrSet, prog = nil, nil
                if Admin._isValidUObject(ps) then
                    pcall(function() attrSet = ps.R5AttributeSet end)
                    pcall(function() prog = ps.ProgressionComponent end)
                end
                if not Admin._isValidUObject(attrSet) then attrSet = nil end
                if not Admin._isValidUObject(prog) then prog = nil end

                -- ==== Identity header ====
                local pName = p.displayName or p.name or "?"
                local actorId = p.actorName or "?"
                table.insert(lines, pName .. "  (" .. actorId .. ")")

                -- Server-local PlayerId (Engine.PlayerState.PlayerId, IntProperty).
                -- Self-hosted Windrose servers don't have an OnlineSubsystem
                -- populating UniqueID/SteamId/EpicAccountId, so those return
                -- empty UObject wrappers. PlayerId is the next-best stable
                -- identifier — unique per player per session, server-assigned,
                -- no auth dependency. Already resolved during _getPlayers.
                if p.playerId then
                    table.insert(lines, "  Player ID: " .. tostring(math.floor(p.playerId)))
                end


                -- ==== Session time ====
                -- Use the unified _resolveJoinTimeKey helper so wp.playerinfo
                -- and wp.playtime stay in lockstep with main.lua's onPlayerJoin
                -- keying (per maintainer review of PR #68).
                if Admin._playerJoinTimes then
                    local key = Admin._resolveJoinTimeKey(p)
                    local joinTime = key and Admin._playerJoinTimes[key]
                    if joinTime then
                        local elapsed = os.time() - joinTime
                        local hours = math.floor(elapsed / 3600)
                        local mins = math.floor((elapsed % 3600) / 60)
                        table.insert(lines, "  Session:   " .. hours .. "h " .. mins .. "m")
                    end
                end

                -- ==== Position ====
                if p.x then
                    table.insert(lines, string.format("  Position:  %.0f, %.0f, %.0f", p.x, p.y, p.z))
                end

                -- ==== Status (alive/dead via HealthComponent.bAlive) ====
                local alive = nil
                if Admin._isValidUObject(pawn) then
                    pcall(function()
                        local hc = pawn.HealthComponent
                        if Admin._isValidUObject(hc) then
                            alive = normalizeBool(hc.bAlive)
                        end
                    end)
                end
                if alive ~= nil then
                    table.insert(lines, "  Status:    " .. (alive and "Alive" or "Dead"))
                end

                -- ==== Vitals row (HP, Stamina, Stamina Recovery, Corruption) ====
                -- Aligned with the in-game UI's "Stat bonuses" panel. Corruption is
                -- hidden when both current and max are 0, since most players never
                -- accrue any (only certain biomes/effects produce it).
                if attrSet then
                    local hp = Admin._readGameplayAttribute(attrSet, "Health")
                    local maxHp = Admin._readGameplayAttribute(attrSet, "MaxHealth")
                    local stam = Admin._readGameplayAttribute(attrSet, "Stamina")
                    local maxStam = Admin._readGameplayAttribute(attrSet, "MaxStamina")
                    local stamRegen = Admin._readGameplayAttribute(attrSet, "StaminaRegenRate")
                    local corrupt = Admin._readGameplayAttribute(attrSet, "CorruptionStatus")
                    local maxCorrupt = Admin._readGameplayAttribute(attrSet, "MaxCorruptionStatus")

                    local vitals = {}
                    if hp or maxHp then
                        table.insert(vitals, "HP " .. fmtN(hp) .. "/" .. fmtN(maxHp))
                    end
                    if stam or maxStam then
                        table.insert(vitals, "Stamina " .. fmtN(stam) .. "/" .. fmtN(maxStam))
                    end
                    if stamRegen and stamRegen > 0 then
                        table.insert(vitals, "Recovery " .. fmtN(stamRegen))
                    end
                    -- Show Corruption when the player has any corruption capacity
                    -- (max > 0), even at 0 current — that surfaces "you can take
                    -- corruption damage in this biome" as informative state.
                    -- Hidden only when both current and max are 0 / nil.
                    if (corrupt and corrupt > 0) or (maxCorrupt and maxCorrupt > 0) then
                        table.insert(vitals, "Corruption " .. fmtN(corrupt) .. "/" .. fmtN(maxCorrupt))
                    end
                    if #vitals > 0 then
                        table.insert(lines, "  Vitals:    " .. table.concat(vitals, "   "))
                    end

                    -- ==== Stats grid — only the 6 stats the in-game UI surfaces ====
                    -- Mobility and Fortitude exist in R5AttributeSet but never display
                    -- in the player's Stats panel; they're always 0 for normal play
                    -- and would just clutter the output.
                    local stats = {
                        Str  = Admin._readGameplayAttribute(attrSet, "Strength"),
                        Agi  = Admin._readGameplayAttribute(attrSet, "Agility"),
                        Prec = Admin._readGameplayAttribute(attrSet, "Precision"),
                        Mas  = Admin._readGameplayAttribute(attrSet, "Mastery"),
                        Vit  = Admin._readGameplayAttribute(attrSet, "Vitality"),
                        End  = Admin._readGameplayAttribute(attrSet, "Endurance"),
                    }
                    if stats.Str or stats.Agi or stats.Prec or stats.Mas then
                        table.insert(lines, "  Stats:     "
                            .. fmtStat("Str",  stats.Str) .. "  "
                            .. fmtStat("Agi",  stats.Agi) .. "  "
                            .. fmtStat("Prec", stats.Prec))
                        table.insert(lines, "             "
                            .. fmtStat("Mas",  stats.Mas) .. "  "
                            .. fmtStat("Vit",  stats.Vit) .. "  "
                            .. fmtStat("End",  stats.End))
                    end

                    -- ==== Combat headlines (matches UI Stat bonuses panel) ====
                    -- Armor + Secondary AttackPower omitted: the UI surfaces
                    -- "Damage Resistance %" not raw Armor, and SecondaryAttackPower
                    -- typically equals MainAttackPower for non-dual-wield builds.
                    -- Crit values are 0-1 fractions in GAS; the UI multiplies by
                    -- 100 for percent display, so we do the same.
                    local atkMain = Admin._readGameplayAttribute(attrSet, "MainAttackPower")
                    local def = Admin._readGameplayAttribute(attrSet, "DefencePower")
                    local critBase = Admin._readGameplayAttribute(attrSet, "CriticalChanceBase")
                    local critMod = Admin._readGameplayAttribute(attrSet, "CriticalChanceModifier")
                    local critDmg = Admin._readGameplayAttribute(attrSet, "CriticalDamageDoneModifier")
                    local crit = nil
                    if critBase then crit = (critBase + (critMod or 0)) * 100 end
                    local critDmgPct = critDmg and (critDmg * 100) or nil

                    local combat = {}
                    if atkMain then table.insert(combat, "Attack " .. fmtN(atkMain)) end
                    if def then table.insert(combat, "Defense " .. fmtN(def)) end
                    if crit then table.insert(combat, string.format("Crit %.1f%%", crit)) end
                    if critDmgPct and critDmgPct > 0 then
                        table.insert(combat, string.format("CritDmg %.0f%%", critDmgPct))
                    end
                    if #combat > 0 then
                        table.insert(lines, "  Combat:    " .. table.concat(combat, "   "))
                    end
                end

                -- ==== Progression (talent + stat-point counts) ====
                -- nT is distinct talents that have at least one point, NOT total
                -- points spent across them. CachedLearnedTalents entry shape
                -- isn't fully probed yet — once we know the per-entry struct we
                -- can sum points and surface "X talents (Y points)".
                if Admin._isValidUObject(prog) then
                    local talents, statsArr = nil, nil
                    pcall(function() talents = prog.CachedLearnedTalents end)
                    pcall(function() statsArr = prog.CachedLearnedStats end)
                    local nT = Admin._readArrayLen(talents)
                    local nS = Admin._readArrayLen(statsArr)
                    if nT > 0 or nS > 0 then
                        table.insert(lines, "  Progress:  " .. nT .. " talents   " .. nS .. " stat upgrades")
                    end
                end

                -- Blank line between players (skip after last)
                table.insert(lines, "")
            end
            -- Trim trailing blank line
            if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.playtime"] = {
        description = "Show how long a player has been online this session",
        usage = "wp.playtime [player]",
        category = "players",
        playerArg = true,
        examples = {"wp.playtime", "wp.playtime HumanGenome", "wp.playtime Some Player"},
        handler = function(args)
            if not Admin._playerJoinTimes then return "No session data available" end
            -- Join all args as the player name so multi-word names ("Some Player") match.
            local targetName = (#args > 0) and table.concat(args, " ") or nil
            local players = Admin._findPlayersByName(targetName)
            if #players == 0 then return targetName and ("Player '" .. targetName .. "' not found") or "No players online" end
            local lines = {}
            for _, p in ipairs(players) do
                -- Use the unified _resolveJoinTimeKey helper so wp.playtime
                -- and wp.playerinfo stay in lockstep with main.lua's
                -- onPlayerJoin keying (per maintainer review of PR #68).
                local key = Admin._resolveJoinTimeKey(p)
                local joinTime = key and Admin._playerJoinTimes[key]
                if joinTime then
                    local elapsed = os.time() - joinTime
                    local hours = math.floor(elapsed / 3600)
                    local mins = math.floor((elapsed % 3600) / 60)
                    table.insert(lines, p.name .. ": " .. hours .. "h " .. mins .. "m")
                else
                    table.insert(lines, p.name .. ": unknown")
                end
            end
            return table.concat(lines, "\n")
        end
    }

    -- =========================================
    -- New Commands: World Monitoring
    -- =========================================

    Admin._commands["wp.creatures"] = {
        description = "Count spawned creatures by type",
        usage = "wp.creatures",
        category = "world",
        examples = {"wp.creatures"},
        handler = function(args)
            local pawns = FindAllOf("Pawn")
            if not pawns then return "No creatures found" end
            local counts = {}
            local total = 0
            for _, pawn in ipairs(pawns) do
                if pawn:IsValid() then
                    local fn = pawn:GetFullName()
                    if not fn:find("R5Character") and not fn:find("PlayerController") then
                        local name = "Unknown"
                        pcall(function()
                            name = fn:match("BP_[^_]+_([^_]+)") or fn:match("BP_([^_]+)") or "Mob"
                        end)
                        counts[name] = (counts[name] or 0) + 1
                        total = total + 1
                    end
                end
            end
            local sorted = {}
            for name, count in pairs(counts) do table.insert(sorted, {name = name, count = count}) end
            table.sort(sorted, function(a, b) return a.count > b.count end)
            local lines = {"Creatures (" .. total .. " total):"}
            for _, entry in ipairs(sorted) do
                table.insert(lines, "  " .. entry.name .. ": " .. entry.count)
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.entities"] = {
        description = "Count total entities by type (lag diagnosis)",
        usage = "wp.entities",
        category = "world",
        examples = {"wp.entities"},
        handler = function(args)
            local types = {"Pawn", "R5Character", "R5MineralNode", "PlayerController", "GameState"}
            local lines = {"Entity Counts:"}
            for _, t in ipairs(types) do
                local objs = FindAllOf(t)
                local count = 0
                if objs then
                    for _, o in ipairs(objs) do
                        if o:IsValid() then count = count + 1 end
                    end
                end
                if count > 0 then
                    table.insert(lines, "  " .. t .. ": " .. count)
                end
            end
            if #lines == 1 then table.insert(lines, "  No entities found") end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.weather"] = {
        description = "Read current weather and environmental values",
        usage = "wp.weather",
        category = "world",
        examples = {"wp.weather"},
        handler = function(args)
            local weatherProps = {"WindSpeed", "WaveHeight", "OceanCurrentSpeed",
                                  "TemperatureMultiplier", "WeatherState", "CurrentWeather",
                                  "WindDirection", "RainIntensity", "FogDensity"}
            local types = {"R5GameMode", "R5GameState", "GameState", "WorldSettings"}
            local lines = {}
            for _, t in ipairs(types) do
                local objs = FindAllOf(t)
                if objs then
                    for _, obj in ipairs(objs) do
                        if obj:IsValid() then
                            for _, p in ipairs(weatherProps) do
                                pcall(function()
                                    local v = obj[p]
                                    if v ~= nil then
                                        table.insert(lines, t .. "." .. p .. " = " .. tostring(v))
                                    end
                                end)
                            end
                        end
                    end
                end
            end
            return #lines > 0 and table.concat(lines, "\n") or "No weather data available"
        end
    }

    -- =========================================
    -- New Commands: Diagnostics
    -- =========================================

    Admin._commands["wp.doctor"] = {
        description = "Show a support snapshot with runtime, module, and config warnings",
        usage = "wp.doctor",
        category = "diagnostics",
        examples = {"wp.doctor"},
        handler = function(args)
            local function yesno(v) return v and "yes" or "no" end
            local function enabled(v) return v and "enabled" or "disabled" end
            local function fmtDuration(sec)
                sec = tonumber(sec) or 0
                local days = math.floor(sec / 86400)
                local hours = math.floor((sec % 86400) / 3600)
                local mins = math.floor((sec % 3600) / 60)
                if days > 0 then return string.format("%dd %dh %dm", days, hours, mins) end
                return string.format("%dh %dm", hours, mins)
            end

            local lines = {"WindrosePlus Doctor:"}
            local warnings = {}
            local state = WindrosePlus and WindrosePlus.state or {}
            local cfg = Admin._config
            local now = os.time()

            table.insert(lines, "  Version: " .. (WindrosePlus and WindrosePlus.VERSION or "?"))
            table.insert(lines, "  Mode: " .. tostring(state.mode or "unknown"))
            table.insert(lines, "  Uptime: " .. fmtDuration(now - (Admin._bootTime or now)))

            local controllers, active, zombies = 0, 0, 0
            local pcs = FindAllOf("PlayerController")
            if pcs then
                for _, pc in ipairs(pcs) do
                    if pc:IsValid() then
                        controllers = controllers + 1
                        if Admin._isConnected(pc) then active = active + 1 else zombies = zombies + 1 end
                    end
                end
            end
            table.insert(lines, "  Players: " .. active .. " active, " .. zombies .. " zombie, " .. tostring(state.playerCount or 0) .. " cached")
            table.insert(lines, "  PlayerControllers: " .. controllers)
            if zombies > 0 then table.insert(warnings, zombies .. " zombie PlayerController(s) detected") end

            local lastSeen = tonumber(state.lastPlayerSeen) or 0
            if lastSeen > 0 then
                table.insert(lines, "  Last Player: " .. fmtDuration(now - lastSeen) .. " ago")
            else
                table.insert(lines, "  Last Player: never seen")
            end
            if state.mode == "degraded" then
                table.insert(warnings, "WindrosePlus is in degraded mode; game-thread dispatch may be starved")
            end

            table.insert(lines, "")
            table.insert(lines, "Runtime:")
            table.insert(lines, "  LoopAsync: " .. yesno(type(LoopAsync) == "function"))
            table.insert(lines, "  ExecuteInGameThread: " .. yesno(type(ExecuteInGameThread) == "function"))
            table.insert(lines, "  RegisterHook: " .. yesno(type(RegisterHook) == "function"))
            table.insert(lines, "  RestartMod: " .. yesno(type(RestartMod) == "function"))
            if type(LoopAsync) ~= "function" then table.insert(warnings, "LoopAsync is unavailable; timers and RCON polling cannot run normally") end
            if type(ExecuteInGameThread) ~= "function" then table.insert(warnings, "ExecuteInGameThread is unavailable; UObject reads may race") end
            if type(RegisterHook) ~= "function" then table.insert(warnings, "RegisterHook is unavailable; hook-based mods cannot attach") end

            table.insert(lines, "")
            table.insert(lines, "Modules:")
            local modules = WindrosePlus and WindrosePlus._modules or {}
            for _, name in ipairs({"Config", "Admin", "Query", "RCON", "LiveMap", "MapGen", "POIScan", "Mods"}) do
                table.insert(lines, "  " .. name .. ": " .. (modules[name] and "OK" or "missing"))
                if not modules[name] then table.insert(warnings, name .. " module is missing") end
            end

            table.insert(lines, "")
            table.insert(lines, "Features:")
            table.insert(lines, "  RCON: " .. enabled(cfg and cfg.isRconEnabled and cfg.isRconEnabled()))
            table.insert(lines, "  Query: " .. enabled(cfg and cfg.isQueryEnabled and cfg.isQueryEnabled()))
            table.insert(lines, "  LiveMap: " .. enabled(cfg and cfg.isLiveMapEnabled and cfg.isLiveMapEnabled()))
            table.insert(lines, "  POIScan: " .. enabled(cfg and cfg.isPOIScanEnabled and cfg.isPOIScanEnabled()))
            if cfg and cfg.getQueryInterval and cfg.getQueryIdleInterval then
                table.insert(lines, "  Query intervals: " .. tostring(cfg.getQueryInterval()) .. "ms active / " .. tostring(cfg.getQueryIdleInterval()) .. "ms idle")
            end
            if cfg and cfg.getLiveMapPlayerInterval and cfg.getLiveMapEntityInterval then
                table.insert(lines, "  LiveMap intervals: " .. tostring(cfg.getLiveMapPlayerInterval()) .. "ms players / " .. tostring(cfg.getLiveMapEntityInterval()) .. "ms entities")
            end
            local mods = modules.Mods
            if mods and mods.getLoadedCount then
                table.insert(lines, "  Mods loaded: " .. tostring(mods.getLoadedCount()))
            end
            if cfg and cfg.isQueryEnabled and not cfg.isQueryEnabled() then table.insert(warnings, "Query writer is disabled; dashboard/server-status data may not update") end
            if cfg and cfg.isLiveMapEnabled and not cfg.isLiveMapEnabled() then table.insert(warnings, "LiveMap writer is disabled; Sea Chart data may not update") end

            local disabledMultipliers = {"points_per_level", "stack_size", "weight", "inventory_size", "crop_speed"}
            for _, key in ipairs(disabledMultipliers) do
                local raw = cfg and cfg.get and cfg.get("multipliers", key) or nil
                local n = tonumber(tostring(raw))
                if n and n ~= 1.0 then
                    table.insert(warnings, key .. " is configured as " .. tostring(raw) .. "x but is disabled/no-op in current PAK builds")
                end
            end

            table.insert(lines, "")
            table.insert(lines, "Warnings:")
            if #warnings == 0 then
                table.insert(lines, "  none")
            else
                for _, warning in ipairs(warnings) do
                    table.insert(lines, "  - " .. warning)
                end
            end

            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.memory"] = {
        description = "Show detailed memory usage",
        usage = "wp.memory",
        category = "diagnostics",
        examples = {"wp.memory"},
        handler = function(args)
            -- Memory metrics require wmic which flashes a CMD window on desktop
            -- Lua collectgarbage reports only Lua heap, not the full process
            local lines = {"Memory Usage:"}
            local luaKB = math.floor(collectgarbage("count"))
            table.insert(lines, "  Lua Heap: " .. luaKB .. " KB")
            table.insert(lines, "  Process memory: not available (use Task Manager or perfpoll)")
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.connections"] = {
        description = "Show network connection info",
        usage = "wp.connections",
        category = "diagnostics",
        examples = {"wp.connections"},
        handler = function(args)
            local lines = {"Connections:"}
            local pcs = FindAllOf("PlayerController")
            local connected = 0
            local zombies = 0
            if pcs then
                for _, pc in ipairs(pcs) do
                    if pc:IsValid() then
                        if Admin._isConnected(pc) then
                            connected = connected + 1
                        else
                            zombies = zombies + 1
                        end
                    end
                end
            end
            table.insert(lines, "  Active: " .. connected)
            if zombies > 0 then
                table.insert(lines, "  Zombie Controllers: " .. zombies)
            end
            table.insert(lines, "  Mode: " .. (WindrosePlus and WindrosePlus.state.mode or "unknown"))
            if WindrosePlus and WindrosePlus.state.lastPlayerSeen > 0 then
                local ago = os.time() - WindrosePlus.state.lastPlayerSeen
                if ago < 60 then
                    table.insert(lines, "  Last Player: " .. ago .. "s ago")
                else
                    table.insert(lines, "  Last Player: " .. math.floor(ago / 60) .. "m ago")
                end
            end
            return table.concat(lines, "\n")
        end
    }

    -- wp.givestats: record a stat-point compensation note for a player.
    -- Use case: when xp_multiplier was raised on a server with existing characters,
    -- the engine fires only one StatPointsReward per XP gain so players "skip"
    -- earned points across multiple levels. There is no safe live applier yet;
    -- this command only records an auditable note.
    -- Issue: HumanGenome/WindrosePlus#4
    Admin._commands["wp.givestats"] = {
        description = "Record stat/talent point compensation note (audit only)",
        usage = "wp.givestats <player> <stat_count> [talent_count]",
        category = "players",
        examples = {"wp.givestats Alice 3", "wp.givestats Bob 5 2"},
        handler = function(args)
            if #args < 2 then return "Usage: wp.givestats <player> <stat_count> [talent_count]" end
            -- Player names can contain spaces. RCON tokenizes on whitespace,
            -- so reconstruct: walk from the right, peel off 1-2 trailing numbers
            -- as stat_count/[talent_count], everything before joins as the name.
            local n = #args
            local last = tonumber(args[n])
            local prev = n >= 3 and tonumber(args[n - 1]) or nil
            local target, statCount, talentCount
            if last and prev then
                statCount = prev
                talentCount = last
                target = table.concat(args, " ", 1, n - 2)
            elseif last then
                statCount = last
                talentCount = 0
                target = table.concat(args, " ", 1, n - 1)
            else
                return "Usage: wp.givestats <player> <stat_count> [talent_count]"
            end
            if target == "" then return "Player name required" end
            if not statCount or statCount < 1 or statCount > 100 then
                return "stat_count must be 1-100"
            end
            if talentCount < 0 or talentCount > 100 then
                return "talent_count must be 0-100"
            end

            local matched = Admin._findPlayersByName(target)
            local connected = #matched > 0

            local entry = {
                ts = os.time(),
                type = "stat_compensation_note",
                player = target,
                stat_points = statCount,
                talent_points = talentCount,
                connected_at_request = connected
            }
            local ok, line = pcall(json.encode, entry)
            if not ok then return "Failed to encode audit note" end

            if not Admin._gameDir then return "Game directory not initialized" end
            local queuePath = Admin._gameDir .. "windrose_plus_data\\stat_grants_queue.log"
            local f = io.open(queuePath, "a")
            if not f then return "Failed to write audit note at " .. queuePath end
            f:write(line .. "\n")
            f:close()

            local msg = "Recorded audit note: " .. target .. " +" .. statCount .. " stat"
            if talentCount > 0 then msg = msg .. " +" .. talentCount .. " talent" end
            msg = msg .. ". This does not change the character in-game."
            if not connected then msg = msg .. " Player was offline when recorded." end
            return msg
        end
    }

    -- wp.kick / wp.netid / wp.say are deferred to v1.3.0. UE4SS Lua only binds
    -- UFunctions and a tiny set of native helpers (GetClass / IsValid / ToString /
    -- GetFName / GetFullName). It cannot call the C++ virtual methods needed for
    -- player disconnect (UNetConnection::Close, AActor::Destroy on remotely-owned
    -- PCs, UWorld::Exec, APlayerController::ConsoleCommand) and cannot deref
    -- USTRUCT-by-value properties like FUniqueNetIdRepl. All three features need a
    -- native UE4SS C++ mod (DLL) in the same release.

end

-- Delegate to shared helper in WindrosePlus global
function Admin._isConnected(pc)
    return WindrosePlus._isConnected(pc)
end

-- Helper: match a name (and optional type string) against a pipe-delimited filter
-- Filter "Steam|Unique" matches if name or type contains "steam" OR "unique" (case-insensitive substring).
function Admin._matchFilter(name, type_or_nil, filter)
    if not filter or filter == "" then return true end
    local lname = name and name:lower() or ""
    local ltype = type_or_nil and type_or_nil:lower() or ""
    for term in (filter .. "|"):gmatch("([^|]*)|") do
        if term ~= "" then
            local lt = term:lower()
            if lname:find(lt, 1, true) then return true end
            if ltype ~= "" and ltype:find(lt, 1, true) then return true end
        end
    end
    return false
end

-- Defensive UObject validity check. Calling :IsValid() outside pcall on a
-- non-UObject (or torn-down object) can fault below the Lua boundary in some
-- UE4SS bindings; pcall keeps that contained.
function Admin._isValidUObject(o)
    if o == nil then return false end
    local ok, valid = pcall(function() return o:IsValid() end)
    return ok and valid == true
end

-- Module-level player-target matcher. Mirrors the local helper in
-- _registerCommands() that the movement commands use, hoisted here so
-- _findPlayersByName can share it (per maintainer review of PR #68 — avoid
-- drift between the movement and info-command targeting paths).
function Admin._playerTargetMatches(targetName, displayName, actorName, actorFullName)
    if not targetName then return true end
    local target = targetName:lower()
    if displayName and displayName:lower() == target then return true end
    if actorName and actorName:lower() == target then return true end
    if actorFullName and actorFullName:lower() == target then return true end
    return false
end

-- Read a value from an FGameplayAttributeData struct on an R5GAS AttributeSet.
-- GAS attributes have BaseValue (raw) and CurrentValue (after active modifiers).
-- We prefer CurrentValue since that's what the game logic actually uses for
-- damage rolls / regen / display. Falls back through other patterns if the
-- struct shape varies.
function Admin._readGameplayAttribute(attrSet, fieldName)
    if not Admin._isValidUObject(attrSet) then return nil end
    local attr = nil
    pcall(function() attr = attrSet[fieldName] end)
    if attr == nil then return nil end
    -- Defensive: if a future engine update renames or removes the attribute,
    -- UE4SS may surface the missing field as a UObject wrapper instead of an
    -- FGameplayAttributeData struct. Drilling into a UObject sub-handle here
    -- has hung the UE4SS Lua VM in the past (e.g. R5GameMode.TimeOfDay walks
    -- on 4/29) — and pcall can't catch a hang. Bail early if we got a wrapper.
    if tostring(attr):match("^UObject:") then return nil end
    -- Try the GAS standard sub-fields in priority order (most builds expose
    -- the FGameplayAttributeData struct fields directly).
    for _, sub in ipairs({"CurrentValue", "BaseValue", "Value"}) do
        local ok, val = pcall(function() return attr[sub] end)
        if ok and val ~= nil then
            local n = tonumber(tostring(val))
            if n then return n end
        end
    end
    -- Method-form cascade: some GAS builds expose the values via
    -- BlueprintCallable getters instead of direct struct access.
    -- (Per maintainer review of PR #68.)
    for _, method in ipairs({"GetCurrentValue", "GetBaseValue", "GetValue"}) do
        local ok, val = pcall(function() return attr[method](attr) end)
        if ok and val ~= nil then
            local n = tonumber(tostring(val))
            if n then return n end
        end
    end
    -- Last resort: tostring the whole thing in case it's a raw float
    local n = tonumber(tostring(attr))
    if n then return n end
    return nil
end

-- Resolves the key main.lua's onPlayerJoin used to populate Admin._playerJoinTimes.
-- main.lua keys by player.name from Query.getPlayers(), which follows the
-- priority: PlayerNamePrivate -> "Player <id>" -> "Player". The same priority
-- here keeps wp.playerinfo and wp.playtime aligned even in the early-connect
-- race window where displayName hasn't loaded yet (per maintainer review of #68).
function Admin._resolveJoinTimeKey(p)
    if not p then return nil end
    if p.displayName and p.displayName ~= "" then return p.displayName end
    if p.name and p.name ~= "" then return p.name end
    if p.playerId then return "Player " .. tostring(p.playerId) end
    return nil
end

-- Read length of a UE TArray defensively. UE4SS exposes arrays through
-- different access patterns depending on type — try the Lua # operator first,
-- then UE's GetArrayNum() method, then a Length property.
function Admin._readArrayLen(arr)
    if arr == nil then return 0 end
    local ok, len = pcall(function() return #arr end)
    if ok and type(len) == "number" then return len end
    ok, len = pcall(function() return arr:GetArrayNum() end)
    if ok and type(len) == "number" then return len end
    ok, len = pcall(function() return arr.Length end)
    if ok and type(len) == "number" then return len end
    return 0
end

function Admin._findPlayersByName(targetName)
    local players = Admin._getPlayers()
    if not targetName then return players end
    local matched = {}
    for _, p in ipairs(players) do
        -- Use the shared matcher so info-commands and movement-commands stay
        -- in lockstep (per maintainer review of PR #68).
        if Admin._playerTargetMatches(targetName, p.displayName, p.actorName, p.actorFullName)
           or (p.name and p.name:lower() == targetName:lower()) then
            table.insert(matched, p)
        end
    end
    return matched
end

-- Shared UE4 property names for discovery/inspection commands
Admin._UE4_PROPS = {
    -- Gameplay multipliers
    "XPMultiplier", "ExperienceMultiplier", "LootMultiplier", "HarvestMultiplier",
    "DamageMultiplier", "PlayerDamageMultiplier", "NPCDamageMultiplier",
    "StackSizeMultiplier", "CraftCostMultiplier", "CropGrowthMultiplier",
    "WeightMultiplier", "StructureDamageMultiplier", "ResourceAmountMultiplier",
    "ResourceRespawnMultiplier", "StaminaDrainMultiplier", "HungerDrainMultiplier",
    "ThirstDrainMultiplier", "HealthRegenMultiplier", "StaminaRegenMultiplier",
    "DurabilityMultiplier", "RepairCostMultiplier", "FuelConsumptionMultiplier",
    "SpeedMultiplier", "JumpMultiplier", "FallDamageMultiplier",
    -- Time/Day
    "TimeOfDay", "CurrentTimeOfDay", "DayCycleDuration", "NightCycleDuration",
    "DayNightCycleSpeed", "DayLength", "NightLength", "TimeDilation",
    "MatineeTimeDilation", "DemoPlayTimeDilation",
    -- Server settings
    "MaxPlayers", "ServerName", "ServerPassword", "NumPlayers", "NumBots",
    "bAllowPVP", "bAllowBuilding", "bAllowCheats", "bPauseable",
    "SpawnRate", "DifficultyLevel", "Difficulty",
    "DropOnDeath", "bDropOnDeath", "KeepInventoryOnDeath",
    "RespawnTimer", "RespawnCooldown",
    -- Physics
    "GlobalGravityZ", "GravityScale", "bGlobalGravitySet",
    "KillZ", "WorldGravityZ",
    -- Network
    "ServerTickRate", "NetServerMaxTickRate", "MaxTickRate",
    "bUseFixedFrameRate", "FixedFrameRate",
    "MinNetUpdateFrequency", "NetUpdateFrequency",
    -- Movement
    "MaxWalkSpeed", "MaxSwimSpeed", "MaxFlySpeed", "JumpZVelocity",
    "MaxAcceleration", "BrakingDecelerationWalking",
    "CheatMovementSpeedModifer", "bCanFly", "bCheatFlying",
    -- Health/Combat
    "MaxHealth", "CurrentHealth", "BaseHealth",
    "BaseDamage", "BaseArmor", "BaseResistance",
    -- Character
    "bCanBeDamaged", "bCanPickupItems", "bHidden",
    "bIsInvulnerable", "bInvincible",
    -- Game mode
    "bUseSeamlessTravel", "bStartPlayersAsSpectators",
    "bDelayedStart", "DefaultPlayerName", "bEnableWorldComposition",
    -- R5-specific
    "SailSpeed", "WindSpeed", "WaveHeight", "OceanCurrentSpeed",
    "CrewSize", "MaxCrewSize", "ShipHealth", "ShipMaxHealth",
    "CannonDamage", "CannonRange", "CannonReloadTime",
    "FishingMultiplier", "CookingSpeed", "SmeltingSpeed",
    "BuildingDamageMultiplier", "SiegeDamageMultiplier",
    "TamingSpeedMultiplier", "BreedingSpeedMultiplier",
    "FoodDrainMultiplier", "WaterDrainMultiplier",
    "OxygenDrainMultiplier", "TemperatureMultiplier",
    "NightVisionEnabled", "MapFogEnabled",
    -- General UE4
    "NetCullDistanceSquared", "NetPriority",
    "bAlwaysRelevant", "bReplicates", "NumSpectators",
    "GameSessionClass",
}

-- Helper: probe a UE4 object for properties and return found values
-- filter matches against both property name and value
function Admin._probeObject(obj, filter)
    local found = {}
    for _, prop in ipairs(Admin._UE4_PROPS) do
        pcall(function()
            local v = obj[prop]
            if v ~= nil then
                local display = tostring(v)
                pcall(function()
                    local s = v:ToString()
                    if s and s ~= "" then display = s end
                end)
                local num = tonumber(display)
                if num then display = tostring(num) end
                -- Skip raw UObject pointers
                if not display:match("^UObject:") and not display:match("^FString:") and not display:match("^FText:") then
                    if not filter or prop:lower():find(filter, 1, true) or display:lower():find(filter, 1, true) then
                        found[#found + 1] = { name = prop, value = display }
                    end
                end
            end
        end)
    end
    return found
end

-- Helper: find first valid instance of a UE4 type
function Admin._findFirstValid(typeName)
    local results = FindAllOf(typeName)
    if not results then return nil end
    for _, o in ipairs(results) do
        if o:IsValid() then return o end
    end
    return nil
end

-- Helper: lookup live position from the LiveMap snapshot (which is collected
-- on the game thread by LiveMap.writeIfDue and stored as plain Lua values).
-- This is the async-safe path: reading from the snapshot is just table access,
-- no UFunction calls. Returns nil if the snapshot is missing or no entry
-- matches by display name / actor name. Same data the dashboard uses.
local function liveMapPosition(displayName, actorName)
    local lm = WindrosePlus and WindrosePlus._modules and WindrosePlus._modules.LiveMap
    if not lm then return nil end
    local snap = lm._lastSnapshot
    if not snap or type(snap.players) ~= "table" then return nil end
    for _, sp in ipairs(snap.players) do
        if sp.name and (sp.name == displayName or sp.name == actorName) and sp.x then
            return sp.x, sp.y, sp.z
        end
    end
    return nil
end

-- Helper: read display name + playerId off a PlayerState, with fallbacks
-- matching Query.getPlayers()'s priority (PlayerNamePrivate -> "Player <id>"
-- -> "Player"). Returns (displayName, playerId, fallbackName).
-- displayName is nil if PlayerNamePrivate hasn't replicated yet.
local function readNameFromPlayerState(ps)
    local displayName, playerId = nil, nil
    if not Admin._isValidUObject(ps) then return nil, nil, nil end
    pcall(function()
        local val = ps.PlayerNamePrivate
        if val then
            local ok, str = pcall(function() return val:ToString() end)
            if ok and str and str ~= "" then displayName = str end
        end
    end)
    pcall(function()
        local pid = ps.PlayerId
        if pid ~= nil then
            local n = tonumber(tostring(pid))
            if n then playerId = n end
        end
    end)
    local fallbackName = displayName or (playerId and ("Player " .. tostring(playerId))) or "Player"
    return displayName, playerId, fallbackName
end

-- Helper: read position from LiveMap snapshot first (game-thread-collected,
-- async-safe), then ReplicatedMovement.Location (struct property, async-safe
-- but lags a tick / reads 0,0,0 for ship-parented actors), then RootComponent
-- as a last resort. Returns x,y,z or nil. K2_GetActorLocation is intentionally
-- not called here — it's a UFunction and unsafe from the LoopAsync thread
-- that drives info commands.
local function readPositionAsyncSafe(actor, displayName, actorName)
    local x, y, z = liveMapPosition(displayName, actorName)
    if x then return x, y, z end
    if not Admin._isValidUObject(actor) then return nil end
    pcall(function()
        local repMove = actor.ReplicatedMovement
        if repMove then
            local loc = repMove.Location
            if loc then x, y, z = loc.X, loc.Y, loc.Z end
        end
    end)
    if x then return x, y, z end
    pcall(function()
        local root = actor.RootComponent
        if Admin._isValidUObject(root) then
            local rel = root.RelativeLocation
            if rel then x, y, z = rel.X, rel.Y, rel.Z end
        end
    end)
    return x, y, z
end

-- Helper: get player list with positions and resolved component references.
-- Mirrors Query.getPlayers()'s PlayerController-primary + R5Character-fallback
-- pattern (per maintainer review of PR #68 — issue #67 reports cases where
-- the PC scan returns empty even with players connected; the R5Character
-- iteration is reached via char.Controller.PlayerState in those cases).
--
-- Position chain is async-safe by design: K2_GetActorLocation is a UFunction
-- and unsafe from the LoopAsync thread that drives info commands. We read
-- from the LiveMap snapshot (game-thread-collected) or the already-replicated
-- Location struct field instead.
--
-- Each entry exposes:
--   p.name          - displayName -> "Player <id>" -> "Player" (matches Query)
--   p.displayName   - PlayerState.PlayerNamePrivate (nil during early connect)
--   p.playerId      - PlayerState.PlayerId (server-local int, stable per session)
--   p.actorName     - last segment of pawn:GetFullName(), e.g. BP_R5Character_C_2145886219
--   p.actorFullName - full pawn:GetFullName()
--   p.pawn          - PlayerController.Pawn (the R5Character actor) or nil
--   p.playerState   - PlayerController.PlayerState or nil
--   p.x/p.y/p.z     - position, when available
function Admin._getPlayers()
    local players = {}

    -- Primary: iterate PlayerControllers, filtered through Admin._isConnected
    -- so we don't pull in disconnected/spectator PCs (matches Query.getPlayers).
    local pcs = FindAllOf("PlayerController")
    if pcs then
        for _, pc in ipairs(pcs) do
            if Admin._isValidUObject(pc) and Admin._isConnected(pc) then
                local ps = nil
                pcall(function() ps = pc.PlayerState end)
                if not Admin._isValidUObject(ps) then ps = nil end

                local displayName, playerId, fallbackName = readNameFromPlayerState(ps)

                local pawn = nil
                pcall(function() pawn = pc.Pawn end)
                if not Admin._isValidUObject(pawn) then pawn = nil end

                if pawn then
                    local actorFullName, actorName = nil, nil
                    pcall(function()
                        actorFullName = pawn:GetFullName()
                        if actorFullName then
                            actorName = actorFullName:match("([^%.]+)$") or actorFullName
                        end
                    end)

                    local player = {
                        name          = fallbackName,
                        displayName   = displayName,
                        playerId      = playerId,
                        actorName     = actorName,
                        actorFullName = actorFullName,
                        pawn          = pawn,
                        playerState   = ps,
                    }
                    player.x, player.y, player.z = readPositionAsyncSafe(pawn, displayName, actorName)
                    table.insert(players, player)
                end
            end
        end
    end

    -- Fallback: if PC enumeration yielded nothing (issue #67 — at least one
    -- customer report where this happens even with players online), iterate
    -- R5Character actors and reach PlayerState through char.Controller. Same
    -- struct shape so info commands work identically against either path.
    if #players == 0 then
        local chars = FindAllOf("R5Character")
        if chars then
            for _, char in ipairs(chars) do
                if Admin._isValidUObject(char) then
                    local controller = nil
                    pcall(function() controller = char.Controller end)
                    if Admin._isValidUObject(controller) then
                        local ps = nil
                        pcall(function() ps = controller.PlayerState end)
                        if not Admin._isValidUObject(ps) then ps = nil end

                        local displayName, playerId, fallbackName = readNameFromPlayerState(ps)

                        local actorFullName, actorName = nil, nil
                        pcall(function()
                            actorFullName = char:GetFullName()
                            if actorFullName then
                                actorName = actorFullName:match("([^%.]+)$") or actorFullName
                            end
                        end)

                        local player = {
                            name          = fallbackName,
                            displayName   = displayName,
                            playerId      = playerId,
                            actorName     = actorName,
                            actorFullName = actorFullName,
                            pawn          = char,
                            playerState   = ps,
                        }
                        player.x, player.y, player.z = readPositionAsyncSafe(char, displayName, actorName)
                        table.insert(players, player)
                    end
                end
            end
        end
    end

    return players
end

return Admin
