#!/usr/bin/env bats
# tests for lib/targets.sh — backup target registry + dispatch

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_CONFIG="$ANTCRATE_HOME/config"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_CONFIG='$ANTCRATE_CONFIG'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'; . '$LIB/backup.sh'; . '$LIB/targets/local.sh'; . '$LIB/targets.sh'
        $1
    "
}

@test "enabled: defaults to local when config absent" {
    run src "ac_targets_enabled"
    [ "$status" -eq 0 ]
    [ "$output" = "local" ]
}

@test "enabled: parses comma list in priority order" {
    printf 'backup_targets=local,usb,git-mirror\n' > "$ANTCRATE_CONFIG"
    run src "ac_targets_enabled"
    [ "${lines[0]}" = "local" ]
    [ "${lines[1]}" = "usb" ]
    [ "${lines[2]}" = "git-mirror" ]
}

@test "enabled: config present without backup_targets defaults to local (errexit-safe)" {
    printf 'duty_involvement=lean\n' > "$ANTCRATE_CONFIG"
    run bash -c "set -euo pipefail
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_CONFIG='$ANTCRATE_CONFIG' ANTCRATE_LOG_LEVEL=error
        . '$LIB/log.sh'; . '$LIB/backup.sh'; . '$LIB/targets/local.sh'; . '$LIB/targets.sh'
        ac_targets_enabled"
    [ "$status" -eq 0 ]
    [ "$output" = "local" ]
}

@test "call: dispatches verb to the named target" {
    run src "ac_target_call local scopes"
    [ "$status" -eq 0 ]
    [ "$output" = "project" ]
}

@test "call: unknown target/verb exits 2" {
    run src "ac_target_call nope push proj /tmp"
    [ "$status" -eq 2 ]
}
