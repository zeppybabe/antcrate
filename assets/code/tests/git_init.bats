#!/usr/bin/env bats
# tests for lib/git_init.sh

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    touch "$R/README.md"
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/git_init.sh"
        '"$1"
}

@test "git_init: creates .git in registered project" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_git_init proj"
    [ "$status" -eq 0 ]
    [ -d "$R/.git" ]
}

@test "git_init: idempotent (no-op when .git already exists)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_git_init proj"
    # Mark the resulting .git so we can detect re-init
    touch "$R/.git/.sentinel"
    run src "ac_git_init proj"
    [ "$status" -eq 0 ]
    [ -f "$R/.git/.sentinel" ]   # sentinel survived → no re-init
}

@test "git_init: configures core.hooksPath when .githooks/ exists" {
    mkdir -p "$R/.githooks"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_git_init proj"
    [ "$status" -eq 0 ]
    [ -d "$R/.git" ]
    out=$(git -C "$R" config core.hooksPath)
    [ "$out" = ".githooks" ]
}

@test "git_init: skips hooksPath when .githooks/ absent" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_git_init proj"
    [ "$status" -eq 0 ]
    run git -C "$R" config core.hooksPath
    [ "$status" -ne 0 ]   # config key not set
}

@test "git_init: errors when project unregistered" {
    run src "ac_git_init nonexistent"
    [ "$status" -ne 0 ]
    [ ! -d "$R/.git" ]
}

@test "git_init: errors when project name missing" {
    run src "ac_git_init"
    [ "$status" -ne 0 ]
}

@test "git_init: errors when project path missing on disk" {
    run src "ac_registry_upsert ghost '$BATS_TEST_TMPDIR/does-not-exist' scripts ''
             ac_git_init ghost"
    [ "$status" -ne 0 ]
}
