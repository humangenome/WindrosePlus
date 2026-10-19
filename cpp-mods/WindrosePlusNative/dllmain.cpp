#define NOMINMAX
// WindrosePlus native server helper.
//
// Provides server-authoritative admin actions that have no safe Lua path on
// Windrose (the UE4SS Lua game-thread bridge is unavailable on this build).
//
// Threads: on_update runs on a UE4SS thread of its own, not the game thread, so it
// only does file I/O (command file, ban list, result file). Everything that touches
// UObjects is queued and runs from UE4SS's ProcessInternal pre-callback, which fires
// on the game thread while the game runs script code (i.e. while a player is online).
// On an empty server queued jobs wait for the next player.
//
// Command IPC (all under <gameRoot>/windrose_plus_data):
//   wpn_command.txt   - one command, tab-separated: <verb>\t<arg1>\t<arg2>...
//   wpn_result.txt    - written after each command runs
//   wpn_bans.txt      - persisted ban list, one player name per line
//
// Verbs:
//   players                 - list connected players (name, playerId)
//   kick <name> [reason]    - kick a connected player by name
//   ban  <name> [reason]    - add to ban list + kick if present
//   unban <name>            - remove from ban list
//   listbans                - dump the ban list
//
// This mod calls reflected UFunctions only (no engine-internal vtable calls)
// and is intended for the controlled WindrosePlus hosting path, not autoload.

#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UClass.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/FString.hpp>
#include <Unreal/FText.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <windows.h>

#include <cstdint>
#include <algorithm>
#include <atomic>
#include <mutex>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
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

static std::wstring utf8_to_wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    if (n <= 0) return {};
    std::wstring w(n, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

static std::string to_lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c){ return (char)std::tolower(c); });
    return s;
}

static std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return {};
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
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

// Read an FString-typed property by name (in chain) as utf8.
static std::string read_fstring_prop(UObject* o, const TCHAR* propName) {
    if (!o) return {};
    auto* fs = o->GetValuePtrByPropertyNameInChain<FString>(propName);
    if (!fs) return {};
    const auto& arr = fs->GetCharArray();
    int32 num = arr.Num();
    if (num <= 1) return {};
    const TCHAR* data = arr.GetData();
    if (!data) return {};
    return wide_to_utf8(std::wstring_view(data, static_cast<size_t>(num - 1)));
}

static int read_int_prop(UObject* o, const TCHAR* propName, int dflt = -1) {
    if (!o) return dflt;
    auto* ip = o->GetValuePtrByPropertyNameInChain<int32>(propName);
    return ip ? *ip : dflt;
}

// FGameplayAttributeData layout is { float BaseValue; float CurrentValue; }.
// GAS attributes (e.g. on R5WDSAttributeSet) are exposed as a StructProperty of
// this type; read/write the two floats directly at the property offset.
static bool read_attr(UObject* o, const TCHAR* name, float& base, float& current) {
    if (!o) return false;
    auto* p = o->GetValuePtrByPropertyNameInChain<float>(name);
    if (!p) return false;
    base = p[0];
    current = p[1];
    return true;
}

static bool write_attr(UObject* o, const TCHAR* name, float value) {
    if (!o) return false;
    auto* p = o->GetValuePtrByPropertyNameInChain<float>(name);
    if (!p) return false;
    p[0] = value; // BaseValue
    p[1] = value; // CurrentValue (replicated to clients)
    return true;
}

static std::vector<UObject*> collect_live(const TCHAR* className) {
    std::vector<UObject*> live;
    std::vector<UObject*> all;
    try { UObjectGlobals::FindAllOf(className, all); } catch (...) {}
    for (UObject* o : all) {
        if (!o) continue;
        if (o->HasAnyFlags(static_cast<EObjectFlags>(RF_ClassDefaultObject))) continue;
        live.push_back(o);
    }
    return live;
}

struct PlayerInfo {
    UObject* controller = nullptr;
    UObject* playerState = nullptr;
    std::string name;
    int playerId = -1;
};

// Enumerate connected players via their server-side PlayerControllers.
static std::vector<PlayerInfo> collect_players() {
    std::vector<PlayerInfo> out;
    std::vector<UObject*> pcs;
    try {
        UObjectGlobals::FindAllOf(STR("PlayerController"), pcs);
    } catch (...) {}
    for (UObject* pc : pcs) {
        if (!pc) continue;
        if (pc->HasAnyFlags(static_cast<EObjectFlags>(RF_ClassDefaultObject))) continue;
        UObject* ps = nullptr;
        try {
            auto** psp = pc->GetValuePtrByPropertyNameInChain<UObject*>(STR("PlayerState"));
            if (psp) ps = *psp;
        } catch (...) {}
        if (!ps) continue; // no PlayerState -> not a fully joined player
        PlayerInfo pi;
        pi.controller = pc;
        pi.playerState = ps;
        pi.name = read_fstring_prop(ps, STR("PlayerNamePrivate"));
        pi.playerId = read_int_prop(ps, STR("PlayerId"));
        out.push_back(pi);
    }
    return out;
}

// Call APlayerController::ClientReturnToMainMenuWithTextReason(FText) on a PC.
static bool kick_controller(UObject* pc, const std::string& reasonUtf8) {
    if (!pc) return false;
    UFunction* func = pc->GetFunctionByNameInChain(STR("ClientReturnToMainMenuWithTextReason"));
    if (!func) return false;
    struct Params { FText ReturnReason; };
    std::wstring reasonW = utf8_to_wide(reasonUtf8.empty() ? "You have been removed from the server." : reasonUtf8);
    Params params{ FText(reasonW.c_str()) };
    try {
        pc->ProcessEvent(func, &params);
        return true;
    } catch (...) {
        return false;
    }
}

class WindrosePlusNative : public CppUserModBase {
public:
    WindrosePlusNative() : CppUserModBase() {
        ModName = STR("WindrosePlusNative");
        ModVersion = STR("0.3.0");
        m_startedMs = GetTickCount64();
    }
    ~WindrosePlusNative() override {}

    auto on_unreal_init() -> void override {
        // UE4SS's ProcessInternal callback runs on the game thread (it fires whenever the
        // game runs script code, i.e. continuously while a player is online). Everything
        // that touches UObjects runs from here.
        Hook::FCallbackOptions options{};
        options.bReadonly = true;
        options.OwnerModName = STR("WindrosePlusNative");
        options.HookName = STR("GameThreadJobs");
        Hook::RegisterProcessInternalPreCallback(
            [this](Hook::TCallbackIterationData<void>&, UObject*, FFrame&, void*) { run_game_jobs(); },
            options);
        Output::send<LogLevel::Verbose>(STR("[WPN] native helper ready\n"));
    }

    // on_update runs on a UE4SS thread of its own, not the game thread: file I/O only here.
    auto on_update() -> void override {
        ULONGLONG now = GetTickCount64();
        // settle before touching UObjects
        if (now - m_startedMs < 10000) return;

        // poll the command file every 250 ms
        if (now - m_lastPollMs >= 250) {
            m_lastPollMs = now;
            poll_command();
        }
        // enforce the ban list every 10 s - kick any banned player present
        if (now - m_lastBanCheckMs >= 10000) {
            m_lastBanCheckMs = now;
            auto bans = load_bans();
            if (!bans.empty()) {
                bans.insert(bans.begin(), "enforce");
                queue_game_job(std::move(bans));
            }
        }
        flush_result();
    }

private:
    ULONGLONG m_startedMs = 0;
    ULONGLONG m_lastPollMs = 0;
    ULONGLONG m_lastBanCheckMs = 0;

    // Hand-off between on_update (files) and the game thread (UObjects).
    std::mutex m_lock;
    std::vector<std::vector<std::string>> m_jobs;  // verb + args, run on the game thread
    std::atomic<bool> m_jobsPending{false};
    std::string m_result;                          // last result, written to disk by on_update
    bool m_hasResult = false;

    std::filesystem::path data_dir() { return resolve_data_dir(); }

    void queue_game_job(std::vector<std::string> job) {
        std::lock_guard<std::mutex> guard(m_lock);
        // jobs wait while the server is empty: keep only the newest ban sweep
        if (job[0] == "enforce") {
            m_jobs.erase(std::remove_if(m_jobs.begin(), m_jobs.end(),
                [](const std::vector<std::string>& j) { return j[0] == "enforce"; }), m_jobs.end());
        }
        m_jobs.push_back(std::move(job));
        m_jobsPending.store(true);
    }

    // Game thread. Cheap when idle: one atomic load per script call.
    void run_game_jobs() {
        if (!m_jobsPending.load(std::memory_order_relaxed)) return;
        std::vector<std::vector<std::string>> jobs;
        {
            std::lock_guard<std::mutex> guard(m_lock);
            jobs.swap(m_jobs);
            m_jobsPending.store(false);
        }
        for (auto& parts : jobs) {
            const std::string& verb = parts[0];
            try {
                if (verb == "players") {
                    cmd_players();
                } else if (verb == "kick") {
                    cmd_kick(parts[1], parts.size() >= 3 ? parts[2] : "");
                } else if (verb == "ban") {
                    kick_by_name(parts[1], parts.size() >= 3 && !parts[2].empty() ? parts[2] : "You are banned from this server.");
                } else if (verb == "enforce") {
                    std::vector<std::string> bans(parts.begin() + 1, parts.end());
                    for (auto& p : collect_players()) {
                        if (is_banned(to_lower(p.name), bans)) kick_controller(p.controller, "You are banned from this server.");
                    }
                } else if (verb == "wds") {
                    cmd_wds();
                } else if (verb == "setwds") {
                    cmd_setwds(parts[1], parts[2]);
                }
            } catch (...) {
                write_result("error\texception while executing: " + verb);
            }
        }
    }

    // Any thread: keeps the result for on_update to write.
    void write_result(const std::string& body) {
        std::lock_guard<std::mutex> guard(m_lock);
        m_result = body;
        m_hasResult = true;
    }

    void flush_result() {
        std::string body;
        {
            std::lock_guard<std::mutex> guard(m_lock);
            if (!m_hasResult) return;
            body.swap(m_result);
            m_hasResult = false;
        }
        try {
            std::ofstream f(data_dir() / "wpn_result.txt", std::ios::trunc);
            f << body;
            f.close();
        } catch (...) {}
    }

    std::vector<std::string> load_bans() {
        std::vector<std::string> bans;
        try {
            std::ifstream f(data_dir() / "wpn_bans.txt");
            std::string line;
            while (std::getline(f, line)) {
                std::string t = trim(line);
                if (!t.empty()) bans.push_back(t);
            }
        } catch (...) {}
        return bans;
    }

    void save_bans(const std::vector<std::string>& bans) {
        try {
            std::ofstream f(data_dir() / "wpn_bans.txt", std::ios::trunc);
            for (auto& b : bans) f << b << "\n";
            f.close();
        } catch (...) {}
    }

    bool is_banned(const std::string& nameLower, const std::vector<std::string>& bans) {
        for (auto& b : bans) if (to_lower(b) == nameLower) return true;
        return false;
    }

    void poll_command() {
        auto dir = data_dir();
        auto cmdPath = dir / "wpn_command.txt";
        std::string raw;
        try {
            if (!std::filesystem::exists(cmdPath)) return;
            std::ifstream f(cmdPath);
            std::stringstream ss;
            ss << f.rdbuf();
            raw = ss.str();
            f.close();
            std::filesystem::remove(cmdPath);
        } catch (...) { return; }

        raw = trim(raw);
        if (raw.empty()) return;

        // split on tabs
        std::vector<std::string> parts;
        {
            std::stringstream ss(raw);
            std::string item;
            while (std::getline(ss, item, '\t')) parts.push_back(trim(item));
        }
        if (parts.empty()) return;
        std::string verb = to_lower(parts[0]);

        parts[0] = verb;

        // Ban list verbs are file-only and run here; anything that touches UObjects
        // is queued for the game thread (run_game_jobs).
        try {
            if (verb == "ban" && parts.size() >= 2) {
                cmd_ban(parts[1]);
                queue_game_job(std::move(parts));
            } else if (verb == "unban" && parts.size() >= 2) {
                cmd_unban(parts[1]);
            } else if (verb == "listbans") {
                cmd_listbans();
            } else if (verb == "players" || verb == "wds"
                       || (verb == "kick" && parts.size() >= 2)
                       || (verb == "setwds" && parts.size() >= 3)) {
                queue_game_job(std::move(parts));
            } else {
                write_result("error\tunknown or malformed command: " + verb);
            }
        } catch (...) {
            write_result("error\texception while executing: " + verb);
        }
    }

    void cmd_players() {
        auto players = collect_players();
        std::ostringstream o;
        o << "ok\tplayers=" << players.size() << "\n";
        for (auto& p : players) {
            o << "player\t" << p.name << "\tplayerId=" << p.playerId << "\n";
        }
        write_result(o.str());
    }

    int kick_by_name(const std::string& name, const std::string& reason) {
        std::string nl = to_lower(name);
        int kicked = 0;
        for (auto& p : collect_players()) {
            if (to_lower(p.name) == nl) {
                if (kick_controller(p.controller, reason)) kicked++;
            }
        }
        return kicked;
    }

    void cmd_kick(const std::string& name, const std::string& reason) {
        int kicked = kick_by_name(name, reason);
        write_result(kicked > 0 ? ("ok\tkicked " + name) : ("error\tplayer not found: " + name));
    }

    // Adds the name to the ban list; the kick (if present) follows on the game thread.
    void cmd_ban(const std::string& name) {
        auto bans = load_bans();
        if (!is_banned(to_lower(name), bans)) {
            bans.push_back(name);
            save_bans(bans);
        }
        write_result("ok\tbanned " + name);
    }

    void cmd_unban(const std::string& name) {
        auto bans = load_bans();
        std::string nl = to_lower(name);
        size_t before = bans.size();
        bans.erase(std::remove_if(bans.begin(), bans.end(), [&](const std::string& b){ return to_lower(b) == nl; }), bans.end());
        save_bans(bans);
        write_result(bans.size() < before ? ("ok\tunbanned " + name) : ("error\tnot in ban list: " + name));
    }

    void cmd_listbans() {
        auto bans = load_bans();
        std::ostringstream o;
        o << "ok\tbans=" << bans.size() << "\n";
        for (auto& b : bans) o << "ban\t" << b << "\n";
        write_result(o.str());
    }

    // GAS world-difficulty / stat tuning via the R5WDSAttributeSet (exists at boot,
    // independent of connected players). Reads/writes the FGameplayAttributeData floats.
    static constexpr const TCHAR* kWdsAttrs[] = {
        STR("WDSCombatDifficulty"), STR("WDSDamageMultiplier"),
        STR("WDSHealthMultiplier"), STR("WDSCoopHealthMultiplier")
    };

    void cmd_wds() {
        auto sets = collect_live(STR("R5WDSAttributeSet"));
        std::ostringstream o;
        o << "ok\tattributesets=" << sets.size() << "\n";
        int idx = 0;
        for (UObject* s : sets) {
            o << "set\t" << idx++ << "\n";
            for (auto* attr : kWdsAttrs) {
                float base = 0, cur = 0;
                if (read_attr(s, attr, base, cur)) {
                    o << "  attr\t" << wide_to_utf8(attr) << "\tbase=" << base << "\tcurrent=" << cur << "\n";
                }
            }
        }
        write_result(o.str());
    }

    void cmd_setwds(const std::string& attrName, const std::string& valueStr) {
        float value = 0.0f;
        try { value = std::stof(valueStr); } catch (...) { write_result("error\tbad value: " + valueStr); return; }
        std::wstring attrW = utf8_to_wide(attrName);
        auto sets = collect_live(STR("R5WDSAttributeSet"));
        int applied = 0;
        std::ostringstream o;
        for (UObject* s : sets) {
            if (write_attr(s, attrW.c_str(), value)) {
                applied++;
                float base = 0, cur = 0;
                read_attr(s, attrW.c_str(), base, cur);
                o << "  applied\tbase=" << base << "\tcurrent=" << cur << "\n";
            }
        }
        std::ostringstream head;
        head << (applied > 0 ? "ok\t" : "error\t") << "setwds " << attrName << "=" << value
             << " applied to " << applied << "/" << sets.size() << " sets\n";
        write_result(head.str() + o.str());
    }
};

extern "C" __declspec(dllexport) RC::CppUserModBase* start_mod() {
    return new WindrosePlusNative();
}

extern "C" __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod) {
    delete mod;
}
