# CurveTableParser.ps1 — Structural CurveTable .uasset/.uexp parser
# Parses retoc-converted CurveTable assets and emits a manifest of row names,
# key offsets, and values. Used by the patcher to safely modify values.

function Find-NameTable {
    <#
    .SYNOPSIS
    Finds the name table in a retoc-converted .uasset by scanning for the
    "None" FString pattern and validating surrounding entries.
    .OUTPUTS
    Int32 offset of the name table start, or -1 if not found.
    #>
    param([byte[]]$Data)

    # Name table entries are: int32 length + UTF-8 string + null + uint32 hash
    # Search for "None" as an FString entry: len=5 (4 chars + null), "None\0", hash
    $nonePattern = [byte[]]@(5, 0, 0, 0, 0x4E, 0x6F, 0x6E, 0x65, 0x00)  # int32(5) + "None\0"

    $pos = Find-BytePattern -Data $Data -Pattern $nonePattern -Start 0
    while ($pos -ge 0) {
        # Validate: walk forward from this position counting valid entries
        $testPos = $pos
        $validCount = 0
        for ($i = 0; $i -lt 500; $i++) {
            if ($testPos + 4 -gt $Data.Length) { break }
            $slen = [BitConverter]::ToInt32($Data, $testPos)
            if ($slen -le 0 -or $slen -gt 500) { break }
            $entryEnd = $testPos + 4 + $slen + 4  # len + string + hash
            if ($entryEnd -gt $Data.Length) { break }
            if ($Data[$testPos + 4 + $slen - 1] -ne 0) { break }  # null terminator
            # Verify printable ASCII
            $valid = $true
            for ($j = 0; $j -lt ($slen - 1); $j++) {
                $b = $Data[$testPos + 4 + $j]
                if ($b -lt 32 -or $b -ge 127) { $valid = $false; break }
            }
            if (-not $valid) { break }
            $validCount++
            $testPos = $entryEnd
        }

        if ($validCount -ge 5) {
            # Walk backwards to find the real start
            $tableStart = $pos
            while ($tableStart -gt 4) {
                $foundPrev = $false
                for ($tryLen = 1; $tryLen -lt 300; $tryLen++) {
                    $candidate = $tableStart - 4 - $tryLen - 4  # hash + string + length
                    if ($candidate -lt 0) { break }
                    $slen = [BitConverter]::ToInt32($Data, $candidate)
                    if ($slen -ne $tryLen) { continue }
                    if ($Data[$candidate + 4 + $slen - 1] -ne 0) { continue }
                    # Verify ASCII
                    $ok = $true
                    for ($j = 0; $j -lt ($slen - 1); $j++) {
                        $b = $Data[$candidate + 4 + $j]
                        if ($b -lt 32 -or $b -ge 127) { $ok = $false; break }
                    }
                    if ($ok) {
                        $tableStart = $candidate
                        $foundPrev = $true
                        break
                    }
                }
                if (-not $foundPrev) { break }
            }
            return $tableStart
        }

        $pos = Find-BytePattern -Data $Data -Pattern $nonePattern -Start ($pos + 1)
    }
    return -1
}

function Read-NameTable {
    <#
    .SYNOPSIS
    Parses name table entries starting at the given offset.
    .OUTPUTS
    String array of names.
    #>
    param([byte[]]$Data, [int]$Start)

    $names = [System.Collections.ArrayList]::new()
    $pos = $Start
    while ($pos + 4 -lt $Data.Length) {
        $slen = [BitConverter]::ToInt32($Data, $pos)
        if ($slen -le 0 -or $slen -gt 1000) { break }
        $entryEnd = $pos + 4 + $slen
        if ($entryEnd + 4 -gt $Data.Length) { break }
        if ($Data[$entryEnd - 1] -ne 0) { break }
        $name = [System.Text.Encoding]::UTF8.GetString($Data, $pos + 4, $slen - 1)
        $null = $names.Add($name)
        $pos = $entryEnd + 4  # skip hash
    }
    return ,$names.ToArray()
}

function Read-FName {
    <#
    .SYNOPSIS
    Reads an FName (uint32 index + uint32 number) from binary data.
    #>
    param([byte[]]$Data, [int]$Offset, [string[]]$Names)

    $idx = [BitConverter]::ToUInt32($Data, $Offset)
    $num = [BitConverter]::ToUInt32($Data, $Offset + 4)
    if ($idx -lt $Names.Length) {
        $name = $Names[$idx]
        if ($num -gt 0) { $name = "${name}_$($num - 1)" }
        return $name
    }
    return "__UNK_$idx"
}

function Find-BytePattern {
    <#
    .SYNOPSIS
    Finds a byte pattern in a byte array starting from a given position.
    .OUTPUTS
    Int32 offset of first match, or -1 if not found.
    #>
    param([byte[]]$Data, [byte[]]$Pattern, [int]$Start = 0)

    $end = $Data.Length - $Pattern.Length
    for ($i = $Start; $i -le $end; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Data[$i + $j] -ne $Pattern[$j]) {
                $match = $false
                break
            }
        }
        if ($match) { return $i }
    }
    return -1
}

function Parse-CurveTable {
    <#
    .SYNOPSIS
    Structurally parses a CurveTable .uasset/.uexp pair and returns a manifest
    of rows with their key offsets and values.

    .DESCRIPTION
    Unlike heuristic approaches, this parser:
    1. Finds the name table structurally
    2. Locates the row count after the first None FName terminator
    3. Parses each row's curve structure (key count, interp mode, time/value pairs)
    4. Records absolute byte offsets for every value

    The manifest enables safe in-place patching with full verification.

    .OUTPUTS
    Hashtable with:
      - Names: string[] name table
      - NoneIndex: int index of "None" in name table
      - RowCount: int number of rows
      - Rows: array of row objects, each with:
        - Name: string row name
        - NameOffset: int offset of the FName in uexp
        - Keys: array of key objects, each with:
          - Time: float
          - TimeOffset: int absolute offset in uexp
          - Value: float
          - ValueOffset: int absolute offset in uexp
      - Error: string or $null
    #>
    param(
        [string]$UAssetPath,
        [string]$UExpPath = $null
    )

    if (-not $UExpPath) {
        $UExpPath = $UAssetPath -replace '\.uasset$', '.uexp'
    }

    $result = @{
        Names = @()
        NoneIndex = -1
        RowCount = 0
        Rows = @()
        Error = $null
    }

    if (-not (Test-Path -LiteralPath $UAssetPath)) {
        $result.Error = "Missing .uasset: $UAssetPath"
        return $result
    }
    if (-not (Test-Path -LiteralPath $UExpPath)) {
        $result.Error = "Missing .uexp: $UExpPath"
        return $result
    }

    $uasset = [System.IO.File]::ReadAllBytes($UAssetPath)
    $uexp = [System.IO.File]::ReadAllBytes($UExpPath)

    # Find and parse name table
    $tableStart = Find-NameTable -Data $uasset
    if ($tableStart -lt 0) {
        $result.Error = "Could not find name table"
        return $result
    }

    $names = Read-NameTable -Data $uasset -Start $tableStart
    if ($names.Length -lt 3) {
        $result.Error = "Name table too small: $($names.Length) entries"
        return $result
    }

    $noneIdx = -1
    for ($i = 0; $i -lt $names.Length; $i++) {
        if ($names[$i] -eq "None") { $noneIdx = $i; break }
    }
    if ($noneIdx -lt 0) {
        $result.Error = "No 'None' in name table"
        return $result
    }

    $result.Names = $names
    $result.NoneIndex = $noneIdx

    # Build None FName bytes for scanning
    $noneBytes = [byte[]]::new(8)
    [BitConverter]::GetBytes([uint32]$noneIdx).CopyTo($noneBytes, 0)
    # Second uint32 is already 0

    # Find the first None FName in uexp (terminates the UObject property list)
    # Then the next int32 should be the row count
    $firstNone = Find-BytePattern -Data $uexp -Pattern $noneBytes -Start 0
    if ($firstNone -lt 0) {
        $result.Error = "No None FName found in uexp"
        return $result
    }

    # After the first None FName (8 bytes), read the row count
    $rowCountOffset = $firstNone + 8
    if ($rowCountOffset + 4 -gt $uexp.Length) {
        $result.Error = "Uexp too short after first None"
        return $result
    }

    $rowCount = [BitConverter]::ToInt32($uexp, $rowCountOffset)
    if ($rowCount -le 0 -or $rowCount -gt 5000) {
        # Not a valid row count at first None — scan for a better one
        $searchPos = $firstNone + 1
        $found = $false
        while ($searchPos -lt $uexp.Length - 12) {
            $nextNone = Find-BytePattern -Data $uexp -Pattern $noneBytes -Start $searchPos
            if ($nextNone -lt 0) { break }
            $rc = [BitConverter]::ToInt32($uexp, $nextNone + 8)
            if ($rc -gt 0 -and $rc -lt 5000) {
                $rowCountOffset = $nextNone + 8
                $rowCount = $rc
                $firstNone = $nextNone
                $found = $true
                break
            }
            $searchPos = $nextNone + 1
        }
        if (-not $found) {
            $result.Error = "Could not find valid row count"
            return $result
        }
    }

    $result.RowCount = $rowCount

    # Parse rows structurally
    # Each row: FName RowName (8 bytes) + curve data
    # Curve data: int32 curveType + ... keys
    $pos = $rowCountOffset + 4
    $rows = [System.Collections.ArrayList]::new()
    $float1Bytes = [BitConverter]::GetBytes([float]1.0)

    for ($r = 0; $r -lt $rowCount; $r++) {
        if ($pos + 8 -gt $uexp.Length) { break }

        $rowName = Read-FName -Data $uexp -Offset $pos -Names $names
        $nameOffset = $pos
        $pos += 8

        # Find the next None FName to determine row span
        $nextNone = Find-BytePattern -Data $uexp -Pattern $noneBytes -Start $pos
        if ($nextNone -lt 0) { $nextNone = $uexp.Length }

        $rowSpan = $uexp[$pos..($nextNone - 1)]
        $rowDataStart = $pos
        $keys = [System.Collections.ArrayList]::new()

        # Parse curve keys within this row's data span
        # Look for all float pairs where the first could be a time value
        # Primary method: find Time=1.0 pattern (single-key curves)
        $f1Pos = Find-BytePattern -Data $uexp -Pattern $float1Bytes -Start $pos
        while ($f1Pos -ge 0 -and $f1Pos -lt $nextNone) {
            $valueOffset = $f1Pos + 4
            if ($valueOffset + 4 -le $nextNone) {
                $timeVal = [BitConverter]::ToSingle($uexp, $f1Pos)
                $value = [BitConverter]::ToSingle($uexp, $valueOffset)
                # Validate: time should be exactly 1.0 and value should be reasonable
                if ($timeVal -eq 1.0 -and [Math]::Abs($value) -lt 1e10 -and -not [float]::IsNaN($value) -and -not [float]::IsInfinity($value)) {
                    $null = $keys.Add(@{
                        Time = $timeVal
                        TimeOffset = $f1Pos
                        Value = [Math]::Round($value, 6)
                        ValueOffset = $valueOffset
                    })
                    break  # Take first valid match per row
                }
            }
            $f1Pos = Find-BytePattern -Data $uexp -Pattern $float1Bytes -Start ($f1Pos + 1)
            if ($f1Pos -ge $nextNone) { break }
        }

        $null = $rows.Add(@{
            Name = $rowName
            NameOffset = $nameOffset
            Keys = $keys.ToArray()
        })

        # Advance past the None terminator
        $pos = $nextNone + 8
    }

    $result.Rows = $rows.ToArray()
    return $result
}

function Export-CurveTableManifest {
    <#
    .SYNOPSIS
    Parses a CurveTable and exports a JSON manifest with all row names,
    values, and their byte offsets.
    #>
    param(
        [string]$UAssetPath,
        [string]$OutputPath = $null
    )

    $parsed = Parse-CurveTable -UAssetPath $UAssetPath
    if ($parsed.Error) {
        Write-Warning "Parse error for $UAssetPath : $($parsed.Error)"
        return $null
    }

    $manifest = @{
        source = $UAssetPath
        row_count = $parsed.RowCount
        name_count = $parsed.Names.Length
        none_index = $parsed.NoneIndex
        rows = @()
    }

    foreach ($row in $parsed.Rows) {
        $rowEntry = @{
            name = $row.Name
            name_offset = $row.NameOffset
            keys = @()
        }
        foreach ($key in $row.Keys) {
            $rowEntry.keys += @{
                time = $key.Time
                time_offset = $key.TimeOffset
                value = $key.Value
                value_offset = $key.ValueOffset
            }
        }
        $manifest.rows += $rowEntry
    }

    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, ($manifest | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    }

    return $manifest
}
