#!/usr/bin/env bats
# tests for lib/delegate.sh — proposal #93 (Clyde -> Cody handoff with
# per-key attempt counter).

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_EVENTS_DIR="$ANTCRATE_HOME/events"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R/.antcrate"
    printf '%s\n' '{}' > "$R/.antcrate/cody-attempts.json"
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_EVENTS_DIR="'"$ANTCRATE_EVENTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_DELEGATE_THRESHOLD="'"${ANTCRATE_DELEGATE_THRESHOLD:-3}"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/events.sh"
        . "'"$LIB"'/delegate.sh"
        '"$1"
}

# ---------- ac_delegate_run ----------

@test "delegate: first run increments counter to 1 and prints handoff block" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_delegate_run proj 'src/foo.sh:42' 'fix the off-by-one' 'src/foo.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Delegate to proj-cody"* ]]
    [[ "$output" == *"src/foo.sh:42"* ]]
    [[ "$output" == *"attempt : 1 of 3"* ]]
    [[ "$output" == *"fix the off-by-one"* ]]
    out=$(jq -r '."src/foo.sh:42"' "$R/.antcrate/cody-attempts.json")
    [ "$out" = "1" ]
}

@test "delegate: second run on same key increments to 2" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_delegate_run proj 'k' 't' >/dev/null
         ac_delegate_run proj 'k' 't' >/dev/null"
    out=$(jq -r '.k' "$R/.antcrate/cody-attempts.json")
    [ "$out" = "2" ]
}

@test "delegate: refuses with exit 3 once counter is at threshold" {
    src "ac_registry_upsert proj '$R' scripts ''" >/dev/null
    printf '%s\n' '{"hot":3}' > "$R/.antcrate/cody-attempts.json"
    run src "ac_delegate_run proj 'hot' 'try again'"
    [ "$status" -eq 3 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"threshold of 3"* ]]
    out=$(jq -r '.hot' "$R/.antcrate/cody-attempts.json")
    [ "$out" = "3" ]   # not incremented past threshold
}

@test "delegate: refuses on counter above threshold (defensive)" {
    src "ac_registry_upsert proj '$R' scripts ''" >/dev/null
    printf '%s\n' '{"k":7}' > "$R/.antcrate/cody-attempts.json"
    run src "ac_delegate_run proj 'k' 't'"
    [ "$status" -eq 3 ]
}

@test "delegate: ANTCRATE_DELEGATE_THRESHOLD overrides default" {
    src "ac_registry_upsert proj '$R' scripts ''" >/dev/null
    ANTCRATE_DELEGATE_THRESHOLD=2 run src "ac_delegate_run proj 'k' 't'
                                            ac_delegate_run proj 'k' 't'
                                            ac_delegate_run proj 'k' 't'"
    [ "$status" -eq 3 ]
    [[ "$output" == *"threshold of 2"* ]]
}

@test "delegate: emits a delegate event on success" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_delegate_run proj 'src/foo.sh:42' 'fix' 'src/foo.sh' >/dev/null"
    f="$ANTCRATE_EVENTS_DIR/proj.jsonl"
    [ -f "$f" ]
    grep -q '"kind":"delegate"' "$f"
    grep -q '"path":"src/foo.sh"' "$f"
    grep -q '"agent":"clyde"' "$f"
}

@test "delegate: lazily creates attempts file when missing" {
    rm -f "$R/.antcrate/cody-attempts.json"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_delegate_run proj 'k' 't'"
    [ "$status" -eq 0 ]
    [ -f "$R/.antcrate/cody-attempts.json" ]
    out=$(jq -r '.k' "$R/.antcrate/cody-attempts.json")
    [ "$out" = "1" ]
}

@test "delegate: errors when project unregistered" {
    run src "ac_delegate_run nonexistent k t"
    [ "$status" -ne 0 ]
}

@test "delegate: errors when --key is missing" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_delegate_run proj '' 't'"
    [ "$status" -eq 2 ]
}

@test "delegate: errors when --task is missing" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_delegate_run proj 'k' ''"
    [ "$status" -eq 2 ]
}

@test "delegate: --file omitted falls back to key in event path" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_delegate_run proj 'some_function' 't' >/dev/null"
    f="$ANTCRATE_EVENTS_DIR/proj.jsonl"
    grep -q '"path":"some_function"' "$f"
}

# ---------- ac_delegate_reset ----------

@test "delegate-reset: clears one key when --key given" {
    printf '%s\n' '{"a":2,"b":1}' > "$R/.antcrate/cody-attempts.json"
    src "ac_registry_upsert proj '$R' scripts ''
         ac_delegate_reset proj a"
    out=$(jq -r '. | has("a")' "$R/.antcrate/cody-attempts.json")
    [ "$out" = "false" ]
    out=$(jq -r '.b' "$R/.antcrate/cody-attempts.json")
    [ "$out" = "1" ]
}

@test "delegate-reset: clears all keys when no --key given" {
    printf '%s\n' '{"a":2,"b":1}' > "$R/.antcrate/cody-attempts.json"
    src "ac_registry_upsert proj '$R' scripts ''
         ac_delegate_reset proj"
    out=$(cat "$R/.antcrate/cody-attempts.json")
    [ "$out" = "{}" ]
}

@test "delegate-reset: unblocks future delegations after threshold hit" {
    printf '%s\n' '{"k":3}' > "$R/.antcrate/cody-attempts.json"
    src "ac_registry_upsert proj '$R' scripts ''" >/dev/null
    run src "ac_delegate_run proj k t"
    [ "$status" -eq 3 ]
    src "ac_delegate_reset proj k"
    run src "ac_delegate_run proj k t"
    [ "$status" -eq 0 ]
    out=$(jq -r '.k' "$R/.antcrate/cody-attempts.json")
    [ "$out" = "1" ]
}

@test "delegate-reset: errors when project unregistered" {
    run src "ac_delegate_reset nonexistent"
    [ "$status" -ne 0 ]
}

# ---------- ac_delegate_status ----------

@test "delegate-status: empty counter prints (none)" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_delegate_status proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"attempts  : (none)"* ]]
}

@test "delegate-status: lists non-zero entries sorted by count desc" {
    printf '%s\n' '{"low":1,"high":3,"mid":2,"zero":0}' > "$R/.antcrate/cody-attempts.json"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_delegate_status proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3  high"* ]]
    [[ "$output" == *"2  mid"* ]]
    [[ "$output" == *"1  low"* ]]
    [[ "$output" != *"zero"* ]]
    # high must come before mid
    [[ "$output" == *"3  high"*"2  mid"* ]]
}

@test "delegate-status: errors when project unregistered" {
    run src "ac_delegate_status nonexistent"
    [ "$status" -ne 0 ]
}
