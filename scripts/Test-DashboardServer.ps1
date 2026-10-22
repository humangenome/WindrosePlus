# Live tests for the dashboard server (server/windrose_plus_server.ps1): login,
# session cookie, request limits, file caching, background tile builds and the
# public map info. Starts two copies of the real server on 127.0.0.1, each with
# its own throwaway game folder, and talks to them over HTTP.
# Windows only (the request limits use the Windows HTTP stack).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-DashboardServer.ps1   (Windows PowerShell 5.1)
#      pwsh -File scripts/Test-DashboardServer.ps1
param([string]$Shell = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $root 'server\windrose_plus_server.ps1'
$exe = if ($Shell) { $Shell } else { (Get-Process -Id $PID).Path }
$password = 'Test-Pass-1234'

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

function New-GameDir([int]$Port, [switch]$PublicMap) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-server-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $public = if ($PublicMap) { ',"livemap":{"public":{"enabled":true}}' } else { '' }
    $cfg = '{"server":{"http_port":' + $Port + ',"bind_ip":"127.0.0.1"},"rcon":{"enabled":true,"password":"' + $password + '"},"catalog":{"build":false}' + $public + '}'
    [System.IO.File]::WriteAllText((Join-Path $dir 'windrose_plus.json'), $cfg)
    # A map tile, a stand-in tile builder that takes 6 seconds, and a build status
    # with the fields the public map must not show.
    $data = Join-Path $dir 'windrose_plus_data'
    New-Item -ItemType Directory -Path (Join-Path $data 'map_tiles\0') -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $data 'map_tiles\0\0-0.png'), [byte[]](137, 80, 78, 71, 1, 2, 3))
    $tools = Join-Path $dir 'windrose_plus\tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tools 'generateTiles.ps1'), "param([string]`$GameDir)`nStart-Sleep -Seconds 6`nWrite-Host 'stand-in build done'`n")
    [System.IO.File]::WriteAllText((Join-Path $data 'map_generation_status.json'), '{"state":"error","ts":1,"script":"C:\\secret\\path\\generateTiles.ps1","error":"boom at C:\\secret","output":"tool output"}')
    return $dir
}

function Start-Dashboard([string]$GameDir, [int]$Port) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -GameDir "{1}" -Port {2} -BindIp 127.0.0.1' -f $serverScript, $GameDir, $Port)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    return @{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Port = $Port; Dir = $GameDir }
}

function Invoke-Http([string]$Method, [string]$Url, $Body = $null, [string]$ContentType = "", [hashtable]$Headers = @{}) {
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.AllowAutoRedirect = $false
    $req.Timeout = 30000
    $req.KeepAlive = $false
    foreach ($k in $Headers.Keys) { $req.Headers.Add($k, [string]$Headers[$k]) }
    if ($ContentType) { $req.ContentType = $ContentType }
    if ($null -ne $Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    $resp = $null
    try { $resp = $req.GetResponse() } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response } else { return @{ Status = 0; Body = "$($_.Exception.Message)" } }
    }
    $text = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    $r = @{ Status = [int]$resp.StatusCode; Body = $text; SetCookie = [string]$resp.Headers['Set-Cookie']; Location = [string]$resp.Headers['Location'] }
    $resp.Close()
    return $r
}

# Sends raw request bytes on a socket; returns the socket (caller reads/closes).
function Open-Raw([int]$Port, [string]$Head) {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $Port)
    $c.ReceiveTimeout = 20000
    $b = [System.Text.Encoding]::ASCII.GetBytes($Head)
    $c.GetStream().Write($b, 0, $b.Length)
    return $c
}
function Read-RawStatus($Client) {
    $buf = New-Object byte[] 4096
    try { $n = $Client.GetStream().Read($buf, 0, $buf.Length) } catch { return "closed" }
    if ($n -le 0) { return "closed" }
    $line = ([System.Text.Encoding]::ASCII.GetString($buf, 0, $n) -split "`r`n")[0]
    return $line
}

function Get-CookieValue([string]$SetCookie, [string]$Name) {
    if ($SetCookie -match ('(?:^|[,;]\s*)' + [regex]::Escape($Name) + '=([^;,]*)')) { return $Matches[1] }
    return $null
}

function Get-HexHmac([byte[]]$Key, [string]$Text) {
    $h = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try { return [System.BitConverter]::ToString($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLower() } finally { $h.Dispose() }
}

$portA = Get-FreePort; $portB = Get-FreePort
while ($portB -eq $portA) { $portB = Get-FreePort }
$dirA = New-GameDir $portA; $dirB = New-GameDir $portB -PublicMap
$a = Start-Dashboard $dirA $portA
$b = Start-Dashboard $dirB $portB
$baseA = "http://127.0.0.1:$portA"; $baseB = "http://127.0.0.1:$portB"
$nameA = "wp_session_$portA"; $nameB = "wp_session_$portB"

try {
    foreach ($base in @($baseA, $baseB)) {
        $deadline = (Get-Date).AddSeconds(60)
        while ($true) {
            $h = Invoke-Http GET "$base/api/health"
            if ($h.Status -eq 200) { break }
            if ((Get-Date) -gt $deadline) { throw "dashboard at $base did not answer /api/health in 60 s" }
            Start-Sleep -Milliseconds 500
        }
    }

    Case 'health answers routes_version 2' {
        $h = Invoke-Http GET "$baseA/api/health"
        Assert ((ConvertFrom-Json $h.Body).routes_version -eq 2) "routes_version is $((ConvertFrom-Json $h.Body).routes_version)"
    }
    Case 'no login: /api/status is refused' {
        $r = Invoke-Http GET "$baseA/api/status"
        Assert ($r.Status -eq 401) "status $($r.Status)"
    }
    Case 'wrong password: no cookie' {
        $r = Invoke-Http POST "$baseA/login" 'password=nope' 'application/x-www-form-urlencoded'
        Assert ($r.Status -eq 200 -and -not $r.SetCookie -and $r.Body -match 'Invalid password') "status $($r.Status), cookie '$($r.SetCookie)'"
    }

    $loginA = Invoke-Http POST "$baseA/login" ("password=" + [uri]::EscapeDataString($password)) 'application/x-www-form-urlencoded'
    $tokenA = Get-CookieValue $loginA.SetCookie $nameA
    $loginB = Invoke-Http POST "$baseB/login" ("password=" + [uri]::EscapeDataString($password)) 'application/x-www-form-urlencoded'
    $tokenB = Get-CookieValue $loginB.SetCookie $nameB

    Case 'login sets a cookie named after the port, HttpOnly, SameSite=Lax' {
        Assert ($loginA.Status -eq 302 -and $loginA.Location -eq '/') "status $($loginA.Status) location $($loginA.Location)"
        Assert ($tokenA) "no $nameA in '$($loginA.SetCookie)'"
        Assert ($loginA.SetCookie -match 'HttpOnly' -and $loginA.SetCookie -match 'SameSite=Lax' -and $loginA.SetCookie -match 'Max-Age=86400') "flags: $($loginA.SetCookie)"
    }
    Case 'the cookie carries a random id and nothing taken from the password' {
        $parts = $tokenA -split ':'
        Assert ($parts.Count -eq 4 -and $parts[0] -ceq 'wp2' -and $parts[1] -cmatch '^[0-9a-f]{32}$') "token shape: $tokenA"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($password))).Replace('-', '').ToLower()
        Assert ($tokenA.IndexOf($hash.Substring(0, 8)) -lt 0) 'token contains the start of the password hash'
        $again = Get-CookieValue (Invoke-Http POST "$baseA/login" "password=$password" 'application/x-www-form-urlencoded').SetCookie $nameA
        Assert ($again -and ($again -split ':')[1] -ne $parts[1]) 'two logins gave the same id'
    }
    Case 'the cookie logs in' {
        $r = Invoke-Http GET "$baseA/api/config" -Headers @{ Cookie = "$nameA=$tokenA" }
        Assert ($r.Status -eq 200) "status $($r.Status)"
    }
    Case 'two dashboards on one address keep both logins (browser sends both cookies to both)' {
        $both = "$nameA=$tokenA; $nameB=$tokenB"
        $ra = Invoke-Http GET "$baseA/api/config" -Headers @{ Cookie = $both }
        $rb = Invoke-Http GET "$baseB/api/config" -Headers @{ Cookie = $both }
        Assert ($ra.Status -eq 200 -and $rb.Status -eq 200) "A $($ra.Status), B $($rb.Status)"
    }
    Case "one dashboard's token does not open the other" {
        $r = Invoke-Http GET "$baseB/api/config" -Headers @{ Cookie = "$nameB=$tokenA" }
        Assert ($r.Status -eq 401) "status $($r.Status)"
    }
    Case 'a token sent under the old name wp_session still logs in' {
        $r = Invoke-Http GET "$baseA/api/config" -Headers @{ Cookie = "wp_session=$tokenA" }
        Assert ($r.Status -eq 200) "status $($r.Status)"
    }
    Case 'an old-format token (v1.3.24, signed with the same secret) is refused' {
        $secret = ([System.IO.File]::ReadAllText((Join-Path $dirA 'windrose_plus_data\dashboard_session.key'))).Trim()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hb = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($password))
        $epoch = '{0:x2}{1:x2}{2:x2}{3:x2}' -f $hb[0], $hb[1], $hb[2], $hb[3]
        $payload = "wp_session:${epoch}:$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        $old = "${payload}:$(Get-HexHmac ([System.Text.Encoding]::UTF8.GetBytes($secret)) $payload)"
        $r = Invoke-Http GET "$baseA/api/config" -Headers @{ Cookie = "wp_session=$old" }
        Assert ($r.Status -eq 401) "status $($r.Status)"
    }
    Case 'a changed signature is refused' {
        $last = $tokenA.Substring($tokenA.Length - 1)
        $bad = $tokenA.Substring(0, $tokenA.Length - 1) + $(if ($last -eq 'a') { 'b' } else { 'a' })
        $r = Invoke-Http GET "$baseA/api/config" -Headers @{ Cookie = "$nameA=$bad" }
        Assert ($r.Status -eq 401) "status $($r.Status)"
    }
    Case 'logged in by cookie: a POST a cross-site form could send is refused (415)' {
        foreach ($ct in @('text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data; boundary=x', '')) {
            $r = Invoke-Http POST "$baseA/api/rcon" '{"command":"wp.help"}' $ct -Headers @{ Cookie = "$nameA=$tokenA" }
            Assert ($r.Status -eq 415) "content type '$ct' got $($r.Status)"
        }
    }
    Case 'logged in by cookie: a JSON POST passes the check' {
        $r = Invoke-Http POST "$baseA/api/rcon" '{"nocommand":true}' 'application/json' -Headers @{ Cookie = "$nameA=$tokenA" }
        Assert ($r.Status -eq 400) "status $($r.Status)"
    }
    Case 'the X-RCON-Password header works with any content type' {
        $r = Invoke-Http POST "$baseA/api/rcon" '{"nocommand":true}' 'text/plain' -Headers @{ 'X-RCON-Password' = $password }
        Assert ($r.Status -eq 400) "status $($r.Status)"
    }
    Case 'a body password still works (no cookie, no header)' {
        $r = Invoke-Http POST "$baseA/api/rcon" ('{"password":"' + $password + '"}') 'application/json'
        Assert ($r.Status -eq 400) "status $($r.Status)"
    }
    Case 'an oversized login is refused before its body arrives' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $c = Open-Raw $portA "POST /login HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/x-www-form-urlencoded`r`nContent-Length: 50000000`r`n`r`n"
        $line = Read-RawStatus $c; $c.Close()
        Assert ($line -match ' 413 ' -and $sw.Elapsed.TotalSeconds -lt 5) "got '$line' after $([int]$sw.Elapsed.TotalSeconds) s"
    }
    Case 'an oversized console request without login is refused before its body arrives' {
        $c = Open-Raw $portA "POST /api/rcon HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/json`r`nContent-Length: 50000000`r`n`r`n"
        $line = Read-RawStatus $c; $c.Close()
        Assert ($line -match ' 413 ') "got '$line'"
    }
    Case 'a chunked console request is cut off at 64 KB' {
        $c = Open-Raw $portA "POST /api/rcon HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/json`r`nTransfer-Encoding: chunked`r`n`r`n"
        $chunk = [System.Text.Encoding]::ASCII.GetBytes(("2000`r`n" + ('x' * 0x2000) + "`r`n"))
        try { for ($i = 0; $i -lt 12; $i++) { $c.GetStream().Write($chunk, 0, $chunk.Length) } } catch {}
        $line = Read-RawStatus $c; $c.Close()
        Assert ($line -match ' 413 ' -or $line -eq 'closed') "got '$line'"
        $h = Invoke-Http GET "$baseA/api/health"
        Assert ($h.Status -eq 200) "dashboard not answering after: $($h.Status)"
    }
    Case 'a login that dribbles one byte a second is dropped, and other clients are answered meanwhile' {
        $c = Open-Raw $portA "POST /login HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Type: application/x-www-form-urlencoded`r`nContent-Length: 200`r`n`r`n"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $one = [byte[]](0x61)
        $dropped = $false
        $healthAt = $null
        $health = $null
        $task = (New-Object System.Net.WebClient).DownloadStringTaskAsync("$baseA/api/health")
        while ($sw.Elapsed.TotalSeconds -lt 25) {
            try { $c.GetStream().Write($one, 0, 1) } catch { $dropped = $true; break }
            if (-not $healthAt -and $task.IsCompleted) { $healthAt = $sw.Elapsed.TotalSeconds; $health = $task.Status }
            Start-Sleep -Milliseconds 1000
        }
        $droppedAt = $sw.Elapsed.TotalSeconds
        if (-not $healthAt) { [void]$task.Wait(15000); $healthAt = $sw.Elapsed.TotalSeconds; $health = $task.Status }
        $c.Close()
        Assert $dropped "the dribbling connection was still open after $([int]$droppedAt) s"
        Assert ($droppedAt -lt 16) "dropped only after $([int]$droppedAt) s"
        Assert ($health -eq 'RanToCompletion' -and $healthAt -lt 14) "the other client waited $([int]$healthAt) s ($health)"
    }
    Case 'a tile asked for with ?v= may be kept for a day, with an ETag' {
        $r = Invoke-Http GET "$baseA/livemap/tiles/0/0-0.png?v=20261021T000000Z" -Headers @{ Cookie = "$nameA=$tokenA" }
        Assert ($r.Status -eq 200) "status $($r.Status)"
        $req = [System.Net.HttpWebRequest]::Create("$baseA/livemap/tiles/0/0-0.png?v=20261021T000000Z")
        $req.Headers.Add('Cookie', "$nameA=$tokenA")
        $resp = $req.GetResponse()
        $script:tileEtag = $resp.Headers['ETag']; $cc = $resp.Headers['Cache-Control']; $resp.Close()
        Assert ($cc -eq 'public, max-age=86400') "Cache-Control '$cc'"
        Assert ($script:tileEtag -match '^"[0-9a-f]+-[0-9a-f]+"$') "ETag '$($script:tileEtag)'"
    }
    Case 'the same tile again with its ETag answers 304 and no body' {
        $r = Invoke-Http GET "$baseA/livemap/tiles/0/0-0.png?v=20261021T000000Z" -Headers @{ Cookie = "$nameA=$tokenA"; 'If-None-Match' = $script:tileEtag }
        Assert ($r.Status -eq 304 -and $r.Body.Length -eq 0) "status $($r.Status), $($r.Body.Length) bytes"
    }
    Case 'a tile asked for without ?v= is checked back each time' {
        $req = [System.Net.HttpWebRequest]::Create("$baseA/livemap/tiles/0/0-0.png")
        $req.Headers.Add('Cookie', "$nameA=$tokenA")
        $resp = $req.GetResponse(); $cc = $resp.Headers['Cache-Control']; $resp.Close()
        Assert ($cc -eq 'no-cache') "Cache-Control '$cc'"
    }
    Case 'the public map info shows the build state but not its path or output' {
        $r = Invoke-Http GET "$baseB/api/public/mapinfo"
        Assert ($r.Status -eq 503) "status $($r.Status)"
        Assert ($r.Body -match '"state":"error"') "body $($r.Body)"
        Assert ($r.Body -notmatch 'secret' -and $r.Body -notmatch 'tool output') "body $($r.Body)"
    }
    Case 'a tile build runs beside the dashboard, which keeps answering' {
        $statusPath = Join-Path $dirA 'windrose_plus_data\map_generation_status.json'
        [System.IO.File]::WriteAllText((Join-Path $dirA 'windrose_plus_data\generate_tiles_trigger'), '1')
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline -and -not ([System.IO.File]::ReadAllText($statusPath) -match '"running"')) { Start-Sleep -Milliseconds 200 }
        Assert ([System.IO.File]::ReadAllText($statusPath) -match '"running"') 'the build did not start'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $h = Invoke-Http GET "$baseA/api/health"
        Assert ($h.Status -eq 200 -and $sw.Elapsed.TotalSeconds -lt 2) "health took $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s during the build"
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not ([System.IO.File]::ReadAllText($statusPath) -match '"complete"')) { Start-Sleep -Milliseconds 500 }
        $st = [System.IO.File]::ReadAllText($statusPath)
        Assert ($st -match '"complete"' -and $st -match 'stand-in build done') "status: $st"
    }
    Case 'the console audit feed lists the commands from the activity log' {
        $logDir = Join-Path $dirA 'windrose_plus_data\logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        # Each line in parentheses: a comma binds tighter than + in PowerShell.
        $lines = @(
            ('{"ts":"x","ts_unix":' + ($now - 20) + ',"sid":"s","ev":"player.join","payload":{"name":"A"}}'),
            ('{"ts":"x","ts_unix":' + ($now - 10) + ',"sid":"s","ev":"admin.command","payload":{"command":"wp.status","admin_user":"Dashboard","status":"ok"}}'),
            ('{"ts":"x","ts_unix":' + ($now - 5) + ',"sid":"s","ev":"admin.command","payload":{"command":"wp.say J' + [char]0x00F6 + 'rg ahoy","admin_user":"Dashboard","status":"error"}}')
        )
        [System.IO.File]::WriteAllText((Join-Path $logDir ([DateTime]::UtcNow.ToString('yyyy-MM-dd') + '.log')), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-Http GET "$baseA/api/rcon/log" -Headers @{ Cookie = "$nameA=$tokenA" }
        Assert ($r.Status -eq 200) "status $($r.Status)"
        $list = @($r.Body | ConvertFrom-Json | ForEach-Object { $_ })
        Assert ($list.Count -eq 2) "$($list.Count) entries: $($r.Body)"
        Assert ($list[0].command -eq 'wp.status' -and $list[1].status -eq 'error' -and $list[1].ip -eq 'Dashboard') "entries: $($r.Body)"
        Assert ($list[1].command -eq ('wp.say J' + [char]0x00F6 + 'rg ahoy')) "non-English text came back as '$($list[1].command)'"
    }
    Case 'non-English names in data files come back as written' {
        $name = 'J' + [char]0x00F6 + 'rg ' + [char]0x0421 + [char]0x0435 + [char]0x0440 + [char]0x0433 + [char]0x0435 + [char]0x0439
        [System.IO.File]::WriteAllText((Join-Path $dirA 'windrose_plus_data\server_status.json'), ('{"players":[{"name":"' + $name + '"}]}'), (New-Object System.Text.UTF8Encoding($false)))
        $req = [System.Net.HttpWebRequest]::Create("$baseA/api/status")
        $req.Headers.Add('Cookie', "$nameA=$tokenA")
        $resp = $req.GetResponse()
        $body = (New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)).ReadToEnd(); $resp.Close()
        $got = ($body | ConvertFrom-Json).players[0].name
        Assert ($got -eq $name) "got '$got'"
    }
    Case 'with rcon.enabled off a console command is refused at once' {
        $cfgPath = Join-Path $dirB 'windrose_plus.json'
        $saved = [System.IO.File]::ReadAllText($cfgPath)
        [System.IO.File]::WriteAllText($cfgPath, $saved.Replace('"enabled":true,"password"', '"enabled":false,"password"'))
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-Http POST "$baseB/api/rcon" '{"command":"wp.ping"}' 'application/json' -Headers @{ 'X-RCON-Password' = $password }
            Assert ($r.Status -eq 503 -and $r.Body -match 'switched off' -and $sw.Elapsed.TotalSeconds -lt 3) "status $($r.Status) after $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s: $($r.Body)"
        } finally {
            [System.IO.File]::WriteAllText($cfgPath, $saved)
        }
    }
    Case 'a command nobody answers is withdrawn when the dashboard gives up' {
        $r = Invoke-Http POST "$baseA/api/rcon" '{"command":"wp.ping"}' 'application/json' -Headers @{ 'X-RCON-Password' = $password }
        Assert ($r.Status -eq 504 -and $r.Body -match 'withdrawn') "status $($r.Status): $($r.Body)"
        $left = @(Get-ChildItem -LiteralPath (Join-Path $dirA 'windrose_plus_data\rcon') -Filter 'cmd_*.json' -File -ErrorAction SilentlyContinue)
        Assert ($left.Count -eq 0) "$($left.Count) command file(s) left in the spool"
    }
    Case 'logout clears the cookie' {
        $r = Invoke-Http GET "$baseA/logout" -Headers @{ Cookie = "$nameA=$tokenA" }
        Assert ($r.Status -eq 302 -and $r.Location -eq '/login') "status $($r.Status) location $($r.Location)"
        Assert ($r.SetCookie -match ([regex]::Escape($nameA) + '=;') -and $r.SetCookie -match 'Max-Age=0') "set-cookie '$($r.SetCookie)'"
    }
    Case 'changing the password ends the session' {
        $cfgPath = Join-Path $dirA 'windrose_plus.json'
        $text = [System.IO.File]::ReadAllText($cfgPath)
        [System.IO.File]::WriteAllText($cfgPath, $text.Replace($password, 'Another-Pass-5678'))
        $r = Invoke-Http GET "$baseA/api/config" -Headers @{ Cookie = "$nameA=$tokenA" }
        Assert ($r.Status -eq 401) "status $($r.Status)"
    }
} finally {
    foreach ($d in @($a, $b)) {
        try { if (-not $d.Process.HasExited) { $d.Process.Kill(); [void]$d.Process.WaitForExit(10000) } } catch {}
        if ($failed) {
            Write-Host "--- dashboard on port $($d.Port) output:"
            try { Write-Host $d.Out.Result } catch {}
            try { Write-Host $d.Err.Result } catch {}
        }
        try { Remove-Item -LiteralPath $d.Dir -Recurse -Force } catch {}
    }
}

if ($failed) { Write-Host "$failed test(s) failed"; exit 1 }
Write-Host "All dashboard server tests passed."
