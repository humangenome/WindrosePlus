Hand-written samples for the data files the Linux checks cannot produce with the real writer: terrain_v17.json
comes from the HeightmapExporter C++ mod inside the game, map_generation_status.json from the dashboard server
(PowerShell). Each copies its writer's output field for field (cpp-mods/HeightmapExporter/dllmain.cpp,
Write-TileGenStatus in server/windrose_plus_server.ps1); change them only together with the writer.
terrain_v17.empty.json is the export taken before the world loads (the lobby): valid in form, but the mod
treats it as no terrain (terrainLooksValid) and exports again when the next player joins.
