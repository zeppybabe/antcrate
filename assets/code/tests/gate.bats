#!/usr/bin/env bats
# tests for ac_gate_confirm (lib/safety.sh) — TTY-optional confirm helper

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

@test "gate: non-TTY proceeds without input" {
    run bash -c ". '$LIB/log.sh'; . '$LIB/safety.sh'; ac_gate_confirm 'Proceed?' </dev/null"
    [ "$status" -eq 0 ]
}

@test "gate: ASSUME_TTY + y proceeds" {
    run bash -c ". '$LIB/log.sh'; . '$LIB/safety.sh'; ANTCRATE_ASSUME_TTY=1 ac_gate_confirm 'Proceed?' <<< 'y'"
    [ "$status" -eq 0 ]
}

@test "gate: ASSUME_TTY + n declines" {
    run bash -c ". '$LIB/log.sh'; . '$LIB/safety.sh'; ANTCRATE_ASSUME_TTY=1 ac_gate_confirm 'Proceed?' <<< 'n'"
    [ "$status" -eq 1 ]
}

@test "gate: ASSUME_TTY + empty input declines (EOF-safe)" {
    run bash -c ". '$LIB/log.sh'; . '$LIB/safety.sh'; ANTCRATE_ASSUME_TTY=1 ac_gate_confirm 'Proceed?' </dev/null"
    [ "$status" -eq 1 ]
}
