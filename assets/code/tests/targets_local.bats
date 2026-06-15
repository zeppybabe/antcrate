#!/usr/bin/env bats
# tests for lib/targets/local.sh — local filesystem backup target

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
    PROJ="$BATS_TEST_TMPDIR/proj"; mkdir -p "$PROJ"; echo "hello" > "$PROJ/file.txt"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_BACKUP_DIR='$ANTCRATE_BACKUP_DIR'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'; . '$LIB/backup.sh'; . '$LIB/targets/local.sh'
        $1
    "
}

@test "local: scopes is project" {
    run src "target_local_scopes"
    [ "$status" -eq 0 ]
    [ "$output" = "project" ]
}

@test "local: available always succeeds" {
    run src "target_local_available"
    [ "$status" -eq 0 ]
}

@test "local: push stores a verifiable tarball and echoes its id" {
    run src "target_local_push proj '$PROJ'"
    [ "$status" -eq 0 ]
    [ -f "$output" ]
    run src "target_local_verify proj '$output'"
    [ "$status" -eq 0 ]
}

@test "local: list returns pushed snapshot; pull round-trips contents" {
    id=$(src "target_local_push proj '$PROJ'")
    run src "target_local_list proj"
    [[ "$output" == *"$id"* ]]
    dest="$BATS_TEST_TMPDIR/out"
    run src "target_local_pull proj '$id' '$dest'"
    [ "$status" -eq 0 ]
    [ "$(cat "$dest/proj/file.txt")" = "hello" ]
}

@test "local: verify fails on a corrupt snapshot" {
    id=$(src "target_local_push proj '$PROJ'")
    echo "garbage" > "$id"
    run src "target_local_verify proj '$id'"
    [ "$status" -ne 0 ]
}
