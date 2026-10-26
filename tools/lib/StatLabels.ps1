# Readable names for the stats in the item catalog (tools/WindrosePlus-BuildCatalog.ps1 writes them as "label").
# The game names stats with code words ("ShipFireRangeRANK") and the numbers in an item's text by curve rows
# ("Greatsword_Souldrinker_AbilityCooldown", "Vanilla_SetEffect_CritChance"); the Items panel shows these labels.
# The dashboard page (server/web/livemap/index.html, readableStatName) applies the same rules to catalogs built
# before labels existed. Test: scripts/Test-StatLabels.ps1

$script:WindroseStatNames = @{
    'AttackPower'          = 'Attack power'
    'ShipCannonDamage'     = 'Ship damage'
    'ShipCannonReloadTime' = 'Ship reload'
    'ShipFireAccuracyRANK' = 'Ship accuracy'
    'ShipFireRangeRANK'    = 'Ship range'
}
# short words inside the game's names
$script:WindroseStatWords = @{
    'Dmg' = 'damage'; 'HP' = 'health'; 'Cons' = 'use'; 'Crit' = 'critical'; 'Add' = 'bonus'; 'Resist' = 'resistance'
    'Wpn' = 'weapon'; 'Stmn' = 'stamina'; 'Crpt' = 'corruption'; 'Coeff' = 'coefficient'; 'Eff' = 'effect'
    'Resotre' = 'restore'
}

function ConvertTo-WindroseStatWords([string]$Name) {
    $s = $Name -replace 'RANK$', ''
    $s = [regex]::Replace($s, '([A-Z]+)([A-Z][a-z])', '$1 $2')
    $s = [regex]::Replace($s, '([a-z0-9])([A-Z])', '$1 $2')
    # a number stuck to a word ("Effect1") is an index, not part of the name
    $words = @($s -split '[\s_]+' | ForEach-Object { $_ -replace '(?<=[A-Za-z])\d+$', '' } | Where-Object { $_ })
    if ($words.Count -eq 0) { return 'Value' }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($w in $words) {
        if ($script:WindroseStatWords.ContainsKey($w)) { $w = $script:WindroseStatWords[$w] }
        elseif ($w -cnotmatch '^[A-Z0-9]{2,}$') { $w = $w.ToLowerInvariant() }
        # "PostureBonusAdd" would read "posture bonus bonus"
        if ($out.Count -and $out[$out.Count - 1] -eq $w) { continue }
        $out.Add($w)
    }
    $text = ($out -join ' ')
    return $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1)
}

# $Stat: the stat tag of a stat entry ('' for a number in an item's text); $RowName: its curve row.
function Get-WindroseStatLabel([string]$Stat, [string]$RowName) {
    if ($Stat -and $Stat -ne 'None') {
        if ($script:WindroseStatNames.ContainsKey($Stat)) { return $script:WindroseStatNames[$Stat] }
        return ConvertTo-WindroseStatWords $Stat
    }
    if (-not $RowName -or $RowName -eq 'None' -or $RowName -match '^-?\d+(\.\d+)?$') { return 'Value' }
    $r = $RowName -replace '_(UI|StatValue)$', ''
    if ($r -match '_SetEffect_(.+)$') { $r = $Matches[1] }
    else { $r = @($r -split '_' | Where-Object { $_ })[-1] }
    return ConvertTo-WindroseStatWords $r
}
