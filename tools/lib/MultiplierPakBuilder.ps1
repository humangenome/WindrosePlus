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

function Build-MultiplierPak {
    <#
    .SYNOPSIS
    Builds a multiplier override PAK by extracting game JSONs, modifying values,
    and repacking.

    .PARAMETER Config
    Hashtable with multiplier values: loot, xp, stack_size, craft_cost, crop_speed, weight.
    Values of 1.0 are skipped (no change).

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

    $loot = if ($Config.ContainsKey("loot")) { [double]$Config.loot } else { 1.0 }
    $xp = if ($Config.ContainsKey("xp")) { [double]$Config.xp } else { 1.0 }
    $stackSize = if ($Config.ContainsKey("stack_size")) { [double]$Config.stack_size } else { 1.0 }
    $craftCost = if ($Config.ContainsKey("craft_cost")) { [double]$Config.craft_cost } else { 1.0 }
    $cropSpeed = if ($Config.ContainsKey("crop_speed")) { [double]$Config.crop_speed } else { 1.0 }
    $weight = if ($Config.ContainsKey("weight")) { [double]$Config.weight } else { 1.0 }
    $invSize = if ($Config.ContainsKey("inventory_size")) { [double]$Config.inventory_size } else { 1.0 }
    $pointsPerLvl = if ($Config.ContainsKey("points_per_level")) { [double]$Config.points_per_level } else { 1.0 }

    $allDefault = ($loot -eq 1.0 -and $xp -eq 1.0 -and $stackSize -eq 1.0 -and $craftCost -eq 1.0 -and $cropSpeed -eq 1.0 -and $weight -eq 1.0 -and $invSize -eq 1.0 -and $pointsPerLvl -eq 1.0)
    if ($allDefault) {
        $result.Error = "All multipliers are 1.0 (default). Nothing to build."
        return $result
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "WindrosePlus_pak_$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    try {
        $modifiedCount = 0

        # Loot tables
        if ($loot -ne 1.0) {
            Write-Host "  Modifying loot tables (${loot}x)..."
            $lootFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "LootTable"
            foreach ($lf in $lootFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $lf.Trim()
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.LootData) { continue }
                $changed = $false
                foreach ($item in $data.LootData) {
                    if ($null -ne $item.Min -and $null -ne $item.Max) {
                        $item.Min = [Math]::Max(1, [int]($item.Min * $loot))
                        $item.Max = [Math]::Max(1, [int]($item.Max * $loot))
                        $changed = $true
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $lf.Trim()
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                }
            }
            Write-Host "    Modified $modifiedCount loot tables"
        }

        # XP tables
        if ($xp -ne 1.0) {
            Write-Host "  Modifying XP tables (${xp}x)..."
            $xpFiles = @(
                "R5/Plugins/R5BusinessRules/Content/EntityProgression/DA_HeroLevels.json",
                "R5/Plugins/R5BusinessRules/Content/EntityProgression/Ship/DA_ShipLevels.json"
            )
            foreach ($xf in $xpFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $xf
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.Levels) { continue }
                $changed = $false
                foreach ($level in $data.Levels) {
                    if ($level.Exp -and $level.Exp -gt 0) {
                        $level.Exp = [Math]::Max(1, [int]($level.Exp / $xp))
                        $changed = $true
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $xf
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    Write-Host "    Modified $xf"
                }
            }
        }

        # Stack sizes and weight
        if ($stackSize -ne 1.0 -or $weight -ne 1.0) {
            Write-Host "  Modifying inventory items (stack=${stackSize}x, weight=${weight}x)..."
            $itemFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "InventoryItems/"
            $itemMod = 0
            foreach ($item in $itemFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $item.Trim()
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.InventoryItemGppData) { continue }
                $gpp = $data.InventoryItemGppData
                $changed = $false
                if ($stackSize -ne 1.0 -and $gpp.MaxCountInSlot -and $gpp.MaxCountInSlot -gt 0) {
                    $gpp.MaxCountInSlot = [Math]::Max(1, [int]($gpp.MaxCountInSlot * $stackSize))
                    $changed = $true
                }
                if ($weight -ne 1.0 -and $gpp.Weight -and $gpp.Weight -gt 0) {
                    $gpp.Weight = [Math]::Round($gpp.Weight * $weight, 4)
                    $changed = $true
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $item.Trim()
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    $itemMod++
                }
            }
            Write-Host "    Modified $itemMod items"
        }

        # Crafting costs
        if ($craftCost -ne 1.0) {
            Write-Host "  Modifying recipe costs (${craftCost}x)..."
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
                        $cost.Count = [Math]::Max(1, [int]($cost.Count / $craftCost))
                        $changed = $true
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $rf.Trim()
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    $recipeMod++
                }
            }
            Write-Host "    Modified $recipeMod recipes"
        }

        # Inventory slot counts
        if ($invSize -ne 1.0) {
            Write-Host "  Modifying inventory slot counts (${invSize}x)..."
            $slotFields = @('CountSlots', 'MaxSlots', 'InventorySize', 'SlotCount')
            $invFilesA = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "Inventory"
            $invFilesB = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "Character"
            $invFiles = @($invFilesA) + @($invFilesB) | Sort-Object -Unique
            $invMod = 0
            foreach ($if in $invFiles) {
                $fname = $if.Trim()
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $fname
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                $changed = $false
                foreach ($field in $slotFields) {
                    if ($null -ne $data.$field -and [int]$data.$field -gt 0) {
                        $data.$field = [Math]::Max(1, [int]([int]$data.$field * $invSize))
                        $changed = $true
                    }
                    if ($data.InventoryComponent -and $null -ne $data.InventoryComponent.$field -and [int]$data.InventoryComponent.$field -gt 0) {
                        $data.InventoryComponent.$field = [Math]::Max(1, [int]([int]$data.InventoryComponent.$field * $invSize))
                        $changed = $true
                    }
                }
                if ($changed) {
                    $outPath = Join-Path $tmpDir $fname
                    New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
                    $modifiedCount++
                    $invMod++
                }
            }
            Write-Host "    Modified $invMod inventory configs"
        }

        # Points per level (talent/stat/skill rewards on hero level progression).
        # DA_HeroLevels.json may already have been written by the XP patcher —
        # if so, re-read from tmpDir to preserve the XP modifications.
        if ($pointsPerLvl -ne 1.0) {
            Write-Host "  Modifying points per level (${pointsPerLvl}x)..."
            $pointFields = @('TalentPointsReward', 'StatPointsReward', 'PointsReward', 'SkillPoints', 'AttributePoints')
            $levelFile = "R5/Plugins/R5BusinessRules/Content/EntityProgression/DA_HeroLevels.json"
            $outPath = Join-Path $tmpDir $levelFile

            if (Test-Path -LiteralPath $outPath) {
                $data = Get-Content -LiteralPath $outPath -Raw | ConvertFrom-Json
                $alreadyWritten = $true
            } else {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $levelFile
                $data = if ($json) { $json | ConvertFrom-Json } else { $null }
                $alreadyWritten = $false
            }

            $pointsMod = 0
            if ($data -and $data.Levels) {
                $changed = $false
                foreach ($level in $data.Levels) {
                    foreach ($field in $pointFields) {
                        if ($null -ne $level.$field -and [int]$level.$field -gt 0) {
                            $level.$field = [Math]::Max(1, [int]([int]$level.$field * $pointsPerLvl))
                            $changed = $true
                        }
                    }
                }
                if ($changed) {
                    if (-not $alreadyWritten) {
                        New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                        $modifiedCount++
                    }
                    [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
                    $pointsMod++
                }
            }
            Write-Host "    Modified $pointsMod level entries"
        }

        # Crop growth speed (FIXED: divide duration to make faster, not max())
        if ($cropSpeed -ne 1.0) {
            Write-Host "  Modifying crop growth (${cropSpeed}x)..."
            $cropFiles = Invoke-RepakList -Repak $repak -AesKey $AesKey -PakPath $pak -Filter "Farming/Crops/"
            $cropMod = 0
            foreach ($cf in $cropFiles) {
                $json = Invoke-RepakGet -Repak $repak -AesKey $AesKey -PakPath $pak -FilePath $cf.Trim()
                if (-not $json) { continue }
                $data = $json | ConvertFrom-Json
                if (-not $data.GrowthDuration -or $data.GrowthDuration -le 0) { continue }
                # Divide duration by speed multiplier: 2x speed = half duration
                $data.GrowthDuration = [Math]::Max(1, [int]($data.GrowthDuration / $cropSpeed))
                $outPath = Join-Path $tmpDir $cf.Trim()
                New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
                [System.IO.File]::WriteAllText($outPath, ($data | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
                $modifiedCount++
                $cropMod++
            }
            Write-Host "    Modified $cropMod crops"
        }

        if ($modifiedCount -eq 0) {
            $result.Error = "No files were modified"
            return $result
        }

        # Pack into PAK
        $outPakPath = if ($ServerDir) {
            Join-Path $ServerDir "R5\Content\Paks\$OutputPak"
        } else {
            $OutputPak
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
