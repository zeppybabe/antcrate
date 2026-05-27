#!/usr/bin/env bats
# tests for lib/address.sh — layered positional addressing

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    mkdir -p "$ANTCRATE_HOME"

    # build a fixture tree
    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"/{src/{api,utils},tests,docs}
    touch "$R/Dockerfile" "$R/README.md" "$R/.gitignore"
    touch "$R/src/main.sh" "$R/src/helpers.sh"
    touch "$R/src/api/handler.sh"
    touch "$R/src/utils/io.sh" "$R/src/utils/log.sh"
    touch "$R/tests/test_main.bats"
    touch "$R/docs/intro.md"
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/address.sh"
        '"$1"
}

@test "letters_to_int: a=1, z=26, aa=27, ab=28, ba=53" {
    [ "$(src 'ac_addr_letters_to_int a')" = "1" ]
    [ "$(src 'ac_addr_letters_to_int z')" = "26" ]
    [ "$(src 'ac_addr_letters_to_int aa')" = "27" ]
    [ "$(src 'ac_addr_letters_to_int ab')" = "28" ]
    [ "$(src 'ac_addr_letters_to_int ba')" = "53" ]
}

@test "int_to_letters: round-trip across boundaries" {
    for n in 1 2 25 26 27 28 52 53 702 703; do
        s=$(src "ac_addr_int_to_letters $n")
        back=$(src "ac_addr_letters_to_int $s")
        [ "$back" = "$n" ]
    done
}

@test "decode: 1a3 -> 1 1 3" {
    out=$(src 'ac_addr_decode 1a3' | tr '\n' ' ')
    [ "$out" = "1 1 3 " ]
}

@test "decode: multi-digit and multi-letter segments" {
    out=$(src 'ac_addr_decode 11aa3' | tr '\n' ' ')
    [ "$out" = "11 27 3 " ]
}

@test "decode: rejects invalid characters" {
    run src 'ac_addr_decode "1A3"'
    [ "$status" -ne 0 ]
    run src 'ac_addr_decode "1-2"'
    [ "$status" -ne 0 ]
}

@test "decode: rejects empty input" {
    run src 'ac_addr_decode ""'
    [ "$status" -ne 0 ]
}

@test "resolve: top-level entries (Dockerfile, README, docs, src, tests)" {
    [ "$(src "ac_addr_resolve $R 1")" = "$R/Dockerfile" ]
    [ "$(src "ac_addr_resolve $R 2")" = "$R/README.md" ]
    [ "$(src "ac_addr_resolve $R 3")" = "$R/docs" ]
    [ "$(src "ac_addr_resolve $R 4")" = "$R/src" ]
    [ "$(src "ac_addr_resolve $R 5")" = "$R/tests" ]
}

@test "resolve: descend into src — 4a, 4b, 4c, 4d" {
    [ "$(src "ac_addr_resolve $R 4a")" = "$R/src/api" ]
    [ "$(src "ac_addr_resolve $R 4b")" = "$R/src/helpers.sh" ]
    [ "$(src "ac_addr_resolve $R 4c")" = "$R/src/main.sh" ]
    [ "$(src "ac_addr_resolve $R 4d")" = "$R/src/utils" ]
}

@test "resolve: deep address 4a1, 4d2" {
    [ "$(src "ac_addr_resolve $R 4a1")" = "$R/src/api/handler.sh" ]
    [ "$(src "ac_addr_resolve $R 4d2")" = "$R/src/utils/log.sh" ]
}

@test "resolve: errors when index out of range" {
    run src "ac_addr_resolve $R 99"
    [ "$status" -ne 0 ]
}

@test "resolve: errors when descending into a file" {
    run src "ac_addr_resolve $R 1a"
    [ "$status" -ne 0 ]
}

@test "resolve: hidden files filtered by default" {
    # .gitignore exists but is filtered, so addresses skip past it
    [ "$(src "ac_addr_resolve $R 1")" = "$R/Dockerfile" ]
}

@test "resolve: hidden files included when ANTCRATE_ADDR_INCLUDE_HIDDEN=1" {
    out=$(ANTCRATE_ADDR_INCLUDE_HIDDEN=1 bash -c '
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/address.sh"
        ac_addr_resolve "'"$R"'" 1
    ')
    [ "$out" = "$R/.gitignore" ]
}

@test "render_tree: every entry gets an address" {
    out=$(src "ac_addr_render_tree $R")
    [[ "$out" == *"4	src"* ]]
    [[ "$out" == *"4a	src/api"* ]]
    [[ "$out" == *"4d2	src/utils/log.sh"* ]]
    [[ "$out" == *"5a	tests/test_main.bats"* ]]
}
