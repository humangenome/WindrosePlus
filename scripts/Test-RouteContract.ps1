# Route contract: starts the real dashboard server (server/windrose_plus_server.ps1) on a copy of the made-up
# game folder in scripts/contract/fixture/game and checks every route in server/routes.json against
# scripts/contract/routes-contract.json: status with and without a login, content type, redirects, the fields
# of each JSON answer. A route with no entry in the contract fails, so a new route cannot ship unchecked.
# A stand-in for the mod answers console commands through the spool (rcon\cmd_*.json -> res_*.json).
# -ResponsesDir keeps the JSON answers marked "save" for scripts/contract/check-data-files.py --partial.
# Windows only (the dashboard uses the Windows HTTP stack).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-RouteContract.ps1   (Windows PowerShell 5.1)
#      pwsh -File scripts/Test-RouteContract.ps1 -ResponsesDir <folder>
param([string]$ResponsesDir = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $root 'server\windrose_plus_server.ps1'
$contract = [System.IO.File]::ReadAllText((Join-Path $root 'scripts\contract\routes-contract.json')) | ConvertFrom-Json
$routes = [System.IO.File]::ReadAllText((Join-Path $root 'server\routes.json')) | ConvertFrom-Json
$exe = (Get-Process -Id $PID).Path
$password = 'contract-pass-123'
$mapToken = 'contract-map-token'

$failed = 0
$passed = 0
function Fail([string]$Msg) { $script:failed++; Write-Host "FAIL $Msg" }
function Pass([string]$Msg) { $script:passed++; Write-Host "ok   $Msg" }

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

# ---------------------------------------------------------------- the game folder
$game = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-contract-" + [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath (Join-Path $root 'scripts\contract\fixture\game') -Destination $game -Recurse
# the audit feed reads today's and yesterday's activity log (UTC day names)
$logs = Join-Path $game 'windrose_plus_data\logs'
Move-Item -LiteralPath (Join-Path $logs 'activity.log') -Destination (Join-Path $logs ([DateTime]::UtcNow.ToString('yyyy-MM-dd') + '.log'))
New-Item -ItemType Directory -Path (Join-Path $game 'windrose_plus_data\rcon') -Force | Out-Null
if ($ResponsesDir) { New-Item -ItemType Directory -Path $ResponsesDir -Force | Out-Null }

$port = Get-FreePort
$base = "http://127.0.0.1:$port"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -GameDir "{1}" -Port {2} -BindIp 127.0.0.1' -f $serverScript, $game, $port)
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$server = [System.Diagnostics.Process]::Start($psi)
$serverOut = $server.StandardOutput.ReadToEndAsync()
$serverErr = $server.StandardError.ReadToEndAsync()

# ---------------------------------------------------------------- a stand-in for the mod's console worker
$responder = Start-Job -ArgumentList (Join-Path $game 'windrose_plus_data\rcon') -ScriptBlock {
    param($spool)
    $until = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $until) {
        $index = Join-Path $spool 'pending_commands.txt'
        $batch = Join-Path $spool 'pending_commands.processing'
        if (Test-Path -LiteralPath $index) {
            try { Move-Item -LiteralPath $index -Destination $batch -Force } catch { Start-Sleep -Milliseconds 100; continue }
            foreach ($name in ([System.IO.File]::ReadAllText($batch) -split "`r?`n")) {
                $name = $name.Trim()
                if ($name -notmatch '^cmd_[A-Za-z0-9_-]+\.json$') { continue }
                $cmdPath = Join-Path $spool $name
                if (-not (Test-Path -LiteralPath $cmdPath)) { continue }
                $cmd = [System.IO.File]::ReadAllText($cmdPath) | ConvertFrom-Json
                $answer = '{"id":"' + $cmd.id + '","status":"ok","message":"stand-in answer to ' + $cmd.command + '","timestamp":' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + '}'
                $res = Join-Path $spool ('res_' + $cmd.id + '.json')
                [System.IO.File]::WriteAllText($res + '.tmp', $answer)
                Move-Item -LiteralPath ($res + '.tmp') -Destination $res -Force
                Remove-Item -LiteralPath $cmdPath -Force
            }
            Remove-Item -LiteralPath $batch -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-Http([string]$Method, [string]$Url, [string]$Body, [string]$ContentType, [hashtable]$Headers) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.AllowAutoRedirect = $false
    $req.Timeout = 40000
    $req.KeepAlive = $false
    foreach ($k in $Headers.Keys) { $req.Headers.Add($k, [string]$Headers[$k]) }
    if ($ContentType) { $req.ContentType = $ContentType }
    if ($Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    } elseif ($Method -eq 'POST') {
        $req.ContentLength = 0
    }
    $resp = $null
    try { $resp = $req.GetResponse() } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response } else { return @{ Status = 0; Body = "$($_.Exception.Message)"; Headers = @{} } }
    }
    $ms = New-Object System.IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $headersOut = @{}
    foreach ($h in $resp.Headers.AllKeys) { $headersOut[$h] = [string]$resp.Headers[$h] }
    $r = @{ Status = [int]$resp.StatusCode; Body = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()); Bytes = $ms.ToArray(); Headers = $headersOut; ContentType = [string]$resp.ContentType }
    $resp.Close()
    return $r
}

$types = @{
    json = '^application/json'; html = '^text/html'; png = '^image/png'; webp = '^image/webp'
    js = '^(application|text)/javascript'; css = '^text/css'
}

try {
    $deadline = (Get-Date).AddSeconds(60)
    while ($true) {
        $h = Invoke-Http GET "$base/api/health" '' '' @{}
        if ($h.Status -eq 200) { break }
        if ((Get-Date) -gt $deadline) { throw "the dashboard did not answer /api/health in 60 s" }
        Start-Sleep -Milliseconds 500
    }

    # a dashboard session for the "cookie" checks
    $login = Invoke-Http POST "$base/login" ("password=" + [uri]::EscapeDataString($password)) 'application/x-www-form-urlencoded' @{}
    $cookieName = "wp_session_$port"
    $cookie = $null
    if ([string]$login.Headers['Set-Cookie'] -match ([regex]::Escape($cookieName) + '=([^;,]+)')) { $cookie = $Matches[1] }
    if (-not $cookie) { throw "could not log in to the dashboard (status $($login.Status))" }

    $fill = {
        param([string]$Text)
        return $Text.Replace('{password}', $password).Replace('{token}', $mapToken).Replace('{port}', [string]$port).Replace('{routes_version}', [string]$routes.routes_version)
    }

    # every route in routes.json has an entry in the contract, and nothing else does
    $routePaths = @($routes.routes | ForEach-Object { $_.path })
    $contractPaths = @($contract.routes.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($p in $routePaths) { if ($contractPaths -notcontains $p) { Fail "route $p has no entry in scripts/contract/routes-contract.json" } }
    foreach ($p in $contractPaths) { if ($routePaths -notcontains $p) { Fail "the contract names $p, which server/routes.json does not list" } }

    foreach ($entry in $contract.routes.PSObject.Properties) {
        $route = $routes.routes | Where-Object { $_.path -eq $entry.Name } | Select-Object -First 1
        $sawAnonymous = $false
        foreach ($check in @($entry.Value)) {
            $parts = ([string]$check.request) -split ' ', 2
            $method = $parts[0]; $target = & $fill $parts[1]
            $label = "$($check.request) [$($check.login)]"
            if ($route -and @($route.methods) -notcontains $method -and -not ($check.status -eq 405)) {
                Fail "$label uses $method, which routes.json does not list for $($entry.Name)"
            }
            $headers = @{}
            switch ([string]$check.login) {
                'cookie' { $headers['Cookie'] = "$cookieName=$cookie" }
                'header' { $headers['X-RCON-Password'] = $password }
                default { $sawAnonymous = $true }
            }
            $body = if ($check.body) { & $fill ([string]$check.body) } else { '' }
            $r = Invoke-Http $method ($base + $target) $body ([string]$check.content_type) $headers
            $problems = New-Object System.Collections.Generic.List[string]

            $wanted = @($check.status | ForEach-Object { [int]$_ })
            if ($wanted -notcontains $r.Status) { $problems.Add("status $($r.Status), expected $($wanted -join ' or ')") }
            if ($check.type -and $r.Status -lt 300) {
                if ($r.ContentType -notmatch $types[[string]$check.type]) { $problems.Add("content type '$($r.ContentType)', expected $($check.type)") }
            }
            if ($check.location) {
                $loc = [string]$r.Headers['Location']
                if ($loc -ne [string]$check.location -and -not $loc.EndsWith([string]$check.location)) { $problems.Add("redirects to '$loc', expected $($check.location)") }
            }
            if ($check.headers_contain) {
                foreach ($hp in $check.headers_contain.PSObject.Properties) {
                    $want = & $fill ([string]$hp.Value)
                    if (-not ([string]$r.Headers[$hp.Name]).Contains($want)) { $problems.Add("header $($hp.Name) '$($r.Headers[$hp.Name])' lacks '$want'") }
                }
            }
            if ($check.no_cookie -and $r.Headers['Set-Cookie']) { $problems.Add("set a cookie: $($r.Headers['Set-Cookie'])") }
            foreach ($s in @($check.contains)) { if ($s -and -not $r.Body.Contains((& $fill ([string]$s)))) { $problems.Add("body lacks '$s'") } }
            foreach ($s in @($check.absent)) { if ($s -and $r.Body.Contains((& $fill ([string]$s)))) { $problems.Add("body contains '$s'") } }
            if ($check.type -eq 'json' -and $r.Status -ne 304) {
                $doc = $null
                try { $doc = $r.Body | ConvertFrom-Json } catch { $problems.Add("body is not JSON: $($r.Body.Substring(0, [Math]::Min(120, $r.Body.Length)))") }
                if ($null -ne $doc) {
                    if ($check.array -and -not ($r.Body.TrimStart().StartsWith('['))) { $problems.Add("expected a JSON array") }
                    foreach ($f in @($check.fields)) {
                        if ($f -and -not ($doc.PSObject.Properties.Name -contains $f)) { $problems.Add("answer lacks field '$f'") }
                    }
                    if ($check.equals) {
                        foreach ($ep in $check.equals.PSObject.Properties) {
                            if ([string]$doc.($ep.Name) -ne (& $fill ([string]$ep.Value))) { $problems.Add("$($ep.Name) is '$($doc.($ep.Name))', expected '$(& $fill ([string]$ep.Value))'") }
                        }
                    }
                }
            }
            if ($check.save -and $ResponsesDir -and $r.Status -eq 200) {
                [System.IO.File]::WriteAllBytes((Join-Path $ResponsesDir ([string]$check.save)), $r.Bytes)
            }
            if ($problems.Count) { Fail ("$label : " + ($problems -join '; ')) } else { Pass $label }
        }
        if (-not $sawAnonymous) { Fail "$($entry.Name) has no check without a login" }
    }

    # cross-origin preflight answers on any path
    $o = Invoke-Http OPTIONS "$base/api/status" '' '' @{ 'Origin' = 'http://example.test' }
    if ($o.Status -eq 200 -and $o.Headers['Access-Control-Allow-Origin'] -eq '*') { Pass 'OPTIONS preflight answers 200 with Access-Control-Allow-Origin *' }
    else { Fail "OPTIONS preflight: status $($o.Status), allow-origin '$($o.Headers['Access-Control-Allow-Origin'])'" }
} catch {
    Fail "the contract run stopped: $($_.Exception.Message)"
} finally {
    try { if (-not $server.HasExited) { $server.Kill(); [void]$server.WaitForExit(10000) } } catch {}
    try { Stop-Job $responder -ErrorAction SilentlyContinue; Remove-Job $responder -Force -ErrorAction SilentlyContinue } catch {}
    if ($failed) {
        Write-Host "--- dashboard output:"
        try { Write-Host $serverOut.Result } catch {}
        try { Write-Host $serverErr.Result } catch {}
    }
    try { Remove-Item -LiteralPath $game -Recurse -Force } catch {}
}

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 }
