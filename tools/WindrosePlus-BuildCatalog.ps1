<#
.SYNOPSIS
    Builds the Sea Chart item catalog from this server's own Windrose game files.

.DESCRIPTION
    Windrose keeps its item, recipe, crafting-station, trader and loot data as
    JSON inside R5\Content\Paks\pakchunk0-WindowsServer.pak, and the item text in
    the English localisation file next to it. This script unpacks only those
    folders with the bundled repak, reads them, and writes the three files the
    Sea Chart's Items panel loads:

        items_full.json   every item: name, description, rarity, type, stack,
                          tags, effect text, and where it drops
        item_usage.json   recipes that make or use each item, with stations,
                          trader buy/sell offers, and building costs
        _summary.json     counts and the game-file fingerprint the catalog was
                          built from

    Nothing from the game ships with Windrose+: the catalog is made on the
    server, from the server's copy of the game, and rebuilt after a game update.
    The dashboard runs this script by itself when the catalog is missing or the
    game files changed. Run it by hand with -Force to rebuild.

    Stat values and the numbers in effect text come from the game's curve tables,
    which retoc reads out of the IoStore container (CT_* tables only). Not in the
    catalog: item art (the icons are Windrose+'s own, one per kind of item) and the
    old resource-zone map hints, which were never part of the game's data.

.PARAMETER GameDir
    The Windrose dedicated server folder (the one with the R5 folder in it).

.PARAMETER OutputDir
    Where to write the catalog. Default: <GameDir>\windrose_plus_data\catalog\v1

.PARAMETER SourceDir
    An already-unpacked copy of the pak (skips the unpack step).

.PARAMETER Force
    Rebuild even when the game files have not changed since the last build.

.PARAMETER Vanilla
    Read stat values from the game's own container only, leaving out this
    server's settings override (WindrosePlus_CurveTables_P). By default the
    catalog shows the values this server actually uses.
#>
param(
    [string]$GameDir = "",
    [string]$OutputDir = "",
    [string]$SourceDir = "",
    [string]$WorkDir = "",
    [string]$Repak = "",
    [string]$Retoc = "",
    [string]$CurveTableDir = "",
    [string]$LogFile = "",
    [switch]$Force,
    [switch]$KeepWork,
    [switch]$Vanilla
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# 2: every stat entry carries a readable "label" (tools/lib/StatLabels.ps1)
$BuilderVersion = "2"

if ($LogFile) {
    $logDir = Split-Path -Parent $LogFile
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Set-Content -LiteralPath $LogFile -Value ("[wp-catalog] started {0:u}" -f (Get-Date).ToUniversalTime()) -Encoding UTF8
}
function Write-Step($msg) {
    Write-Host "[wp-catalog] $msg"
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value "[wp-catalog] $msg" -Encoding UTF8 }
}
function Stop-Build([string]$msg, [int]$code) {
    [Console]::Error.WriteLine("[wp-catalog] FAIL: $msg")
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value "[wp-catalog] FAIL: $msg" -Encoding UTF8 }
    exit $code
}
trap {
    Stop-Build ("{0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 1
}

# --- Locate the game folder ---------------------------------------------------
if (-not $GameDir) {
    $probe = $PSScriptRoot
    for ($i = 0; $i -lt 8 -and $probe; $i++) {
        if (Test-Path -LiteralPath (Join-Path $probe "R5\Content\Paks")) { $GameDir = $probe; break }
        $probe = Split-Path -Parent $probe
    }
}
if (-not $GameDir -and -not $SourceDir) {
    Stop-Build "Cannot find the game folder. Pass -GameDir <Windrose server folder>." 2
}
if ($GameDir) { $GameDir = [System.IO.Path]::GetFullPath($GameDir) }
if (-not $OutputDir) {
    if (-not $GameDir) { Stop-Build "Pass -OutputDir when -GameDir is not given." 2 }
    $OutputDir = Join-Path $GameDir "windrose_plus_data\catalog\v1"
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# --- Fingerprint: rebuild only when the game data or this builder changed ------
$pakPath = $null
$fingerprint = "builder=$BuilderVersion"
if ($GameDir) {
    $pakPath = Join-Path $GameDir "R5\Content\Paks\pakchunk0-WindowsServer.pak"
    if (Test-Path -LiteralPath $pakPath) {
        $pakInfo = Get-Item -LiteralPath $pakPath
        $fingerprint = "builder=$BuilderVersion;pak=$($pakInfo.Length);$($pakInfo.LastWriteTimeUtc.Ticks)"
        # Stat values come from the IoStore container, and from this server's own
        # settings override when there is one, so a change to either rebuilds too.
        foreach ($extra in @("pakchunk0-WindowsServer.utoc", "WindrosePlus_CurveTables_P.utoc")) {
            $ep = Join-Path (Split-Path -Parent $pakPath) $extra
            if (Test-Path -LiteralPath $ep) {
                $ei = Get-Item -LiteralPath $ep
                $fingerprint += ";$extra=$($ei.Length);$($ei.LastWriteTimeUtc.Ticks)"
            }
        }
    } elseif (-not $SourceDir) {
        Stop-Build "Game data file not found: $pakPath" 2
    }
}
$summaryPath = Join-Path $OutputDir "_summary.json"
if (-not $Force -and -not $SourceDir -and (Test-Path -LiteralPath $summaryPath) -and (Test-Path -LiteralPath (Join-Path $OutputDir "items_full.json"))) {
    try {
        $prev = [System.IO.File]::ReadAllText($summaryPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($prev.fingerprint -eq $fingerprint) {
            Write-Step "Catalog is current ($fingerprint); nothing to do."
            exit 0
        }
    } catch {}
}

# --- Unpack the folders the catalog needs --------------------------------------
$includeDirs = @(
    "R5/Plugins/R5BusinessRules/Content/InventoryItems",
    "R5/Plugins/R5BusinessRules/Content/Ship",
    "R5/Plugins/R5BusinessRules/Content/Inventory",
    "R5/Plugins/R5BusinessRules/Content/Recipes",
    "R5/Plugins/R5BusinessRules/Content/RecipeLists",
    "R5/Plugins/R5BusinessRules/Content/Production",
    "R5/Plugins/R5BusinessRules/Content/LootTables",
    "R5/Content/Gameplay/Scenario/Player",
    "R5/Content/Localization/Game/en"
)
$cleanupWork = $false
if ($SourceDir) {
    $root = [System.IO.Path]::GetFullPath($SourceDir)
} else {
    if (-not $Repak) {
        foreach ($candidate in @((Join-Path $PSScriptRoot "bin\repak.exe"), (Join-Path $PSScriptRoot "bin\repak"))) {
            if (Test-Path -LiteralPath $candidate) { $Repak = $candidate; break }
        }
    }
    if (-not $Repak -or -not (Test-Path -LiteralPath $Repak)) {
        Stop-Build "repak not found next to this script (tools\bin). Reinstall Windrose+ or pass -Repak." 2
    }
    # The game's data file is encrypted; the key is the one the settings builders use.
    . (Join-Path $PSScriptRoot "lib\IniConfigParser.ps1")
    $aesKey = $script:WindroseAesKey
    if (-not $WorkDir) { $WorkDir = Join-Path (Split-Path -Parent $OutputDir) "build_tmp" }
    $WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $cleanupWork = -not $KeepWork
    $repakArgs = @("--aes-key", $aesKey, "unpack", "-q", "-f", "-o", $WorkDir)
    foreach ($d in $includeDirs) { $repakArgs += @("-i", $d) }
    $repakArgs += $pakPath
    Write-Step "Unpacking game data from $pakPath"
    $out = & $Repak @repakArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Build "repak unpack failed (exit $LASTEXITCODE): $(($out | Out-String).Trim())" 3
    }
    $root = $WorkDir
}

# --- Curve tables: the numbers behind item stats and effect text ---------------
# They live in the game's IoStore container, not in the JSON. retoc pulls out only
# the CT_* tables (well under a megabyte). Without retoc the catalog still builds,
# just without numbers.
$statSource = "game files"
if ($SourceDir) { $statSource = "supplied curve tables" }
elseif (-not $Vanilla -and $pakPath -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $pakPath) "WindrosePlus_CurveTables_P.utoc"))) {
    $statSource = "game files plus this server's settings"
}
if (-not $CurveTableDir -and -not $SourceDir) {
    if (-not $Retoc) {
        foreach ($candidate in @((Join-Path $PSScriptRoot "bin\retoc.exe"), (Join-Path $PSScriptRoot "bin\retoc"))) {
            if (Test-Path -LiteralPath $candidate) { $Retoc = $candidate; break }
        }
    }
    if ($Retoc -and (Test-Path -LiteralPath $Retoc)) {
        $ctOut = Join-Path $WorkDir "curvetables"
        New-Item -ItemType Directory -Path $ctOut -Force | Out-Null
        $ctInput = Split-Path -Parent $pakPath
        if ($Vanilla) {
            # retoc reads every container in the folder it is given, so give it a
            # folder of hard links to the game's containers without ours.
            $vanillaDir = Join-Path $WorkDir "paks_vanilla"
            New-Item -ItemType Directory -Path $vanillaDir -Force | Out-Null
            $linked = 0
            foreach ($f in (Get-ChildItem -LiteralPath $ctInput -File | Where-Object { ($_.Extension -eq ".utoc" -or $_.Extension -eq ".ucas") -and $_.Name -notlike "WindrosePlus_*" })) {
                try { New-Item -ItemType HardLink -Path (Join-Path $vanillaDir $f.Name) -Target $f.FullName | Out-Null; $linked++ } catch {}
            }
            if ($linked -gt 0) { $ctInput = $vanillaDir; $statSource = "game files" }
            else { Write-Step "Could not set this server's settings override aside; stat values include it" }
        }
        $null = & $Retoc -a $aesKey to-legacy --filter CT_ --no-shaders --no-script-objects $ctInput $ctOut 2>&1
        if ($LASTEXITCODE -eq 0) { $CurveTableDir = $ctOut } else { Write-Step "retoc could not read the curve tables (exit $LASTEXITCODE); building without stat values" }
    } else {
        Write-Step "retoc not found; building without stat values"
    }
}
$curveRows = @{}   # table name -> @{ row name -> keys }
if ($CurveTableDir -and (Test-Path -LiteralPath $CurveTableDir)) {
    . (Join-Path $PSScriptRoot "lib\CurveTableParser.ps1")
    $wanted = '^CT_(Weapon_GE_Values|CombatPower_StaticData|ShipEquipStats|Armor_GE_Values|JewelryGEValues|Food_GE_Values|Alchemy_GE_Values|OtherGEValues)$'
    foreach ($ua in (Get-ChildItem -LiteralPath $CurveTableDir -Recurse -Filter "CT_*.uasset" -File)) {
        if ($ua.BaseName -notmatch $wanted) { continue }
        $manifest = Parse-CurveTable -UAssetPath $ua.FullName
        if ($manifest.Error) { Write-Step "Curve table $($ua.BaseName) could not be read: $($manifest.Error)"; continue }
        if ($manifest.ExpectedRowCount -gt 0 -and $manifest.RowCount -ne $manifest.ExpectedRowCount) { Write-Step "Curve table $($ua.BaseName): read $($manifest.RowCount) of $($manifest.ExpectedRowCount) rows" }
        $rows = @{}
        foreach ($r in $manifest.Rows) { $rows[[string]$r.Name] = $r.Keys }
        $curveRows[$ua.BaseName] = $rows
    }
    Write-Step "Curve tables read: $($curveRows.Count)"
}

# --- Helpers -------------------------------------------------------------------
function Read-JsonFile([string]$path) {
    return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value }
    return $null
}
function Get-AssetName($ref) {
    if ($null -eq $ref) { return $null }
    $s = [string]$ref
    if (-not $s -or $s -eq "None") { return $null }
    $s = $s.Trim("'")
    $i = $s.LastIndexOf("/")
    if ($i -ge 0) { $s = $s.Substring($i + 1) }
    $j = $s.IndexOf(".")
    if ($j -ge 0) { $s = $s.Substring(0, $j) }
    $s = $s.Trim("'")
    if (-not $s) { return $null }
    return $s
}
function ConvertTo-Words([string]$s) {
    # DA_RD_DID_Resource_Wood_T01 -> "Resource Wood T01"; CamelCase split into words.
    if (-not $s) { return "" }
    $t = $s -replace '^(DA_|BP_)', ''
    $t = $t -replace '^(RD|LT|IC|QP|EID|DID|CID|AID|ODL|RecipeList)_', ''
    $t = $t -replace '_', ' '
    $t = [regex]::Replace($t, '([a-z])([A-Z])', '$1 $2')
    return ($t -replace '\s+', ' ').Trim()
}
function Unescape-Po([string]$s) {
    if ($null -eq $s) { return "" }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($c -eq [char]'\' -and $i + 1 -lt $s.Length) {
            $n = $s[$i + 1]; $i++
            switch ($n) {
                'n' { [void]$sb.Append("`n") }
                'r' { [void]$sb.Append("`r") }
                't' { [void]$sb.Append("`t") }
                '"' { [void]$sb.Append('"') }
                '\' { [void]$sb.Append('\') }
                default { [void]$sb.Append($c); [void]$sb.Append($n) }
            }
        } else {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

# --- Localisation: "Table,Key" -> English text --------------------------------
$loc = @{}
$poPath = Join-Path $root "R5\Content\Localization\Game\en\Game.po"
if (-not (Test-Path -LiteralPath $poPath)) {
    Stop-Build "English text file not found in the game data: $poPath" 3
}
$poText = [System.IO.File]::ReadAllText($poPath, [System.Text.Encoding]::UTF8)
$poMatches = [regex]::Matches($poText, 'msgctxt "((?:[^"\\]|\\.)*)"\r?\nmsgid "((?:[^"\\]|\\.)*)"\r?\nmsgstr "((?:[^"\\]|\\.)*)"')
foreach ($m in $poMatches) {
    $txt = $m.Groups[3].Value
    if (-not $txt) { $txt = $m.Groups[2].Value }
    $loc[$m.Groups[1].Value] = Unescape-Po $txt
}
$poText = $null
Write-Step "Text entries: $($loc.Count)"

function Resolve-Text($t) {
    if ($null -eq $t) { return $null }
    if ($t -is [string]) {
        if (-not $t -or $t -eq "None") { return $null }
        return $t
    }
    $table = Get-Prop $t "TableId"
    $key = Get-Prop $t "Key"
    if ($table -and $key) {
        $v = $loc["$table,$key"]
        if ($v) { return $v }
        return $null
    }
    $src = Get-Prop $t "SourceString"
    if ($src) { return [string]$src }
    return $null
}
function Format-Number($v) {
    if ($null -eq $v) { return $null }
    $r = [Math]::Round([double]$v, 2)
    if ($r -eq [Math]::Floor($r) -and [Math]::Abs($r) -lt 1e15) { return [long]$r }
    return $r
}
function Get-CurveValue($tablePath, [string]$row, $level) {
    $t = Get-AssetName $tablePath
    if (-not $t) { return $null }
    $rows = $curveRows[$t]
    if (-not $rows) { return $null }
    $keys = @($rows[$row])
    if ($keys.Count -eq 0 -or $null -eq $keys[0]) { return $null }
    $lv = 0.0
    if ($null -ne $level) { $lv = [double]$level }
    $best = $keys[0]
    foreach ($k in $keys) {
        if ([Math]::Abs([double]$k.Time - $lv) -lt [Math]::Abs([double]$best.Time - $lv)) { $best = $k }
    }
    return [double]$best.Value
}
. (Join-Path $PSScriptRoot "lib\StatLabels.ps1")
function Get-StatEntry($e) {
    # One stat reference from an item's UI data, with its value at level 1.
    if ($null -eq $e) { return $null }
    $stat = [string](Get-Prop $e "Stat")
    if (-not $stat -or $stat -eq "None") { return $null }
    $table = [string](Get-Prop $e "CurveTable")
    $row = [string](Get-Prop $e "RowName")
    $entry = [ordered]@{ stat = $stat; label = (Get-WindroseStatLabel $stat $row); curveTable = $table; rowName = $row; curveLevel = (Get-Prop $e "CurveLevel") }
    if ($row -match '^[A-Z][+-]?$') {
        $entry.grade = $row; $entry.valueLevel1 = $row
    } elseif (-not $table -or $table -eq "None") {
        if ($row -match '^-?\d+(\.\d+)?$') { $entry.valueLevel1 = Format-Number $row }
    } else {
        $v = Get-CurveValue $table $row (Get-Prop $e "CurveLevel")
        if ($null -ne $v) { $entry.valueLevel1 = Format-Number $v }
    }
    return $entry
}
function Get-DescriptionEntry($e) {
    # A number shown in an item's effect text ({0}, {1}, ...), already in display units.
    if ($null -eq $e) { return $null }
    $table = [string](Get-Prop $e "CurveTable")
    $row = [string](Get-Prop $e "RowName")
    $dtype = [string](Get-Prop $e "DisplayType")
    $inverse = [bool](Get-Prop $e "bInverseValue")
    $raw = $null
    if (-not $table -or $table -eq "None") {
        if ($row -match '^-?\d+(\.\d+)?$') { $raw = [double]$row }
    } else {
        $raw = Get-CurveValue $table $row (Get-Prop $e "CurveLevel")
    }
    $entry = [ordered]@{ label = (Get-WindroseStatLabel "" $row); curveTable = $table; rowName = $row; curveLevel = (Get-Prop $e "CurveLevel"); displayType = $dtype; inverse = $inverse }
    if ($null -ne $raw) {
        $shown = $raw
        switch ($dtype) {
            "RatioToPercent" { if ($inverse) { $shown = -$raw * 100 } else { $shown = $raw * 100 } }
            "SecondsAsMinutes" { $shown = $raw / 60 }
        }
        $entry.valueLevel1 = Format-Number $shown
        $entry.rawValue = Format-Number $raw
    }
    return $entry
}
function Resolve-EffectText($t, $descEntries) {
    $s = Resolve-Text $t
    if (-not $s) { return $null }
    return [regex]::Replace($s, '\{(\d+)\}(%?)', {
        param($m)
        $i = [int]$m.Groups[1].Value
        $pct = $m.Groups[2].Value
        if ($descEntries -and $i -lt $descEntries.Count -and $null -ne $descEntries[$i].valueLevel1) {
            $x = $descEntries[$i]
            if (-not $pct -and $x.displayType -match 'Percent') { $pct = "%" }
            return ([string]$x.valueLevel1) + $pct
        }
        return "?" + $pct
    })
}

# --- Load every JSON asset we need ---------------------------------------------
$assets = @{}
$jsonCount = 0
foreach ($dir in $includeDirs) {
    $full = Join-Path $root ($dir -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $full -Recurse -Filter "*.json" -File)) {
        try { $data = Read-JsonFile $f.FullName } catch { continue }
        $type = Get-Prop $data '$type'
        if (-not $type) { continue }
        $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        $assets[$f.BaseName] = @{ Name = $f.BaseName; Path = $rel; Type = [string]$type; Data = $data }
        $jsonCount++
    }
}
Write-Step "Game data files read: $jsonCount"

function Get-AssetsOfType([string]$type) {
    return @($assets.Values | Where-Object { $_.Type -eq $type })
}

# --- Items ---------------------------------------------------------------------
$groupOf = @{
    food = "consumables"; alchemy = "consumables"; medicine = "consumables"
    armor = "equipment"; ring = "equipment"; necklace = "equipment"; backpack = "equipment"
    meleeweapon = "weapons"; rangeweapon = "weapons"; tool = "weapons"; ammo = "weapons"
    shipweapon = "ship"; shiphullmod = "ship"; shipsailmod = "ship"; shipcombatorder = "ship"; shipcrewequipment = "ship"
    resource = "resources"; metal = "resources"
}
$groupLabel = @{ consumables = "Consumables"; equipment = "Equipment"; weapons = "Weapons"; ship = "Ship"; resources = "Resources"; misc = "Misc" }

$items = [ordered]@{}
foreach ($a in (Get-AssetsOfType "R5BLInventoryItem" | Sort-Object { $_.Name })) {
    if ($a.Path -match '/(AutoTests|Test|NPC)/' -or $a.Name -match 'Test') { continue }
    $d = $a.Data
    $gpp = Get-Prop $d "InventoryItemGppData"
    $ui = Get-Prop $d "InventoryItemUIData"
    $category = [string](Get-Prop $ui "Category")
    if (-not $category -or $category -eq "None") { $category = "Misc" }
    $cat = $category.ToLowerInvariant()
    $group = $groupOf[$cat]
    if (-not $group) { $group = "misc" }
    $catLabel = [regex]::Replace($category, '([a-z])([A-Z])', '$1 $2')
    $tier = 0
    $tm = [regex]::Matches($a.Name, '(?:_|(?<=[a-z]))T0*(\d+)(?=_|$)')
    if ($tm.Count -gt 0) { $tier = [int]$tm[$tm.Count - 1].Groups[1].Value }
    $descEntries = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-Prop $ui "ItemDescriptionData")) { $x = Get-DescriptionEntry $e; if ($x) { $descEntries.Add($x) } }
    $effects = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-Prop $ui "EffectsDescriptions")) { $t = Resolve-EffectText $e $descEntries; if ($t) { $effects.Add($t) } }
    $setEffects = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-Prop $ui "SetEffectsDescriptions")) { $t = Resolve-EffectText $e $descEntries; if ($t) { $setEffects.Add($t) } }
    $mainStat = Get-StatEntry (Get-Prop $ui "StatCurveMainStatsData")
    $secondary = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-Prop $ui "StatCurveSecondaryStatsData")) { $x = Get-StatEntry $e; if ($x) { $secondary.Add($x) } }
    $additional = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-Prop $ui "StatCurveAdditionalStats")) { $x = Get-StatEntry $e; if ($x) { $additional.Add($x) } }
    $rangeRank = $null; $accuracyRank = $null; $shipDamage = $null; $shipReload = $null
    $weaponLabel = $null; $weaponValue = $null; $weaponGrade = $null; $weaponGradeStat = $null
    foreach ($x in $secondary) {
        if ($x.stat -eq "ShipFireRangeRANK") { $rangeRank = $x.rowName }
        elseif ($x.stat -eq "ShipFireAccuracyRANK") { $accuracyRank = $x.rowName }
        elseif ($x.stat -eq "ShipCannonDamage") { $shipDamage = $x.valueLevel1 }
        elseif ($x.stat -eq "ShipCannonReloadTime") { $shipReload = $x.valueLevel1 }
        elseif ($x.Contains("grade")) { if (-not $weaponGrade) { $weaponGrade = $x.grade; $weaponGradeStat = $x.stat } }
        elseif (-not $weaponLabel -and $null -ne $x.valueLevel1) { $weaponLabel = $x.stat; $weaponValue = $x.valueLevel1 }
    }
    $foodDuration = $null
    foreach ($x in $descEntries) {
        if ($x.displayType -eq "SecondsAsMinutes" -and $x.rowName -match '_Duration$' -and $null -ne $x.rawValue) { $foodDuration = $x.rawValue; break }
    }
    $name = Resolve-Text (Get-Prop $ui "ItemName")
    $desc = Resolve-EffectText (Get-Prop $ui "ItemDescription") $descEntries
    # Items the developers marked as unused or left as placeholders stay out.
    if ($name -and ($name -match '^\s*(NOT USED|TBD\s*$|Technical placeholder)' -or $name -match '^Test' -or ($name -cmatch '^[A-Z]{3,}$' -and $desc -match '^\s*TEST') -or ($desc -and $desc -ceq $name -and $name -cmatch '^[a-z]'))) { continue }
    if ($a.Name -match '_Fists_' -or $a.Name -match '_AI$') { continue }   # bare hands and NPC ship guns, not player items
    if ($desc -and $desc -match '^\s*TEST') { $desc = $null }   # developer placeholder text in the game files
    $item = [ordered]@{
        id = $a.Name
        sourceId = $a.Name
        name = $name
        description = $desc
        rarity = ([string](Get-Prop $gpp "Rarity")).ToLowerInvariant()
        tier = $tier
        stack = [int](Get-Prop $gpp "MaxCountInSlot")
        sourceCategory = $cat
        sourceCategoryLabel = $catLabel
        topLevelCategoryId = $group
        topLevelCategoryLabel = $groupLabel[$group]
        categoryId = "$group/$cat"
        itemTag = [string](Get-Prop (Get-Prop $gpp "ItemTag") "TagName")
        itemTypeTag = [string](Get-Prop (Get-Prop $gpp "ItemType") "TagName")
        tooltip = [ordered]@{
            category = $catLabel
            description = $desc
            mainStat = $mainStat
            secondaryStats = $secondary
            additionalStats = $additional
            descriptionData = $descEntries
            effectsDescriptions = $effects
            setEffectsDescriptions = $setEffects
            vanityText = Resolve-Text (Get-Prop $ui "VanityText")
        }
        drops = New-Object System.Collections.Generic.List[object]
    }
    if ($group -eq "weapons" -and $weaponLabel) { $item.weaponStatLabel = $weaponLabel; $item.weaponStatValue = $weaponValue }
    if ($group -eq "weapons" -and $weaponGrade) { $item.weaponGrade = $weaponGrade; $item.weaponGradePrimaryStat = $weaponGradeStat }
    if ($null -ne $shipDamage) { $item.shipWeaponDamage = $shipDamage }
    if ($null -ne $shipReload) { $item.shipWeaponReloadTime = $shipReload }
    if ($rangeRank) { $item.shipWeaponRangeRank = $rangeRank }
    if ($accuracyRank) { $item.shipWeaponAccuracyRank = $accuracyRank }
    if ($null -ne $foodDuration) { $item.foodDurationSeconds = $foodDuration }
    $items[$a.Name] = $item
}
Write-Step "Items: $($items.Count)"

function Get-ItemRef([string]$assetName, $qty) {
    $it = $items[$assetName]
    if (-not $it) { return $null }
    $label = $it.name
    if (-not $label) { $label = ConvertTo-Words $assetName }
    return [ordered]@{ sourceId = $assetName; id = $assetName; name = $label; rarity = $it.rarity; quantity = $qty }
}

# --- Stations, traders and the recipe lists they offer -------------------------
# Crafting stations name themselves through the building recipe that places them.
$stationBuildRecipe = @{
    DA_IC_AlchemyTable_T02 = "DA_RD_BuildObject_Craft_AlchemyTable_Station"
    DA_IC_ArmorTable_T03 = "DA_RD_BuildObject_Craft_ArmorTable_Station"
    DA_IC_Bonefire_T01 = "DA_RD_BuildObject_Craft_Cooking_Station"
    DA_IC_DisassemblyBench_T01 = "DA_RD_BuildObject_Craft_Disassemble_Station"
    DA_IC_Dockyard = "DA_RD_BuildObject_Craft_Dockyard_Station"
    DA_IC_FermentationBarrel_T04 = "DA_RD_BuildObject_Craft_FermintationBarrel_T04"
    DA_IC_Furnace_T01 = "DA_RD_BuildObject_Craft_Furnace_T01"
    DA_IC_Furnace_T02 = "DA_RD_BuildObject_Craft_Furnace_T03"
    DA_IC_JewelryTable_T02 = "DA_RD_BuildObject_Craft_JewelryTable_Station"
    DA_IC_Kiln_T02 = "DA_RD_BuildObject_Craft_Kiln_T02"
    DA_IC_Millstones_T02 = "DA_RD_BuildObject_Craft_Millstones_T02"
    DA_IC_Punch_T02 = "DA_RD_BuildObject_Craft_Punch_T03"
    DA_IC_ScrewPress_T04 = "DA_RD_BuildObject_Craft_ScrewPress_T04"
    DA_IC_ShipEq_T01 = "DA_RD_BuildObject_Craft_ShipEquipment_Station"
    DA_IC_SpinningWheel_T02 = "DA_RD_BuildObject_Craft_SpinningWheel_T02"
    DA_IC_Tannery_T02 = "DA_RD_BuildObject_Craft_Tannery_T02"
    DA_IC_UpgradeTable_T02 = "DA_RD_BuildObject_Craft_UpgradeTable_T02"
    DA_IC_WeaponTable_T03 = "DA_RD_BuildObject_Craft_WeaponTable_Station"
    DA_IC_WitchTable_T03 = "DA_RD_BuildObject_Craft_WitchCooking_T03"
    DA_IC_Workbench_T01 = "DA_RD_BuildObject_Craft_Workbench_Station"
}
function Get-StationInfo($ic) {
    $n = $ic.Name
    $kind = "station"; $category = "Crafting station"; $label = $null
    if ($ic.Path -match '/ItemsCreator/(Trade\w+|Tortuga)/' -or $n -match '^DA_IC_Handyman_Trader_') {
        $kind = "vendor"; $category = "Trader"
        if ($n -match '^DA_IC_Trade_([A-Za-z]+?)1_Player(Buys|Sells)') {
            $label = "$($Matches[1]) trader"
        } elseif ($n -match '^DA_IC_Tortuga_(\w+)$') {
            $label = "Tortuga: $(ConvertTo-Words $Matches[1])"
        } elseif ($n -match '^DA_IC_Handyman_Trader_(\w+)$') {
            $label = "Trading post: $(ConvertTo-Words $Matches[1])"
        }
    } elseif ($n -match '^DA_IC_Handyman_(\w+?)_T\d+$') {
        $kind = "worker"; $category = "Worker"; $label = "Worker: $(ConvertTo-Words $Matches[1])"
    } elseif ($stationBuildRecipe[$n] -and $assets[$stationBuildRecipe[$n]]) {
        $label = Resolve-Text (Get-Prop (Get-Prop $assets[$stationBuildRecipe[$n]].Data "UIData") "Name")
    }
    if (-not $label) { $label = ConvertTo-Words $n }
    return [ordered]@{ sourceId = $n; id = $n; name = $label; category = $category; kind = $kind }
}

$recipeStations = @{}   # recipe asset -> list of station info
function Add-RecipeStation([string]$recipe, $station) {
    if (-not $recipeStations[$recipe]) { $recipeStations[$recipe] = New-Object System.Collections.Generic.List[object] }
    foreach ($s in $recipeStations[$recipe]) { if ($s.id -eq $station.id) { return } }
    $recipeStations[$recipe].Add($station)
}
$listToStations = @{}
$stationCount = 0; $vendorCount = 0
foreach ($ic in (Get-AssetsOfType "R5BLItemsCreatorParams" | Sort-Object { $_.Name })) {
    if ($ic.Path -match '/Test/') { continue }
    $info = Get-StationInfo $ic
    if ($info.kind -eq "vendor") { $vendorCount++ } else { $stationCount++ }
    foreach ($rl in @(Get-Prop $ic.Data "RecipesLists")) {
        $listName = Get-AssetName (Get-Prop $rl "AvailableRecipes")
        if (-not $listName) { continue }
        if (-not $listToStations[$listName]) { $listToStations[$listName] = New-Object System.Collections.Generic.List[object] }
        $listToStations[$listName].Add($info)
    }
}
foreach ($list in (Get-AssetsOfType "R5BLRecipeList" | Sort-Object { $_.Name })) {
    # DA_RecipeList_PlayerGrantedRecipes is what a new character already knows, not a place to craft.
    if ($list.Name -eq "DA_RecipeList_PlayerGrantedRecipes" -or $list.Path -match '/Test/') { continue }
    $stations = $listToStations[$list.Name]
    if (-not $stations) {
        $stations = @([ordered]@{ sourceId = $list.Name; id = $list.Name; name = (ConvertTo-Words $list.Name); category = "Recipe list"; kind = "list" })
    }
    foreach ($r in @(Get-Prop $list.Data "RecipeList")) {
        $rn = Get-AssetName $r
        if (-not $rn) { continue }
        foreach ($s in $stations) { Add-RecipeStation $rn $s }
    }
}

# --- Recipes: crafted by / crafts / trader offers / building costs -------------
$usage = @{}
function Get-Usage([string]$id) {
    if (-not $usage[$id]) {
        $usage[$id] = [ordered]@{
            craftedBy = New-Object System.Collections.Generic.List[object]
            crafts = New-Object System.Collections.Generic.List[object]
            vendorTrades = New-Object System.Collections.Generic.List[object]
            construction = New-Object System.Collections.Generic.List[object]
        }
    }
    return $usage[$id]
}
function Get-RecipeSide($list) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($list)) {
        if ($null -eq $e) { continue }
        $n = Get-AssetName (Get-Prop $e "Item")
        if (-not $n) { continue }
        $r = Get-ItemRef $n ([int](Get-Prop $e "Count"))
        if ($r) { $out.Add($r) }
    }
    return ,$out
}
$recipeCount = 0; $tradeCount = 0; $buildCount = 0
foreach ($rec in (Get-AssetsOfType "R5BLRecipeData" | Sort-Object { $_.Name })) {
    if ($rec.Path -match '/(Test|AutoTests)/') { continue }
    $d = $rec.Data
    $inputs = Get-RecipeSide (Get-Prop $d "RecipeCost")
    $outputs = Get-RecipeSide (Get-Prop $d "RecipeResult")
    if ($inputs.Count -eq 0 -and $outputs.Count -eq 0) { continue }
    $uiData = Get-Prop $d "UIData"
    $label = Resolve-Text (Get-Prop $uiData "Name")
    if (-not $label) {
        $firstOut = $null; $firstIn = $null
        if ($outputs.Count -gt 0) { $firstOut = $outputs[0].name }
        if ($inputs.Count -gt 0) { $firstIn = $inputs[0].name }
        if ($rec.Name -match 'Disassembl' -and $firstIn) { $label = "Disassemble $firstIn" }
        elseif ($rec.Name -match 'Ascend' -and $firstOut) { $label = "Ascend to $firstOut" }
        elseif ($rec.Name -match 'Upgrade' -and $firstOut) { $label = "Upgrade: $firstOut" }
        elseif ($firstOut) { $label = $firstOut }
        else { $label = ConvertTo-Words $rec.Name }
    }
    $stations = $recipeStations[$rec.Name]
    if (-not $stations) { $stations = New-Object System.Collections.Generic.List[object] }
    $vendor = $null
    foreach ($s in $stations) { if ($s.kind -eq "vendor") { $vendor = $s; break } }
    $isBuilding = ([string](Get-Prop $uiData "RecipeType") -eq "Building") -or ($rec.Path -match '/Recipes/Building/')

    if ($vendor) {
        $coinIn = $false; $coinOut = $false
        $goods = New-Object System.Collections.Generic.List[object]
        foreach ($x in $inputs) { if ($x.sourceId -match 'Coin') { $coinIn = $true } else { $goods.Add($x) } }
        foreach ($x in $outputs) { if ($x.sourceId -match 'Coin') { $coinOut = $true } else { $goods.Add($x) } }
        $direction = "trade"
        if ($coinOut -and -not $coinIn) { $direction = "sell" } elseif ($coinIn -and -not $coinOut) { $direction = "buy" }
        foreach ($g in $goods) {
            (Get-Usage $g.sourceId).vendorTrades.Add([ordered]@{
                direction = $direction
                sourceRecipeId = $rec.Name
                vendor = [ordered]@{ id = $vendor.id; name = $vendor.name; kind = "trader"; stationSourceId = $vendor.sourceId }
                itemQuantity = $g.quantity
                costs = $inputs
                rewards = $outputs
            })
        }
        $tradeCount++
        continue
    }
    if ($isBuilding -and $outputs.Count -eq 0) {
        $folder = ($rec.Path -split '/')[-2]
        foreach ($inp in $inputs) {
            (Get-Usage $inp.sourceId).construction.Add([ordered]@{
                sourceId = $rec.Name
                id = $rec.Name
                name = $label
                category = (ConvertTo-Words $folder)
                quantity = $inp.quantity
                sourceRecipeId = $rec.Name
            })
        }
        $buildCount++
        continue
    }
    $row = [ordered]@{
        sourceRecipeId = $rec.Name
        name = $label
        recipeType = "crafting"
        stations = $stations
        inputs = $inputs
        outputs = $outputs
        durationSeconds = (Get-Prop $d "CookingProcessDuration")
    }
    foreach ($o in $outputs) { (Get-Usage $o.sourceId).craftedBy.Add($row) }
    foreach ($inp in $inputs) { (Get-Usage $inp.sourceId).crafts.Add($row) }
    $recipeCount++
}
Write-Step "Recipes: $recipeCount crafting, $tradeCount trader offers, $buildCount building costs"

# --- Where items drop -----------------------------------------------------------
$lootTables = @{}
foreach ($lt in (Get-AssetsOfType "R5BLLootParams")) { $lootTables[$lt.Name] = $lt }
$nestedTables = @{}
foreach ($lt in $lootTables.Values) {
    foreach ($e in @(Get-Prop $lt.Data "LootData")) {
        $sub = Get-AssetName (Get-Prop $e "LootTable")
        if ($sub) { $nestedTables[$sub] = $true }
    }
}
# What one opening of a loot table gives: item -> chance (at least one) and count range.
# "Weight" tables pick one entry by weight; "List" tables give every entry. An entry
# that points at another table runs that table Min..Max times.
$lootOutcomeCache = @{}
function Add-LootOutcome($acc, [string]$item, [double]$chance, [int]$min, [int]$max) {
    if ($chance -le 0) { return }
    if (-not $acc.ContainsKey($item)) { $acc[$item] = @{ chance = $chance; min = $min; max = $max }; return }
    $cur = $acc[$item]
    $cur.chance = 1 - (1 - $cur.chance) * (1 - $chance)
    if ($min -lt $cur.min) { $cur.min = $min }
    $cur.max = $cur.max + $max
}
function Get-LootOutcome([string]$tableName, $seen) {
    if ($lootOutcomeCache.ContainsKey($tableName)) { return $lootOutcomeCache[$tableName] }
    $acc = @{}
    $lt = $lootTables[$tableName]
    if (-not $lt -or $seen.ContainsKey($tableName) -or $seen.Count -gt 8) { return $acc }
    $seen[$tableName] = $true
    $type = [string](Get-Prop $lt.Data "LootTableType")
    $entries = @(Get-Prop $lt.Data "LootData" | Where-Object { $null -ne $_ })
    $weighted = ($type -eq "Weight" -or $type -eq "WeightedOnetime")
    $total = 0.0
    if ($weighted) { foreach ($e in $entries) { $total += [double](Get-Prop $e "Weight") } }
    foreach ($e in $entries) {
        $p = 1.0
        if ($weighted) {
            if ($total -le 0) { continue }
            $p = [double](Get-Prop $e "Weight") / $total
        }
        if ($p -le 0) { continue }
        $min = Get-Prop $e "Min"; $max = Get-Prop $e "Max"
        $amount = Get-Prop $e "Amount"
        if ($null -eq $min -and $null -ne $amount) {
            if ($amount -is [System.Management.Automation.PSCustomObject]) {
                $min = Get-Prop $amount "Min"; $max = Get-Prop $amount "Max"
            } else { $min = $amount; $max = $amount }
        }
        if ($null -eq $min) { $min = 1 }
        if ($null -eq $max) { $max = $min }
        $min = [int]$min; $max = [int]$max
        $itemName = Get-AssetName (Get-Prop $e "LootItem")
        if ($itemName) { Add-LootOutcome $acc $itemName $p $min $max }
        $sub = Get-AssetName (Get-Prop $e "LootTable")
        if ($sub) {
            $rolls = [Math]::Max(1, $max)
            $inner = Get-LootOutcome $sub $seen
            foreach ($k in $inner.Keys) {
                $q = $inner[$k]
                $chance = $p * (1 - [Math]::Pow(1 - $q.chance, $rolls))
                Add-LootOutcome $acc $k $chance $q.min ($q.max * $rolls)
            }
        }
    }
    $seen.Remove($tableName)
    $lootOutcomeCache[$tableName] = $acc
    return $acc
}
$dropRows = 0
function Add-Drops([string]$tableName, [string]$sourceType, [string]$sourceLabel, [string]$sourceName, [string]$sourceId) {
    $acc = Get-LootOutcome $tableName @{}
    foreach ($k in ($acc.Keys | Sort-Object)) {
        $it = $items[$k]
        if (-not $it) { continue }
        $v = $acc[$k]
        $it.drops.Add([ordered]@{
            npcId = $sourceId
            npcSourceId = $sourceId
            npcName = $sourceName
            sourceType = $sourceType
            sourceTypeLabel = $sourceLabel
            chance = [Math]::Round([Math]::Min(1.0, $v.chance), 4)
            minQuantity = $v.min
            maxQuantity = $v.max
            sourceTableId = $tableName
        })
        $script:dropRows++
    }
}
$folderSource = @{
    Chests = @("chest", "Chest", "Chest")
    Mobs = @("creature", "Creature", "Creature")
    Ships = @("ship", "Ship", "Ship")
    Foliage = @("gathering", "Gathering", "Gathering")
    PickupResource = @("gathering", "Gathering", "Gathering")
    Crop = @("gathering", "Farming", "Farming")
    Fishing = @("gathering", "Fishing", "Fishing")
}
# Items that open into a loot table (crates, bundles, sacks).
$containerTables = @{}
foreach ($it in $items.Values) {
    $gpp = Get-Prop $assets[$it.sourceId].Data "InventoryItemGppData"
    $lt = Get-AssetName (Get-Prop $gpp "LootTableData")
    if (-not $lt -or -not $lootTables[$lt]) {
        $cd = Get-Prop $gpp "ConsumableData"
        $lt = $null
    }
    if ($lt -and $lootTables[$lt]) {
        $label = $it.name
        if (-not $label) { $label = ConvertTo-Words $it.sourceId }
        Add-Drops $lt "container" "Opened item" $label $it.sourceId
        $containerTables[$lt] = $true
    }
}
foreach ($lt in ($lootTables.Values | Sort-Object { $_.Name })) {
    if ($nestedTables[$lt.Name] -or $containerTables[$lt.Name]) { continue }
    $parts = $lt.Path -split '/'
    $idx = [Array]::IndexOf($parts, "LootTables")
    if ($idx -lt 0 -or $idx + 1 -ge $parts.Count) { continue }
    $folder = $parts[$idx + 1]
    $src = $folderSource[$folder]
    if (-not $src) { continue }
    $short = $lt.Name -replace '^DA_LT_(Chest_|Mob_|Ships_|Foliage_|PickupResource_|Crop_|Fishing_)?', ''
    Add-Drops $lt.Name $src[0] $src[1] ("$($src[2]): " + (ConvertTo-Words $short)) $lt.Name
}
# Chests that start with fixed contents.
foreach ($inv in (Get-AssetsOfType "R5BLDefaultInventoryItemsParams" | Sort-Object { $_.Name })) {
    if ($inv.Path -notmatch '/POIChestsDefaultInventoriesItems/') { continue }
    $entries = @(Get-Prop $inv.Data "DefaultItemsToAdd") + @(Get-Prop $inv.Data "DefaultInventoryItemsInSlots")
    $acc = @{}
    foreach ($e in $entries) {
        if ($null -eq $e) { continue }
        $ref = Get-Prop $e "Item"
        if ($ref -and -not ($ref -is [string])) { $ref = Get-Prop $ref "ItemParams" }
        $n = Get-AssetName $ref
        if (-not $n -or -not $items[$n]) { continue }
        $c = [int](Get-Prop $e "Count")
        if (-not $acc.ContainsKey($n)) { $acc[$n] = 0 }
        $acc[$n] += $c
    }
    $label = "Chest: " + (ConvertTo-Words ($inv.Name -replace '^DA_Shared_Storage_', ''))
    foreach ($k in $acc.Keys) {
        $items[$k].drops.Add([ordered]@{
            npcId = $inv.Name; npcSourceId = $inv.Name; npcName = $label
            sourceType = "chest-inventory"; sourceTypeLabel = "Chest contents"
            chance = 1; minQuantity = $acc[$k]; maxQuantity = $acc[$k]; sourceTableId = $inv.Name
        })
        $dropRows++
    }
}
# Quest and research rewards.
$researchStation = [ordered]@{ sourceId = "Research"; id = "Research"; name = "Research"; category = "Research"; kind = "research" }
$researchCount = 0
foreach ($q in (Get-AssetsOfType "R5BLQuestParams" | Sort-Object { $_.Name })) {
    $logic = Get-Prop $q.Data "LogicData"
    if (-not $logic) { continue }
    $isResearch = $q.Path -match '/(RecipePaperUnlock|RecipeLootUnlock)/'
    $type = "quest"; $typeLabel = "Quest reward"
    if ($isResearch) { $type = "research"; $typeLabel = "Research" }
    $label = "${typeLabel}: " + (ConvertTo-Words ($q.Name -replace '^DA_QP_', ''))
    foreach ($e in @(Get-Prop $logic "RewardItems")) {
        if ($null -eq $e) { continue }
        $ref = Get-Prop $e "Item"
        if ($ref -and -not ($ref -is [string])) { $ref = Get-Prop $ref "ItemParams" }
        $n = Get-AssetName $ref
        if (-not $n -or -not $items[$n]) { continue }
        $c = [int](Get-Prop $e "Count")
        $items[$n].drops.Add([ordered]@{
            npcId = $q.Name; npcSourceId = $q.Name; npcName = $label
            sourceType = $type; sourceTypeLabel = $typeLabel
            chance = 1; minQuantity = $c; maxQuantity = $c; sourceTableId = $q.Name
        })
        $dropRows++
    }
    $rlt = Get-AssetName (Get-Prop $logic "RewardLootTable")
    if ($rlt -and $lootTables[$rlt]) { Add-Drops $rlt $type $typeLabel $label $q.Name }
    # Research: handing in a recipe paper unlocks recipes. Shown under the paper's "Crafts".
    if ($isResearch) {
        $papers = New-Object System.Collections.Generic.List[object]
        foreach ($g in @(Get-Prop $logic "GoalItems")) {
            if ($null -eq $g) { continue }
            $ref = Get-Prop $g "Item"
            if ($ref -and -not ($ref -is [string])) { $ref = Get-Prop $ref "ItemParams" }
            $r = Get-ItemRef (Get-AssetName $ref) ([int](Get-Prop $g "Count"))
            if ($r) { $papers.Add($r) }
        }
        if ($papers.Count -gt 0) {
            foreach ($rr in @(Get-Prop $logic "RewardRecipes")) {
                $rn = Get-AssetName $rr
                if (-not $rn -or -not $assets[$rn]) { continue }
                $rd = $assets[$rn].Data
                $unlocked = Get-RecipeSide (Get-Prop $rd "RecipeResult")
                $rlabel = Resolve-Text (Get-Prop (Get-Prop $rd "UIData") "Name")
                if (-not $rlabel -and $unlocked.Count -gt 0) { $rlabel = $unlocked[0].name }
                if (-not $rlabel) { $rlabel = ConvertTo-Words $rn }
                $row = [ordered]@{
                    sourceRecipeId = $rn
                    name = "Unlocks recipe: $rlabel"
                    recipeType = "research"
                    stations = @($researchStation)
                    inputs = $papers
                    outputs = $unlocked
                }
                foreach ($pp in $papers) { (Get-Usage $pp.sourceId).crafts.Add($row) }
                $researchCount++
            }
        }
    }
}
foreach ($it in $items.Values) {
    if ($it.drops.Count -gt 1) {
        $sorted = @($it.drops | Sort-Object -Property @{ Expression = { $_.chance }; Descending = $true }, @{ Expression = { $_.npcName } }, @{ Expression = { $_.sourceTableId } })
        $it.drops = New-Object System.Collections.Generic.List[object]
        foreach ($x in ($sorted | Select-Object -First 60)) { $it.drops.Add($x) }
    }
}
Write-Step "Drop records: $dropRows; research unlocks: $researchCount"

# --- Write the catalog ----------------------------------------------------------
function Write-JsonAtomic([string]$path, $data) {
    $json = ConvertTo-Json -InputObject $data -Depth 32 -Compress
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
$itemList = New-Object System.Collections.Generic.List[object]
foreach ($it in $items.Values) { $itemList.Add($it) }
$usageOut = [ordered]@{}
foreach ($k in ($usage.Keys | Sort-Object)) { if ($items[$k]) { $usageOut[$k] = $usage[$k] } }

$cats = [ordered]@{}; $rarities = [ordered]@{}
foreach ($it in $itemList) {
    $g = $it.topLevelCategoryLabel; if (-not $cats.Contains($g)) { $cats[$g] = 0 }; $cats[$g]++
    $r = $it.rarity; if (-not $r) { $r = "none" }; if (-not $rarities.Contains($r)) { $rarities[$r] = 0 }; $rarities[$r]++
}
$withDrops = @($itemList | Where-Object { $_.drops.Count -gt 0 }).Count

Write-JsonAtomic (Join-Path $OutputDir "items_full.json") $itemList
Write-JsonAtomic (Join-Path $OutputDir "item_usage.json") ([ordered]@{
    meta = [ordered]@{
        generatedFrom = "this server's game files"
        itemCount = $itemList.Count
        itemsWithUsage = $usageOut.Count
        recipeCount = $recipeCount
        traderOfferCount = $tradeCount
        buildingCostCount = $buildCount
        researchUnlockCount = $researchCount
        generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    byItemId = $usageOut
})
Write-JsonAtomic $summaryPath ([ordered]@{
    source = "built on this server from the game's own data files"
    builder_version = $BuilderVersion
    fingerprint = $fingerprint
    built_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    items_total = $itemList.Count
    items_with_drop_records = $withDrops
    items_with_usage = $usageOut.Count
    recipes = $recipeCount
    trader_offers = $tradeCount
    building_costs = $buildCount
    stations = $stationCount
    traders = $vendorCount
    categories = $cats
    rarities = $rarities
    stat_values = ($curveRows.Count -gt 0)
    stat_values_from = $statSource
    not_in_game_data = @("item art (the icons are Windrose+'s own)", "resource-zone map hints")
})

if ($cleanupWork -and $WorkDir -and (Test-Path -LiteralPath $WorkDir)) {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Step "Catalog written to $OutputDir ($($itemList.Count) items, $withDrops with drop records, $($usageOut.Count) with recipes or trades)."
exit 0
