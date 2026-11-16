# Tests that INI numbers (tools/lib/IniConfigParser.ps1, ConvertTo-SafeDouble) read the
# same on every Windows language. The function is taken out of the file as written.
# Also windrose_plus.harvest.ini numbers (Read-HarvestIni in tools/lib/MultiplierPakBuilder.ps1).
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

# windrose_plus.harvest.ini (tools/lib/MultiplierPakBuilder.ps1, Read-HarvestIni), taken out of the file as written
$builderPath = Join-Path $root 'tools/lib/MultiplierPakBuilder.ps1'
$builderAst = [System.Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$null, [ref]$null)
$harvestFn = $builderAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Read-HarvestIni' }, $true) | Select-Object -First 1
if (-not $harvestFn) { Write-Host 'FAIL Read-HarvestIni not found'; exit 1 }
. ([scriptblock]::Create($harvestFn.Extent.Text))
function Read-HarvestText([string]$Text) {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-harvest-test-" + [guid]::NewGuid().ToString('N') + '.ini')
    try {
        [System.IO.File]::WriteAllText($path, $Text)
        return Read-HarvestIni -Path $path -WarningAction SilentlyContinue
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}
Case 'harvest file: numbers are read, names match whatever their case' {
    $r = Read-HarvestText "[Resources]`r`nWood = 5.0`r`nstone = 2 ; note`r`n; Clay = 9`r`n"
    Assert ($r['wood'] -eq 5.0 -and $r['Stone'] -eq 2.0 -and -not $r.ContainsKey('Clay')) "read $($r.Keys -join ',')"
}
Case 'harvest file: 5x, NaN and Infinity are skipped, not read' {
    $r = Read-HarvestText "Wood = 5x`nStone = NaN`nClay = Infinity`nSalt = -Infinity`nCoal = 2`n"
    Assert ($r.Count -eq 1 -and $r['Coal'] -eq 2.0) "read $(($r.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')"
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All INI number cases passed.'
