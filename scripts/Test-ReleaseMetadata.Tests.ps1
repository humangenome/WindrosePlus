# Tests for scripts/Test-ReleaseMetadata.ps1: each case copies the files it reads into a
# temp folder, changes one thing, and checks the result. Run: pwsh scripts/Test-ReleaseMetadata.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(
    'scripts/Test-ReleaseMetadata.ps1', 'scripts/pak-builder-fingerprint.txt',
    'server/windrose_plus_server.ps1', 'server/routes.json',
    'tools/PAK_BUILDER_VERSION', 'tools/WindrosePlus-BuildPak.ps1',
    'tools/lib/MultiplierPakBuilder.ps1', 'tools/lib/CurveTableParser.ps1',
    'tools/lib/CurveTablePatcher.ps1', 'tools/lib/IniConfigParser.ps1',
    '.github/workflows/release.yml'
) + @(Get-ChildItem -LiteralPath (Join-Path $root 'config') -Filter 'windrose_plus*.default.ini' | ForEach-Object { "config/$($_.Name)" })

$failed = 0
$base = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-meta-" + [guid]::NewGuid().ToString('N'))

function New-Copy {
    $dir = Join-Path $base ([guid]::NewGuid().ToString('N'))
    foreach ($f in $files) {
        $dest = Join-Path $dir $f
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $dest
    }
    return $dir
}
function Invoke-Check([string]$Dir, [string[]]$CheckArgs = @()) {
    $out = & pwsh -NoProfile -File (Join-Path $Dir 'scripts/Test-ReleaseMetadata.ps1') @CheckArgs 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Text = $out }
}
function Edit-File([string]$Dir, [string]$Rel, [scriptblock]$Change) {
    $p = Join-Path $Dir $Rel
    [System.IO.File]::WriteAllText($p, (& $Change ([System.IO.File]::ReadAllText($p))))
}
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Expect($Result, [int]$Code, [string]$Text = '') {
    if ($Result.Code -ne $Code) { throw "exit $($Result.Code), expected $Code. Output: $($Result.Text)" }
    if ($Text -and $Result.Text -notlike "*$Text*") { throw "output lacks '$Text'. Output: $($Result.Text)" }
}

try {
    Case 'the repository passes as it is' {
        Expect (Invoke-Check (New-Copy)) 0 'matches the server'
    }
    Case 'a new route in the server that routes.json does not list fails' {
        $d = New-Copy
        Edit-File $d 'server/windrose_plus_server.ps1' { param($t) $t.Replace('"/api/status" {', "`"/api/new-thing`" { }`n                `"/api/status`" {") }
        Expect (Invoke-Check $d) 1 "server matches 'switch /api/new-thing'"
    }
    Case 'a route listed in routes.json that the server dropped fails' {
        $d = New-Copy
        Edit-File $d 'server/windrose_plus_server.ps1' { param($t) $t.Replace('"/api/rcon/log" {', '"/api/rcon/history" {') }
        Expect (Invoke-Check $d) 1 "routes.json lists 'switch /api/rcon/log'"
    }
    Case 'routes changed since the previous release without a higher routes_version fails' {
        $d = New-Copy
        $prev = Join-Path $d 'previous-routes.json'
        $j = Get-Content -Raw (Join-Path $d 'server/routes.json') | ConvertFrom-Json
        $j.routes = @($j.routes | Where-Object { $_.path -ne '/api/rcon/log' })
        $j | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $prev
        Expect (Invoke-Check $d @('-PreviousRoutes', $prev)) 1 'raise it'
    }
    Case 'the same change with routes_version raised passes' {
        $d = New-Copy
        $prev = Join-Path $d 'previous-routes.json'
        $j = Get-Content -Raw (Join-Path $d 'server/routes.json') | ConvertFrom-Json
        $j.routes = @($j.routes | Where-Object { $_.path -ne '/api/rcon/log' })
        $j | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $prev
        Edit-File $d 'server/routes.json' { param($t) $t -replace '"routes_version": \d+', '"routes_version": 99' }
        Expect (Invoke-Check $d @('-PreviousRoutes', $prev)) 0
    }
    Case 'routes_version lower than the previous release fails' {
        $d = New-Copy
        $prev = Join-Path $d 'previous-routes.json'
        (Get-Content -Raw (Join-Path $d 'server/routes.json')) -replace '"routes_version": \d+', '"routes_version": 99' | Set-Content -LiteralPath $prev
        Expect (Invoke-Check $d @('-PreviousRoutes', $prev)) 1 'went down'
    }
    Case 'a PAK builder change without recording fails' {
        $d = New-Copy
        Edit-File $d 'tools/lib/MultiplierPakBuilder.ps1' { param($t) $t + "`n# changed`n" }
        Expect (Invoke-Check $d) 1 'PAK builder files changed'
    }
    Case 'a new repak version counts as a PAK builder change' {
        $d = New-Copy
        Edit-File $d '.github/workflows/release.yml' { param($t) $t -replace 'REPAK_VERSION: "[^"]+"', 'REPAK_VERSION: "9.9.9"' }
        Expect (Invoke-Check $d) 1 'PAK builder files changed'
    }
    Case 'recording a builder change without raising the version is refused' {
        $d = New-Copy
        Edit-File $d 'config/windrose_plus.default.ini' { param($t) $t + "`n; changed`n" }
        Expect (Invoke-Check $d @('-RecordPakFingerprint')) 1 'still'
    }
    Case 'recording with -PakOutputUnchanged keeps the version and then passes' {
        $d = New-Copy
        Edit-File $d 'tools/lib/IniConfigParser.ps1' { param($t) $t + "`n# comment only`n" }
        Expect (Invoke-Check $d @('-RecordPakFingerprint', '-PakOutputUnchanged')) 0
        Expect (Invoke-Check $d) 0
    }
    $pakNow = [int]([System.IO.File]::ReadAllText((Join-Path $root 'tools/PAK_BUILDER_VERSION')).Trim())
    $pakNext = $pakNow + 1
    Case 'raising the version, then recording, passes' {
        $d = New-Copy
        Edit-File $d 'tools/lib/CurveTablePatcher.ps1' { param($t) $t + "`n# new rounding`n" }
        [System.IO.File]::WriteAllText((Join-Path $d 'tools/PAK_BUILDER_VERSION'), "$pakNext`n")
        Expect (Invoke-Check $d @('-RecordPakFingerprint')) 0
        Expect (Invoke-Check $d) 0 "PAK_BUILDER_VERSION $pakNext"
    }
    Case 'raising the version without recording fails' {
        $d = New-Copy
        [System.IO.File]::WriteAllText((Join-Path $d 'tools/PAK_BUILDER_VERSION'), "$pakNext`n")
        Expect (Invoke-Check $d) 1 "recorded for $pakNow"
    }
    Case 'Windows line endings give the same fingerprint' {
        $d = New-Copy
        foreach ($f in $files | Where-Object { $_ -like 'tools/*' -or $_ -like 'config/*' }) {
            Edit-File $d $f { param($t) $t.Replace("`r`n", "`n").Replace("`n", "`r`n") }
        }
        Expect (Invoke-Check $d) 0
    }
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All release metadata cases passed.'
exit 0
