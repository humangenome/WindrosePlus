#pragma once
// How the HeightmapExporter puts terrain_v17.json on disk (no UE4SS here, so it is tested on its own:
// cpp-mods/HeightmapExporter/tests/terrain_commit_test.cpp).
//
// Up to v17.0 the exporter opened terrain_v17.json for writing before it had looked at the world, so an export
// taken while the server sat in its lobby map (no landscape pieces with heights) replaced a good file with a
// 74-byte one. A test server lost its terrain that way on 2026-10-12 and could not rebuild its Sea Chart tiles.
//
// Now the new file is written beside the old one and moved over it only when at least one piece has heights.
// An export with none leaves terrain_v17.json exactly as it was (or absent) and says so in the done marker:
// "ok" = a new terrain file was written, "empty" = nothing was written. main.lua reads the marker.

#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>

namespace hme {

enum class Commit { Written, Empty, Failed };

inline const char* TerrainFile = "terrain_v17.json";
inline const char* TerrainTemp = "terrain_v17.json.tmp";
inline const char* DoneMarker = "export_heightmap_done";

// Writes text to path (text mode, as the exporter always has: CRLF line ends on Windows). True when every byte
// was written and the file closed cleanly.
inline bool writeText(const std::filesystem::path& path, const std::string& text) {
    std::ofstream out(path, std::ios::out | std::ios::trunc);
    if (!out) return false;
    out << text;
    out.close();
    return !out.fail();
}

// Puts a finished export on disk. withHeights = pieces that had height data. Never throws: this runs on the
// game thread.
inline Commit commitTerrain(const std::filesystem::path& dir, const std::string& json, int withHeights) {
    std::error_code ec;
    const auto target = dir / TerrainFile;
    const auto temp = dir / TerrainTemp;
    std::filesystem::remove(temp, ec);  // a leftover from an export that died half way

    if (withHeights <= 0) return Commit::Empty;

    if (!writeText(temp, json)) {
        std::filesystem::remove(temp, ec);
        return Commit::Failed;
    }
    // Replaces the old file in one step (MoveFileExW with MOVEFILE_REPLACE_EXISTING on Windows).
    std::filesystem::rename(temp, target, ec);
    if (!ec) return Commit::Written;
    // A reader that holds the old file open without delete sharing blocks the move; copying over it is what
    // v17.0 did anyway.
    std::error_code copyEc;
    std::filesystem::copy_file(temp, target, std::filesystem::copy_options::overwrite_existing, copyEc);
    std::filesystem::remove(temp, ec);
    return copyEc ? Commit::Failed : Commit::Written;
}

// The marker main.lua waits for after it asks for an export.
inline void writeDone(const std::filesystem::path& dir, Commit result) {
    writeText(dir / DoneMarker, result == Commit::Written ? "ok" : "empty");
}

}  // namespace hme
