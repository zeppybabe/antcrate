#!/usr/bin/env bats
# tests for lib/post.sh — material mode

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
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

@test "material: unknown project rc 2" {
    run src "ac_post_material ghost"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown project"* ]]
}

@test "material: first post takes last commits, emits MATERIAL + DRAFT" {
    src "ac_registry_upsert proj '$R' scripts ''"
    ( cd "$R" && echo x > f1 && git add f1 && git commit -qm "feat: add f1" )
    run src "ac_post_material proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== MATERIAL"* ]]
    [[ "$output" == *"feat: add f1"* ]]
    [[ "$output" == *"=== DRAFT ==="* ]]
    [[ "$output" == *"proj update:"* ]]
}

@test "material: range starts after last logged sha" {
    src "ac_registry_upsert proj '$R' scripts ''"
    ( cd "$R" && echo x > f1 && git add f1 && git commit -qm "feat: old commit" )
    sha=$( cd "$R" && git rev-parse --short HEAD )
    src "ac_post_log_append proj @antcrate aaaaaaa..$sha 'prior post'"
    ( cd "$R" && echo y > f2 && git add f2 && git commit -qm "feat: new commit" )
    run src "ac_post_material proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"feat: new commit"* ]]
    [[ "$output" != *"feat: old commit"* ]]
}

@test "material: nothing new rc 3" {
    src "ac_registry_upsert proj '$R' scripts ''"
    sha=$( cd "$R" && git rev-parse --short HEAD )
    src "ac_post_log_append proj @antcrate aaaaaaa..$sha 'prior post'"
    run src "ac_post_material proj"
    [ "$status" -eq 3 ]
    [[ "$output" == *"nothing to post"* ]]
}

@test "material: secret lines in commit bodies are redacted" {
    src "ac_registry_upsert proj '$R' scripts ''"
    ( cd "$R" && echo x > f1 && git add f1 \
      && git commit -qm "feat: add f1" -m "leaked AKIAIOSFODNN7EXAMPLE here" )
    run src "ac_post_material proj"
    [ "$status" -eq 0 ]
    [[ "$output" != *"AKIAIOSFODNN7"* ]]
    [[ "$output" == *"[redacted: secret-pattern]"* ]]
}

@test "repo_url: SSH remote converted to HTTPS" {
    src "ac_registry_upsert proj '$R' scripts ''"
    git -C "$R" remote add origin git@github.com:someowner/somerepo.git
    run src "ac_post_repo_url proj '$R'"
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/someowner/somerepo" ]
}
