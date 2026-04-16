<#
.SYNOPSIS
    WindrosePlus PAK Builder — generates server-side override PAK files from config.

.DESCRIPTION
    Reads windrose_plus.ini and builds two PAK files:
    1. WindrosePlus_Multipliers_P.pak — JSON-based overrides (loot, XP, stack size, etc.)
    2. WindrosePlus_CurveTables_P.pak — Binary CurveTable overrides (weapon damage, mob HP, etc.)

    Both PAKs use the _P suffix for UE5 load priority over base game assets.

.PARAMETER ConfigPath
    Path to windrose_plus.ini. Defaults to ../windrose_plus.ini relative to this script.

.PARAMETER ServerDir
    Path to the Windrose dedicated server directory. Auto-detected if not specified.

.PARAMETER DryRun
    Show what would be changed without modifying any files.

.PARAMETER ForceExtract
    Force re-extraction of CurveTable cache even if it already exists.
    Use after a game update to ensure patching uses fresh assets.

.EXAMPLE
    .\WindrosePlus-BuildPak.ps1
    .\WindrosePlus-BuildPak.ps1 -ConfigPath "C:\MyServer\windrose_plus.ini" -ServerDir "C:\MyServer"
    .\WindrosePlus-BuildPak.ps1 -DryRun
    .\WindrosePlus-BuildPak.ps1 -ForceExtract
#>
param(
    [string]$ConfigPath = "",
    [string]$ServerDir = "",
    [switch]$DryRun,
    [switch]$ForceExtract
)

$ErrorActionPreference = "Stop"

# Load library modules
. (Join-Path $PSScriptRoot "lib\IniConfigParser.ps1")
. (Join-Path $PSScriptRoot "lib\CurveTableParser.ps1")
. (Join-Path $PSScriptRoot "lib\CurveTablePatcher.ps1")
. (Join-Path $PSScriptRoot "lib\MultiplierPakBuilder.ps1")

# Find config
if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Split-Path $PSScriptRoot) "windrose_plus.ini"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath`nCopy windrose_plus.default.ini to windrose_plus.ini and edit it."
    exit 1
}

Write-Host "WindrosePlus PAK Builder" -ForegroundColor Cyan
Write-Host "Config: $ConfigPath"

# Parse INI config
$config = Import-WindrosePlusConfig -ConfigPath $ConfigPath
if ($config.Error) {
    Write-Error $config.Error
    exit 1
}

$aesKey = $config.AesKey

# Auto-detect server directory (check: -ServerDir param > INI server_dir > common paths)
if (-not $ServerDir -and $config.Server.server_dir) {
    $ServerDir = $config.Server.server_dir
}
if (-not $ServerDir) {
    # Check current directory and parent
    foreach ($c in @(".", "..")) {
        if (Test-Path -LiteralPath (Join-Path $c "R5\Content\Paks")) {
            $ServerDir = (Resolve-Path $c).Path
            break
        }
    }
}
if (-not $ServerDir) {
    Write-Error "Could not find server directory. Use -ServerDir parameter or set server_dir in [Server] section."
    exit 1
}

Write-Host "Server: $ServerDir"
Write-Host ""

$paksDir = Join-Path $ServerDir "R5\Content\Paks"

# --- JSON Multiplier PAK ---
$multipliers = $config.Multipliers

$hasMultipliers = $false
foreach ($val in $multipliers.Values) {
    if ($val -ne 1.0) { $hasMultipliers = $true; break }
}

if ($hasMultipliers) {
    Write-Host "=== JSON Multiplier PAK ===" -ForegroundColor Yellow
    $multStr = ($multipliers.GetEnumerator() | Where-Object { $_.Value -ne 1.0 } | ForEach-Object { "$($_.Key)=$($_.Value)x" }) -join ", "
    Write-Host "  Active: $multStr"

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would build WindrosePlus_Multipliers_P.pak" -ForegroundColor DarkGray
    } else {
        $multResult = Build-MultiplierPak -Config $multipliers -AesKey $aesKey -ServerDir $ServerDir
        if ($multResult.Error) {
            Write-Warning "Multiplier PAK failed: $($multResult.Error)"
        } else {
            Write-Host "  OK: $($multResult.ModifiedFiles) files -> $($multResult.OutputPath)" -ForegroundColor Green
        }
    }
    Write-Host ""
} else {
    Write-Host "=== JSON Multiplier PAK ===" -ForegroundColor Yellow
    Write-Host "  Skipped (all multipliers are 1.0)" -ForegroundColor DarkGray
    $stalePak = Join-Path $paksDir "WindrosePlus_Multipliers_P.pak"
    if ((Test-Path -LiteralPath $stalePak) -and -not $DryRun) {
        Remove-Item $stalePak -Force
        Write-Host "  Removed stale $stalePak"
    }
    Write-Host ""
}

# --- CurveTable PAK ---
$ctConfig = $config.CurveTables

if ($ctConfig.Count -gt 0) {
    Write-Host "=== CurveTable PAK ===" -ForegroundColor Yellow

    $changedTables = ($ctConfig.Keys | ForEach-Object { "$_ ($($ctConfig[$_].overrides.Count) changes)" }) -join ", "
    Write-Host "  Tables with changes: $changedTables"

    # retoc extraction — check for cached extraction
    $retocDir = Join-Path $ServerDir "WindrosePlus\curvetable_cache"
    $gamePak = Join-Path $paksDir "pakchunk0-WindowsServer.pak"

    # Cache invalidation: if game pak is newer than cache, force re-extract
    if ((Test-Path -LiteralPath $retocDir) -and (Test-Path -LiteralPath $gamePak)) {
        $cacheTime = (Get-Item $retocDir).LastWriteTime
        $pakTime = (Get-Item $gamePak).LastWriteTime
        if ($pakTime -gt $cacheTime) {
            Write-Host "  Game pak is newer than cache — re-extracting..." -ForegroundColor Yellow
            Remove-Item -Recurse -Force $retocDir -ErrorAction SilentlyContinue
        }
    }

    # Force re-extract if requested
    if ($ForceExtract -and (Test-Path -LiteralPath $retocDir)) {
        Write-Host "  Force extract requested — clearing cache..." -ForegroundColor Yellow
        Remove-Item -Recurse -Force $retocDir -ErrorAction SilentlyContinue
    }

    $extractionOk = $true
    if (-not (Test-Path -LiteralPath $retocDir)) {
        Write-Host "  Extracting CurveTable assets with retoc..."

        # Find retoc.exe — alongside repak, in tools dir, or in PATH
        $retocExe = $null
        $repakPath = Find-Repak
        if ($repakPath) {
            $candidate = Join-Path (Split-Path $repakPath) "retoc.exe"
            if (Test-Path -LiteralPath $candidate) { $retocExe = $candidate }
        }
        if (-not $retocExe) {
            $retocExe = Get-Command "retoc.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        }

        if (-not $retocExe -or -not (Test-Path -LiteralPath $retocExe)) {
            Write-Error "retoc.exe not found. CurveTable patching requires retoc for initial extraction.`nDownload from: https://github.com/trumank/retoc`nPlace retoc.exe alongside repak.exe or in your PATH."
            exit 1
        }

        $utocPath = $gamePak -replace '\.pak$', '.utoc'
        if (-not (Test-Path -LiteralPath $utocPath)) {
            Write-Error "Game utoc not found: $utocPath`nIs the server installed correctly?"
            exit 1
        }

        New-Item -ItemType Directory -Force -Path $retocDir | Out-Null
        & $retocExe -a $aesKey to-legacy $utocPath $retocDir 2>&1 | Out-Null

        # Verify extraction produced CT files
        $extractedFiles = Get-ChildItem -Path $retocDir -Recurse -Filter "CT_*.uasset" -ErrorAction SilentlyContinue
        if (-not $extractedFiles -or $extractedFiles.Count -eq 0) {
            Write-Error "retoc extraction failed — no CT_*.uasset files found in $retocDir.`nCheck that the AES key is correct and the game files are not corrupted."
            Remove-Item -Recurse -Force $retocDir -ErrorAction SilentlyContinue
            exit 1
        }
        Write-Host "  Extracted $($extractedFiles.Count) CurveTable assets to cache"
    }

    if (Test-Path -LiteralPath $retocDir) {
        $ctFiles = Get-ChildItem -Path $retocDir -Recurse -Filter "CT_*.uasset"
        $totalChanges = 0
        $tablesModified = 0

        $stageDir = Join-Path ([System.IO.Path]::GetTempPath()) "WindrosePlus_ct_$(Get-Random)"
        New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

        try {
            foreach ($ctFile in $ctFiles) {
                $basename = $ctFile.BaseName

                # Check if this table has overrides from the INI config
                $tableOverrides = $null
                if ($ctConfig.Contains($basename)) {
                    $tableOverrides = $ctConfig[$basename]
                }
                if (-not $tableOverrides -or $tableOverrides.overrides.Count -eq 0) { continue }

                Write-Host "  Parsing $basename..."
                $manifest = Parse-CurveTable -UAssetPath $ctFile.FullName
                if ($manifest.Error) {
                    Write-Warning "    Parse error: $($manifest.Error)"
                    continue
                }

                $rowsWithKeys = ($manifest.Rows | Where-Object { $_.Keys.Count -gt 0 }).Count
                Write-Host "    $($manifest.RowCount) rows, $rowsWithKeys with patchable values"

                # Build config hashtable with overrides from INI
                $configHT = @{
                    overrides = $tableOverrides.overrides
                }

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

                # Copy files to staging
                $relPath = $ctFile.FullName.Substring($retocDir.Length).TrimStart('\','/')
                $stageUasset = Join-Path $stageDir $relPath
                $stageUexp = $stageUasset -replace '\.uasset$', '.uexp'
                $srcUexp = $ctFile.FullName -replace '\.uasset$', '.uexp'

                New-Item -ItemType Directory -Force -Path (Split-Path $stageUasset) | Out-Null
                Copy-Item $ctFile.FullName $stageUasset
                Copy-Item $srcUexp $stageUexp

                # Patch
                $patchResult = Invoke-CurveTablePatch -Manifest $manifest -Config $configHT -UExpPath $stageUexp
                if ($patchResult.Error) {
                    Write-Warning "    Patch error: $($patchResult.Error)"
                    continue
                }
                if ($patchResult.ChangesApplied -eq 0) {
                    Remove-Item $stageUasset -Force -ErrorAction SilentlyContinue
                    Remove-Item $stageUexp -Force -ErrorAction SilentlyContinue
                    Write-Host "    No changes needed"
                    continue
                }

                if (-not $patchResult.VerificationPassed) {
                    Write-Warning "    VERIFICATION FAILED — skipping this table"
                    Remove-Item $stageUasset -Force -ErrorAction SilentlyContinue
                    Remove-Item $stageUexp -Force -ErrorAction SilentlyContinue
                    continue
                }

                Write-Host "    Patched $($patchResult.ChangesApplied) values (verified)" -ForegroundColor Green
                $totalChanges += $patchResult.ChangesApplied
                $tablesModified++
            }

            if ($DryRun) {
                Write-Host "  [DRY RUN] Would patch $totalChanges values" -ForegroundColor DarkGray
            } elseif ($totalChanges -gt 0) {
                $repak = Find-Repak
                $outPak = Join-Path $paksDir "WindrosePlus_CurveTables_P.pak"
                & $repak pack $stageDir $outPak 2>&1 | Out-Null
                if (Test-Path -LiteralPath $outPak) {
                    $size = (Get-Item $outPak).Length
                    Write-Host "  OK: $tablesModified tables, $totalChanges values -> $outPak ($size bytes)" -ForegroundColor Green
                } else {
                    Write-Warning "  repak failed to create $outPak"
                }
            } else {
                Write-Host "  No CurveTable changes needed" -ForegroundColor DarkGray
                $stalePak = Join-Path $paksDir "WindrosePlus_CurveTables_P.pak"
                if (Test-Path -LiteralPath $stalePak) {
                    Remove-Item $stalePak -Force
                    Write-Host "  Removed stale $stalePak"
                }
            }
        } finally {
            Remove-Item -Recurse -Force $stageDir -ErrorAction SilentlyContinue
        }
    }
    Write-Host ""
} else {
    Write-Host "=== CurveTable PAK ===" -ForegroundColor Yellow
    Write-Host "  Skipped (no CurveTable values changed from defaults)" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "Done." -ForegroundColor Cyan
if (-not $DryRun) {
    Write-Host "Restart the game server for changes to take effect."
}
