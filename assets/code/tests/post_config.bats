#!/usr/bin/env bats
# tests for lib/post.sh — config resolution + update log

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
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
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_POSTS_DIR="'"$ANTCRATE_POSTS_DIR"'"
        export ANTCRATE_X_ACCOUNTS="'"$ANTCRATE_X_ACCOUNTS"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/post.sh"
        '"$1"
}

@test "account_resolve: project default" {
    run src "ac_post_account_resolve proj"
    [ "$status" -eq 0 ]
    [ "$output" = "@antcrate	x-antcrate" ]
}

@test "account_resolve: explicit handle override" {
    run src "ac_post_account_resolve otherproj @antcrate"
    [ "$status" -eq 0 ]
    [ "$output" = "@antcrate	x-antcrate" ]
}

@test "account_resolve: missing config prints sample, rc 2" {
    rm -f "$ANTCRATE_X_ACCOUNTS"
    run src "ac_post_account_resolve proj"
    [ "$status" -eq 2 ]
    [[ "$output" == *"x-accounts.json"* ]]
    [[ "$output" == *'"accounts"'* ]]
}

@test "account_resolve: unmapped project rc 2" {
    run src "ac_post_account_resolve nomap"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no default account"* ]]
}

@test "account_resolve: unknown handle rc 2" {
    run src "ac_post_account_resolve proj @ghost"
    [ "$status" -eq 2 ]
    [[ "$output" == *"@ghost"* ]]
}

@test "log: last_sha rc 1 when no log" {
    run src "ac_post_last_sha proj"
    [ "$status" -eq 1 ]
}

@test "log: append then last_sha reads range end" {
    src "ac_post_log_append proj @antcrate abc1234..def5678 'hello world'"
    run src "ac_post_last_sha proj"
    [ "$status" -eq 0 ]
    [ "$output" = "def5678" ]
}

@test "log: append flattens newlines; newest wins" {
    src "ac_post_log_append proj @antcrate abc1234..def5678 'first'"
    src "ac_post_log_append proj @antcrate def5678..0011223 \$'line1\nline2'"
    run src "ac_post_last_sha proj"
    [ "$output" = "0011223" ]
    run grep -c '' "$ANTCRATE_POSTS_DIR/proj.log"
    [ "$output" = "2" ]
}

@test "log_show: newest first, rc 1 when absent" {
    run src "ac_post_log_show proj"
    [ "$status" -eq 1 ]
    src "ac_post_log_append proj @antcrate a..b 'old'"
    src "ac_post_log_append proj @antcrate b..c 'new'"
    run src "ac_post_log_show proj"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"new"* ]]
}
