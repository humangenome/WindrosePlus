# Tests that error text from repak (a missing file, a warning) does not stop the
# PAK builder's helpers in tools/lib/MultiplierPakBuilder.ps1. The builder runs with
# $ErrorActionPreference = "Stop", and Windows PowerShell 5.1 turns a program's
# error output into PowerShell errors when it is captured with 2>&1.
# A small stand-in program takes the place of repak.exe.
# Windows only. Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-ToolErrorText.ps1
#                    pwsh -File scripts/Test-ToolErrorText.ps1
param([string]$LibPath = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $LibPath) { $LibPath = Join-Path $root 'tools\lib\MultiplierPakBuilder.ps1' }
. $LibPath

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-tool-errors-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# repak stand-in: "get <pak> <file>" prints a small JSON file, or for a name with
# "missing" an error on stderr and exit 1; "warn" adds a warning on stderr.
# "list <pak>" prints two file names and a warning on stderr.
$source = @'
using System;
class RepakStandIn {
    static int Main(string[] a) {
        int i = 0;
        if (a.Length > 1 && a[0] == "--aes-key") i = 2;
        string verb = a.Length > i ? a[i] : "";
        if (verb == "get") {
            string file = a.Length > i + 2 ? a[i + 2] : "";
            if (file.Contains("missing")) { Console.Error.WriteLine("Error: no file found at " + file); return 1; }
            if (file.Contains("warn")) Console.Error.WriteLine("warning: stand-in warning");
            Console.Out.WriteLine("{\"Value\": 5}");
            return 0;
        }
        if (verb == "list") {
            Console.Error.WriteLine("warning: stand-in warning");
            Console.Out.WriteLine("R5/Content/LootTables/LT_One.json");
            Console.Out.WriteLine("R5/Content/LootTables/LT_Two.json");
            return 0;
        }
        Console.Error.WriteLine("Error: unknown command");
        return 2;
    }
}
'@
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$standInSource = Join-Path $work 'repak-standin.cs'
$repakStandIn = Join-Path $work 'repak-standin.exe'
[System.IO.File]::WriteAllText($standInSource, $source)
& $csc /nologo /target:exe "/out:$repakStandIn" $standInSource | Out-Host
if (-not (Test-Path -LiteralPath $repakStandIn)) { Write-Host 'FAIL the stand-in tool did not compile'; exit 1 }

try {
    Case 'a file repak cannot find comes back as nothing, not as a stopped build' {
        $text = Invoke-RepakGet -Repak $repakStandIn -AesKey '0x00' -PakPath 'game.pak' -FilePath 'R5/missing.json'
        Assert ($null -eq $text) "returned: $text"
    }
    Case 'a warning from repak does not stop the build or end up in the file text' {
        $text = Invoke-RepakGet -Repak $repakStandIn -AesKey '0x00' -PakPath 'game.pak' -FilePath 'R5/warn.json'
        Assert ($text -and $text.Trim() -eq '{"Value": 5}') "returned: $text"
        $parsed = $text | ConvertFrom-Json
        Assert ($parsed.Value -eq 5) 'the file text did not parse'
    }
    Case 'listing files works when repak also prints a warning' {
        $files = @(Invoke-RepakList -Repak $repakStandIn -AesKey '0x00' -PakPath 'game.pak' -Filter 'LootTables')
        Assert ($files.Count -eq 2) "got $($files.Count): $($files -join ' | ')"
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All tool error text cases passed.'
