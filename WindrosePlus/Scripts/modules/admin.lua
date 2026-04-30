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
                table.insert(lines, "  " .. i .. ". " .. p.name .. posStr)
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
                local nameMatch = not targetName or (pName and pName:lower() == targetName)
                if nameMatch then
                    pcall(function()
                        local pawn = pc.Pawn
                        if pawn and pawn:IsValid() then
                            local mc = pawn.CharacterMovement or pawn.MovementComponent
                            if mc and mc:IsValid() then
                                local key = pName or tostring(pc)
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
        examples = {"wp.speed 2.0", "wp.speed HumanGenome 1.5", "wp.speed John Smith 1.5"},
        playerArg = true,
        handler = function(args) return setMovementCheat(args, "speed") end,
    }

    Admin._commands["wp.jump"] = {
        description = "Set player jump height multiplier (JumpZVelocity; 1.0=normal, 2.0=double)",
        usage = "wp.jump [player] <multiplier>",
        category = "admin",
        examples = {"wp.jump 2.0", "wp.jump HumanGenome 3"},
        playerArg = true,
        handler = function(args) return setMovementCheat(args, "jump") end,
    }

    Admin._commands["wp.gravity"] = {
        description = "Set player gravity multiplier (CharacterMovement.GravityScale; 1.0=normal, 0.3=moon)",
        usage = "wp.gravity [player] <multiplier>",
        category = "admin",
        examples = {"wp.gravity 0.3", "wp.gravity HumanGenome 2"},
        playerArg = true,
        handler = function(args) return setMovementCheat(args, "gravity") end,
    }

    Admin._commands["wp.health"] = {
        description = "Read player health",
        usage = "wp.health [player]",
        category = "players",
        playerArg = true,
        handler = function(args)
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end

            local lines = {}
            local chars = FindAllOf("R5Character")
            if not chars then return "No character data" end
            for _, p in ipairs(players) do
                for _, char in ipairs(chars) do
                    if char:IsValid() then
                        local charName = nil
                        pcall(function() charName = char:GetFullName():match("([^%.]+)$") end)
                        if charName == p.name then
                            pcall(function()
                                local hc = char.HealthComponent
                                if hc and hc:IsValid() then
                                    local hp = hc.CurrentHealth
                                    local maxHp = hc.MaxHealth
                                    table.insert(lines, p.name .. ": " .. (hp and tostring(hp) or "?") .. "/" .. (maxHp and tostring(maxHp) or "?") .. " HP")
                                else
                                    table.insert(lines, p.name .. ": No HealthComponent")
                                end
                            end)
                            break
                        end
                    end
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
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end
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
                    local nameMatch = not targetName or (pName and pName:lower() == targetName)
                    if nameMatch then
                        matched = matched + 1
                        pcall(function()
                            local pawn = pc.Pawn
                            if not (pawn and pawn:IsValid()) then
                                table.insert(results, (pName or "?") .. ": no pawn")
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
                                table.insert(results, string.format("%s: ERR %s", pName or "?", tostring(ret)))
                                return
                            end
                            anyTeleported = true
                            table.insert(results, string.format("%s: tp -> (%.0f, %.0f, %.0f) ret=%s",
                                pName or "?", x, y, targetZ, tostring(ret)))
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
            local targetName = args[1] and args[1]:lower() or nil
            local chars = FindAllOf("R5Character")
            if not chars then return "No character data" end

            local lines = {}
            for _, char in ipairs(chars) do
                if char:IsValid() then
                    local charName = nil
                    pcall(function() charName = char:GetFullName():match("([^%.]+)$") end)

                    local nameMatch = not targetName or (charName and charName:lower() == targetName)
                    if nameMatch then
                        local playerLines = {}
                        for _, comp in ipairs({"StaminaComponent", "HungerComponent", "ThirstComponent"}) do
                            pcall(function()
                                local c = char[comp]
                                if c and c:IsValid() then
                                    local props = {"CurrentStamina", "MaxStamina", "CurrentValue", "MaxValue",
                                                   "CurrentHunger", "MaxHunger", "CurrentThirst", "MaxThirst"}
                                    for _, p in ipairs(props) do
                                        pcall(function()
                                            local v = c[p]
                                            if v ~= nil then
                                                table.insert(playerLines, "  " .. comp .. "." .. p .. " = " .. tostring(v))
                                            end
                                        end)
                                    end
                                end
                            end)
                        end
                        if #playerLines > 0 then
                            table.insert(lines, (charName or "Unknown") .. ":")
                            for _, l in ipairs(playerLines) do table.insert(lines, l) end
                        end
                    end
                end
            end
            if #lines == 0 and targetName then return "Player '" .. targetName .. "' not found" end
            return #lines > 0 and table.concat(lines, "\n") or "No stamina data"
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

    Admin._commands["wp.config"] = {
        description = "Show current config values",
        usage = "wp.config",
        category = "server",
        examples = {"wp.config"},
        handler = function(args)
            local lines = {"WindrosePlus Config:"}
            table.insert(lines, "  Loot: " .. Admin._config.getLootMultiplier() .. "x")
            table.insert(lines, "  XP: " .. Admin._config.getXpMultiplier() .. "x")
            table.insert(lines, "  Stack Size: " .. Admin._config.getStackSizeMultiplier() .. "x")
            table.insert(lines, "  Craft Efficiency: " .. Admin._config.getCraftEfficiencyMultiplier() .. "x")
            table.insert(lines, "  Crop Speed: " .. Admin._config.getCropSpeedMultiplier() .. "x")
            table.insert(lines, "  Weight: " .. Admin._config.getWeightMultiplier() .. "x")
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
            table.insert(lines, "  Loot: " .. Admin._config.getLootMultiplier() .. "x")
            table.insert(lines, "  XP: " .. Admin._config.getXpMultiplier() .. "x")
            table.insert(lines, "  Stack Size: " .. Admin._config.getStackSizeMultiplier() .. "x")
            table.insert(lines, "  Craft Efficiency: " .. Admin._config.getCraftEfficiencyMultiplier() .. "x")
            table.insert(lines, "  Crop Speed: " .. Admin._config.getCropSpeedMultiplier() .. "x")
            table.insert(lines, "  Weight: " .. Admin._config.getWeightMultiplier() .. "x")
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
        description = "Show consolidated player info (health, position, status)",
        usage = "wp.playerinfo [player]",
        category = "players",
        playerArg = true,
        examples = {"wp.playerinfo", "wp.playerinfo HumanGenome"},
        handler = function(args)
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end
            local chars = FindAllOf("R5Character")
            local lines = {}
            for _, p in ipairs(players) do
                local info = {p.name .. ":"}
                if p.x then
                    table.insert(info, string.format("  Position: %.0f, %.0f, %.0f", p.x, p.y, p.z))
                end
                -- Find matching character for health
                if chars then
                    for _, char in ipairs(chars) do
                        if char:IsValid() then
                            local cn = nil
                            pcall(function() cn = char:GetFullName():match("([^%.]+)$") end)
                            if cn == p.name then
                                pcall(function()
                                    local hc = char.HealthComponent
                                    if hc and hc:IsValid() then
                                        table.insert(info, "  Health: " .. tostring(hc.CurrentHealth or "?") .. "/" .. tostring(hc.MaxHealth or "?"))
                                        local alive = hc.CurrentHealth and tonumber(tostring(hc.CurrentHealth)) > 0
                                        table.insert(info, "  Alive: " .. (alive and "Yes" or "No"))
                                    end
                                end)
                                break
                            end
                        end
                    end
                end
                -- Session time
                if Admin._playerJoinTimes and Admin._playerJoinTimes[p.name] then
                    local elapsed = os.time() - Admin._playerJoinTimes[p.name]
                    local hours = math.floor(elapsed / 3600)
                    local mins = math.floor((elapsed % 3600) / 60)
                    table.insert(info, "  Session: " .. hours .. "h " .. mins .. "m")
                end
                for _, l in ipairs(info) do table.insert(lines, l) end
            end
            return table.concat(lines, "\n")
        end
    }

    Admin._commands["wp.playtime"] = {
        description = "Show how long a player has been online this session",
        usage = "wp.playtime [player]",
        category = "players",
        playerArg = true,
        examples = {"wp.playtime", "wp.playtime HumanGenome"},
        handler = function(args)
            if not Admin._playerJoinTimes then return "No session data available" end
            local players = Admin._findPlayersByName(args[1])
            if #players == 0 then return args[1] and ("Player '" .. args[1] .. "' not found") or "No players online" end
            local lines = {}
            for _, p in ipairs(players) do
                local joinTime = Admin._playerJoinTimes[p.name]
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

-- Helper: find player(s) by display name from R5PlayerState.PlayerNamePrivate
-- Returns table of { state = R5PlayerState, pc = PlayerController-or-nil, name = "..." }
function Admin._findPlayerByDisplayName(targetName)
    local matches = {}
    local target = targetName and targetName:lower() or nil
    local states = FindAllOf("R5PlayerState") or FindAllOf("PlayerState")
    if not states then return matches end
    for _, ps in ipairs(states) do
        if ps:IsValid() then
            local name = nil
            pcall(function() name = ps.PlayerNamePrivate:ToString() end)
            if name and name ~= "" then
                if not target or name:lower() == target then
                    local pc = nil
                    pcall(function() pc = ps:GetPlayerController() end)
                    table.insert(matches, { state = ps, pc = pc, name = name })
                end
            end
        end
    end
    return matches
end

-- Helper: find players by name (case-insensitive exact match, or return all if no filter)
function Admin._findPlayersByName(targetName)
    local players = Admin._getPlayers()
    if not targetName then return players end
    local target = targetName:lower()
    local matched = {}
    for _, p in ipairs(players) do
        if p.name and p.name:lower() == target then
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

-- Helper: get player list with positions
function Admin._getPlayers()
    local players = {}
    local chars = FindAllOf("R5Character")
    if not chars then return players end

    for _, char in ipairs(chars) do
        if char:IsValid() then
            local hasController = false
            pcall(function()
                local ctrl = char.Controller
                if ctrl and ctrl:IsValid() then hasController = true end
            end)

            if hasController then
                local player = { name = "Unknown" }

                pcall(function()
                    local fn = char:GetFullName()
                    player.name = fn:match("([^%.]+)$") or fn
                end)

                pcall(function()
                    local repMove = char.ReplicatedMovement
                    if repMove then
                        local loc = repMove.Location
                        if loc then
                            player.x = loc.X
                            player.y = loc.Y
                            player.z = loc.Z
                        end
                    end
                end)

                if not player.x then
                    pcall(function()
                        local root = char.RootComponent
                        if root and root:IsValid() then
                            local rel = root.RelativeLocation
                            if rel then
                                player.x = rel.X
                                player.y = rel.Y
                                player.z = rel.Z
                            end
                        end
                    end)
                end

                table.insert(players, player)
            end
        end
    end
    return players
end

return Admin
