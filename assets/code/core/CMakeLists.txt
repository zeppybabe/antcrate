cmake_minimum_required(VERSION 3.20)
project(antcrate_core LANGUAGES CXX VERSION 0.0.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-Wall -Wextra -Wpedantic -Werror)
add_compile_definitions(_POSIX_C_SOURCE=200809L _XOPEN_SOURCE=700)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_executable(antcrate_core src/main.cpp)
set_target_properties(antcrate_core PROPERTIES OUTPUT_NAME antcrate-core)

enable_testing()
add_subdirectory(tests)

install(TARGETS antcrate_core RUNTIME DESTINATION bin)
