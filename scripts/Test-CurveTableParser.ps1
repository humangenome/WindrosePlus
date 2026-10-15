# Tests for tools/lib/CurveTableParser.ps1 and the first row of a table.
# The game's tables cannot ship in this repository, so each case builds a small table
# with the same layout in a temp folder. Run: pwsh scripts/Test-CurveTableParser.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'tools/lib/CurveTableParser.ps1')
. (Join-Path $root 'tools/lib/CurveTablePatcher.ps1')

$names = @('/Script/Engine', 'ArrayProperty', 'FloatProperty', 'Keys', 'None', 'Row_First', 'Row_Second', 'Row_Third', 'SimpleCurveKey', 'StructProperty', 'CurveTable')
function NameIndex([string]$n) { return [array]::IndexOf($names, $n) }

function New-UAsset {
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([byte[]]::new(16))
    foreach ($n in $names) {
        $b = [System.Text.Encoding]::ASCII.GetBytes($n)
        $w.Write([int]($b.Length + 1)); $w.Write($b); $w.Write([byte]0); $w.Write([uint32]0x12345678)
    }
    $w.Write([byte[]]::new(16))
    return $ms.ToArray()
}

# One row: [row FName] [Keys FName] [int32 key count] [float time 1.0] [float value] [None]
function Write-Row($w, [string]$Row, [float]$Value, [uint32]$Number = 0) {
    $w.Write([uint32](NameIndex $Row)); $w.Write([uint32]$Number)
    $w.Write([uint32](NameIndex 'Keys')); $w.Write([uint32]0)
    $w.Write([int]1); $w.Write([float]1.0); $w.Write([float]$Value)
    $w.Write([uint32](NameIndex 'None')); $w.Write([uint32]0)
}

# Layout C, as current Windrose builds write it:
#   [byte 0] [None] [int32 bHasGuid] ([16-byte GUID]) [int32 NumRows] [uint8 mode] rows...
# Layout A, older engines: [byte 0] [None] [int32 NumRows] rows...
function New-UExp([string]$Layout, [object[]]$Rows, [int]$HasGuid = 0) {
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([byte]0)
    $w.Write([uint32](NameIndex 'None')); $w.Write([uint32]0)
    if ($Layout -eq 'C') {
        $w.Write([int]$HasGuid)
        if ($HasGuid) { $w.Write([byte[]](1..16)) }
        $w.Write([int]$Rows.Count); $w.Write([byte]1)
    } else {
        $w.Write([int]$Rows.Count)
    }
    foreach ($r in $Rows) { Write-Row $w $r[0] $r[1] $(if ($r.Count -gt 2) { $r[2] } else { 0 }) }
    $w.Write([byte[]]::new(4))
    return $ms.ToArray()
}

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-ct-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base | Out-Null
$failed = 0
function New-Table([string]$Name, [byte[]]$UExp) {
    $ua = Join-Path $base "$Name.uasset"
    [System.IO.File]::WriteAllBytes($ua, (New-UAsset))
    [System.IO.File]::WriteAllBytes((Join-Path $base "$Name.uexp"), $UExp)
    return $ua
}
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function RowValue($m, [string]$Row) {
    $r = @($m.Rows | Where-Object { $_.Name -eq $Row })
    if (-not $r.Count) { return $null }
    return $r[0].Keys[0].Value
}

try {
    Case 'current layout: the first row is read, with its value' {
        $m = Parse-CurveTable -UAssetPath (New-Table 'c3' (New-UExp 'C' @(@('Row_First', 42.5), @('Row_Second', 7), @('Row_Third', -3.25))))
        Assert (-not $m.Error) "error: $($m.Error)"
        Assert ($m.RowCount -eq 3 -and $m.ExpectedRowCount -eq 3) "rows $($m.RowCount) of $($m.ExpectedRowCount)"
        Assert ($m.Rows[0].Name -eq 'Row_First') "first row read as $($m.Rows[0].Name)"
        Assert ((RowValue $m 'Row_First') -eq 42.5) "first row value $(RowValue $m 'Row_First')"
        Assert ((RowValue $m 'Row_Third') -eq -3.25) "last row value $(RowValue $m 'Row_Third')"
    }
    Case 'current layout: a one-row table is read' {
        $m = Parse-CurveTable -UAssetPath (New-Table 'c1' (New-UExp 'C' @(, @('Row_First', 5))))
        Assert (-not $m.Error -and $m.RowCount -eq 1 -and (RowValue $m 'Row_First') -eq 5) "rows $($m.RowCount), error $($m.Error)"
    }
    Case 'current layout with a GUID: the first row is read' {
        $m = Parse-CurveTable -UAssetPath (New-Table 'cg' (New-UExp 'C' @(@('Row_First', 11), @('Row_Second', 12)) 1))
        Assert ($m.RowCount -eq 2 -and (RowValue $m 'Row_First') -eq 11) "rows $($m.RowCount)"
    }
    Case 'a first row whose name has a large number suffix is read' {
        $m = Parse-CurveTable -UAssetPath (New-Table 'cn' (New-UExp 'C' @(@('Row_First', 9, 25), @('Row_Second', 8))))
        Assert ($m.RowCount -eq 2 -and $m.Rows[0].Name -eq 'Row_First_24') "first row read as $($m.Rows[0].Name)"
    }
    Case 'older layout (row count only) still reads every row' {
        $m = Parse-CurveTable -UAssetPath (New-Table 'a3' (New-UExp 'A' @(@('Row_First', 1.5), @('Row_Second', 2.5), @('Row_Third', 3.5))))
        Assert ($m.RowCount -eq 3 -and (RowValue $m 'Row_First') -eq 1.5) "rows $($m.RowCount), first $($m.Rows[0].Name)"
    }
    Case 'a setting on the first row is patched and only that value changes' {
        $ua = New-Table 'p3' (New-UExp 'C' @(@('Row_First', 42.5), @('Row_Second', 7), @('Row_Third', -3.25)))
        $ux = $ua -replace '\.uasset$', '.uexp'
        $before = [System.IO.File]::ReadAllBytes($ux)
        $m = Parse-CurveTable -UAssetPath $ua
        $out = Join-Path $base 'p3-patched.uexp'
        $r = Invoke-CurveTablePatch -Manifest $m -Config @{ overrides = @{ Row_First = 100 } } -UExpPath $ux -OutputPath $out
        Assert (-not $r.Error) "patch error: $($r.Error)"
        Assert ($r.ChangesApplied -eq 1) "changes applied: $($r.ChangesApplied)"
        $after = [System.IO.File]::ReadAllBytes($out)
        $off = $m.Rows[0].Keys[0].ValueOffset
        Assert ([BitConverter]::ToSingle($after, $off) -eq 100) "value at offset $off is $([BitConverter]::ToSingle($after, $off))"
        $diff = @(0..($before.Length - 1) | Where-Object { $before[$_] -ne $after[$_] })
        Assert ($diff.Count -ge 1 -and $diff.Count -le 4 -and ($diff | Where-Object { $_ -lt $off -or $_ -ge $off + 4 }).Count -eq 0) "bytes changed outside the value: $($diff -join ',')"
    }
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All curve table reader cases passed.'
exit 0
