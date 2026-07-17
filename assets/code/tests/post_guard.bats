#!/usr/bin/env bats
# tests for lib/post.sh — content guard, X length, urlencode

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

@test "guard: clean text passes" {
    src "ac_post_guard_text 'shipped v0.2.0, see repo'"
}

@test "guard: AWS key refused, not echoed" {
    run src "ac_post_guard_text 'oops AKIAIOSFODNN7EXAMPLE'"
    [ "$status" -eq 1 ]
    [[ "$output" != *"AKIAIOSFODNN7"* ]]
    [[ "$output" == *"secret-pattern"* ]]
}

@test "guard: github pat refused" {
    run src "ac_post_guard_text 'ghp_0123456789abcdef0123456789abcdef0123'"
    [ "$status" -eq 1 ]
}

@test "guard: private key header refused" {
    run src "ac_post_guard_text '-----BEGIN OPENSSH PRIVATE KEY-----'"
    [ "$status" -eq 1 ]
}

@test "guard: password assignment refused" {
    run src "ac_post_guard_text 'password=hunter2!'"
    [ "$status" -eq 1 ]
}

@test "redact: replaces only the secret line" {
    result=$(printf 'safe line\ntoken: xoxb-1234567890-abcdef\nlast line\n' | src "ac_post_redact")
    [[ "$result" == *"safe line"* ]]
    [[ "$result" == *"[redacted: secret-pattern]"* ]]
    [[ "$result" == *"last line"* ]]
    [[ "$result" != *"xoxb"* ]]
}

@test "x_len: plain ascii" {
    run src "ac_post_x_len 'hello'"
    [ "$output" = "5" ]
}

@test "x_len: url counts as 23" {
    run src "ac_post_x_len 'go https://github.com/zeppybabe/antcrate now'"
    # "go " (3) + 23 + " now" (4) = 30
    [ "$output" = "30" ]
}

@test "x_len: newline counts as 1" {
    run src "ac_post_x_len \$'a\nb'"
    [ "$output" = "3" ]
}

@test "urlencode: spaces and special chars" {
    run src "ac_post_urlencode 'hello world#tag'"
    [ "$output" = "hello%20world%23tag" ]
}
