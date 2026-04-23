<#
.SYNOPSIS
    WindrosePlus PAK Builder — generates server-side override PAK files from config.

.DESCRIPTION
    Reads multipliers from windrose_plus.json and advanced CurveTable overrides from
    windrose_plus.ini (both at the server root). Builds up to two PAK files:

      1. WindrosePlus_Multipliers_P.pak  — JSON-based overrides (loot, XP, stack size,
                                           craft cost, crop speed, weight, inventory
                                           size, points per level)
      2. WindrosePlus_CurveTables_P.pak  — Binary CurveTable overrides (player stats,
                                           talents, weapons, food, gear, entities,
                                           co-op scaling, combat tuning)

    Both use the _P suffix so UE5 loads them as priority overrides over base assets.

    Hash cache at R5\Content\Paks\.windroseplus_build.hash lets repeat invocations
    exit quickly when inputs haven't changed.

    If a [Multipliers] section is found in windrose_plus.ini it is ignored with a
    warning — multipliers belong in windrose_plus.json so the in-game wp.config
    command stays accurate.

.PARAMETER ServerDir
    Path to the Windrose dedicated server directory. Auto-detected if omitted.

.PARAMETER ConfigPath
    Path to windrose_plus.ini. Defaults to <ServerDir>\windrose_plus.ini.

.PARAMETER DefaultPath
    Path to windrose_plus.default.ini. Defaults to
    <ServerDir>\windrose_plus\config\windrose_plus.default.ini.

.PARAMETER DryRun
    Show what would be changed without modifying any files.

.PARAMETER ForceExtract
    Force re-extraction of the CurveTable cache even when it appears valid.

.PARAMETER RemoveStalePak
    When no overrides are present, delete any leftover override PAK files. Default
    is to leave them alone so external PAK builders are not disturbed.

.EXAMPLE
    .\WindrosePlus-BuildPak.ps1 -ServerDir "C:\MyServer"
    .\WindrosePlus-BuildPak.ps1 -DryRun
#>
param(
    [string]$ConfigPath = "",
    [string]$ServerDir = "",
    [string]$DefaultPath = "",
    [switch]$DryRun,
    [switch]$ForceExtract,
    [switch]$RemoveStalePak
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\IniConfigParser.ps1")
. (Join-Path $PSScriptRoot "lib\CurveTableParser.ps1")
. (Join-Path $PSScriptRoot "lib\CurveTablePatcher.ps1")
. (Join-Path $PSScriptRoot "lib\MultiplierPakBuilder.ps1")

# --- Resolve server directory ---
if (-not $ServerDir) {
    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        $configParent = Split-Path -Parent $ConfigPath
        $ServerDir = if ($configParent) { (Resolve-Path $configParent).Path } else { (Resolve-Path ".").Path }
    } else {
        foreach ($c in @(".", "..", "..\..")) {
            if (Test-Path -LiteralPath (Join-Path $c "R5\Content\Paks")) {
                $ServerDir = (Resolve-Path $c).Path
                break
            }
        }
    }
}
if (-not $ServerDir -or -not (Test-Path -LiteralPath (Join-Path $ServerDir "R5\Content\Paks"))) {
    Write-Error "Server directory not found. Pass -ServerDir or run from inside the server folder."
    exit 2
}

$paksDir = Join-Path $ServerDir "R5\Content\Paks"
$binDir  = Join-Path $PSScriptRoot "bin"

$jsonPath = Join-Path $ServerDir "windrose_plus.json"
if ($ConfigPath) {
    $iniPath = if (Split-Path -Parent $ConfigPath) { $ConfigPath } else { Join-Path $ServerDir $ConfigPath }
} else {
    $iniPath = Join-Path $ServerDir "windrose_plus.ini"
}
$iniDir = Split-Path -Parent $iniPath
if (-not $iniDir) { $iniDir = $ServerDir }
$iniConfigPaths = @(
    $iniPath,
    (Join-Path $iniDir "windrose_plus.weapons.ini"),
    (Join-Path $iniDir "windrose_plus.food.ini"),
    (Join-Path $iniDir "windrose_plus.gear.ini"),
    (Join-Path $iniDir "windrose_plus.entities.ini")
)
if (-not $DefaultPath) {
    $DefaultPath = Join-Path $ServerDir "windrose_plus\config\windrose_plus.default.ini"
}

Write-Host "WindrosePlus PAK Builder" -ForegroundColor Cyan
Write-Host "Server: $ServerDir"

# --- Read multipliers (JSON only) ---
$multipliers = @{}
if (Test-Path -LiteralPath $jsonPath) {
    try {
        $jsonObj = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
        if ($jsonObj.multipliers) {
            foreach ($prop in $jsonObj.multipliers.PSObject.Properties) {
                $multipliers[$prop.Name] = [double]$prop.Value
            }
        }
    } catch {
        Write-Error "Failed to parse ${jsonPath}: $_"
        exit 2
    }
}

# --- Read INI (CurveTables only) ---
$iniConfig = $null
$hasIniConfig = $false
foreach ($path in $iniConfigPaths) {
    if (Test-Path -LiteralPath $path) {
        $hasIniConfig = $true
        break
    }
}
if ($hasIniConfig) {
    if (-not (Test-Path -LiteralPath $DefaultPath)) {
        Write-Error "Default INI not found at $DefaultPath. Reinstall WindrosePlus."
        exit 2
    }
    $iniConfig = Import-WindrosePlusConfig -ConfigPath $iniPath -DefaultPath $DefaultPath
    if ($iniConfig.Error) {
        Write-Error $iniConfig.Error
        exit 2
    }
    if ($iniConfig.Multipliers -and $iniConfig.Multipliers.Count -gt 0) {
        Write-Warning "[Multipliers] in $iniPath is ignored. Put multipliers in windrose_plus.json so the in-game wp.config matches what's applied."
    }
}

$aesKey = if ($iniConfig -and $iniConfig.AesKey) { $iniConfig.AesKey } else { $script:WindroseAesKey }
$ctConfig = if ($iniConfig -and $iniConfig.CurveTables) { $iniConfig.CurveTables } else { @{} }

# Expected PAK set (derived from actual config state)
$hasMultipliers = $false
foreach ($prop in $multipliers.GetEnumerator()) {
    if ($prop.Key -eq "points_per_level") { continue }
    if ($prop.Value -ne 1.0) { $hasMultipliers = $true; break }
}
$hasCT = ($ctConfig.Count -gt 0)

# --- No-op path ---
if (-not $hasMultipliers -and -not $hasCT) {
    Write-Host "No config overrides found — nothing to build."
    if ($RemoveStalePak -and -not $DryRun) {
        foreach ($p in @("WindrosePlus_Multipliers_P.pak", "WindrosePlus_CurveTables_P.pak")) {
            $stale = Join-Path $paksDir $p
            if (Test-Path -LiteralPath $stale) {
                Remove-Item $stale -Force
                Write-Host "Removed stale $stale"
            }
        }
    }
    exit 0
}

# --- Hash-skip ---
function Get-BuildInputHash {
    param([string]$ServerDir, [string]$ScriptRoot, [string[]]$IniConfigPaths)

    $chunks = [System.Collections.Generic.List[byte[]]]::new()

    $files = @(@{ Label = "windrose_plus.json"; Path = (Join-Path $ServerDir "windrose_plus.json") })
    foreach ($path in $IniConfigPaths) {
        $files += @{ Label = $path; Path = $path }
    }
    foreach ($f in $files) {
        $path = $f.Path
        $chunks.Add([System.Text.Encoding]::UTF8.GetBytes("$($f.Label)`n"))
        if (Test-Path -LiteralPath $path) {
            $lines = [System.IO.File]::ReadAllLines($path)
            $kept = @()
            foreach ($l in $lines) {
                $t = $l.Trim()
                if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#') -or $t.StartsWith('//')) { continue }
                $kept += $t
            }
            $chunks.Add([System.Text.Encoding]::UTF8.GetBytes(($kept -join "`n") + "`n"))
        } else {
            $chunks.Add([System.Text.Encoding]::UTF8.GetBytes("MISSING`n"))
        }
    }

    $gamePak = Join-Path $ServerDir "R5\Content\Paks\pakchunk0-WindowsServer.pak"
    if (Test-Path -LiteralPath $gamePak) {
        $mtime = (Get-Item $gamePak).LastWriteTimeUtc.Ticks
        $chunks.Add([System.Text.Encoding]::UTF8.GetBytes("GAMEPAK_TICKS:$mtime`n"))
    }

    $versionFile = Join-Path $ScriptRoot "bin\VERSION.txt"
    if (Test-Path -LiteralPath $versionFile) {
        $v = [System.IO.File]::ReadAllText($versionFile).Trim()
        $chunks.Add([System.Text.Encoding]::UTF8.GetBytes("TOOLS:$v`n"))
    }

    $mainLua = Join-Path $ServerDir "R5\Binaries\Win64\ue4ss\Mods\WindrosePlus\Scripts\main.lua"
    if (Test-Path -LiteralPath $mainLua) {
        $content = [System.IO.File]::ReadAllText($mainLua)
        if ($content -match 'VERSION\s*=\s*"([^"]+)"') {
            $chunks.Add([System.Text.Encoding]::UTF8.GetBytes("WP_VERSION:$($Matches[1])`n"))
        }
    }

    $totalLen = 0
    foreach ($c in $chunks) { $totalLen += $c.Length }
    $all = [byte[]]::new($totalLen)
    $offset = 0
    foreach ($c in $chunks) {
        [Array]::Copy($c, 0, $all, $offset, $c.Length)
        $offset += $c.Length
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($all)
    return [System.BitConverter]::ToString($hash).Replace('-','').ToLower()
}

$hashFile = Join-Path $paksDir ".windroseplus_build.hash"
$currentHash = Get-BuildInputHash -ServerDir $ServerDir -ScriptRoot $PSScriptRoot -IniConfigPaths $iniConfigPaths

$expectedPaks = @()
if ($hasMultipliers) { $expectedPaks += "WindrosePlus_Multipliers_P.pak" }
if ($hasCT) { $expectedPaks += "WindrosePlus_CurveTables_P.pak" }

$allExpectedExist = $true
foreach ($p in $expectedPaks) {
    if (-not (Test-Path -LiteralPath (Join-Path $paksDir $p))) { $allExpectedExist = $false; break }
}

$cachedHash = $null
if (Test-Path -LiteralPath $hashFile) {
    $cachedHash = (Get-Content -LiteralPath $hashFile -Raw).Trim()
}

if ($cachedHash -eq $currentHash -and $allExpectedExist -and -not $DryRun -and -not $ForceExtract) {
    Write-Host "Config unchanged since last build (hash matches). Skipping."
    exit 0
}

# --- Locate bundled tools ---
$repakExe = $null
$bundledRepak = Join-Path $binDir "repak.exe"
if (Test-Path -LiteralPath $bundledRepak) {
    $repakExe = $bundledRepak
} else {
    $repakExe = Find-Repak
}
if (-not $repakExe) {
    Write-Error "repak.exe not found. Reinstall WindrosePlus so tools\bin\repak.exe is populated."
    exit 2
}

$retocExe = $null
$bundledRetoc = Join-Path $binDir "retoc.exe"
if (Test-Path -LiteralPath $bundledRetoc) {
    $retocExe = $bundledRetoc
} else {
    $alt = Get-Command "retoc.exe" -ErrorAction SilentlyContinue
    if ($alt) { $retocExe = $alt.Source }
}

# --- Build Multipliers PAK ---
if ($hasMultipliers) {
    Write-Host ""
    Write-Host "=== Multipliers PAK ===" -ForegroundColor Yellow
    $multStr = ($multipliers.GetEnumerator() | Where-Object { $_.Value -ne 1.0 } | ForEach-Object { "$($_.Key)=$($_.Value)x" }) -join ", "
    Write-Host "  Active: $multStr"

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would build WindrosePlus_Multipliers_P.pak" -ForegroundColor DarkGray
    } else {
        $multResult = Build-MultiplierPak -Config $multipliers -AesKey $aesKey -ServerDir $ServerDir -RepakPath $repakExe
        if ($multResult.Error) {
            Write-Error "Multipliers PAK failed: $($multResult.Error)"
            exit 3
        }
        Write-Host "  OK: $($multResult.ModifiedFiles) files -> $($multResult.OutputPath)" -ForegroundColor Green
    }
}

# --- Build CurveTables PAK ---
if ($hasCT) {
    Write-Host ""
    Write-Host "=== CurveTables PAK ===" -ForegroundColor Yellow

    $changedTables = ($ctConfig.Keys | ForEach-Object { "$_ ($($ctConfig[$_].overrides.Count) changes)" }) -join ", "
    Write-Host "  Tables: $changedTables"

    $retocDir = Join-Path $ServerDir "WindrosePlus\curvetable_cache"
    $gamePak = Join-Path $paksDir "pakchunk0-WindowsServer.pak"

    if ((Test-Path -LiteralPath $retocDir) -and (Test-Path -LiteralPath $gamePak)) {
        $cacheTime = (Get-Item $retocDir).LastWriteTime
        $pakTime = (Get-Item $gamePak).LastWriteTime
        if ($pakTime -gt $cacheTime) {
            Write-Host "  Game pak is newer than cache — re-extracting..." -ForegroundColor Yellow
            Remove-Item -Recurse -Force $retocDir -ErrorAction SilentlyContinue
        }
    }
    if ($ForceExtract -and (Test-Path -LiteralPath $retocDir)) {
        Write-Host "  Force extract requested — clearing cache..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $retocDir -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $retocDir) {
        $cachedCtFiles = @(Get-ChildItem -Path $retocDir -Recurse -Filter "CT_*.uasset" -ErrorAction SilentlyContinue)
        if ($cachedCtFiles.Count -eq 0) {
            Write-Host "  CurveTable cache is empty — re-extracting..." -ForegroundColor Yellow
            Remove-Item -Recurse -Force $retocDir -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $retocDir)) {
        if (-not $retocExe) {
            Write-Error "retoc.exe not found at tools\bin\retoc.exe. Antivirus often quarantines retoc/repak as a false positive on Rust UE pak tools. Add an exclusion for the windrose_plus folder in Defender/your AV, then re-extract WindrosePlus.zip over the existing install."
            exit 2
        }
        $utocPath = $gamePak -replace '\.pak$', '.utoc'
        if (-not (Test-Path -LiteralPath $utocPath)) {
            Write-Error "Game utoc not found: $utocPath. Is the server installed correctly?"
            exit 2
        }
        Write-Host "  Extracting CurveTable assets with retoc..."
        New-Item -ItemType Directory -Force -Path $retocDir | Out-Null
        $retocOutput = @(& $retocExe -a $aesKey to-legacy $utocPath $retocDir 2>&1)
        $retocExit = $LASTEXITCODE

        $extractedFiles = @(Get-ChildItem -Path $retocDir -Recurse -Filter "CT_*.uasset" -ErrorAction SilentlyContinue)
        if ($retocExit -ne 0 -or -not $extractedFiles -or $extractedFiles.Count -eq 0) {
            $retocDetails = ($retocOutput | Select-Object -Last 8 | ForEach-Object { $_.ToString() }) -join "`n"
            $errorMessage = "retoc extraction failed (exit $retocExit, $($extractedFiles.Count) CT assets found). Check AES key, game files, and retoc compatibility with this Windrose build."
            if ($retocDetails) { $errorMessage += "`nretoc output:`n$retocDetails" }
            Write-Error $errorMessage
            Remove-Item -Recurse -Force $retocDir -ErrorAction SilentlyContinue
            exit 3
        }
        Write-Host "  Extracted $($extractedFiles.Count) CurveTable assets to cache"
    }

    $ctFiles = @(Get-ChildItem -Path $retocDir -Recurse -Filter "CT_*.uasset" -ErrorAction SilentlyContinue)
    if ($ctFiles.Count -eq 0) {
        Write-Error "CurveTable cache contains no CT_*.uasset files. Rerun with -ForceExtract; if it repeats, retoc is not compatible with this Windrose build."
        exit 3
    }
    $totalChanges = 0
    $tablesModified = 0
    $pendingCtTables = @{}
    foreach ($tableName in $ctConfig.Keys) {
        if ($ctConfig[$tableName].overrides -and $ctConfig[$tableName].overrides.Count -gt 0) {
            $pendingCtTables[$tableName] = $true
        }
    }

    $stageDir = Join-Path ([System.IO.Path]::GetTempPath()) "WindrosePlus_ct_$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    try {
        foreach ($ctFile in $ctFiles) {
            $basename = $ctFile.BaseName
            $tableOverrides = if ($ctConfig.Contains($basename)) { $ctConfig[$basename] } else { $null }
            if (-not $tableOverrides -or $tableOverrides.overrides.Count -eq 0) { continue }
            $null = $pendingCtTables.Remove($basename)

            Write-Host "  Parsing $basename..."
            $manifest = Parse-CurveTable -UAssetPath $ctFile.FullName
            if ($manifest.Error) {
                Write-Error "CurveTable parse failed for ${basename}: $($manifest.Error)"
                exit 3
            }
            $rowsWithKeys = ($manifest.Rows | Where-Object { $_.Keys.Count -gt 0 }).Count
            Write-Host "    $($manifest.RowCount) rows, $rowsWithKeys with patchable values"

            $rowNames = @($manifest.Rows | Where-Object { $_.Keys.Count -gt 0 } | ForEach-Object { $_.Name })
            $unmatchedPatterns = @()
            foreach ($pattern in $tableOverrides.overrides.Keys) {
                $matched = $false
                foreach ($rowName in $rowNames) {
                    if ($rowName -like $pattern) {
                        $matched = $true
                        break
                    }
                }
                if (-not $matched) { $unmatchedPatterns += $pattern }
            }
            if ($unmatchedPatterns.Count -gt 0) {
                Write-Error "CurveTable config for $basename has row patterns that did not match this Windrose build: $($unmatchedPatterns -join ', ')"
                exit 3
            }

            $configHT = @{ overrides = $tableOverrides.overrides }

            if ($DryRun) {
                foreach ($row in $manifest.Rows) {
                    if ($row.Keys.Count -eq 0) { continue }
                    $ovr = Resolve-ConfigMatch -RowName $row.Name -Patterns $configHT["overrides"]
                    if ($null -ne $ovr) {
                        $orig = $row.Keys[0].Value
                        if ([Math]::Abs($ovr - $orig) -gt 0.0001) {
                            Write-Host "    [DRY] $($row.Name): $orig -> $([Math]::Round($ovr, 2))" -ForegroundColor DarkGray
                            $totalChanges++
                        }
                    }
                }
                continue
            }

            $relPath = $ctFile.FullName.Substring($retocDir.Length).TrimStart('\','/')
            $stageUasset = Join-Path $stageDir $relPath
            $stageUexp = $stageUasset -replace '\.uasset$', '.uexp'
            $srcUexp = $ctFile.FullName -replace '\.uasset$', '.uexp'

            New-Item -ItemType Directory -Force -Path (Split-Path $stageUasset) | Out-Null
            Copy-Item $ctFile.FullName $stageUasset
            Copy-Item $srcUexp $stageUexp

            $patchResult = Invoke-CurveTablePatch -Manifest $manifest -Config $configHT -UExpPath $stageUexp
            if ($patchResult.Error) {
                Write-Error "CurveTable patch failed for ${basename}: $($patchResult.Error)"
                exit 3
            }
            if ($patchResult.ChangesApplied -eq 0) {
                Remove-Item $stageUasset -Force -ErrorAction SilentlyContinue
                Remove-Item $stageUexp -Force -ErrorAction SilentlyContinue
                Write-Host "    No changes needed"
                continue
            }
            if (-not $patchResult.VerificationPassed) {
                Write-Error "CurveTable verification failed for $basename"
                Remove-Item $stageUasset -Force -ErrorAction SilentlyContinue
                Remove-Item $stageUexp -Force -ErrorAction SilentlyContinue
                exit 3
            }

            Write-Host "    Patched $($patchResult.ChangesApplied) values (verified)" -ForegroundColor Green
            $totalChanges += $patchResult.ChangesApplied
            $tablesModified++
        }

        if ($pendingCtTables.Count -gt 0) {
            Write-Error "Configured CurveTables were not found in this Windrose build: $($pendingCtTables.Keys -join ', ')"
            exit 3
        }

        if ($DryRun) {
            Write-Host "  [DRY RUN] Would patch $totalChanges values" -ForegroundColor DarkGray
        } elseif ($totalChanges -gt 0) {
            $outPak = Join-Path $paksDir "WindrosePlus_CurveTables_P.pak"
            & $repakExe pack $stageDir $outPak 2>&1 | Out-Null
            $repakExit = $LASTEXITCODE
            if ($repakExit -ne 0 -or -not (Test-Path -LiteralPath $outPak)) {
                Write-Error "repak failed to create $outPak (exit $repakExit)"
                exit 3
            }
            $size = (Get-Item $outPak).Length
            Write-Host "  OK: $tablesModified tables, $totalChanges values -> $outPak ($size bytes)" -ForegroundColor Green
        } else {
            Write-Host "  No CurveTable changes needed" -ForegroundColor DarkGray
        }
    } finally {
        Remove-Item -Recurse -Force $stageDir -ErrorAction SilentlyContinue
    }
}

# --- Write hash cache (only on successful non-dry build) ---
if (-not $DryRun) {
    try {
        Set-Content -LiteralPath $hashFile -Value $currentHash -Encoding ASCII
    } catch {
        Write-Warning "Could not write hash cache: $_"
    }
}

# --- Optional stale-PAK cleanup ---
if ($RemoveStalePak -and -not $DryRun) {
    if (-not $hasMultipliers) {
        $stale = Join-Path $paksDir "WindrosePlus_Multipliers_P.pak"
        if (Test-Path -LiteralPath $stale) {
            Remove-Item $stale -Force
            Write-Host "Removed stale $stale"
        }
    }
    if (-not $hasCT) {
        $stale = Join-Path $paksDir "WindrosePlus_CurveTables_P.pak"
        if (Test-Path -LiteralPath $stale) {
            Remove-Item $stale -Force
            Write-Host "Removed stale $stale"
        }
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
if (-not $DryRun) {
    Write-Host "Restart the game server for changes to take effect."
}
exit 0
