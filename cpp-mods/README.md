# C++ Mods

This directory contains C++ mods built against the [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) SDK.

## End Users

You do **not** need to build these yourself. Download the pre-built DLLs from the [GitHub Releases](https://github.com/HumanGenome/WindrosePlus/releases) page and drop them into your UE4SS `Mods/` folder.

## Included Mods

- `HeightmapExporter` exports terrain height data for the live map.
- `WindroseNativeProbe` is an experimental read-only runtime UObject reflection
  dump for player, inventory, storage, progression, chat, and network research.
  It is not enabled by the installer; use it only on non-production test servers.

## Building from Source (Contributors)

### Prerequisites

- Windows 10/11
- Visual Studio 2022 with C++ desktop workload (MSVC v143)
- CMake 3.18+
- Git

### Setup

```bash
git clone https://github.com/HumanGenome/WindrosePlus.git
cd WindrosePlus/cpp-mods

# Clone the UE4SS SDK (required dependency, not included as submodule)
git clone https://github.com/UE4SS-RE/RE-UE4SS.git
```

### Build

```bash
cmake -B build -S . -G "Visual Studio 17 2022" -A x64
cmake --build build --config Game__Shipping__Win64
```

Output DLLs will be under each mod's `Game__Shipping__Win64/` directory.

## Adding a New C++ Mod

1. Create a new directory under `cpp-mods/` (e.g., `cpp-mods/MyMod/`)
2. Add a `CMakeLists.txt` that links against the UE4SS SDK from `RE-UE4SS/`
3. Follow the structure of `HeightmapExporter/` as a reference
4. Register your mod's subdirectory in the top-level `cpp-mods/CMakeLists.txt`
5. Build and test against a running Windrose dedicated server with UE4SS loaded
