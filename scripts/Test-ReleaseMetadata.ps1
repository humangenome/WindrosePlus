<#
Checks the two release files other projects read to follow changes:

  server/routes.json          every route windrose_plus_server.ps1 answers, plus routes_version
  tools/PAK_BUILDER_VERSION   goes up whenever the generated PAK output changes

Routes: each route in routes.json names the literal the server matches it on, and the
check fails when the server matches a path that routes.json does not list, or the other
way round. With -PreviousRoutes (the previous release's routes.json) it also fails when
the routes changed and routes_version did not go up.

PAK builder: scripts/pak-builder-fingerprint.txt holds "<version> <sha256>" of the files
that decide the PAK output. When they change, decide whether the output changes: if it
does, raise tools/PAK_BUILDER_VERSION. Then record the new fingerprint:

  pwsh scripts/Test-ReleaseMetadata.ps1 -RecordPakFingerprint                       (version raised)
  pwsh scripts/Test-ReleaseMetadata.ps1 -RecordPakFingerprint -PakOutputUnchanged   (same output)
#>
param(
    [string]$PreviousRoutes = "",
    [switch]$RecordPakFingerprint,
    [switch]$PakOutputUnchanged
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-Text([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    return [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start).Replace("`r`n", "`n")
}

# --- Routes ------------------------------------------------------------------

function Get-ServerRouteMatches([string]$Path) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $vars = @('path', 'filePath')
    $found = New-Object System.Collections.Generic.HashSet[string]
    foreach ($n in $ast.FindAll({ $true }, $true)) {
        if ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $vars -contains $n.Left.VariablePath.UserPath -and
            $n.Right -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            [void]$found.Add("$($n.Operator) $($n.Right.Value)")
        } elseif ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $vars -contains $n.Expression.VariablePath.UserPath -and
            $n.Member.Value -eq 'StartsWith' -and
            $n.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            [void]$found.Add("StartsWith $($n.Arguments[0].Value)")
        } elseif ($n -is [System.Management.Automation.Language.SwitchStatementAst] -and
            $n.Condition.Extent.Text -match '^\$path$') {
            foreach ($c in $n.Clauses) { [void]$found.Add("switch $($c.Item1.Value)") }
        }
    }
    return $found
}

function Get-RouteSignature($Manifest) {
    return (@($Manifest.routes | ForEach-Object { "{0} {1} {2}" -f (($_.methods | Sort-Object) -join ','), $_.path, $_.auth }) | Sort-Object) -join "`n"
}

$routesPath = Join-Path $root 'server/routes.json'
$manifest = (Read-Text $routesPath) | ConvertFrom-Json

if (-not ($manifest.routes_version -is [int] -or $manifest.routes_version -is [long]) -or $manifest.routes_version -lt 1) {
    $failures.Add("routes.json: routes_version must be a whole number of 1 or more")
}
$authNames = @($manifest.auth.PSObject.Properties.Name)
$listed = New-Object System.Collections.Generic.HashSet[string]
$paths = @{}
foreach ($r in $manifest.routes) {
    if (-not $r.path) { $failures.Add("routes.json: a route has no path"); continue }
    if ($paths.ContainsKey($r.path)) { $failures.Add("routes.json: $($r.path) is listed twice") }
    $paths[$r.path] = $true
    if (-not $r.methods -or @($r.methods | Where-Object { $_ -notin @('GET', 'POST') }).Count) { $failures.Add("routes.json: $($r.path) needs methods from GET and POST") }
    if ($authNames -notcontains $r.auth) { $failures.Add("routes.json: $($r.path) has auth '$($r.auth)', which is not described under auth") }
    if (-not $r.description) { $failures.Add("routes.json: $($r.path) has no description") }
    foreach ($m in @($r.match)) { [void]$listed.Add($m) }
}
foreach ($m in @($manifest.prefix_checks)) { [void]$listed.Add($m) }

$inCode = Get-ServerRouteMatches (Join-Path $root 'server/windrose_plus_server.ps1')
foreach ($m in $inCode) { if (-not $listed.Contains($m)) { $failures.Add("server matches '$m' but routes.json does not list it") } }
foreach ($m in $listed) { if (-not $inCode.Contains($m)) { $failures.Add("routes.json lists '$m' but the server no longer matches it") } }

if ($PreviousRoutes -and (Test-Path -LiteralPath $PreviousRoutes) -and (Get-Item -LiteralPath $PreviousRoutes).Length -gt 0) {
    $previous = (Read-Text $PreviousRoutes) | ConvertFrom-Json
    if ($manifest.routes_version -lt $previous.routes_version) {
        $failures.Add("routes_version went down: $($previous.routes_version) -> $($manifest.routes_version)")
    } elseif ((Get-RouteSignature $manifest) -ne (Get-RouteSignature $previous) -and $manifest.routes_version -eq $previous.routes_version) {
        $failures.Add("routes changed since the previous release but routes_version is still $($manifest.routes_version); raise it")
    }
    Write-Host "Compared with the previous release's routes.json (routes_version $($previous.routes_version))."
}

# --- PAK builder version -----------------------------------------------------

# Everything that decides what the generated PAKs contain: the builder, its libraries,
# the default INI files (they define the keys) and the pinned repak/retoc versions.
$pakInputs = @(
    'tools/WindrosePlus-BuildPak.ps1',
    'tools/lib/MultiplierPakBuilder.ps1',
    'tools/lib/CurveTableParser.ps1',
    'tools/lib/CurveTablePatcher.ps1',
    'tools/lib/IniConfigParser.ps1'
) + @(Get-ChildItem -LiteralPath (Join-Path $root 'config') -Filter 'windrose_plus*.default.ini' | Sort-Object Name | ForEach-Object { "config/$($_.Name)" })

function Get-PakFingerprint {
    $sb = New-Object System.Text.StringBuilder
    foreach ($rel in $pakInputs) {
        [void]$sb.Append("== $rel`n").Append((Read-Text (Join-Path $root $rel))).Append("`n")
    }
    $release = Read-Text (Join-Path $root '.github/workflows/release.yml')
    foreach ($tool in 'REPAK_VERSION', 'RETOC_VERSION') {
        if ($release -match "(?m)^\s*$($tool):\s*`"?([^`"\s]+)") { [void]$sb.Append("== $tool $($Matches[1])`n") }
        else { $failures.Add("release.yml: $tool not found") }
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString())) } finally { $sha.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

$versionText = (Read-Text (Join-Path $root 'tools/PAK_BUILDER_VERSION')).Trim()
$pakVersion = 0
if ($versionText -notmatch '^\d+$' -or -not [int]::TryParse($versionText, [ref]$pakVersion) -or $pakVersion -lt 1) {
    $failures.Add("tools/PAK_BUILDER_VERSION must be one line holding a whole number of 1 or more")
}
$fingerprint = Get-PakFingerprint
$recordPath = Join-Path $root 'scripts/pak-builder-fingerprint.txt'
$recorded = if (Test-Path -LiteralPath $recordPath) { (Read-Text $recordPath).Trim() -split '\s+' } else { @('0', '') }

if ($RecordPakFingerprint) {
    if ($recorded[1] -ne $fingerprint -and [int]$recorded[0] -eq $pakVersion -and -not $PakOutputUnchanged) {
        $failures.Add("the PAK builder changed and PAK_BUILDER_VERSION is still $pakVersion. Raise it if the output changes, or pass -PakOutputUnchanged if it does not")
    } elseif ($failures.Count -eq 0) {
        [System.IO.File]::WriteAllText($recordPath, "$pakVersion $fingerprint`n")
        Write-Host "Recorded PAK builder fingerprint for version ${pakVersion}: $fingerprint"
    }
} elseif ($recorded[1] -ne $fingerprint) {
    $failures.Add("the PAK builder files changed. If the PAK output changes, raise tools/PAK_BUILDER_VERSION; then run scripts/Test-ReleaseMetadata.ps1 -RecordPakFingerprint (add -PakOutputUnchanged if the output is the same)")
} elseif ([int]$recorded[0] -ne $pakVersion) {
    $failures.Add("tools/PAK_BUILDER_VERSION is $pakVersion but the fingerprint was recorded for $($recorded[0]); run scripts/Test-ReleaseMetadata.ps1 -RecordPakFingerprint")
}

if ($failures.Count) {
    foreach ($f in $failures) { Write-Host "FAIL: $f" }
    exit 1
}
Write-Host "routes.json: $(@($manifest.routes).Count) routes, routes_version $($manifest.routes_version), matches the server ($($inCode.Count) path checks)."
Write-Host "PAK_BUILDER_VERSION $pakVersion matches the builder files ($($pakInputs.Count) files + repak/retoc versions)."
exit 0
