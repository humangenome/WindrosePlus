# Windrose+ web dashboard and REST API server (PowerShell)

param(
    [string]$GameDir = "",
    [int]$Port = 0
)

$Version = "1.0.0"

# Find game directory
function Find-GameDir {
    $candidates = @()
    if ($GameDir) { $candidates += $GameDir }
    $candidates += $PWD.Path
    $candidates += Split-Path -Parent $PSScriptRoot

    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath (Join-Path $path "windrose_plus.json"))) {
            return (Resolve-Path $path).Path
        }
    }
    return $null
}

$gameDir = Find-GameDir
if (-not $gameDir) {
    Write-Error "Cannot find windrose_plus.json. Run from the game server directory."
    exit 1
}

# Load config
$config = Get-Content (Join-Path $gameDir "windrose_plus.json") -Raw | ConvertFrom-Json

# Find data directory
$dataDir = Join-Path $gameDir "windrose_plus_data"
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

# Find web directory
$webDir = Join-Path $PSScriptRoot "web"

# Resolve port
if ($Port -eq 0) {
    $Port = if ($config.server.http_port) { [int]$config.server.http_port } else { 8780 }
}

$rconPassword = if ($config.rcon.password) { $config.rcon.password } else { "" }

# Session management — HMAC-signed tokens
$sessionSecret = [System.Guid]::NewGuid().ToString()

function New-SessionToken {
    $timestamp = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $payload = "wp_session:$timestamp"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($sessionSecret)
    $hash = [System.BitConverter]::ToString($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload))).Replace("-","").ToLower()
    return "$payload`:$hash"
}

function Test-SessionToken($token) {
    if (-not $token) { return $false }
    $parts = $token -split ":"
    if ($parts.Count -ne 3) { return $false }
    $payload = "$($parts[0]):$($parts[1])"
    $providedHash = $parts[2]
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($sessionSecret)
    $expectedHash = [System.BitConverter]::ToString($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload))).Replace("-","").ToLower()
    if ($providedHash -ne $expectedHash) { return $false }
    # Check expiry (24 hours)
    $timestamp = [long]$parts[1]
    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return ($now - $timestamp) -lt 86400
}

function Get-SessionFromCookies($request) {
    $cookieHeader = $request.Headers["Cookie"]
    if (-not $cookieHeader) { return $null }
    foreach ($cookie in $cookieHeader -split ";") {
        $cookie = $cookie.Trim()
        if ($cookie.StartsWith("wp_session=")) {
            return $cookie.Substring(11)
        }
    }
    return $null
}

# Login page HTML
$loginPageHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>WindrosePlus - Login</title>
<style>
body { background: #1a1410; color: #ede0cc; font-family: 'Segoe UI', sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; }
.login-box { background: rgba(30, 22, 16, 0.9); border: 1px solid rgba(180, 140, 80, 0.3); border-radius: 8px; padding: 40px; max-width: 400px; width: 90%; text-align: center; }
h1 { color: #d4a04a; font-size: 24px; margin: 0 0 8px; }
p { color: #8f775d; font-size: 14px; margin: 0 0 24px; }
input[type=password] { width: 100%; padding: 12px; background: rgba(15, 10, 8, 0.9); border: 1px solid rgba(180, 140, 80, 0.3); color: #ede0cc; border-radius: 4px; font-size: 16px; box-sizing: border-box; }
input[type=password]:focus { outline: none; border-color: #d4a04a; }
button { width: 100%; padding: 12px; background: #d4a04a; color: #1a1410; border: none; border-radius: 4px; font-size: 16px; font-weight: 600; cursor: pointer; margin-top: 16px; }
button:hover { background: #e0b060; }
.error { color: #d37d66; font-size: 13px; margin-top: 12px; display: none; }
</style>
</head>
<body>
<div class="login-box">
<h1>WindrosePlus</h1>
<p>Enter RCON password to access the dashboard</p>
<form method="POST" action="/login" data-form-type="other" autocomplete="off">
<input type="password" name="password" placeholder="RCON Password" autofocus required autocomplete="off" data-1p-ignore data-lpignore="true" data-form-type="other">
<button type="submit">Enter</button>
</form>
ERRORPLACEHOLDER
</div>
</body>
</html>
"@

Write-Host "WindrosePlus Server v$Version (PowerShell)"
Write-Host "Game directory: $gameDir"
Write-Host "Data directory: $dataDir"
Write-Host ""
Write-Host "Dashboard:  http://localhost:$Port/"
Write-Host "API:        http://localhost:$Port/api/status"
Write-Host ""

# Start HTTP listener
$listener = New-Object System.Net.HttpListener
try {
    $listener.Prefixes.Add("http://+:$Port/")
    $listener.Start()
    Write-Host "Listening on 0.0.0.0:$Port"
} catch {
    Write-Host "Cannot bind to all interfaces (needs admin), trying localhost only..."
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    Write-Host "Listening on localhost:$Port (localhost only)"
}

# Background tile generation watcher
$tileGenTimer = New-Object System.Timers.Timer
$tileGenTimer.Interval = 5000
$tileGenTimer.AutoReset = $true
$tileGenTrigger = Join-Path $dataDir "generate_tiles_trigger"
$tileGenScript = Join-Path $gameDir "windrose_plus\tools\generateTiles.ps1"
if (-not (Test-Path -LiteralPath $tileGenScript)) { $tileGenScript = Join-Path $gameDir "tools\generateTiles.ps1" }
Register-ObjectEvent $tileGenTimer Elapsed -Action {
    if (Test-Path -LiteralPath $tileGenTrigger) {
        Remove-Item $tileGenTrigger -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $tileGenScript) {
            Write-Host "Generating map tiles..."
            try {
                & $tileGenScript -GameDir $gameDir
                Write-Host "Map tiles generated."
            } catch {
                Write-Host "Tile generation failed: $_"
            }
        }
    }
} | Out-Null
$tileGenTimer.Start()

function Send-Json($context, $data, $statusCode = 200) {
    $json = if ($null -eq $data) { '{}' } else { $data | ConvertTo-Json -Depth 10 -Compress }
    if ([string]::IsNullOrEmpty($json)) { $json = '{}' }
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $context.Response.StatusCode = $statusCode
    $context.Response.ContentType = "application/json"
    $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $context.Response.ContentLength64 = $buffer.Length
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.Close()
}

function Send-Html($context, $html, $statusCode = 200) {
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
    $context.Response.StatusCode = $statusCode
    $context.Response.ContentType = "text/html; charset=utf-8"
    $context.Response.ContentLength64 = $buffer.Length
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.Close()
}

function Send-Redirect($context, $location) {
    $context.Response.StatusCode = 302
    $context.Response.RedirectLocation = $location
    $context.Response.Close()
}

function Send-File($context, $filePath) {
    if (-not (Test-Path -LiteralPath $filePath)) {
        $context.Response.StatusCode = 404
        $context.Response.Close()
        return
    }
    $content = [System.IO.File]::ReadAllBytes($filePath)
    $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
    $mimeTypes = @{
        ".html" = "text/html"; ".css" = "text/css"; ".js" = "application/javascript"
        ".json" = "application/json"; ".png" = "image/png"; ".jpg" = "image/jpeg"
        ".svg" = "image/svg+xml"; ".ico" = "image/x-icon"
    }
    $mime = if ($mimeTypes[$ext]) { $mimeTypes[$ext] } else { "application/octet-stream" }
    $context.Response.ContentType = $mime
    $context.Response.ContentLength64 = $content.Length
    $context.Response.OutputStream.Write($content, 0, $content.Length)
    $context.Response.Close()
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $path = $context.Request.Url.AbsolutePath.TrimEnd("/")
        $method = $context.Request.HttpMethod

        try {
            if ($method -eq "OPTIONS") {
                $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
                $context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                $context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, X-RCON-Password")
                $context.Response.StatusCode = 200
                $context.Response.Close()
                continue
            }

            # Login page — no auth required
            if ($path -eq "/login") {
                if ($method -eq "POST") {
                    $reader = New-Object System.IO.StreamReader($context.Request.InputStream)
                    $body = $reader.ReadToEnd()
                    $formPassword = ""
                    foreach ($pair in $body -split "&") {
                        $kv = $pair -split "=", 2
                        if ($kv[0] -eq "password") {
                            $formPassword = [System.Uri]::UnescapeDataString($kv[1].Replace("+", " "))
                        }
                    }
                    if (-not $rconPassword) {
                        $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Set a password in windrose_plus.json to access the dashboard</div>')
                        Send-Html $context $errorHtml
                    } elseif ($rconPassword -eq "changeme") {
                        $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Change the default password in windrose_plus.json</div>')
                        Send-Html $context $errorHtml
                    } elseif ($formPassword -eq $rconPassword) {
                        $token = New-SessionToken
                        $context.Response.Headers.Add("Set-Cookie", "wp_session=$token; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax")
                        Send-Redirect $context "/"
                    } else {
                        $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Invalid password</div>')
                        Send-Html $context $errorHtml
                    }
                } else {
                    if (-not $rconPassword) {
                        $errorMsg = '<div class="error" style="display:block">Set a password in windrose_plus.json to access the dashboard</div>'
                    } elseif ($rconPassword -eq "changeme") {
                        $errorMsg = '<div class="error" style="display:block">Change the default password in windrose_plus.json</div>'
                    } else {
                        $errorMsg = ""
                    }
                    $html = $loginPageHtml.Replace("ERRORPLACEHOLDER", $errorMsg)
                    Send-Html $context $html
                }
                continue
            }

            # API health endpoint — no auth (used for monitoring)
            if ($path -eq "/api/health") {
                Send-Json $context @{ status = "ok"; version = $Version; timestamp = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
                continue
            }

            # All other routes require authentication
            if (-not $rconPassword -or $rconPassword -eq "changeme") {
                # No password configured or still default — block everything
                if ($path.StartsWith("/api/")) {
                    Send-Json $context @{ error = "No password configured. Set a password in windrose_plus.json to access the dashboard." } 403
                } else {
                    Send-Redirect $context "/login"
                }
                continue
            }
            if (-not (Test-SessionToken (Get-SessionFromCookies $context.Request))) {
                # API calls get 401, browser requests get redirect
                if ($path.StartsWith("/api/")) {
                    Send-Json $context @{ error = "Authentication required" } 401
                } else {
                    Send-Redirect $context "/login"
                }
                continue
            }

            switch ($path) {
                "/api/status" {
                    $statusFile = Join-Path $dataDir "server_status.json"
                    if (Test-Path -LiteralPath $statusFile) {
                        $data = Get-Content $statusFile -Raw | ConvertFrom-Json
                        Send-Json $context $data
                    } else {
                        Send-Json $context @{ error = "No status data" }
                    }
                }
                "/api/livemap" {
                    $mapFile = Join-Path $dataDir "livemap_data.json"
                    if (Test-Path -LiteralPath $mapFile) {
                        $data = Get-Content $mapFile -Raw | ConvertFrom-Json
                        Send-Json $context $data
                    } else {
                        Send-Json $context @{ error = "No livemap data" }
                    }
                }
                "/api/config" {
                    $safeConfig = $config.PSObject.Copy()
                    if ($safeConfig.rcon) { $safeConfig.rcon.password = "***" }
                    Send-Json $context $safeConfig
                }
                "/api/commands" {
                    $cmds = @(
                        @{name="wp.help"; usage="wp.help [command|all]"; description="List all commands or get help for a specific command"; category="server"},
                        @{name="wp.status"; usage="wp.status"; description="Show server status and multipliers"; category="server"},
                        @{name="wp.config"; usage="wp.config"; description="Show current config values"; category="server"},
                        @{name="wp.multipliers"; usage="wp.multipliers"; description="Show all gameplay multipliers"; category="server"},
                        @{name="wp.uptime"; usage="wp.uptime"; description="Show server uptime"; category="server"},
                        @{name="wp.reload"; usage="wp.reload"; description="Reload config from disk"; category="server"},
                        @{name="wp.version"; usage="wp.version"; description="Show version"; category="server"},
                        @{name="wp.players"; usage="wp.players"; description="List online players with positions"; category="players"},
                        @{name="wp.playerinfo"; usage="wp.playerinfo [player]"; description="Consolidated player info"; category="players"},
                        @{name="wp.playtime"; usage="wp.playtime [player]"; description="Player session time"; category="players"},
                        @{name="wp.health"; usage="wp.health [player]"; description="Read player health"; category="players"},
                        @{name="wp.pos"; usage="wp.pos [player]"; description="Get player positions"; category="players"},
                        @{name="wp.stamina"; usage="wp.stamina [player]"; description="Read stamina/hunger/thirst"; category="players"},
                        @{name="wp.speed"; usage="wp.speed [player] <mult>"; description="Set movement speed"; category="admin"},
                        @{name="wp.time"; usage="wp.time"; description="Read current time of day"; category="world"},
                        @{name="wp.creatures"; usage="wp.creatures"; description="Count spawned creatures by type"; category="world"},
                        @{name="wp.entities"; usage="wp.entities"; description="Count entities by type"; category="world"},
                        @{name="wp.weather"; usage="wp.weather"; description="Read weather values"; category="world"},
                        @{name="wp.perf"; usage="wp.perf"; description="Show server performance metrics"; category="diagnostics"},
                        @{name="wp.memory"; usage="wp.memory"; description="Detailed memory usage"; category="diagnostics"},
                        @{name="wp.connections"; usage="wp.connections"; description="Network connection info"; category="diagnostics"},
                        @{name="wp.mapgen"; usage="wp.mapgen"; description="Generate heightmap for live map"; category="server"},
                        @{name="wp.mapexport"; usage="wp.mapexport"; description="Trigger terrain heightmap export"; category="server"}
                    )
                    Send-Json $context @{ commands = $cmds }
                }
                "/api/mapinfo" {
                    $mapCoordsFile = Join-Path $dataDir "map_coords.json"
                    if (Test-Path -LiteralPath $mapCoordsFile) {
                        $data = Get-Content $mapCoordsFile -Raw | ConvertFrom-Json
                        Send-Json $context $data
                    } else {
                        Send-Json $context @{ error = "Map not ready yet. Join the server once to auto-generate the map." }
                    }
                }
                "/api/rcon/log" {
                    $auditFile = Join-Path $dataDir "rcon_audit.json"
                    if (Test-Path -LiteralPath $auditFile) {
                        try {
                            $raw = Get-Content $auditFile -Raw
                            if ($raw) {
                                $buffer = [System.Text.Encoding]::UTF8.GetBytes($raw)
                                $context.Response.StatusCode = 200
                                $context.Response.ContentType = "application/json"
                                $context.Response.ContentLength64 = $buffer.Length
                                $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
                                $context.Response.Close()
                            } else {
                                Send-Json $context @{ entries = @() }
                            }
                        } catch {
                            Send-Json $context @{ entries = @() }
                        }
                    } else {
                        Send-Json $context @{ entries = @() }
                    }
                }
                "/api/rcon" {
                    if ($method -ne "POST") {
                        Send-Json $context @{ error = "POST required" } 405
                        continue
                    }
                    $reader = New-Object System.IO.StreamReader($context.Request.InputStream)
                    $body = $reader.ReadToEnd() | ConvertFrom-Json

                    if (-not $rconPassword -or $rconPassword -eq "changeme") {
                        Send-Json $context @{ error = "RCON not configured" } 403
                        continue
                    }

                    # Session-authenticated users don't need password in API body
                    # (they already proved identity at login)

                    # Write command file
                    $cmdId = "ps_" + [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + "_" + (Get-Random -Maximum 999999)
                    $spoolDir = Join-Path $dataDir "rcon"
                    if (-not (Test-Path -LiteralPath $spoolDir)) { New-Item -ItemType Directory -Path $spoolDir -Force | Out-Null }
                    $cmdData = @{ id = $cmdId; command = $body.command; args = @($body.args); password = $rconPassword; admin_user = "Dashboard" }
                    $cmdData | ConvertTo-Json | Set-Content (Join-Path $spoolDir "cmd_$cmdId.json")
                    # Write index file so Lua mod can find the command without dir /b
                    [System.IO.File]::AppendAllText((Join-Path $spoolDir "pending_commands.txt"), "cmd_$cmdId.json`r`n")

                    # Poll for response
                    $resPath = Join-Path $spoolDir "res_$cmdId.json"
                    $deadline = (Get-Date).AddSeconds(25)
                    $result = $null
                    while ((Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 100
                        if (Test-Path -LiteralPath $resPath) {
                            $result = Get-Content $resPath -Raw | ConvertFrom-Json
                            Remove-Item $resPath -ErrorAction SilentlyContinue
                            break
                        }
                    }
                    if (-not $result) {
                        Remove-Item (Join-Path $spoolDir "cmd_$cmdId.json") -ErrorAction SilentlyContinue
                        $result = @{ id = $cmdId; status = "error"; message = "Command timed out (25s)" }
                    }
                    Send-Json $context $result
                }
                default {
                    # Static file serving
                    $filePath = $path
                    if ($filePath -eq "" -or $filePath -eq "/") { $filePath = "/index.html" }
                    if ($filePath -eq "/livemap") { $filePath = "/livemap/index.html" }

                    # Serve map tiles from data directory
                    if ($filePath -match "^/livemap/tiles/(\d+)/(\d+)-(\d+)\.png$") {
                        $tilePath = Join-Path $dataDir "map_tiles\$($Matches[1])\$($Matches[2])-$($Matches[3]).png"
                        Send-File $context $tilePath
                        continue
                    }

                    $safePath = $filePath.TrimStart("/").Replace("/", "\")
                    $fullPath = Join-Path $webDir $safePath

                    if ($safePath -match "\.\." -or [System.IO.Path]::IsPathRooted($safePath)) {
                        $context.Response.StatusCode = 403
                        $context.Response.Close()
                        continue
                    }

                    Send-File $context $fullPath
                }
            }
        } catch {
            try {
                $context.Response.StatusCode = 500
                $context.Response.Close()
            } catch {}
            Write-Host "Error: $_"
        }
    }
} finally {
    $listener.Stop()
}
