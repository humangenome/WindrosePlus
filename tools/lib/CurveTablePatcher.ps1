# CurveTablePatcher.ps1 — Safe in-place CurveTable value patcher
# Uses the manifest from CurveTableParser to patch float values with full verification.

function Resolve-ConfigMatch {
    <#
    .SYNOPSIS
    Matches a row name against config patterns with explicit precedence:
    1. Exact match (highest priority)
    2. Longest wildcard pattern
    3. Catch-all "*" (lowest priority)

    This prevents JSON key order from affecting behavior (Codex finding #5).
    .OUTPUTS
    The matched value, or $null if no match.
    #>
    param(
        [string]$RowName,
        [hashtable]$Patterns  # pattern -> value
    )

    if (-not $Patterns -or $Patterns.Count -eq 0) { return $null }

    # Exact match first
    if ($Patterns.ContainsKey($RowName)) {
        return $Patterns[$RowName]
    }

    # Wildcard matches — longest pattern wins
    $bestMatch = $null
    $bestLen = -1
    foreach ($pattern in $Patterns.Keys) {
        if ($pattern -eq "*") { continue }  # handle catch-all last
        if ($RowName -like $pattern) {
            if ($pattern.Length -gt $bestLen) {
                $bestLen = $pattern.Length
                $bestMatch = $Patterns[$pattern]
            }
        }
    }
    if ($null -ne $bestMatch) { return $bestMatch }

    # Catch-all
    if ($Patterns.ContainsKey("*")) {
        return $Patterns["*"]
    }

    return $null
}

function Invoke-CurveTablePatch {
    <#
    .SYNOPSIS
    Patches a CurveTable .uexp file using a parsed manifest and config.

    .DESCRIPTION
    For each row in the manifest, checks config for multipliers/overrides.
    Patches the float value at the manifest's recorded offset.
    After patching, re-reads the bytes to verify only intended changes were made.

    .PARAMETER Manifest
    Output from Parse-CurveTable or Export-CurveTableManifest.

    .PARAMETER Config
    Hashtable with optional "multipliers" and "overrides" keys.
    Each is a hashtable of pattern -> value.
    Multipliers are applied first, then overrides replace the result.

    .PARAMETER UExpPath
    Path to the .uexp file to patch.

    .PARAMETER OutputPath
    Path to write the patched .uexp. If not specified, patches in-place.

    .OUTPUTS
    Hashtable with:
      - ChangesApplied: int count of values changed
      - Changes: array of {RowName, OriginalValue, NewValue, Offset}
      - VerificationPassed: bool
      - Error: string or $null
    #>
    param(
        [object]$Manifest,
        [hashtable]$Config,
        [string]$UExpPath,
        [string]$OutputPath = $null
    )

    $result = @{
        ChangesApplied = 0
        Changes = @()
        VerificationPassed = $false
        Error = $null
    }

    if (-not (Test-Path -LiteralPath $UExpPath)) {
        $result.Error = "Missing .uexp: $UExpPath"
        return $result
    }

    $uexp = [System.IO.File]::ReadAllBytes($UExpPath)
    $multipliers = @{}
    $overrides = @{}

    if ($Config.ContainsKey("multipliers")) {
        foreach ($key in $Config.multipliers.PSObject.Properties.Name) {
            $multipliers[$key] = [double]$Config.multipliers.$key
        }
    }
    if ($Config.ContainsKey("overrides")) {
        foreach ($key in $Config.overrides.PSObject.Properties.Name) {
            $overrides[$key] = [double]$Config.overrides.$key
        }
    }

    # Also handle when Config comes as plain hashtable (not PSCustomObject)
    if ($Config.ContainsKey("multipliers") -and $Config.multipliers -is [hashtable]) {
        $multipliers = $Config.multipliers
    }
    if ($Config.ContainsKey("overrides") -and $Config.overrides -is [hashtable]) {
        $overrides = $Config.overrides
    }

    $changes = [System.Collections.ArrayList]::new()

    # Get rows from either manifest format
    $rows = if ($Manifest.ContainsKey("Rows")) { $Manifest.Rows }
            elseif ($Manifest.ContainsKey("rows")) { $Manifest.rows }
            else { @() }

    foreach ($row in $rows) {
        $rowName = if ($row.ContainsKey("Name")) { $row.Name } else { $row.name }
        $keys = if ($row.ContainsKey("Keys")) { $row.Keys } else { $row.keys }

        foreach ($key in $keys) {
            $valueOffset = if ($key.ContainsKey("ValueOffset")) { $key.ValueOffset } else { $key.value_offset }
            $origValue = if ($key.ContainsKey("Value")) { $key.Value } else { $key.value }

            if ($valueOffset + 4 -gt $uexp.Length) { continue }

            # Verify the original value still matches what the manifest recorded
            $currentValue = [BitConverter]::ToSingle($uexp, $valueOffset)
            if ([Math]::Abs($currentValue - $origValue) -gt 0.001) {
                $result.Error = "Value mismatch at offset $valueOffset for '$rowName': manifest says $origValue but file has $currentValue. File may have been modified."
                return $result
            }

            # Apply multiplier
            $newValue = [double]$origValue
            $mult = Resolve-ConfigMatch -RowName $rowName -Patterns $multipliers
            if ($null -ne $mult) {
                $newValue = $origValue * $mult
            }

            # Apply override (replaces multiplier result)
            $ovr = Resolve-ConfigMatch -RowName $rowName -Patterns $overrides
            if ($null -ne $ovr) {
                $newValue = $ovr
            }

            # Skip if unchanged
            if ([Math]::Abs($newValue - $origValue) -lt 0.0001) { continue }

            # Patch the bytes
            $newBytes = [BitConverter]::GetBytes([float]$newValue)
            [Array]::Copy($newBytes, 0, $uexp, $valueOffset, 4)

            $null = $changes.Add(@{
                RowName = $rowName
                OriginalValue = [Math]::Round($origValue, 6)
                NewValue = [Math]::Round($newValue, 6)
                Offset = $valueOffset
            })
        }
    }

    $result.ChangesApplied = $changes.Count
    $result.Changes = $changes.ToArray()

    if ($changes.Count -eq 0) {
        $result.VerificationPassed = $true
        return $result
    }

    # Verification pass: re-read every patched offset and confirm the new value
    $verified = $true
    foreach ($change in $changes) {
        $readBack = [BitConverter]::ToSingle($uexp, $change.Offset)
        if ([Math]::Abs($readBack - $change.NewValue) -gt 0.01) {
            $verified = $false
            $result.Error = "Verification failed for '$($change.RowName)' at offset $($change.Offset): expected $($change.NewValue) but got $readBack"
            break
        }
    }
    $result.VerificationPassed = $verified

    if ($verified) {
        $outPath = if ($OutputPath) { $OutputPath } else { $UExpPath }
        [System.IO.File]::WriteAllBytes($outPath, $uexp)
    }

    return $result
}
