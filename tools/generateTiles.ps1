<#
.SYNOPSIS
    WindrosePlus Tile Generator — renders map tiles from exported heightfield data.
.DESCRIPTION
    Reads terrain_v17.json + binary heightfield files, renders Leaflet tiles
    at multiple zoom levels with per-tile sampling for peak quality at all zooms.
    Uses inline C# for fast pixel rendering.
.PARAMETER GameDir
    Path to the game server root directory containing windrose_plus_data/
.PARAMETER OutputDir
    Where to write tiles. Defaults to windrose_plus_data/map_tiles/
.PARAMETER MaxZoom
    Maximum zoom level (default: 6, produces 64x64=4096 tiles at max zoom)
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$GameDir,
    [string]$OutputDir,
    [int]$MaxZoom = 6
)

$ErrorActionPreference = "Stop"
$tileSize = 256
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Locate data
$dataDir = Join-Path $GameDir "windrose_plus_data"
if (-not $OutputDir) {
    $OutputDir = Join-Path $dataDir "map_tiles"
}

$terrainJson = Join-Path $dataDir "terrain_v17.json"
if (-not (Test-Path -LiteralPath $terrainJson)) {
    $altDataDir = Join-Path $GameDir "R5\Binaries\Win64\windrose_plus_data"
    $terrainJson = Join-Path $altDataDir "terrain_v17.json"
    if (-not (Test-Path -LiteralPath $terrainJson)) {
        Write-Host "ERROR: terrain_v17.json not found" -ForegroundColor Red
        exit 1
    }
    $dataDir = $altDataDir
}

$hfDir = Join-Path $dataDir "heightmaps"
if (-not (Test-Path -LiteralPath $hfDir)) {
    Write-Host "ERROR: heightmaps/ directory not found" -ForegroundColor Red
    exit 1
}

Write-Host "Loading terrain metadata..."
$meta = Get-Content $terrainJson -Raw | ConvertFrom-Json
$comps = $meta.components
$lands = $meta.landscapes
$withH = @($comps | Where-Object { $_.h -eq 1 })
Write-Host "Components with heights: $($withH.Count)"

if ($withH.Count -eq 0) {
    Write-Host "ERROR: No components with heightfield data" -ForegroundColor Red
    exit 1
}

# Calculate landscape steps
$byLand = @{}
foreach ($c in $comps) {
    $li = [string]$c.l
    if (-not $byLand.ContainsKey($li)) { $byLand[$li] = @() }
    $byLand[$li] += $c
}
$landSteps = @{}
foreach ($li in $byLand.Keys) {
    $sxs = @($byLand[$li] | ForEach-Object { $_.sx } | Sort-Object -Unique)
    if ($sxs.Count -gt 1) { $landSteps[$li] = $sxs[1] - $sxs[0] }
    else { $landSteps[$li] = 255 }
}

# Calculate world bounds
$allWx = @(); $allWy = @()
foreach ($c in $withH) {
    $li = [string]$c.l
    $land = $lands[$c.l]
    $scale = if ($land.sx -gt 0) { $land.sx } else { 100 }
    $step = if ($landSteps.ContainsKey($li)) { $landSteps[$li] } else { 255 }
    $compSize = $step * $scale
    $allWx += $c.wx; $allWx += ($c.wx + $compSize)
    $allWy += $c.wy; $allWy += ($c.wy + $compSize)
}
$wminx = ($allWx | Measure-Object -Minimum).Minimum
$wmaxx = ($allWx | Measure-Object -Maximum).Maximum
$wminy = ($allWy | Measure-Object -Minimum).Minimum
$wmaxy = ($allWy | Measure-Object -Maximum).Maximum

# Make square (required for Leaflet CRS alignment)
$side = [Math]::Max($wmaxx - $wminx, $wmaxy - $wminy)
$cx = ($wminx + $wmaxx) / 2; $cy = ($wminy + $wmaxy) / 2
$wminx = $cx - $side / 2; $wmaxx = $cx + $side / 2
$wminy = $cy - $side / 2; $wmaxy = $cy + $side / 2
$worldW = $wmaxx - $wminx; $worldH = $wmaxy - $wminy

Write-Host "World bounds: ($wminx, $wminy) to ($wmaxx, $wmaxy)"

# Preload all heightfield data into memory
Write-Host "Loading heightfield data into memory..."
$hfData = @{}
$loadedCount = 0
foreach ($c in $withH) {
    $hfPath = Join-Path $hfDir $c.f
    if (Test-Path -LiteralPath $hfPath) {
        $hfData[$c.f] = [System.IO.File]::ReadAllBytes($hfPath)
        $loadedCount++
    }
}
Write-Host "Loaded $loadedCount heightfield files"

# Detect ocean floor components: if the highest point in the entire component
# is below 100 world units, it's ocean floor (possibly with minor heightfield noise).
# Real coastal terrain has maxZ in the hundreds/thousands.
# Sea level in the Windrose heightfield data is Z=0 (confirmed from terrain_v17.json:
# 463 ocean components clamped to maxZ≈0, real beaches start at minZ=0 with maxZ=1475+)
$seaLevelThreshold = 100.0  # world units - components with maxZ below this are ocean floor
foreach ($c in $withH) {
    $maxZ = if ($null -ne $c.maxZ) { [double]$c.maxZ } else { 1 }
    $c | Add-Member -NotePropertyName "isOcean" -NotePropertyValue ($maxZ -lt $seaLevelThreshold) -Force
}

$oceanComps = @($withH | Where-Object { $_.isOcean })
$landComps = @($withH | Where-Object { -not $_.isOcean })
Write-Host "Land components: $($landComps.Count), Ocean floor: $($oceanComps.Count)"

# Build component spatial index for fast tile lookups
$compIndex = @()
foreach ($c in $landComps) {
    $li = [string]$c.l
    $land = $lands[$c.l]
    $scale = if ($land.sx -gt 0) { $land.sx } else { 100 }
    $step = if ($landSteps.ContainsKey($li)) { $landSteps[$li] } else { 255 }
    $compW = $step * $scale
    if (-not $hfData.ContainsKey($c.f)) { continue }
    $bytes = $hfData[$c.f]
    if ($bytes.Length -lt 8) { continue }
    $res = [BitConverter]::ToInt32($bytes, 0)
    if ($bytes.Length -lt (4 + $res * $res * 2)) { continue }
    $minZ = if ($null -ne $c.minZ) { [double]$c.minZ } else { 0 }
    $maxZ = if ($null -ne $c.maxZ) { [double]$c.maxZ } else { 1 }
    $rng = $maxZ - $minZ
    if ($rng -lt 1) { continue }

    $compIndex += [PSCustomObject]@{
        wx = [double]$c.wx; wy = [double]$c.wy
        wx2 = [double]$c.wx + $compW; wy2 = [double]$c.wy + $compW
        res = $res; minZ = $minZ; maxZ = $maxZ; rng = $rng
        data = $bytes
    }
}
Write-Host "Indexed $($compIndex.Count) renderable components"

# Compile C# tile renderer for native speed
Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public struct CompData {
    public double wx, wy, wx2, wy2;
    public int res;
    public double minZ, maxZ, rng;
    public byte[] data;
}

public static class TileRenderer {
    static byte[] oceanBGR = new byte[] { 65, 35, 20 };  // BGR

    // Sea level is Z=0 in Windrose heightfield data (confirmed from terrain_v17.json)
    public static double SeaLevel = 0.0;

    public static void GetHeightColor(double h, byte[] buf) {
        if (h < SeaLevel) { buf[0] = oceanBGR[0]; buf[1] = oceanBGR[1]; buf[2] = oceanBGR[2]; return; }
        double ah = h - SeaLevel;  // adjusted height above sea level
        if (ah < 5) { buf[0] = 130; buf[1] = 170; buf[2] = 180; return; }  // beach
        double t;
        if (ah < 40) {
            t = ah / 40.0;
            buf[0] = (byte)(100 - t * 50); buf[1] = (byte)(145 - t * 20); buf[2] = (byte)(130 - t * 60);
            return;
        }
        if (ah < 120) {
            t = (ah - 40) / 80.0;
            buf[0] = (byte)(50 + t * 5); buf[1] = (byte)(125 - t * 15); buf[2] = (byte)(70 - t * 10);
            return;
        }
        if (ah < 300) {
            t = (ah - 120) / 180.0;
            buf[0] = (byte)(55 + t * 5); buf[1] = (byte)(110 - t * 10); buf[2] = (byte)(60 + t * 15);
            return;
        }
        if (ah < 600) {
            t = (ah - 300) / 300.0;
            buf[0] = (byte)(60 + t * 5); buf[1] = (byte)(100 - t * 5); buf[2] = (byte)(75 + t * 25);
            return;
        }
        if (ah < 1000) {
            t = (ah - 600) / 400.0;
            buf[0] = (byte)(65 + t * 10); buf[1] = (byte)(95 + t * 5); buf[2] = (byte)(100 + t * 20);
            return;
        }
        if (ah < 2000) {
            t = (ah - 1000) / 1000.0;
            buf[0] = (byte)(75 + t * 15); buf[1] = (byte)(100 + t * 15); buf[2] = (byte)(120 + t * 20);
            return;
        }
        buf[0] = 95; buf[1] = 120; buf[2] = 145;  // peak
    }

    public static Bitmap RenderTile(int tileSize, double tileWx, double tileWy,
                                     double tileWorldSize, CompData[] comps) {
        var bmp = new Bitmap(tileSize, tileSize, PixelFormat.Format24bppRgb);
        var rect = new Rectangle(0, 0, tileSize, tileSize);
        var bmpData = bmp.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
        int stride = bmpData.Stride;
        byte[] pixels = new byte[stride * tileSize];

        // Fill with ocean
        for (int y = 0; y < tileSize; y++) {
            for (int x = 0; x < tileSize; x++) {
                int idx = y * stride + x * 3;
                pixels[idx] = oceanBGR[0];
                pixels[idx + 1] = oceanBGR[1];
                pixels[idx + 2] = oceanBGR[2];
            }
        }

        double pixelSize = tileWorldSize / tileSize;
        byte[] color = new byte[3];

        foreach (var c in comps) {
            // Check overlap
            if (c.wx2 <= tileWx || c.wx >= tileWx + tileWorldSize) continue;
            if (c.wy2 <= tileWy || c.wy >= tileWy + tileWorldSize) continue;

            double compW = c.wx2 - c.wx;
            double compH = c.wy2 - c.wy;

            // Pixel range in tile that this component covers
            int px1 = Math.Max(0, (int)((c.wx - tileWx) / tileWorldSize * tileSize));
            int py1 = Math.Max(0, (int)((c.wy - tileWy) / tileWorldSize * tileSize));
            int px2 = Math.Min(tileSize, (int)Math.Ceiling((c.wx2 - tileWx) / tileWorldSize * tileSize));
            int py2 = Math.Min(tileSize, (int)Math.Ceiling((c.wy2 - tileWy) / tileWorldSize * tileSize));

            for (int py = py1; py < py2; py++) {
                double worldY = tileWy + (py + 0.5) * pixelSize;
                double fy = (worldY - c.wy) / compH;
                int hy = (int)(fy * c.res);
                if (hy < 0) hy = 0; if (hy >= c.res) hy = c.res - 1;

                for (int px = px1; px < px2; px++) {
                    double worldX = tileWx + (px + 0.5) * pixelSize;
                    double fx = (worldX - c.wx) / compW;
                    int hx = (int)(fx * c.res);
                    if (hx < 0) hx = 0; if (hx >= c.res) hx = c.res - 1;

                    int dataIdx = 4 + (hy * c.res + hx) * 2;
                    if (dataIdx + 1 >= c.data.Length) continue;
                    ushort raw = BitConverter.ToUInt16(c.data, dataIdx);
                    double worldH = c.minZ + raw * (c.rng / 65535.0);

                    GetHeightColor(worldH, color);
                    int pidx = py * stride + px * 3;
                    pixels[pidx] = color[0];
                    pixels[pidx + 1] = color[1];
                    pixels[pidx + 2] = color[2];
                }
            }
        }

        Marshal.Copy(pixels, 0, bmpData.Scan0, pixels.Length);
        bmp.UnlockBits(bmpData);
        return bmp;
    }
}
"@ -ReferencedAssemblies System.Drawing

# Build CompData array for C#
Write-Host "Building render data..."
$csharpComps = New-Object 'CompData[]' $compIndex.Count
for ($i = 0; $i -lt $compIndex.Count; $i++) {
    $ci = $compIndex[$i]
    $cd = New-Object CompData
    $cd.wx = $ci.wx; $cd.wy = $ci.wy
    $cd.wx2 = $ci.wx2; $cd.wy2 = $ci.wy2
    $cd.res = $ci.res; $cd.minZ = $ci.minZ; $cd.maxZ = $ci.maxZ; $cd.rng = $ci.rng
    $cd.data = $ci.data
    $csharpComps[$i] = $cd
}

# Clean output dir
if (Test-Path -LiteralPath $OutputDir) { Remove-Item $OutputDir -Recurse -Force }

# Generate tiles at each zoom level
$totalTiles = 0
for ($zoom = 0; $zoom -le $MaxZoom; $zoom++) {
    $tps = [int][Math]::Pow(2, $zoom)
    $tileWorldSize = $worldW / $tps
    $zoomDir = Join-Path $OutputDir $zoom
    New-Item -ItemType Directory -Path $zoomDir -Force | Out-Null

    $zoomTiles = 0
    for ($row = 0; $row -lt $tps; $row++) {
        for ($col = 0; $col -lt $tps; $col++) {
            $tileWx = $wminx + $col * $tileWorldSize
            $tileWy = $wminy + $row * $tileWorldSize

            # Skip tiles with no overlapping land components
            $hasOverlap = $false
            foreach ($ci in $compIndex) {
                if ($ci.wx2 -gt $tileWx -and $ci.wx -lt ($tileWx + $tileWorldSize) -and
                    $ci.wy2 -gt $tileWy -and $ci.wy -lt ($tileWy + $tileWorldSize)) {
                    $hasOverlap = $true; break
                }
            }

            if (-not $hasOverlap) {
                # Pure ocean tile — write a small ocean-only tile
                $oceanBmp = New-Object System.Drawing.Bitmap($tileSize, $tileSize)
                $gfx = [System.Drawing.Graphics]::FromImage($oceanBmp)
                $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 35, 65))
                $gfx.FillRectangle($brush, 0, 0, $tileSize, $tileSize)
                $gfx.Dispose(); $brush.Dispose()
                $oceanBmp.Save((Join-Path $zoomDir "${col}-${row}.png"), [System.Drawing.Imaging.ImageFormat]::Png)
                $oceanBmp.Dispose()
            } else {
                $tile = [TileRenderer]::RenderTile($tileSize, $tileWx, $tileWy, $tileWorldSize, $csharpComps)
                $tile.Save((Join-Path $zoomDir "${col}-${row}.png"), [System.Drawing.Imaging.ImageFormat]::Png)
                $tile.Dispose()
            }
            $zoomTiles++
        }
    }
    $totalTiles += $zoomTiles
    Write-Host "  Zoom ${zoom}: ${tps}x${tps} = $zoomTiles tiles ($([int]$sw.Elapsed.TotalSeconds)s)"
}

# Calculate island bounds (only components with significant terrain)
$aboveSeaComps = @($landComps | Where-Object { $_.maxZ -gt 100 })
if ($aboveSeaComps.Count -eq 0) { $aboveSeaComps = $landComps }
$ibMinX = ($aboveSeaComps | ForEach-Object { $_.wx } | Measure-Object -Minimum).Minimum
$ibMinY = ($aboveSeaComps | ForEach-Object { $_.wy } | Measure-Object -Minimum).Minimum
$ibMaxX = ($aboveSeaComps | ForEach-Object {
    $li = [string]$_.l; $land = $lands[$_.l]
    $scale = if ($land.sx -gt 0) { $land.sx } else { 100 }
    $step = if ($landSteps.ContainsKey($li)) { $landSteps[$li] } else { 255 }
    $_.wx + $step * $scale
} | Measure-Object -Maximum).Maximum
$ibMaxY = ($aboveSeaComps | ForEach-Object {
    $li = [string]$_.l; $land = $lands[$_.l]
    $scale = if ($land.sx -gt 0) { $land.sx } else { 100 }
    $step = if ($landSteps.ContainsKey($li)) { $landSteps[$li] } else { 255 }
    $_.wy + $step * $scale
} | Measure-Object -Maximum).Maximum

# Write map_coords.json
$mapCoords = @{
    world_min_x = $wminx; world_min_y = $wminy
    world_max_x = $wmaxx; world_max_y = $wmaxy
    tile_size = $tileSize; max_zoom = $MaxZoom
    total_components = $landComps.Count
    island_bounds = @{
        min_x = $ibMinX; min_y = $ibMinY
        max_x = $ibMaxX; max_y = $ibMaxY
    }
}
$coordsPath = Join-Path $dataDir "map_coords.json"
[System.IO.File]::WriteAllText($coordsPath, ($mapCoords | ConvertTo-Json -Depth 3))

Write-Host ""
Write-Host "Generated $totalTiles tiles in $OutputDir" -ForegroundColor Green
Write-Host "Map manifest: $coordsPath"
Write-Host "Total time: $([int]$sw.Elapsed.TotalSeconds) seconds"
