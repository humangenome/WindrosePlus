# Tests for the dashboard's server.stop_with_game watch (server/windrose_plus_server.ps1):
# the decision function is taken out of the script as written and run on fixed times.
# Also the quoting of the paths it hands to the tile and catalog builders.
# Run: pwsh scripts/Test-DashboardGameWatch.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $root 'server/windrose_plus_server.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$null, [ref]$null)
$functions = @{}
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$f.Name] = $f }

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

Case 'the decision function is in the dashboard' { Assert ($functions.ContainsKey('Get-GameWatchDecision')) 'Get-GameWatchDecision not found' }
. ([scriptblock]::Create($functions['Get-GameWatchDecision'].Extent.Text))

$t0 = Get-Date '2026-10-15 12:00'
Case 'game running: stays, and the time it was seen is kept' {
    $d = Get-GameWatchDecision -Now $t0.AddHours(2) -Started $t0 -LastSeen $null -GameState 'running'
    Assert (-not $d.Exit -and $d.LastSeen -eq $t0.AddHours(2)) "exit=$($d.Exit) lastSeen=$($d.LastSeen)"
}
Case 'game not up yet, dashboard 5 minutes old: stays (start-up grace)' {
    $d = Get-GameWatchDecision -Now $t0.AddMinutes(5) -Started $t0 -LastSeen $null -GameState 'gone'
    Assert (-not $d.Exit) 'exited during the grace period'
}
Case 'game never came up, dashboard 15 minutes old: exits' {
    $d = Get-GameWatchDecision -Now $t0.AddMinutes(15) -Started $t0 -LastSeen $null -GameState 'gone'
    Assert ($d.Exit) 'did not exit'
}
Case 'game gone 3 minutes (a restart in progress): stays' {
    $d = Get-GameWatchDecision -Now $t0.AddHours(2) -Started $t0 -LastSeen $t0.AddHours(2).AddMinutes(-3) -GameState 'gone'
    Assert (-not $d.Exit) 'exited during a short gap'
}
Case 'game gone 12 minutes after running for hours: exits' {
    $d = Get-GameWatchDecision -Now $t0.AddHours(2) -Started $t0 -LastSeen $t0.AddHours(2).AddMinutes(-12) -GameState 'gone'
    Assert ($d.Exit) 'did not exit'
}
Case 'game state unknown (path unreadable), last seen long ago: stays' {
    $d = Get-GameWatchDecision -Now $t0.AddDays(2) -Started $t0 -LastSeen $t0 -GameState 'unknown'
    Assert (-not $d.Exit) 'exited on an unknown state'
}

Case 'the path quoting function is in the dashboard' { Assert ($functions.ContainsKey('Format-ProcessPathArg')) 'Format-ProcessPathArg is missing' }
. ([scriptblock]::Create($functions['Format-ProcessPathArg'].Extent.Text))
Case 'a game folder at a drive root reaches a child process whole, and so does the next argument' {
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-arg-probe-" + [guid]::NewGuid().ToString('N') + ".ps1")
    [System.IO.File]::WriteAllText($probe, 'param([string]$GameDir, [string]$Next) [Console]::Out.Write($GameDir + "|" + $Next)')
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (Format-ProcessPathArg $probe) + ' -GameDir ' + (Format-ProcessPathArg 'D:\') + ' -Next ' + (Format-ProcessPathArg 'C:\a b')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        [void]$p.WaitForExit(30000)
        Assert ($out -eq 'D:\|C:\a b') "the child got '$out'"
    } finally {
        [System.IO.File]::Delete($probe)
    }
}

$text = [System.IO.File]::ReadAllText($serverPath)
Case 'off unless server.stop_with_game or WINDROSEPLUS_STOP_WITH_GAME is set' {
    $body = $functions['Get-StopWithGame'].Extent.Text
    Assert ($body -match 'Get-ConfigBool \$cfg\.server "stop_with_game" \$false') 'default is not false'
    $watch = $functions['Invoke-GameWatch'].Extent.Text
    Assert ($watch.IndexOf('Get-StopWithGame') -ge 0 -and $watch.IndexOf('Get-StopWithGame') -lt $watch.IndexOf('Get-GameWatchDecision')) 'the watch decides before checking the setting'
}
Case 'the request loop runs the watch between requests too, not only after an idle second' {
    $loopStart = $text.IndexOf('while ($listener.IsListening)')
    $getContext = $text.IndexOf('$listener.GetContextAsync()', [Math]::Max($loopStart, 0))
    $between = $text.Substring($loopStart, $getContext - $loopStart)
    Assert ($loopStart -ge 0 -and $getContext -gt $loopStart -and $between.Contains('Invoke-GameWatch')) 'Invoke-GameWatch is not called before each GetContextAsync'
}
Case 'the request loop runs the watch while it waits' {
    $w = $text.IndexOf('AsyncWaitHandle.WaitOne(1000)')
    $c = $text.IndexOf('            Invoke-GameWatch', [Math]::Max($w, 0))
    Assert ($w -ge 0 -and $c -gt $w -and ($c - $w) -lt 300) 'Invoke-GameWatch is not in the wait loop'
}
Case 'an unreadable process path counts as unknown, never gone' {
    $body = $functions['Get-GameState'].Extent.Text
    Assert ($body -match 'IsNullOrEmpty\(\$path\)\) \{ return "unknown" \}') 'unreadable path is not treated as unknown'
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All dashboard game-watch cases passed.'
exit 0
