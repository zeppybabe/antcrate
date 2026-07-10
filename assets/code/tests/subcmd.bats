#!/usr/bin/env bats
# subcommand dispatcher: compact words alias the --flag surface (audit 2026-07-10)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

@test "subcmd: st == --status" {
    run "$BIN" st
    [ "$status" -eq 0 ]
    [[ "$output" == *"antcrate status"* ]]
}

@test "subcmd: help prints usage" {
    run "$BIN" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Commands"* ]]
}

@test "subcmd: duty ls == --duties" {
    run "$BIN" duty ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open duties"* ]]
}

@test "subcmd: duties == --duties" {
    run "$BIN" duties
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open duties"* ]]
}

@test "subcmd: duty add + duty done round-trip" {
    run "$BIN" duty add --type command "test duty"
    [ "$status" -eq 0 ]
    run "$BIN" duty ls
    [[ "$output" == *"test duty"* ]]
    run "$BIN" duty done 1
    [ "$status" -eq 0 ]
    run "$BIN" duty ls
    [[ "$output" == *"No open duties"* ]]
}

@test "subcmd: bak ls routes to --backups (soft-warn, not unknown arg)" {
    ANTCRATE_LOG_LEVEL=warn run "$BIN" bak ls nosuch
    [ "$status" -eq 0 ]
    [[ "$output" == *"no backups for nosuch"* ]]
}

@test "subcmd: self src == --selfsrc" {
    run "$BIN" self src
    [ "$status" -eq 0 ]
    [[ "$output" == /* ]]
}

@test "subcmd: unknown word exits 2 with hint" {
    run "$BIN" frobnicate
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown command"* ]]
}

@test "subcmd: legacy --flags still work" {
    run "$BIN" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"antcrate status"* ]]
}
