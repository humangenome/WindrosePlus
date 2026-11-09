# Tests the dashboard's wrong-password limit (Get-RecentAuthFailures, Test-AuthThrottled and
# Add-AuthFailure in server/windrose_plus_server.ps1): a flood of wrong passwords from new
# addresses must never lift a block. The functions and their settings are taken out of the file
# as written; the clock is replaced so the cases control time.
# Run: pwsh scripts/Test-AuthThrottle.ps1   (also runs on Windows PowerShell 5.1)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $root 'server/windrose_plus_server.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($serverPath, [ref]$null, [ref]$null)
$settings = @($ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $args[0].Left.Extent.Text -like '$script:AuthFailure*' -and
    $null -eq $args[0].Parent.Parent.Parent
}, $true))
$functions = @($ast.FindAll({
    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    ($args[0].Name -like '*AuthFailure*' -or $args[0].Name -eq 'Test-AuthThrottled' -or $args[0].Name -eq 'Get-AuthNowSeconds')
}, $true))
if ($settings.Count -eq 0 -or $functions.Count -lt 3) { Write-Host 'FAIL the wrong-password limit was not found in the server script'; exit 1 }
foreach ($fn in $functions) { . ([scriptblock]::Create($fn.Extent.Text)) }

$script:Clock = [long]1800000000
function Get-AuthNowSeconds { return $script:Clock }
function Reset-Table {
    foreach ($s in $settings) { . ([scriptblock]::Create($s.Extent.Text)) }
    $script:Clock = [long]1800000000
}
function Addr([int]$i) { return ('10.{0}.{1}.{2}' -f (($i -shr 16) -band 255), (($i -shr 8) -band 255), ($i -band 255)) }
function Block([string]$Key) { for ($i = 0; $i -lt $script:AuthFailureLimit; $i++) { Add-AuthFailure $Key } }

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

# The table holds 5000 addresses before it makes room.
$tableLimit = 5000

Case 'a flood of wrong passwords from new addresses never lifts a block' {
    Reset-Table
    Block 'guesser'
    Assert (Test-AuthThrottled 'guesser') 'the guesser is not blocked after its wrong passwords'
    $script:Clock += 1
    for ($i = 0; $i -lt $tableLimit + 1000; $i++) { Add-AuthFailure (Addr $i) }
    Assert (Test-AuthThrottled 'guesser') 'wrong passwords from many new addresses lifted the block'
    Assert ($script:AuthFailures.Count -le $tableLimit) "the table holds $($script:AuthFailures.Count) addresses"
}

Case 'the longest-quiet addresses that are not blocked make room first' {
    Reset-Table
    for ($i = 0; $i -lt $tableLimit - 1; $i++) { Add-AuthFailure (Addr $i) }
    $script:Clock += 5
    for ($i = 0; $i -lt $script:AuthFailureLimit - 1; $i++) { Add-AuthFailure 'guesser' }
    $script:Clock += 1
    Add-AuthFailure (Addr $tableLimit)
    $script:Clock += 1
    Add-AuthFailure 'guesser'
    Assert (Test-AuthThrottled 'guesser') 'the newest guesser lost its count; the oldest rows should go first'
}

Case 'a table full of blocks keeps every block until the ceiling, then drops the one nearest to running out' {
    Reset-Table
    # Small limits so the case runs in seconds; the rule is the same at 5000 and 65536.
    $script:AuthFailureTableLimit = 40
    $script:AuthFailureTableCeiling = 100
    Block 'first'
    $script:Clock += 10
    for ($i = 0; $i -lt 99; $i++) { Block (Addr $i) }
    $script:Clock += 10
    Assert ($script:AuthFailures.Count -eq 100) "the table holds $($script:AuthFailures.Count) addresses, not 100"
    Assert (Test-AuthThrottled 'first') 'the first block was dropped while the table grew'
    Assert (Test-AuthThrottled (Addr 0)) 'an early block was dropped while the table grew'

    Block 'newcomer'
    Assert ($script:AuthFailures.Count -eq 100) "the table grew past its ceiling to $($script:AuthFailures.Count)"
    Assert (Test-AuthThrottled 'newcomer') 'the newcomer is not blocked'
    Assert (-not (Test-AuthThrottled 'first')) 'at the ceiling the block nearest to running out should make way'
    Assert (Test-AuthThrottled (Addr 0)) 'a later block was dropped instead'
    Assert (Test-AuthThrottled (Addr 98)) 'the last block was dropped'
}

Case 'a table full of blocks logs one line, with no address in it' {
    Reset-Table
    $script:AuthFailureTableLimit = 40
    $script:AuthFailureTableCeiling = 100
    $lines = @(& { for ($i = 0; $i -lt 70; $i++) { Block (Addr $i) } } 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -like '*auth table full*' })
    Assert ($lines.Count -eq 1) "expected one line, got $($lines.Count)"
    Assert ($lines[0] -eq 'WARN: auth table full: all 40 tracked addresses are blocked; every block is kept (up to 100)') "the line was '$($lines[0])'"
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All wrong-password limit cases passed.'
