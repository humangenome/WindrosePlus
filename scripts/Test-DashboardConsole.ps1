# Live test of the console's privacy rules on the dashboard route itself. The real dashboard server
# (server/windrose_plus_server.ps1) and the mod's real console worker (scripts/test-lua/console-worker.lua: the mod's
# rcon, admin and config modules with one made-up player) share a throwaway game folder, and commands go in through
# POST /api/rcon the way the dashboard page and scripts send them.
# Proves: the dashboard refuses wp.peek and wp.probe_player before any command file is written, in any spelling and
# whatever debug.show_player_ids says; the mod refuses a command file with the dashboard's id too (an older
# dashboard); commands the dashboard does run leave players' addresses and account IDs out unless
# debug.show_player_ids is true; a tool on the server itself still runs both through the command files.
# Needs Lua 5.4 (CI builds one from the lua.org source).
# Run: pwsh -File scripts/Test-DashboardConsole.ps1 -Lua <lua 5.4 interpreter>
#      powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-DashboardConsole.ps1 -Lua <lua.exe>
param([Parameter(Mandatory = $true)][string]$Lua)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$root = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $root 'server\windrose_plus_server.ps1'
$worker = Join-Path $root 'scripts\test-lua\console-worker.lua'
$exe = (Get-Process -Id $PID).Path
$password = 'Console-Pass-1234'
# The made-up player's address and account IDs (console-worker.lua)
$identity = @('203.0.113.7', '76561198000000002', '0123456789abcdef0123456789abcdef')
$hidden = '(hidden: set debug.show_player_ids to true in windrose_plus.json to show)'
$refusedText = 'is not available from the web dashboard'

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function Test-Leak([string]$Text) {
    foreach ($v in $identity) { if ($Text.Contains($v)) { return $true } }
    return $false
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p
}

$port = Get-FreePort
$base = "http://127.0.0.1:$port"
$game = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-console-test-" + [guid]::NewGuid().ToString('N'))
$data = Join-Path $game 'windrose_plus_data'
$spool = Join-Path $data 'rcon'
New-Item -ItemType Directory -Path $spool -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $data 'logs') -Force | Out-Null
$cfgPath = Join-Path $game 'windrose_plus.json'
function Write-Config([bool]$ShowIds) {
    $show = if ($ShowIds) { 'true' } else { 'false' }
    $cfg = '{"server":{"http_port":' + $port + ',"bind_ip":"127.0.0.1"},"rcon":{"enabled":true,"password":"' + $password + '"},"catalog":{"build":false},"debug":{"log_level":"info","show_player_ids":' + $show + '}}'
    [System.IO.File]::WriteAllText($cfgPath, $cfg)
}
Write-Config $false

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

$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(40)

function Start-Console([string]$Body) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), "$base/api/rcon"
    $req.Headers.Add('X-RCON-Password', $password)
    $req.Content = New-Object System.Net.Http.StringContent $Body, ([System.Text.Encoding]::UTF8), 'application/json'
    return $http.SendAsync($req)
}
function Read-Answer($Task) {
    Assert ($Task.Wait(40000)) "no answer within 40 s"
    $res = $Task.Result
    $text = $res.Content.ReadAsStringAsync().Result
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch {}
    return @{ Status = [int]$res.StatusCode; Text = $text; Json = $json }
}
function Get-SpoolCommands { return @(Get-ChildItem -LiteralPath $spool -File | Where-Object { $_.Name -like 'cmd_*' -or $_.Name -like 'pending_commands*' }) }
function Invoke-Worker {
    Push-Location $root
    try {
        $out = & $Lua $worker $game 2>&1
        if ($LASTEXITCODE -ne 0) { throw "console worker exit $LASTEXITCODE`: $($out -join "`n")" }
    } finally { Pop-Location }
}
# A command sent to the dashboard and answered by the mod's worker: waits for the dashboard's command file, runs one
# pass of the worker, then reads the dashboard's answer.
function Invoke-Console([string]$Command) {
    $task = Start-Console (@{ command = $Command } | ConvertTo-Json -Compress)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Get-ChildItem -LiteralPath $spool -Filter 'cmd_ps_*.json' -File)) {
        if ($task.IsCompleted) { return Read-Answer $task }
        Assert ([DateTime]::UtcNow -lt $deadline) "the dashboard wrote no command file for '$Command'"
        Start-Sleep -Milliseconds 100
    }
    Invoke-Worker
    return Read-Answer $task
}
# A command file a tool on the server writes itself, answered by one pass of the worker
function Invoke-Spool([string]$Id, [string]$Command, [string]$Admin) {
    $cmd = @{ id = $Id; command = $Command; args = @(); password = $password; admin_user = $Admin; timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    [System.IO.File]::WriteAllText((Join-Path $spool "cmd_$Id.json"), ($cmd | ConvertTo-Json -Compress))
    [System.IO.File]::AppendAllText((Join-Path $spool 'pending_commands.txt'), "cmd_$Id.json`r`n")
    Invoke-Worker
    $resPath = Join-Path $spool "res_$Id.json"
    Assert (Test-Path -LiteralPath $resPath) "no answer file for $Id"
    $res = [System.IO.File]::ReadAllText($resPath) | ConvertFrom-Json
    Remove-Item -LiteralPath $resPath -Force
    return $res
}

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($true) {
        try { if ($http.GetAsync("$base/api/health").Result.IsSuccessStatusCode) { break } } catch {}
        if ([DateTime]::UtcNow -gt $deadline) { throw "the dashboard did not start" }
        Start-Sleep -Milliseconds 250
    }

    $refusedBodies = @(
        '{"command":"wp.probe_player"}',
        '{"command":"wp.peek R5PlayerState UniqueId"}',
        '{"command":"wp.peek","args":["R5PlayerState","SavedNetworkAddress"]}',
        '{"command":"PEEK R5PlayerState EpicAccountId"}',
        '{"command":"  Wp.Probe_Player  "}',
        '{"command":"probe_player"}'
    )
    Case 'the dashboard refuses wp.peek and wp.probe_player before writing a command file, in any spelling' {
        foreach ($body in $refusedBodies) {
            $r = Read-Answer (Start-Console $body)
            Assert ($r.Status -eq 403) "$body got $($r.Status): $($r.Text)"
            Assert ($r.Json.status -eq 'error' -and $r.Json.message -match $refusedText -and $r.Json.error -eq $r.Json.message) "$body answer: $($r.Text)"
            Assert (-not (Test-Leak $r.Text)) "$body answer leaks: $($r.Text)"
            $left = Get-SpoolCommands
            Assert ($left.Count -eq 0) "$body left $($left.Count) file(s) in the spool: $($left.Name -join ', ')"
        }
    }

    Case 'a command the dashboard runs leaves addresses and account IDs out of its answer' {
        $r = Invoke-Console 'wp.gm ServerNote'
        Assert ($r.Status -eq 200 -and $r.Json.status -eq 'ok') "wp.gm ServerNote: $($r.Status) $($r.Text)"
        Assert ($r.Json.message -eq "ServerNote = admin at $hidden") "wp.gm ServerNote answer: $($r.Json.message)"
        $r = Invoke-Console 'wp.gm SavedNetworkAddress'
        Assert ($r.Json.message -match "holds a player's address or account ID" -and -not (Test-Leak $r.Text)) "wp.gm SavedNetworkAddress: $($r.Text)"
        $r = Invoke-Console 'wp.gm XPMultiplier'
        Assert ($r.Json.status -eq 'ok' -and $r.Json.message -eq 'XPMultiplier = 2') "an ordinary value: $($r.Text)"
    }

    Case 'a command file with the dashboard''s id is refused by the mod too' {
        $id = 'ps_' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + '_4242'
        $res = Invoke-Spool $id 'wp.probe_player' 'Dashboard'
        Assert ($res.status -eq 'error' -and $res.message -match $refusedText) "answer: $($res | ConvertTo-Json -Compress)"
        Assert (-not (Test-Leak ([string]$res.message))) "leaks: $($res.message)"
    }

    Case 'a tool on the server itself runs both commands, with addresses and account IDs hidden' {
        $res = Invoke-Spool 'tool_1' 'wp.probe_player' 'Local tool'
        Assert ($res.status -eq 'ok' -and $res.message.Contains('PlayerNamePrivate = [str] Alice')) "wp.probe_player: $($res | ConvertTo-Json -Compress)"
        Assert ($res.message.Contains("SavedNetworkAddress = $hidden") -and $res.message.Contains("UniqueId = $hidden")) "not marked hidden: $($res.message)"
        Assert (-not (Test-Leak ([string]$res.message))) "wp.probe_player leaks: $($res.message)"
        $res = Invoke-Spool 'tool_2' 'wp.peek R5PlayerState UniqueId' 'Local tool'
        Assert ($res.status -eq 'ok' -and $res.message.Contains($hidden) -and -not (Test-Leak ([string]$res.message))) "wp.peek: $($res | ConvertTo-Json -Compress)"
    }

    Case 'with debug.show_player_ids true the dashboard still refuses both, and the IDs show where commands run' {
        Write-Config $true
        try {
            foreach ($body in $refusedBodies) {
                $r = Read-Answer (Start-Console $body)
                Assert ($r.Status -eq 403 -and $r.Json.message -match $refusedText) "$body got $($r.Status): $($r.Text)"
                Assert ((Get-SpoolCommands).Count -eq 0) "$body left a command file"
            }
            $r = Invoke-Console 'wp.gm ServerNote'
            Assert ($r.Json.message -eq "ServerNote = admin at $($identity[0])") "wp.gm ServerNote with the setting on: $($r.Text)"
            $res = Invoke-Spool 'tool_3' 'wp.probe_player' 'Local tool'
            foreach ($v in $identity) { Assert ($res.message.Contains($v)) "$v not shown with the setting on: $($res.message)" }
        } finally {
            Write-Config $false
        }
    }
} finally {
    try { if (-not $server.HasExited) { $server.Kill(); [void]$server.WaitForExit(10000) } } catch {}
    if ($failed) {
        Write-Host "--- dashboard output:"
        try { Write-Host $serverOut.Result } catch {}
        try { Write-Host $serverErr.Result } catch {}
    }
    try { $http.Dispose() } catch {}
    try { Remove-Item -LiteralPath $game -Recurse -Force } catch {}
}

if ($failed) { Write-Host "$failed test(s) failed"; exit 1 }
Write-Host "All dashboard console tests passed."
