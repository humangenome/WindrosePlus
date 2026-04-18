# Windrose+ Installer
# Run this from inside your Windrose server folder after extracting the release zip.

param(
    [string]$GameDir = ""
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  Windrose+ Installer" -ForegroundColor Cyan
Write-Host ""

# Use provided path or current directory
if ($GameDir) {
    $gameDir = $GameDir
} else {
    $gameDir = $PSScriptRoot
    if (-not $gameDir) { $gameDir = $PWD.Path }
}

$gameDir = (Resolve-Path $gameDir).Path

# Verify this is a Windrose server folder (check for R5/ directory)
$r5Dir = Join-Path $gameDir "R5"
if (-not (Test-Path -LiteralPath $r5Dir)) {
    Write-Host "  ERROR: This doesn't look like a Windrose server folder." -ForegroundColor Red
    Write-Host "  Expected to find R5\ directory in: $gameDir" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Extract the Windrose+ zip into your Windrose Dedicated Server folder and run this again." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Server folder: $gameDir" -ForegroundColor Green
Write-Host ""

$scriptDir = $gameDir
$win64Dir = Join-Path $gameDir "R5\Binaries\Win64"
$ue4ssDir = Join-Path $win64Dir "ue4ss"
$modsDir = Join-Path $ue4ssDir "Mods"

# Validate R5\Binaries\Win64 exists
if (-not (Test-Path -LiteralPath $win64Dir)) {
    Write-Host "  ERROR: R5\Binaries\Win64 not found." -ForegroundColor Red
    Write-Host "  Make sure the Windrose Dedicated Server is fully installed." -ForegroundColor Yellow
    exit 1
}

# Step 1: Install UE4SS
Write-Host "  [1/3] Installing UE4SS mod loader..." -NoNewline
$proxyDll = Join-Path $win64Dir "dwmapi.dll"
$ue4ssDll = Join-Path $ue4ssDir "UE4SS.dll"

if ((Test-Path -LiteralPath $proxyDll) -and (Test-Path -LiteralPath $ue4ssDll)) {
    Write-Host " already installed" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "    Downloading UE4SS..." -ForegroundColor DarkGray

    $ue4ssZipPath = Join-Path $env:TEMP "ue4ss_download.zip"
    $ue4ssExtractDir = Join-Path $env:TEMP "ue4ss_extract"

    try {
        # Find the latest UE4SS experimental release zip (filename changes each build)
        Write-Host "    Finding latest UE4SS release..." -ForegroundColor DarkGray
        $releaseJson = Invoke-WebRequest -Uri "https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/tags/experimental-latest" -UseBasicParsing | ConvertFrom-Json
        $ue4ssAsset = $releaseJson.assets | Where-Object { $_.name -match "^UE4SS_v" -and $_.name -notmatch "^z" -and $_.name -notmatch "DEV" } | Select-Object -First 1
        if (-not $ue4ssAsset) {
            Write-Host "    ERROR: Could not find UE4SS download." -ForegroundColor Red
            exit 1
        }
        $ue4ssZipUrl = $ue4ssAsset.browser_download_url
        Write-Host "    Downloading $($ue4ssAsset.name)..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $ue4ssZipUrl -OutFile $ue4ssZipPath -UseBasicParsing

        if (Test-Path -LiteralPath $ue4ssExtractDir) { Remove-Item $ue4ssExtractDir -Recurse -Force }
        Expand-Archive -Path $ue4ssZipPath -DestinationPath $ue4ssExtractDir -Force

        $extractedProxy = Join-Path $ue4ssExtractDir "dwmapi.dll"
        if (-not (Test-Path -LiteralPath $extractedProxy)) {
            Write-Host "    ERROR: dwmapi.dll not found in UE4SS download." -ForegroundColor Red
            exit 1
        }

        Copy-Item $extractedProxy $win64Dir -Force

        $extractedUe4ss = Join-Path $ue4ssExtractDir "ue4ss"
        if (Test-Path -LiteralPath $extractedUe4ss) {
            if (-not (Test-Path -LiteralPath $ue4ssDir)) { New-Item -ItemType Directory -Path $ue4ssDir -Force | Out-Null }
            Copy-Item "$extractedUe4ss\*" $ue4ssDir -Recurse -Force
        }

        if (-not (Test-Path -LiteralPath $modsDir)) { New-Item -ItemType Directory -Path $modsDir -Force | Out-Null }

        try { Remove-Item $ue4ssZipPath -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item $ue4ssExtractDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}

        Write-Host "    Done." -ForegroundColor Green
    } catch {
        Write-Host "    ERROR: Failed to download UE4SS." -ForegroundColor Red
        Write-Host "    Download manually from: https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest" -ForegroundColor Yellow
        exit 1
    }
}

# Copy UE4SS-settings.ini
$settingsSource = Join-Path $scriptDir "UE4SS-settings.ini"
if (Test-Path -LiteralPath $settingsSource) {
    try { Copy-Item $settingsSource (Join-Path $ue4ssDir "UE4SS-settings.ini") -Force } catch {}
}

# Step 2: Install Windrose+ mod
Write-Host "  [2/3] Installing Windrose+ mod..." -NoNewline
$modSource = Join-Path $scriptDir "WindrosePlus"
$modDest = Join-Path $modsDir "WindrosePlus"

if (-not (Test-Path -LiteralPath $modsDir)) { New-Item -ItemType Directory -Path $modsDir -Force | Out-Null }

if (Test-Path -LiteralPath $modSource) {
    try {
        if (-not (Test-Path -LiteralPath $modDest)) {
            Copy-Item $modSource $modDest -Recurse -Force
        } else {
            # Reinstall: overwrite Scripts/ but preserve user Mods/
            $scriptsDst = Join-Path $modDest "Scripts"
            if (Test-Path -LiteralPath $scriptsDst) { Remove-Item $scriptsDst -Recurse -Force }
            Copy-Item (Join-Path $modSource "Scripts") $scriptsDst -Recurse -Force

            Get-ChildItem $modSource -File | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $modDest $_.Name) -Force
            }
        }
        # Install HeightmapExporter if included
        $hmeSrc = Join-Path $scriptDir "cpp-mods\HeightmapExporter\HeightmapExporter.dll"
        if (Test-Path -LiteralPath $hmeSrc) {
            $hmeDest = Join-Path $modsDir "HeightmapExporter\dlls"
            if (-not (Test-Path -LiteralPath $hmeDest)) { New-Item -ItemType Directory -Path $hmeDest -Force | Out-Null }
            Copy-Item $hmeSrc (Join-Path $hmeDest "main.dll") -Force
            $hmeEnabled = Join-Path $modsDir "HeightmapExporter\enabled.txt"
            if (-not (Test-Path -LiteralPath $hmeEnabled)) { Set-Content $hmeEnabled "1" }
        }

        Write-Host " done" -ForegroundColor Green
    } catch {
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host " ERROR: WindrosePlus folder not found" -ForegroundColor Red
    exit 1
}

# Add to mods.txt
$modsTxt = Join-Path $modsDir "mods.txt"
if (Test-Path -LiteralPath $modsTxt) {
    $content = Get-Content $modsTxt -Raw
    if ($content -notmatch "WindrosePlus") {
        Add-Content $modsTxt "`nWindrosePlus : 1`n"
    }
} else {
    Set-Content $modsTxt "WindrosePlus : 1`n"
}

# Step 3: Set up dashboard
Write-Host "  [3/3] Setting up dashboard..." -NoNewline
$wpDir = Join-Path $gameDir "windrose_plus"
if (-not (Test-Path -LiteralPath $wpDir)) { New-Item -ItemType Directory -Path $wpDir -Force | Out-Null }

try {
    foreach ($folder in @("server", "tools", "docs")) {
        $src = Join-Path $scriptDir $folder
        $dst = Join-Path $wpDir $folder
        if (Test-Path -LiteralPath $src) {
            if (Test-Path -LiteralPath $dst) { Remove-Item $dst -Recurse -Force }
            Copy-Item $src $dst -Recurse -Force
        }
    }

    # Config: only copy .default.ini files, preserve user overrides
    $configSrc = Join-Path $scriptDir "config"
    $configDst = Join-Path $wpDir "config"
    if (Test-Path -LiteralPath $configSrc) {
        if (-not (Test-Path -LiteralPath $configDst)) { New-Item -ItemType Directory -Path $configDst -Force | Out-Null }
        Get-ChildItem $configSrc -Filter "*.default.ini" | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $configDst $_.Name) -Force
        }
    }

    # Create dashboard launcher
    $dashBat = Join-Path $wpDir "start_dashboard.bat"
    Set-Content $dashBat "@echo off`npowershell -ExecutionPolicy Bypass -File `"%~dp0server\windrose_plus_server.ps1`" -GameDir `"$gameDir`" %*"

    Write-Host " done" -ForegroundColor Green
} catch {
    Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Step 4: verify bundled build tools present (used by the wrapper's PAK rebuild step)
$binDir = Join-Path $wpDir "tools\bin"
$missingTools = @()
foreach ($tool in @("repak.exe", "retoc.exe")) {
    if (-not (Test-Path -LiteralPath (Join-Path $binDir $tool))) { $missingTools += $tool }
}
if ($missingTools.Count -gt 0) {
    Write-Host ""
    Write-Host "  WARNING: Bundled build tools missing: $($missingTools -join ', ')" -ForegroundColor Yellow
    Write-Host "           Re-download WindrosePlus.zip and extract it fully." -ForegroundColor Yellow
}

# Step 5: write StartWindrosePlusServer.bat wrapper to the game root
$wrapperPath = Join-Path $gameDir "StartWindrosePlusServer.bat"
$wrapperBody = @'
@echo off
setlocal

set "GAMEDIR=%~dp0"
if "%GAMEDIR:~-1%"=="\" set "GAMEDIR=%GAMEDIR:~0,-1%"

set "WP_BUILD=%GAMEDIR%\windrose_plus\tools\WindrosePlus-BuildPak.ps1"

if not exist "%WP_BUILD%" (
    echo [WindrosePlus] Installer not complete. Run install.ps1 first.
    if not "%WP_NOPAUSE%"=="1" pause
    exit /b 1
)

echo [WindrosePlus] Checking config overrides...
where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
      -File "%WP_BUILD%" ^
      -ServerDir "%GAMEDIR%" ^
      -RemoveStalePak
) else (
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
      -File "%WP_BUILD%" ^
      -ServerDir "%GAMEDIR%" ^
      -RemoveStalePak
)
set "BUILD_EXIT=%ERRORLEVEL%"

if not "%BUILD_EXIT%"=="0" (
    echo.
    echo [WindrosePlus] Config build failed (exit %BUILD_EXIT%^).
    echo Not launching server. Fix the error above and try again.
    if not "%WP_NOPAUSE%"=="1" pause
    exit /b %BUILD_EXIT%
)

echo.
echo [WindrosePlus] Starting Windrose server...
pushd "%GAMEDIR%"
"%GAMEDIR%\WindroseServer.exe" %*
set "SERVER_EXIT=%ERRORLEVEL%"
popd

endlocal & exit /b %SERVER_EXIT%
'@
try {
    [System.IO.File]::WriteAllText($wrapperPath, $wrapperBody, [System.Text.Encoding]::ASCII)
} catch {
    Write-Host "  WARNING: could not write wrapper batch: $_" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Windrose+ installed." -ForegroundColor Green
Write-Host ""
Write-Host "  Start server:" -ForegroundColor Cyan
Write-Host "    StartWindrosePlusServer.bat   (always use this — it rebuilds the override PAK when config changes)"
Write-Host ""
Write-Host "  Start dashboard:" -ForegroundColor Cyan
Write-Host "    windrose_plus\start_dashboard.bat"
Write-Host ""
Write-Host "  Config:" -ForegroundColor Cyan
Write-Host "    windrose_plus.json  (multipliers, RCON, admin — created on first server start)"
Write-Host "    windrose_plus.ini   (advanced overrides — optional, copy from windrose_plus\config\windrose_plus.default.ini)"
Write-Host ""
