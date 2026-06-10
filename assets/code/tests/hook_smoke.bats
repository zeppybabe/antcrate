#!/usr/bin/env bats
# tests for ac_hook_smoke in lib/hooks.sh — proposal claude-hook-smoke.
# Feed a synthetic PreToolUse/PostToolUse payload to ANY hook script and
# report exit code + stderr; the hook's exit code propagates so scripts can
# assert. Pattern surfaced 2026-06-01 when gateway-guard blocked its own
# commands twice and each fix needed a hand-built synthetic-payload pipe.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
    CAPTURE="$BATS_TEST_TMPDIR/captured.json"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/hooks.sh'
        $1
    "
}

# fixture hook: records stdin, optionally writes stderr, exits as scripted
mk_hook() {  # <exit_code> [stderr_msg]
    local rc="$1" msg="${2:-}"
    cat > "$BATS_TEST_TMPDIR/hook.sh" <<EOF
#!/usr/bin/env bash
cat > "$CAPTURE"
[ -n "$msg" ] && printf '%s\n' "$msg" >&2
exit $rc
EOF
    chmod +x "$BATS_TEST_TMPDIR/hook.sh"
}

@test "smoke: --command builds a Bash tool_input payload the hook receives" {
    mk_hook 0
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh" --command "rm -rf /tmp/x"'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tool_input.command' "$CAPTURE")" = "rm -rf /tmp/x" ]
    [ "$(jq -r '.tool_name' "$CAPTURE")" = "Bash" ]
}

@test "smoke: --file builds a file_path payload with Read tool default" {
    mk_hook 0
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh" --file /etc/passwd'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tool_input.file_path' "$CAPTURE")" = "/etc/passwd" ]
    [ "$(jq -r '.tool_name' "$CAPTURE")" = "Read" ]
}

@test "smoke: --tool overrides the payload tool_name" {
    mk_hook 0
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh" --file /tmp/f --tool Edit'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.tool_name' "$CAPTURE")" = "Edit" ]
}

@test "smoke: --payload passes raw JSON through untouched" {
    mk_hook 0
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh" --payload "{\"custom\":1}"'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.custom' "$CAPTURE")" = "1" ]
}

@test "smoke: hook exit code propagates (block=2)" {
    mk_hook 2 "BLOCKED: nope"
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh" --command "x"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"BLOCKED: nope"* ]]
    [[ "$output" == *"exit=2"* ]]
}

@test "smoke: verdict line names allow/warn/block tiers" {
    mk_hook 0
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh" --command "x"'
    [[ "$output" == *"exit=0"* ]]
    [[ "$output" == *"allow"* ]]
    mk_hook 1 "careful"
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh" --command "x"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"warn"* ]]
}

@test "smoke: missing hook script errors exit 2" {
    run src 'ac_hook_smoke /nonexistent/hook.sh --command "x"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"nonexistent"* ]]
}

@test "smoke: requires exactly one payload source" {
    mk_hook 0
    run src 'ac_hook_smoke "'"$BATS_TEST_TMPDIR"'/hook.sh"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"--command"* ]]
}
