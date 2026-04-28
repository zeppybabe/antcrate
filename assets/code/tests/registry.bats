#!/usr/bin/env bats
# tests for lib/registry.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    mkdir -p "$ANTCRATE_HOME"
}

run_lib() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/registry.sh"
        '"$1"
}

@test "init creates empty registry" {
    run run_lib 'ac_registry_init; cat "$ANTCRATE_REGISTRY"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"projects"'* ]]
}

@test "upsert + has + get" {
    run run_lib 'ac_registry_upsert alpha /tmp/alpha proj git@x:a.git
                  ac_registry_has alpha
                  ac_registry_get alpha path
                  ac_registry_get alpha git_remote'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/tmp/alpha"* ]]
    [[ "$output" == *"git@x:a.git"* ]]
}

@test "has returns nonzero for missing" {
    run run_lib 'ac_registry_has ghost'
    [ "$status" -ne 0 ]
}

@test "link is bidirectional and idempotent" {
    run run_lib '
        ac_registry_upsert a /t/a proj r1
        ac_registry_upsert b /t/b proj r2
        ac_registry_link a b
        ac_registry_link a b
        ac_registry_get a linked_nodes
        echo "---"
        ac_registry_get b linked_nodes'
    [ "$status" -eq 0 ]
    aside=$(echo "$output" | grep -c '^b$')
    bside=$(echo "$output" | grep -c '^a$')
    [ "$aside" -eq 1 ]
    [ "$bside" -eq 1 ]
}

@test "delete removes and prunes back-links" {
    run run_lib '
        ac_registry_upsert a /t/a proj r1
        ac_registry_upsert b /t/b proj r2
        ac_registry_link a b
        ac_registry_delete a
        ac_registry_has a; echo "has_a=$?"
        ac_registry_get b linked_nodes'
    [[ "$output" == *"has_a=1"* ]]
    [[ ! "$output" == *$'\n'a$'\n'* ]]
}

@test "set_path updates path field" {
    run run_lib '
        ac_registry_upsert a /old proj r
        ac_registry_set_path a /new
        ac_registry_get a path'
    [[ "$output" == *"/new"* ]]
}
