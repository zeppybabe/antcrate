#!/usr/bin/env bats
# tests for ac_backup_run / ac_backup_restore_best (lib/backup.sh)

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_CONFIG="$ANTCRATE_HOME/config"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_MIRROR_PREFIX="$BATS_TEST_TMPDIR/hub/"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git config --file "$GIT_CONFIG_GLOBAL" user.name tester
    git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.com
    git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master
    mkdir -p "$ANTCRATE_HOME" "$BATS_TEST_TMPDIR/hub"
    PROJ="$BATS_TEST_TMPDIR/proj"; mkdir -p "$PROJ"; echo "v1" > "$PROJ/f.txt"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_BACKUP_DIR='$ANTCRATE_BACKUP_DIR'
        export ANTCRATE_CONFIG='$ANTCRATE_CONFIG' ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        export ANTCRATE_MIRROR_PREFIX='$ANTCRATE_MIRROR_PREFIX'
        export GIT_CONFIG_GLOBAL='$GIT_CONFIG_GLOBAL'
        . '$LIB/log.sh'; . '$LIB/backup.sh'; . '$LIB/targets/local.sh'
        . '$LIB/targets/git_mirror.sh'; . '$LIB/targets.sh'
        $1
    "
}

@test "run: fans push to enabled targets (local default)" {
    run src "ac_backup_run proj '$PROJ'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"local"*"OK"* ]]
    [ "$(src "target_local_list proj" | wc -l)" -eq 1 ]
}

@test "run: dev-scope target receives the project's dev/ tree" {
    printf 'backup_targets=local,git-mirror\n' > "$ANTCRATE_CONFIG"
    mkdir -p "$PROJ/dev"; echo "note" > "$PROJ/dev/state.md"
    run src "ac_backup_run proj '$PROJ'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"local"*"OK"* ]]
    [[ "$output" == *"git-mirror (dev)"*"OK"* ]]
    [ -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "run: dev-scope target skips with a note when the project has no dev/" {
    printf 'backup_targets=local,git-mirror\n' > "$ANTCRATE_CONFIG"
    run src "ac_backup_run proj '$PROJ'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"git-mirror"*"skip (no dev/)"* ]]
    [ ! -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
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
