#define NOMINMAX
// MapMaterializerExporter v1.0 — engine-side dumper for FT->POI registry and post-rule terrain grids.
//
// Two phases gated by sentinel files in windrose_plus_data/:
//   export_mapmat_discovery_trigger -> dumps UClass survey (classes, sample objects, property metadata)
//   export_mapmat_extract_trigger   -> dumps focused per-class data (object paths of every Object property,
//                                       plus class+path of all R5TerrainSettings/FoliageType/MarkerModel/Spawner/Subsystem instances).
//
// Outputs:
//   windrose_plus_data/mapmat_discovery.json
//   windrose_plus_data/mapmat_extract.json
//   windrose_plus_data/export_mapmat_done       (one of: discovery|extract)
//
// Notes
// -----
// * Discovery is the "find me class names" phase. It lists every UObject class whose name contains an
//   interest token (Foliage / POI / Terrain / Marker / Scenario / Subsystem / Quest / R5 / Island / Biome / Spawner)
//   along with the count of live objects, a sample object's path, and the names+types of properties on its class.
// * Extract pulls the actual data once we know which classes hold the FT<->POI mapping. Initial implementation
//   dumps every Object reference on every R5TerrainSettings / FoliageType / MarkerModel / Spawner / Subsystem instance.
//   That should expose the cross-references the engine actually maintains at runtime (e.g. a subsystem's TMap of
//   FoliageType to POI map).
// * String/Name property values are intentionally NOT read in v1.0. v2.0 will add typed reads for FString and
//   FName once we know which property names matter. UObject pointers via ContainerPtrToValuePtr<UObject*> are safe.

#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UClass.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <windows.h>
#include <fstream>
#include <vector>
#include <cstdint>
#include <filesystem>
#include <map>
#include <string>

using namespace RC;
using namespace RC::Unreal;

static std::string wide_to_utf8(std::wstring_view w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

static std::string json_escape(const std::string& s) {
    std::string out; out.reserve(s.size() + 4);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if ((unsigned char)c < 0x20) {
                    char buf[8]; std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
                    out += buf;
                } else out += c;
        }
    }
    return out;
}

static std::string class_name_str(UObject* o) {
    if (!o) return "(null)";
    auto* c = o->GetClassPrivate();
    return c ? wide_to_utf8(c->GetName()) : "(noclass)";
}

static std::string obj_path(UObject* o) {
    if (!o) return "";
    return wide_to_utf8(o->GetPathName());
}

static std::filesystem::path resolve_data_dir() {
    std::filesystem::path candidates[] = {
        "../../../windrose_plus_data",
        "windrose_plus_data",
    };
    for (auto& p : candidates) {
        try { if (std::filesystem::exists(p)) return p; } catch (...) {}
    }
    try { std::filesystem::create_directories("windrose_plus_data"); } catch (...) {}
    return "windrose_plus_data";
}

static const std::vector<std::wstring> kInterestTokens = {
    STR("Foliage"),
    STR("POI"),
    STR("Terrain"),
    STR("Marker"),
    STR("Scenario"),
    STR("Subsystem"),
    STR("Quest"),
    STR("R5"),
    STR("Island"),
    STR("Biome"),
    STR("Spawner"),
};

static bool name_matches_interest(const std::wstring& n) {
    for (auto& tok : kInterestTokens) {
        if (n.find(tok) != std::wstring::npos) return true;
    }
    return false;
}

static bool class_name_contains(UObject* o, const std::wstring& tok) {
    auto* c = o->GetClassPrivate();
    return c && c->GetName().find(tok) != std::wstring::npos;
}

// ---------- DISCOVERY PHASE ----------

struct DiscoveryBucket {
    std::wstring class_name;
    int count = 0;
    UObject* sample = nullptr;
};

static void run_discovery(const std::filesystem::path& outDir) {
    Output::send<LogLevel::Verbose>(STR("[MME] discovery start\n"));
    std::map<std::wstring, DiscoveryBucket> buckets;

    UObjectGlobals::ForEachUObject([&](UObject* o, int32, int32) -> RC::LoopAction {
        auto* c = o->GetClassPrivate();
        if (!c) return RC::LoopAction::Continue;
        auto cn = c->GetName();
        if (!name_matches_interest(cn)) return RC::LoopAction::Continue;
        auto& b = buckets[cn];
        if (b.class_name.empty()) b.class_name = cn;
        b.count++;
        if (!b.sample) b.sample = o;
        return RC::LoopAction::Continue;
    });

    std::ofstream out(outDir / "mapmat_discovery.json");
    out << "{\n  \"version\": 1,\n  \"classes\": [\n";
    bool first = true;
    for (auto& [_, b] : buckets) {
        if (!first) out << ",\n";
        first = false;
        out << "    {\"class\":\"" << json_escape(wide_to_utf8(b.class_name))
            << "\",\"count\":" << b.count;
        if (b.sample) {
            out << ",\"samplePath\":\"" << json_escape(obj_path(b.sample)) << "\"";
            // Property metadata via TFieldRange
            out << ",\"props\":[";
            bool pfirst = true;
            for (FProperty* p : TFieldRange<FProperty>(b.sample->GetClassPrivate(),
                                                       EFieldIterationFlags::IncludeSuper | EFieldIterationFlags::IncludeDeprecated)) {
                if (!pfirst) out << ", ";
                pfirst = false;
                auto fc = p->GetClass();
                out << "{\"name\":\"" << json_escape(wide_to_utf8(p->GetName()))
                    << "\",\"type\":\"" << json_escape(wide_to_utf8(fc.GetFName().ToString()))
                    << "\",\"offset\":" << (int)p->GetOffset_Internal() << "}";
            }
            out << "]";
        }
        out << "}";
    }
    out << "\n  ]\n}\n";
    out.close();
    Output::send<LogLevel::Verbose>(STR("[MME] discovery wrote {} classes\n"), (int)buckets.size());
}

// ---------- EXTRACTION PHASE ----------

// Walk every Object property on |o| and emit each non-null reference as JSON.
static void emit_object_refs(std::ofstream& out, UObject* o, bool& first) {
    auto* sc = o->GetClassPrivate();
    if (!sc) return;
    for (FProperty* p : TFieldRange<FProperty>(sc,
                                               EFieldIterationFlags::IncludeSuper | EFieldIterationFlags::IncludeDeprecated)) {
        auto fc = p->GetClass();
        auto type_name = fc.GetFName().ToString();
        if (type_name.find(STR("ObjectProperty")) == std::wstring::npos) continue;
        // Read UObject** at the property's offset.
        auto** pp = p->ContainerPtrToValuePtr<UObject*>(o);
        if (!pp || !*pp) continue;
        if (!first) out << ", ";
        first = false;
        out << "{\"prop\":\"" << json_escape(wide_to_utf8(p->GetName()))
            << "\",\"path\":\"" << json_escape(obj_path(*pp))
            << "\",\"class\":\"" << json_escape(class_name_str(*pp))
            << "\"}";
    }
}

static void emit_object_with_refs(std::ofstream& out, UObject* o, bool& first) {
    if (!first) out << ",\n";
    first = false;
    out << "    {\"class\":\"" << json_escape(class_name_str(o))
        << "\",\"path\":\"" << json_escape(obj_path(o)) << "\""
        << ",\"refs\":[";
    bool rfirst = true;
    emit_object_refs(out, o, rfirst);
    out << "]}";
}

static void run_extract(const std::filesystem::path& outDir) {
    Output::send<LogLevel::Verbose>(STR("[MME] extract start\n"));

    std::vector<UObject*> terrains, foliages, markers, spawners, subsystems;
    UObjectGlobals::ForEachUObject([&](UObject* o, int32, int32) -> RC::LoopAction {
        if      (class_name_contains(o, STR("TerrainSettings"))) terrains.push_back(o);
        else if (class_name_contains(o, STR("FoliageType")))     foliages.push_back(o);
        else if (class_name_contains(o, STR("MarkerModel")))     markers.push_back(o);
        else if (class_name_contains(o, STR("Spawner")) || class_name_contains(o, STR("FoliageInstance"))) spawners.push_back(o);
        else if (class_name_contains(o, STR("Subsystem")))       subsystems.push_back(o);
        return RC::LoopAction::Continue;
    });

    std::ofstream out(outDir / "mapmat_extract.json");
    out << "{\n  \"version\": 1";
    auto emit_section = [&](const char* name, std::vector<UObject*>& v) {
        out << ",\n  \"" << name << "\": [\n";
        bool f = true;
        for (auto* o : v) emit_object_with_refs(out, o, f);
        out << "\n  ]";
    };
    emit_section("terrainSettings", terrains);
    emit_section("foliageTypes",    foliages);
    emit_section("markerModels",    markers);
    emit_section("foliageSpawners", spawners);
    emit_section("subsystems",      subsystems);
    out << "\n}\n";
    out.close();

    Output::send<LogLevel::Verbose>(STR("[MME] extract wrote terrains={} foliages={} markers={} spawners={} subsystems={}\n"),
        (int)terrains.size(), (int)foliages.size(), (int)markers.size(), (int)spawners.size(), (int)subsystems.size());
}

// ---------- DRIVER ----------

class MapMaterializerExporter : public CppUserModBase {
public:
    MapMaterializerExporter() : CppUserModBase() {
        ModName = STR("MapMaterializerExporter");
        ModVersion = STR("1.0.0");
    }
    ~MapMaterializerExporter() override {}

    auto on_unreal_init() -> void override {
        Output::send<LogLevel::Verbose>(STR("[MME] v1.0 init\n"));
    }

    auto on_update() -> void override {
        m_frameCount++;
        if (m_frameCount % 300 != 0) return;
        auto outDir = resolve_data_dir();
        try {
            auto disc = outDir / "export_mapmat_discovery_trigger";
            if (std::filesystem::exists(disc)) {
                std::filesystem::remove(disc);
                run_discovery(outDir);
                std::ofstream mk(outDir / "export_mapmat_done"); mk << "discovery"; mk.close();
            }
            auto extr = outDir / "export_mapmat_extract_trigger";
            if (std::filesystem::exists(extr)) {
                std::filesystem::remove(extr);
                run_extract(outDir);
                std::ofstream mk(outDir / "export_mapmat_done"); mk << "extract"; mk.close();
            }
        } catch (...) {}
    }

private:
    int m_frameCount = 0;
};

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod() { return new MapMaterializerExporter(); }
extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod) { delete mod; }
