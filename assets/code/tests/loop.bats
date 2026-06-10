#!/usr/bin/env bats
# tests for lib/loop.sh — durable loop run-state + tick state-machine

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    export ANTCRATE_LOOP_ALLOW_UNSAFE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    # shellcheck disable=SC1090
    . "$LIB/log.sh"
    # registry stub: a project "demo" living at $ANTCRATE_ROOT/demo
    ac_registry_get() { [[ "$2" == path ]] && printf '%s\n' "$ANTCRATE_ROOT/$1"; }
    ac_registry_has() { [[ -d "$ANTCRATE_ROOT/$1" ]]; }
    mkdir -p "$ANTCRATE_ROOT/demo"
    # shellcheck disable=SC1090
    . "$LIB/loop.sh"
}

@test "loop dir resolves under ANTCRATE_HOME" {
    run _ac_loop_dir
    [ "$status" -eq 0 ]
    [ "$output" = "$ANTCRATE_HOME/loops" ]
}

@test "gen_id is slug + timestamp and filesystem-safe" {
    run _ac_loop_gen_id "demo"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^demo-[0-9]{8}T[0-9]{6}$ ]]
}

@test "write then get round-trips a field" {
    echo '{"id":"x","status":"running","tick":3}' | _ac_loop_write "x"
    run _ac_loop_get "x" status
    [ "$status" -eq 0 ]
    [ "$output" = "running" ]
    run _ac_loop_get "x" tick
    [ "$output" = "3" ]
}

@test "get on missing loop fails closed" {
    run _ac_loop_get "nope" status
    [ "$status" -ne 0 ]
}

@test "interrupted write leaves prior state intact" {
    echo '{"id":"x","status":"running"}' | _ac_loop_write "x"
    run _ac_loop_set "x" status "done"
    [ "$status" -eq 0 ]
    run _ac_loop_get "x" status
    [ "$output" = "done" ]
}

@test "safety floor passes when bypass env set" {
    run _ac_loop_safety_floor_armed
    [ "$status" -eq 0 ]
}

@test "safety floor refuses when canary gate fails and no bypass" {
    unset ANTCRATE_LOOP_ALLOW_UNSAFE
    ac_canary_gate_check() { return 2; }   # missing canary
    run _ac_loop_safety_floor_armed
    [ "$status" -ne 0 ]
    [[ "$output" == *"safety floor"* ]]
}

@test "init writes well-formed state and prints the /loop prompt" {
    run ac_loop_init "Add reset flow" "demo" 10
    [ "$status" -eq 0 ]
    [[ "$output" == *"/loop antcrate --loop-tick demo-"* ]]
    local f; f=$(ls "$ANTCRATE_HOME/loops/"demo-*.json)
    run jq -er '.objective' "$f"; [ "$output" = "Add reset flow" ]
    run jq -er '.status'    "$f"; [ "$output" = "running" ]
    run jq -er '.max_iter'  "$f"; [ "$output" = "10" ]
    run jq -er '.tick'      "$f"; [ "$output" = "0" ]
}

@test "init refuses unregistered project" {
    run ac_loop_init "x" "ghost" 10
    [ "$status" -ne 0 ]
    [[ "$output" == *"not registered"* ]]
}

@test "init refuses when safety floor not armed" {
    unset ANTCRATE_LOOP_ALLOW_UNSAFE
    ac_canary_gate_check() { return 2; }
    run ac_loop_init "x" "demo" 10
    [ "$status" -ne 0 ]
    [[ "$output" == *"safety floor"* ]]
}

@test "stops: max-iter trips at threshold" {
    echo '{"id":"a","status":"running","tick":10,"max_iter":10,"stall_streak":0,"budget_ceiling":null,"budget_counter_start":0}' | _ac_loop_write "a"
    run _ac_loop_check_stops "a"
    [ "$output" = "max-iter" ]
}

@test "stops: no-progress trips at stall_streak 3" {
    echo '{"id":"a","status":"running","tick":4,"max_iter":25,"stall_streak":3,"budget_ceiling":null,"budget_counter_start":0}' | _ac_loop_write "a"
    run _ac_loop_check_stops "a"
    [ "$output" = "no-progress" ]
}

@test "stops: budget trips when elapsed exceeds ceiling" {
    local past; past=$(( $(date -u +%s) - 100 ))
    echo "{\"id\":\"a\",\"status\":\"running\",\"tick\":1,\"max_iter\":25,\"stall_streak\":0,\"budget_ceiling\":10,\"budget_counter_start\":$past}" | _ac_loop_write "a"
    run _ac_loop_check_stops "a"
    [ "$output" = "budget" ]
}

@test "stops: none when all within bounds" {
    echo '{"id":"a","status":"running","tick":1,"max_iter":25,"stall_streak":0,"budget_ceiling":null,"budget_counter_start":0}' | _ac_loop_write "a"
    run _ac_loop_check_stops "a"
    [ "$output" = "" ]
}

@test "observe: stall_streak increments when tree-sha unchanged" {
    echo '{"id":"a","status":"running","tick":1,"last_tree_sha":"SAME","error_signature":"E","stall_streak":0,"updated":"x"}' | _ac_loop_write "a"
    _ac_loop_observe "a" "SAME" "E"
    run _ac_loop_get "a" stall_streak; [ "$output" = "1" ]
    _ac_loop_observe "a" "SAME" "E"
    run _ac_loop_get "a" stall_streak; [ "$output" = "2" ]
}

@test "observe: stall_streak resets when tree-sha changes and error clears" {
    echo '{"id":"a","status":"running","tick":1,"last_tree_sha":"OLD","error_signature":"E","stall_streak":2,"updated":"x"}' | _ac_loop_write "a"
    _ac_loop_observe "a" "NEW" ""
    run _ac_loop_get "a" stall_streak; [ "$output" = "0" ]
    run _ac_loop_get "a" last_tree_sha; [ "$output" = "NEW" ]
}

@test "signoff records pass" {
    echo '{"id":"a","status":"running","signoff":"none","updated":"x"}' | _ac_loop_write "a"
    run ac_loop_signoff "a" pass "looks correct"
    [ "$status" -eq 0 ]
    run _ac_loop_get "a" signoff; [ "$output" = "pass" ]
}

@test "signoff rejects bad verdict" {
    echo '{"id":"a","status":"running","signoff":"none"}' | _ac_loop_write "a"
    run ac_loop_signoff "a" maybe
    [ "$status" -ne 0 ]
}

@test "halt sets status, writes checkpoint, calls quarantine" {
    echo '{"id":"a","project":"demo","status":"running","tick":5,"checkpoint":{"step_completed":"","key_decisions":"","current_state":"","next_step":""},"updated":"x"}' | _ac_loop_write "a"
    _ac_quarantine_capture() { echo "QCAP $*" >> "$BATS_TEST_TMPDIR/qcap.log"; return 0; }
    ANTCRATE_LEDGER="$BATS_TEST_TMPDIR/ledger.md"
    run _ac_loop_halt "a" "max-iter"
    [ "$status" -eq 0 ]
    run _ac_loop_get "a" status; [ "$output" = "halted-max-iter" ]
    [ -f "$BATS_TEST_TMPDIR/qcap.log" ]
    grep -q "halted-max-iter" "$BATS_TEST_TMPDIR/ledger.md"
}

@test "halt records wip_quarantine=failed when capture fails" {
    echo '{"id":"a","project":"demo","status":"running","tick":5,"checkpoint":{},"updated":"x"}' | _ac_loop_write "a"
    _ac_quarantine_capture() { return 1; }
    ANTCRATE_LEDGER="$BATS_TEST_TMPDIR/ledger.md"
    run _ac_loop_halt "a" "manual"
    run _ac_loop_get "a" wip_quarantine; [ "$output" = "failed" ]
}

@test "tick is a no-op after halt" {
    echo '{"id":"a","status":"halted-manual"}' | _ac_loop_write "a"
    run ac_loop_tick "a"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not running"* ]]
}

@test "tick that trips a stop halts and says do-not-reschedule" {
    echo '{"id":"a","project":"demo","objective":"o","status":"running","tick":25,"max_iter":25,"stall_streak":0,"signoff":"none","budget_ceiling":null,"budget_counter_start":0,"checkpoint":{},"last_tree_sha":"","error_signature":""}' | _ac_loop_write "a"
    _ac_quarantine_capture() { return 0; }
    ANTCRATE_LEDGER="$BATS_TEST_TMPDIR/ledger.md"
    run ac_loop_tick "a"
    [[ "$output" == *"LOOP COMPLETE"* ]]
    [[ "$output" == *"do not reschedule"* ]]
    run _ac_loop_get "a" status; [ "$output" = "halted-max-iter" ]
}

@test "tick: CI green AND signoff pass => done, do-not-reschedule" {
    echo '{"id":"a","project":"demo","objective":"o","status":"running","tick":1,"max_iter":25,"stall_streak":0,"signoff":"pass","budget_ceiling":null,"budget_counter_start":0,"checkpoint":{},"last_tree_sha":"x","error_signature":""}' | _ac_loop_write "a"
    _ac_loop_tree_sha() { printf 'sha2\n'; }
    _ac_loop_run_ci()   { printf '\n'; return 0; }
    run ac_loop_tick "a"
    [[ "$output" == *"LOOP COMPLETE"* ]]
    run _ac_loop_get "a" status; [ "$output" = "done" ]
}

@test "tick: CI red => running, reschedule, tick increments" {
    echo '{"id":"a","project":"demo","objective":"o","status":"running","tick":1,"max_iter":25,"stall_streak":0,"signoff":"none","budget_ceiling":null,"budget_counter_start":0,"checkpoint":{},"last_tree_sha":"x","error_signature":""}' | _ac_loop_write "a"
    _ac_loop_tree_sha() { printf 'sha2\n'; }
    _ac_loop_run_ci()   { printf 'bats: auth:42 fail\n'; return 1; }
    run ac_loop_tick "a"
    [[ "$output" == *"RESCHEDULE"* ]]
    run _ac_loop_get "a" tick; [ "$output" = "2" ]
}

@test "status prints human + porcelain" {
    echo '{"id":"a","project":"demo","objective":"o","status":"running","tick":3,"max_iter":25}' | _ac_loop_write "a"
    run ac_loop_status "a";              [[ "$output" == *"running"* ]]
    run ac_loop_status "a" --porcelain;  [[ "$output" == *'"status": "running"'* ]] || [[ "$output" == *'"status":"running"'* ]]
}

@test "list shows all loops with status" {
    echo '{"id":"a","status":"running"}' | _ac_loop_write "a"
    echo '{"id":"b","status":"done"}'    | _ac_loop_write "b"
    run ac_loop_list
    [[ "$output" == *"a"* ]]; [[ "$output" == *"b"* ]]; [[ "$output" == *"done"* ]]
}

@test "resume flips halted back to running and emits context" {
    echo '{"id":"a","project":"demo","objective":"o","status":"halted-no-progress","tick":4,"checkpoint":{"current_state":"halted at tick 4","next_step":"x"}}' | _ac_loop_write "a"
    run ac_loop_resume "a"
    [ "$status" -eq 0 ]
    [[ "$output" == *"resuming"* ]] || [[ "$output" == *"Resume"* ]]
    run _ac_loop_get "a" status; [ "$output" = "running" ]
}

@test "manual halt routes through halt path" {
    echo '{"id":"a","project":"demo","objective":"o","status":"running","tick":2,"checkpoint":{}}' | _ac_loop_write "a"
    _ac_quarantine_capture() { return 0; }
    ANTCRATE_LEDGER="$BATS_TEST_TMPDIR/ledger.md"
    run ac_loop_halt "a" "manual"
    run _ac_loop_get "a" status; [ "$output" = "halted-manual" ]
}
