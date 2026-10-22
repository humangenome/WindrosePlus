-- Example Welcome Mod for WindrosePlus
-- Logs player join/leave events to the server console
-- Turn it on by adding "example-welcome" to WindrosePlus/Mods/mods_registry.json

local API = WindrosePlus.API

API.onPlayerJoin(function(player)
    API.log("info", "Welcome", player.name .. " joined the server")
end)

API.onPlayerLeave(function(player)
    API.log("info", "Welcome", player.name .. " left the server")
end)

-- Register a custom command
API.registerCommand("wp.greet", function(args)
    local players = API.getPlayers()
    if #players == 0 then return "No players to greet" end
    local names = {}
    for _, p in ipairs(players) do table.insert(names, p.name) end
    return "Ahoy, " .. table.concat(names, ", ") .. "!"
end, "Greet all online players", "wp.greet")
