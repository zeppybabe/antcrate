#!/usr/bin/env bats
# tests for lib/post.sh — ac_post_draft (git-ignored X-POSTS.md delivery)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_POSTS_DIR="$ANTCRATE_HOME/posts"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

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

@test "draft: writes X-POSTS.md, logs drafted, advances pointer" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_post_draft proj 'shipped the drafts pivot today'"
    [ "$status" -eq 0 ]
    [ -f "$R/X-POSTS.md" ]
    grep -q "shipped the drafts pivot today" "$R/X-POSTS.md"
    grep -q "drafted" "$R/X-POSTS.md"
    sha=$( cd "$R" && git rev-parse --short HEAD )
    run src "ac_post_last_sha proj"
    [ "$status" -eq 0 ]
    [ "$output" = "$sha" ]
    log_line=$(tail -n 1 "$ANTCRATE_POSTS_DIR/proj.log")
    [[ "$log_line" == *$'\t-\t'* ]]
    [[ "$log_line" == *$'\tdrafted\t'* ]]
}

@test "draft: newest entry on top" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_post_draft proj 'first draft'"
    ( cd "$R" && echo x > f1 && git add f1 && git commit -qm "feat: more" )
    src "ac_post_draft proj 'second draft'"
    first_line_no=$(grep -n "first draft"  "$R/X-POSTS.md" | cut -d: -f1)
    second_line_no=$(grep -n "second draft" "$R/X-POSTS.md" | cut -d: -f1)
    [ "$second_line_no" -lt "$first_line_no" ]
}

@test "draft: X-POSTS.md ends up git-ignored via .gitignore line" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_post_draft proj 'ignore me please'"
    ( cd "$R" && git check-ignore -q X-POSTS.md )
    # idempotent: second draft adds no duplicate line
    src "ac_post_draft proj 'still just one line'"
    [ "$(grep -c '^X-POSTS.md$' "$R/.gitignore")" = "1" ]
}

@test "draft: respects a pre-existing ignore rule, leaves .gitignore alone" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "X-POSTS.md" > "$R/.gitignore"
    before=$(cat "$R/.gitignore")
    src "ac_post_draft proj 'already ignored'"
    [ "$(cat "$R/.gitignore")" = "$before" ]
}

@test "draft: secret text refused, nothing written or logged" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_post_draft proj 'oops AKIAIOSFODNN7EXAMPLE'"
    [ "$status" -eq 1 ]
    [ ! -f "$R/X-POSTS.md" ]
    run src "ac_post_last_sha proj"
    [ "$status" -eq 1 ]
}

@test "draft: over-280 refused with count" {
    src "ac_registry_upsert proj '$R' scripts ''"
    long=$(printf 'a%.0s' $(seq 1 300))
    run src "ac_post_draft proj '$long'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"300"* ]]
}

@test "draft: unknown project rc 2" {
    run src "ac_post_draft ghost 'hi'"
    [ "$status" -eq 2 ]
}

@test "draft: unborn HEAD rc 2, nothing written" {
    E="$BATS_TEST_TMPDIR/empty"
    mkdir -p "$E"
    git -C "$E" init -q -b master
    src "ac_registry_upsert emptyproj '$E' scripts ''"
    run src "ac_post_draft emptyproj 'hello'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no commits"* ]]
    [ ! -f "$E/X-POSTS.md" ]
}
