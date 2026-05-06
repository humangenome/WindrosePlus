[CmdletBinding()]
param(
    [string]$WorldFolder,

    [switch]$EmitJson
)

# --- byte-array helpers -------------------------------------------------------

function ConvertTo-BytesAscii {
    param([string]$Value)
    return [System.Text.Encoding]::ASCII.GetBytes($Value)
}

function Find-NeedleOffsets {
    param([byte[]]$Hay, [byte[]]$Needle, [int]$Start = 0)
    $result = New-Object System.Collections.Generic.List[int]
    if ($Needle.Length -eq 0 -or $Hay.Length -lt $Needle.Length) { return $result }
    $end = $Hay.Length - $Needle.Length
    $first = $Needle[0]
    $i = $Start
    while ($i -le $end) {
        if ($Hay[$i] -eq $first) {
            $match = $true
            for ($k = 1; $k -lt $Needle.Length; $k++) {
                if ($Hay[$i + $k] -ne $Needle[$k]) { $match = $false; break }
            }
            if ($match) { $result.Add($i) | Out-Null; $i = $i + 1; continue }
        }
        $i++
    }
    return $result
}

function Read-Uint32LE {
    param([byte[]]$Hay, [int]$Offset)
    if ($Offset -lt 0 -or ($Offset + 4) -gt $Hay.Length) { return $null }
    return ([uint32]$Hay[$Offset]) -bor `
           ([uint32]$Hay[$Offset+1] -shl 8) -bor `
           ([uint32]$Hay[$Offset+2] -shl 16) -bor `
           ([uint32]$Hay[$Offset+3] -shl 24)
}

function Read-Float64LE {
    param([byte[]]$Hay, [int]$Offset)
    if ($Offset -lt 0 -or ($Offset + 8) -gt $Hay.Length) { return $null }
    return [System.BitConverter]::ToDouble($Hay, $Offset)
}

function Find-NextByte {
    param([byte[]]$Hay, [byte]$Target, [int]$Start, [int]$End)
    $stop = if ($End -lt $Hay.Length) { $End } else { $Hay.Length }
    for ($i = $Start; $i -lt $stop; $i++) { if ($Hay[$i] -eq $Target) { return $i } }
    return -1
}

function Round6 {
    param([double]$Value)
    return [Math]::Round($Value * 1e6) / 1e6
}

# --- token-driven extractors --------------------------------------------------

$T_FixedRandom  = ConvertTo-BytesAscii "FixedRandomNumber`0"
$T_CommonIsland = ConvertTo-BytesAscii "CommonIsland`0"
$T_Terrains     = ConvertTo-BytesAscii "Terrains`0"
$T_BoundsX      = ConvertTo-BytesAscii "BoundsSizeX`0"
$T_BoundsY      = ConvertTo-BytesAscii "BoundsSizeY`0"
$T_WorldLoc     = ConvertTo-BytesAscii "WorldLocation`0"

function Find-LengthPrefixedUint32 {
    param([byte[]]$Hay, [byte[]]$Token)
    $offsets = Find-NeedleOffsets -Hay $Hay -Needle $Token
    if ($offsets.Count -eq 0) { return $null }
    $tokEnd = $offsets[0] + $Token.Length
    return Read-Uint32LE -Hay $Hay -Offset $tokEnd
}

function Get-SeedHits {
    param([byte[]]$Bytes, [string]$FileName)
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($a in (Find-NeedleOffsets -Hay $Bytes -Needle $T_FixedRandom)) {
        $valOffset = $a + $T_FixedRandom.Length
        $v = Read-Uint32LE -Hay $Bytes -Offset $valOffset
        if ($null -ne $v) {
            $hits.Add([pscustomobject]@{ value = [uint32]$v; offset = $valOffset; fileName = $FileName }) | Out-Null
        }
    }
    return $hits
}

function Update-WorldPresetCounts {
    param([byte[]]$Bytes, [hashtable]$Counts)
    foreach ($a in (Find-NeedleOffsets -Hay $Bytes -Needle $T_CommonIsland)) {
        $lenOffset = $a + $T_CommonIsland.Length
        $len = Read-Uint32LE -Hay $Bytes -Offset $lenOffset
        if ($null -eq $len) { continue }
        $strStart = $lenOffset + 4
        $strEnd   = $strStart + [int]$len
        if ($len -le 0 -or $len -gt 512 -or $strEnd -gt $Bytes.Length) { continue }
        $s = [System.Text.Encoding]::UTF8.GetString($Bytes, $strStart, [int]$len).TrimEnd([char]0)
        if ($s.StartsWith('/R5BusinessRules/CommonIslands/')) {
            if ($Counts.ContainsKey($s)) { $Counts[$s] = $Counts[$s] + 1 } else { $Counts[$s] = 1 }
        }
    }
}

function Parse-OneTerrainPlacement {
    param([byte[]]$Sub, [int]$Slot)

    $bx = Find-LengthPrefixedUint32 -Hay $Sub -Token $T_BoundsX
    $by = Find-LengthPrefixedUint32 -Hay $Sub -Token $T_BoundsY

    $worldLocOffsets = Find-NeedleOffsets -Hay $Sub -Needle $T_WorldLoc
    if ($worldLocOffsets.Count -eq 0) { return $null }
    $wlOffset = $worldLocOffsets[0] + $T_WorldLoc.Length
    $blockLen = Read-Uint32LE -Hay $Sub -Offset $wlOffset
    if ($null -eq $blockLen) { return $null }
    $blockStart = $wlOffset + 4
    # JS convention: blockLen includes the 4-byte length prefix itself.
    $blockEnd   = $wlOffset + [int]$blockLen
    if ($blockLen -le 0 -or $blockEnd -gt $Sub.Length) { return $null }

    $sx = $null; $sy = $null; $sz = $null
    $i = $blockStart
    while (($i + 11) -le $blockEnd) {
        $marker = $Sub[$i]
        $i = $i + 1
        $nameEnd = Find-NextByte -Hay $Sub -Target ([byte]0) -Start $i -End $blockEnd
        if ($nameEnd -lt 0 -or ($nameEnd + 8) -gt $blockEnd) { break }
        $compName = [System.Text.Encoding]::ASCII.GetString($Sub, $i, $nameEnd - $i)
        $i = $nameEnd + 1
        if ($marker -ne 1 -or ($i + 8) -gt $blockEnd) { break }
        $f = Read-Float64LE -Hay $Sub -Offset $i
        $i = $i + 8
        switch ($compName) {
            'X' { $sx = $f }
            'Y' { $sy = $f }
            'Z' { $sz = $f }
        }
    }

    if ($null -eq $sx -or $null -eq $sy -or $null -eq $sz) { return $null }
    if ($null -eq $bx -or $null -eq $by) { return $null }

    return [pscustomobject]@{
        slot   = [int]$Slot
        center = [pscustomobject]@{ x = (Round6 $sx); y = (Round6 $sy); z = (Round6 $sz) }
        bounds = [pscustomobject]@{ width = (36 * [int]$bx); height = (36 * [int]$by) }
    }
}

function Parse-TerrainsBlock {
    param([byte[]]$Bytes, [int]$TokenOffset)

    $lenOffset = $TokenOffset + $T_Terrains.Length
    $blockLen  = Read-Uint32LE -Hay $Bytes -Offset $lenOffset
    if ($null -eq $blockLen) { return @() }
    $blockStart = $lenOffset + 4
    # JS convention: blockLen includes the 4-byte length prefix itself.
    $blockEnd   = $lenOffset + [int]$blockLen
    if ($blockLen -lt 4 -or $blockEnd -gt $Bytes.Length) { return @() }

    $placements = New-Object System.Collections.Generic.List[object]
    $d = $blockStart
    while (($d + 6) -le $blockEnd) {
        while ($d -lt $blockEnd -and $Bytes[$d] -eq 0) { $d++ }
        if (($d + 6) -gt $blockEnd) { break }
        if ($Bytes[$d] -ne 3) { break }
        $nameEnd = Find-NextByte -Hay $Bytes -Target ([byte]0) -Start ($d + 1) -End $blockEnd
        if ($nameEnd -lt 0 -or ($nameEnd + 5) -gt $blockEnd) { break }
        $slotName = [System.Text.Encoding]::ASCII.GetString($Bytes, $d + 1, $nameEnd - ($d + 1))
        $entryLen = Read-Uint32LE -Hay $Bytes -Offset ($nameEnd + 1)
        if ($null -eq $entryLen) { break }
        $entryStart = $nameEnd + 5
        $entryEnd   = $nameEnd + 1 + [int]$entryLen
        if ($entryLen -lt 4 -or $entryEnd -gt $blockEnd) { break }
        if ($slotName -match '^\d+$') {
            $sub = New-Object byte[] ($entryEnd - $entryStart)
            [Array]::Copy($Bytes, $entryStart, $sub, 0, $sub.Length)
            $placement = Parse-OneTerrainPlacement -Sub $sub -Slot ([int]$slotName)
            if ($placement) { $placements.Add($placement) | Out-Null }
        }
        $d = $entryEnd
    }
    if ($placements.Count -eq 0) { return @() }
    return ($placements | Sort-Object -Property slot)
}

function Parse-AllTerrainPlacements {
    param([byte[]]$Bytes)
    $variantKeys = @{}
    $variantPlace = @{}
    foreach ($off in (Find-NeedleOffsets -Hay $Bytes -Needle $T_Terrains)) {
        $placements = Parse-TerrainsBlock -Bytes $Bytes -TokenOffset $off
        if ($placements -and $placements.Count -gt 0) {
            $keyParts = @()
            foreach ($pl in $placements) {
                $keyParts += ("{0}|{1}|{2}|{3}|{4}|{5}" -f $pl.slot, $pl.center.x, $pl.center.y, $pl.center.z, $pl.bounds.width, $pl.bounds.height)
            }
            $key = $keyParts -join ';'
            if ($variantKeys.ContainsKey($key)) {
                $variantKeys[$key] = $variantKeys[$key] + 1
            } else {
                $variantKeys[$key] = 1
                $variantPlace[$key] = $placements
            }
        }
    }
    if ($variantKeys.Count -eq 0) { return @() }
    $bestKey = ($variantKeys.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Name
    return $variantPlace[$bestKey]
}

# --- main ---------------------------------------------------------------------

function Get-WindroseLayoutScan {
    param([Parameter(Mandatory=$true)][string]$Path)

    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "World folder not found: $Path"
    }

    $sstFiles = Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop |
        Where-Object { $_.Name.ToLowerInvariant().EndsWith('.sst') }

    if ($sstFiles.Count -eq 0) { throw "No .sst files in $Path. Cannot scan." }

    $entries = New-Object System.Collections.Generic.List[object]
    $seedHits = New-Object System.Collections.Generic.List[object]
    $worldPresetCounts = @{}
    $bytesByName = @{}

    foreach ($f in $sstFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $bytesByName[$f.Name] = $bytes

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try { $hashBytes = $sha256.ComputeHash($bytes) } finally { $sha256.Dispose() }
        $hash = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })

        $entries.Add([pscustomobject]@{
            Name = $f.Name; Size = [long]$f.Length; Hash = $hash
        }) | Out-Null

        $hits = Get-SeedHits -Bytes $bytes -FileName $f.Name
        if ($hits) { foreach ($h in $hits) { $seedHits.Add($h) | Out-Null } }
        Update-WorldPresetCounts -Bytes $bytes -Counts $worldPresetCounts
    }

    $sorted = $entries | Sort-Object `
        @{Expression = { $_.Name }; Ascending = $true},
        @{Expression = { $_.Size }; Ascending = $true},
        @{Expression = { $_.Hash }; Ascending = $true}

    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append("`n") }
        [void]$sb.Append($sorted[$i].Name)
        [void]$sb.Append([char]0)
        [void]$sb.Append([string]$sorted[$i].Size)
        [void]$sb.Append([char]0)
        [void]$sb.Append($sorted[$i].Hash)
    }
    $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $fpBytes = $sha.ComputeHash($manifestBytes) } finally { $sha.Dispose() }
    $layoutFingerprint = -join ($fpBytes | ForEach-Object { $_.ToString('x2') })

    $uniqueSeeds = ($seedHits | ForEach-Object { $_.value } | Sort-Object -Unique)
    if ($uniqueSeeds.Count -ne 1) {
        throw ("Expected exactly one unique seed; found {0}" -f $uniqueSeeds.Count)
    }
    $seed = [string]$uniqueSeeds[0]

    $worldPreset = $null
    if ($worldPresetCounts.Count -gt 0) {
        $worldPreset = ($worldPresetCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
    }

    $bestPlacements = @()
    foreach ($name in ($bytesByName.Keys | Sort-Object)) {
        $p = Parse-AllTerrainPlacements -Bytes $bytesByName[$name]
        if ($p -and $p.Count -gt $bestPlacements.Count) { $bestPlacements = $p }
    }

    if ($null -eq $worldPreset) { $worldPreset = '' }
    if (-not $bestPlacements) { $bestPlacements = @() }

    return [pscustomobject]@{
        layoutFingerprint      = $layoutFingerprint
        shortLayoutFingerprint = $layoutFingerprint.Substring(0, 16)
        seed                   = $seed
        worldPreset            = $worldPreset
        terrainPlacements      = @($bestPlacements)
        sstFileCount           = $sorted.Count
        worldFolder            = $Path
    }
}

if ($WorldFolder) {
    $result = Get-WindroseLayoutScan -Path $WorldFolder

    if ($EmitJson) {
        $result | ConvertTo-Json -Depth 10 -Compress
    } else {
        Write-Output $result
    }
}
