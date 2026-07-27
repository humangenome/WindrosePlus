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

# Locate data. Source export data may live beside the Win64 process on some
# Wine/Docker layouts, but dashboard artifacts must stay in the root data dir.
$dashboardDataDir = Join-Path $GameDir "windrose_plus_data"
$dataDir = $dashboardDataDir
if (-not $OutputDir) {
    $OutputDir = Join-Path $dashboardDataDir "map_tiles"
}

$terrainJson = Join-Path $dataDir "terrain_v17.json"
if (-not (Test-Path -LiteralPath $terrainJson)) {
    $altDataDir = Join-Path $GameDir "R5\Binaries\Win64\windrose_plus_data"
    $terrainJson = Join-Path $altDataDir "terrain_v17.json"
    if (-not (Test-Path -LiteralPath $terrainJson)) {
        Write-Host "ERROR: terrain_v17.json not found" -ForegroundColor Red
        throw "terrain_v17.json not found"
    }
    $dataDir = $altDataDir
}

$hfDir = Join-Path $dataDir "heightmaps"
if (-not (Test-Path -LiteralPath $hfDir)) {
    Write-Host "ERROR: heightmaps/ directory not found" -ForegroundColor Red
    throw "heightmaps/ directory not found"
}

Write-Host "Loading terrain metadata..."
$meta = Get-Content $terrainJson -Raw | ConvertFrom-Json
$comps = $meta.components
$lands = $meta.landscapes
$withH = @($comps | Where-Object { $_.h -eq 1 })
Write-Host "Components with heights: $($withH.Count)"

if ($withH.Count -eq 0) {
    Write-Host "ERROR: No components with heightfield data" -ForegroundColor Red
    throw "No components with heightfield data"
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

# Map space (north-up): image right = world Y, image down = -world X.
$mapMinX = $wminy
$mapMinY = -$wmaxx

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

# Compile C# tile renderer and PNG writer for native speed. This avoids
# System.Drawing so tile generation works on Linux/Docker PowerShell too.
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;

public struct CompData {
    public double wx, wy, wx2, wy2;
    public int res;
    public double minZ, maxZ, rng;
    public byte[] data;
}

public static class TileRenderer {
    static byte[] oceanRGB = new byte[] { 20, 35, 65 };

    // Sea level is Z=0 in Windrose heightfield data (confirmed from terrain_v17.json)
    public static double SeaLevel = 0.0;

    public static void GetHeightColor(double h, byte[] buf) {
        if (h < SeaLevel) { buf[0] = oceanRGB[0]; buf[1] = oceanRGB[1]; buf[2] = oceanRGB[2]; return; }
        double ah = h - SeaLevel;  // adjusted height above sea level
        if (ah < 5) { buf[0] = 180; buf[1] = 170; buf[2] = 130; return; }  // beach
        double t;
        if (ah < 40) {
            t = ah / 40.0;
            buf[0] = (byte)(130 - t * 60); buf[1] = (byte)(145 - t * 20); buf[2] = (byte)(100 - t * 50);
            return;
        }
        if (ah < 120) {
            t = (ah - 40) / 80.0;
            buf[0] = (byte)(70 - t * 10); buf[1] = (byte)(125 - t * 15); buf[2] = (byte)(50 + t * 5);
            return;
        }
        if (ah < 300) {
            t = (ah - 120) / 180.0;
            buf[0] = (byte)(60 + t * 15); buf[1] = (byte)(110 - t * 10); buf[2] = (byte)(55 + t * 5);
            return;
        }
        if (ah < 600) {
            t = (ah - 300) / 300.0;
            buf[0] = (byte)(75 + t * 25); buf[1] = (byte)(100 - t * 5); buf[2] = (byte)(60 + t * 5);
            return;
        }
        if (ah < 1000) {
            t = (ah - 600) / 400.0;
            buf[0] = (byte)(100 + t * 20); buf[1] = (byte)(95 + t * 5); buf[2] = (byte)(65 + t * 10);
            return;
        }
        if (ah < 2000) {
            t = (ah - 1000) / 1000.0;
            buf[0] = (byte)(120 + t * 20); buf[1] = (byte)(100 + t * 15); buf[2] = (byte)(75 + t * 15);
            return;
        }
        buf[0] = 145; buf[1] = 120; buf[2] = 95;  // peak
    }

    public static byte[] RenderSolidTile(int tileSize, byte r, byte g, byte b) {
        byte[] pixels = new byte[tileSize * tileSize * 3];
        for (int i = 0; i < pixels.Length; i += 3) {
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b;
        }
        return pixels;
    }

    // Tiles are rendered in MAP space, which is world space turned a quarter
    // turn so the image reads north-up like the in-game chart:
    //     map x (image right) =  world Y  (east)
    //     map y (image down)  = -world X  (south)
    // The livemap CRS uses the same mapping, so terrain and every marker layer
    // move together.
    public static byte[] RenderTile(int tileSize, double tileMx, double tileMy,
                                     double tileWorldSize, CompData[] comps) {
        byte[] pixels = RenderSolidTile(tileSize, oceanRGB[0], oceanRGB[1], oceanRGB[2]);

        double pixelSize = tileWorldSize / tileSize;
        byte[] color = new byte[3];

        foreach (var c in comps) {
            // Component bounds expressed in map space
            double cmx1 = c.wy,   cmx2 = c.wy2;
            double cmy1 = -c.wx2, cmy2 = -c.wx;

            // Check overlap
            if (cmx2 <= tileMx || cmx1 >= tileMx + tileWorldSize) continue;
            if (cmy2 <= tileMy || cmy1 >= tileMy + tileWorldSize) continue;

            double compW = c.wx2 - c.wx;
            double compH = c.wy2 - c.wy;

            // Pixel range in tile that this component covers
            int px1 = Math.Max(0, (int)((cmx1 - tileMx) / tileWorldSize * tileSize));
            int py1 = Math.Max(0, (int)((cmy1 - tileMy) / tileWorldSize * tileSize));
            int px2 = Math.Min(tileSize, (int)Math.Ceiling((cmx2 - tileMx) / tileWorldSize * tileSize));
            int py2 = Math.Min(tileSize, (int)Math.Ceiling((cmy2 - tileMy) / tileWorldSize * tileSize));

            for (int py = py1; py < py2; py++) {
                double worldX = -(tileMy + (py + 0.5) * pixelSize);
                double fx = (worldX - c.wx) / compW;
                int hx = (int)(fx * c.res);
                if (hx < 0) hx = 0; if (hx >= c.res) hx = c.res - 1;

                for (int px = px1; px < px2; px++) {
                    double worldY = tileMx + (px + 0.5) * pixelSize;
                    double fy = (worldY - c.wy) / compH;
                    int hy = (int)(fy * c.res);
                    if (hy < 0) hy = 0; if (hy >= c.res) hy = c.res - 1;

                    int dataIdx = 4 + (hy * c.res + hx) * 2;
                    if (dataIdx + 1 >= c.data.Length) continue;
                    ushort raw = BitConverter.ToUInt16(c.data, dataIdx);
                    double worldH = c.minZ + raw * (c.rng / 65535.0);

                    GetHeightColor(worldH, color);
                    int pidx = (py * tileSize + px) * 3;
                    pixels[pidx] = color[0];
                    pixels[pidx + 1] = color[1];
                    pixels[pidx + 2] = color[2];
                }
            }
        }

        return pixels;
    }
}

public static class PngWriter {
    static readonly byte[] Signature = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
    static readonly uint[] CrcTable = BuildCrcTable();

    public static void SaveRgb(string path, int width, int height, byte[] rgb) {
        byte[] scanlines = new byte[(width * 3 + 1) * height];
        int src = 0, dst = 0;
        for (int y = 0; y < height; y++) {
            scanlines[dst++] = 0; // filter type: none
            Buffer.BlockCopy(rgb, src, scanlines, dst, width * 3);
            src += width * 3;
            dst += width * 3;
        }

        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None)) {
            fs.Write(Signature, 0, Signature.Length);

            byte[] ihdr = new byte[13];
            WriteUInt32BE(ihdr, 0, (uint)width);
            WriteUInt32BE(ihdr, 4, (uint)height);
            ihdr[8] = 8;  // bit depth
            ihdr[9] = 2;  // truecolor RGB
            ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
            WriteChunk(fs, "IHDR", ihdr);
            WriteChunk(fs, "IDAT", ZlibCompress(scanlines));
            WriteChunk(fs, "IEND", new byte[0]);
        }
    }

    static byte[] ZlibCompress(byte[] data) {
        using (var ms = new MemoryStream()) {
            ms.WriteByte(0x78);
            ms.WriteByte(0x9C);
            using (var ds = new DeflateStream(ms, CompressionLevel.Optimal, true)) {
                ds.Write(data, 0, data.Length);
            }
            uint adler = Adler32(data);
            WriteUInt32BE(ms, adler);
            return ms.ToArray();
        }
    }

    static uint Adler32(byte[] data) {
        const uint Mod = 65521;
        uint a = 1, b = 0;
        foreach (byte value in data) {
            a = (a + value) % Mod;
            b = (b + a) % Mod;
        }
        return (b << 16) | a;
    }

    static void WriteChunk(Stream stream, string type, byte[] data) {
        byte[] typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        WriteUInt32BE(stream, (uint)data.Length);
        stream.Write(typeBytes, 0, typeBytes.Length);
        stream.Write(data, 0, data.Length);

        uint crc = 0xFFFFFFFF;
        crc = UpdateCrc(crc, typeBytes);
        crc = UpdateCrc(crc, data);
        WriteUInt32BE(stream, crc ^ 0xFFFFFFFF);
    }

    static uint[] BuildCrcTable() {
        uint[] table = new uint[256];
        for (uint n = 0; n < table.Length; n++) {
            uint c = n;
            for (int k = 0; k < 8; k++) {
                c = ((c & 1) != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
            }
            table[n] = c;
        }
        return table;
    }

    static uint UpdateCrc(uint crc, byte[] data) {
        uint c = crc;
        foreach (byte b in data) {
            c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        }
        return c;
    }

    static void WriteUInt32BE(Stream stream, uint value) {
        byte[] buf = new byte[4];
        WriteUInt32BE(buf, 0, value);
        stream.Write(buf, 0, 4);
    }

    static void WriteUInt32BE(byte[] buf, int offset, uint value) {
        buf[offset] = (byte)(value >> 24);
        buf[offset + 1] = (byte)(value >> 16);
        buf[offset + 2] = (byte)(value >> 8);
        buf[offset + 3] = (byte)value;
    }
}
"@

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
            $tileMx = $mapMinX + $col * $tileWorldSize
            $tileMy = $mapMinY + $row * $tileWorldSize

            # Skip tiles with no overlapping land components (map space, see RenderTile)
            $hasOverlap = $false
            foreach ($ci in $compIndex) {
                if ($ci.wy2 -gt $tileMx -and $ci.wy -lt ($tileMx + $tileWorldSize) -and
                    (-$ci.wx) -gt $tileMy -and (-$ci.wx2) -lt ($tileMy + $tileWorldSize)) {
                    $hasOverlap = $true; break
                }
            }

            if (-not $hasOverlap) {
                # Pure ocean tile.
                $pixels = [TileRenderer]::RenderSolidTile($tileSize, 20, 35, 65)
                [PngWriter]::SaveRgb((Join-Path $zoomDir "${col}-${row}.png"), $tileSize, $tileSize, $pixels)
            } else {
                $pixels = [TileRenderer]::RenderTile($tileSize, $tileMx, $tileMy, $tileWorldSize, $csharpComps)
                [PngWriter]::SaveRgb((Join-Path $zoomDir "${col}-${row}.png"), $tileSize, $tileSize, $pixels)
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
    # Tells the map viewer how these tiles are laid out. Viewers fall back to
    # the old world-X-right / world-Y-down layout when this is absent, so a
    # server with tiles from an older build keeps terrain and markers aligned
    # until the tiles are regenerated.
    orientation = "north-up"
    total_components = $landComps.Count
    island_bounds = @{
        min_x = $ibMinX; min_y = $ibMinY
        max_x = $ibMaxX; max_y = $ibMaxY
    }
}
$coordsPath = Join-Path $dashboardDataDir "map_coords.json"
[System.IO.File]::WriteAllText($coordsPath, ($mapCoords | ConvertTo-Json -Depth 3))

Write-Host ""
Write-Host "Generated $totalTiles tiles in $OutputDir" -ForegroundColor Green
Write-Host "Map manifest: $coordsPath"
Write-Host "Total time: $([int]$sw.Elapsed.TotalSeconds) seconds"
