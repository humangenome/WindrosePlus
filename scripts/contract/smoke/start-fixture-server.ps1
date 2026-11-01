# Starts the real dashboard server on a fresh copy of scripts/contract/fixture/game, in the foreground, for the
# page smoke test (playwright.config.mjs starts and stops it). Windows only.
param([int]$Port = 8790)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repo = Split-Path -Parent $root
$game = Join-Path ([System.IO.Path]::GetTempPath()) ("wp-smoke-" + [guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath (Join-Path $repo 'scripts\contract\fixture\game') -Destination $game -Recurse
$logs = Join-Path $game 'windrose_plus_data\logs'
Move-Item -LiteralPath (Join-Path $logs 'activity.log') -Destination (Join-Path $logs ([DateTime]::UtcNow.ToString('yyyy-MM-dd') + '.log'))
# in this process, so stopping this script stops the server too
& (Join-Path $repo 'server\windrose_plus_server.ps1') -GameDir $game -Port $Port -BindIp 127.0.0.1
