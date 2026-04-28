#!/usr/bin/env bats
# tests for lib/propose.sh — pattern-proposal escape valve

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_PROPOSALS_LOG="$ANTCRATE_HOME/proposals.log"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_PROPOSER="bats"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_PROPOSALS_LOG="'"$ANTCRATE_PROPOSALS_LOG"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_PROPOSER="'"$ANTCRATE_PROPOSER"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/propose.sh"
        '"$1"
}

@test "propose: appends a tab-separated entry" {
    run src 'ac_propose_pattern remove "Backup-protected project removal"'
    [ "$status" -eq 0 ]
    [ -f "$ANTCRATE_PROPOSALS_LOG" ]
    line=$(cat "$ANTCRATE_PROPOSALS_LOG")
    [[ "$line" == *$'\t'"bats"$'\t'"remove"$'\t'"Backup-protected project removal" ]]
}

@test "propose: append-only across multiple calls" {
    src 'ac_propose_pattern banner "ASCII banner output"'
    src 'ac_propose_pattern archive "Move project to .archive/"'
    n=$(wc -l < "$ANTCRATE_PROPOSALS_LOG")
    [ "$n" -eq 2 ]
    grep -q '	banner	' "$ANTCRATE_PROPOSALS_LOG"
    grep -q '	archive	' "$ANTCRATE_PROPOSALS_LOG"
}

@test "propose: refuses missing name" {
    run src 'ac_propose_pattern "" "desc only"'
    [ "$status" -eq 2 ]
    [ ! -f "$ANTCRATE_PROPOSALS_LOG" ]
}

@test "propose: refuses missing description" {
    run src 'ac_propose_pattern named ""'
    [ "$status" -eq 2 ]
    [ ! -f "$ANTCRATE_PROPOSALS_LOG" ]
}

@test "propose: refuses whitespace in name" {
    run src 'ac_propose_pattern "bad name" "desc"'
    [ "$status" -eq 2 ]
    [ ! -f "$ANTCRATE_PROPOSALS_LOG" ]
}

@test "propose: strips embedded tabs and newlines from description" {
    run src $'ac_propose_pattern noisy "line1\tline2\nline3"'
    [ "$status" -eq 0 ]
    line=$(cat "$ANTCRATE_PROPOSALS_LOG")
    # exactly 4 tab-separated fields
    fields=$(awk -F '\t' '{print NF}' <<< "$line")
    [ "$fields" -eq 4 ]
    # only one record line in the log
    n=$(wc -l < "$ANTCRATE_PROPOSALS_LOG")
    [ "$n" -eq 1 ]
}

@test "propose: list shows empty notice when no log" {
    run src 'ac_propose_list'
    [ "$status" -eq 0 ]
    [[ "$output" == *"No proposals logged yet"* ]]
}

@test "propose: list renders existing entries" {
    src 'ac_propose_pattern remove "Backup-protected removal"'
    run src 'ac_propose_list'
    [ "$status" -eq 0 ]
    [[ "$output" == *"remove"* ]]
    [[ "$output" == *"Backup-protected removal"* ]]
}
