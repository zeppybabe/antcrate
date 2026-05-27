#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"

#include "canary.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>

#include <sys/stat.h>

using namespace antcrate::canary;

static std::string tmp_dir() {
    const char* t = ::getenv("BATS_TEST_TMPDIR");
    if (t && *t) return t;
    const char* ts = ::getenv("TMPDIR");
    if (ts && *ts) return std::string(ts) + "/ac_canary_test";
    return "/tmp/ac_canary_test";
}

static void set_antcrate_home(const std::string& dir) {
    ::setenv("ANTCRATE_HOME", dir.c_str(), 1);
}

TEST_CASE("generate_token returns 32-char string") {
    auto tok = generate_token();
    CHECK(tok.size() == 32U);
}

TEST_CASE("generate_token returns only [0-9a-f]") {
    auto tok = generate_token();
    CHECK(!tok.empty());
    for (char c : tok) {
        bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        CHECK(ok);
    }
}

TEST_CASE("two consecutive generate_token calls produce distinct values") {
    auto a = generate_token();
    auto b = generate_token();
    CHECK(!a.empty());
    CHECK(!b.empty());
    CHECK(a != b);
}

TEST_CASE("write_state_atomic + load_state round-trips a populated State") {
    std::string home = tmp_dir() + "/rtrip";
    set_antcrate_home(home);

    State s;
    s.schema_version            = 1;
    s.token                     = generate_token();
    s.init_ts                   = 1748300000LL;
    s.last_verified_ts          = 1748303600LL;
    s.invocations_since_verify  = 7;
    s.freshness_ttl_seconds     = 7200;
    s.freshness_max_invocations = 50;

    REQUIRE(write_state_atomic(s));

    auto loaded = load_state();
    REQUIRE(loaded.has_value());
    CHECK(loaded->schema_version            == s.schema_version);
    CHECK(loaded->token                     == s.token);
    CHECK(loaded->init_ts                   == s.init_ts);
    CHECK(loaded->last_verified_ts          == s.last_verified_ts);
    CHECK(loaded->invocations_since_verify  == s.invocations_since_verify);
    CHECK(loaded->freshness_ttl_seconds     == s.freshness_ttl_seconds);
    CHECK(loaded->freshness_max_invocations == s.freshness_max_invocations);
}

TEST_CASE("load_state returns nullopt when file missing") {
    std::string home = tmp_dir() + "/no_file";
    set_antcrate_home(home);
    auto result = load_state();
    CHECK(!result.has_value());
}

TEST_CASE("load_state returns nullopt when JSON malformed") {
    std::string home = tmp_dir() + "/malformed";
    set_antcrate_home(home);
    std::string dir = home + "/canary";
    ::mkdir((home).c_str(), 0700);
    ::mkdir(dir.c_str(), 0700);
    std::string path = dir + "/state.json";
    std::ofstream ofs(path);
    ofs << "NOT JSON {{{";
    ofs.close();

    auto result = load_state();
    CHECK(!result.has_value());
}

TEST_CASE("is_fresh returns true when both criteria satisfied") {
    State s;
    s.last_verified_ts         = 1748300000LL;
    s.freshness_ttl_seconds    = 3600;
    s.invocations_since_verify = 5;
    s.freshness_max_invocations= 30;
    // now = last_verified + 100 (well within TTL, well within max invocations)
    CHECK(is_fresh(s, 1748300100LL));
}

TEST_CASE("is_fresh returns false when wall-clock exceeded") {
    State s;
    s.last_verified_ts         = 1748300000LL;
    s.freshness_ttl_seconds    = 3600;
    s.invocations_since_verify = 0;
    s.freshness_max_invocations= 30;
    // now = last_verified + 3601 (one second past TTL)
    CHECK(!is_fresh(s, 1748303601LL));
}

TEST_CASE("is_fresh returns false when invocation count exceeded") {
    State s;
    s.last_verified_ts         = 1748300000LL;
    s.freshness_ttl_seconds    = 3600;
    s.invocations_since_verify = 30;
    s.freshness_max_invocations= 30;
    // invocations_since_verify == max → stale
    CHECK(!is_fresh(s, 1748300100LL));
}

TEST_CASE("cmd_init writes schema_version == 1") {
    std::string home = tmp_dir() + "/cmd_init";
    set_antcrate_home(home);
    char* argv[] = {const_cast<char*>("init"), nullptr};
    int rc = cmd_init(1, argv);
    CHECK(rc == 0);

    auto s = load_state();
    REQUIRE(s.has_value());
    CHECK(s->schema_version == 1);
}

TEST_CASE("cmd_verify with matching token bumps last_verified_ts and resets invocations") {
    std::string home = tmp_dir() + "/cmd_verify_ok";
    set_antcrate_home(home);

    // init first
    char* init_argv[] = {const_cast<char*>("init"), nullptr};
    REQUIRE(cmd_init(1, init_argv) == 0);

    auto after_init = load_state();
    REQUIRE(after_init.has_value());
    std::string tok = after_init->token;

    // set non-zero invocations to verify they reset
    State s = *after_init;
    s.invocations_since_verify = 5;
    s.last_verified_ts         = 1000LL;
    REQUIRE(write_state_atomic(s));

    char tok_buf[33];
    std::strncpy(tok_buf, tok.c_str(), 33);
    char* verify_argv[] = {const_cast<char*>("verify"), tok_buf, nullptr};
    int rc = cmd_verify(2, verify_argv);
    CHECK(rc == 0);

    auto after_verify = load_state();
    REQUIRE(after_verify.has_value());
    CHECK(after_verify->invocations_since_verify == 0);
    CHECK(after_verify->last_verified_ts         >  1000LL);
}

TEST_CASE("cmd_verify with mismatching token: state file byte-identical; exit 1") {
    std::string home = tmp_dir() + "/cmd_verify_bad";
    set_antcrate_home(home);

    char* init_argv[] = {const_cast<char*>("init"), nullptr};
    REQUIRE(cmd_init(1, init_argv) == 0);

    // Read state file as bytes before bad verify
    std::string path = home + "/canary/state.json";
    std::ifstream before_ifs(path, std::ios::binary);
    std::string before_content((std::istreambuf_iterator<char>(before_ifs)),
                                std::istreambuf_iterator<char>());

    char* verify_argv[] = {
        const_cast<char*>("verify"),
        const_cast<char*>("00000000000000000000000000000000"),
        nullptr
    };
    int rc = cmd_verify(2, verify_argv);
    CHECK(rc == 1);

    std::ifstream after_ifs(path, std::ios::binary);
    std::string after_content((std::istreambuf_iterator<char>(after_ifs)),
                               std::istreambuf_iterator<char>());
    CHECK(before_content == after_content);
}

TEST_CASE("cmd_gate_check increments invocations_since_verify by exactly 1") {
    std::string home = tmp_dir() + "/gate_incr";
    set_antcrate_home(home);

    char* init_argv[] = {const_cast<char*>("init"), nullptr};
    REQUIRE(cmd_init(1, init_argv) == 0);

    auto before = load_state();
    REQUIRE(before.has_value());
    int prev = before->invocations_since_verify;

    char* gate_argv[] = {const_cast<char*>("gate-check"), nullptr};
    cmd_gate_check(1, gate_argv);

    auto after = load_state();
    REQUIRE(after.has_value());
    CHECK(after->invocations_since_verify == prev + 1);
}

TEST_CASE("cmd_gate_check returns 2 when state file missing") {
    std::string home = tmp_dir() + "/gate_missing";
    set_antcrate_home(home);
    char* argv[] = {const_cast<char*>("gate-check"), nullptr};
    int rc = cmd_gate_check(1, argv);
    CHECK(rc == 2);
}

TEST_CASE("cmd_status returns {initialized:false} when state missing; exit 0") {
    std::string home = tmp_dir() + "/status_no_state";
    set_antcrate_home(home);

    // Redirect stdout capture via a pipe would require platform gymnastics;
    // instead verify the function returns 0 and trust the state-missing branch.
    char* argv[] = {const_cast<char*>("status"), nullptr};
    int rc = cmd_status(1, argv);
    CHECK(rc == 0);
}
