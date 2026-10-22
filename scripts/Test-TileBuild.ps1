# Tests tools/generateTiles.ps1 on a small made-up terrain (two land pieces, one
# ocean piece): the tile set, the manifest, the shared ocean tile, and that the old
# tiles stay in place until a new set is complete.
# Windows (the swap test relies on Windows file locking).
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-TileBuild.ps1
#      pwsh -File scripts/Test-TileBuild.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $root 'tools\generateTiles.ps1'
$exe = (Get-Process -Id $PID).Path

$failed = 0
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert($Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

$game = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-tile-test-" + [guid]::NewGuid().ToString('N'))
$data = Join-Path $game 'windrose_plus_data'
$hf = Join-Path $data 'heightmaps'
New-Item -ItemType Directory -Path $hf -Force | Out-Null

function Write-Heightfield([string]$Path, [int]$Res, [scriptblock]$Height) {
    $bytes = New-Object byte[] (4 + $Res * $Res * 2)
    [BitConverter]::GetBytes([int]$Res).CopyTo($bytes, 0)
    for ($y = 0; $y -lt $Res; $y++) {
        for ($x = 0; $x -lt $Res; $x++) {
            $v = [uint16](& $Height $x $y)
            [BitConverter]::GetBytes($v).CopyTo($bytes, 4 + ($y * $Res + $x) * 2)
        }
    }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}
Write-Heightfield (Join-Path $hf 'a.bin') 16 { param($x, $y) 32768 + $x * 1000 + $y * 500 }
Write-Heightfield (Join-Path $hf 'b.bin') 16 { param($x, $y) 40000 - $x * 800 }
Write-Heightfield (Join-Path $hf 'o.bin') 16 { param($x, $y) 0 }
$terrain = '{"landscapes":[{"sx":100}],"components":[' +
    '{"l":0,"sx":0,"wx":0,"wy":0,"h":1,"f":"a.bin","minZ":-200,"maxZ":3000},' +
    '{"l":0,"sx":255,"wx":25500,"wy":0,"h":1,"f":"b.bin","minZ":-100,"maxZ":1500},' +
    '{"l":0,"sx":0,"wx":0,"wy":25500,"h":1,"f":"o.bin","minZ":-500,"maxZ":0}]}'
[System.IO.File]::WriteAllText((Join-Path $data 'terrain_v17.json'), $terrain)

$tiles = Join-Path $data 'map_tiles'
function Invoke-Generator {
    # Windows PowerShell 5.1 turns a child's stderr into error records; do not stop on them.
    $ErrorActionPreference = 'Continue'
    $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $generator -GameDir $game -MaxZoom 3 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $out }
}
function Get-Coords { return ([System.IO.File]::ReadAllText((Join-Path $data 'map_coords.json')) | ConvertFrom-Json) }

try {
    $first = Invoke-Generator
    Case 'a build writes every tile of zoom 0-3 (85) and nothing else' {
        Assert ($first.Code -eq 0) "exit $($first.Code): $($first.Output)"
        $n = @(Get-ChildItem -LiteralPath $tiles -Recurse -File).Count
        Assert ($n -eq 85) "$n tiles"
        Assert (-not (Test-Path -LiteralPath "$tiles.building") -and -not (Test-Path -LiteralPath "$tiles.old")) 'a build folder was left behind'
    }
    Case 'the manifest says "game" and carries a tile set id' {
        $c = Get-Coords
        Assert ($c.orientation -eq 'game') "orientation $($c.orientation)"
        Assert ($c.tileset_id -match '^\d{8}T\d{6}Z$') "tileset_id '$($c.tileset_id)'"
        Assert ($c.max_zoom -eq 3) "max_zoom $($c.max_zoom)"
    }
    Case 'ocean tiles are one picture, land tiles are drawn' {
        $hashes = @(Get-ChildItem -LiteralPath (Join-Path $tiles '3') -File | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
        $groups = @($hashes | Group-Object | Sort-Object Count -Descending)
        Assert ($groups[0].Count -ge 32) "the most common zoom-3 tile appears $($groups[0].Count) times"
        Assert ($groups.Count -ge 2) 'no land tile at zoom 3'
    }

    $idBefore = (Get-Coords).tileset_id
    Start-Sleep -Seconds 1
    Case 'while a viewer holds a tile open, the swap fails and the old tiles stay' {
        $held = [System.IO.File]::Open((Join-Path $tiles '0\0-0.png'), 'Open', 'Read', 'Read')
        try { $r = Invoke-Generator } finally { $held.Dispose() }
        Assert ($r.Code -ne 0) 'the build reported success'
        Assert ($r.Output -match 'Could not rename') "output: $($r.Output)"
        $n = @(Get-ChildItem -LiteralPath $tiles -Recurse -File).Count
        Assert ($n -eq 85) "$n tiles left in place"
        Assert ((Get-Coords).tileset_id -eq $idBefore) 'the manifest changed'
    }
    Case 'the next build cleans up and swaps in a new set' {
        $r = Invoke-Generator
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Output)"
        Assert (-not (Test-Path -LiteralPath "$tiles.building") -and -not (Test-Path -LiteralPath "$tiles.old")) 'a build folder was left behind'
        Assert (@(Get-ChildItem -LiteralPath $tiles -Recurse -File).Count -eq 85) 'wrong tile count'
        Assert ((Get-Coords).tileset_id -ne $idBefore) 'the tile set id did not change'
    }
} finally {
    try { Remove-Item -LiteralPath $game -Recurse -Force } catch {}
}

if ($failed) { Write-Host "$failed case(s) failed"; exit 1 }
Write-Host 'All tile build cases passed.'
