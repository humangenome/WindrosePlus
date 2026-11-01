# Tests install.ps1 on a made-up server folder whose name has brackets, a space and
# a non-English letter: a first install, a reinstall that keeps what the owner changed,
# and the files it writes. No download: the folder already has a UE4SS loader, so the
# installer runs with -KeepCurrentUE4SS. tools\bin stays empty, as in a git checkout,
# so the "build tools missing" warning is expected here.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-Installer.ps1
#      pwsh -File scripts/Test-Installer.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = (Get-Process -Id $PID).Path

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

$parent = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-install-test-" + [guid]::NewGuid().ToString('N'))
$game = Join-Path $parent ('[EU] J' + [char]0x00F6 + 'rg server')
$win64 = Join-Path $game 'R5\Binaries\Win64'
$ue4ss = Join-Path $win64 'ue4ss'
$modsDir = Join-Path $ue4ss 'Mods'
[void][System.IO.Directory]::CreateDirectory($modsDir)
[System.IO.File]::WriteAllText((Join-Path $win64 'dwmapi.dll'), 'stand-in')
[System.IO.File]::WriteAllText((Join-Path $ue4ss 'UE4SS.dll'), 'stand-in')

# The sample mods UE4SS ships switched on, and a diagnostic mod left on by an old install.
$modsTxt = Join-Path $modsDir 'mods.txt'
[System.IO.File]::WriteAllText($modsTxt, "CheatManagerEnablerMod : 1`r`nKeybinds : 1`r`nWindroseNativeProbe : 1`r`n")
$probeDir = Join-Path $modsDir 'WindroseNativeProbe'
[void][System.IO.Directory]::CreateDirectory($probeDir)
[System.IO.File]::WriteAllText((Join-Path $probeDir 'enabled.txt'), '1')

# What the release zip unpacks into the server folder.
foreach ($name in @('WindrosePlus', 'server', 'tools', 'config')) {
    [System.IO.Directory]::GetFiles((Join-Path $root $name), '*', [System.IO.SearchOption]::AllDirectories) | ForEach-Object {
        $rel = $_.Substring($root.Length + 1)
        $dest = Join-Path $game $rel
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $dest))
        [System.IO.File]::Copy($_, $dest, $true)
    }
}
foreach ($name in @('install.ps1', 'UE4SS-settings.ini')) {
    [System.IO.File]::Copy((Join-Path $root $name), (Join-Path $game $name), $true)
}
$fakeDll = Join-Path $game 'cpp-mods\HeightmapExporter\HeightmapExporter.dll'
[void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $fakeDll))
[System.IO.File]::WriteAllText($fakeDll, 'stand-in')

function Invoke-Installer {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $game 'install.ps1') + '" -KeepCurrentUE4SS'
    $psi.WorkingDirectory = $game
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch {}; throw 'the installer did not finish in 2 minutes' }
    return @{ Code = $p.ExitCode; Output = ($out.Result + $err.Result) }
}

$modDest = Join-Path $modsDir 'WindrosePlus'
$wpDir = Join-Path $game 'windrose_plus'

try {
    $first = Invoke-Installer
    Case 'a folder with brackets and a non-English letter installs' {
        Assert ($first.Code -eq 0) "exit $($first.Code): $($first.Output)"
        Assert ($first.Output -match 'Windrose\+ installed') "no finish line: $($first.Output)"
    }
    Case 'the mod, the dashboard and the tools are in place' {
        foreach ($p in @(
            (Join-Path $modDest 'Scripts\main.lua'),
            (Join-Path $wpDir 'server\windrose_plus_server.ps1'),
            (Join-Path $wpDir 'tools\generateTiles.ps1'),
            (Join-Path $wpDir 'config\windrose_plus.default.ini'),
            (Join-Path $ue4ss 'UE4SS-settings.ini'),
            (Join-Path $modsDir 'HeightmapExporter\dlls\main.dll'),
            (Join-Path $game 'StartWindrosePlusServer.bat')
        )) { Assert ([System.IO.File]::Exists($p)) "missing $p" }
    }
    Case 'mods.txt: the mod and the exporter on, sample mods off, the diagnostic mod gone' {
        $t = [System.IO.File]::ReadAllText($modsTxt)
        Assert ($t -match '(?m)^WindrosePlus : 1') "no WindrosePlus line: $t"
        Assert ($t -match '(?m)^HeightmapExporter : 1') "no HeightmapExporter line: $t"
        Assert ($t -match '(?m)^CheatManagerEnablerMod : 0') "sample mod not off: $t"
        Assert ($t -match '(?m)^Keybinds : 0') "sample mod not off: $t"
        Assert ($t -notmatch 'WindroseNativeProbe') "diagnostic mod still listed: $t"
        Assert (-not [System.IO.File]::Exists((Join-Path $probeDir 'enabled.txt'))) 'diagnostic mod still enabled'
    }
    Case 'the dashboard launcher finds the game folder from where it sits' {
        $bat = [System.IO.File]::ReadAllText((Join-Path $wpDir 'start_dashboard.bat'))
        Assert ($bat.Contains('-GameDir "%~dp0.."')) "launcher: $bat"
        Assert (-not $bat.Contains('[EU]')) "the folder name is written into the launcher: $bat"
    }
    Case 'the server wrapper is plain ASCII and calls the PAK builder' {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $game 'StartWindrosePlusServer.bat'))
        Assert (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'non-ASCII bytes in the wrapper'
        Assert ([System.Text.Encoding]::ASCII.GetString($bytes).Contains('WindrosePlus-BuildPak.ps1')) 'no PAK build step'
    }

    # What an owner changes between installs.
    $luaMods = Join-Path $modDest 'Mods'
    $myMod = Join-Path $luaMods 'my-mod'
    [void][System.IO.Directory]::CreateDirectory($myMod)
    [System.IO.File]::WriteAllText((Join-Path $myMod 'mod.json'), '{"name":"Mine","main":"init.lua"}')
    [System.IO.File]::WriteAllText((Join-Path $myMod 'init.lua'), '-- mine')
    [System.IO.File]::WriteAllText((Join-Path $game 'windrose_plus.json'), '{"rcon":{"enabled":true,"password":"keep-me"}}')
    [System.IO.File]::WriteAllText((Join-Path $game 'windrose_plus.ini'), '[PlayerStats]')
    [System.IO.File]::WriteAllText((Join-Path $wpDir 'config\windrose_plus.default.ini'), 'old defaults')
    [System.IO.File]::WriteAllText((Join-Path $modDest 'Scripts\leftover.lua'), '-- from an older version')

    $second = Invoke-Installer
    Case 'a reinstall finishes' {
        Assert ($second.Code -eq 0) "exit $($second.Code): $($second.Output)"
    }
    Case 'a reinstall keeps the config, the INI and the owner''s Lua mod' {
        Assert ([System.IO.File]::ReadAllText((Join-Path $game 'windrose_plus.json')).Contains('keep-me')) 'config was changed'
        Assert ([System.IO.File]::Exists((Join-Path $game 'windrose_plus.ini'))) 'INI is gone'
        Assert ([System.IO.File]::Exists((Join-Path $myMod 'init.lua'))) 'the Lua mod is gone'
    }
    Case 'a reinstall refreshes the scripts and the default INI' {
        Assert (-not [System.IO.File]::Exists((Join-Path $modDest 'Scripts\leftover.lua'))) 'old script left behind'
        Assert ([System.IO.File]::Exists((Join-Path $modDest 'Scripts\main.lua'))) 'main.lua is gone'
        Assert (-not [System.IO.File]::ReadAllText((Join-Path $wpDir 'config\windrose_plus.default.ini')).Contains('old defaults')) 'default INI not refreshed'
    }
    $registry = Join-Path $luaMods 'mods_registry.json'
    Case 'a reinstall lists the owner''s Lua mod in mods_registry.json, without the example' {
        Assert ([System.IO.File]::Exists($registry)) 'no mods_registry.json'
        # Through a variable: Windows PowerShell 5.1 hands a JSON array down a pipe as one object.
        $parsed = [System.IO.File]::ReadAllText($registry) | ConvertFrom-Json
        $listed = @($parsed | ForEach-Object { [string]$_ })
        Assert ($listed -contains 'my-mod') "listed: $listed"
        Assert ($listed -notcontains 'example-welcome') "listed: $listed"
    }
    Case 'a reinstall does not turn a sample mod back on' {
        Assert ([System.IO.File]::ReadAllText($modsTxt) -match '(?m)^Keybinds : 0') 'Keybinds is on again'
    }

    # A list the owner edited stays as it is, and a mod left out of it is named.
    [System.IO.File]::WriteAllText($registry, '[]')
    $third = Invoke-Installer
    Case 'a reinstall keeps an edited mods_registry.json and names the mod left out' {
        Assert ($third.Code -eq 0) "exit $($third.Code): $($third.Output)"
        Assert ([System.IO.File]::ReadAllText($registry).Trim() -eq '[]') 'the list was rewritten'
        Assert ($third.Output -match 'not loaded: my-mod') "no mention of my-mod: $($third.Output)"
    }
} finally {
    try { [System.IO.Directory]::Delete($parent, $true) } catch {}
}

if ($failed) { Write-Host "$failed test(s) failed"; exit 1 }
Write-Host "All installer tests passed."
