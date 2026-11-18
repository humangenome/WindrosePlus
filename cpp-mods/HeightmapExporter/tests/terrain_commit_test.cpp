// Tests for terrain_commit.hpp: how the HeightmapExporter puts terrain_v17.json on disk.
// No UE4SS needed. From the repo root:
//   g++ -std=c++17 -Wall -Wextra -Werror -I cpp-mods/HeightmapExporter
//       cpp-mods/HeightmapExporter/tests/terrain_commit_test.cpp -o hme-test
//   ./hme-test scripts/contract/samples
// (CI: .github/workflows/ci.yml, "C++ exporter file handling").

#include "terrain_commit.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>

namespace fs = std::filesystem;

static int failures = 0;
static int cases = 0;

#define CHECK(cond, msg)                                                   \
    do {                                                                   \
        if (!(cond)) {                                                     \
            std::printf("  FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__);   \
            ++failures;                                                    \
        }                                                                  \
    } while (0)

static std::string readAll(const fs::path& p) {
    std::ifstream in(p, std::ios::binary);
    if (!in) return std::string("<missing>");
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

// What a text-mode write puts on disk: the exporter has always written CRLF line ends on Windows (the 74-byte
// lobby file was 71 bytes of text plus three CRs) and LF elsewhere.
static std::string onDisk(const std::string& text) {
#ifdef _WIN32
    std::string out;
    for (char c : text) {
        if (c == '\n') out += '\r';
        out += c;
    }
    return out;
#else
    return text;
#endif
}

static void writeAll(const fs::path& p, const std::string& text) {
    std::ofstream out(p, std::ios::binary | std::ios::trunc);
    out << text;
}

static fs::path freshDir(const char* name) {
    static const auto run = std::chrono::steady_clock::now().time_since_epoch().count();
    fs::path d = fs::temp_directory_path() / ("hme-test-" + std::to_string(run) + "-" + name);
    std::error_code ec;
    fs::remove_all(d, ec);
    fs::create_directories(d);
    return d;
}

static void dropDir(const fs::path& d) {
    std::error_code ec;
    fs::remove_all(d, ec);
}

int main(int argc, char** argv) {
    const fs::path samples = argc > 1 ? fs::path(argv[1]) : fs::path("scripts/contract/samples");
    const std::string good = readAll(samples / "terrain_v17.json");
    const std::string empty = readAll(samples / "terrain_v17.empty.json");
    if (good == "<missing>" || empty == "<missing>") {
        std::printf("samples not found under %s\n", samples.string().c_str());
        return 2;
    }
    std::string good2 = good;
    good2.replace(good2.find("\"maxZ\":"), 7, "\"maxZ\": ");

    {
        ++cases;
        std::printf("an export with heights replaces the old terrain file\n");
        fs::path d = freshDir("written");
        writeAll(d / hme::TerrainFile, good);
        auto r = hme::commitTerrain(d, good2, 3);
        hme::writeDone(d, r);
        CHECK(r == hme::Commit::Written, "result is not Written");
        CHECK(readAll(d / hme::TerrainFile) == onDisk(good2), "terrain file is not the new export");
        CHECK(!fs::exists(d / hme::TerrainTemp), "a .tmp file was left");
        CHECK(readAll(d / hme::DoneMarker) == "ok", "done marker is not ok");
        dropDir(d);
    }
    {
        ++cases;
        std::printf("an export with no heights (the lobby map) leaves a good terrain file byte for byte\n");
        fs::path d = freshDir("kept");
        writeAll(d / hme::TerrainFile, good);
        auto r = hme::commitTerrain(d, empty, 0);
        hme::writeDone(d, r);
        CHECK(r == hme::Commit::Empty, "result is not Empty");
        CHECK(readAll(d / hme::TerrainFile) == good, "the good terrain file changed");
        CHECK(!fs::exists(d / hme::TerrainTemp), "a .tmp file was left");
        CHECK(readAll(d / hme::DoneMarker) == "empty", "done marker is not empty");
        dropDir(d);
    }
    {
        ++cases;
        std::printf("an export with no heights and no old file writes no terrain file (no 74-byte stub)\n");
        fs::path d = freshDir("none");
        auto r = hme::commitTerrain(d, empty, 0);
        hme::writeDone(d, r);
        CHECK(r == hme::Commit::Empty, "result is not Empty");
        CHECK(!fs::exists(d / hme::TerrainFile), "a terrain file was written");
        CHECK(readAll(d / hme::DoneMarker) == "empty", "done marker is not empty");
        dropDir(d);
    }
    {
        ++cases;
        std::printf("a first export with heights is written when no file existed\n");
        fs::path d = freshDir("first");
        auto r = hme::commitTerrain(d, good, 5);
        CHECK(r == hme::Commit::Written, "result is not Written");
        CHECK(readAll(d / hme::TerrainFile) == onDisk(good), "terrain file is not the export");
        dropDir(d);
    }
    {
        ++cases;
        std::printf("a .tmp left by an export that died half way is removed, and never becomes the terrain file\n");
        fs::path d = freshDir("leftover");
        writeAll(d / hme::TerrainFile, good);
        writeAll(d / hme::TerrainTemp, empty);
        auto r = hme::commitTerrain(d, empty, 0);
        CHECK(r == hme::Commit::Empty, "result is not Empty");
        CHECK(!fs::exists(d / hme::TerrainTemp), "the leftover .tmp is still there");
        CHECK(readAll(d / hme::TerrainFile) == good, "the good terrain file changed");
        dropDir(d);
    }
    {
        ++cases;
        std::printf("a folder that cannot be written to fails and leaves the old file\n");
        fs::path d = freshDir("nowrite");
        writeAll(d / hme::TerrainFile, good);
        fs::create_directories(d / hme::TerrainTemp);  // a directory where the .tmp should go: the write must fail
        writeAll(d / hme::TerrainTemp / "x", "x");     // and not be removable by remove()
        auto r = hme::commitTerrain(d, good2, 2);
        CHECK(r == hme::Commit::Failed, "result is not Failed");
        CHECK(readAll(d / hme::TerrainFile) == good, "the old terrain file changed");
        hme::writeDone(d, r);
        CHECK(readAll(d / hme::DoneMarker) == "empty", "done marker is not empty after a failed write");
        dropDir(d);
    }

    std::printf("%d cases, %d failed checks\n", cases, failures);
    return failures == 0 ? 0 : 1;
}
