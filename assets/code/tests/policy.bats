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
