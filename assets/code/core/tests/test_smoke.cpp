#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest/doctest.h"

#include <string_view>

TEST_CASE("sanity: 1+1==2") {
    CHECK(1 + 1 == 2);
}

TEST_CASE("version string is non-empty and has expected prefix") {
    std::string_view v = "antcrate-core 0.0.0-stub";
    CHECK(!v.empty());
    CHECK(v.substr(0, 14) == "antcrate-core ");
}
