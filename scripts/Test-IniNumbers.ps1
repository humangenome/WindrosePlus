# Tests that INI numbers (tools/lib/IniConfigParser.ps1, ConvertTo-SafeDouble) read the
# same on every Windows language. The function is taken out of the file as written.
# Run: pwsh scripts/Test-IniNumbers.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$parserPath = Join-Path $root 'tools/lib/IniConfigParser.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($parserPath, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'ConvertTo-SafeDouble' }, $true) | Select-Object -First 1
if (-not $fn) { Write-Host 'FAIL ConvertTo-SafeDouble not found'; exit 1 }
$script:parserErrors = New-Object System.Collections.Generic.List[string]
function Add-WindrosePlusParserError([string]$Message) { $script:parserErrors.Add($Message) }
. ([scriptblock]::Create($fn.Extent.Text))

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

# Runs ConvertTo-SafeDouble with the thread set to a culture, in one script block
# (Windows PowerShell 5.1 resets the culture between statements at the prompt).
function Read-InCulture([string]$Culture, [string]$Value) {
    $thread = [System.Threading.Thread]::CurrentThread
    $saved = $thread.CurrentCulture
    try {
        $thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
        $shown = (1.5).ToString()
        $parsed = ConvertTo-SafeDouble $Value
        return @{ Value = $parsed; Shown = $shown }
    } finally {
        $thread.CurrentCulture = $saved
    }
}

foreach ($culture in @('en-US', 'de-DE', 'pt-BR', 'fr-FR', 'ru-RU', 'pl-PL')) {
    Case "$culture reads 0.35, 2.5, 1000, -3 and 1e-3 as written" {
        foreach ($pair in @(@('0.35', 0.35), @('2.5', 2.5), @('1000', 1000), @('-3', -3), @('1e-3', 0.001), @(' 12.75 ', 12.75))) {
            $r = Read-InCulture $culture $pair[0]
            Assert ($null -ne $r.Value -and [Math]::Abs($r.Value - $pair[1]) -lt 1e-9) "'$($pair[0])' read as '$($r.Value)'"
        }
    }
}
Case 'the culture switch takes effect (de-DE shows 1.5 as 1,5)' {
    $r = Read-InCulture 'de-DE' '1'
    Assert ($r.Shown -eq '1,5') "de-DE showed 1.5 as '$($r.Shown)'"
}
Case 'a decimal comma is read when there is no dot (0,35)' {
    $r = Read-InCulture 'en-US' '0,35'
    Assert ($r.Value -eq 0.35) "read as '$($r.Value)'"
}
Case '1,000 is refused as ambiguous' {
    $script:parserErrors.Clear()
    $r = Read-InCulture 'de-DE' '1,000'
    Assert ($null -eq $r.Value -and $script:parserErrors.Count -eq 1) "read as '$($r.Value)'"
}
Case 'text, NaN and infinity are refused' {
    foreach ($v in @('abc', 'NaN', 'Infinity', '1.2.3', '')) {
        $r = Read-InCulture 'en-US' $v
        Assert ($null -eq $r.Value) "'$v' read as '$($r.Value)'"
    }
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All INI number cases passed.'
