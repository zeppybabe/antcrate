#include <iostream>
#include <string_view>
#include <cstdlib>

static constexpr std::string_view VERSION = "antcrate-core 0.0.0-stub";
static constexpr std::string_view USAGE   = "Usage: antcrate-core [--version | --help]";

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
    std::cerr << "antcrate-core: no subcommand wired (Wave 0 stub)\n";
    return 64;
}
