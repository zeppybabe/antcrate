#!/usr/bin/env bats
# tests for lib/post.sh — update log

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_POSTS_DIR="$ANTCRATE_HOME/posts"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_POSTS_DIR="'"$ANTCRATE_POSTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/post.sh"
        '"$1"
}

@test "log: last_sha rc 1 when no log" {
    run src "ac_post_last_sha proj"
    [ "$status" -eq 1 ]
}

@test "log: append then last_sha reads range end" {
    src "ac_post_log_append proj - abc1234..def5678 'hello world'"
    run src "ac_post_last_sha proj"
    [ "$status" -eq 0 ]
    [ "$output" = "def5678" ]
}

@test "log: append flattens newlines; newest wins" {
    src "ac_post_log_append proj - abc1234..def5678 'first'"
    src "ac_post_log_append proj - def5678..0011223 \$'line1\nline2'"
    run src "ac_post_last_sha proj"
    [ "$output" = "0011223" ]
    run grep -c '' "$ANTCRATE_POSTS_DIR/proj.log"
    [ "$output" = "2" ]
}

@test "log: default status is drafted; explicit status honored" {
    src "ac_post_log_append proj - a..b 'default status'"
    src "ac_post_log_append proj - b..c 'explicit status' posted"
    run tail -n 2 "$ANTCRATE_POSTS_DIR/proj.log"
    [[ "${lines[0]}" == *$'\tdrafted\t'* ]]
    [[ "${lines[1]}" == *$'\tposted\t'* ]]
}

@test "log_show: newest first, rc 1 when absent" {
    run src "ac_post_log_show proj"
    [ "$status" -eq 1 ]
    src "ac_post_log_append proj - a..b 'old'"
    src "ac_post_log_append proj - b..c 'new'"
    run src "ac_post_log_show proj"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"new"* ]]
}
