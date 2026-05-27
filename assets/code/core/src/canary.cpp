#include "canary.hpp"
#include "json.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

using json = nlohmann::json;

namespace antcrate::canary {

namespace {

// RAII guard for a raw file descriptor.
struct FdGuard {
    int fd{-1};
    explicit FdGuard(int f) : fd(f) {}
    ~FdGuard() { if (fd >= 0) ::close(fd); }
    FdGuard(const FdGuard&)            = delete;
    FdGuard& operator=(const FdGuard&) = delete;
};

// mkdir -p for a single path; ignores EEXIST at every component.
void mkdir_p(const std::string& path) {
    std::string buf;
    for (std::size_t i = 0; i < path.size(); ++i) {
        buf += path[i];
        if ((path[i] == '/' && i != 0) || i + 1 == path.size()) {
            if (::mkdir(buf.c_str(), 0700) != 0 && errno != EEXIST) {
                throw std::runtime_error(
                    std::string("mkdir(") + buf + "): " + ::strerror(errno));
            }
        }
    }
}

int64_t now_seconds() {
    return static_cast<int64_t>(::time(nullptr));
}

} // anonymous namespace

// ─── token generation ────────────────────────────────────────────────────────

std::string generate_token() {
    FdGuard urand{::open("/dev/urandom", O_RDONLY)};
    if (urand.fd < 0) {
        return {};
    }

    unsigned char buf[kTokenBytes];
    int total = 0;
    while (total < kTokenBytes) {
        int n = static_cast<int>(
            ::read(urand.fd, buf + total,
                   static_cast<std::size_t>(kTokenBytes - total)));
        if (n <= 0) return {};
        total += n;
    }

    char hex[kTokenHexChars + 1];
    for (int i = 0; i < kTokenBytes; ++i) {
        // NOLINTNEXTLINE(cppcoreguidelines-pro-type-vararg)
        std::snprintf(hex + 2 * i, 3, "%02x",
                      static_cast<unsigned int>(buf[i]));
    }
    return {hex, kTokenHexChars};
}

// ─── state path ──────────────────────────────────────────────────────────────

std::string state_path() {
    const char* home_override = ::getenv("ANTCRATE_HOME");
    std::string base;
    if (home_override && *home_override) {
        base = home_override;
    } else {
        const char* home = ::getenv("HOME");
        if (!home || !*home) return {};
        base = std::string(home) + "/.antcrate";
    }
    return base + "/canary/state.json";
}

// ─── state I/O ───────────────────────────────────────────────────────────────

std::optional<State> load_state() {
    std::string path = state_path();
    if (path.empty()) return std::nullopt;

    std::ifstream ifs(path);
    if (!ifs.is_open()) return std::nullopt;

    try {
        json j = json::parse(ifs);
        State s;
        s.schema_version           = j.at("schema_version").get<int>();
        s.token                    = j.at("token").get<std::string>();
        s.init_ts                  = j.at("init_ts").get<int64_t>();
        s.last_verified_ts         = j.at("last_verified_ts").get<int64_t>();
        s.invocations_since_verify = j.at("invocations_since_verify").get<int>();
        s.freshness_ttl_seconds    = j.at("freshness_ttl_seconds").get<int>();
        s.freshness_max_invocations= j.at("freshness_max_invocations").get<int>();
        return s;
    } catch (const json::exception&) {
        return std::nullopt;
    }
}

bool write_state_atomic(const State& s) {
    std::string path = state_path();
    if (path.empty()) return false;

    // mkdir -p parent
    std::string parent = path.substr(0, path.rfind('/'));
    try {
        mkdir_p(parent);
    } catch (...) {
        return false;
    }

    std::string tmp_path = path + ".tmp." + std::to_string(::getpid());

    {
        std::ofstream ofs(tmp_path);
        if (!ofs.is_open()) return false;

        json j;
        j["schema_version"]            = s.schema_version;
        j["token"]                     = s.token;
        j["init_ts"]                   = s.init_ts;
        j["last_verified_ts"]          = s.last_verified_ts;
        j["invocations_since_verify"]  = s.invocations_since_verify;
        j["freshness_ttl_seconds"]     = s.freshness_ttl_seconds;
        j["freshness_max_invocations"] = s.freshness_max_invocations;
        ofs << j.dump(2) << '\n';
        ofs.flush();
        if (!ofs.good()) {
            (void)::unlink(tmp_path.c_str());
            return false;
        }
    }

    if (::rename(tmp_path.c_str(), path.c_str()) != 0) {
        (void)::unlink(tmp_path.c_str());
        return false;
    }
    return true;
}

// ─── freshness check ─────────────────────────────────────────────────────────

bool is_fresh(const State& s, int64_t now) {
    // >= so that TTL=0 means "stale on the very next check" (test #9).
    // For non-zero TTL the boundary is unchanged in practice (sub-second
    // operations are dominated by other latency).
    if (now - s.last_verified_ts >= static_cast<int64_t>(s.freshness_ttl_seconds))
        return false;
    if (s.invocations_since_verify >= s.freshness_max_invocations)
        return false;
    return true;
}

// ─── subcommands ─────────────────────────────────────────────────────────────

int cmd_init(int argc, char* argv[]) {
    int ttl  = kDefaultTtlSeconds;
    int maxv = kDefaultMaxInvocations;
    bool with_claudemd = false;

    for (int i = 1; i < argc; ++i) {
        std::string a{argv[i]};
        if (a == "--ttl-seconds" && i + 1 < argc) {
            ttl = std::stoi(argv[++i]);
        } else if (a == "--max-invocations" && i + 1 < argc) {
            maxv = std::stoi(argv[++i]);
        } else if (a == "--with-claudemd") {
            with_claudemd = true;
        }
    }

    std::string tok = generate_token();
    if (tok.empty()) {
        std::cerr << "antcrate-core: cannot read /dev/urandom\n";
        return 1;
    }

    int64_t now = now_seconds();
    State s;
    s.schema_version            = 1;
    s.token                     = tok;
    s.init_ts                   = now;
    s.last_verified_ts          = now;
    s.invocations_since_verify  = 0;
    s.freshness_ttl_seconds     = ttl;
    s.freshness_max_invocations = maxv;

    if (!write_state_atomic(s)) {
        std::cerr << "antcrate-core: failed to write state\n";
        return 1;
    }

    std::cout << tok << '\n';

    if (with_claudemd) {
        // Signal to the Bash layer so it can patch CLAUDE.md
        std::cout << "__WITH_CLAUDEMD__\n";
    }

    return 0;
}

int cmd_verify(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "antcrate-core: canary verify requires <token>\n";
        return 1;
    }
    std::string provided{argv[1]};

    auto maybe = load_state();
    if (!maybe) {
        std::cerr << "antcrate-core: no canary state — run 'antcrate --canary-init' first\n";
        return 1;
    }

    State s = *maybe;
    if (s.token != provided) {
        std::cerr << "antcrate-core: token mismatch — not verified\n";
        return 1;
    }

    s.last_verified_ts        = now_seconds();
    s.invocations_since_verify = 0;

    if (!write_state_atomic(s)) {
        std::cerr << "antcrate-core: failed to persist verification\n";
        return 1;
    }

    std::cout << "canary: verified\n";
    return 0;
}

int cmd_gate_check(int /*argc*/, char* /*argv*/[]) {
    auto maybe = load_state();
    if (!maybe) {
        return 2;
    }

    State s = *maybe;
    s.invocations_since_verify += 1;

    if (!write_state_atomic(s)) {
        // best-effort; don't block operations on a write failure
        std::cerr << "antcrate-core: warning: could not persist gate-check counter\n";
    }

    // Runtime env-var override: ANTCRATE_CANARY_TTL_SECONDS / MAX_INVOCATIONS
    // take precedence over state-stored values for the freshness check. This
    // lets users (and tests) tighten freshness without re-init'ing state.
    State check_state = s;
    if (const char* env_ttl = ::getenv("ANTCRATE_CANARY_TTL_SECONDS")) {
        try { check_state.freshness_ttl_seconds = std::stoi(env_ttl); } catch (...) {}
    }
    if (const char* env_max = ::getenv("ANTCRATE_CANARY_MAX_INVOCATIONS")) {
        try { check_state.freshness_max_invocations = std::stoi(env_max); } catch (...) {}
    }

    if (!is_fresh(check_state, now_seconds())) {
        return 4;
    }
    return 0;
}

int cmd_status(int /*argc*/, char* /*argv*/[]) {
    auto maybe = load_state();
    if (!maybe) {
        std::cout << R"({"initialized":false})" << '\n';
        return 0;
    }

    const State& s = *maybe;
    json j;
    j["initialized"]              = true;
    j["schema_version"]           = s.schema_version;
    j["token"]                    = s.token;
    j["init_ts"]                  = s.init_ts;
    j["last_verified_ts"]         = s.last_verified_ts;
    j["invocations_since_verify"] = s.invocations_since_verify;
    j["freshness_ttl_seconds"]    = s.freshness_ttl_seconds;
    j["freshness_max_invocations"]= s.freshness_max_invocations;
    std::cout << j.dump(2) << '\n';
    return 0;
}

} // namespace antcrate::canary
