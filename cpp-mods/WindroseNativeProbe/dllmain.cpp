#define NOMINMAX
// Read-only native UObject probe for WindrosePlus.
//
// Trigger:
//   <gameRoot>/windrose_plus_data/native_probe_trigger
//
// Output:
//   <gameRoot>/windrose_plus_data/native_probe.json
//   <gameRoot>/windrose_plus_data/native_probe_done
//
// This mod deliberately does not call gameplay UFunctions or mutate UObject
// state. It exists to inspect classes that can hang the UE4SS Lua bridge when
// walked from Lua, especially player, inventory, storage, and progression types.

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
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <vector>

using namespace RC;
using namespace RC::Unreal;

static std::string wide_to_utf8(std::wstring_view w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string s(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if ((unsigned char)c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

static std::string q(const std::string& s) {
    return "\"" + json_escape(s) + "\"";
}

static std::string fmt_double(double d) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.9g", d);
    return buf;
}

static std::string obj_path(UObject* o) {
    if (!o) return {};
    return wide_to_utf8(o->GetPathName());
}

static std::string class_name_str(UObject* o) {
    if (!o) return "(null)";
    auto* c = o->GetClassPrivate();
    return c ? wide_to_utf8(c->GetName()) : "(noclass)";
}

static bool is_skippable(UObject* o) {
    if (!o) return true;
    if (o->HasAnyFlags(static_cast<EObjectFlags>(RF_ClassDefaultObject))) return true;
    if (o->HasAnyFlags(static_cast<EObjectFlags>(RF_BeginDestroyed | RF_FinishDestroyed))) return true;
    return false;
}

static std::wstring prop_kind(FProperty* p) {
    auto fc = p->GetClass();
    return fc.GetFName().ToString();
}

static std::filesystem::path resolve_data_dir() {
    std::filesystem::path candidates[] = {
        "../../../windrose_plus_data",
        "windrose_plus_data",
    };
    for (auto& p : candidates) {
        try {
            if (std::filesystem::exists(p)) return p;
        } catch (...) {}
    }
    try { std::filesystem::create_directories("windrose_plus_data"); } catch (...) {}
    return "windrose_plus_data";
}

struct InterestToken {
    std::wstring token;
    int priority;
};

static const std::vector<InterestToken> kInterestTokens = {
    {STR("BP_R5"), 0}, {STR("R5Player"), 0}, {STR("R5GameMode"), 0},
    {STR("R5GameState"), 0}, {STR("R5BL"), 0},

    {STR("PlayerController"), 10}, {STR("PlayerState"), 10},
    {STR("Character"), 10}, {STR("Pawn"), 10}, {STR("Controller"), 10},
    {STR("Unique"), 10}, {STR("Session"), 10}, {STR("Net"), 10},
    {STR("Ban"), 10}, {STR("Kick"), 10},

    {STR("Inventory"), 20}, {STR("Storage"), 20}, {STR("Container"), 20},
    {STR("Chest"), 20}, {STR("Proximity"), 20}, {STR("BuildingCenter"), 20},
    {STR("Requirement"), 20}, {STR("BusinessRule"), 20},

    {STR("Item"), 30}, {STR("Progression"), 30}, {STR("Experience"), 30},
    {STR("Talent"), 30}, {STR("Stat"), 30}, {STR("Attribute"), 30},

    {STR("Chat"), 40}, {STR("Message"), 40}, {STR("Notification"), 40},
    {STR("HUD"), 40}, {STR("Interaction"), 40}, {STR("Interact"), 40},

    {STR("GameplayAbility"), 60}, {STR("Ability"), 80}
};

static int class_priority(const std::wstring& n) {
    int best = 1000;
    for (const auto& tok : kInterestTokens) {
        if (n.find(tok.token) != std::wstring::npos && tok.priority < best) {
            best = tok.priority;
        }
    }
    return best;
}

static bool interesting_class_name(const std::wstring& n) {
    return class_priority(n) < 1000;
}

static bool read_fstring(FProperty* p, UObject* o, std::string& out) {
    auto* fs = p->ContainerPtrToValuePtr<FString>(o);
    if (!fs) return false;
    const auto& arr = fs->GetCharArray();
    int32 num = arr.Num();
    if (num <= 1) {
        out.clear();
        return true;
    }
    const TCHAR* data = arr.GetData();
    if (!data) return false;
    out = wide_to_utf8(std::wstring_view(data, static_cast<size_t>(num - 1)));
    return true;
}

static bool read_fname(FProperty* p, UObject* o, std::string& out) {
    auto* fn = p->ContainerPtrToValuePtr<FName>(o);
    if (!fn) return false;
    out = wide_to_utf8(fn->ToString());
    return true;
}

static UObject* read_object_ref(FProperty* p, UObject* o) {
    auto** pp = p->ContainerPtrToValuePtr<UObject*>(o);
    if (!pp) return nullptr;
    return *pp;
}

static void emit_simple_value(std::ofstream& out, FProperty* p, UObject* o) {
    std::wstring kind = prop_kind(p);
    if (kind == STR("BoolProperty")) {
        try {
            auto* bp = static_cast<FBoolProperty*>(p);
            void* container = p->ContainerPtrToValuePtr<void>(o);
            out << (container && bp->GetPropertyValue(container) ? "true" : "false");
        } catch (...) {
            out << "null";
        }
    } else if (kind == STR("FloatProperty")) {
        try {
            const float* fp = p->ContainerPtrToValuePtr<float>(o);
            if (fp) out << fmt_double((double)*fp);
            else out << "null";
        } catch (...) {
            out << "null";
        }
    } else if (kind == STR("DoubleProperty")) {
        try {
            const double* dp = p->ContainerPtrToValuePtr<double>(o);
            if (dp) out << fmt_double(*dp);
            else out << "null";
        } catch (...) {
            out << "null";
        }
    } else if (kind == STR("IntProperty") || kind == STR("Int32Property")) {
        try {
            const int32* ip = p->ContainerPtrToValuePtr<int32>(o);
            if (ip) out << *ip;
            else out << "null";
        } catch (...) {
            out << "null";
        }
    } else if (kind == STR("Int64Property")) {
        try {
            const int64* ip = p->ContainerPtrToValuePtr<int64>(o);
            if (ip) out << *ip;
            else out << "null";
        } catch (...) {
            out << "null";
        }
    } else if (kind == STR("ByteProperty")) {
        try {
            const uint8_t* bp = p->ContainerPtrToValuePtr<uint8_t>(o);
            if (bp) out << (uint32_t)*bp;
            else out << "null";
        } catch (...) {
            out << "null";
        }
    } else if (kind == STR("StrProperty")) {
        std::string s;
        if (read_fstring(p, o, s)) out << q(s);
        else out << "null";
    } else if (kind == STR("NameProperty")) {
        std::string s;
        if (read_fname(p, o, s)) out << q(s);
        else out << "null";
    } else {
        out << "null";
    }
}

static bool is_simple_kind(const std::wstring& kind) {
    return kind == STR("BoolProperty") ||
           kind == STR("FloatProperty") ||
           kind == STR("DoubleProperty") ||
           kind == STR("IntProperty") ||
           kind == STR("Int32Property") ||
           kind == STR("Int64Property") ||
           kind == STR("ByteProperty") ||
           kind == STR("StrProperty") ||
           kind == STR("NameProperty");
}

static void emit_ref_summary(std::ofstream& out, UObject* ref, int maxProps) {
    out << "{";
    out << "\"path\":" << q(obj_path(ref))
        << ",\"class\":" << q(class_name_str(ref));
    if (!ref || is_skippable(ref)) {
        out << ",\"skipped\":true}";
        return;
    }
    UClass* c = ref->GetClassPrivate();
    out << ",\"simpleProps\":[";
    bool first = true;
    int emitted = 0;
    try {
        for (FProperty* p : TFieldRange<FProperty>(c, EFieldIterationFlags::IncludeSuper)) {
            if (emitted >= maxProps) break;
            std::wstring kind = prop_kind(p);
            if (!is_simple_kind(kind)) continue;
            if (!first) out << ",";
            first = false;
            emitted++;
            out << "{\"name\":" << q(wide_to_utf8(p->GetName()))
                << ",\"type\":" << q(wide_to_utf8(kind))
                << ",\"value\":";
            emit_simple_value(out, p, ref);
            out << "}";
        }
    } catch (...) {}
    out << "]";
    if (emitted >= maxProps) out << ",\"truncated\":true";
    out << "}";
}

static void emit_props(std::ofstream& out, UClass* c, UObject* sample) {
    out << "[";
    bool first = true;
    int emitted = 0;
    const int maxProps = 260;
    try {
        for (FProperty* p : TFieldRange<FProperty>(c, EFieldIterationFlags::IncludeSuper)) {
            if (emitted >= maxProps) break;
            if (!first) out << ",";
            first = false;
            emitted++;

            std::wstring kind = prop_kind(p);
            out << "{\"name\":" << q(wide_to_utf8(p->GetName()))
                << ",\"type\":" << q(wide_to_utf8(kind))
                << ",\"offset\":" << (int32)p->GetOffset_Internal()
                << ",\"size\":" << (int32)p->GetElementSize();

            if (sample && !is_skippable(sample)) {
                if (is_simple_kind(kind)) {
                    out << ",\"value\":";
                    emit_simple_value(out, p, sample);
                } else if (kind == STR("ObjectProperty")) {
                    try {
                        UObject* ref = read_object_ref(p, sample);
                        if (ref) {
                            out << ",\"ref\":";
                            emit_ref_summary(out, ref, 48);
                        } else {
                            out << ",\"ref\":null";
                        }
                    } catch (...) {}
                } else if (kind == STR("ArrayProperty")) {
                    try {
                        auto* ap = static_cast<FArrayProperty*>(p);
                        FProperty* inner = ap->GetInner();
                        std::wstring innerKind = inner ? prop_kind(inner) : STR("");
                        out << ",\"innerType\":" << q(wide_to_utf8(innerKind));
                        void* container = ap->ContainerPtrToValuePtr<void>(sample);
                        if (container) {
                            FScriptArrayHelper helper(ap, container);
                            out << ",\"count\":" << helper.Num();
                        }
                    } catch (...) {}
                }
            }
            out << "}";
        }
    } catch (...) {}
    if (emitted >= maxProps) {
        out << ",{\"truncated\":true,\"limit\":" << maxProps << "}";
    }
    out << "]";
}

static void emit_funcs(std::ofstream& out, UClass* c) {
    out << "[";
    bool first = true;
    int emitted = 0;
    const int maxFuncs = 320;
    try {
        for (UFunction* f : TFieldRange<UFunction>(c, EFieldIterationFlags::IncludeSuper)) {
            if (emitted >= maxFuncs) break;
            if (!first) out << ",";
            first = false;
            emitted++;

            uint32 flags = 0;
            try { flags = f->GetFunctionFlags(); } catch (...) {}
            out << "{\"name\":" << q(wide_to_utf8(f->GetName()))
                << ",\"flags\":" << flags
                << ",\"net\":" << ((flags & FUNC_Net) ? "true" : "false")
                << ",\"server\":" << ((flags & FUNC_NetServer) ? "true" : "false")
                << ",\"client\":" << ((flags & FUNC_NetClient) ? "true" : "false")
                << ",\"multicast\":" << ((flags & FUNC_NetMulticast) ? "true" : "false")
                << ",\"params\":[";

            bool pfirst = true;
            try {
                for (FProperty* p : TFieldRange<FProperty>(f, EFieldIterationFlags::None)) {
                    if (!pfirst) out << ",";
                    pfirst = false;
                    std::wstring kind = prop_kind(p);
                    out << "{\"name\":" << q(wide_to_utf8(p->GetName()))
                        << ",\"type\":" << q(wide_to_utf8(kind)) << "}";
                }
            } catch (...) {}
            out << "]}";
        }
    } catch (...) {}
    if (emitted >= maxFuncs) {
        out << ",{\"truncated\":true,\"limit\":" << maxFuncs << "}";
    }
    out << "]";
}

struct ClassBucket {
    std::wstring class_name;
    int total = 0;
    int live = 0;
    UObject* sample_live = nullptr;
    UObject* sample_any = nullptr;
};

static void run_probe(const std::filesystem::path& outDir) {
    Output::send<LogLevel::Verbose>(STR("[WNP] native probe start\n"));

    std::map<std::wstring, ClassBucket> buckets;
    UObjectGlobals::ForEachUObject([&](UObject* o, int32, int32) -> RC::LoopAction {
        auto* c = o->GetClassPrivate();
        if (!c) return RC::LoopAction::Continue;
        auto cn = c->GetName();
        if (!interesting_class_name(cn)) return RC::LoopAction::Continue;
        auto& b = buckets[cn];
        if (b.class_name.empty()) b.class_name = cn;
        b.total++;
        if (!b.sample_any) b.sample_any = o;
        if (!is_skippable(o)) {
            b.live++;
            if (!b.sample_live) b.sample_live = o;
        }
        return RC::LoopAction::Continue;
    });

    std::vector<ClassBucket*> ordered;
    ordered.reserve(buckets.size());
    for (auto& [_, b] : buckets) ordered.push_back(&b);
    std::sort(ordered.begin(), ordered.end(), [](const ClassBucket* a, const ClassBucket* b) {
        int ap = class_priority(a->class_name);
        int bp = class_priority(b->class_name);
        if (ap != bp) return ap < bp;
        if ((a->live > 0) != (b->live > 0)) return a->live > 0;
        if (a->live != b->live) return a->live > b->live;
        if (a->total != b->total) return a->total > b->total;
        return a->class_name < b->class_name;
    });

    std::filesystem::path tmpPath = outDir / "native_probe.json.tmp";
    std::filesystem::path outPath = outDir / "native_probe.json";
    std::ofstream out(tmpPath);
    out << "{\n";
    out << "  \"version\": 1,\n";
    out << "  \"readOnly\": true,\n";
    out << "  \"classCount\": " << buckets.size() << ",\n";
    out << "  \"classIndex\": [\n";
    bool indexFirst = true;
    for (auto* bp : ordered) {
        if (!bp) continue;
        if (!indexFirst) out << ",\n";
        indexFirst = false;
        out << "    {\"class\":" << q(wide_to_utf8(bp->class_name))
            << ",\"countTotal\":" << bp->total
            << ",\"countLive\":" << bp->live
            << ",\"priority\":" << class_priority(bp->class_name) << "}";
    }
    out << "\n  ],\n";
    out << "  \"classes\": [\n";

    bool first = true;
    int emitted = 0;
    const int maxClasses = 320;
    for (auto* bp : ordered) {
        if (emitted >= maxClasses) break;
        if (!bp) continue;
        ClassBucket& b = *bp;
        UObject* sample = b.sample_live ? b.sample_live : b.sample_any;
        UClass* sc = sample ? sample->GetClassPrivate() : nullptr;
        if (!sc) continue;

        if (!first) out << ",\n";
        first = false;
        emitted++;

        out << "    {\"class\":" << q(wide_to_utf8(b.class_name))
            << ",\"countTotal\":" << b.total
            << ",\"countLive\":" << b.live
            << ",\"priority\":" << class_priority(b.class_name);
        if (sample) {
            out << ",\"samplePath\":" << q(obj_path(sample))
                << ",\"sampleIsCDO\":" << (b.sample_live ? "false" : "true");
        }
        out << ",\"props\":";
        emit_props(out, sc, sample);
        out << ",\"funcs\":";
        emit_funcs(out, sc);
        out << "}";
    }
    out << "\n  ]";
    out << ",\n  \"emittedClassCount\": " << emitted;
    if (emitted >= maxClasses) {
        out << ",\n  \"truncatedClasses\": true,\n  \"truncatedDetailedClasses\": true,\n  \"classLimit\": " << maxClasses
            << ",\n  \"omittedDetailedClassCount\": " << (ordered.size() - emitted);
    }
    out << "\n}\n";
    out.close();

    std::error_code ec;
    std::filesystem::remove(outPath, ec);
    ec.clear();
    std::filesystem::rename(tmpPath, outPath, ec);
    if (ec) {
        std::filesystem::copy_file(tmpPath, outPath, std::filesystem::copy_options::overwrite_existing, ec);
        std::filesystem::remove(tmpPath, ec);
    }
    std::ofstream done(outDir / "native_probe_done");
    done << "ok\n";
    done.close();
    Output::send<LogLevel::Verbose>(STR("[WNP] native probe wrote {} classes\n"), emitted);
}

class WindroseNativeProbe : public CppUserModBase {
public:
    WindroseNativeProbe() : CppUserModBase() {
        ModName = STR("WindroseNativeProbe");
        ModVersion = STR("1.0.1");
        m_startedMs = GetTickCount64();
    }

    ~WindroseNativeProbe() override {}

    auto on_unreal_init() -> void override {
        Output::send<LogLevel::Verbose>(STR("[WNP] read-only native probe ready\n"));
    }

    auto on_update() -> void override {
        m_frameCount++;
        if (GetTickCount64() - m_startedMs < 30000) return;
        if (m_frameCount % 300 != 0) return;
        auto outDir = resolve_data_dir();
        auto trigger = outDir / "native_probe_trigger";
        try {
            if (!std::filesystem::exists(trigger)) return;
            std::filesystem::remove(trigger);
            std::error_code ec;
            std::filesystem::remove(outDir / "native_probe_done", ec);
            run_probe(outDir);
        } catch (...) {
            try {
                std::ofstream err(outDir / "native_probe_error");
                err << "probe failed\n";
                err.close();
            } catch (...) {}
        }
    }

private:
    int m_frameCount = 0;
    ULONGLONG m_startedMs = 0;
};

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod() {
    return new WindroseNativeProbe();
}

extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod) {
    delete mod;
}
