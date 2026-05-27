cmake_minimum_required(VERSION 3.20)
project(antcrate_core LANGUAGES CXX VERSION 0.0.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(-Wall -Wextra -Wpedantic -Werror)
add_compile_definitions(_POSIX_C_SOURCE=200809L _XOPEN_SOURCE=700)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Static library of all non-main translation units — avoids duplicate compilation
# when linking both the executable and the test binary.
add_library(antcrate_core_lib STATIC
    src/canary.cpp
)
target_include_directories(antcrate_core_lib PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_compile_options(antcrate_core_lib PRIVATE -Wall -Wextra -Wpedantic -Werror)

add_executable(antcrate_core src/main.cpp)
target_link_libraries(antcrate_core PRIVATE antcrate_core_lib)
set_target_properties(antcrate_core PROPERTIES OUTPUT_NAME antcrate-core)

enable_testing()
add_subdirectory(tests)

install(TARGETS antcrate_core RUNTIME DESTINATION bin)
