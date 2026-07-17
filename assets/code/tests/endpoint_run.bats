#!/usr/bin/env bats
# tests for ac_endpoint_run — policy endpoint -> sandboxed launch glue,
# proven end-to-end with the mock-llm fixture (spec 2026-07-16).

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    MOCK="$BATS_TEST_DIRNAME/fixtures/mock-llm"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME/anycrate"
}

# write a policy.json whose endpoints object is the given JSON
_policy_with() {
    jq -n --argjson e "$1" '{endpoints: $e}' > "$ANTCRATE_HOME/anycrate/policy.json"
}

# run a snippet with libs loaded; sandbox disabled by default so the launch
# path itself is what's under test (the real-sandbox test overrides this)
src() {
    ANTCRATE_SANDBOX_DISABLE="${FORCE_SANDBOX:-1}" \
    ANTCRATE_HOME="$ANTCRATE_HOME" ANTCRATE_LOG_LEVEL=error \
    bash -c "
        . '$LIB/log.sh'
        . '$LIB/policy.sh'
        . '$LIB/sandbox.sh'
        $1
    "
}

@test "endpoint_run: launches a local endpoint, prompt in stdin, output on stdout" {
    _policy_with "{\"mock\": {\"kind\":\"local\",\"exec\":\"$MOCK\"}}"
    run bash -c "echo 'hello world' | ANTCRATE_SANDBOX_DISABLE=1 ANTCRATE_HOME='$ANTCRATE_HOME' \
        ANTCRATE_LOG_LEVEL=error bash -c '. \"$LIB/log.sh\"; . \"$LIB/policy.sh\"; \
        . \"$LIB/sandbox.sh\"; ac_endpoint_run mock'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK-OK(11 chars)"* ]]
}

@test "endpoint_run: unknown endpoint refused" {
    _policy_with '{}'
    run src "ac_endpoint_run nope </dev/null"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown endpoint"* ]]
}

@test "endpoint_run: non-local kind refused, never downgraded" {
    _policy_with '{"cloud": {"kind":"api","url":"https://api.anthropic.com"}}'
    run src "ac_endpoint_run cloud </dev/null"
    [ "$status" -eq 1 ]
    [[ "$output" == *"only local endpoints are launched"* ]]
}

@test "endpoint_run: missing policy file refused" {
    run src "ac_endpoint_run mock </dev/null"
    [ "$status" -eq 1 ]
}

@test "endpoint_run: jq-path injection in endpoint name refused" {
    # name 'x"]|"local" #' would forge kind=local if spliced into the jq
    # path unescaped — must be refused by the name guard, nothing executed
    _policy_with '{}'
    run src "ac_endpoint_run 'x\"]|\"local\" #' </dev/null"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid endpoint name"* ]]
}

@test "endpoint_run: local endpoint without exec refused" {
    _policy_with '{"noexec": {"kind":"local"}}'
    run src "ac_endpoint_run noexec </dev/null"
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no exec"* ]]
}

@test "endpoint_run: model_file becomes -m arg with ~ expanded" {
    # argv-recording stand-in (mock-llm ignores argv, so use a recorder here)
    cat > "$BATS_TEST_TMPDIR/rec" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'ARGS:%s\n' "$*"
EOF
    chmod +x "$BATS_TEST_TMPDIR/rec"
    _policy_with "{\"m\": {\"kind\":\"local\",\"exec\":\"$BATS_TEST_TMPDIR/rec\",\"model_file\":\"~/models/x.gguf\"}}"
    run src "ac_endpoint_run m </dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ARGS:-m $HOME/models/x.gguf"* ]]
}

@test "endpoint_run: REAL sandbox blocks network (positive isolation proof)" {
    # only meaningful where confinement actually verifies (degraded hosts —
    # e.g. Ubuntu's default AppArmor userns restriction — correctly warn+run)
    ( . "$LIB/log.sh"; . "$LIB/sandbox.sh"; ac_sandbox_capable ) \
        || skip "sandbox not enforceable on this host (probe failed)"
    _policy_with "{\"mock\": {\"kind\":\"local\",\"exec\":\"$MOCK\"}}"
    FORCE_SANDBOX=0 run src "MOCK_LLM_MODE=tries-network ac_endpoint_run mock </dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NETWORK-BLOCKED"* ]]
    [[ "$output" != *"NETWORK-REACHED"* ]]
}

@test "endpoint_run: endpoint sandbox:false runs direct" {
    _policy_with "{\"mock\": {\"kind\":\"local\",\"exec\":\"$MOCK\",\"sandbox\":false}}"
    FORCE_SANDBOX=0 run src "ac_endpoint_run mock </dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOCK-OK"* ]]
    [[ "$output" != *"unavailable"* ]]   # no sandbox-fallback warning: direct path
}
