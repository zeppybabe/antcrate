#!/usr/bin/env bats
# tests for hooks/claude/env-guard.sh — secrets stay opaque to agents.
# PreToolUse / Bash+Read. Agents may ASSIGN/reference env vars by name;
# any display sink that would reveal secret VALUES is blocked (exit 2).

setup() {
    HOOKS="$BATS_TEST_DIRNAME/../hooks/claude"
    GUARD="$HOOKS/env-guard.sh"
}

bash_guard() {
    jq -n --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}' | "$GUARD"
}
read_guard() {
    jq -n --arg p "$1" '{tool_name:"Read", tool_input:{file_path:$p}}' | "$GUARD"
}

# ---- env dumps ----

@test "bare env is blocked" {
    run bash_guard "env"
    [ "$status" -eq 2 ]
    [[ "$output" == *"env-guard"* ]]
}

@test "env piped to grep is blocked" {
    run bash_guard "env | grep API"
    [ "$status" -eq 2 ]
}

@test "env used as launcher (env VAR=x cmd) is allowed" {
    run bash_guard "env FOO=1 ls -la"
    [ "$status" -eq 0 ]
}

@test "printenv is blocked, with or without a var name" {
    run bash_guard "printenv"
    [ "$status" -eq 2 ]
    run bash_guard "printenv ANTHROPIC_API_KEY"
    [ "$status" -eq 2 ]
}

@test "bare set is blocked but set -euo pipefail is allowed" {
    run bash_guard "set"
    [ "$status" -eq 2 ]
    run bash_guard "set -euo pipefail"
    [ "$status" -eq 0 ]
}

@test "declare -p and export -p are blocked" {
    run bash_guard "declare -p"
    [ "$status" -eq 2 ]
    run bash_guard "export -p"
    [ "$status" -eq 2 ]
}

# ---- echo/printf of secret-named vars ----

@test "echo of a secret-named var is blocked" {
    run bash_guard 'echo $ANTHROPIC_API_KEY'
    [ "$status" -eq 2 ]
}

@test "echo of a double-quoted secret var is blocked" {
    run bash_guard 'echo "$GITHUB_TOKEN"'
    [ "$status" -eq 2 ]
}

@test "printf of a braced secret var is blocked" {
    run bash_guard 'printf "%s" "${DB_PASSWORD}"'
    [ "$status" -eq 2 ]
}

@test "echo of a single-quoted literal is allowed (no expansion)" {
    run bash_guard "echo '\$ANTHROPIC_API_KEY'"
    [ "$status" -eq 0 ]
}

@test "echo of a non-secret var is allowed" {
    run bash_guard 'echo $ANTCRATE_HOME'
    [ "$status" -eq 0 ]
}

@test "assignment from a secret var is allowed (assign, not display)" {
    run bash_guard 'export FOO="$ANTHROPIC_API_KEY"'
    [ "$status" -eq 0 ]
    run bash_guard 'API_KEY=$VAULT_TOKEN ./run.sh'
    [ "$status" -eq 0 ]
}

@test "BYPASS does not false-positive on the PASS segment" {
    run bash_guard 'echo $ANTCRATE_BYPASS_CHECK'
    [ "$status" -eq 0 ]
}

# ---- secret-file read sinks ----

@test "cat of .env is blocked (bare and pathed)" {
    run bash_guard "cat .env"
    [ "$status" -eq 2 ]
    run bash_guard "cat /home/u/projects/app/.env"
    [ "$status" -eq 2 ]
}

@test "cat of .env.example/.env.sample is allowed" {
    run bash_guard "cat .env.example"
    [ "$status" -eq 0 ]
    run bash_guard "cat .env.sample"
    [ "$status" -eq 0 ]
}

@test "grep on a .env file is blocked" {
    run bash_guard "grep API_KEY .env.production"
    [ "$status" -eq 2 ]
}

@test "private ssh key read is blocked; public key allowed" {
    run bash_guard "cat ~/.ssh/id_rsa"
    [ "$status" -eq 2 ]
    run bash_guard "cat ~/.ssh/id_rsa.pub"
    [ "$status" -eq 0 ]
}

@test "pem and aws credentials reads are blocked" {
    run bash_guard "head -5 server.pem"
    [ "$status" -eq 2 ]
    run bash_guard "cat ~/.aws/credentials"
    [ "$status" -eq 2 ]
}

@test "sourcing .env is allowed (assignment path)" {
    run bash_guard "source .env"
    [ "$status" -eq 0 ]
}

# ---- Read tool ----

@test "Read tool on .env is blocked" {
    run read_guard "/home/u/projects/app/.env"
    [ "$status" -eq 2 ]
}

@test "Read tool on normal files is allowed" {
    run read_guard "/home/u/projects/app/README.md"
    [ "$status" -eq 0 ]
}

@test "Read tool on .env.example is allowed" {
    run read_guard "/home/u/projects/app/.env.example"
    [ "$status" -eq 0 ]
}

# ---- harness behavior ----

@test "payload without command or file_path exits 0 silently" {
    run bash -c 'jq -n "{tool_name:\"Glob\", tool_input:{pattern:\"*.md\"}}" | "'"$GUARD"'"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "ANTCRATE_ENV_GUARD_DISABLE=1 bypasses (CI escape hatch)" {
    ANTCRATE_ENV_GUARD_DISABLE=1 run bash_guard "env"
    [ "$status" -eq 0 ]
}
