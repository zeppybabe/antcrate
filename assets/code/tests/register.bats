#!/usr/bin/env bats
# tests for ac_action_register

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    EXISTING="$BATS_TEST_TMPDIR/existing-tree"
    mkdir -p "$EXISTING/src"
    touch "$EXISTING/README.md"
    export EXISTING
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/scaffold.sh"
        '"$1"
}

@test "register: adds entry for an existing tree" {
    run src "ac_action_register myproj $EXISTING"
    [ "$status" -eq 0 ]
    has=$(src 'ac_registry_has myproj && echo YES')
    [ "$has" = "YES" ]
    p=$(src 'ac_registry_get myproj path')
    [ "$p" = "$EXISTING" ]
}

@test "register: domain defaults to parent dir name" {
    src "ac_action_register myproj $EXISTING"
    parent=$(src 'ac_registry_get myproj parent')
    expected=$(basename "$(dirname "$EXISTING")")
    [ "$parent" = "$expected" ]
}

@test "register: explicit --domain wins" {
    src "ac_action_register myproj $EXISTING claude-skills"
    parent=$(src 'ac_registry_get myproj parent')
    [ "$parent" = "claude-skills" ]
}

@test "register: refuses missing path" {
    run src "ac_action_register myproj /no/such/path"
    [ "$status" -ne 0 ]
}

@test "register: refuses duplicate name" {
    src "ac_action_register myproj $EXISTING"
    run src "ac_action_register myproj $EXISTING"
    [ "$status" -ne 0 ]
}

@test "register: requires both args" {
    run src "ac_action_register myproj"
    [ "$status" -eq 2 ]
    run src "ac_action_register"
    [ "$status" -eq 2 ]
}
