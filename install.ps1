# Windrose+ Installer
# Run this from inside your Windrose server folder after extracting the release zip.

param(
    [string]$GameDir = "",
    # Keep whatever UE4SS build is already installed instead of the tested one.
    [switch]$KeepCurrentUE4SS
)

$ErrorActionPreference = "Stop"

function ConvertTo-WindroseBool {
    param(
        $Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @("1", "true", "yes", "on", "enabled")) { return $true }
    if ($text -in @("0", "false", "no", "off", "disabled")) { return $false }
    return $Default
}

function Clamp-WindroseInt {
    param(
        [int]$Value,
        [int]$Min,
        [int]$Max
    )

    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

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

$gameDir = (Resolve-Path -LiteralPath $gameDir).Path

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
# Windrose+ is tested against one UE4SS build. UE4SS's "experimental-latest"
# tag is rebuilt every few days, so installing whatever it points at gives each
# server a different, untested loader. Download the pinned build and check its
# hash before using it.
$ue4ssPinName = "UE4SS_v3.0.1-944-g0196ef29.zip"
$ue4ssPinUrl = "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/$ue4ssPinName"
$ue4ssPinZipSha256 = "B7BE182458695A95D5D862D0A5F279E23FA5EF5B93566648E181191958EA45BD"
$ue4ssPinDllSha256 = "DF9E6E9A2280972B1C28CE590700FEACC752B447204F8BAADEB95F5776957055"

Write-Host "  [1/3] Installing UE4SS mod loader..." -NoNewline
$proxyDll = Join-Path $win64Dir "dwmapi.dll"
$ue4ssDll = Join-Path $ue4ssDir "UE4SS.dll"

$ue4ssPresent = (Test-Path -LiteralPath $proxyDll) -and (Test-Path -LiteralPath $ue4ssDll)
$ue4ssOnPin = $false
if ($ue4ssPresent) {
    try { $ue4ssOnPin = ((Get-FileHash -LiteralPath $ue4ssDll -Algorithm SHA256).Hash -eq $ue4ssPinDllSha256) } catch {}
}

if ($ue4ssPresent -and ($ue4ssOnPin -or $KeepCurrentUE4SS)) {
    if ($ue4ssOnPin) {
        Write-Host " already installed" -ForegroundColor DarkGray
    } else {
        Write-Host " kept (-KeepCurrentUE4SS; not the tested build)" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    if ($ue4ssPresent) {
        Write-Host "    The installed UE4SS is not the build Windrose+ is tested with; replacing the loader files only." -ForegroundColor Yellow
        Write-Host "    Your mods and settings are kept. Run with -KeepCurrentUE4SS to skip this." -ForegroundColor DarkGray
    }
    Write-Host "    Downloading $ue4ssPinName..." -ForegroundColor DarkGray

    $ue4ssZipPath = Join-Path $env:TEMP "ue4ss_download.zip"
    $ue4ssExtractDir = Join-Path $env:TEMP "ue4ss_extract"

    try {
        Invoke-WebRequest -Uri $ue4ssPinUrl -OutFile $ue4ssZipPath -UseBasicParsing
        $zipHash = (Get-FileHash -LiteralPath $ue4ssZipPath -Algorithm SHA256).Hash
        if ($zipHash -ne $ue4ssPinZipSha256) {
            Write-Host "    ERROR: UE4SS download does not match the expected file (SHA256 $zipHash)." -ForegroundColor Red
            try { Remove-Item -LiteralPath $ue4ssZipPath -Force -ErrorAction SilentlyContinue } catch {}
            exit 1
        }

        if (Test-Path -LiteralPath $ue4ssExtractDir) { Remove-Item -LiteralPath $ue4ssExtractDir -Recurse -Force }
        Expand-Archive -Path $ue4ssZipPath -DestinationPath $ue4ssExtractDir -Force

        $extractedProxy = Join-Path $ue4ssExtractDir "dwmapi.dll"
        $extractedUe4ss = Join-Path $ue4ssExtractDir "ue4ss"
        $extractedDll = Join-Path $extractedUe4ss "UE4SS.dll"
        if (-not (Test-Path -LiteralPath $extractedProxy) -or -not (Test-Path -LiteralPath $extractedDll)) {
            Write-Host "    ERROR: dwmapi.dll or UE4SS.dll not found in UE4SS download." -ForegroundColor Red
            exit 1
        }

        if (-not (Test-Path -LiteralPath $ue4ssDir)) { New-Item -ItemType Directory -Path $ue4ssDir -Force | Out-Null }
        Copy-Item -LiteralPath $extractedProxy -Destination $win64Dir -Force
        if ($ue4ssPresent) {
            # Upgrade or downgrade in place: swap the loader, leave Mods\ and settings alone.
            Copy-Item -LiteralPath $extractedDll -Destination $ue4ssDir -Force
        } else {
            Get-ChildItem -LiteralPath $extractedUe4ss | Copy-Item -Destination $ue4ssDir -Recurse -Force
        }

        if (-not (Test-Path -LiteralPath $modsDir)) { New-Item -ItemType Directory -Path $modsDir -Force | Out-Null }

        try { Remove-Item -LiteralPath $ue4ssZipPath -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $ue4ssExtractDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}

        Write-Host "    Done." -ForegroundColor Green
    } catch {
        Write-Host "    ERROR: Failed to download UE4SS." -ForegroundColor Red
        Write-Host "    Download $ue4ssPinName manually from: https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental" -ForegroundColor Yellow
        exit 1
    }
}

# Copy UE4SS-settings.ini
$settingsSource = Join-Path $scriptDir "UE4SS-settings.ini"
if (Test-Path -LiteralPath $settingsSource) {
    # These settings are what keep Windrose from crashing at start, so say so if they did not land.
    try {
        Copy-Item -LiteralPath $settingsSource -Destination (Join-Path $ue4ssDir "UE4SS-settings.ini") -Force
    } catch {
        Write-Host "  WARNING: could not write ue4ss\UE4SS-settings.ini: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "           Stop the server and run the installer again." -ForegroundColor Yellow
    }
}

# Step 2: Install Windrose+ mod
Write-Host "  [2/3] Installing Windrose+ mod..." -NoNewline
$modSource = Join-Path $scriptDir "WindrosePlus"
$modDest = Join-Path $modsDir "WindrosePlus"
$dataDir = Join-Path $gameDir "windrose_plus_data"
$configPath = Join-Path $gameDir "windrose_plus.json"

if (-not (Test-Path -LiteralPath $modsDir)) { New-Item -ItemType Directory -Path $modsDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

# Activity log directory. Lua can't reliably mkdir on locked-down hosts, so
# create it here. Without this the events module falls back to writing into
# windrose_plus_data\ next to the legacy events.log, which is hard to find.
$logsDir = Join-Path $dataDir "logs"
if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

# Remove legacy IdleCpuLimiter state from prior versions. The limiter caused
# join-timeout failures under load and is gone for good as of v1.0.15.
$legacyIdleMod = Join-Path $modsDir "IdleCpuLimiter"
if (Test-Path -LiteralPath $legacyIdleMod) {
    try { Remove-Item -LiteralPath $legacyIdleMod -Recurse -Force } catch {}
}
foreach ($legacyFile in @(
    (Join-Path $dataDir "idle_cpu_limiter_disabled"),
    (Join-Path $dataDir "idle_cpu_limiter_enabled"),
    (Join-Path $dataDir "idle_cpu_limiter_cpu_rate.txt"),
    (Join-Path $dataDir "idle_cpu_limiter_cpu_rate_override.txt"),
    (Join-Path $dataDir "idle_cpu_limiter_status.txt")
)) {
    if (Test-Path -LiteralPath $legacyFile) { try { Remove-Item -LiteralPath $legacyFile -Force } catch {} }
}

if (Test-Path -LiteralPath $modSource) {
    try {
        if (-not (Test-Path -LiteralPath $modDest)) {
            Copy-Item -LiteralPath $modSource -Destination $modDest -Recurse -Force
        } else {
            # Reinstall: overwrite Scripts/ but preserve user Mods/
            $scriptsDst = Join-Path $modDest "Scripts"
            if (Test-Path -LiteralPath $scriptsDst) { Remove-Item -LiteralPath $scriptsDst -Recurse -Force }
            Copy-Item -LiteralPath (Join-Path $modSource "Scripts") -Destination $scriptsDst -Recurse -Force

            Get-ChildItem -LiteralPath $modSource -File | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $modDest $_.Name) -Force
            }
        }
        # Install bundled C++ mods if included. WindroseNativeProbe is
        # diagnostic-only and is not auto-loaded on normal servers.
        $cppMods = @(
            @{ Name = "HeightmapExporter"; Source = "cpp-mods\HeightmapExporter\HeightmapExporter.dll" }
        )
        foreach ($cppMod in $cppMods) {
            $dllSrc = Join-Path $scriptDir $cppMod.Source
            if (Test-Path -LiteralPath $dllSrc) {
                $dllDest = Join-Path $modsDir "$($cppMod.Name)\dlls"
                if (-not (Test-Path -LiteralPath $dllDest)) { New-Item -ItemType Directory -Path $dllDest -Force | Out-Null }
                Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $dllDest "main.dll") -Force
                $enabledPath = Join-Path $modsDir "$($cppMod.Name)\enabled.txt"
                if (-not (Test-Path -LiteralPath $enabledPath)) {
                    Set-Content -LiteralPath $enabledPath -Value "1"
                }
            }
        }
        foreach ($diagnosticMod in @("WindroseNativeProbe", "MapMaterializerExporter", "MappingsDumperMod", "WindrosePlusNative")) {
            $enabledPath = Join-Path $modsDir "$diagnosticMod\enabled.txt"
            if (Test-Path -LiteralPath $enabledPath) {
                Remove-Item -LiteralPath $enabledPath -Force -ErrorAction SilentlyContinue
            }
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

# Lua mods: Windrose+ loads the folders listed in Mods\mods_registry.json (a JSON
# array of folder names). Write that list once from the mod folders that have a
# mod.json, leaving the bundled example off; after that, edit the list by hand.
$luaModsDir = Join-Path $modDest "Mods"
if (Test-Path -LiteralPath $luaModsDir) {
    $registryPath = Join-Path $luaModsDir "mods_registry.json"
    $foundMods = @(Get-ChildItem -LiteralPath $luaModsDir -Directory |
        Where-Object { $_.Name -ne "example-welcome" -and (Test-Path -LiteralPath (Join-Path $_.FullName "mod.json")) } |
        ForEach-Object { $_.Name } | Sort-Object)
    if (-not (Test-Path -LiteralPath $registryPath)) {
        if ($foundMods.Count -gt 0) {
            $registryJson = ConvertTo-Json -InputObject @($foundMods) -Compress
            [System.IO.File]::WriteAllText($registryPath, $registryJson, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "  Lua mods listed in Mods\mods_registry.json: $($foundMods -join ', ')"
        }
    } else {
        $listedMods = @()
        try {
            $parsed = [System.IO.File]::ReadAllText($registryPath) | ConvertFrom-Json
            $listedMods = @($parsed | ForEach-Object { [string]$_ })
        } catch {}
        $unlisted = @($foundMods | Where-Object { $listedMods -notcontains $_ })
        if ($unlisted.Count -gt 0) {
            Write-Host "  Lua mods not in Mods\mods_registry.json, so not loaded: $($unlisted -join ', ')" -ForegroundColor Yellow
        }
    }
}

# Add to mods.txt
$modsTxt = Join-Path $modsDir "mods.txt"
if (Test-Path -LiteralPath $modsTxt) {
    $content = Get-Content -LiteralPath $modsTxt -Raw
    # Strip legacy/diagnostic entries that should not auto-load.
    if ($content -match "(?mi)^\s*(IdleCpuLimiter|WindroseNativeProbe|MapMaterializerExporter|MappingsDumperMod|WindrosePlusNative)\s*:") {
        $content = [regex]::Replace($content, "(?mi)^\s*(IdleCpuLimiter|WindroseNativeProbe|MapMaterializerExporter|MappingsDumperMod|WindrosePlusNative)\s*:\s*\d+\s*\r?\n?", "")
        Set-Content -LiteralPath $modsTxt -Value $content
    }
    if ($content -notmatch "WindrosePlus") {
        Add-Content -LiteralPath $modsTxt -Value "`nWindrosePlus : 1`n"
        $content += "`nWindrosePlus : 1`n"
    }
    foreach ($cppModName in @("HeightmapExporter")) {
        $cppMainDll = Join-Path $modsDir "$cppModName\dlls\main.dll"
        if (Test-Path -LiteralPath $cppMainDll) {
            if ($content -match "(?m)^\s*$cppModName\s*:") {
                $content = [regex]::Replace($content, "(?m)^\s*$cppModName\s*:\s*\d+\s*$", "$cppModName : 1")
                Set-Content -LiteralPath $modsTxt -Value $content
            } else {
                Add-Content -LiteralPath $modsTxt -Value "$cppModName : 1`n"
                $content += "`n$cppModName : 1`n"
            }
        }
    }
} else {
    $modsContent = "WindrosePlus : 1`n"
    foreach ($cppModName in @("HeightmapExporter")) {
        $cppMainDll = Join-Path $modsDir "$cppModName\dlls\main.dll"
        if (Test-Path -LiteralPath $cppMainDll) {
            $modsContent += "$cppModName : 1`n"
        }
    }
    Set-Content -LiteralPath $modsTxt -Value $modsContent
}

# UE4SS ships sample Lua mods (console and cheat-manager enablers, keybinds,
# the Blueprint mod loader) switched on. None of them does anything on a
# dedicated server, and with them on Windrose crashed seconds after launch in
# about 1 start in 4 in testing; with them off it did not. Windrose+ does not
# use them. Switch them off; set a line back to 1 in mods.txt to use one.
$ue4ssSampleMods = @("CheatManagerEnablerMod", "ConsoleCommandsMod", "ConsoleEnablerMod", "SplitScreenMod", "LineTraceMod", "BPML_GenericFunctions", "BPModLoaderMod", "Keybinds")
if (Test-Path -LiteralPath $modsTxt) {
    $content = Get-Content -LiteralPath $modsTxt -Raw
    $turnedOff = @()
    foreach ($sample in $ue4ssSampleMods) {
        $pattern = "(?m)^[ \t]*$sample[ \t]*:[ \t]*1[ \t]*(?=\r?$)"
        if ($content -match $pattern) {
            $content = [regex]::Replace($content, $pattern, "$sample : 0")
            $turnedOff += $sample
        }
    }
    if ($turnedOff.Count -gt 0) {
        Set-Content -LiteralPath $modsTxt -Value $content
        Write-Host "    Switched off UE4SS sample mods: $($turnedOff -join ', ')" -ForegroundColor DarkGray
    }
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
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        }
    }

    # Config: only copy .default.ini files, preserve user overrides
    $configSrc = Join-Path $scriptDir "config"
    $configDst = Join-Path $wpDir "config"
    if (Test-Path -LiteralPath $configSrc) {
        if (-not (Test-Path -LiteralPath $configDst)) { New-Item -ItemType Directory -Path $configDst -Force | Out-Null }
        Get-ChildItem -LiteralPath $configSrc -Filter "*.default.ini" | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $configDst $_.Name) -Force
        }
    }

    # Create dashboard launcher. It finds the game folder from where it sits, so a
    # % or a non-English letter in the folder name cannot break the batch file.
    $dashBat = Join-Path $wpDir "start_dashboard.bat"
    Set-Content -LiteralPath $dashBat -Value "@echo off`npowershell -ExecutionPolicy Bypass -File `"%~dp0server\windrose_plus_server.ps1`" -GameDir `"%~dp0..`" %*"

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
    Write-Host "           Antivirus often quarantines retoc/repak as a false positive." -ForegroundColor Yellow
    Write-Host "           Add an exclusion for the windrose_plus folder, then re-extract WindrosePlus.zip." -ForegroundColor Yellow
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
