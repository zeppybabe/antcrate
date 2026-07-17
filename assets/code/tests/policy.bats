#!/usr/bin/env bats
# tests for lib/policy.sh — model/tier/budget policy file

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/policy.sh'
        $1
    "
}

@test "policy: seed creates file with models/budgets/classes" {
    run src "ac_policy_seed"
    [ "$status" -eq 0 ]
    f="$ANTCRATE_HOME/anycrate/policy.json"
    [ -f "$f" ]
    [ "$(jq -r '.models.haiku.window' "$f")" = "200000" ]
    [ "$(jq -r '.budgets.fable.hard' "$f")" = "400000" ]
    [ "$(jq -r '.budgets.default.hard' "$f")" = "140000" ]
    [ "$(jq -r '.classes.orchestrate.model' "$f")" = "inherit" ]
    [ "$(jq -r '.classes.lookup.tier' "$f")" = "TH" ]
}

@test "policy: seed is idempotent (does not clobber user edits)" {
    src "ac_policy_seed" >/dev/null
    jq '.budgets.fable.soft = 999' "$ANTCRATE_HOME/anycrate/policy.json" > "$BATS_TEST_TMPDIR/t" \
        && mv "$BATS_TEST_TMPDIR/t" "$ANTCRATE_HOME/anycrate/policy.json"
    src "ac_policy_seed" >/dev/null
    [ "$(jq -r '.budgets.fable.soft' "$ANTCRATE_HOME/anycrate/policy.json")" = "999" ]
}

@test "policy: ac_policy_get reads a jq path" {
    src "ac_policy_seed" >/dev/null
    run src "ac_policy_get '.models.fable.tokenizer_factor'"
    [ "$status" -eq 0 ]
    [ "$output" = "1.3" ]
}

@test "policy: ac_policy_get on missing file returns 1, empty output" {
    run src "ac_policy_get '.models.fable.window'"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "policy: ac_policy_show prints the whole file" {
    src "ac_policy_seed" >/dev/null
    run src "ac_policy_show"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"fable"'* ]]
}

@test "policy: seed validates with jq (no trailing garbage / parse errors)" {
    src "ac_policy_seed" >/dev/null
    run jq -e . "$ANTCRATE_HOME/anycrate/policy.json"
    [ "$status" -eq 0 ]
}

@test "policy: ac_policy_show on missing file returns 1" {
    run src "ac_policy_show"
    [ "$status" -eq 1 ]
}

# ---- endpoints (spec 2026-07-16) ----

# helper: seed then overwrite .endpoints with the given JSON object
_seed_with_endpoints() {
    src "ac_policy_seed" >/dev/null
    jq --argjson e "$1" '.endpoints = $e' "$ANTCRATE_HOME/anycrate/policy.json" \
        > "$BATS_TEST_TMPDIR/t" && mv "$BATS_TEST_TMPDIR/t" "$ANTCRATE_HOME/anycrate/policy.json"
}

@test "policy: seed includes empty endpoints object" {
    src "ac_policy_seed" >/dev/null
    [ "$(jq -r '.endpoints | type' "$ANTCRATE_HOME/anycrate/policy.json")" = "object" ]
    [ "$(jq -r '.endpoints | length' "$ANTCRATE_HOME/anycrate/policy.json")" = "0" ]
}

@test "policy: endpoints validate — clean file passes" {
    _seed_with_endpoints '{
      "local-llama": {"kind":"local","exec":"llama-cli","model_file":"~/m.gguf"},
      "office-vllm": {"kind":"vllm","url":"http://10.0.0.5:8000/v1","model":"qwen"},
      "claude":      {"kind":"api","url":"https://api.anthropic.com","model":"claude-sonnet-5"}
    }'
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 0 ]
}

@test "policy: endpoints validate — empty endpoints passes" {
    src "ac_policy_seed" >/dev/null
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 0 ]
}

@test "policy: endpoints validate — unknown kind refused" {
    _seed_with_endpoints '{"bad": {"kind":"cloud","url":"https://x"}}'
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kind must be local|vllm|api"* ]]
}

@test "policy: endpoints validate — local without exec refused" {
    _seed_with_endpoints '{"l": {"kind":"local"}}'
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires exec"* ]]
}

@test "policy: endpoints validate — vllm without url refused" {
    _seed_with_endpoints '{"v": {"kind":"vllm"}}'
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires url"* ]]
}

@test "policy: endpoints validate — http api url refused, http vllm allowed" {
    _seed_with_endpoints '{"a": {"kind":"api","url":"http://api.example.com"}}'
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"api url must be https"* ]]
    _seed_with_endpoints '{"v": {"kind":"vllm","url":"http://10.0.0.5:8000/v1"}}'
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 0 ]
}

@test "policy: endpoints validate — missing file rc 1" {
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 1 ]
}

@test "policy: endpoints validate — reports EVERY defect, not just the first" {
    _seed_with_endpoints '{"a": {"kind":"nope"}, "b": {"kind":"local"}}'
    run src "ac_policy_endpoints_validate"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kind must be"* ]]
    [[ "$output" == *"requires exec"* ]]
}

@test "policy: show includes endpoints table, edit hint, and human-only marker" {
    _seed_with_endpoints '{"local-llama": {"kind":"local","exec":"llama-cli"}}'
    run src "ac_policy_show"
    [ "$status" -eq 0 ]
    [[ "$output" == *"local-llama"* ]]
    [[ "$output" == *"HUMAN-ONLY"* ]]
    [[ "$output" == *"anycrate/policy.json"* ]]
}

@test "policy: show surfaces endpoint defects loudly but still rc 0" {
    _seed_with_endpoints '{"bad": {"kind":"nope"}}'
    run src "ac_policy_show"
    [ "$status" -eq 0 ]
    [[ "$output" == *"kind must be"* ]]
}

@test "policy: show on missing file names the word-form fix" {
    run src "ac_policy_show"
    [ "$status" -eq 1 ]
    [[ "$output" == *"antcrate policy seed"* ]]
}

@test "policy: status line — missing file names the fix" {
    run src "ac_policy_status_line"
    [ "$status" -eq 0 ]
    [[ "$output" == *"policy: missing"* ]]
    [[ "$output" == *"antcrate policy seed"* ]]
}

@test "policy: status line — counts endpoints and local subset" {
    _seed_with_endpoints '{
      "l1": {"kind":"local","exec":"x"}, "l2": {"kind":"local","exec":"y"},
      "a":  {"kind":"api","url":"https://z"}
    }'
    run src "ac_policy_status_line"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 endpoints (2 local)"* ]]
    [[ "$output" == *"sandbox "* ]]
}
