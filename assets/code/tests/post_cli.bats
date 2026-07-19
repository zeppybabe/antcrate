#!/usr/bin/env bats
# tests for the `antcrate post x ...` word command (bin/antcrate wiring)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_POSTS_DIR="$ANTCRATE_HOME/posts"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    # set up a real git repo for the project
    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
        echo "initial" > README.md
        git add README.md
        git commit -qm "initial"
    )
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_POSTS_DIR="'"$ANTCRATE_POSTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/post.sh"
        '"$1"
}

run_bin() {
    run env ANTCRATE_HOME="$ANTCRATE_HOME" ANTCRATE_REGISTRY="$ANTCRATE_REGISTRY" \
        ANTCRATE_POSTS_DIR="$ANTCRATE_POSTS_DIR" \
        "$BIN" "$@"
}

@test "cli: post x <p> prints material" {
    src "ac_registry_upsert proj '$R' scripts ''"
    ( cd "$R" && echo x > f1 && git add f1 && git commit -qm "feat: cli smoke" )
    run_bin post x proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== MATERIAL"* ]]
}

@test "cli: post x --draft writes X-POSTS.md and logs" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run_bin post x proj --draft "cli smoke draft"
    [ "$status" -eq 0 ]
    [ -f "$R/X-POSTS.md" ]
    grep -q "cli smoke draft" "$R/X-POSTS.md"
    run src "ac_post_last_sha proj"
    [ "$status" -eq 0 ]
}

@test "cli: post x log <p> shows entries" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_post_log_append proj - a..b 'logged entry'"
    run_bin post x log proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"logged entry"* ]]
}

@test "cli: post with unknown platform rc 2" {
    run "$BIN" post mastodon proj
    [ "$status" -eq 2 ]
}

@test "cli: post x --draft with empty text rc 2, no material" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run_bin post x proj --draft ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"non-empty"* ]]
    [[ "$output" != *"=== MATERIAL"* ]]
}

@test "cli: retired --open flag is rejected" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run_bin post x proj --open "should fail"
    [ "$status" -ne 0 ]
    [ ! -f "$R/X-POSTS.md" ]
}
