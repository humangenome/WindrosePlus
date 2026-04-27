-- WindrosePlus RCON Module
-- File-based command processor using a spool directory
--
-- IPC Protocol:
--   External tool writes: <spool_dir>/cmd_<id>.json
--   Lua reads, executes, writes: <spool_dir>/res_<id>.json
--   External tool reads response, deletes both files

local json = require("modules.json")
local Log = require("modules.log")
local Events = require("modules.events")

local Rcon = {}
Rcon._spoolDir = nil
Rcon._gameDir = nil
Rcon._loopHandle = nil
Rcon._admin = nil
Rcon._config = nil
Rcon._commandExpirySec = 30
Rcon._consoleHistoryMax = 100
Rcon._tickCallbacks = {}
Rcon._activeInterval = 1     -- seconds (os.time resolution is 1s)
Rcon._idleInterval = 5       -- seconds
Rcon._lastPoll = 0
Rcon._historyBuffer = {}     -- batched history entries
Rcon._lastHistoryFlush = 0   -- last time buffer was flushed to disk
Rcon._historyFlushInterval = 5  -- flush every 5 seconds
Rcon._historyFlushSize = 10    -- or every 10 entries
Rcon._lastHeartbeat = 0
Rcon._heartbeatInterval = 5
Rcon._lastErrorDetail = ""
Rcon._lastErrorTs = 0

function Rcon.init(gameDir, config, adminModule)
    Rcon._gameDir = gameDir
    Rcon._spoolDir = gameDir .. "windrose_plus_data\\rcon"
    Rcon._config = config
    Rcon._admin = adminModule

    if not config.isRconEnabled() then
        Log.info("RCON", "RCON disabled (set password in windrose_plus.json to enable)")
        return
    end

    -- Ensure spool directory exists (pure Lua — no os.execute/CMD flash)
    -- The installer creates this directory; this just verifies it's writable
    local testFile = Rcon._spoolDir .. "\\.wp_dirtest"
    local tf = io.open(testFile, "w")
    if tf then
        tf:close()
        os.remove(testFile)
    else
        Log.warn("RCON", "Spool directory not writable: " .. Rcon._spoolDir)
    end
    Rcon._recoverProcessingIndex()
    Rcon._cleanStaleFiles()
    Rcon._writeHeartbeat("starting", "RCON worker starting")

    -- Archive previous session's console history and start fresh
    Rcon._archiveAndResetHistory()

    Log.info("RCON", "Command processor started")
    Log.info("RCON", "Spool directory: " .. Rcon._spoolDir)
    Rcon._writeHeartbeat("running", "ready")

    -- Poll at 2000ms (reduced from 500ms to cut idle CPU ~75%)
    -- Active mode: processes every 2s (os.time gate at 1s passes every wakeup)
    -- Idle mode: processes every 5s (2-3 wakeups skipped between scans)
    Rcon._loopHandle = LoopAsync(2000, function()
        local now = os.time()
        local interval = Rcon._activeInterval
        if WindrosePlus and WindrosePlus.isIdle() then
            interval = Rcon._idleInterval
        end
        if now - Rcon._lastPoll >= interval then
            Rcon._lastPoll = now
            local ok, err = pcall(Rcon._processCommands)
            if not ok then
                local msg = tostring(err)
                Log.warn("RCON", "Command processor error: " .. msg)
                Rcon._writeHeartbeat("error", msg)
            end
        end
        if now - Rcon._lastHeartbeat >= Rcon._heartbeatInterval then
            Rcon._writeHeartbeat("running", "polling")
        end
        -- Flush buffered history entries periodically
        if #Rcon._historyBuffer > 0 and (now - Rcon._lastHistoryFlush >= Rcon._historyFlushInterval) then
            pcall(Rcon._flushHistoryBuffer)
        end
        for _, cb in ipairs(Rcon._tickCallbacks) do
            pcall(cb)
        end
        return false
    end)
end

function Rcon._writeHeartbeat(state, detail)
    if not Rcon._gameDir or not Rcon._spoolDir then return end

    if state == "error" then
        Rcon._lastErrorDetail = detail or ""
        Rcon._lastErrorTs = os.time()
    end

    local statusPath = Rcon._gameDir .. "windrose_plus_data\\rcon_status.json"
    local tmpPath = statusPath .. ".tmp"
    local payload = json.encode({
        ts = os.time(),
        version = WindrosePlus and WindrosePlus.VERSION or "?",
        state = state or "running",
        detail = detail or "",
        last_error = Rcon._lastErrorDetail or "",
        last_error_ts = Rcon._lastErrorTs or 0,
        spool_dir = Rcon._spoolDir
    })

    local file = io.open(tmpPath, "w")
    if not file then return end
    file:write(payload)
    file:close()

    os.remove(statusPath)
    if not os.rename(tmpPath, statusPath) then
        os.remove(tmpPath)
        local direct = io.open(statusPath, "w")
        if direct then
            direct:write(payload)
            direct:close()
        end
    end
    Rcon._lastHeartbeat = os.time()
end

function Rcon._archiveAndResetHistory()
    -- Flush any buffered entries before archiving
    pcall(Rcon._flushHistoryBuffer)

    -- Write a signal file requesting PHP to archive the old history on next API call
    -- (UE4SS can't run os.execute/io.popen reliably — they deadlock in this context)
    local historyPath = Rcon._gameDir .. "windrose_plus_data\\console_history.json"
    local signalPath = Rcon._gameDir .. "windrose_plus_data\\archive_request.txt"

    local file = io.open(historyPath, "r")
    if file then
        local content = file:read("*a")
        file:close()
        if content and content ~= "" and content ~= "[]" then
            -- Save a backup for PHP to archive (Lua can't mkdir/rename reliably)
            local backupPath = Rcon._gameDir .. "windrose_plus_data\\console_history.json.pre_session"
            local bf = io.open(backupPath, "w")
            if bf then bf:write(content); bf:close() end
            -- Signal PHP to archive the backup on next API call
            local sf = io.open(signalPath, "w")
            if sf then sf:write("archive"); sf:close() end
        end
    end

    -- Start fresh console for this session
    local f = io.open(historyPath, "w")
    if f then f:write("[]"); f:close() end
    Log.info("RCON", "Console history reset for new session")
end

function Rcon._cleanStaleFiles()
    -- Clean stale response files and incomplete temp command writes by probing known ID patterns.
    -- Real cmd_*.json files are retryable work items and must not be deleted here.
    -- No io.popen('dir') needed — avoids CMD window flash
    local prefixes = {"api_", "ps_", "web_", ""}
    local now = os.time()
    for _, prefix in ipairs({"res_", "cmd_"}) do
        for _, idPrefix in ipairs(prefixes) do
            for t = now - 60, now do
                local filename = prefix .. idPrefix .. t .. ".json"
                if prefix == "res_" then
                    os.remove(Rcon._spoolDir .. "\\" .. filename)
                end
                os.remove(Rcon._spoolDir .. "\\" .. filename .. ".tmp")
            end
        end
        for i = 0, 20 do
            local filename = prefix .. i .. ".json"
            if prefix == "res_" then
                os.remove(Rcon._spoolDir .. "\\" .. filename)
            end
            os.remove(Rcon._spoolDir .. "\\" .. filename .. ".tmp")
        end
    end
end

function Rcon._recoverProcessingIndex()
    local batchPath = Rcon._spoolDir .. "\\pending_commands.processing"
    local file = io.open(batchPath, "r")
    if not file then return end

    local content = file:read("*a")
    file:close()
    os.remove(batchPath)

    if not content or content == "" then return end

    local indexPath = Rcon._spoolDir .. "\\pending_commands.txt"
    local out = io.open(indexPath, "a")
    if out then
        out:write(content)
        if content:sub(-1) ~= "\n" then out:write("\r\n") end
        out:close()
        Log.warn("RCON", "Recovered pending command index from previous session")
    end
end

-- Track the next command sequence number to try
Rcon._nextSeqId = 0
-- Known command ID prefixes used by the PHP/API layer
Rcon._cmdPrefixes = {"api_", "ps_", "web_", ""}

function Rcon._processCommands()
    -- Read command filenames from pending_commands.txt (written by dashboard/API)
    -- Atomic: rename to .processing before reading to avoid losing entries
    local indexPath = Rcon._spoolDir .. "\\pending_commands.txt"
    local batchPath = Rcon._spoolDir .. "\\pending_commands.processing"

    -- Atomically grab the index file
    local renamed = os.rename(indexPath, batchPath)
    if not renamed then return end

    local indexFile = io.open(batchPath, "r")
    if not indexFile then
        os.rename(batchPath, indexPath)
        Rcon._writeHeartbeat("error", "Unable to read pending command batch")
        return
    end
    local content = indexFile:read("*a")
    indexFile:close()

    if not content or content == "" then
        os.remove(batchPath)
        return
    end

    -- Strip UTF-8 BOM if present
    if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end

    local found = {}
    for filename in content:gmatch("[^\r\n]+") do
        filename = filename:match("^%s*(.-)%s*$") -- trim
        if filename ~= "" then
            local filePath = Rcon._spoolDir .. "\\" .. filename
            local f = io.open(filePath, "r")
            if f then
                f:close()
                found[#found + 1] = {path = filePath, name = filename}
            end
        end
    end

    -- Fallback: try sequential IDs
    for i = 0, 10 do
        local filename = "cmd_" .. (Rcon._nextSeqId + i) .. ".json"
        local filePath = Rcon._spoolDir .. "\\" .. filename
        local f = io.open(filePath, "r")
        if f then
            f:close()
            found[#found + 1] = {path = filePath, name = filename}
            Rcon._nextSeqId = Rcon._nextSeqId + i + 1
        end
    end

    -- Deduplicate and process
    local processed = {}
    local processedCount = 0
    local failed = {}
    for _, entry in ipairs(found) do
        if not processed[entry.path] then
            processed[entry.path] = true
            local ok, err = pcall(Rcon._processFile, entry.path, entry.name)
            if ok then
                processedCount = processedCount + 1
            else
                local msg = tostring(err)
                Log.warn("RCON", "Command failed before response: " .. entry.name .. " - " .. msg)
                failed[#failed + 1] = entry.name
            end
        end
    end

    if #failed > 0 then
        local out = io.open(indexPath, "a")
        if out then
            for _, name in ipairs(failed) do
                out:write(name .. "\r\n")
            end
            out:close()
            os.remove(batchPath)
        else
            Rcon._writeHeartbeat("error", "processed " .. tostring(processedCount) .. " command(s); failed to requeue " .. tostring(#failed))
            return
        end
        Rcon._writeHeartbeat("error", "processed " .. tostring(processedCount) .. " command(s); requeued " .. tostring(#failed))
    else
        os.remove(batchPath)
        Rcon._writeHeartbeat("running", "processed " .. tostring(processedCount) .. " command(s)")
    end
end

function Rcon._processFile(filePath, filename)
    local fileId = tostring((filename or ""):match("^cmd_(.+)%.json$") or "unknown"):gsub("[^%w_%-]", "")
    if fileId == "" then fileId = "unknown" end

    local function finishWithId(responseId, status, message, responseCommand, responseAdmin)
        local okWrite, written = pcall(Rcon._writeResponse, responseId, status, message, responseCommand, responseAdmin)
        if not okWrite then error(tostring(written)) end
        if written == false then error("Unable to write response file") end
        os.remove(filePath)
    end

    local file = io.open(filePath, "r")
    if not file then return end
    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        finishWithId(fileId, "error", "Empty command file", nil, nil)
        return
    end

    local ok, data = pcall(json.decode, content)
    if not ok or type(data) ~= "table" then
        local badId = (content:match('"id"%s*:%s*"([^"]*)"') or fileId):gsub("[^%w_%-]", "")
        if badId == "" then badId = fileId end
        finishWithId(badId, "error", "Malformed JSON in command file", nil, nil)
        Log.warn("RCON", "Malformed command: " .. filename)
        return
    end

    local rawId = tostring(data.id or "0")
    local id = rawId:gsub("[^%w_%-]", "")
    if id == "" then id = "0" end
    local command = data.command
    local originalCommand = command
    local args = data.args or {}
    local password = data.password
    local adminUser = data.admin_user

    local function finish(status, message, responseCommand, responseAdmin)
        finishWithId(id, status, message, responseCommand, responseAdmin)
    end

    if not command then
        finish("error", "Missing 'command' field", originalCommand, adminUser)
        return
    end

    if data.timestamp then
        local timestamp = tonumber(data.timestamp)
        if not timestamp then
            finish("error", "Invalid command timestamp", originalCommand, adminUser)
            return
        end
        local age = os.time() - timestamp
        if age > Rcon._commandExpirySec then
            finish("error", "Command expired (" .. age .. "s old)", originalCommand, adminUser)
            return
        end
    end

    if Rcon._config and Rcon._config.reload then
        local okReload, reloadErr = pcall(Rcon._config.reload)
        if not okReload then
            finish("error", "Config reload failed: " .. tostring(reloadErr), originalCommand, adminUser)
            return
        end
    end

    local okPassword, expectedPassword = pcall(Rcon._config.getRconPassword)
    if not okPassword then
        finish("error", "Config password read failed: " .. tostring(expectedPassword), originalCommand, adminUser)
        return
    end

    if password ~= expectedPassword then
        finish("error", "Authentication failed")
        Log.warn("RCON", "Auth failed: " .. command)
        return
    end

    Log.info("RCON", "Executing: " .. command)

    if not Rcon._admin then
        finish("error", "Admin module not loaded", originalCommand, adminUser)
        return
    end
    if #args == 0 then
        local parts = {}
        for part in command:gmatch("%S+") do table.insert(parts, part) end
        if #parts > 1 then
            command = parts[1]
            for i = 2, #parts do table.insert(args, parts[i]) end
        end
    end
    local startMs = (os.clock() * 1000)
    local ok, status, message = pcall(Rcon._admin.execute, command, args)
    local durationMs = math.floor((os.clock() * 1000) - startMs + 0.5)

    -- Truncate response message in the activity log to keep entries small.
    -- Full message still goes back to the caller; this is just the record.
    local recordedMessage = nil
    if message ~= nil then
        local s = tostring(message)
        if #s > 512 then s = s:sub(1, 512) .. "...(truncated)" end
        recordedMessage = s
    end
    Events.record("admin.command", {
        id = id,
        command = originalCommand,
        resolved_command = command,
        args = args,
        admin_user = adminUser,
        ok = ok,
        status = ok and status or "error",
        message = ok and recordedMessage or tostring(status),
        duration_ms = durationMs,
    })

    if ok then
        finish(status, message, originalCommand, adminUser)
    else
        finish("error", tostring(status), originalCommand, adminUser)
    end
end

function Rcon._writeResponse(id, status, message, command, adminUser)
    local response = json.encode({
        id = id, status = status, message = message, timestamp = os.time()
    })
    local resPath = Rcon._spoolDir .. "\\res_" .. id .. ".json"
    local tmpPath = resPath .. ".tmp"
    local file = io.open(tmpPath, "w")
    if not file then return false end
    local wrote = file:write(response)
    if not wrote then
        file:close()
        os.remove(tmpPath)
        return false
    end
    local closed = file:close()
    if not closed then
        os.remove(tmpPath)
        return false
    end
    local renamed = os.rename(tmpPath, resPath)
    if not renamed then
        os.remove(resPath)
        renamed = os.rename(tmpPath, resPath)
    end
    if not renamed then
        os.remove(tmpPath)
        return false
    end

    if command and message ~= "Authentication failed" then
        pcall(Rcon._appendConsoleHistory, command, status, message, adminUser)
    end
    return true
end

function Rcon._appendConsoleHistory(command, status, message, adminUser)
    if not Rcon._gameDir then return end

    local histMsg = message or ""
    if #histMsg > 500 then
        histMsg = histMsg:sub(1, 500) .. "..."
    end

    table.insert(Rcon._historyBuffer, {
        timestamp = os.time(),
        command = command,
        status = status,
        message = histMsg,
        admin = adminUser or "unknown"
    })

    -- Flush immediately if buffer is full
    if #Rcon._historyBuffer >= Rcon._historyFlushSize then
        pcall(Rcon._flushHistoryBuffer)
    end
end

function Rcon._flushHistoryBuffer()
    if #Rcon._historyBuffer == 0 then return end
    if not Rcon._gameDir then return end

    local historyPath = Rcon._gameDir .. "windrose_plus_data\\console_history.json"
    local history = {}

    local file = io.open(historyPath, "r")
    if file then
        local content = file:read("*a")
        file:close()
        if content and content ~= "" then
            local ok, data = pcall(json.decode, content)
            if ok and type(data) == "table" then
                history = data
            end
        end
    end

    -- Append all buffered entries
    local pending = Rcon._historyBuffer
    for _, entry in ipairs(pending) do
        table.insert(history, entry)
    end

    while #history > Rcon._consoleHistoryMax do
        table.remove(history, 1)
    end

    local encoded = json.encode(history)
    local tmpPath = historyPath .. ".tmp"
    local written = false
    local outFile = io.open(tmpPath, "w")
    if outFile then
        outFile:write(encoded)
        outFile:close()
        local ok = os.rename(tmpPath, historyPath)
        if not ok then
            os.remove(tmpPath)
            local direct = io.open(historyPath, "w")
            if direct then direct:write(encoded); direct:close(); written = true end
        else
            written = true
        end
    else
        local direct = io.open(historyPath, "w")
        if direct then direct:write(encoded); direct:close(); written = true end
    end

    -- Only clear buffer after successful write
    if written then
        Rcon._historyBuffer = {}
        Rcon._lastHistoryFlush = os.time()
    end
end

function Rcon.registerTickCallback(fn)
    table.insert(Rcon._tickCallbacks, fn)
end

return Rcon
