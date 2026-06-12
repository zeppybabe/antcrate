#!/usr/bin/env bats
# tests for hooks/claude/cost-anticipator.sh — predictive cost gate
# Payloads are piped on stdin exactly as Claude Code delivers them.

setup() {
    HOOK="$BATS_TEST_DIRNAME/../hooks/claude/cost-anticipator.sh"
    export ANTCRATE_POLICY_FILE="$BATS_TEST_TMPDIR/policy.json"
    export ANTCRATE_COST_SKILLS_DIR="$BATS_TEST_TMPDIR/skills"
    T="$BATS_TEST_TMPDIR/transcript.jsonl"
    jq -n '{models:{fable:{window:1000000,tokenizer_factor:1.3},haiku:{window:200000,tokenizer_factor:1.0}},
            budgets:{default:{soft:100000,hard:140000},fable:{soft:250000,hard:400000}},
            skill_overrides:{"claude-api":{extra_bytes:700000}}}' > "$ANTCRATE_POLICY_FILE"
    mkdir -p "$ANTCRATE_COST_SKILLS_DIR/smallskill" "$ANTCRATE_COST_SKILLS_DIR/claude-api"
    head -c 4000   /dev/zero | tr '\0' 'a' > "$ANTCRATE_COST_SKILLS_DIR/smallskill/SKILL.md"
    head -c 40000  /dev/zero | tr '\0' 'a' > "$ANTCRATE_COST_SKILLS_DIR/claude-api/SKILL.md"
}

# transcript with a given context size + model id
mk_transcript() {
    jq -cn --argjson n "$1" --arg m "$2" \
        '{message:{model:$m,usage:{input_tokens:$n,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' > "$T"
}

payload_skill() { jq -cn --arg t "$T" --arg s "$1" '{transcript_path:$t,tool_name:"Skill",tool_input:{skill:$s}}'; }

@test "anticipator: small skill at low context allows (rc 0)" {
    mk_transcript 50000 "claude-fable-5"
    run bash -c "payload=\$(jq -cn --arg t '$T' '{transcript_path:\$t,tool_name:\"Skill\",tool_input:{skill:\"smallskill\"}}'); printf '%s' \"\$payload\" | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: claude-api skill (extra_bytes) at 130k on fable BLOCKS past hard" {
    # 130k + (40000+700000)/4*1.3 ≈ 130k + 240k = 370k < fable hard 400k -> allow
    mk_transcript 130000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
    # but at 200k projected 440k > 400k -> block rc 2
    mk_transcript 200000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "${lines[*]}" == *"cheaper"* ]]
}

@test "anticipator: unknown model uses default budgets (claude-api at 50k blocks: 50k+240k>140k)" {
    mk_transcript 50000 "claude-mystery-9"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "anticipator: soft crossing warns on stdout systemMessage, rc 0" {
    # smallskill est ≈ 1300 tok; context 249500 -> projected 250800 > fable soft 250k
    mk_transcript 249500 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"smallskill\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *systemMessage* ]]
}

@test "anticipator: Agent prompt overflowing target model window blocks" {
    mk_transcript 10000 "claude-fable-5"
    bigf="$BATS_TEST_TMPDIR/bigprompt.txt"
    head -c 1000000 /dev/zero | tr '\0' 'b' > "$bigf"   # ~250k tok > haiku 200k window
    jq -cn --arg t "$T" --rawfile p "$bigf" \
        '{transcript_path:$t,tool_name:"Agent",tool_input:{prompt:$p,model:"haiku"}}' > "$BATS_TEST_TMPDIR/payload.json"
    run bash -c "'$HOOK' < '$BATS_TEST_TMPDIR/payload.json'"
    [ "$status" -eq 2 ]
}

@test "anticipator: Read of huge file blocks past hard budget" {
    mk_transcript 130000 "claude-mystery-9"   # default hard 140k
    big="$BATS_TEST_TMPDIR/big.txt"; head -c 200000 /dev/zero | tr '\0' 'c' > "$big"  # ~50k tok
    run bash -c "jq -cn --arg t '$T' --arg f '$big' '{transcript_path:\$t,tool_name:\"Read\",tool_input:{file_path:\$f}}' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "anticipator: fail-open on missing policy file" {
    rm -f "$ANTCRATE_POLICY_FILE"
    mk_transcript 999999 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: fail-open on garbage payload" {
    run bash -c "printf 'not json' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: DISABLE hatch honored" {
    mk_transcript 999999 "claude-fable-5"
    ANTCRATE_COST_GUARD_DISABLE=1 run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | env ANTCRATE_COST_GUARD_DISABLE=1 '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: unknown skill name fails open (no dir to size)" {
    mk_transcript 130000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"no-such\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
}
