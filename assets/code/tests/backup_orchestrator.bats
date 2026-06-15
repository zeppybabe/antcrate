#!/usr/bin/env bats
# tests for ac_backup_run / ac_backup_restore_best (lib/backup.sh)

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_CONFIG="$ANTCRATE_HOME/config"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
    PROJ="$BATS_TEST_TMPDIR/proj"; mkdir -p "$PROJ"; echo "v1" > "$PROJ/f.txt"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_BACKUP_DIR='$ANTCRATE_BACKUP_DIR'
        export ANTCRATE_CONFIG='$ANTCRATE_CONFIG' ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'; . '$LIB/backup.sh'; . '$LIB/targets/local.sh'; . '$LIB/targets.sh'
        $1
    "
}

@test "run: fans push to enabled targets (local default)" {
    run src "ac_backup_run proj '$PROJ'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"local"*"OK"* ]]
    [ "$(src "target_local_list proj" | wc -l)" -eq 1 ]
}

@test "restore-best: picks newest verified snapshot" {
    src "target_local_push proj '$PROJ'" >/dev/null
    sleep 1; echo "v2" > "$PROJ/f.txt"
    src "target_local_push proj '$PROJ'" >/dev/null
    dest="$BATS_TEST_TMPDIR/out"
    run src "ac_backup_restore_best proj '$dest'"
    [ "$status" -eq 0 ]
    [ "$(cat "$dest/proj/f.txt")" = "v2" ]
}
