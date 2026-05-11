# MultiplierPakBuilder.ps1 — JSON-based multiplier PAK builder
# Modifies loot tables, XP progression, stack sizes, crafting costs,
# crop growth speed, and item weight by extracting JSON from the game pak,
# applying multipliers, and repacking.

function Find-Repak {
    <#
    .SYNOPSIS
    Locates the repak binary. Checks common locations.
    #>
    param([string]$CustomPath = "")

    if ($CustomPath -and (Test-Path -LiteralPath $CustomPath)) { return $CustomPath }

    $candidates = @(
        (Join-Path $PSScriptRoot "..\..\repak.exe"),
        (Join-Path $PSScriptRoot "..\repak.exe"),
        "repak.exe",
        "repak",
        "$env:USERPROFILE\.cargo\bin\repak.exe"
    )
    foreach ($c in $candidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { return $c }
        if (Test-Path -LiteralPath $c) { return (Resolve-Path $c).Path }
    }
    return $null
}

function Find-GamePak {
    <#
    .SYNOPSIS
    Locates the game's main pak file from the server directory.
    #>
    param([string]$ServerDir = "")

    if ($ServerDir) {
        $pak = Join-Path $ServerDir "R5\Content\Paks\pakchunk0-WindowsServer.pak"
        if (Test-Path -LiteralPath $pak) { return $pak }
        # Try client pak name
        $pak = Join-Path $ServerDir "R5\Content\Paks\pakchunk0-Windows.pak"
        if (Test-Path -LiteralPath $pak) { return $pak }
    }

    # Check current and parent directory
    foreach ($dir in @(".", "..")) {
        $pak = Join-Path $dir "R5\Content\Paks\pakchunk0-WindowsServer.pak"
        if (Test-Path -LiteralPath $pak) { return (Resolve-Path $pak).Path }
        $pak = Join-Path $dir "R5\Content\Paks\pakchunk0-Windows.pak"
        if (Test-Path -LiteralPath $pak) { return (Resolve-Path $pak).Path }
    }
    return $null
}

function Invoke-RepakGet {
    <#
    .SYNOPSIS
    Extracts a single file from a pak as text (for JSON files).
    #>
    param([string]$Repak, [string]$AesKey, [string]$PakPath, [string]$FilePath)

    $result = & $Repak --aes-key $AesKey get $PakPath $FilePath 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($result | Out-String)
}

function Invoke-RepakList {
    <#
    .SYNOPSIS
    Lists files in a pak, optionally filtered by a substring.
    #>
    param([string]$Repak, [string]$AesKey, [string]$PakPath, [string]$Filter = "")

    $result = & $Repak --aes-key $AesKey list $PakPath 2>&1
    $files = ($result | Out-String).Split("`n") | Where-Object { $_.Trim() -ne "" -and $_.Trim().EndsWith(".json") }
    if ($Filter) {
        $files = $files | Where-Object { $_ -match [regex]::Escape($Filter) }
    }
    return $files
}

function Get-WindrosePlusThirdPartyPaks {
    param([string]$ServerDir = "")

    $pakRoot = if ($ServerDir) {
        Join-Path $ServerDir "R5\Content\Paks"
    } else {
        Join-Path "." "R5\Content\Paks"
    }

    $pakDirs = @($pakRoot, (Join-Path $pakRoot "~mods"))
    $paks = @()

    foreach ($dir in $pakDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $paks += Get-ChildItem -LiteralPath $dir -Filter "*.pak" -File -ErrorAction SilentlyContinue | Where-Object {
            $name = $_.Name
            $name -notlike "pakchunk*-Windows*.pak" -and
            $name -notlike "pakchunk*-WindowsServer*.pak" -and
            $name -ne "WindrosePlus_Multipliers_P.pak" -and
            $name -ne "WindrosePlus_CurveTables_P.pak"
        }
    }

    return @($paks)
}

function Test-WindrosePlusPakConflicts {
    param(
        [string]$Repak,
        [string]$AesKey,
        [string]$ServerDir = "",
        [string[]]$Needles
    )

    $allow = "$env:WINDROSEPLUS_ALLOW_PAK_CONFLICTS".ToLowerInvariant()
    if ($allow -in @("1", "true", "yes", "on")) { return @() }

    $paks = @(Get-WindrosePlusThirdPartyPaks -ServerDir $ServerDir)
    if ($paks.Count -eq 0) { return @() }

    $conflicts = @()
    foreach ($pakFile in $paks) {
        $raw = & $Repak --aes-key $AesKey list $pakFile.FullName 2>&1
        $listExit = $LASTEXITCODE
        if ($listExit -ne 0) {
            $raw = & $Repak list $pakFile.FullName 2>&1
            $listExit = $LASTEXITCODE
        }

        if ($listExit -ne 0) {
            $message = ($raw | Out-String).Trim()
            if ($message.Length -gt 140) { $message = $message.Substring(0, 140) + "..." }
            $conflicts += [pscustomobject]@{
                Pak = $pakFile.Name
                Asset = "unable to inspect PAK contents ($message)"
            }
            continue
        }

        $seenForPak = 0
        foreach ($line in (($raw | Out-String).Split("`n"))) {
            $asset = $line.Trim()
            if (-not $asset) { continue }

            foreach ($needle in $Needles) {
                if ($asset.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $conflicts += [pscustomobject]@{
                        Pak = $pakFile.Name
                        Asset = $asset
                    }
                    $seenForPak++
                    break
                }
            }

            if ($seenForPak -ge 5) {
                $conflicts += [pscustomobject]@{
                    Pak = $pakFile.Name
                    Asset = "additional matching assets omitted"
                }
                break
            }
        }
    }

    return @($conflicts)
}

# Parse windrose_plus.harvest.ini into a {ResourceName -> multiplier}
# hashtable. Section headers are ignored; only `Key = Number` lines are
# read. Inline `;` comments are stripped. Values clamped to >= 0.01.
# Missing file or no readable values -> empty hashtable.
function Read-HarvestIni {
    param([string]$Path)
    $out = @{}
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $out }
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        $first = $line[0]
        if ($first -eq ';' -or $first -eq '#' -or $first -eq '[') { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1)
        $semi = $val.IndexOf(';')
        if ($semi -ge 0) { $val = $val.Substring(0, $semi) }
        $val = $val.Trim()
        if (-not $val) {
            Write-Warning "Read-HarvestIni: '$key =' has no value (line skipped)"
            continue
        }
        $d = 0.0
        if ([double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
            $out[$key] = [Math]::Max(0.01, $d)
        } else {
            Write-Warning "Read-HarvestIni: '$key = $val' is not a number (expected e.g. '5.0', not '5x'); line skipped"
        }
    }
    return $out
}

# Pull the resource family from a UE asset soft-object path. Matches both
# loot-table item paths (`.../Resource_Wood_T01...`) and the BP_Mineral_*
# blueprint paths used in ResourceSpawner Assets[]
# (`/Game/.../BP_Mineral_Clay_T01_C`). Returns $null when nothing matches.
#
# Note: the Linux docker installer's sed pass rewrites `\<alnum>` between
# alnum chars to `/<alnum>` (path-separator fixup for Windows literals),
# which would mangle regex shorthand like `\d` to `/d`. Use [0-9] instead.
function Get-ResourceFamily {
    param([string]$LootItemPath)
    if (-not $LootItemPath) { return $null }
    if ($LootItemPath -match '(?:Resource|Mineral)_([A-Za-z][A-Za-z0-9]*)_T[0-9]') {
        return $Matches[1]
    }
    return $null
}

function ConvertTo-DropInt {
    param(
        [double]$Value,
        [double]$Multiplier
    )

    $scaled = $Value * $Multiplier
    if ($Multiplier -gt 1.0 -and $scaled -gt $Value) {
        return [Math]::Max(1, [int][Math]::Ceiling($scaled - 0.000001))
    }
    return [Math]::Max(1, [int][Math]::Floor($scaled + 0.000001))
}

function Build-MultiplierPak {
    <#
    .SYNOPSIS
    Builds a multiplier override PAK by extracting game JSONs, modifying values,
    and repacking.

    .PARAMETER Config
    Hashtable with multiplier values: loot, xp, stack_size, craft_efficiency, crop_speed, weight.
    Values of 1.0 are skipped (no change). The legacy key craft_cost is accepted with
    identical semantics and normalized to craft_efficiency at function entry.

    .PARAMETER AesKey
    The game's AES encryption key for pak access.

    .PARAMETER ServerDir
    Path to the game server directory (used to find the pak and output).

    .PARAMETER RepakPath
    Optional path to repak binary.

    .PARAMETER OutputPak
    Output pak filename. Defaults to WindrosePlus_Multipliers_P.pak.
    #>
    param(
        [hashtable]$Config,
        [string]$AesKey,
        [string]$ServerDir = "",
        [string]$RepakPath = "",
        [string]$OutputPak = "WindrosePlus_Multipliers_P.pak"
    )

    $result = @{
        ModifiedFiles = 0
        OutputPath = ""
        Error = $null
    }

    # Normalize legacy craft_cost -> craft_efficiency before any downstream read,
    # so non-default counters and the math below see a single canonical key.
    if ($Config.ContainsKey("craft_cost")) {
        if (-not $Config.ContainsKey("craft_efficiency")) {
            $Config["craft_efficiency"] = $Config["craft_cost"]
        }
        $null = $Config.Remove("craft_cost")
    }

    $disabledPakMultipliers = @("points_per_level", "stack_size", "weight", "inventory_size", "crop_speed")
    $effectiveNonDefaultMultipliers = 0
    foreach ($entry in $Config.GetEnumerator()) {
        if ($disabledPakMultipliers -contains $entry.Key) { continue }
        if ([double]$entry.Value -ne 1.0) { $effectiveNonDefaultMultipliers++ }
    }

    $repak = Find-Repak -CustomPath $RepakPath
    if (-not $repak) {
        $result.Error = "repak not found. Install with: cargo install --git https://github.com/trumank/repak.git repak_cli"
        return $result
    }

    $pak = Find-GamePak -ServerDir $ServerDir
    if (-not $pak) {
        $result.Error = "Game PAK not found. Set server_dir in config or pass --server-dir."
        return $result
    }

    function Get-EffectiveMultiplier {
        param(
            [string]$Name,
            [hashtable]$Values,
            [string[]]$DisabledKeys
        )

        if ($DisabledKeys -contains $Name) { return 1.0 }
        if ($Values.ContainsKey($Name)) { return [double]$Values[$Name] }
        return 1.0
    }

    $loot = Get-EffectiveMultiplier -Name "loot" -Values $Config -DisabledKeys $disabledPakMultipliers
    $xp = Get-EffectiveMultiplier -Name "xp" -Values $Config -DisabledKeys $disabledPakMultipliers
    $stackSize = Get-EffectiveMultiplier -Name "stack_size" -Values $Config -DisabledKeys $disabledPakMultipliers
    $craftEfficiency = Get-EffectiveMultiplier -Name "craft_efficiency" -Values $Config -DisabledKeys $disabledPakMultipliers
    $cropSpeed = Get-EffectiveMultiplier -Name "crop_speed" -Values $Config -DisabledKeys $disabledPakMultipliers
    $weight = Get-EffectiveMultiplier -Name "weight" -Values $Config -DisabledKeys $disabledPakMultipliers
    $invSize = Get-EffectiveMultiplier -Name "inventory_size" -Values $Config -DisabledKeys $disabledPakMultipliers
    $pointsPerLvl = Get-EffectiveMultiplier -Name "points_per_level" -Values $Config -DisabledKeys $disabledPakMultipliers
    $cookSpeed = Get-EffectiveMultiplier -Name "cooking_speed" -Values $Config -DisabledKeys $disabledPakMultipliers
    $harvestYield = Get-EffectiveMultiplier -Name "harvest_yield" -Values $Config -DisabledKeys $disabledPakMultipliers

    # Clamp to prevent div-by-zero / negative-duration math when the builder is
    # invoked standalone (Lua clamps, but the PS1 also runs from -BuildPak directly).
    $loot = [Math]::Max(0.01, $loot)
    $xp = [Math]::Max(0.01, $xp)
    $stackSize = [Math]::Max(0.01, $stackSize)
    $craftEfficiency = [Math]::Max(0.01, $craftEfficiency)
    $cropSpeed = [Math]::Max(0.01, $cropSpeed)
    $weight = [Math]::Max(0.01, $weight)
    $invSize = [Math]::Max(0.01, $invSize)
    $pointsPerLvl = [Math]::Max(0.01, $pointsPerLvl)
    $cookSpeed = [Math]::Max(0.01, $cookSpeed)
    $harvestYield = [Math]::Max(0.01, $harvestYield)

    # Per-resource harvest overrides from windrose_plus.harvest.ini
    # (optional). Stacks multiplicatively on $harvestYield.
    $harvestIniPath = if ($ServerDir) { Join-Path $ServerDir "windrose_plus.harvest.ini" } else { $null }
    $perResource = Read-HarvestIni -Path $harvestIniPath
    $perResourceActive = $false
    foreach ($v in $perResource.Values) { if ($v -ne 1.0) { $perResourceActive = $true; break } }

    $allDefault = ($effectiveNonDefaultMultipliers -eq 0 -and -not $perResourceActive)
    if ($allDefault) {
        $result.Error = "All multipliers are 1.0 (default). Nothing to build."
        return $result
    }

    $outPakPath = if ($ServerDir) {
        Join-Path $ServerDir "R5\Content\Paks\$OutputPak"
    } else {
        $OutputPak
    }

    $riskMultipliers = @()
    if ($stackSize -ne 1.0) { $riskMultipliers += "stack_size" }
    if ($weight -ne 1.0) { $riskMultipliers += "weight" }
    if ($invSize -ne 1.0) { $riskMultipliers += "inventory_size" }

    if ($riskMultipliers.Count -gt 0) {
        $allow = "$env:WINDROSEPLUS_ALLOW_PAK_CONFLICTS".ToLowerInvariant()
        if ($allow -in @("1", "true", "yes", "on")) {
            Write-Warning "Skipping third-party PAK conflict check because WINDROSEPLUS_ALLOW_PAK_CONFLICTS is set."
        } else {
            Write-Host "  Checking existing PAK mods for inventory/save conflicts..."
            $conflicts = @(Test-WindrosePlusPakConflicts `
                -Repak $repak `
                -AesKey $AesKey `
                -ServerDir $ServerDir `
                -Needles @("InventoryItems/", "/Inventory", "Inventory/"))

            if ($conflicts.Count -gt 0) {
                $sample = $conflicts | Select-Object -First 8 | ForEach-Object { "$($_.Pak): $($_.Asset)" }
                $more = if ($conflicts.Count -gt 8) { " (+$($conflicts.Count - 8) more)" } else { "" }
                $staleNote = ""
                if (Test-Path -LiteralPath $outPakPath) {
                    try {
                        Remove-Item -LiteralPath $outPakPath -Force -ErrorAction Stop
                        $staleNote = " Existing $OutputPak was removed so a stale high-risk override cannot load after this failure."
                    } catch {
                        $staleNote = " Existing $OutputPak could not be removed automatically: $($_.Exception.Message). Delete it manually before launching the server."
                    }
                }
                $result.OutputPath = $outPakPath
                $result.Error = "Refusing to build high-risk multiplier PAK because $($riskMultipliers -join ', ') changes inventory/save-affecting assets and existing PAK mod(s) also touch inventory assets: $($sample -join '; ')$more. Remove the conflicting PAK(s), rebuild, and restore a pre-change save backup if affected players already joined.$staleNote Advanced admins can set WINDROSEPLUS_ALLOW_PAK_CONFLICTS=1 to override after testing the exact PAK combination."
                return $result
            }
        }
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "WindrosePlus_pak_$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    try {
        $modifiedCount = 0

        # Loot tables
        if ($loot -ne 1.0) {
            Write-Host "  Modifying loot tables (${loot}x)..."
            $lootFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "LootTable"
            $lootMod = 0
            foreach ($lf in $lootFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $lf.Trim()
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.LootData) { continue }
                $changed = $false
                foreach ($item in $data.LootData) {
                    # Skip equipment drops — multiplying weapons/armor/jewelry produces duplicate
                    # gear stacks and breaks unique-item gameplay (issue #3).
                    if ($item.LootItem -and $item.LootItem -like "*/InventoryItems/Equipments/*") { continue }
                    # Skip sub-table roll-count references. LootData entries come in two
                    # shapes: direct item drops (LootItem set, LootTable="None", where Min/Max
                    # is the per-roll item count) and sub-table references (LootItem="None",
                    # LootTable set, where Min/Max is the *number of times to roll the
                    # referenced sub-table*). Scaling Min/Max on a sub-table reference
                    # composes multiplicatively with the scaling already applied to the
                    # sub-table's own item entries, producing the squared-multiplier bug
                    # in issue #94 (e.g. loot=8.0 → 64x Plague Thrall / Senkamati drops).
                    # The sub-table itself is matched by the same Invoke-RepakList pass and
                    # gets its direct-item Min/Max scaled exactly once, which is correct.
                    if ($item.LootTable -and $item.LootTable -ne "None" -and $item.LootTable -ne "") { continue }
                    if ($null -ne $item.Min -and $null -ne $item.Max) {
                        $item.Min = ConvertTo-DropInt -Value $item.Min -Multiplier $loot
                        $item.Max = ConvertTo-DropInt -Value $item.Max -Multiplier $loot
                        $changed = $true
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $lf.Trim()
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    $lootMod++
                }
            }
            Write-Host "    Modified $lootMod loot tables"
            if ($lootMod -eq 0) {
                Write-Warning "loot=${loot}x configured but zero loot tables matched — LootTable filter or LootData[].Min/Max schema may have been renamed by a recent engine update."
            }
        }

        # XP tables
        if ($xp -ne 1.0) {
            Write-Host "  Modifying XP tables (${xp}x)..."
            $xpFiles = @(
                "R5/Plugins/R5BusinessRules/Content/EntityProgression/DA_HeroLevels.json",
                "R5/Plugins/R5BusinessRules/Content/EntityProgression/Ship/DA_ShipLevels.json"
            )
            $xpMod = 0
            foreach ($xf in $xpFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $xf
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.Levels) { continue }
                $changed = $false
                foreach ($level in $data.Levels) {
                    if ($level.Exp -and $level.Exp -gt 0) {
                        $level.Exp = [Math]::Max(1, [long]($level.Exp / $xp))
                        $changed = $true
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $xf
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    $xpMod++
                    Write-Host "    Modified $xf"
                }
            }
            if ($xpMod -eq 0) {
                Write-Warning "xp=${xp}x configured but zero XP tables matched — DA_HeroLevels / DA_ShipLevels paths or Levels[].Exp schema may have been renamed by a recent engine update."
            }
        }

        # stack_size and weight patching intentionally disabled (v1.0.14).
        # Multiple live production servers with non-default stack_size (or stack+inv) crashed
        # repeatedly with the same R5BLBusinessRule.h:374 "Inventory.Module.Default" data-
        # inconsistency signature as the previously-disabled points_per_level path. Even the
        # narrower `MaxCountInSlot > 1` guard (originally issue #3) did not prevent the engine's
        # inventory-module validator from rejecting stacked state at runtime. No safe patch
        # path found until the validator is understood or relaxed.
        if ($stackSize -ne 1.0 -or $weight -ne 1.0) {
            Write-Host "  Skipping stack_size/weight (disabled due to engine inventory validator crash)"
        }

        # Crafting efficiency: divide ingredient Count by efficiency multiplier so
        # craft_efficiency 2.0 -> recipes cost half (more efficient).
        if ($craftEfficiency -ne 1.0) {
            Write-Host "  Modifying recipe costs (craft_efficiency ${craftEfficiency}x)..."
            $recipeFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "Recipes/"
            $recipeMod = 0
            foreach ($rf in $recipeFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $rf.Trim()
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.RecipeCost -or $data.RecipeCost -isnot [array]) { continue }
                $changed = $false
                foreach ($cost in $data.RecipeCost) {
                    if ($cost.Count -and $cost.Count -gt 0) {
                        $cost.Count = [Math]::Max(1, [int]($cost.Count / $craftEfficiency))
                        $changed = $true
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $rf.Trim()
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    $recipeMod++
                }
            }
            Write-Host "    Modified $recipeMod recipes"
            if ($recipeMod -eq 0) {
                Write-Warning "craft_efficiency=${craftEfficiency}x configured but zero recipes matched — Recipes/ filter or RecipeCost[].Count schema may have been renamed by a recent engine update."
            }
        }

        # inventory_size patching intentionally disabled (v1.0.14).
        # Inflated CountSlots/MaxSlots on inventory components triggers the same
        # R5BLBusinessRule.h:374 "Inventory.Module.Default" validator crash documented for
        # stack_size above. Additionally: slot counts bake into character saves (time-bomb
        # property) — once a character has allocated beyond vanilla bounds, lowering inv_size
        # makes the save fail vanilla validation and the server refuses to load the character.
        # Keep disabled until a validator-aware patch path exists AND a character sanitizer
        # can safely restore save files after a rollback.
        if ($invSize -ne 1.0) {
            Write-Host "  Ignoring inventory_size (disabled/no-op due to engine validator crash + character-save time-bomb)"
        }

        # points_per_level patching intentionally disabled.
        # Multiplying TalentPointsReward / StatPointsReward / PointsReward / SkillPoints /
        # AttributePoints in DA_HeroLevels.json trips the engine's ValidateProgression check
        # on fresh character spawn: R5BLPlayer_ValidateData fails Condition
        # 'RewardLevel < CurrentLevel' and the server aborts with R5GameProblems "data
        # inconsistency". Isolated with a minimal reproduction (pts=3 alone, vanilla Exp,
        # no UE4SS, virgin world, single-file PAK) which still crashed. No safe patch path
        # known until the engine's validator is understood or relaxed.
        if ($pointsPerLvl -ne 1.0) {
            Write-Host "  Skipping points_per_level (disabled due to engine ValidateProgression crash)"
        }

        # crop_speed patching intentionally disabled (v1.1.10).
        # Live server logs showed non-default crop_speed can trip
        # UR5CropComponent::UpdateCropStage with UpdateCropStageTime <= 0, then
        # Windrose stops the server for data inconsistency. Keep the setting
        # visible in config/status, but do not write a PAK override until a
        # validator-safe crop timing path exists.
        if ($cropSpeed -ne 1.0) {
            Write-Host "  Skipping crop_speed (disabled due to engine crop timing validator crash)"
        }

        # Cooking / production duration (alchemy elixirs, fermentation, smelting, etc.)
        # Divide CookingProcessDuration by multiplier: 2x speed = half duration.
        if ($cookSpeed -ne 1.0) {
            Write-Host "  Modifying cooking/production speed (${cookSpeed}x)..."
            $cookFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "Recipes/"
            $cookMod = 0
            foreach ($cf in $cookFiles) {
                $fname = $cf.Trim()
                # Reuse craft_efficiency output if it already wrote to this file
                $outPath = Join-Path $tmpDir $fname
                if (Test-Path -LiteralPath $outPath) {
                    # Read explicit UTF-8 — Get-Content -Raw on PS 5.1 falls back to ANSI for BOM-less files.
                    $data = [System.IO.File]::ReadAllText($outPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
                    $alreadyWritten = $true
                } else {
                    $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $fname
                    if (-not $json) { continue }
                    $data = $json | ConvertFrom-Json
                    $alreadyWritten = $false
                }
                if ($null -eq $data.CookingProcessDuration -or $data.CookingProcessDuration -le 0) { continue }
                $data.CookingProcessDuration = [Math]::Max(1, [long]($data.CookingProcessDuration / $cookSpeed))
                if (-not $alreadyWritten) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    $modifiedCount++
                }
                [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                $cookMod++
            }
            Write-Host "    Modified $cookMod recipes"
            if ($cookMod -eq 0) {
                Write-Warning "cooking_speed=${cookSpeed}x configured but zero recipes had a CookingProcessDuration to scale — Recipes/ filter or CookingProcessDuration field may have been renamed by a recent engine update."
            }
        }

        # Harvest yield (gatherable resource spawn amounts: berries, ore, wood, etc.)
        # Multiplies Variants[].Collection[].Amount.Min/Max in ResourceSpawner JSONs,
        # plus LootData[].Min/Max in mineral foliage loot tables (copper/iron/etc.
        # nodes are loot-table-driven, not ResourceSpawner-driven). Does not touch
        # RespawnInterval — yield per node, not respawn rate.
        # Per-resource overrides from windrose_plus.harvest.ini stack multiplicatively.
        if ($harvestYield -ne 1.0 -or $perResourceActive) {
            if ($perResourceActive) {
                $perResStr = ($perResource.GetEnumerator() | Where-Object { $_.Value -ne 1.0 } | ForEach-Object { "$($_.Key)=$($_.Value)x" }) -join ", "
                Write-Host "  Modifying harvest yields (base=${harvestYield}x; per-resource: $perResStr)..."
            } else {
                Write-Host "  Modifying harvest yields (${harvestYield}x)..."
            }

            # Per-family applied counter — increments each time a non-default
            # per-resource multiplier is matched against an asset family.
            # Surfaces typos: a configured `Wod=5.0` produces no matches and
            # ends up reported as `Wod=0` in the summary line below.
            $perFamilyApplied = @{}
            foreach ($k in $perResource.Keys) {
                if ($perResource[$k] -ne 1.0) { $perFamilyApplied[$k] = 0 }
            }

            $harvFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "ResourcesSpawners/"
            $harvMod = 0
            foreach ($hf in $harvFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $hf.Trim()
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.Variants) { continue }
                $changed = $false
                foreach ($variant in $data.Variants) {
                    if (-not $variant.Collection) { continue }
                    foreach ($entry in $variant.Collection) {
                        if ($null -ne $entry.Amount -and $null -ne $entry.Amount.Min -and $null -ne $entry.Amount.Max) {
                            $resMult = 1.0
                            # ResourceSpawner entries reference one or more BP
                            # asset paths via Assets[] (e.g. BP_Mineral_Clay_T01).
                            # Use the first that yields a family.
                            $family = $null
                            if ($entry.Assets) {
                                foreach ($a in $entry.Assets) {
                                    $f = Get-ResourceFamily -LootItemPath $a
                                    if ($f) { $family = $f; break }
                                }
                            }
                            if ($family -and $perResource.ContainsKey($family)) {
                                $resMult = $perResource[$family]
                                if ($perFamilyApplied.ContainsKey($family)) { $perFamilyApplied[$family]++ }
                            }
                            $eff = $harvestYield * $resMult
                            if ($eff -eq 1.0) { continue }
                            $entry.Amount.Min = ConvertTo-DropInt -Value $entry.Amount.Min -Multiplier $eff
                            $entry.Amount.Max = ConvertTo-DropInt -Value $entry.Amount.Max -Multiplier $eff
                            $changed = $true
                        }
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $hf.Trim()
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    $harvMod++
                }
            }
            Write-Host "    Modified $harvMod resource spawners"

            # Foliage/resource loot tables (LootTables/Foliage/*.json): trees,
            # shipwreck debris, copper/iron/etc. nodes, and several resource
            # props are loot-table-driven and don't appear in ResourcesSpawners/.
            # Use the same LootData[].Min/Max schema as the loot pass. If the
            # loot pass already wrote this file in tmpDir, read from there so
            # the multipliers stack.
            $foliageFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "LootTables/Foliage/"
            $foliageMod = 0
            foreach ($ff in $foliageFiles) {
                $ffTrim = $ff.Trim()
                $outPath = Join-Path $tmpDir $ffTrim
                $existedBefore = Test-Path -LiteralPath $outPath
                if ($existedBefore) {
                    $json = Get-Content -LiteralPath $outPath -Raw
                } else {
                    $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $ffTrim
                }
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.LootData) { continue }
                $changed = $false
                foreach ($item in $data.LootData) {
                    if ($item.LootItem -and $item.LootItem -like "*/InventoryItems/Equipments/*") { continue }
                    # Skip sub-table roll-count references (see issue #94 comment in the main loot pass).
                    if ($item.LootTable -and $item.LootTable -ne "None" -and $item.LootTable -ne "") { continue }
                    if ($null -ne $item.Min -and $null -ne $item.Max) {
                        $resMult = 1.0
                        $family = Get-ResourceFamily -LootItemPath $item.LootItem
                        if ($family -and $perResource.ContainsKey($family)) {
                            $resMult = $perResource[$family]
                            if ($perFamilyApplied.ContainsKey($family)) { $perFamilyApplied[$family]++ }
                        }
                        $eff = $harvestYield * $resMult
                        if ($eff -eq 1.0) { continue }
                        $item.Min = ConvertTo-DropInt -Value $item.Min -Multiplier $eff
                        $item.Max = ConvertTo-DropInt -Value $item.Max -Multiplier $eff
                        $changed = $true
                    }
                }
                if ($changed) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                    if (-not $existedBefore) { $modifiedCount++ }
                    $foliageMod++
                }
            }
            if ($foliageMod -gt 0) { Write-Host "    Modified $foliageMod foliage loot tables" }

            # Pickup-resource loot tables (LootTables/PickupResource/*.json):
            # sulfur pickup chests, salt rocks, mushrooms, shells, dodo eggs,
            # etc. Same LootData[].Min/Max schema as foliage. The loot pass
            # already scaled these by loot multiplier; stack harvest_yield
            # (and any per-resource override) on top by reading the working
            # file from tmpDir if present.
            $pickupFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "LootTables/PickupResource/"
            $pickupMod = 0
            foreach ($pf in $pickupFiles) {
                $pfTrim = $pf.Trim()
                $outPath = Join-Path $tmpDir $pfTrim
                $existedBefore = Test-Path -LiteralPath $outPath
                if ($existedBefore) {
                    $json = Get-Content -LiteralPath $outPath -Raw
                } else {
                    $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $pfTrim
                }
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.LootData) { continue }
                $changed = $false
                foreach ($item in $data.LootData) {
                    if ($item.LootItem -and $item.LootItem -like "*/InventoryItems/Equipments/*") { continue }
                    # Skip sub-table roll-count references (see issue #94 comment in the main loot pass).
                    if ($item.LootTable -and $item.LootTable -ne "None" -and $item.LootTable -ne "") { continue }
                    if ($null -ne $item.Min -and $null -ne $item.Max) {
                        $resMult = 1.0
                        $family = Get-ResourceFamily -LootItemPath $item.LootItem
                        if ($family -and $perResource.ContainsKey($family)) {
                            $resMult = $perResource[$family]
                            if ($perFamilyApplied.ContainsKey($family)) { $perFamilyApplied[$family]++ }
                        }
                        $eff = $harvestYield * $resMult
                        if ($eff -eq 1.0) { continue }
                        $item.Min = ConvertTo-DropInt -Value $item.Min -Multiplier $eff
                        $item.Max = ConvertTo-DropInt -Value $item.Max -Multiplier $eff
                        $changed = $true
                    }
                }
                if ($changed) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                    if (-not $existedBefore) { $modifiedCount++ }
                    $pickupMod++
                }
            }
            if ($pickupMod -gt 0) { Write-Host "    Modified $pickupMod pickup resource loot tables" }

            # Segmented trees and cave dig volumes use contextual destroy
            # scores instead of the LootData tables above. Each file maps
            # to a single resource family for the per-resource multiplier;
            # `null` family means "use harvest_yield only".
            $contextualHarvestFiles = @(
                @{ Path = "R5/Content/Gameplay/ContextualSpawners/DA_ContextualSpawnerParams_Player_SegmentTreesAndMineralDestroy.json"; Family = "Wood" },
                @{ Path = "R5/Content/Gameplay/ContextualSpawners/DA_ContextualSpawnerParams_Player_CopperCaves_DigVolumesDestroy.json"; Family = "CopperOre" },
                @{ Path = "R5/Content/Gameplay/ContextualSpawners/DA_ContextualSpawnerParams_Player_IronCaverns_DigVolumesDestroy.json"; Family = "Iron" }
            )
            $contextualMod = 0
            foreach ($cfEntry in $contextualHarvestFiles) {
                $cf = $cfEntry.Path
                $cfResMult = 1.0
                if ($cfEntry.Family -and $perResource.ContainsKey($cfEntry.Family)) {
                    $cfResMult = $perResource[$cfEntry.Family]
                }
                $cfEff = $harvestYield * $cfResMult
                if ($cfEff -eq 1.0) { continue }
                $outPath = Join-Path $tmpDir $cf
                $existedBefore = Test-Path -LiteralPath $outPath
                if ($existedBefore) {
                    $json = Get-Content -LiteralPath $outPath -Raw
                } else {
                    $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $cf
                }
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.EventHandlers) { continue }
                $changed = $false
                if ($null -ne $data.MaxScore) {
                    $data.MaxScore = [Math]::Max(0.0, [Math]::Round(([double]$data.MaxScore) * $cfEff, 4))
                    $changed = $true
                }
                foreach ($handler in $data.EventHandlers) {
                    if ($null -ne $handler.Score -and $null -ne $handler.Score.Min -and $null -ne $handler.Score.Max) {
                        $handler.Score.Min = [Math]::Max(0.0, [Math]::Round(([double]$handler.Score.Min) * $cfEff, 4))
                        $handler.Score.Max = [Math]::Max(0.0, [Math]::Round(([double]$handler.Score.Max) * $cfEff, 4))
                        $changed = $true
                    }
                }
                if ($changed) {
                    # Only credit the per-resource family AFTER a real patch landed.
                    # Pre-incrementing on entry suppressed the unmatched-keys warning
                    # when an engine update moved the contextual path or schema.
                    if ($cfEntry.Family -and $perFamilyApplied.ContainsKey($cfEntry.Family)) {
                        $perFamilyApplied[$cfEntry.Family]++
                    }
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
                    if (-not $existedBefore) { $modifiedCount++ }
                    $contextualMod++
                }
            }
            if ($contextualMod -gt 0) { Write-Host "    Modified $contextualMod contextual destroy score tables" }

            if ($perResourceActive) {
                $report = ($perFamilyApplied.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
                Write-Host "    Per-resource matches: $report"
                $unmatched = @($perFamilyApplied.GetEnumerator() | Where-Object { $_.Value -eq 0 } | ForEach-Object { $_.Key })
                if ($unmatched.Count -gt 0) {
                    Write-Warning "Per-resource keys with zero matches (typo or unsupported family?): $($unmatched -join ', ')"
                }
            }

            # If a base harvest_yield multiplier was requested but every harvest pass
            # came back empty, that's an engine-rename signature (ResourcesSpawners/,
            # LootTables/Foliage/, LootTables/PickupResource/, ContextualSpawners/
            # paths or their inner schemas changed). Per-resource-only configs with
            # all-zero matches already surface via the unmatched-keys warning above.
            if ($harvestYield -ne 1.0 -and ($harvMod + $foliageMod + $pickupMod + $contextualMod) -eq 0) {
                Write-Warning "harvest_yield=${harvestYield}x configured but zero harvest files matched across resource spawners, foliage loot, pickup loot, and contextual destroy scores — one or more harvest paths/schemas may have been renamed by a recent engine update."
            }
        }

        if ($modifiedCount -eq 0) {
            # Only treat zero-modifications as a clean no-op when there was
            # nothing to apply in the first place. A per-resource-only config
            # (harvestYield=1.0, Wood=5.0 in harvest.ini) has
            # effectiveNonDefaultMultipliers=0, so without the perResourceActive
            # check below, an engine-renamed harvest path or schema would mask
            # itself as "no work to do" and return success. With it, the build
            # raises "No files were modified" and the caller can act.
            if ($effectiveNonDefaultMultipliers -eq 0 -and -not $perResourceActive) {
                Write-Host "  No active multiplier files were modified; removing stale $outPakPath if present"
                if (Test-Path -LiteralPath $outPakPath) {
                    Remove-Item -LiteralPath $outPakPath -Force
                }
                $result.OutputPath = $outPakPath
                return $result
            }
            $result.Error = "No files were modified"
            return $result
        }

        & $repak pack $tmpDir $outPakPath 2>&1 | Out-Null
        $packExit = $LASTEXITCODE
        if ($packExit -ne 0 -or -not (Test-Path -LiteralPath $outPakPath)) {
            $result.Error = "repak failed to create $outPakPath (exit $packExit)"
            return $result
        }

        $result.ModifiedFiles = $modifiedCount
        $result.OutputPath = $outPakPath
        Write-Host "  Packed $modifiedCount files into $outPakPath"

    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }

    return $result
}
