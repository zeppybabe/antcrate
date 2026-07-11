#!/usr/bin/env bats
# tests for hooks/claude/session-budget-guard.sh — context-window session gate
#
# Gate measures the LAST usage record in the session transcript (input +
# cache_read + cache_creation). Soft (default 100k) warns, throttled per 10k
# growth. Hard (default 140k) blocks everything except the wrap-up whitelist.
# Stateless across /clear: a fresh transcript measures small. Fails OPEN.

setup() {
    HOOK="$BATS_TEST_DIRNAME/../hooks/claude/session-budget-guard.sh"
    export ANTCRATE_SESSION_GATE_DIR="$BATS_TEST_TMPDIR/gate"
    export ANTCRATE_SESSION_SOFT=100000
    export ANTCRATE_SESSION_HARD=140000
    export ANTCRATE_POLICY_FILE="$BATS_TEST_TMPDIR/no-such-policy.json"
}

# mk_transcript <input_tokens> [cache_read] — fixture JSONL, prints its path
mk_transcript() {
    local f="$BATS_TEST_TMPDIR/transcript.jsonl"
    printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$f"
    printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":12}}}\n' \
        "$1" "${2:-0}" >> "$f"
    printf '%s' "$f"
}

# run_hook <tool_name> <tool_input_json> <transcript_path>
run_hook() {
    printf '{"session_id":"testsess","transcript_path":"%s","tool_name":"%s","tool_input":%s}' \
        "$3" "$1" "$2" | "$HOOK"
}

@test "gate: under soft — silent allow" {
    t=$(mk_transcript 50000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gate: cache_read counts toward context" {
    t=$(mk_transcript 2000 145000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: soft — allows but emits systemMessage warn" {
    t=$(mk_transcript 112000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'soft limit'* ]]
}

@test "gate: soft warn throttled until +10k growth" {
    t=$(mk_transcript 112000)
    run_hook Bash '{"command":"x"}' "$t" >/dev/null
    run run_hook Bash '{"command":"x"}' "$t"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    t=$(mk_transcript 123000)
    run run_hook Bash '{"command":"x"}' "$t"
    [[ "$output" == *'systemMessage'* ]]
}

@test "gate: hard blocks non-whitelisted Bash with checklist" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *'SESSION HARD LIMIT'* ]]
    [[ "$output" == *'/clear'* ]]
}

@test "gate: hard allows each wrap-up command" {
    t=$(mk_transcript 143000)
    while IFS= read -r c; do
        run run_hook Bash "{\"command\":\"$c\"}" "$t"
        [ "$status" -eq 0 ]
    done <<'EOF'
antcrate commit antcrate -m wrap
antcrate pp antcrate
antcrate st
antcrate duty ls
antcrate duty add add-me
antcrate duty done 1
antcrate --emit-activity antcrate --kind note
git status
git diff HEAD
git log --oneline -5
git add ledger.md
EOF
}

@test "gate: hard allows compact-word commit form (PREAPPROVED retired 2026-07-10)" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"antcrate commit antcrate -m wrap -- ledger.md"}' "$t"
    [ "$status" -eq 0 ]
}

@test "gate: hard — quoted text cannot smuggle a segment" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"antcrate commit antcrate -m \"feat: a && b; c\" -- ledger.md"}' "$t"
    [ "$status" -eq 0 ]
}

@test "gate: hard — compound with non-whitelisted segment blocks" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"git status && make deploy"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: hard — command substitution always blocks" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"git log $(whoami)"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: hard — Edit allowed only on the four state files" {
    t=$(mk_transcript 143000)
    for f in state.md ledger.md state-archive.md duties.md; do
        run run_hook Edit "{\"file_path\":\"/home/u/projects/antcrate/$f\"}" "$t"
        [ "$status" -eq 0 ]
    done
    run run_hook Edit '{"file_path":"/home/u/projects/antcrate/assets/code/lib/cost.sh"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: hard — Read/Grep/Glob allowed, Task blocked" {
    t=$(mk_transcript 143000)
    run run_hook Read '{"file_path":"/etc/hostname"}' "$t"
    [ "$status" -eq 0 ]
    run run_hook Grep '{"pattern":"x"}' "$t"
    [ "$status" -eq 0 ]
    run run_hook Task '{"prompt":"spawn"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: fails OPEN on missing transcript and garbage JSONL" {
    run run_hook Bash '{"command":"make build"}' "/nonexistent/t.jsonl"
    [ "$status" -eq 0 ]
    g="$BATS_TEST_TMPDIR/garbage.jsonl"
    printf 'not json at all\n{broken\n' > "$g"
    run run_hook Bash '{"command":"make build"}' "$g"
    [ "$status" -eq 0 ]
}

@test "gate: DISABLE hatch bypasses even hard" {
    t=$(mk_transcript 190000)
    export ANTCRATE_SESSION_GATE_DISABLE=1
    run run_hook Bash '{"command":"make build"}' "$t"
    unset ANTCRATE_SESSION_GATE_DISABLE
    [ "$status" -eq 0 ]
}
