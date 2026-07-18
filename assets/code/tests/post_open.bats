#!/usr/bin/env bats
# tests for lib/post.sh — delivery mode (ac_post_open)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
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

wait_browser_out() {  # the launch is backgrounded; poll up to 2s
    for _ in $(seq 20); do [[ -s "$FAKEBROWSER_OUT" ]] && return 0; sleep 0.1; done
    return 1
}

@test "open: launches profile + intent url, logs, advances pointer" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_post_open proj 'shipped v1 today' ''"
    [ "$status" -eq 0 ]
    wait_browser_out
    args=$(cat "$FAKEBROWSER_OUT")
    [[ "$args" == *"-P"* ]]
    [[ "$args" == *"x-antcrate"* ]]
    [[ "$args" == *"https://x.com/intent/post?text=shipped%20v1%20today"* ]]
    run src "ac_post_last_sha proj"
    [ "$status" -eq 0 ]
    sha=$( cd "$R" && git rev-parse --short HEAD )
    [ "$output" = "$sha" ]
}

@test "open: secret text refused, nothing logged, browser not launched" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_post_open proj 'key is AKIAIOSFODNN7EXAMPLE' ''"
    [ "$status" -eq 1 ]
    [ ! -s "$FAKEBROWSER_OUT" ]
    run src "ac_post_last_sha proj"
    [ "$status" -eq 1 ]
}

@test "open: over-280 refused with count" {
    src "ac_registry_upsert proj '$R' scripts ''"
    long=$(printf 'a%.0s' $(seq 1 300))
    run src "ac_post_open proj '$long' ''"
    [ "$status" -eq 1 ]
    [[ "$output" == *"300"* ]]
}

@test "open: url counted as 23 keeps long-url text under limit" {
    src "ac_registry_upsert proj '$R' scripts ''"
    text="update $(printf 'b%.0s' $(seq 1 240)) https://github.com/zeppybabe/antcrate/releases/tag/v0.2.0-very-long"
    run src "ac_post_open proj \"\$text\" ''"
    [ "$status" -eq 0 ]
}

@test "open: --as override picks that handle" {
    cat > "$ANTCRATE_X_ACCOUNTS" <<'JSON'
{ "accounts": { "@antcrate": { "profile": "x-antcrate" },
                "@other":    { "profile": "x-other" } },
  "projects": { "proj": "@antcrate" } }
JSON
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_post_open proj 'hi' @other"
    [ "$status" -eq 0 ]
    wait_browser_out
    [[ "$(cat "$FAKEBROWSER_OUT")" == *"x-other"* ]]
}

@test "open: missing browser binary prints url, still logs" {
    src "ac_registry_upsert proj '$R' scripts ''"
    export ANTCRATE_BROWSER_CMD="/nonexistent/browser"
    run src "ac_post_open proj 'manual open' ''"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://x.com/intent/post?text=manual%20open"* ]]
    run src "ac_post_last_sha proj"
    [ "$status" -eq 0 ]
}
