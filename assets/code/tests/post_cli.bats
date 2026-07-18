#!/usr/bin/env bats
# tests for the `antcrate post x ...` word command (bin/antcrate wiring)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_POSTS_DIR="$ANTCRATE_HOME/posts"
    export ANTCRATE_X_ACCOUNTS="$BATS_TEST_TMPDIR/x-accounts.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
    cat > "$ANTCRATE_X_ACCOUNTS" <<'JSON'
{
  "accounts": { "@antcrate": { "profile": "x-antcrate" } },
  "projects": { "proj": "@antcrate" }
}
JSON

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

    # browser test double: records argv, never launches anything
    export ANTCRATE_BROWSER_CMD="$BATS_TEST_TMPDIR/fakebrowser"
    cat > "$ANTCRATE_BROWSER_CMD" <<'FB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKEBROWSER_OUT:?}"
FB
    chmod +x "$ANTCRATE_BROWSER_CMD"
    export FAKEBROWSER_OUT="$BATS_TEST_TMPDIR/browser-args"
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_POSTS_DIR="'"$ANTCRATE_POSTS_DIR"'"
        export ANTCRATE_X_ACCOUNTS="'"$ANTCRATE_X_ACCOUNTS"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_BROWSER_CMD="'"$ANTCRATE_BROWSER_CMD"'"
        export FAKEBROWSER_OUT="'"$FAKEBROWSER_OUT"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/post.sh"
        '"$1"
}

@test "cli: post x <p> prints material" {
    src "ac_registry_upsert proj '$R' scripts ''"
    ( cd "$R" && echo x > f1 && git add f1 && git commit -qm "feat: cli smoke" )
    run env ANTCRATE_HOME="$ANTCRATE_HOME" ANTCRATE_REGISTRY="$ANTCRATE_REGISTRY" \
        ANTCRATE_POSTS_DIR="$ANTCRATE_POSTS_DIR" ANTCRATE_X_ACCOUNTS="$ANTCRATE_X_ACCOUNTS" \
        "$BIN" post x proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== MATERIAL"* ]]
}

@test "cli: post x --open opens and logs" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run env ANTCRATE_HOME="$ANTCRATE_HOME" ANTCRATE_REGISTRY="$ANTCRATE_REGISTRY" \
        ANTCRATE_POSTS_DIR="$ANTCRATE_POSTS_DIR" ANTCRATE_X_ACCOUNTS="$ANTCRATE_X_ACCOUNTS" \
        ANTCRATE_BROWSER_CMD="$ANTCRATE_BROWSER_CMD" FAKEBROWSER_OUT="$FAKEBROWSER_OUT" \
        "$BIN" post x proj --open "cli smoke post"
    [ "$status" -eq 0 ]
    run env ANTCRATE_POSTS_DIR="$ANTCRATE_POSTS_DIR" \
        bash -c ". '$BATS_TEST_DIRNAME/../lib/log.sh'; . '$BATS_TEST_DIRNAME/../lib/post.sh'; ac_post_last_sha proj"
    [ "$status" -eq 0 ]
}

@test "cli: post x log <p> shows entries" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_post_log_append proj @antcrate a..b 'logged entry'"
    run env ANTCRATE_HOME="$ANTCRATE_HOME" ANTCRATE_REGISTRY="$ANTCRATE_REGISTRY" \
        ANTCRATE_POSTS_DIR="$ANTCRATE_POSTS_DIR" ANTCRATE_X_ACCOUNTS="$ANTCRATE_X_ACCOUNTS" \
        "$BIN" post x log proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"logged entry"* ]]
}

@test "cli: post with unknown platform rc 2" {
    run "$BIN" post mastodon proj
    [ "$status" -eq 2 ]
}
