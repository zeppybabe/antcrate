#include "canary.hpp"

#include <iostream>
#include <string_view>
#include <cstdlib>

static constexpr std::string_view VERSION = "antcrate-core 0.1.0";
static constexpr std::string_view USAGE   =
    "Usage: antcrate-core [--version | --help | canary <init|verify|gate-check|status> ...]";

int main(int argc, char* argv[])
{
    if (argc == 2) {
        std::string_view arg{argv[1]};
        if (arg == "--version") {
            std::cout << VERSION << '\n';
            return EXIT_SUCCESS;
        }
        if (arg == "--help") {
            std::cout << USAGE << '\n';
            return EXIT_SUCCESS;
        }
    }

    if (argc >= 3) {
        std::string_view a1{argv[1]};
        if (a1 == "canary") {
            std::string_view a2{argv[2]};
            if (a2 == "init")
                return antcrate::canary::cmd_init(argc - 2, argv + 2);
            if (a2 == "verify")
                return antcrate::canary::cmd_verify(argc - 2, argv + 2);
            if (a2 == "gate-check")
                return antcrate::canary::cmd_gate_check(argc - 2, argv + 2);
            if (a2 == "status")
                return antcrate::canary::cmd_status(argc - 2, argv + 2);
            std::cerr << "antcrate-core: unknown canary subcommand: " << a2 << '\n';
            return 64;
        }
    }

    std::cerr << "antcrate-core: unknown command (see --help)\n";
    return 64;
}
