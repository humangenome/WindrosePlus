# IniConfigParser.ps1 — Parses WindrosePlus INI config into structured config object
#
# Reads windrose_plus.ini (and optional weapons/food/gear/entities configs) and
# returns a structured object that the build pipeline can consume. Maps friendly
# INI section/key names back to CurveTable raw row names for binary patching.
#
# Config file structure:
#   windrose_plus.ini              — Main config (required)
#   windrose_plus.weapons.ini      — Weapon damage/crit overrides (optional)
#   windrose_plus.food.ini         — Food/consumable/alchemy overrides (optional)
#   windrose_plus.gear.ini         — Armor/jewelry overrides (optional)
#   windrose_plus.entities.ini     — Land + naval entity overrides (optional)

# AES key is hardcoded — this is the Windrose game encryption key, not a secret
$script:WindroseAesKey = "0x5F430BF9FEF2B0B91B7C79C313BDAF291BA076A1DAB5045974186333AA16CFAE"

# Section-to-CurveTable mapping for the MAIN config file
$script:SectionToCurveTable = @{
    'PlayerStats'         = 'CT_CharactersAttributes'
    'Talents'             = 'CT_TalentData'
    'CoopScaling'         = 'CT_Mob_StatCorrection_CoopBased'
    'RestEffects'         = 'CT_RestGameplayEffectCurves'
    'Swimming'            = 'CT_OtherGEValues'
    'SharedCombatEffects' = 'CT_OtherGEValues'
    'Hearth'              = 'CT_OtherGEValues'
}

# Non-CurveTable sections in the main config.
# Features and Debug are Lua-side concerns (read from windrose_plus.json)
# but declared here so the parser does not warn if they appear in INI.
$script:NonCtSections = @('Server', 'Multipliers', 'Features', 'Debug')

function Read-IniFile {
    <#
    .SYNOPSIS
        Parse an INI file into a hashtable of sections.
    .DESCRIPTION
        Returns @{ SectionName = @{ key = value; ... }; ... }
        Skips comment lines (; and #) and blank lines.
        Strips inline comments ("; comment" after a value).
        Warns on duplicate keys within the same section.
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Error = "File not found: $Path" }
    }

    $sections = [ordered]@{}
    $currentSection = $null

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()

        # Skip empty lines and full-line comments (; or #)
        if ($trimmed -eq '' -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

        # Section header
        if ($trimmed -match '^\[(.+)\]$') {
            $currentSection = $Matches[1]
            if (-not $sections.Contains($currentSection)) {
                $sections[$currentSection] = [ordered]@{}
            }
            continue
        }

        # Key = Value (strip inline comments)
        if ($trimmed -match '^([^=]+?)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()

            # Strip inline comment (space + ; or #) — skip for [Server] section
            # which has string values (server_dir, rcon_password) that may contain ; or #
            if ($currentSection -ne 'Server' -and $val -match '^(.*?)\s+[;#].*$') {
                $stripped = $Matches[1].Trim()
                if ($stripped -ne '') { $val = $stripped }
            }

            if ($currentSection) {
                if ($sections[$currentSection].Contains($key)) {
                    Write-Warning "Duplicate key '$key' in [$currentSection] — using last value"
                }
                $sections[$currentSection][$key] = $val
            }
        }
    }

    return $sections
}

function Read-IniDefaults {
    <#
    .SYNOPSIS
        Parse a default INI file to extract Raw: comments as a mapping.
    .DESCRIPTION
        Reads an INI file and builds a lookup table from "; Raw: XYZ" comments.
        Returns @{ Mapping = @{ "Section:key" = "RawRowName" }; Defaults = @{ "Section:key" = "value" } }
    #>
    param([string]$Path)

    $mapping = @{}
    $defaults = @{}
    $currentSection = $null
    $pendingRaw = $null

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^\[(.+)\]$') {
            $currentSection = $Matches[1]
            $pendingRaw = $null
            continue
        }

        if ($trimmed -match '^;\s*Raw:\s*(.+)$') {
            $pendingRaw = $Matches[1].Trim()
            continue
        }

        if ($trimmed -match '^([^=]+?)\s*=\s*(.*)$' -and -not $trimmed.StartsWith(';') -and -not $trimmed.StartsWith('#') -and $currentSection) {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()

            if ($val -match '^(.*?)\s+[;#].*$') {
                $stripped = $Matches[1].Trim()
                if ($stripped -ne '') { $val = $stripped }
            }

            if ($pendingRaw) {
                $mapping["${currentSection}:${key}"] = $pendingRaw
                $pendingRaw = $null
            }
            $defaults["${currentSection}:${key}"] = $val
        } elseif (-not $trimmed.StartsWith(';') -and -not $trimmed.StartsWith('#')) {
            $pendingRaw = $null
        }
    }

    return @{
        Mapping  = $mapping
        Defaults = $defaults
    }
}

function ConvertTo-Boolean {
    param([string]$Value)
    $truthy = @('true', '1', 'yes', 'on')
    return $truthy -contains $Value.ToLower()
}

function ConvertTo-SafeDouble {
    param([string]$Value, [string]$Context = "")
    $result = 0.0
    if ([double]::TryParse($Value, [ref]$result)) {
        return $result
    }
    Write-Warning "Cannot parse '$Value' as a number${Context}. Skipping."
    return $null
}

function Resolve-SectionCurveTable {
    <#
    .SYNOPSIS
        Determine which CurveTable a section belongs to based on prefix routing rules.
    .DESCRIPTION
        Used by optional config files where section names indicate which CurveTable
        the overrides belong to. Returns the CurveTable name or $null if no match.
    #>
    param(
        [string]$SectionName,
        [hashtable]$PrefixRouting
    )

    foreach ($prefix in $PrefixRouting.Keys) {
        if ($SectionName.StartsWith($prefix)) {
            return $PrefixRouting[$prefix]
        }
    }
    return $null
}

function Import-EntityConfig {
    <#
    .SYNOPSIS
        Import an optional config file where sections group related overrides.
    .DESCRIPTION
        Each [Section] contains keys that map to CurveTable row names via Raw: comments
        in the corresponding default file. Only values that differ from defaults are
        returned as overrides.

        If PrefixRouting is provided, sections are routed to different CurveTables based
        on their name prefix (e.g., Naval_ sections → CT_ShipAttributes). Otherwise all
        sections use the single CurveTableName.
    .OUTPUTS
        Hashtable of CurveTable overrides: @{ CT_Name = @{ overrides = @{ raw_row = value } } }
    #>
    param(
        [string]$ConfigPath,
        [string]$DefaultPath,
        [string]$CurveTableName = "",
        [hashtable]$PrefixRouting = @{},
        [switch]$EntityKeyFallback
    )

    $overrides = @{}

    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $overrides }
    if (-not (Test-Path -LiteralPath $DefaultPath)) {
        Write-Warning "Default file not found for $(Split-Path $ConfigPath -Leaf) — skipping"
        return $overrides
    }

    $iniData = Read-IniFile -Path $ConfigPath
    if ($iniData.Error) {
        Write-Warning $iniData.Error
        return $overrides
    }

    $defaultInfo = Read-IniDefaults -Path $DefaultPath
    $mapping = $defaultInfo.Mapping
    $defaults = $defaultInfo.Defaults

    # Collect known section names from defaults for validation
    $defaultSections = @{}
    foreach ($k in $defaults.Keys) {
        $sec = $k.Split(':')[0]
        $defaultSections[$sec] = $true
    }

    foreach ($sectionName in $iniData.Keys) {
        # Warn if section doesn't exist in default file (possible typo or misroute)
        if (-not $defaultSections.Contains($sectionName)) {
            Write-Warning "Section [$sectionName] not found in $(Split-Path $DefaultPath -Leaf) — possible typo or wrong config file"
        }

        # Determine target CurveTable for this section
        # PrefixRouting takes priority, CurveTableName is the fallback
        $targetTable = $null
        if ($PrefixRouting.Count -gt 0) {
            $targetTable = Resolve-SectionCurveTable -SectionName $sectionName -PrefixRouting $PrefixRouting
        }
        if (-not $targetTable) { $targetTable = $CurveTableName }

        if (-not $targetTable) {
            Write-Warning "No CurveTable mapping for section [$sectionName] — skipping"
            continue
        }

        foreach ($kv in $iniData[$sectionName].GetEnumerator()) {
            $statKey = $kv.Key
            $newValue = ConvertTo-SafeDouble $kv.Value " (${sectionName}.${statKey})"
            if ($null -eq $newValue) { continue }

            # Resolve raw name from Raw: mapping
            $lookupKey = "${sectionName}:${statKey}"
            $rawName = $mapping[$lookupKey]

            # Fallback when Raw: mapping is missing
            if (-not $rawName) {
                if ($EntityKeyFallback) {
                    # Creature convention: SectionName_StatKey (e.g., AlphaWolf_Health)
                    $rawName = "${sectionName}_${statKey}"
                } else {
                    # Flat configs: key is already the raw CurveTable row name
                    $rawName = $statKey
                }
            }

            # Warn on unknown keys
            $defaultVal = $defaults[$lookupKey]
            if ($null -eq $defaultVal) {
                Write-Warning "Key '$statKey' in [$sectionName] not found in $(Split-Path $DefaultPath -Leaf) — possible typo (mapped to: $rawName)"
            }

            # Skip unchanged values
            if ($null -ne $defaultVal) {
                $defaultNum = ConvertTo-SafeDouble $defaultVal
                if ($null -ne $defaultNum -and [Math]::Abs($newValue - $defaultNum) -lt 0.0001) {
                    continue
                }
            }

            # Add override
            if (-not $overrides.Contains($targetTable)) {
                $overrides[$targetTable] = @{ overrides = @{} }
            }
            $overrides[$targetTable].overrides[$rawName] = $newValue
        }
    }

    return $overrides
}

function Convert-IniToConfig {
    <#
    .SYNOPSIS
        Convert parsed main INI data into the build pipeline config format.
    #>
    param(
        [hashtable]$IniData,
        [hashtable]$RawMapping,
        [hashtable]$DefaultValues
    )

    $result = @{
        AesKey      = $script:WindroseAesKey
        Server      = @{}
        Multipliers = @{}
        CurveTables = @{}
        Warnings    = @()
    }

    # Warn on unknown sections in main config
    $knownSections = @($script:SectionToCurveTable.Keys) + $script:NonCtSections
    foreach ($sectionName in $IniData.Keys) {
        if ($knownSections -notcontains $sectionName) {
            $msg = "Unknown section [$sectionName] in config — will be ignored"
            Write-Warning $msg
            $result.Warnings += $msg
        }
    }

    # --- Server section ---
    if ($IniData.Contains('Server')) {
        $s = $IniData['Server']
        $result.Server = @{
            http_port      = if ($s.http_port) { [int]$s.http_port } else { 8780 }
            game_port      = if ($s.game_port) { $s.game_port } else { $null }
            server_dir     = if ($s.server_dir) { $s.server_dir } else { '' }
            rcon_enabled   = if ($s.rcon_enabled) { ConvertTo-Boolean $s.rcon_enabled } else { $false }
            rcon_password  = if ($s.rcon_password) { $s.rcon_password } else { '' }
            query_enabled  = if ($s.Contains('query_enabled')) { ConvertTo-Boolean $s.query_enabled } else { $true }
            query_interval = if ($s.query_interval_ms) { [int]$s.query_interval_ms } else { 5000 }
            admin_ids      = if ($s.admin_steam_ids) { $s.admin_steam_ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } } else { @() }
        }
    }

    # --- Multipliers section ---
    if ($IniData.Contains('Multipliers')) {
        foreach ($kv in $IniData['Multipliers'].GetEnumerator()) {
            $val = ConvertTo-SafeDouble $kv.Value " (Multipliers.$($kv.Key))"
            if ($null -ne $val) {
                $result.Multipliers[$kv.Key] = $val
            }
        }
    }

    # --- CurveTable sections ---
    foreach ($sectionName in $script:SectionToCurveTable.Keys) {
        if (-not $IniData.Contains($sectionName)) { continue }

        $tableName = $script:SectionToCurveTable[$sectionName]

        foreach ($kv in $IniData[$sectionName].GetEnumerator()) {
            $iniKey = $kv.Key

            $newValue = ConvertTo-SafeDouble $kv.Value " (${sectionName}.${iniKey})"
            if ($null -eq $newValue) { continue }

            $lookupKey = "${sectionName}:${iniKey}"
            $rawName = $RawMapping[$lookupKey]

            if (-not $rawName -and $sectionName -eq 'PlayerStats') {
                $rawName = "Hero_$iniKey"
            }
            if (-not $rawName) {
                $rawName = $iniKey
            }

            $defaultVal = $DefaultValues[$lookupKey]
            if ($null -eq $defaultVal) {
                $msg = "Key '$iniKey' in [$sectionName] not found in defaults — possible typo (mapped to: $rawName)"
                Write-Warning $msg
                $result.Warnings += $msg
            }

            if ($null -ne $defaultVal) {
                $defaultNum = ConvertTo-SafeDouble $defaultVal
                if ($null -ne $defaultNum -and [Math]::Abs($newValue - $defaultNum) -lt 0.0001) {
                    continue
                }
            }

            if (-not $result.CurveTables.Contains($tableName)) {
                $result.CurveTables[$tableName] = @{ overrides = @{} }
            }
            $result.CurveTables[$tableName].overrides[$rawName] = $newValue
        }
    }

    return $result
}

function Import-WindrosePlusConfig {
    <#
    .SYNOPSIS
        Main entry point — reads all WindrosePlus config files and returns a build-ready config.
    .DESCRIPTION
        Loads the main config (windrose_plus.ini) and optionally merges in:
        - windrose_plus.weapons.ini   (weapon stats → CT_Weapon_GE_Values)
        - windrose_plus.food.ini      (food/consumable/alchemy → 3 CurveTables)
        - windrose_plus.gear.ini      (armor/jewelry → 2 CurveTables)
        - windrose_plus.entities.ini  (land → CT_CharactersAttributes, naval → CT_ShipAttributes)

        Only values that differ from their respective default files are included.
    .PARAMETER ConfigPath
        Path to windrose_plus.ini (main config, required)
    .PARAMETER DefaultPath
        Path to windrose_plus.default.ini. Auto-detected if not specified.
    #>
    param(
        [string]$ConfigPath,
        [string]$DefaultPath = ""
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @{ Error = "Config not found: $ConfigPath" }
    }

    $configDir = Split-Path $ConfigPath

    # Find the default config for mapping
    if (-not $DefaultPath) {
        $DefaultPath = Join-Path $configDir "windrose_plus.default.ini"
    }
    if (-not (Test-Path -LiteralPath $DefaultPath)) {
        return @{ Error = "Default config not found: $DefaultPath. Needed for Raw name mapping." }
    }

    # Parse main config
    $iniData = Read-IniFile -Path $ConfigPath
    if ($iniData.Error) { return $iniData }

    $defaultInfo = Read-IniDefaults -Path $DefaultPath
    $config = Convert-IniToConfig -IniData $iniData -RawMapping $defaultInfo.Mapping -DefaultValues $defaultInfo.Defaults

    # --- Merge optional config files ---
    # The .default.ini version provides the Raw: mapping comments
    $defaultDir = Split-Path $DefaultPath

    $optionalConfigs = @(
        @{
            Config  = "windrose_plus.weapons.ini"
            Default = "windrose_plus.weapons.default.ini"
            Table   = "CT_Weapon_GE_Values"
        },
        @{
            Config        = "windrose_plus.food.ini"
            Default       = "windrose_plus.food.default.ini"
            Table         = "CT_Food_GE_Values"
            PrefixRouting = @{
                'Consumables_'  = 'CT_Consumables_GE_Values'
                'Alchemy_'      = 'CT_Alchemy_GE_Values'
            }
        },
        @{
            Config        = "windrose_plus.gear.ini"
            Default       = "windrose_plus.gear.default.ini"
            Table         = "CT_Armor_GE_Values"
            PrefixRouting = @{
                'Necklaces' = 'CT_JewelryGEValues'
                'Rings'     = 'CT_JewelryGEValues'
            }
        },
        @{
            Config            = "windrose_plus.entities.ini"
            Default           = "windrose_plus.entities.default.ini"
            Table             = "CT_CharactersAttributes"
            EntityKeyFallback = $true
            PrefixRouting     = @{
                'Naval_' = 'CT_ShipAttributes'
            }
        }
    )

    foreach ($opt in $optionalConfigs) {
        $userFile = Join-Path $configDir $opt.Config
        $defaultFile = Join-Path $defaultDir $opt.Default

        if (-not (Test-Path -LiteralPath $userFile)) { continue }

        Write-Host "  Loading overrides from $(Split-Path $userFile -Leaf)" -ForegroundColor DarkGray

        $params = @{
            ConfigPath  = $userFile
            DefaultPath = $defaultFile
        }
        if ($opt.Table) { $params.CurveTableName = $opt.Table }
        if ($opt.PrefixRouting) { $params.PrefixRouting = $opt.PrefixRouting }
        if ($opt.EntityKeyFallback) { $params.EntityKeyFallback = $true }

        $overrides = Import-EntityConfig @params

        foreach ($tableName in $overrides.Keys) {
            if (-not $config.CurveTables.Contains($tableName)) {
                $config.CurveTables[$tableName] = @{ overrides = @{} }
            }
            foreach ($kv in $overrides[$tableName].overrides.GetEnumerator()) {
                $config.CurveTables[$tableName].overrides[$kv.Key] = $kv.Value
            }
        }
    }

    return $config
}
