#!/usr/bin/env bats
# per-model budget lookup in session-budget-guard (spec 2026-06-11 Unit 5)

setup() {
    HOOK="$BATS_TEST_DIRNAME/../hooks/claude/session-budget-guard.sh"
    export ANTCRATE_POLICY_FILE="$BATS_TEST_TMPDIR/policy.json"
    export ANTCRATE_SESSION_GATE_DIR="$BATS_TEST_TMPDIR/gate"
    T="$BATS_TEST_TMPDIR/transcript.jsonl"
    jq -n '{budgets:{default:{soft:100000,hard:140000},fable:{soft:250000,hard:400000}}}' \
        > "$ANTCRATE_POLICY_FILE"
}

mk() { jq -cn --argjson n "$1" --arg m "$2" \
    '{message:{model:$m,usage:{input_tokens:$n,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' > "$T"; }

run_hook() { printf '%s' "{\"transcript_path\":\"$T\",\"session_id\":\"s1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" | "$HOOK"; }

@test "gate: 176k on fable ALLOWS (fable hard 400k)" {
    mk 176000 "claude-fable-5"; run run_hook; [ "$status" -eq 0 ]
}

@test "gate: 401k on fable BLOCKS" {
    mk 401000 "claude-fable-5"; run run_hook; [ "$status" -eq 2 ]
}

@test "gate: 176k on unknown model BLOCKS (default 140k — bitwise-identical to today)" {
    mk 176000 "claude-mystery-9"; run run_hook; [ "$status" -eq 2 ]
}

@test "gate: env override beats policy (human-only escape unchanged)" {
    mk 150000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"session_id\":\"s1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}' | env ANTCRATE_SESSION_SOFT=100000 ANTCRATE_SESSION_HARD=140000 ANTCRATE_POLICY_FILE='$ANTCRATE_POLICY_FILE' ANTCRATE_SESSION_GATE_DIR='$ANTCRATE_SESSION_GATE_DIR' '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "gate: missing policy file -> default budgets still enforced" {
    rm -f "$ANTCRATE_POLICY_FILE"; mk 176000 "claude-fable-5"
    run run_hook; [ "$status" -eq 2 ]
}

@test "gate: 251k on fable WARNS (fable soft 250k) and allows" {
    mk 251000 "claude-fable-5"; run run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'soft limit'* ]]
    # Throttle state reset: a new marker file is created
    [ -f "$ANTCRATE_SESSION_GATE_DIR/s1.lastwarn" ]
}
