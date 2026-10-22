# Windrose+ web dashboard and REST API server (PowerShell)

param(
    [string]$GameDir = "",
    [int]$Port = 0,
    [string]$BindIp = ""
)

# $Version is rewritten from the git tag by .github/workflows/release.yml at
# release time. The literal here is the development default.
$Version = "1.0.16"

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

# Load config. Retry on transient parse failures — external writers may
# overwrite this file non-atomically and catch us mid-write during startup.
$configPath = Join-Path $gameDir "windrose_plus.json"
$config = $null
for ($i = 0; $i -lt 5; $i++) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        break
    } catch {
        if ($i -eq 4) {
            Write-Error "Failed to parse $configPath after 5 retries: $($_.Exception.Message)"
            exit 1
        }
        Start-Sleep -Milliseconds 100
    }
}

# Find data directory
$dataDir = Join-Path $gameDir "windrose_plus_data"
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
# The activity log lives in windrose_plus_data\logs. Lua cannot create folders
# safely, so make it here for hosts that never ran install.ps1; the mod uses it
# from its next start.
$activityLogDir = Join-Path $dataDir "logs"
if (-not (Test-Path -LiteralPath $activityLogDir)) {
    try { New-Item -ItemType Directory -Path $activityLogDir -Force | Out-Null } catch {}
}

# Find web directory
$webDir = Join-Path $PSScriptRoot "web"

# Release metadata for other tools, reported by /api/health: the route list's version
# (server\routes.json) and the PAK builder version (tools\PAK_BUILDER_VERSION).
$routesVersion = $null
try { $routesVersion = [int]((Get-Content -LiteralPath (Join-Path $PSScriptRoot "routes.json") -Raw -ErrorAction Stop | ConvertFrom-Json).routes_version) } catch {}
$pakBuilderVersion = $null
try { $pakBuilderVersion = [int]((Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\tools\PAK_BUILDER_VERSION") -Raw -ErrorAction Stop).Trim()) } catch {}

# Resolve port
if ($Port -eq 0) {
    $Port = if ($config.server.http_port) { [int]$config.server.http_port } else { 8780 }
}

if (-not $BindIp -and $config.server -and $config.server.bind_ip) {
    $BindIp = [string]$config.server.bind_ip
}
$BindIp = $BindIp.Trim()

$listenHost = "+"
if ($BindIp -and $BindIp -ne "0.0.0.0" -and $BindIp -ne "*" -and $BindIp -ne "+") {
    $listenHost = $BindIp
}
$displayListenHost = if ($listenHost -eq "+") { "0.0.0.0" } else { $listenHost }
$dashboardHost = if ($listenHost -eq "+") { "localhost" } else { $listenHost }

# Load the INI parser used by /api/pak-status. Failure is non-fatal; the endpoint
# degrades to a "parser unavailable" response instead of crashing the dashboard.
$script:IniParserLoaded = $false
$script:IniParserLoadError = $null
$iniParserPath = Join-Path $PSScriptRoot "..\tools\lib\IniConfigParser.ps1"
if (Test-Path -LiteralPath $iniParserPath) {
    try {
        . $iniParserPath
        $script:IniParserLoaded = $true
    } catch {
        $script:IniParserLoadError = $_.Exception.Message
        Write-Host "WARN: IniConfigParser.ps1 failed to load: $($_.Exception.Message). /api/pak-status CT detection degraded."
    }
} else {
    $script:IniParserLoadError = "File not found: $iniParserPath"
    Write-Host "WARN: IniConfigParser.ps1 not found at $iniParserPath. /api/pak-status CT detection degraded."
}

# Re-read the RCON password on every auth attempt instead of caching it at startup.
# External writers (e.g. an orchestration panel) can overwrite windrose_plus.json
# mid-session, and non-atomic writes can produce transient parse failures.
# Retry up to 3 times; if all fail, return $null so callers can surface a retry hint.
function Get-CurrentRconPassword {
    $jsonPath = Join-Path $gameDir "windrose_plus.json"
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $cfg = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
            if ($cfg.rcon -and $cfg.rcon.password) { return [string]$cfg.rcon.password }
            return ""
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    Write-Host "WARN: Unable to parse windrose_plus.json after 3 retries"
    return $null
}

# Re-read the full config from disk so the dashboard /api/config view reflects
# live edits (RCON password, multipliers, public-map settings) without needing
# a dashboard restart. Returns $null on parse failure so callers can hint a retry.
function Get-CurrentConfig {
    $jsonPath = Join-Path $gameDir "windrose_plus.json"
    for ($i = 0; $i -lt 3; $i++) {
        try {
            return (Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json)
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    Write-Host "WARN: Unable to parse windrose_plus.json after 3 retries (Get-CurrentConfig)"
    return $null
}

function Get-ConfigPropertyValue {
    param($Object, [string]$Name, $Default)

    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Get-ConfigBool {
    param($Object, [string]$Name, [bool]$Default = $false)

    $raw = Get-ConfigPropertyValue $Object $Name $null
    if ($null -eq $raw) { return $Default }
    if ($raw -is [bool]) { return $raw }
    $s = ([string]$raw).Trim().ToLowerInvariant()
    if ($s -in @("1", "true", "yes", "on")) { return $true }
    if ($s -in @("0", "false", "no", "off")) { return $false }
    return $Default
}

# Re-read public map settings on every request so hosts can enable, disable, or
# rotate the optional share token without restarting the dashboard process.
function Get-CurrentPublicMapConfig {
    $jsonPath = Join-Path $gameDir "windrose_plus.json"
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $cfg = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
            $public = $null
            if ($cfg.livemap -and $cfg.livemap.public) { $public = $cfg.livemap.public }
            $enabled = $false
            $token = ""
            if ($public) {
                $enabled = ($public.enabled -eq $true)
                if ($public.token) { $token = [string]$public.token }
            }
            return [PSCustomObject]@{
                Enabled = $enabled
                Token = $token
            }
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
    Write-Host "WARN: Unable to parse public map settings after 3 retries"
    return $null
}

function Test-PublicMapAccess($request) {
    $publicMap = Get-CurrentPublicMapConfig
    if ($null -eq $publicMap) {
        return @{ Allowed = $false; StatusCode = 503; Error = "Config temporarily unavailable, retry in a moment" }
    }
    if (-not $publicMap.Enabled) {
        return @{ Allowed = $false; StatusCode = 404; Error = "Public map is not enabled" }
    }
    if (-not $publicMap.Token) {
        return @{ Allowed = $true; StatusCode = 200; Error = "" }
    }

    $provided = $request.QueryString["token"]
    if (-not $provided) { $provided = $request.Headers["X-WindrosePlus-Map-Token"] }
    if ($provided -eq $publicMap.Token) {
        return @{ Allowed = $true; StatusCode = 200; Error = "" }
    }
    return @{ Allowed = $false; StatusCode = 401; Error = "Invalid public map token" }
}

function ConvertTo-PublicLiveMapData($data) {
    $players = @()
    if ($data.players) {
        foreach ($p in @($data.players)) {
            $item = [ordered]@{}
            if ($p.name) { $item["name"] = [string]$p.name }
            if ($null -ne $p.x) { $item["x"] = [double]$p.x }
            if ($null -ne $p.y) { $item["y"] = [double]$p.y }
            if ($null -ne $p.z) { $item["z"] = [double]$p.z }
            $players += [PSCustomObject]$item
        }
    }

    $mobs = @()
    if ($data.mobs) {
        foreach ($m in @($data.mobs)) {
            $item = [ordered]@{}
            if ($m.name) { $item["name"] = [string]$m.name }
            if ($null -ne $m.x) { $item["x"] = [double]$m.x }
            if ($null -ne $m.y) { $item["y"] = [double]$m.y }
            if ($null -ne $m.z) { $item["z"] = [double]$m.z }
            $mobs += [PSCustomObject]$item
        }
    }

    $nodes = @()
    if ($data.nodes) {
        foreach ($n in @($data.nodes)) {
            $item = [ordered]@{}
            if ($n.name) { $item["name"] = [string]$n.name }
            if ($null -ne $n.x) { $item["x"] = [double]$n.x }
            if ($null -ne $n.y) { $item["y"] = [double]$n.y }
            if ($null -ne $n.z) { $item["z"] = [double]$n.z }
            $nodes += [PSCustomObject]$item
        }
    }

    $publicData = [ordered]@{
        players = $players
        mobs = $mobs
        nodes = $nodes
        player_count = $players.Count
        mob_count = $mobs.Count
        node_count = $nodes.Count
        timestamp = $data.timestamp
    }
    if ($data.degraded) {
        $publicData["degraded"] = $true
        $publicData["degraded_reason"] = $data.degraded_reason
        $publicData["cache_age_sec"] = $data.cache_age_sec
    }
    return [PSCustomObject]$publicData
}

function Send-PoiScanData($context) {
    $poiFile = Join-Path $dataDir "pois.json"
    if (Test-Path -LiteralPath $poiFile) {
        try {
            $data = Get-Content $poiFile -Raw | ConvertFrom-Json
            Send-Json $context $data
        } catch {
            Send-Json $context @{ error = "POIScan data is not readable" } 503
        }
    } else {
        Send-Json $context @{ error = "No POIScan data" } 503
    }
}

function Get-RuntimeOverlayData {
    $overlayFile = Join-Path $dataDir "runtime_overlay.json"
    if (-not (Test-Path -LiteralPath $overlayFile)) {
        return @{ Ok = $false; StatusCode = 404; Error = "No runtime overlay data" }
    }
    try {
        $data = Get-Content -LiteralPath $overlayFile -Raw | ConvertFrom-Json
        if ($data.PSObject.Properties.Name -contains "source_save_path") {
            $data.PSObject.Properties.Remove("source_save_path")
        }
        return @{ Ok = $true; StatusCode = 200; Data = $data }
    } catch {
        return @{ Ok = $false; StatusCode = 500; Error = "Runtime overlay data is not valid JSON" }
    }
}

# Session management — HMAC-signed tokens.
# The secret is persisted to windrose_plus_data\dashboard_session.key so a
# dashboard restart doesn't log everyone out. Tokens are signed with a key made
# from that secret and the current RCON password, so changing the password ends
# every session, while the cookie itself carries nothing derived from the
# password (up to v1.3.24 it carried 4 bytes of an unsalted password hash).
function Get-OrCreateSessionSecret {
    $keyPath = Join-Path $dataDir "dashboard_session.key"
    if (Test-Path -LiteralPath $keyPath) {
        try {
            $existing = ([System.IO.File]::ReadAllText($keyPath)).Trim()
            if ($existing.Length -ge 64) { return $existing }
        } catch {
            Write-Host "WARN: failed to read dashboard_session.key: $($_.Exception.Message)"
        }
    }
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $secret = [System.BitConverter]::ToString($bytes).Replace("-","").ToLower()
    try {
        if (-not (Test-Path -LiteralPath $dataDir)) {
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($keyPath, $secret)
    } catch {
        Write-Host "WARN: failed to write dashboard_session.key: $($_.Exception.Message)"
    }
    return $secret
}
$sessionSecret = Get-OrCreateSessionSecret

function Get-HmacHex([byte[]]$Key, [string]$Text) {
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try {
        return [System.BitConverter]::ToString($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace("-","").ToLower()
    } finally {
        $hmac.Dispose()
    }
}

# The key that signs session tokens: HMAC(secret, password). $null when no
# password is set, so no token is ever valid then.
function Get-SessionSigningKey {
    $pw = Get-CurrentRconPassword
    if (-not $pw) { return $null }
    $hex = Get-HmacHex ([System.Text.Encoding]::UTF8.GetBytes($sessionSecret)) ("wp-session-key:" + [string]$pw)
    $key = New-Object byte[] 32
    for ($i = 0; $i -lt 32; $i++) { $key[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
    return $key
}

# Token: wp2:<random id>:<unix time>:<signature>. 24 hours.
function New-SessionToken {
    $key = Get-SessionSigningKey
    if (-not $key) { return $null }
    $idBytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($idBytes) } finally { $rng.Dispose() }
    $id = [System.BitConverter]::ToString($idBytes).Replace("-","").ToLower()
    $timestamp = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $payload = "wp2:${id}:${timestamp}"
    return "${payload}:$(Get-HmacHex $key $payload)"
}

function Test-SessionToken($token, [byte[]]$Key = $null) {
    if (-not $token) { return $false }
    $parts = ([string]$token) -split ":"
    if ($parts.Count -ne 4) { return $false }
    if ($parts[0] -cne "wp2" -or $parts[1] -cnotmatch '^[0-9a-f]{32}$' -or $parts[2] -notmatch '^\d{1,12}$' -or $parts[3] -cnotmatch '^[0-9a-f]{64}$') { return $false }
    if (-not $Key) { $Key = Get-SessionSigningKey }
    if (-not $Key) { return $false }
    $payload = "$($parts[0]):$($parts[1]):$($parts[2])"
    if (-not (Test-SecretEqual $parts[3] (Get-HmacHex $Key $payload))) { return $false }
    $timestamp = [long]$parts[2]
    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return (($now - $timestamp) -lt 86400 -and ($timestamp - $now) -lt 300)
}

# Browsers send a host's cookies to every port on it, so the cookie is named
# after this dashboard's port: logging in to a second dashboard on the same
# machine no longer replaces the first one's cookie. A cookie named plain
# wp_session (the name up to v1.3.24) is still read, for scripts that copy it.
$sessionCookieName = "wp_session_$Port"

function Get-SessionCookieValues($request) {
    $own = New-Object System.Collections.Generic.List[string]
    $legacy = New-Object System.Collections.Generic.List[string]
    $cookieHeader = $request.Headers["Cookie"]
    if (-not $cookieHeader) { return @() }
    foreach ($cookie in $cookieHeader -split ";") {
        $cookie = $cookie.Trim()
        $eq = $cookie.IndexOf("=")
        if ($eq -lt 1) { continue }
        $name = $cookie.Substring(0, $eq)
        if ($name -ceq $sessionCookieName) { $own.Add($cookie.Substring($eq + 1)) }
        elseif ($name -ceq "wp_session") { $legacy.Add($cookie.Substring($eq + 1)) }
        if (($own.Count + $legacy.Count) -ge 8) { break }
    }
    return @($own) + @($legacy)
}

function Test-SessionCookie($request) {
    $values = @(Get-SessionCookieValues $request)
    if ($values.Count -eq 0) { return $false }
    $key = Get-SessionSigningKey
    if (-not $key) { return $false }
    foreach ($value in $values) {
        if (Test-SessionToken $value $key) { return $true }
    }
    return $false
}

function Get-SessionCookieHeader([string]$Value, [int]$MaxAge) {
    return "$sessionCookieName=$Value; Path=/; Max-Age=$MaxAge; HttpOnly; SameSite=Lax"
}

# A cross-site HTML form or a no-cors fetch can POST with the dashboard
# cookie attached, but only with one of these content types (or none).
# Requests logged in by cookie must use another type (the dashboard sends
# application/json and application/zip), which a browser only sends
# cross-origin after a CORS check this server never passes for cookies.
function Test-CrossSiteSendableContentType([string]$ContentType) {
    $type = ([string]$ContentType).Split(";")[0].Trim().ToLowerInvariant()
    return ($type -eq "" -or $type -eq "text/plain" -or $type -eq "application/x-www-form-urlencoded" -or $type -eq "multipart/form-data")
}

# Reads a request body as UTF-8 text, at most MaxBytes, within DeadlineMs in
# total. The dashboard answers one request at a time, so an unbounded or slow
# body sent before any login used to hold every other client. Returns
# @{ Ok; Text } on success, @{ Ok = $false; Status = 413 } when too large, and
# @{ Ok = $false; Status = 0 } when the client was too slow (the connection is
# dropped, nothing more can be sent on it).
function Read-RequestBodyText($context, [int]$MaxBytes, [int]$DeadlineMs = 10000) {
    $request = $context.Request
    if ($request.ContentLength64 -gt $MaxBytes) { return @{ Ok = $false; Status = 413 } }
    if (-not $request.HasEntityBody) { return @{ Ok = $true; Text = "" } }
    $stream = $request.InputStream
    $ms = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    $deadline = [DateTime]::UtcNow.AddMilliseconds($DeadlineMs)
    try {
        while ($true) {
            $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0) { throw "slow" }
            $task = $stream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $task.Wait($left)) { throw "slow" }
            $read = $task.Result
            if ($read -le 0) { break }
            if (($ms.Length + $read) -gt $MaxBytes) { return @{ Ok = $false; Status = 413 } }
            $ms.Write($buffer, 0, $read)
        }
    } catch {
        try { $context.Response.Abort() } catch {}
        return @{ Ok = $false; Status = 0 }
    }
    $bytes = $ms.ToArray()
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    return @{ Ok = $true; Text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start) }
}

# Compares two secrets without stopping at the first different character.
function Test-SecretEqual([string]$Provided, [string]$Expected) {
    if ($null -eq $Provided -or $null -eq $Expected) { return $false }
    $a = [System.Text.Encoding]::UTF8.GetBytes($Provided)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    $diff = $a.Length -bxor $b.Length
    for ($i = 0; $i -lt $b.Length; $i++) {
        $ai = if ($i -lt $a.Length) { $a[$i] } else { 0 }
        $diff = $diff -bor ($ai -bxor $b[$i])
    }
    return ($diff -eq 0)
}

# Requests from this machine are NOT trusted by default. Up to v1.3.17 every
# loopback request skipped the login, which let anyone in through a reverse
# proxy on the same host (nginx, Caddy, IIS, AMP) and let any web page open in a
# browser on the server send RCON commands. Set server.trust_loopback = true (or
# WINDROSEPLUS_TRUST_LOOPBACK=1) only when a same-host proxy does its own login.
# Scripts on the same host can send the password in an X-RCON-Password header.
function Get-TrustLoopback {
    $envValue = "$env:WINDROSEPLUS_TRUST_LOOPBACK".Trim()
    if ($envValue) { return ($envValue -eq "1" -or $envValue -ieq "true") }
    $cfg = Get-CurrentConfig
    if ($null -eq $cfg -or $null -eq $cfg.server) { return $false }
    return (Get-ConfigBool $cfg.server "trust_loopback" $false)
}

# server.stop_with_game (or WINDROSEPLUS_STOP_WITH_GAME=1): for a host or panel that
# starts the dashboard together with the game. The dashboard then exits once its
# game has not been running for 10 minutes, so a game that crashed or exited on its
# own does not leave the dashboard behind on its port. Off by default: a dashboard
# started by hand keeps running while the server is down.
function Get-StopWithGame {
    $envValue = "$env:WINDROSEPLUS_STOP_WITH_GAME".Trim()
    if ($envValue) { return ($envValue -eq "1" -or $envValue -ieq "true") }
    $cfg = Get-CurrentConfig
    if ($null -eq $cfg -or $null -eq $cfg.server) { return $false }
    return (Get-ConfigBool $cfg.server "stop_with_game" $false)
}

# Decides whether to exit. GameState is "running", "gone" or "unknown" (a
# WindroseServer process whose path cannot be read counts as unknown, never gone).
# Never exits in the first GraceMinutes after the dashboard started, or while the
# game's state is unknown. Returns @{ Exit; LastSeen }.
function Get-GameWatchDecision {
    param([datetime]$Now, [datetime]$Started, $LastSeen, [string]$GameState, [int]$GraceMinutes = 10)
    if ($GameState -ne "gone") { return @{ Exit = $false; LastSeen = $Now } }
    $since = if ($null -ne $LastSeen) { [datetime]$LastSeen } else { $Started }
    if ($since -lt $Started) { $since = $Started }
    $exit = (($Now - $Started).TotalMinutes -ge $GraceMinutes) -and (($Now - $since).TotalMinutes -ge $GraceMinutes)
    return @{ Exit = $exit; LastSeen = $LastSeen }
}

function Get-GameState {
    $procs = @(Get-Process -Name "WindroseServer*" -ErrorAction SilentlyContinue)
    $prefix = $gameDir.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
    foreach ($p in $procs) {
        $path = $null
        try { $path = $p.Path } catch {}
        if ([string]::IsNullOrEmpty($path)) { return "unknown" }
        if ($path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return "running" }
    }
    return "gone"
}

$script:GameWatchStarted = Get-Date
$script:GameWatchLastSeen = $null
$script:GameWatchNextCheck = (Get-Date).AddSeconds(60)
function Invoke-GameWatch {
    $now = Get-Date
    if ($now -lt $script:GameWatchNextCheck) { return }
    $script:GameWatchNextCheck = $now.AddSeconds(60)
    if (-not (Get-StopWithGame)) { return }
    $d = Get-GameWatchDecision -Now $now -Started $script:GameWatchStarted -LastSeen $script:GameWatchLastSeen -GameState (Get-GameState)
    $script:GameWatchLastSeen = $d.LastSeen
    if ($d.Exit) {
        Write-Host "The game has not been running from $gameDir for 10 minutes and server.stop_with_game is on; the dashboard is stopping."
        try { $listener.Stop() } catch {}
        exit 0
    }
}

function Test-LoopbackRequest($request) {
    $remoteAddr = $null
    try { $remoteAddr = $request.RemoteEndPoint.Address } catch {}
    if (-not $remoteAddr) { return $false }
    $addrStr = $remoteAddr.ToString()
    if ($remoteAddr.IsLoopback) { return $true }
    if ($addrStr -eq "::1" -or $addrStr -eq "127.0.0.1") { return $true }
    if ($addrStr.StartsWith("::ffff:127.")) { return $true }
    if ($remoteAddr.IsIPv4MappedToIPv6) {
        try { if ($remoteAddr.MapToIPv4().IsLoopback) { return $true } } catch {}
    }
    return $false
}

function Get-ClientKey($request) {
    try { return $request.RemoteEndPoint.Address.ToString() } catch { return "unknown" }
}

# Failed-password throttle: 10 wrong passwords from one address inside 5 minutes
# blocks that address for the rest of the window. The listener is single-threaded,
# so this answers 429 instead of sleeping.
$script:AuthFailures = @{}
$script:AuthFailureLimit = 10
$script:AuthFailureWindowSeconds = 300

function Get-RecentAuthFailures([string]$ClientKey) {
    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $script:AuthFailures.ContainsKey($ClientKey)) { return @() }
    $recent = @($script:AuthFailures[$ClientKey] | Where-Object { ($now - $_) -lt $script:AuthFailureWindowSeconds })
    if ($recent.Count -eq 0) { $script:AuthFailures.Remove($ClientKey) } else { $script:AuthFailures[$ClientKey] = $recent }
    return $recent
}

function Test-AuthThrottled([string]$ClientKey) {
    return ((Get-RecentAuthFailures $ClientKey).Count -ge $script:AuthFailureLimit)
}

function Add-AuthFailure([string]$ClientKey) {
    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $recent = @(Get-RecentAuthFailures $ClientKey)
    $script:AuthFailures[$ClientKey] = @($recent + $now)
    if ($script:AuthFailures.Count -gt 5000) { $script:AuthFailures.Clear() }
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
Write-Host ("Dashboard:  http://{0}:{1}/" -f $dashboardHost, $Port)
Write-Host ("API:        http://{0}:{1}/api/status" -f $dashboardHost, $Port)
Write-Host ""

# Start HTTP listener
$listener = New-Object System.Net.HttpListener
if ($listenHost -eq "+") {
    try {
        $listener.Prefixes.Add(("http://{0}:{1}/" -f $listenHost, $Port))
        $listener.Start()
        Write-Host ("Listening on {0}:{1}" -f $displayListenHost, $Port)
    } catch {
        Write-Host "Cannot bind to all interfaces (needs admin), trying localhost only..."
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add(("http://localhost:{0}/" -f $Port))
        $listener.Start()
        Write-Host ("Listening on localhost:{0} (localhost only)" -f $Port)
    }
} else {
    try {
        $listener.Prefixes.Add(("http://{0}:{1}/" -f $listenHost, $Port))
        $listener.Start()
        Write-Host ("Listening on {0}:{1}" -f $displayListenHost, $Port)
    } catch {
        Write-Error ("Cannot bind dashboard to {0}:{1}: {2}" -f $displayListenHost, $Port, $_.Exception.Message)
        exit 1
    }
}

# Windows only (not available on Linux): the HTTP stack drops a request whose
# body stops arriving for 30 seconds and stops draining an unread body after 5
# (both default to 2 minutes). Read-RequestBodyText has its own deadline too.
try {
    $listener.TimeoutManager.EntityBody = [TimeSpan]::FromSeconds(30)
    $listener.TimeoutManager.DrainEntityBody = [TimeSpan]::FromSeconds(5)
} catch {}

# Tile generation watcher. The Lua mod writes generate_tiles_trigger (it cannot
# run PowerShell itself); the request loop below calls this whenever it has
# been idle for a second and after every request. This used to be a
# System.Timers.Timer event, but PowerShell only runs event actions between
# statements, and the loop sits inside HttpListener.GetContext() while nobody
# is using the dashboard, so the tiles were only built once someone opened it.
$tileGenTrigger = Join-Path $dataDir "generate_tiles_trigger"
$tileGenStatus = Join-Path $dataDir "map_generation_status.json"
# install.ps1 puts the tools in <game>\windrose_plus\tools; hosts that unpack
# the release zip straight into ue4ss\Mods\WindrosePlus have them next to this
# script's folder instead.
$tileGenScript = $null
foreach ($candidate in @(
    (Join-Path $gameDir "windrose_plus\tools\generateTiles.ps1"),
    (Join-Path $PSScriptRoot "..\tools\generateTiles.ps1"),
    (Join-Path $gameDir "tools\generateTiles.ps1")
)) {
    if (Test-Path -LiteralPath $candidate) { $tileGenScript = [System.IO.Path]::GetFullPath($candidate); break }
}
if (-not $tileGenScript) { $tileGenScript = Join-Path $gameDir "windrose_plus\tools\generateTiles.ps1" }
function Write-TileGenStatus($data) {
    try {
        [System.IO.File]::WriteAllText($tileGenStatus, ($data | ConvertTo-Json -Depth 100 -Compress), [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Host "WARN: could not write map_generation_status.json: $($_.Exception.Message)"
    }
}

# The tile build runs as its own process at below-normal priority. Up to v1.3.24
# it ran inside the request loop, so the dashboard answered nothing until all
# tiles were written. A trigger that arrives during a build starts another one
# when the first ends.
$script:TileGen = $null
function Invoke-TileGenerationWatch {
    $job = $script:TileGen
    if ($job) {
        $exited = $true
        try { $exited = $job.Process.HasExited } catch {}
        if (-not $exited) { return }
        $code = -1
        try { $code = $job.Process.ExitCode } catch {}
        $output = ""
        try { $output = (([string]$job.Out.Result) + ([string]$job.Err.Result)).Trim() } catch {}
        if ($output.Length -gt 8000) { $output = $output.Substring($output.Length - 8000) }
        if ($code -eq 0) {
            Write-TileGenStatus @{ state = "complete"; ts = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); started_ts = $job.Started; script = $tileGenScript; output = $output }
            Write-Host "Map tiles generated."
        } else {
            $lastLine = @($output -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
            Write-TileGenStatus @{ state = "error"; ts = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); started_ts = $job.Started; script = $tileGenScript; error = "generateTiles.ps1 exited with code ${code}: $lastLine"; output = $output }
            Write-Host "Tile generation failed (exit $code)."
        }
        try { $job.Process.Dispose() } catch {}
        $script:TileGen = $null
    }
    if (-not (Test-Path -LiteralPath $tileGenTrigger)) { return }
    Remove-Item -LiteralPath $tileGenTrigger -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $tileGenScript)) {
        Write-TileGenStatus @{ state = "error"; ts = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); script = $tileGenScript; error = "generateTiles.ps1 not found" }
        return
    }
    Write-Host "Generating map tiles..."
    $started = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -GameDir "{1}"' -f $tileGenScript, $gameDir)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        $script:TileGen = @{ Process = $proc; Out = $proc.StandardOutput.ReadToEndAsync(); Err = $proc.StandardError.ReadToEndAsync(); Started = $started }
        Write-TileGenStatus @{ state = "running"; ts = $started; script = $tileGenScript }
    } catch {
        Write-TileGenStatus @{ state = "error"; ts = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); script = $tileGenScript; error = "generateTiles.ps1 could not start: $($_.Exception.Message)" }
        Write-Host "Tile generation could not start: $($_.Exception.Message)"
    }
}

# Item catalog. The Sea Chart's item list is built on this server from the
# game's own data files by tools/WindrosePlus-BuildCatalog.ps1 and kept in
# windrose_plus_data\catalog\v1; nothing from the game ships with Windrose+.
# The builder exits at once when the catalog already matches the installed game
# files, so starting it with every dashboard start only does real work after a
# game update. "catalog": { "build": false } in windrose_plus.json (or
# WINDROSEPLUS_CATALOG_BUILD=0) turns it off.
$catalogDataDir = Join-Path $dataDir "catalog\v1"
$catalogBuildLog = Join-Path $dataDir "catalog\build.log"
$script:CatalogBuildProcess = $null
$catalogBuildScript = $null
foreach ($candidate in @(
    (Join-Path $gameDir "windrose_plus\tools\WindrosePlus-BuildCatalog.ps1"),
    (Join-Path $PSScriptRoot "..\tools\WindrosePlus-BuildCatalog.ps1"),
    (Join-Path $gameDir "tools\WindrosePlus-BuildCatalog.ps1")
)) {
    if (Test-Path -LiteralPath $candidate) { $catalogBuildScript = [System.IO.Path]::GetFullPath($candidate); break }
}
$catalogBuildEnabled = $true
if ($config.catalog -and $config.catalog.PSObject.Properties['build'] -and $config.catalog.build -eq $false) { $catalogBuildEnabled = $false }
if ("$env:WINDROSEPLUS_CATALOG_BUILD" -eq "0") { $catalogBuildEnabled = $false }
function Start-CatalogBuild {
    if (-not $catalogBuildEnabled) { Write-Host "Item catalog: building is switched off in windrose_plus.json"; return }
    if (-not $catalogBuildScript) { Write-Host "Item catalog: WindrosePlus-BuildCatalog.ps1 not found; the Items panel stays empty"; return }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -GameDir "{1}" -OutputDir "{2}" -LogFile "{3}"' -f $catalogBuildScript, $gameDir, $catalogDataDir, $catalogBuildLog)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
        $script:CatalogBuildProcess = $proc
        Write-Host "Item catalog: checking it against the game files (log: $catalogBuildLog)"
    } catch {
        Write-Host "Item catalog: the builder could not start: $($_.Exception.Message)"
    }
}
function Test-CatalogBuilding {
    $proc = $script:CatalogBuildProcess
    if (-not $proc) { return $false }
    try { return -not $proc.HasExited } catch { return $false }
}
Start-CatalogBuild

function Send-Json($context, $data, $statusCode = 200) {
    $json = if ($null -eq $data) { '{}' } else { $data | ConvertTo-Json -Depth 100 -Compress }
    if ([string]::IsNullOrEmpty($json)) { $json = '{}' }
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $context.Response.StatusCode = $statusCode
    $context.Response.ContentType = "application/json"
    $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $context.Response.ContentLength64 = $buffer.Length
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.Close()
}

function Write-AtomicUtf8Json($path, $data) {
    $tmpPath = "$path.tmp"
    $json = $data | ConvertTo-Json -Depth 100 -Compress
    [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $tmpPath -Destination $path -Force
}

# --- Terrain heightmap sampling (for click-to-teleport on the SEA CHART) ---
# The dashboard already has full elevation data exported by HeightmapExporter:
#   windrose_plus_data/terrain_v17.json   — manifest of components (wx, wy, minZ, maxZ, res, file)
#   windrose_plus_data/heightmaps/*.bin   — uint16 heightfield grids per component
# Component binary format: int32 res, then res*res uint16 samples.
# Sample formula: worldZ = minZ + (raw / 65535) * (maxZ - minZ).
# Components with maxZ < 100 are ocean floor (per generateTiles.ps1's seaLevelThreshold);
# we skip those so a click over ocean falls back to "preserve current Z" rather than
# teleporting the player to the sea floor.
$script:TerrainCacheReady = $false
$script:TerrainLandComps = $null

function Initialize-TerrainCache($DataDir) {
    if ($script:TerrainCacheReady) { return $true }
    $jsonPath = Join-Path $DataDir "terrain_v17.json"
    if (-not (Test-Path -LiteralPath $jsonPath)) { return $false }
    try {
        $meta = Get-Content $jsonPath -Raw | ConvertFrom-Json
    } catch { return $false }

    # Per-landscape step (delta between consecutive sx values; defines compW = step * scale)
    $byLand = @{}
    foreach ($c in $meta.components) {
        $li = [string]$c.l
        if (-not $byLand.ContainsKey($li)) { $byLand[$li] = @() }
        $byLand[$li] += $c
    }
    $landSteps = @{}
    foreach ($li in $byLand.Keys) {
        $sxs = @($byLand[$li] | ForEach-Object { $_.sx } | Sort-Object -Unique)
        if ($sxs.Count -gt 1) { $landSteps[$li] = $sxs[1] - $sxs[0] }
        else { $landSteps[$li] = 255 }
    }

    $comps = New-Object System.Collections.Generic.List[object]
    foreach ($c in $meta.components) {
        if ($c.h -ne 1) { continue }
        $maxZ = if ($null -ne $c.maxZ) { [double]$c.maxZ } else { 1.0 }
        if ($maxZ -lt 100) { continue }  # ocean floor — skip
        $li = [string]$c.l
        $land = $meta.landscapes[$c.l]
        $scale = if ($land.sx -gt 0) { [double]$land.sx } else { 100.0 }
        $step = if ($landSteps.ContainsKey($li)) { [double]$landSteps[$li] } else { 255.0 }
        $compW = $step * $scale
        $minZ = if ($null -ne $c.minZ) { [double]$c.minZ } else { 0.0 }
        $comps.Add([PSCustomObject]@{
            wx = [double]$c.wx
            wy = [double]$c.wy
            wx2 = [double]$c.wx + $compW
            wy2 = [double]$c.wy + $compW
            res = [int]$c.res
            minZ = $minZ
            maxZ = $maxZ
            f = [string]$c.f
        }) | Out-Null
    }
    $script:TerrainLandComps = $comps
    $script:TerrainCacheReady = $true
    return $true
}

function Get-TerrainHeightAt($DataDir, [double]$WorldX, [double]$WorldY) {
    if (-not (Initialize-TerrainCache $DataDir)) { return $null }
    foreach ($c in $script:TerrainLandComps) {
        if ($WorldX -ge $c.wx -and $WorldX -lt $c.wx2 -and $WorldY -ge $c.wy -and $WorldY -lt $c.wy2) {
            $hfPath = Join-Path $DataDir "heightmaps\$($c.f)"
            if (-not (Test-Path -LiteralPath $hfPath)) { return $null }
            try {
                $bytes = [System.IO.File]::ReadAllBytes($hfPath)
                if ($bytes.Length -lt 8) { return $null }
                $res = [BitConverter]::ToInt32($bytes, 0)
                if ($res -le 0 -or $res -ne $c.res) { return $null }
                $compW = $c.wx2 - $c.wx
                $fx = ($WorldX - $c.wx) / $compW
                $fy = ($WorldY - $c.wy) / $compW
                $hx = [int][Math]::Floor($fx * $res)
                $hy = [int][Math]::Floor($fy * $res)
                if ($hx -lt 0) { $hx = 0 } elseif ($hx -ge $res) { $hx = $res - 1 }
                if ($hy -lt 0) { $hy = 0 } elseif ($hy -ge $res) { $hy = $res - 1 }
                $byteOff = 4 + ($hy * $res + $hx) * 2
                if ($byteOff + 1 -ge $bytes.Length) { return $null }
                $raw = [BitConverter]::ToUInt16($bytes, $byteOff)
                $z = $c.minZ + ($raw / 65535.0) * ($c.maxZ - $c.minZ)
                return $z
            } catch { return $null }
        }
    }
    return $null
}

function Get-RconWorkerDiagnostic($spoolDir, $cmdPath) {
    $statusPath = Join-Path $dataDir "rcon_status.json"
    $now = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $status = $null
    $age = $null

    if (Test-Path -LiteralPath $statusPath) {
        try {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            if ($null -ne $status.ts) { $age = $now - [long]$status.ts }
        } catch {
            return "Command timed out (25s). RCON worker status exists but could not be parsed; restart the Windrose server."
        }
    } else {
        return "Command timed out (25s). RCON worker status file is missing; the Windrose+ Lua worker is not running or RCON is disabled in the game process."
    }

    $detail = ""
    if ($status.state -or $status.detail) {
        $detail = " Worker state: $($status.state); detail: $($status.detail)"
    }
    if ($status.last_error) {
        $detail += " Last worker error: $($status.last_error)"
    }

    if ($null -ne $age -and $age -gt 15) {
        return "Command timed out (25s). RCON worker heartbeat is stale (${age}s old); restart the Windrose server process.$detail"
    }

    if (Test-Path -LiteralPath $cmdPath) {
        return "Command timed out (25s). RCON worker is alive but did not consume the command file; check windrose_plus_data\\rcon and restart the Windrose server if it persists.$detail"
    }

    return "Command timed out (25s). RCON worker consumed the command but did not write a response.$detail"
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

# Tiles asked for with the tile set's id (?v=, from map_coords.json tileset_id)
# never change under that address, so the browser may keep them for a day. A
# tile set without an id is checked back each time (ETag) so a rebuild shows.
function Set-TileCacheHeader($context) {
    $v = [string]$context.Request.QueryString["v"]
    if ($v -and $v -match '^[A-Za-z0-9_.-]{1,64}$') {
        $context.Response.Headers.Add("Cache-Control", "public, max-age=86400")
    }
}

# Sends a file with an ETag and Last-Modified and answers 304 when the browser
# already has that version, so a reopened page costs no bytes. Cache-Control is
# no-cache (the browser checks back each time) unless the caller set one first.
function Send-File($context, $filePath) {
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        $context.Response.StatusCode = 404
        $context.Response.Close()
        return
    }
    $info = Get-Item -LiteralPath $filePath
    $etag = '"' + $info.Length.ToString("x") + "-" + $info.LastWriteTimeUtc.Ticks.ToString("x") + '"'
    if (-not $context.Response.Headers["Cache-Control"]) { $context.Response.Headers.Add("Cache-Control", "no-cache") }
    $context.Response.Headers.Add("ETag", $etag)
    $context.Response.Headers.Add("Last-Modified", $info.LastWriteTimeUtc.ToString("r"))
    $ifNoneMatch = [string]$context.Request.Headers["If-None-Match"]
    if ($ifNoneMatch -and (@($ifNoneMatch -split ",\s*") -contains $etag)) {
        $context.Response.StatusCode = 304
        $context.Response.Close()
        return
    }
    $content = [System.IO.File]::ReadAllBytes($filePath)
    $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
    $mimeTypes = @{
        ".html" = "text/html"; ".css" = "text/css"; ".js" = "application/javascript"
        ".json" = "application/json"; ".png" = "image/png"; ".jpg" = "image/jpeg"
        ".svg" = "image/svg+xml"; ".ico" = "image/x-icon"; ".webp" = "image/webp"
        ".woff2" = "font/woff2"; ".woff" = "font/woff"; ".ttf" = "font/ttf"
    }
    $mime = if ($mimeTypes[$ext]) { $mimeTypes[$ext] } else { "application/octet-stream" }
    $context.Response.ContentType = $mime
    $context.Response.ContentLength64 = $content.Length
    $context.Response.OutputStream.Write($content, 0, $content.Length)
    $context.Response.Close()
}

function Send-DownloadFile($context, $filePath, $downloadName, $contentType = "application/octet-stream") {
    if (-not (Test-Path -LiteralPath $filePath)) {
        $context.Response.StatusCode = 404
        $context.Response.Close()
        return
    }
    $fileInfo = Get-Item -LiteralPath $filePath
    $buffer = New-Object byte[] 65536
    $stream = [System.IO.File]::OpenRead($filePath)
    $context.Response.StatusCode = 200
    $context.Response.ContentType = $contentType
    $context.Response.Headers.Add("Content-Disposition", "attachment; filename=`"$downloadName`"")
    $context.Response.Headers.Add("Cache-Control", "no-store")
    $context.Response.ContentLength64 = $fileInfo.Length
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $context.Response.OutputStream.Write($buffer, 0, $read)
        }
    } finally {
        $stream.Close()
        $context.Response.Close()
    }
}

function Read-RequestBodyToFile($context, $targetPath, $maxBytes) {
    $total = 0L
    $buffer = New-Object byte[] 65536
    $stream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        while ($true) {
            # A client that stops sending for 30 seconds is dropped: the
            # dashboard answers one request at a time.
            $task = $context.Request.InputStream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $task.Wait(30000)) {
                try { $context.Response.Abort() } catch {}
                throw "Upload stalled."
            }
            $read = $task.Result
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $maxBytes) {
                throw "Upload exceeds the $([Math]::Round($maxBytes / 1MB)) MB limit."
            }
            $stream.Write($buffer, 0, $read)
        }
    } finally {
        $stream.Close()
    }
    return $total
}

function Format-RepairToolOutput($output, $repairRoot) {
    $text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($text -match "spent or allocated progression nodes|spent points detected") {
        return "The uploaded save has spent or allocated progression nodes, so Safe mode declined to auto-edit it. Send the same SaveProfiles zip to your server admin or hosting support so they can run the deeper repair manually."
    }
    if ($text -match "no repairable progression drift") {
        return "No known no-spend progression drift was found in the uploaded save."
    }
    if ($text -match "could not find SaveProfiles|could not resolve Players RocksDB|no PlayerId") {
        return "The zip did not contain a supported SaveProfiles/<steamid>/RocksDB/0.10.0/Players folder."
    }
    if ($text -match "zip has too many entries|zip entry is too large|zip extracted size is too large|unsafe zip entry path|open zip archive") {
        return "The upload is not a safe supported SaveProfiles zip. Recreate the zip from only your local SteamID profile folder."
    }
    if ($text -match "round-trip mismatch|decode BSON|R5BLPlayer|column family|missing or invalid tree path|tree path is not an array|tree node") {
        return "The player save shape was not recognized, so no automatic repair was made."
    }
    if ($text -match "timed out") {
        return "Repair timed out before a safe result was produced."
    }
    if ($text -match "Upload exceeds") {
        return "The uploaded zip is larger than the 200 MB limit."
    }
    return "The repair tool could not safely repair this zip."
}

function Invoke-RepairTool($healExe, $auditLog, $uploadPath, $outputPath, $timeoutSeconds) {
    $job = Start-Job -ScriptBlock {
        param($exe, $audit, $inputZip, $repairedZip)
        $toolOutput = & $exe --log-level warn --audit-log $audit repair-zip --input $inputZip --output $repairedZip --strategy safe 2>&1
        $toolExitCode = $LASTEXITCODE
        [pscustomobject]@{
            ExitCode = $toolExitCode
            Output = (($toolOutput | ForEach-Object { "$_" }) -join "`n")
        }
    } -ArgumentList $healExe, $auditLog, $uploadPath, $outputPath
    try {
        $done = Wait-Job $job -Timeout $timeoutSeconds
        if (-not $done) {
            Stop-Job $job -ErrorAction SilentlyContinue
            return @{ ExitCode = -1; Output = "repair timed out" }
        }
        $result = Receive-Job $job
        if (-not $result) {
            return @{ ExitCode = -1; Output = "repair produced no result" }
        }
        return @{ ExitCode = [int]$result.ExitCode; Output = [string]$result.Output }
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}

try {
    while ($listener.IsListening) {
        Invoke-TileGenerationWatch
        $contextTask = $listener.GetContextAsync()
        while (-not $contextTask.AsyncWaitHandle.WaitOne(1000)) {
            Invoke-TileGenerationWatch
            Invoke-GameWatch
        }
        $context = $contextTask.GetAwaiter().GetResult()
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
                $currentPassword = Get-CurrentRconPassword
                $clientKey = Get-ClientKey $context.Request
                if ($method -eq "POST" -and (Test-AuthThrottled $clientKey)) {
                    $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Too many wrong passwords. Wait a few minutes and try again.</div>')
                    Send-Html $context $errorHtml 429
                    continue
                }
                if ($method -eq "POST") {
                    $bodyRead = Read-RequestBodyText $context 8192
                    if (-not $bodyRead.Ok) {
                        if ($bodyRead.Status -eq 413) { Send-Html $context ($loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">The login request was too large.</div>')) 413 }
                        continue
                    }
                    $body = $bodyRead.Text
                    $formPassword = ""
                    # Accept both application/x-www-form-urlencoded (browser <form>) and
                    # multipart/form-data (curl -F, some HTTP clients). The HTML form
                    # itself is urlencoded, but the field name + value are identical, so
                    # supporting both keeps scripted callers like `curl -F password=...`
                    # working without forcing them to switch to --data.
                    $contentType = ""
                    if ($context.Request.ContentType) { $contentType = $context.Request.ContentType }
                    if ($contentType -match "(?i)^multipart/form-data") {
                        $boundary = $null
                        if ($contentType -match "(?i)boundary=(?:""([^""]+)""|([^;]+))") {
                            $boundary = if ($matches[1]) { $matches[1].Trim() } else { $matches[2].Trim() }
                        }
                        if ($boundary) {
                            $parts = $body -split [regex]::Escape("--$boundary")
                            foreach ($part in $parts) {
                                if ($part -notmatch '(?i)Content-Disposition:[^\r\n]*name="password"') { continue }
                                $headerEnd = $part.IndexOf("`r`n`r`n")
                                $sepLen = 4
                                if ($headerEnd -lt 0) {
                                    $headerEnd = $part.IndexOf("`n`n")
                                    $sepLen = 2
                                }
                                if ($headerEnd -lt 0) { continue }
                                $valStart = $headerEnd + $sepLen
                                if ($valStart -ge $part.Length) { continue }
                                $val = $part.Substring($valStart)
                                # Strip the trailing CRLF that precedes the next boundary delimiter.
                                $val = $val -replace "(\r\n|\r|\n)+$", ""
                                $formPassword = $val
                                break
                            }
                        }
                    } else {
                        foreach ($pair in $body -split "&") {
                            $kv = $pair -split "=", 2
                            if ($kv[0] -eq "password") {
                                $formPassword = [System.Uri]::UnescapeDataString($kv[1].Replace("+", " "))
                            }
                        }
                    }
                    if ($null -eq $currentPassword) {
                        $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Config temporarily unavailable — retry in a moment</div>')
                        Send-Html $context $errorHtml
                    } elseif (-not $currentPassword) {
                        $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Set a password in windrose_plus.json to access the dashboard</div>')
                        Send-Html $context $errorHtml
                    } elseif ($currentPassword -eq "changeme") {
                        $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Change the default password in windrose_plus.json</div>')
                        Send-Html $context $errorHtml
                    } elseif (Test-SecretEqual $formPassword $currentPassword) {
                        $token = New-SessionToken
                        $context.Response.Headers.Add("Set-Cookie", (Get-SessionCookieHeader $token 86400))
                        Send-Redirect $context "/"
                    } else {
                        Add-AuthFailure $clientKey
                        $errorHtml = $loginPageHtml.Replace("ERRORPLACEHOLDER", '<div class="error" style="display:block">Invalid password</div>')
                        Send-Html $context $errorHtml
                    }
                } else {
                    if ($null -eq $currentPassword) {
                        $errorMsg = '<div class="error" style="display:block">Config temporarily unavailable — retry in a moment</div>'
                    } elseif (-not $currentPassword) {
                        $errorMsg = '<div class="error" style="display:block">Set a password in windrose_plus.json to access the dashboard</div>'
                    } elseif ($currentPassword -eq "changeme") {
                        $errorMsg = '<div class="error" style="display:block">Change the default password in windrose_plus.json</div>'
                    } else {
                        $errorMsg = ""
                    }
                    $html = $loginPageHtml.Replace("ERRORPLACEHOLDER", $errorMsg)
                    Send-Html $context $html
                }
                continue
            }

            # Log out: clears this dashboard's cookie. Changing the RCON
            # password ends every session at once.
            if ($path -eq "/logout") {
                $context.Response.Headers.Add("Set-Cookie", (Get-SessionCookieHeader "" 0))
                Send-Redirect $context "/login"
                continue
            }

            # API health endpoint — no auth (used for monitoring)
            if ($path -eq "/api/health") {
                Send-Json $context @{ status = "ok"; version = $Version; routes_version = $routesVersion; pak_builder_version = $pakBuilderVersion; timestamp = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
                continue
            }

            # Static self-hosted dashboard dependencies — no auth.
            # Public Sea Chart pages need these assets before any dashboard login.
            if ($path.StartsWith("/vendor/")) {
                $vendorRoot = [System.IO.Path]::GetFullPath((Join-Path $webDir "vendor"))
                $candidate  = [System.IO.Path]::GetFullPath((Join-Path $webDir ($path.TrimStart("/").Replace("/", "\"))))
                $sep        = [System.IO.Path]::DirectorySeparatorChar
                if (-not $candidate.StartsWith($vendorRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $context.Response.StatusCode = 403
                    $context.Response.Close()
                    continue
                }
                Send-File $context $candidate
                continue
            }

            # Item catalog (built on this server from the game files) and the
            # Windrose+ item icons — no auth. Nothing here identifies a player or
            # the server; public Sea Chart viewers need it for the Items panel.
            if ($path.StartsWith("/catalog/")) {
                if ($path -match '^/catalog/v1/([A-Za-z0-9_]+\.json)$') {
                    $builtFile = Join-Path $catalogDataDir $Matches[1]
                    if (Test-Path -LiteralPath $builtFile) {
                        $context.Response.Headers.Add("Cache-Control", "no-cache")
                        Send-File $context $builtFile
                    } elseif (Test-CatalogBuilding) {
                        Send-Json $context @{ error = "The item catalog is being built from the game files." } 503
                    } else {
                        Send-Json $context @{ error = "The item catalog has not been built. See windrose_plus_data\catalog\build.log." } 404
                    }
                    continue
                }
                $catalogRoot = [System.IO.Path]::GetFullPath((Join-Path $webDir "catalog"))
                $candidate   = [System.IO.Path]::GetFullPath((Join-Path $webDir ($path.TrimStart("/").Replace("/", "\"))))
                $sep         = [System.IO.Path]::DirectorySeparatorChar
                if (-not $candidate.StartsWith($catalogRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $context.Response.StatusCode = 403
                    $context.Response.Close()
                    continue
                }
                Send-File $context $candidate
                continue
            }

            # Optional public Sea Chart. This deliberately exposes only the map
            # manifest, livemap snapshot, and generated tiles. Dashboard, RCON,
            # config, repair, status, and terrain-height routes still require
            # the normal authenticated dashboard session above.
            if ($path -eq "/public-map" -or $path.StartsWith("/api/public/") -or $path.StartsWith("/public-map/tiles/")) {
                $publicAccess = Test-PublicMapAccess $context.Request
                if (-not $publicAccess.Allowed) {
                    if ($path.StartsWith("/api/")) {
                        Send-Json $context @{ error = $publicAccess.Error } $publicAccess.StatusCode
                    } else {
                        Send-Html $context ("<html><body>{0}</body></html>" -f [System.Net.WebUtility]::HtmlEncode($publicAccess.Error)) $publicAccess.StatusCode
                    }
                    continue
                }

                if ($path -eq "/public-map") {
                    Send-File $context (Join-Path $webDir "livemap\index.html")
                    continue
                }

                if ($path -eq "/api/public/livemap") {
                    $mapFile = Join-Path $dataDir "livemap_data.json"
                    if (Test-Path -LiteralPath $mapFile) {
                        $data = Get-Content $mapFile -Raw | ConvertFrom-Json
                        Send-Json $context (ConvertTo-PublicLiveMapData $data)
                    } else {
                        Send-Json $context @{ error = "No livemap data" } 503
                    }
                    continue
                }

                if ($path -eq "/api/public/pois") {
                    Send-PoiScanData $context
                    continue
                }

                if ($path -eq "/api/public/runtime-overlay") {
                    $overlay = Get-RuntimeOverlayData
                    if ($overlay.Ok) {
                        Send-Json $context $overlay.Data
                    } else {
                        Send-Json $context @{ error = $overlay.Error } $overlay.StatusCode
                    }
                    continue
                }

                if ($path -eq "/api/public/mapinfo") {
                    $mapCoordsFile = Join-Path $dataDir "map_coords.json"
                    if (Test-Path -LiteralPath $mapCoordsFile) {
                        $data = Get-Content $mapCoordsFile -Raw | ConvertFrom-Json
                        Send-Json $context $data
                    } else {
                        # Public viewers get the build state only, not the script path
                        # or the tool output (logged-in /api/mapinfo has those).
                        $generation = $null
                        $statusFile = Join-Path $dataDir "map_generation_status.json"
                        if (Test-Path -LiteralPath $statusFile) {
                            try {
                                $g = [System.IO.File]::ReadAllText($statusFile) | ConvertFrom-Json
                                $generation = @{ state = [string]$g.state; ts = $g.ts }
                            } catch {}
                        }
                        Send-Json $context @{
                            error = "Map not ready yet. Join the server once to auto-generate the map."
                            generation = $generation
                        } 503
                    }
                    continue
                }

                if ($path -match "^/public-map/tiles/(\d+)/(\d+)-(\d+)\.png$") {
                    $tilePath = Join-Path $dataDir "map_tiles\$($Matches[1])\$($Matches[2])-$($Matches[3]).png"
                    Set-TileCacheHeader $context
                    Send-File $context $tilePath
                    continue
                }

                Send-Json $context @{ error = "Not found" } 404
                continue
            }

            # All other routes require authentication: a dashboard session
            # cookie, or the RCON password in an X-RCON-Password header (or, for
            # POST /api/rcon, a "password" field in the JSON body). Requests from
            # this machine get no free pass unless server.trust_loopback is set;
            # see Get-TrustLoopback.
            $script:RconBodyText = $null
            $cookieAuth = $false
            $isTrustedLocal = (Test-LoopbackRequest $context.Request) -and (Get-TrustLoopback)

            if (-not $isTrustedLocal) {
                $currentPassword = Get-CurrentRconPassword
                if ($null -eq $currentPassword) {
                    if ($path.StartsWith("/api/")) {
                        Send-Json $context @{ error = "Config temporarily unavailable, retry in a moment" } 503
                    } else {
                        Send-Redirect $context "/login"
                    }
                    continue
                }
                if (-not $currentPassword -or $currentPassword -eq "changeme") {
                    # No password configured or still default: block everything
                    if ($path.StartsWith("/api/")) {
                        Send-Json $context @{ error = "No password configured. Set a password in windrose_plus.json to access the dashboard." } 403
                    } else {
                        Send-Redirect $context "/login"
                    }
                    continue
                }
                $authenticated = Test-SessionCookie $context.Request
                $cookieAuth = $authenticated -and -not $context.Request.Headers["X-RCON-Password"]
                if (-not $authenticated) {
                    $clientKey = Get-ClientKey $context.Request
                    $headerPassword = $context.Request.Headers["X-RCON-Password"]
                    $bodyPassword = $null
                    if (-not $headerPassword -and $path -eq "/api/rcon" -and $method -eq "POST") {
                        $bodyRead = Read-RequestBodyText $context 65536
                        if (-not $bodyRead.Ok) {
                            if ($bodyRead.Status -eq 413) { Send-Json $context @{ error = "Request body too large" } 413 }
                            continue
                        }
                        $script:RconBodyText = $bodyRead.Text
                        try {
                            $parsedBody = $script:RconBodyText | ConvertFrom-Json
                            if ($parsedBody -and $parsedBody.password) { $bodyPassword = [string]$parsedBody.password }
                        } catch {}
                    }
                    $offered = if ($headerPassword) { [string]$headerPassword } else { $bodyPassword }
                    if ($offered) {
                        if (Test-AuthThrottled $clientKey) {
                            Send-Json $context @{ error = "Too many wrong passwords. Wait a few minutes and try again." } 429
                            continue
                        }
                        if (Test-SecretEqual $offered $currentPassword) {
                            $authenticated = $true
                        } else {
                            Add-AuthFailure $clientKey
                        }
                    }
                }
                if (-not $authenticated) {
                    # API calls get 401, browser requests get redirect
                    if ($path.StartsWith("/api/")) {
                        Send-Json $context @{ error = "Authentication required" } 401
                    } else {
                        Send-Redirect $context "/login"
                    }
                    continue
                }
                if ($cookieAuth -and $method -eq "POST" -and (Test-CrossSiteSendableContentType $context.Request.ContentType)) {
                    Send-Json $context @{ error = "Send this request as application/json, or with the X-RCON-Password header." } 415
                    continue
                }
            }

            switch ($path) {
                "/api/status" {
                    $statusFile = Join-Path $dataDir "server_status.json"
                    if (Test-Path -LiteralPath $statusFile) {
                        $data = Get-Content $statusFile -Raw | ConvertFrom-Json
                        Send-Json $context $data
                    } else {
                        Send-Json $context @{ error = "No status data" } 503
                    }
                }
                "/api/livemap" {
                    $mapFile = Join-Path $dataDir "livemap_data.json"
                    if (Test-Path -LiteralPath $mapFile) {
                        $data = Get-Content $mapFile -Raw | ConvertFrom-Json
                        Send-Json $context $data
                    } else {
                        Send-Json $context @{ error = "No livemap data" } 503
                    }
                }
                "/api/pois" {
                    Send-PoiScanData $context
                }
                "/api/runtime-overlay" {
                    $overlay = Get-RuntimeOverlayData
                    if ($overlay.Ok) {
                        Send-Json $context $overlay.Data
                    } else {
                        Send-Json $context @{ error = $overlay.Error } $overlay.StatusCode
                    }
                }
                "/api/config" {
                    $liveConfig = Get-CurrentConfig
                    if ($null -eq $liveConfig) {
                        Send-Json $context @{ error = "Config temporarily unavailable, retry in a moment" } 503
                        continue
                    }
                    if ($liveConfig.rcon -and $liveConfig.rcon.password) { $liveConfig.rcon.password = "***" }
                    Send-Json $context $liveConfig
                }
                "/api/pak-status" {
                    $multPak = Join-Path $gameDir "R5\Content\Paks\WindrosePlus_Multipliers_P.pak"
                    # The CurveTable override ships as an IoStore container; the .utoc is
                    # the part the engine actually resolves packages from, so status keys off it.
                    $ctPak   = Join-Path $gameDir "R5\Content\Paks\WindrosePlus_CurveTables_P.utoc"
                    $ctManifest = Join-Path $gameDir "windrose_plus_data\.windroseplus_curvetables_manifest.json"
                    $wrapper = Join-Path $gameDir "StartWindrosePlusServer.bat"
                    $jsonPath = Join-Path $gameDir "windrose_plus.json"
                    $iniPath  = Join-Path $gameDir "windrose_plus.ini"
                    $multiplierPakDisabled = "$env:WINDROSEPLUS_DISABLE_MULTIPLIER_PAK".Trim().ToLowerInvariant() -in @("1","true","yes","on")
                    # CurveTable-relevant INIs only — harvest is a
                    # multipliers-only file and must NOT make ct_config_present
                    # true on its own (would trigger spurious "Default INI
                    # missing" status when no CT customization is in play).
                    $ctIniPaths = @(
                        $iniPath,
                        (Join-Path $gameDir "windrose_plus.weapons.ini"),
                        (Join-Path $gameDir "windrose_plus.food.ini"),
                        (Join-Path $gameDir "windrose_plus.gear.ini"),
                        (Join-Path $gameDir "windrose_plus.entities.ini")
                    )
                    # Full INI list (CT + multipliers) used for mtime / stale
                    # detection so harvest edits still invalidate the build.
                    $iniPaths = $ctIniPaths + @(
                        (Join-Path $gameDir "windrose_plus.harvest.ini")
                    )
                    $ctConfigPresent = $false
                    foreach ($p in $ctIniPaths) {
                        if (Test-Path -LiteralPath $p) {
                            $ctConfigPresent = $true
                            break
                        }
                    }

                    $status = @{
                        wrapper_present         = (Test-Path -LiteralPath $wrapper)
                        multipliers_pak_present = (Test-Path -LiteralPath $multPak)
                        curvetables_pak_present = (Test-Path -LiteralPath $ctPak)
                        json_present            = (Test-Path -LiteralPath $jsonPath)
                        ini_present             = (Test-Path -LiteralPath $iniPath)
                        ct_config_present       = $ctConfigPresent
                        multiplier_pak_disabled = $multiplierPakDisabled
                        multiplier_config_present = $false
                        curvetables_manifest_present = (Test-Path -LiteralPath $ctManifest)
                        curvetables_manifest_mtime_utc = $null
                        curvetables_last_build_utc = $null
                        curvetables_changes_total = $null
                        curvetables_tables = @()
                        curvetables_recent_changes = @()
                        stale                   = $false
                        stale_reason            = $null
                    }

                    if ($status.wrapper_present) {
                        $configMtime = 0
                        $configFiles = @($jsonPath) + $iniPaths
                        foreach ($f in $configFiles) {
                            if (Test-Path -LiteralPath $f) {
                                $t = (Get-Item -LiteralPath $f).LastWriteTimeUtc.Ticks
                                if ($t -gt $configMtime) { $configMtime = $t }
                            }
                        }

                        # Does the current config *require* a Multipliers PAK?
                        $disabledPakMultipliers = @("points_per_level", "stack_size", "weight", "inventory_size", "crop_speed")
                        $expectMultPak = $false
                        if ($status.json_present) {
                            try {
                                $j = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
                                if ($j.multipliers) {
                                    foreach ($p in $j.multipliers.PSObject.Properties) {
                                        if ($disabledPakMultipliers -contains $p.Name) { continue }
                                        if ([double]$p.Value -ne 1.0) { $expectMultPak = $true; break }
                                    }
                                }
                            } catch { }
                        }
                        # windrose_plus.harvest.ini alone (no non-default
                        # multipliers in the JSON) also requires a Multipliers
                        # PAK. Inline parse — same `Key = Number` shape that
                        # Read-HarvestIni handles in MultiplierPakBuilder.ps1.
                        if (-not $expectMultPak) {
                            $harvestIniPath = Join-Path $gameDir "windrose_plus.harvest.ini"
                            if (Test-Path -LiteralPath $harvestIniPath) {
                                try {
                                    foreach ($raw in Get-Content -LiteralPath $harvestIniPath) {
                                        $line = $raw.Trim()
                                        if (-not $line) { continue }
                                        $first = $line[0]
                                        if ($first -eq ';' -or $first -eq '#' -or $first -eq '[') { continue }
                                        $eq = $line.IndexOf('=')
                                        if ($eq -lt 1) { continue }
                                        $val = $line.Substring($eq + 1)
                                        $semi = $val.IndexOf(';')
                                        if ($semi -ge 0) { $val = $val.Substring(0, $semi) }
                                        $val = $val.Trim()
                                        $d = 0.0
                                        if ([double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
                                            if ($d -ne 1.0) { $expectMultPak = $true; break }
                                        }
                                    }
                                } catch { }
                            }
                        }
                        $status.multiplier_config_present = $expectMultPak

                        if (-not $script:IniParserLoaded) {
                            # Can't authoritatively answer CT question — return what we know
                            # and surface the parser error. Early-out so the composite
                            # stale/reason calculation below doesn't overwrite this.
                            $status.stale = $true
                            $status.stale_reason = "Parser unavailable: $script:IniParserLoadError"
                        } else {
                            # Does the current config *require* a CurveTables PAK?
                            $expectCtPak = $false
                            $ctStatusError = $null
                            if ($status.ct_config_present) {
                                $defaultIniPath = Join-Path $gameDir "windrose_plus\config\windrose_plus.default.ini"
                                if (Test-Path -LiteralPath $defaultIniPath) {
                                    try {
                                        $parsed = Import-WindrosePlusConfig -ConfigPath $iniPath -DefaultPath $defaultIniPath
                                        if ($parsed.Error) {
                                            $ctStatusError = "INI parse failed: $($parsed.Error)"
                                        } elseif ($parsed.CurveTables -and $parsed.CurveTables.Count -gt 0) {
                                            $expectCtPak = $true
                                        }
                                    } catch {
                                        $ctStatusError = "INI parse failed: $_"
                                    }
                                } else {
                                    $ctStatusError = "Default INI missing; cannot evaluate CurveTable config"
                                }
                            }

                            $pakMtime = [long]::MaxValue
                            $stale = $false
                            $reason = $null

                            if ($ctStatusError) {
                                $stale = $true
                                $reason = $ctStatusError
                            }
                            if ($multiplierPakDisabled -and $status.multipliers_pak_present -and -not $stale) {
                                $stale = $true; $reason = "Multiplier PAK generation is disabled but a generated multiplier PAK is still present"
                            }
                            if ($expectMultPak -and -not $stale) {
                                if ($multiplierPakDisabled) {
                                    # Intentional no-op: config has multipliers, but the
                                    # emergency disable switch tells the builder not to
                                    # produce/load a generated multiplier PAK.
                                } elseif ($status.multipliers_pak_present) {
                                    $t = (Get-Item $multPak).LastWriteTimeUtc.Ticks
                                    if ($t -lt $pakMtime) { $pakMtime = $t }
                                } else {
                                    $stale = $true; $reason = "Multipliers PAK missing but config requires one"
                                }
                            }
                            if ($expectCtPak -and -not $stale) {
                                if ($status.curvetables_pak_present) {
                                    $t = (Get-Item $ctPak).LastWriteTimeUtc.Ticks
                                    if ($t -lt $pakMtime) { $pakMtime = $t }
                                } else {
                                    $stale = $true; $reason = "CurveTables PAK missing but config requires one"
                                }
                            }
                            if (-not $stale -and (($expectMultPak -and -not $multiplierPakDisabled) -or $expectCtPak)) {
                                if ($configMtime -gt 0 -and $configMtime -gt $pakMtime) {
                                    $stale = $true
                                    $reason = "Config edited after PAK build"
                                }
                            }

                            $status.stale = $stale
                            $status.stale_reason = $reason
                        }
                    }

                    if (Test-Path -LiteralPath $ctManifest) {
                        try {
                            $ctm = Get-Content -LiteralPath $ctManifest -Raw | ConvertFrom-Json
                            $status.curvetables_manifest_mtime_utc = (Get-Item -LiteralPath $ctManifest).LastWriteTimeUtc.ToString("o")
                            $status.curvetables_last_build_utc = $ctm.built_at_utc
                            $status.curvetables_changes_total = $ctm.changes_total
                            $status.curvetables_tables = @($ctm.changes | ForEach-Object { $_.Table } | Sort-Object -Unique)
                            $status.curvetables_recent_changes = @($ctm.changes | Select-Object -First 20 Table,Row,OriginalValue,NewValue)
                        } catch {
                            $status.curvetables_manifest_error = "Could not parse CurveTables manifest: $_"
                        }
                    }

                    Send-Json $context $status
                }
                "/api/commands" {
                    # Source of truth is the Lua-side registry, written to
                    # windrose_plus_data\commands.json on Admin.init() and on
                    # every API.registerCommand() (so mod-registered commands
                    # surface in the dashboard autocomplete without code drift).
                    $commandsFile = Join-Path $dataDir "commands.json"
                    if (Test-Path -LiteralPath $commandsFile) {
                        try {
                            $payload = Get-Content -LiteralPath $commandsFile -Raw | ConvertFrom-Json
                            Send-Json $context @{ commands = $payload.commands; generatedAt = $payload.generatedAt }
                            continue
                        } catch {
                            # fall through to bootstrap fallback
                        }
                    }
                    # Bootstrap fallback: a small built-in list used only before
                    # the Lua side has written commands.json (first boot, or if
                    # WindrosePlus isn't loaded). Real autocomplete arrives once
                    # the mod boots and overwrites this.
                    Send-Json $context @{
                        commands = @(
                            @{name="wp.help"; usage="wp.help [command|all]"; description="List all commands or get help for a specific command"; category="server"},
                            @{name="wp.status"; usage="wp.status"; description="Show server status and multipliers"; category="server"},
                            @{name="wp.version"; usage="wp.version"; description="Show version"; category="server"}
                        )
                        bootstrap = $true
                    }
                }
                "/api/mapinfo" {
                    $mapCoordsFile = Join-Path $dataDir "map_coords.json"
                    if (Test-Path -LiteralPath $mapCoordsFile) {
                        $data = Get-Content $mapCoordsFile -Raw | ConvertFrom-Json
                        Send-Json $context $data
                    } else {
                        $generation = $null
                        $statusFile = Join-Path $dataDir "map_generation_status.json"
                        if (Test-Path -LiteralPath $statusFile) {
                            try { $generation = Get-Content $statusFile -Raw | ConvertFrom-Json } catch {}
                        }
                        Send-Json $context @{
                            error = "Map not ready yet. Join the server once to auto-generate the map."
                            generation = $generation
                        } 503
                    }
                }
                "/api/terrain_height" {
                    # Sample the exported heightmap at a world (X, Y) and return ground Z.
                    # Used by the SEA CHART click-to-teleport so we don't drop the player
                    # under a mountain or in deep water.
                    $qs = $context.Request.QueryString
                    $xRaw = $qs["x"]
                    $yRaw = $qs["y"]
                    $worldX = 0.0; $worldY = 0.0
                    if ([string]::IsNullOrWhiteSpace($xRaw) -or [string]::IsNullOrWhiteSpace($yRaw)) {
                        Send-Json $context @{ error = "x and y query params required" } 400
                    } elseif (-not [double]::TryParse($xRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$worldX)) {
                        Send-Json $context @{ error = "x must be numeric" } 400
                    } elseif (-not [double]::TryParse($yRaw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$worldY)) {
                        Send-Json $context @{ error = "y must be numeric" } 400
                    } else {
                        $z = Get-TerrainHeightAt -DataDir $dataDir -WorldX $worldX -WorldY $worldY
                        if ($null -eq $z) {
                            Send-Json $context @{ x = $worldX; y = $worldY; z = $null; reason = "no_land_data" }
                        } else {
                            Send-Json $context @{ x = $worldX; y = $worldY; z = [double]$z }
                        }
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
                    $rawBody = $script:RconBodyText
                    if ($null -eq $rawBody) {
                        $bodyRead = Read-RequestBodyText $context 65536
                        if (-not $bodyRead.Ok) {
                            if ($bodyRead.Status -eq 413) { Send-Json $context @{ error = "Request body too large" } 413 }
                            continue
                        }
                        $rawBody = $bodyRead.Text
                    }
                    $body = $null
                    try { $body = $rawBody | ConvertFrom-Json } catch {}
                    if (-not $body -or -not $body.command) {
                        Send-Json $context @{ error = "JSON body with a command field required" } 400
                        continue
                    }

                    $rconSecret = Get-CurrentRconPassword
                    if ($null -eq $rconSecret) {
                        Send-Json $context @{ error = "Config temporarily unavailable, retry in a moment" } 503
                        continue
                    }
                    if (-not $rconSecret -or $rconSecret -eq "changeme") {
                        Send-Json $context @{ error = "RCON not configured" } 403
                        continue
                    }

                    # The auth gate above already checked the session cookie,
                    # X-RCON-Password header or body password.

                    # Write command file
                    $cmdId = "ps_" + [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + "_" + (Get-Random -Maximum 999999)
                    $spoolDir = Join-Path $dataDir "rcon"
                    if (-not (Test-Path -LiteralPath $spoolDir)) { New-Item -ItemType Directory -Path $spoolDir -Force | Out-Null }
                    $cmdData = @{
                        id = $cmdId
                        command = $body.command
                        args = @($body.args)
                        password = $rconSecret
                        admin_user = "Dashboard"
                        timestamp = [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    }
                    $cmdPath = Join-Path $spoolDir "cmd_$cmdId.json"
                    Write-AtomicUtf8Json $cmdPath $cmdData
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
                        $message = Get-RconWorkerDiagnostic $spoolDir $cmdPath
                        Send-Json $context @{ id = $cmdId; status = "error"; message = $message } 504
                        continue
                    }
                    Send-Json $context $result
                }
                "/api/character-repair" {
                    if ($method -ne "POST") {
                        Send-Json $context @{ error = "POST required" } 405
                        continue
                    }

                    $maxUploadBytes = 200MB
                    if ($context.Request.ContentLength64 -gt $maxUploadBytes) {
                        Send-Json $context @{ error = "Upload too large. Zip files must be 200 MB or smaller." } 413
                        continue
                    }
                    $maxOutputBytes = 200MB

                    $healExe = Join-Path $PSScriptRoot "..\tools\windrose-heal\windrose-heal.exe"
                    if (-not (Test-Path -LiteralPath $healExe)) {
                        Send-Json $context @{ error = "Character repair tool is missing. Reinstall Windrose+ from the latest release zip." } 503
                        continue
                    }

                    $repairRoot = Join-Path $dataDir "character_repair"
                    if (-not (Test-Path -LiteralPath $repairRoot)) {
                        New-Item -ItemType Directory -Path $repairRoot -Force | Out-Null
                    }

                    $runId = "repair_" + [long][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + "_" + (Get-Random -Maximum 999999)
                    $uploadPath = Join-Path $repairRoot "$runId-upload.zip"
                    $outputPath = Join-Path $repairRoot "$runId-repaired.zip"
                    $auditLog = Join-Path $dataDir "character_repair_audit.log"

                    try {
                        $uploadedBytes = Read-RequestBodyToFile $context $uploadPath $maxUploadBytes
                        if ($uploadedBytes -lt 4) {
                            throw "Uploaded file is empty or invalid."
                        }

                        $repairResult = Invoke-RepairTool $healExe $auditLog $uploadPath $outputPath 45
                        $toolOutput = $repairResult.Output
                        $exitCode = $repairResult.ExitCode
                        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath)) {
                            Send-Json $context @{
                                error = "No safe automatic repair was made."
                                detail = Format-RepairToolOutput $toolOutput $repairRoot
                            } 422
                            continue
                        }

                        $outputInfo = Get-Item -LiteralPath $outputPath
                        if ($outputInfo.Length -gt $maxOutputBytes) {
                            Send-Json $context @{
                                error = "Repair failed."
                                detail = "The repaired zip is larger than the 200 MB limit."
                            } 413
                            continue
                        }

                        Send-DownloadFile $context $outputPath "windrose-save-repaired.zip" "application/zip"
                    } catch {
                        $statusCode = 422
                        if ($_.Exception.Message -match "Upload exceeds") { $statusCode = 413 }
                        Send-Json $context @{
                            error = "Repair failed."
                            detail = Format-RepairToolOutput $_.Exception.Message $repairRoot
                        } $statusCode
                    } finally {
                        Remove-Item -LiteralPath $uploadPath -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
                    }
                }
                default {
                    # Static file serving
                    $filePath = $path
                    if ($filePath -eq "" -or $filePath -eq "/") { $filePath = "/index.html" }
                    if ($filePath -eq "/livemap") { $filePath = "/livemap/index.html" }
                    if ($filePath -eq "/repair") { $filePath = "/repair/index.html" }

                    # Serve map tiles from data directory
                    if ($filePath -match "^/livemap/tiles/(\d+)/(\d+)-(\d+)\.png$") {
                        $tilePath = Join-Path $dataDir "map_tiles\$($Matches[1])\$($Matches[2])-$($Matches[3]).png"
                        Set-TileCacheHeader $context
                        Send-File $context $tilePath
                        continue
                    }

                    $safePath = $filePath.TrimStart("/").Replace("/", "\")
                    if ([System.IO.Path]::IsPathRooted($safePath)) {
                        $context.Response.StatusCode = 403
                        $context.Response.Close()
                        continue
                    }
                    $webRoot   = [System.IO.Path]::GetFullPath($webDir)
                    $candidate = [System.IO.Path]::GetFullPath((Join-Path $webDir $safePath))
                    $sep       = [System.IO.Path]::DirectorySeparatorChar
                    if (-not $candidate.StartsWith($webRoot + $sep, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $context.Response.StatusCode = 403
                        $context.Response.Close()
                        continue
                    }

                    Send-File $context $candidate
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
