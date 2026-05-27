add_executable(test_smoke test_smoke.cpp)
target_include_directories(test_smoke PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/doctest
)
target_compile_options(test_smoke PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME smoke COMMAND test_smoke)

add_executable(test_canary test_canary.cpp)
target_include_directories(test_canary PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/doctest
)
target_link_libraries(test_canary PRIVATE antcrate_core_lib)
target_compile_options(test_canary PRIVATE -Wall -Wextra -Wpedantic -Werror)
add_test(NAME canary COMMAND test_canary)
