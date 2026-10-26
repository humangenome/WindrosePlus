-- WindrosePlus Permissions Module
-- Role-based access to commands for channels that know the caller's AccountId (an in-game console, a chat bridge).
-- RCON and the dashboard are not affected: they keep full access.
--
-- Data: windrose_plus_data\permissions.json
--   { "version": 1,
--     "accounts": { "<AccountId>": { "role": "admin", "note": "name" } },
--     "commands": { "wp.give": "admin", "wp.client schema": "public" } }
--
-- Roles: public (account not listed) < member < admin < dev.
-- A command's role: rule "<command> <subcommand>", else rule "<command>", else dev. There is no wildcard and no
-- category rule on purpose: a command nobody assigned is dev-only, never public.

local json = require("modules.json")
local Log = require("modules.log")

local Permissions = {}

Permissions.VERSION = 1
Permissions.ROLES = { "public", "member", "admin", "dev" }
local RANK = { public = 0, member = 1, admin = 2, dev = 3 }

-- Defaults for the core commands, added unless the file already has a rule for the same key (a server's own choice
-- stays). Mods ship defaults for their commands with API.setDefaultCommandRole. Anything not listed is dev only.
Permissions.BUILTIN = {
    -- everyone
    ["wp.help"] = "public", ["wp.version"] = "public",
    -- known players: server state, who is online, player details; their own permissions (list/check show only them)
    ["wp.status"] = "member", ["wp.uptime"] = "member", ["wp.time"] = "member", ["wp.multipliers"] = "member",
    ["wp.players"] = "member", ["wp.playtime"] = "member", ["wp.pos"] = "member", ["wp.health"] = "member",
    ["wp.stamina"] = "member", ["wp.playerinfo"] = "member",
    ["wp.perms list"] = "member", ["wp.perms check"] = "member",
    -- admins: moderation, player changes, server operations and diagnostics, permissions up to admin
    ["wp.kick"] = "admin", ["wp.ban"] = "admin", ["wp.unban"] = "admin", ["wp.listbans"] = "admin",
    ["wp.givestats"] = "admin", ["wp.speed"] = "admin", ["wp.jump"] = "admin", ["wp.gravity"] = "admin",
    ["wp.tp"] = "admin", ["wp.config"] = "admin", ["wp.reload"] = "admin", ["wp.mapexport"] = "admin",
    ["wp.mapgen"] = "admin", ["wp.perf"] = "admin", ["wp.memory"] = "admin", ["wp.connections"] = "admin",
    ["wp.doctor"] = "admin", ["wp.creatures"] = "admin", ["wp.entities"] = "admin",
    ["wp.perms role"] = "admin", ["wp.perms set"] = "admin", ["wp.perms unset"] = "admin",
    -- dev: debug tools (explicit, so the file documents it); wp.inspect / wp.peek / wp.props can crash the server
    ["wp.inspect"] = "dev", ["wp.peek"] = "dev", ["wp.props"] = "dev", ["wp.fields"] = "dev", ["wp.methods"] = "dev",
    ["wp.discover"] = "dev", ["wp.gm"] = "dev", ["wp.settings"] = "dev", ["wp.nativeprobe"] = "dev",
    ["wp.probe_player"] = "dev", ["wp.mapprobe"] = "dev", ["wp.modreload"] = "dev",
    ["wp.perms prune"] = "dev", ["wp.perms reload"] = "dev",
}

Permissions._path = nil
Permissions._accounts = {}   -- AccountId -> { role, note }
Permissions._commands = {}   -- rule -> role
Permissions._broken = nil    -- error text when the file could not be read; then everything is dev-only, nothing saved
Permissions._admin = nil
Permissions._emit = nil
Permissions._resolver = nil  -- fn(nameOrId) -> AccountId or nil (set by a mod that can look players up)
Permissions._loggedUnassigned = {}

local function rankOf(role) return RANK[role] end

function Permissions.isRole(role) return RANK[role] ~= nil end

function Permissions.rank(role) return RANK[role] or 0 end

-- ---------------------------------------------------------------------------------------------------------------
-- File
-- ---------------------------------------------------------------------------------------------------------------

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- One entry per line, sorted: stays readable and diffable when edited by hand
function Permissions._format()
    local lines = { "{", '  "version": ' .. Permissions.VERSION .. ",", '  "accounts": {' }
    local ids = sortedKeys(Permissions._accounts)
    for i, id in ipairs(ids) do
        local a = Permissions._accounts[id]
        local entry = '    ' .. json.encode(id) .. ': { "role": ' .. json.encode(a.role)
        if a.note and a.note ~= "" then entry = entry .. ', "note": ' .. json.encode(a.note) end
        lines[#lines + 1] = entry .. " }" .. (i < #ids and "," or "")
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = '  "commands": {'
    local rules = sortedKeys(Permissions._commands)
    for i, rule in ipairs(rules) do
        lines[#lines + 1] = '    ' .. json.encode(rule) .. ": " .. json.encode(Permissions._commands[rule]) .. (i < #rules and "," or "")
    end
    lines[#lines + 1] = "  }"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

function Permissions._save()
    if Permissions._broken then
        return false, "permissions.json could not be read (" .. Permissions._broken .. "); fix it and run wp.perms reload"
    end
    local tmp = Permissions._path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "cannot write " .. tmp end
    f:write(Permissions._format())
    f:close()
    os.remove(Permissions._path)
    local ok, err = os.rename(tmp, Permissions._path)
    if not ok then return false, "cannot replace " .. Permissions._path .. ": " .. tostring(err) end
    return true
end

-- Returns true, or false and the reason (the old state stays in memory then)
function Permissions.load()
    local accounts, commands = {}, {}
    local f = io.open(Permissions._path, "r")
    if f then
        local text = f:read("*a")
        f:close()
        local ok, data = pcall(json.decode, text)
        local problem = nil
        if not ok then
            problem = "invalid JSON: " .. tostring(data)
        elseif type(data) ~= "table" then
            problem = "not a JSON object"
        elseif data.version ~= Permissions.VERSION then
            problem = "unsupported version " .. tostring(data.version) .. " (expected " .. Permissions.VERSION .. ")"
        end
        if problem then
            Permissions._broken = problem
            Permissions._accounts, Permissions._commands = {}, {}
            Log.error("Permissions", Permissions._path .. ": " .. problem .. "; every command is dev-only until fixed (wp.perms reload)")
            return false, problem
        end
        for id, a in pairs(type(data.accounts) == "table" and data.accounts or {}) do
            local role = type(a) == "table" and a.role or a
            if rankOf(role) then
                accounts[tostring(id)] = { role = role, note = type(a) == "table" and tostring(a.note or "") or "" }
            else
                Log.warn("Permissions", "account " .. tostring(id) .. ": unknown role " .. tostring(role) .. ", ignored")
            end
        end
        for rule, role in pairs(type(data.commands) == "table" and data.commands or {}) do
            if rankOf(role) then
                commands[tostring(rule):lower()] = role
            else
                Log.warn("Permissions", "rule " .. tostring(rule) .. ": unknown role " .. tostring(role) .. ", ignored")
            end
        end
    end
    Permissions._broken = nil
    Permissions._accounts, Permissions._commands = accounts, commands
    local added = false
    for rule, role in pairs(Permissions.BUILTIN) do
        if commands[rule] == nil then commands[rule] = role; added = true end
    end
    if added or not f then Permissions._save() end
    local n = 0
    for _ in pairs(accounts) do n = n + 1 end
    Log.info("Permissions", string.format("%d account(s), %d command rule(s) from %s", n, #sortedKeys(commands), Permissions._path))
    return true
end

function Permissions.init(gameDir, admin, emit)
    Permissions._path = gameDir .. "windrose_plus_data\\permissions.json"
    Permissions._admin = admin
    Permissions._emit = emit
    Permissions.load()
    Permissions._registerCommand()
end

local function changed(kind, id)
    if Permissions._emit then pcall(Permissions._emit, "permissions.changed", { kind = kind, id = id }) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lookup
-- ---------------------------------------------------------------------------------------------------------------

-- Registered command name for what the caller typed ("give" -> "wp.give", like Admin.execute)
function Permissions.canonical(command)
    local name = tostring(command or ""):lower()
    local cmds = Permissions._admin and Permissions._admin._commands or {}
    if cmds[name] == nil and cmds["wp." .. name] ~= nil then name = "wp." .. name end
    return name
end

function Permissions.getRole(accountId)
    if accountId == nil or Permissions._broken then return "public" end
    local a = Permissions._accounts[tostring(accountId)]
    return a and a.role or "public"
end

-- role, rule ("<cmd> <sub>", "<cmd>" or nil when unassigned = dev)
function Permissions.requiredRole(command, args)
    local name = Permissions.canonical(command)
    if Permissions._broken then return "dev", nil end
    local sub = type(args) == "table" and args[1] and tostring(args[1]):lower() or nil
    if sub and Permissions._commands[name .. " " .. sub] then
        return Permissions._commands[name .. " " .. sub], name .. " " .. sub
    end
    if Permissions._commands[name] then return Permissions._commands[name], name end
    if not Permissions._loggedUnassigned[name] then
        Permissions._loggedUnassigned[name] = true
        Log.info("Permissions", name .. ": no permission rule, dev only (wp.perms set " .. name .. " <role>)")
    end
    return "dev", nil
end

-- ok, neededRole, rule
function Permissions.isAllowed(accountId, command, args)
    local needed, rule = Permissions.requiredRole(command, args)
    return RANK[Permissions.getRole(accountId)] >= RANK[needed], needed, rule
end

function Permissions.setAccountResolver(fn)
    Permissions._resolver = type(fn) == "function" and fn or nil
end

-- AccountId for "<AccountId>" or an online player name (needs a resolver), or nil
function Permissions.resolve(target)
    if target == nil or target == "" then return nil end
    if Permissions._resolver then
        local ok, aid = pcall(Permissions._resolver, target)
        if ok and type(aid) == "string" and aid ~= "" then return aid, target end
    end
    return tostring(target), nil
end

function Permissions.list()
    local out = { accounts = {}, commands = {}, unassigned = {}, stale = {}, broken = Permissions._broken }
    for _, id in ipairs(sortedKeys(Permissions._accounts)) do
        local a = Permissions._accounts[id]
        out.accounts[#out.accounts + 1] = { id = id, role = a.role, note = a.note }
    end
    local registered = Permissions._admin and Permissions._admin._commands or {}
    for _, rule in ipairs(sortedKeys(Permissions._commands)) do
        local entry = { rule = rule, role = Permissions._commands[rule] }
        out.commands[#out.commands + 1] = entry
        if registered[rule:match("^(%S+)")] == nil then out.stale[#out.stale + 1] = entry end
    end
    for _, name in ipairs(sortedKeys(registered)) do
        if Permissions._commands[name] == nil then
            out.unassigned[#out.unassigned + 1] = { rule = name, suggested = registered[name].role }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- Changes. actor: nil = RCON (no limits), or { accountId } of an in-game caller (limits below).
-- ---------------------------------------------------------------------------------------------------------------

local function devCount()
    local n = 0
    for _, a in pairs(Permissions._accounts) do if a.role == "dev" then n = n + 1 end end
    return n
end

function Permissions.setRole(accountId, role, note, actor)
    if not rankOf(role) then return false, "unknown role " .. tostring(role) .. " (public, member, admin, dev)" end
    local id = tostring(accountId)
    local current = Permissions.getRole(id)
    if actor then
        local actorRole = Permissions.getRole(actor.accountId)
        if tostring(actor.accountId) == id then return false, "you cannot change your own role" end
        if actorRole ~= "dev" then
            if RANK[current] >= RANK.admin then return false, "needs dev: " .. id .. " is " .. current end
            if RANK[role] > RANK.admin then return false, "needs dev: only dev can grant dev" end
        end
        if current == "dev" and role ~= "dev" and devCount() <= 1 then return false, "cannot remove the last dev" end
    end
    local before = Permissions._accounts[id]
    if role == "public" then
        Permissions._accounts[id] = nil
    else
        Permissions._accounts[id] = { role = role, note = note or (before and before.note) or "" }
    end
    local ok, err = Permissions._save()
    if not ok then Permissions._accounts[id] = before; return false, err end
    changed("account", id)
    return true
end

-- rule: "<command>" or "<command> <sub>"; role nil removes the rule (the command falls back to the next rule / dev)
function Permissions.setCommandRole(rule, role, actor)
    local key = tostring(rule or ""):lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if key == "" then return false, "no command given" end
    local name, sub = key:match("^(%S+)%s*(.*)$")
    key = Permissions.canonical(name) .. (sub ~= "" and (" " .. sub) or "")
    if role ~= nil and not rankOf(role) then return false, "unknown role " .. tostring(role) .. " (public, member, admin, dev)" end
    if actor and Permissions.getRole(actor.accountId) ~= "dev" then
        local old = Permissions._commands[key] or "dev"
        if RANK[old] > RANK.admin then return false, "needs dev: " .. key .. " is " .. old .. (Permissions._commands[key] and "" or " (unassigned)") end
        if role and RANK[role] > RANK.admin then return false, "needs dev: only dev can make a command dev-only" end
        if role == nil then return false, "needs dev: removing a rule makes the command dev-only" end
    end
    local before = Permissions._commands[key]
    Permissions._commands[key] = role
    local ok, err = Permissions._save()
    if not ok then Permissions._commands[key] = before; return false, err end
    changed("command", key)
    return true, key
end

-- Add a rule only if none exists (mods ship defaults for their own commands); saved, no event
function Permissions.setDefault(rule, role)
    local key = tostring(rule or ""):lower()
    if key == "" or not rankOf(role) or Permissions._broken or Permissions._commands[key] ~= nil then return false end
    Permissions._commands[key] = role
    Permissions._save()
    return true
end

function Permissions.prune()
    local removed = {}
    for _, entry in ipairs(Permissions.list().stale) do
        Permissions._commands[entry.rule] = nil
        removed[#removed + 1] = entry.rule
    end
    if #removed > 0 then
        local ok, err = Permissions._save()
        if not ok then return false, err end
        changed("command", "*")
    end
    return true, removed
end

-- ---------------------------------------------------------------------------------------------------------------
-- wp.perms
-- ---------------------------------------------------------------------------------------------------------------

local USAGE = "wp.perms list [accounts|commands|unassigned|stale] [--json] | wp.perms role <player|accountId> <role> [note] | " ..
              "wp.perms set <command [sub]> <role> | wp.perms unset <command [sub]> | wp.perms check <player|accountId> <command ...> | " ..
              "wp.perms prune | wp.perms reload"

local function listText(section)
    local data = Permissions.list()
    local lines = {}
    if data.broken then lines[#lines + 1] = "WARNING: permissions.json unreadable (" .. data.broken .. "); everything is dev-only" end
    if section == nil or section == "accounts" then
        lines[#lines + 1] = "Accounts (" .. #data.accounts .. "; everyone else is public):"
        for _, a in ipairs(data.accounts) do
            lines[#lines + 1] = string.format("  %-6s %s%s", a.role, a.id, a.note ~= "" and ("  # " .. a.note) or "")
        end
    end
    if section == nil or section == "commands" then
        lines[#lines + 1] = "Command rules (" .. #data.commands .. "; commands without a rule are dev only):"
        for _, c in ipairs(data.commands) do lines[#lines + 1] = string.format("  %-6s %s", c.role, c.rule) end
    end
    if section == nil or section == "unassigned" then
        lines[#lines + 1] = "Unassigned, dev only (" .. #data.unassigned .. "):"
        for _, c in ipairs(data.unassigned) do
            lines[#lines + 1] = "  " .. c.rule .. (c.suggested and ("  (suggested: " .. c.suggested .. ")") or "")
        end
    end
    if section == nil or section == "stale" then
        if #data.stale > 0 or section == "stale" then
            lines[#lines + 1] = "Stale rules, command not registered (" .. #data.stale .. "; wp.perms prune removes them):"
            for _, c in ipairs(data.stale) do lines[#lines + 1] = string.format("  %-6s %s", c.role, c.rule) end
        end
    end
    return table.concat(lines, "\n")
end

-- args: the words after wp.perms; caller: nil (RCON) or { accountId, name }
function Permissions.command(args, caller)
    local sub = (args[1] or ""):lower()
    local actorRole = caller and Permissions.getRole(caller.accountId) or "dev"

    -- Below admin, list and check show only the caller (self-diagnosis: my role, what I may run), never other accounts
    local selfOnly = caller ~= nil and RANK[actorRole] < RANK.admin

    if sub == "list" then
        local section, asJson = nil, false
        for i = 2, #args do
            if args[i] == "--json" then asJson = true else section = args[i]:lower() end
        end
        if selfOnly then
            local mine = { role = actorRole, accountId = tostring(caller.accountId), commands = {} }
            for _, c in ipairs(Permissions.list().commands) do
                if RANK[actorRole] >= RANK[c.role] then mine.commands[#mine.commands + 1] = c end
            end
            if asJson then return "[Perms] " .. json.encode(mine) end
            local lines = { "You are " .. actorRole .. " (" .. mine.accountId .. "). You may run:" }
            for _, c in ipairs(mine.commands) do lines[#lines + 1] = string.format("  %-6s %s", c.role, c.rule) end
            return table.concat(lines, "\n")
        end
        if asJson then return "[Perms] " .. json.encode(Permissions.list()) end
        return listText(section)
    end

    if sub == "check" then
        local target, words = args[2], {}
        for i = 3, #args do words[#words + 1] = args[i] end
        local id, name
        if selfOnly then
            -- wp.perms check <command ...> (yourself); naming another account is refused
            words = {}
            for i = 2, #args do words[#words + 1] = args[i] end
            if #words == 0 then return "Usage: wp.perms check <command ...>" end
            -- a first word that names an account (in the file, or an online player) is a target, not a command
            local other, otherName = Permissions.resolve(words[1])
            local isAccount = #words >= 2 and (otherName ~= nil or Permissions._accounts[other] ~= nil)
            if isAccount and other ~= tostring(caller.accountId) then
                return "[Error] you can only check your own permissions"
            end
            if isAccount then table.remove(words, 1) end
            id = tostring(caller.accountId)
        else
            if not target or #words == 0 then return "Usage: wp.perms check <player|accountId> <command ...>" end
            id, name = Permissions.resolve(target)
        end
        local cmd = table.remove(words, 1)
        local ok, needed, rule = Permissions.isAllowed(id, cmd, words)
        return string.format("%s%s is %s; %s needs %s (%s): %s", id, name and (" (" .. name .. ")") or "",
            Permissions.getRole(id), Permissions.canonical(cmd), needed, rule and ("rule " .. rule) or "no rule",
            ok and "allowed" or "denied")
    end

    if sub == "role" then
        local target, role = args[2], args[3] and args[3]:lower()
        if not target or not role then return "Usage: wp.perms role <player|accountId> <public|member|admin|dev> [note]" end
        local id, name = Permissions.resolve(target)
        local noteWords = {}
        for i = 4, #args do noteWords[#noteWords + 1] = args[i] end
        local note = #noteWords > 0 and table.concat(noteWords, " ") or name
        local ok, err = Permissions.setRole(id, role, note, caller)
        if not ok then return "[Error] " .. err end
        Log.info("Permissions", string.format("%s -> %s%s (by %s)", id, role, name and (" (" .. name .. ")") or "",
            caller and tostring(caller.name or caller.accountId) or "RCON"))
        return id .. (name and (" (" .. name .. ")") or "") .. " is now " .. role .. "."
    end

    if sub == "set" or sub == "unset" then
        local words = {}
        for i = 2, #args do words[#words + 1] = args[i] end
        local role = nil
        if sub == "set" then
            role = words[#words] and words[#words]:lower()
            words[#words] = nil
            if #words == 0 or not role then return "Usage: wp.perms set <command [sub]> <public|member|admin|dev>" end
        elseif #words == 0 then
            return "Usage: wp.perms unset <command [sub]>"
        end
        local ok, keyOrErr = Permissions.setCommandRole(table.concat(words, " "), role, caller)
        if not ok then return "[Error] " .. keyOrErr end
        Log.info("Permissions", string.format("rule %s -> %s (by %s)", keyOrErr, role or "removed",
            caller and tostring(caller.name or caller.accountId) or "RCON"))
        if role then return "Rule " .. keyOrErr .. " = " .. role .. "." end
        return "Rule " .. keyOrErr .. " removed (now " .. Permissions.requiredRole(keyOrErr:match("^(%S+)"), { keyOrErr:match("^%S+%s+(%S+)") }) .. ")."
    end

    if sub == "prune" or sub == "reload" then
        if actorRole ~= "dev" then return "[Error] needs dev" end
        if sub == "prune" then
            local ok, removed = Permissions.prune()
            if not ok then return "[Error] " .. removed end
            return #removed == 0 and "No stale rules." or ("Removed " .. #removed .. " stale rule(s): " .. table.concat(removed, ", "))
        end
        local ok, err = Permissions.load()
        changed("command", "*")
        changed("account", "*")
        if not ok then return "[Error] " .. err end
        return "Permissions reloaded."
    end

    return "Usage: " .. USAGE
end

Permissions.SUBCOMMANDS = {
    { name = "list", usage = "[accounts|commands|unassigned|stale] [--json]", description = "Roles and rules (members: only their own)" },
    { name = "role", usage = "<player|accountId> <public|member|admin|dev> [note]", description = "Give an account a role" },
    { name = "set", usage = "<command [sub]> <role>", description = "Set the role a command or subcommand needs" },
    { name = "unset", usage = "<command [sub]>", description = "Remove a rule (the command falls back to the next rule / dev)" },
    { name = "check", usage = "<player|accountId> <command ...>", description = "May this account run this? (members: only themselves)" },
    { name = "prune", usage = "", description = "Remove rules for commands that no longer exist" },
    { name = "reload", usage = "", description = "Re-read permissions.json after a hand edit" },
}

function Permissions._registerCommand()
    local admin = Permissions._admin
    if not admin then return end
    local description = "Roles per account and per command (public < member < admin < dev) for in-game channels"
    local handler = function(args, caller) return Permissions.command(args or {}, caller) end
    if admin.register then
        -- one handler parses every subcommand; the list is for wp.help, commands.json and in-game consoles
        admin.register("wp.perms", handler, description, nil, { category = "admin", subcommands = Permissions.SUBCOMMANDS })
    else
        admin._commands["wp.perms"] = { description = description, usage = USAGE, category = "admin", handler = handler }
    end
end

return Permissions
