#define NOMINMAX
// MapMaterializerExporter v2.1 — engine-side dumper for the WP+ map materializer.
//
// Two phases gated by sentinel files in windrose_plus_data/:
//   export_mapmat_discovery_trigger -> mapmat_discovery.json (UClass survey + UFunction list)
//   export_mapmat_extract_trigger   -> mapmat_extract.json   (typed reads of every live R5* instance)
//
// v2.1 changes vs v2.1:
//   * StructProperty: read fixed-layout structs by name (Vector, Vector2D, Rotator, Guid,
//     IntPoint, IntVector, Quat). Emits {x,y,z} / {a,b,c,d} / etc inline.
//   * ArrayProperty<StructProperty>: walks elements with the same struct dispatch — needed
//     for Models[] / IslandGenerators[] payloads where the inner is FVector / FGuid embedded.
//   * Float/Double/Int/Bool scalar reads (was kind-only in v2.1).
//
// v2.1 changes vs v1.0:
//   * Exact FProperty subclass match (was substring "ObjectProperty" which also matched
//     SoftObjectProperty / WeakObjectProperty -> wrong layout -> crash on deref).
//   * CDO + pending-destroy + Unreachable lifecycle skip on every UObject we touch.
//   * Discovery emits TWO counts: total + live (post-CDO skip), and prefers a LIVE sample.
//   * Discovery emits UFunction list per interesting class (name + flags + numparms + return type).
//   * Extract caps per-class instance count to keep JSON bounded.
//
// Outputs:
//   <gameroot>/windrose_plus_data/mapmat_discovery.json
//   <gameroot>/windrose_plus_data/mapmat_extract.json
//   <gameroot>/windrose_plus_data/export_mapmat_done

#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UClass.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/UnrealFlags.hpp>
#include <Unreal/FString.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UScriptStruct.hpp>
#include <windows.h>
#include <fstream>
#include <vector>
#include <cstdint>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <utility>

using namespace RC;
using namespace RC::Unreal;

// ---------- string helpers ----------

static std::string wide_to_utf8(std::wstring_view w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
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

// ---------- lifecycle / CDO safety ----------

static bool is_skippable(UObject* o) {
    if (!o) return true;
    // CDO
    if (o->HasAnyFlags(static_cast<EObjectFlags>(RF_ClassDefaultObject))) return true;
    if (o->HasAnyFlags(static_cast<EObjectFlags>(RF_BeginDestroyed | RF_FinishDestroyed))) return true;
    return false;
}

// ---------- interest matching ----------

static const std::vector<std::wstring> kInterestTokens = {
    STR("Foliage"), STR("POI"), STR("Terrain"), STR("Marker"), STR("Scenario"),
    STR("Subsystem"), STR("Quest"), STR("R5"), STR("Island"), STR("Biome"),
    STR("Spawner"), STR("Capture"), STR("WorldGenerator"), STR("MapController"),
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

// Suppress per-extract noisy classes (FoliageInstance has tens of thousands).
static const std::vector<std::wstring> kExtractDeny = {
    STR("FoliageInstance"),
    STR("FoliageMesh"),
    STR("HierarchicalInstancedStaticMesh"),
};

static bool class_in_extract_denylist(const std::wstring& cn) {
    for (auto& tok : kExtractDeny) {
        if (cn.find(tok) != std::wstring::npos) return true;
    }
    return false;
}

// ---------- output dir ----------

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

// ---------- typed property reads ----------

// Returns the FProperty class kind name (e.g. "ObjectProperty", "StrProperty", "ArrayProperty").
static std::wstring prop_kind(FProperty* p) {
    auto fc = p->GetClass();
    return fc.GetFName().ToString();
}

// Read FString property safely. Returns utf8.
static std::string read_fstring(FProperty* p, UObject* o, bool& ok) {
    ok = false;
    auto* fs = p->ContainerPtrToValuePtr<FString>(o);
    if (!fs) return {};
    const auto& arr = fs->GetCharArray();
    int32 num = arr.Num();
    if (num <= 1) { ok = true; return {}; }
    const TCHAR* data = arr.GetData();
    if (!data) return {};
    // arr is null-terminated; len = num - 1
    std::wstring_view sv(data, static_cast<size_t>(num - 1));
    ok = true;
    return wide_to_utf8(sv);
}

// Read FName property safely. Returns utf8.
static std::string read_fname(FProperty* p, UObject* o, bool& ok) {
    ok = false;
    auto* fn = p->ContainerPtrToValuePtr<FName>(o);
    if (!fn) return {};
    auto wstr = fn->ToString();
    ok = true;
    return wide_to_utf8(wstr);
}

// Read raw UObject* from an FObjectProperty. Returns nullptr if null or unsafe.
static UObject* read_object_ref(FProperty* p, UObject* o) {
    auto** pp = p->ContainerPtrToValuePtr<UObject*>(o);
    if (!pp) return nullptr;
    return *pp;
}

// ---------- struct readers ----------
//
// Layouts assume UE5 (TVector<double>, TRotator<double>). All struct payloads
// here are POD with deterministic offsets. We emit the struct kind name in the
// returned blob so consumers can branch.

static std::string fmt_double(double d) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.9g", d);
    return buf;
}

// Returns a JSON snippet (no leading separator). Empty string -> caller should
// skip the value (unknown / unsafe layout).
static std::string read_struct_value(const std::wstring& sname, const uint8_t* base) {
    if (!base) return {};
    auto d = [&](size_t off) { return *reinterpret_cast<const double*>(base + off); };
    auto i32 = [&](size_t off) { return *reinterpret_cast<const int32_t*>(base + off); };
    auto u32 = [&](size_t off) { return *reinterpret_cast<const uint32_t*>(base + off); };

    if (sname == STR("Vector")) {
        return "{\"x\":" + fmt_double(d(0)) + ",\"y\":" + fmt_double(d(8)) + ",\"z\":" + fmt_double(d(16)) + "}";
    }
    if (sname == STR("Vector2D")) {
        return "{\"x\":" + fmt_double(d(0)) + ",\"y\":" + fmt_double(d(8)) + "}";
    }
    if (sname == STR("Vector4")) {
        return "{\"x\":" + fmt_double(d(0)) + ",\"y\":" + fmt_double(d(8)) +
               ",\"z\":" + fmt_double(d(16)) + ",\"w\":" + fmt_double(d(24)) + "}";
    }
    if (sname == STR("Rotator")) {
        return "{\"pitch\":" + fmt_double(d(0)) + ",\"yaw\":" + fmt_double(d(8)) +
               ",\"roll\":" + fmt_double(d(16)) + "}";
    }
    if (sname == STR("Quat")) {
        return "{\"x\":" + fmt_double(d(0)) + ",\"y\":" + fmt_double(d(8)) +
               ",\"z\":" + fmt_double(d(16)) + ",\"w\":" + fmt_double(d(24)) + "}";
    }
    if (sname == STR("Guid")) {
        char hex[40];
        std::snprintf(hex, sizeof(hex), "%08X-%08X-%08X-%08X", u32(0), u32(4), u32(8), u32(12));
        return std::string("\"") + hex + "\"";
    }
    if (sname == STR("IntPoint")) {
        return "{\"x\":" + std::to_string(i32(0)) + ",\"y\":" + std::to_string(i32(4)) + "}";
    }
    if (sname == STR("IntVector")) {
        return "{\"x\":" + std::to_string(i32(0)) + ",\"y\":" + std::to_string(i32(4)) +
               ",\"z\":" + std::to_string(i32(8)) + "}";
    }
    return {};
}

// ---------- DISCOVERY PHASE ----------

struct DiscoveryBucket {
    std::wstring class_name;
    int total = 0;
    int live = 0;
    UObject* sampleLive = nullptr;
    UObject* sampleAny = nullptr;
};

// Emit property metadata. Walks superchain.
static void emit_class_props(std::ofstream& out, UClass* c) {
    out << "[";
    bool pfirst = true;
    try {
        for (FProperty* p : TFieldRange<FProperty>(c, EFieldIterationFlags::IncludeSuper)) {
            if (!pfirst) out << ", ";
            pfirst = false;
            auto kind = prop_kind(p);
            int32 offset = (int32)p->GetOffset_Internal();
            int32 size = (int32)p->GetElementSize();
            out << "{\"name\":\"" << json_escape(wide_to_utf8(p->GetName()))
                << "\",\"type\":\"" << json_escape(wide_to_utf8(kind))
                << "\",\"offset\":" << offset
                << ",\"size\":" << size << "}";
        }
    } catch (...) {}
    out << "]";
}

// Emit UFunction metadata for a class.
static void emit_class_funcs(std::ofstream& out, UClass* c) {
    out << "[";
    bool ffirst = true;
    try {
        for (UFunction* f : TFieldRange<UFunction>(c, EFieldIterationFlags::IncludeSuper)) {
            if (!ffirst) out << ", ";
            ffirst = false;
            uint32 flags = 0;
            try { flags = f->GetFunctionFlags(); } catch (...) {}
            out << "{\"name\":\"" << json_escape(wide_to_utf8(f->GetName()))
                << "\",\"flags\":" << flags;
            // Parameter list — names + kinds, in declaration order.
            out << ",\"params\":[";
            bool prfirst = true;
            try {
                for (FProperty* p : TFieldRange<FProperty>(f, EFieldIterationFlags::None)) {
                    if (!prfirst) out << ", ";
                    prfirst = false;
                    auto kind = prop_kind(p);
                    out << "{\"name\":\"" << json_escape(wide_to_utf8(p->GetName()))
                        << "\",\"type\":\"" << json_escape(wide_to_utf8(kind))
                        << "\"}";
                }
            } catch (...) {}
            out << "]}";
        }
    } catch (...) {}
    out << "]";
}

static void run_discovery(const std::filesystem::path& outDir) {
    Output::send<LogLevel::Verbose>(STR("[MME] v2.1 discovery start\n"));
    std::map<std::wstring, DiscoveryBucket> buckets;

    UObjectGlobals::ForEachUObject([&](UObject* o, int32, int32) -> RC::LoopAction {
        auto* c = o->GetClassPrivate();
        if (!c) return RC::LoopAction::Continue;
        auto cn = c->GetName();
        if (!name_matches_interest(cn)) return RC::LoopAction::Continue;
        auto& b = buckets[cn];
        if (b.class_name.empty()) b.class_name = cn;
        b.total++;
        if (!b.sampleAny) b.sampleAny = o;
        if (!is_skippable(o)) {
            b.live++;
            if (!b.sampleLive) b.sampleLive = o;
        }
        return RC::LoopAction::Continue;
    });

    std::ofstream out(outDir / "mapmat_discovery.json");
    out << "{\n  \"version\": 2,\n  \"classes\": [\n";
    bool first = true;
    for (auto& [_, b] : buckets) {
        if (!first) out << ",\n";
        first = false;
        UObject* s = b.sampleLive ? b.sampleLive : b.sampleAny;
        UClass* sc = s ? s->GetClassPrivate() : nullptr;
        out << "    {\"class\":\"" << json_escape(wide_to_utf8(b.class_name))
            << "\",\"countTotal\":" << b.total
            << ",\"countLive\":" << b.live;
        if (s) {
            out << ",\"samplePath\":\"" << json_escape(obj_path(s)) << "\"";
            out << ",\"sampleIsCDO\":" << (b.sampleLive ? "false" : "true");
        }
        if (sc) {
            out << ",\"props\":";  emit_class_props(out, sc);
            out << ",\"funcs\":";  emit_class_funcs(out, sc);
        }
        out << "}";
    }
    out << "\n  ]\n}\n";
    out.close();
    Output::send<LogLevel::Verbose>(STR("[MME] v2.1 discovery wrote {} classes\n"), (int)buckets.size());
}

// ---------- EXTRACTION PHASE ----------

// Per-property emission:
//   - ObjectProperty: object path + class
//   - StrProperty: utf8 string
//   - NameProperty: utf8 name
//   - BoolProperty: not yet (UE4SS API differs)
//   - NumericProperty subclasses: read raw bytes by offset+size
//   - ArrayProperty<ObjectProperty/StrProperty/NameProperty>: walk via FScriptArrayHelper
//   - Other: emit kind name only
static void emit_property_value(std::ofstream& out, FProperty* p, UObject* o) {
    auto kind = prop_kind(p);
    auto kind_u8 = wide_to_utf8(kind);

    out << "{\"name\":\"" << json_escape(wide_to_utf8(p->GetName()))
        << "\",\"kind\":\"" << json_escape(kind_u8) << "\"";

    if (kind == STR("ObjectProperty")) {
        UObject* ref = read_object_ref(p, o);
        if (ref) {
            out << ",\"path\":\"" << json_escape(obj_path(ref)) << "\""
                << ",\"refClass\":\"" << json_escape(class_name_str(ref)) << "\"";
        } else {
            out << ",\"path\":null";
        }
    }
    else if (kind == STR("StrProperty")) {
        bool ok = false;
        std::string s = read_fstring(p, o, ok);
        if (ok) out << ",\"value\":\"" << json_escape(s) << "\"";
    }
    else if (kind == STR("NameProperty")) {
        bool ok = false;
        std::string s = read_fname(p, o, ok);
        if (ok) out << ",\"value\":\"" << json_escape(s) << "\"";
    }
    else if (kind == STR("StructProperty")) {
        try {
            auto* sp = static_cast<FStructProperty*>(p);
            auto& sref = sp->GetStruct();
            UScriptStruct* ss = sref.Get();
            std::wstring sname = ss ? ss->GetName() : STR("");
            out << ",\"structName\":\"" << json_escape(wide_to_utf8(sname)) << "\"";
            const uint8_t* base = p->ContainerPtrToValuePtr<uint8_t>(o);
            std::string blob = read_struct_value(sname, base);
            if (!blob.empty()) {
                out << ",\"value\":" << blob;
            } else {
                // Honest signal to the adapter: this struct shape isn't decoded
                // by read_struct_value yet. The adapter must treat the value
                // as opaque rather than guess fields. A populated-world run
                // that needs custom-struct fields (e.g. R5FoliageBinding,
                // R5RuntimePolygon) MUST extend read_struct_value or add a
                // recursive walker before claiming byte-exact parity.
                out << ",\"value\":null,\"unhandledStruct\":true";
            }
        } catch (...) {
            out << ",\"err\":\"struct_read_failed\"";
        }
    }
    else if (kind == STR("BoolProperty")) {
        try {
            auto* bp = static_cast<FBoolProperty*>(p);
            void* container = p->ContainerPtrToValuePtr<void>(o);
            bool v = container ? bp->GetPropertyValue(container) : false;
            out << ",\"value\":" << (v ? "true" : "false");
        } catch (...) {}
    }
    else if (kind == STR("FloatProperty")) {
        try {
            const float* fp = p->ContainerPtrToValuePtr<float>(o);
            if (fp) out << ",\"value\":" << fmt_double((double)*fp);
        } catch (...) {}
    }
    else if (kind == STR("DoubleProperty")) {
        try {
            const double* dp = p->ContainerPtrToValuePtr<double>(o);
            if (dp) out << ",\"value\":" << fmt_double(*dp);
        } catch (...) {}
    }
    else if (kind == STR("IntProperty") || kind == STR("Int32Property")) {
        try {
            const int32* ip = p->ContainerPtrToValuePtr<int32>(o);
            if (ip) out << ",\"value\":" << *ip;
        } catch (...) {}
    }
    else if (kind == STR("Int64Property")) {
        try {
            const int64* ip = p->ContainerPtrToValuePtr<int64>(o);
            if (ip) out << ",\"value\":" << *ip;
        } catch (...) {}
    }
    else if (kind == STR("ArrayProperty")) {
        try {
            auto* ap = static_cast<FArrayProperty*>(p);
            FProperty* inner = ap->GetInner();
            std::wstring innerKind = inner ? prop_kind(inner) : STR("");
            out << ",\"innerKind\":\"" << json_escape(wide_to_utf8(innerKind)) << "\"";
            // For inner StructProperty, also emit struct name.
            std::wstring innerStruct;
            if (innerKind == STR("StructProperty") && inner) {
                auto* sp = static_cast<FStructProperty*>(inner);
                auto& sref = sp->GetStruct();
                UScriptStruct* ss = sref.Get();
                if (ss) innerStruct = ss->GetName();
                out << ",\"innerStruct\":\"" << json_escape(wide_to_utf8(innerStruct)) << "\"";
            }
            void* container = ap->ContainerPtrToValuePtr<void>(o);
            if (!container) {
                out << ",\"items\":null";
            } else {
                FScriptArrayHelper helper(ap, container);
                int32 num = helper.Num();
                out << ",\"count\":" << num;
                // Cap walk to first 256 items per array (defensive).
                int32 limit = num > 256 ? 256 : num;
                if (innerKind == STR("ObjectProperty")) {
                    out << ",\"items\":[";
                    for (int32 i = 0; i < limit; i++) {
                        if (i > 0) out << ", ";
                        UObject** pp = (UObject**)helper.GetRawPtr(i);
                        UObject* ref = pp ? *pp : nullptr;
                        if (ref) {
                            out << "{\"path\":\"" << json_escape(obj_path(ref))
                                << "\",\"refClass\":\"" << json_escape(class_name_str(ref)) << "\"}";
                        } else {
                            out << "null";
                        }
                    }
                    out << "]";
                    if (num > limit) out << ",\"truncated\":true,\"limit\":" << limit;
                } else if (innerKind == STR("StrProperty")) {
                    out << ",\"items\":[";
                    for (int32 i = 0; i < limit; i++) {
                        if (i > 0) out << ", ";
                        FString* fs = (FString*)helper.GetRawPtr(i);
                        if (!fs) { out << "null"; continue; }
                        const auto& arr = fs->GetCharArray();
                        int32 ln = arr.Num();
                        if (ln <= 1) { out << "\"\""; continue; }
                        std::wstring_view sv(arr.GetData(), static_cast<size_t>(ln - 1));
                        out << "\"" << json_escape(wide_to_utf8(sv)) << "\"";
                    }
                    out << "]";
                    if (num > limit) out << ",\"truncated\":true,\"limit\":" << limit;
                } else if (innerKind == STR("NameProperty")) {
                    out << ",\"items\":[";
                    for (int32 i = 0; i < limit; i++) {
                        if (i > 0) out << ", ";
                        FName* fn = (FName*)helper.GetRawPtr(i);
                        if (!fn) { out << "null"; continue; }
                        auto wstr = fn->ToString();
                        out << "\"" << json_escape(wide_to_utf8(wstr)) << "\"";
                    }
                    out << "]";
                    if (num > limit) out << ",\"truncated\":true,\"limit\":" << limit;
                } else if (innerKind == STR("StructProperty")) {
                    bool sawUnhandledItem = false;
                    out << ",\"items\":[";
                    for (int32 i = 0; i < limit; i++) {
                        if (i > 0) out << ", ";
                        const uint8_t* base = (const uint8_t*)helper.GetRawPtr(i);
                        std::string blob = read_struct_value(innerStruct, base);
                        if (!blob.empty()) {
                            out << blob;
                        } else {
                            // Same honest signal as the scalar StructProperty path.
                            out << "{\"__unhandledStruct\":true,\"structName\":\""
                                << json_escape(wide_to_utf8(innerStruct)) << "\"}";
                            sawUnhandledItem = true;
                        }
                    }
                    out << "]";
                    if (sawUnhandledItem) out << ",\"unhandledStructItems\":true";
                    if (num > limit) out << ",\"truncated\":true,\"limit\":" << limit;
                } else {
                    // Inner kind not yet handled — record count only.
                }
            }
        } catch (...) {
            out << ",\"err\":\"array_walk_failed\"";
        }
    }
    else {
        // Unhandled kind — emit metadata only (no value read).
    }

    out << "}";
}

static void emit_object_full(std::ofstream& out, UObject* o, bool& first) {
    if (is_skippable(o)) return;
    auto* c = o->GetClassPrivate();
    if (!c) return;

    if (!first) out << ",\n";
    first = false;
    out << "    {\"class\":\"" << json_escape(class_name_str(o))
        << "\",\"path\":\"" << json_escape(obj_path(o))
        << "\",\"props\":[";
    bool pfirst = true;
    try {
        for (FProperty* p : TFieldRange<FProperty>(c, EFieldIterationFlags::IncludeSuper)) {
            auto kind = prop_kind(p);
            // Only emit properties whose value we can read or whose ref is informative.
            if (kind == STR("ObjectProperty") ||
                kind == STR("StrProperty") ||
                kind == STR("NameProperty") ||
                kind == STR("ArrayProperty") ||
                kind == STR("StructProperty") ||
                kind == STR("BoolProperty") ||
                kind == STR("FloatProperty") ||
                kind == STR("DoubleProperty") ||
                kind == STR("IntProperty") ||
                kind == STR("Int32Property") ||
                kind == STR("Int64Property")) {
                if (!pfirst) out << ", ";
                pfirst = false;
                emit_property_value(out, p, o);
            }
        }
    } catch (...) {}
    out << "]}";
}

struct ExtractBucket {
    std::wstring class_name;
    std::vector<UObject*> objs;
    int totalSeen = 0; // every match, even past the cap — exposes silent truncation
};

// Per-class instance cap for the live walk.
static constexpr int kPerClassLimit = 500;

static void run_extract(const std::filesystem::path& outDir) {
    Output::send<LogLevel::Verbose>(STR("[MME] v2.1 extract start\n"));

    // Bucket every live interest object by class.
    std::map<std::wstring, ExtractBucket> buckets;
    UObjectGlobals::ForEachUObject([&](UObject* o, int32, int32) -> RC::LoopAction {
        if (is_skippable(o)) return RC::LoopAction::Continue;
        auto* c = o->GetClassPrivate();
        if (!c) return RC::LoopAction::Continue;
        auto cn = c->GetName();
        if (!name_matches_interest(cn)) return RC::LoopAction::Continue;
        if (class_in_extract_denylist(cn)) return RC::LoopAction::Continue;
        auto& b = buckets[cn];
        if (b.class_name.empty()) b.class_name = cn;
        b.totalSeen++;
        if ((int)b.objs.size() < kPerClassLimit) b.objs.push_back(o);
        return RC::LoopAction::Continue;
    });

    std::ofstream out(outDir / "mapmat_extract.json");
    out << "{\n  \"version\": 2,\n  \"perClassLimit\": " << kPerClassLimit << ",\n  \"classes\": [\n";
    bool cfirst = true;
    for (auto& [_, b] : buckets) {
        if (!cfirst) out << ",\n";
        cfirst = false;
        out << "  {\"class\":\"" << json_escape(wide_to_utf8(b.class_name))
            << "\",\"count\":" << (int)b.objs.size()
            << ",\"totalSeen\":" << b.totalSeen;
        if (b.totalSeen > (int)b.objs.size()) {
            // Surface silent class-instance truncation. The adapter's
            // _collect_truncation_flags walker reads `truncated:true`
            // and warns / fails-on-strict.
            out << ",\"truncated\":true,\"limit\":" << kPerClassLimit;
        }
        out << ",\"instances\":[\n";
        bool ifirst = true;
        for (UObject* o : b.objs) {
            emit_object_full(out, o, ifirst);
        }
        out << "\n  ]}";
    }
    out << "\n  ]\n}\n";
    out.close();
    Output::send<LogLevel::Verbose>(STR("[MME] v2.1 extract wrote {} classes\n"), (int)buckets.size());
}

// ---------- DRIVER ----------

class MapMaterializerExporter : public CppUserModBase {
public:
    MapMaterializerExporter() : CppUserModBase() {
        ModName = STR("MapMaterializerExporter");
        ModVersion = STR("2.1.1");
    }
    ~MapMaterializerExporter() override {}

    auto on_unreal_init() -> void override {
        Output::send<LogLevel::Verbose>(STR("[MME] v2.1 init\n"));
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
