# Tests for Invoke-RepairTool in server/windrose_plus_server.ps1, the step of the
# Character Repair page that runs windrose-heal.exe on an uploaded save zip.
# A small stand-in console program takes the place of windrose-heal.exe: it records
# the arguments it was given, then answers, fails or hangs depending on the upload.
# The timeout case checks that a hung tool is ended, not left running with the
# upload open.
# Windows only. Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-RepairTool.ps1
#                    pwsh -File scripts/Test-RepairTool.ps1
param([string]$ServerScript = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ServerScript) { $ServerScript = Join-Path $root 'server\windrose_plus_server.ps1' }

$ast = [System.Management.Automation.Language.Parser]::ParseFile($ServerScript, [ref]$null, [ref]$null)
$wanted = @('Invoke-RepairTool', 'ConvertTo-RepairToolArgument')
$functions = @($ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $args[0].Name
}, $true))
if (-not ($functions | Where-Object { $_.Name -eq 'Invoke-RepairTool' })) { Write-Host 'FAIL Invoke-RepairTool not found in the server script'; exit 1 }
foreach ($fn in $functions) { . ([scriptblock]::Create($fn.Extent.Text)) }

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

# A folder with a space, brackets and a non-English letter, like a real server folder.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-repair-test-" + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $work "[EU] Mein Server $([char]0x00FC)"
New-Item -ItemType Directory -Path $dir -Force | Out-Null

# The stand-in: compiled once with the .NET Framework compiler every Windows has.
$source = @'
using System;
using System.IO;
using System.Threading;
class StandIn {
    static int Main(string[] a) {
        string input = null, output = null;
        for (int i = 0; i < a.Length - 1; i++) {
            if (a[i] == "--input") input = a[i + 1];
            if (a[i] == "--output") output = a[i + 1];
        }
        if (input == null || output == null) { Console.Error.WriteLine("Error: no --input or --output"); return 9; }
        File.WriteAllLines(output + ".args.txt", a);
        string mode = File.ReadAllText(input).Trim();
        if (mode == "HANG") {
            using (var held = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.Read)) { Thread.Sleep(120000); }
            return 0;
        }
        Console.Out.WriteLine("=== Repair applied ===");
        Console.Error.WriteLine("WARN stand-in warning line");
        if (mode == "OK") { File.WriteAllText(output, "PK stand-in"); return 0; }
        Console.Error.WriteLine("Error: no repairable progression drift found");
        return 2;
    }
}
'@
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$standInDir = Join-Path $work 'tool'
New-Item -ItemType Directory -Path $standInDir -Force | Out-Null
$standInSource = Join-Path $standInDir 'standin.cs'
$standIn = Join-Path $standInDir 'windrose-heal-standin.exe'
[System.IO.File]::WriteAllText($standInSource, $source)
& $csc /nologo /target:exe "/out:$standIn" $standInSource | Out-Host
if (-not (Test-Path -LiteralPath $standIn)) { Write-Host 'FAIL the stand-in tool did not compile'; exit 1 }

function New-Upload([string]$Mode) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $upload = Join-Path $dir "repair_$id-upload.zip"
    [System.IO.File]::WriteAllText($upload, $Mode)
    return @{ Upload = $upload; Output = (Join-Path $dir "repair_$id-repaired.zip"); Audit = (Join-Path $dir 'character_repair_audit.log') }
}
function Get-StandInProcesses {
    @(Get-Process -Name 'windrose-heal-standin' -ErrorAction SilentlyContinue)
}

try {
    Case 'a repair that works returns exit 0, both output streams and the repaired zip' {
        $f = New-Upload 'OK'
        $r = Invoke-RepairTool $standIn $f.Audit $f.Upload $f.Output 30
        Assert ($r.ExitCode -eq 0) "exit code $($r.ExitCode), output: $($r.Output)"
        Assert ($r.Output -match 'Repair applied') "stdout missing: $($r.Output)"
        Assert ($r.Output -match 'stand-in warning line') "stderr missing: $($r.Output)"
        Assert (Test-Path -LiteralPath $f.Output) 'repaired zip missing'
    }

    Case 'the tool gets every argument whole, in a folder with a space, brackets and a non-English letter' {
        $f = New-Upload 'OK'
        $null = Invoke-RepairTool $standIn $f.Audit $f.Upload $f.Output 30
        $got = @([System.IO.File]::ReadAllLines($f.Output + '.args.txt'))
        $want = @('--log-level', 'warn', '--audit-log', $f.Audit, 'repair-zip', '--input', $f.Upload, '--output', $f.Output, '--strategy', 'safe')
        Assert ($got.Count -eq $want.Count) "got $($got.Count) arguments: $($got -join ' | ')"
        for ($i = 0; $i -lt $want.Count; $i++) {
            Assert ($got[$i] -ceq $want[$i]) "argument $i is '$($got[$i])', expected '$($want[$i])'"
        }
    }

    Case 'a repair that finds nothing returns the exit code and the error text' {
        $f = New-Upload 'NOTHING'
        $r = Invoke-RepairTool $standIn $f.Audit $f.Upload $f.Output 30
        Assert ($r.ExitCode -eq 2) "exit code $($r.ExitCode)"
        Assert ($r.Output -match 'no repairable progression drift') "error text missing: $($r.Output)"
        Assert (-not (Test-Path -LiteralPath $f.Output)) 'a repaired zip was written'
    }

    Case 'a hung tool is ended at the timeout and the upload can be deleted' {
        $before = @(Get-StandInProcesses).Count
        $f = New-Upload 'HANG'
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-RepairTool $standIn $f.Audit $f.Upload $f.Output 3
        $took = $clock.Elapsed.TotalSeconds
        Assert ($r.ExitCode -eq -1) "exit code $($r.ExitCode)"
        Assert ($r.Output -match 'timed out') "output: $($r.Output)"
        Assert ($took -lt 20) "took $([int]$took) s"
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-StandInProcesses).Count -gt $before -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        $left = (Get-StandInProcesses).Count - $before
        Assert ($left -le 0) "$left stand-in process(es) still running 5 s after the timeout"
        Remove-Item -LiteralPath $f.Upload -Force
        Assert (-not (Test-Path -LiteralPath $f.Upload)) 'the upload could not be deleted'
    }
} finally {
    Get-StandInProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All repair tool cases passed.'
