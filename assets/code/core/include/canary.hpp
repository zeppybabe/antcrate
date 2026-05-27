#pragma once
#include <cstdint>
#include <optional>
#include <string>

namespace antcrate::canary {

static constexpr int     kTokenBytes          = 16;
static constexpr int     kTokenHexChars       = 32;
static constexpr int     kDefaultTtlSeconds   = 3600;
static constexpr int     kDefaultMaxInvocations = 30;

struct State {
    int         schema_version{1};
    std::string token;
    int64_t     init_ts{0};
    int64_t     last_verified_ts{0};
    int         invocations_since_verify{0};
    int         freshness_ttl_seconds{kDefaultTtlSeconds};
    int         freshness_max_invocations{kDefaultMaxInvocations};
};

std::string          generate_token();
std::string          state_path();
std::optional<State> load_state();
bool                 write_state_atomic(const State& s);
bool                 is_fresh(const State& s, int64_t now);

int cmd_init(int argc, char* argv[]);
int cmd_verify(int argc, char* argv[]);
int cmd_gate_check(int argc, char* argv[]);
int cmd_status(int argc, char* argv[]);

} // namespace antcrate::canary
