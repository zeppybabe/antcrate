#!/usr/bin/env bats
# tests for the plugin manifests and hook wiring

setup() {
    ROOT="$BATS_TEST_DIRNAME/../../.."          # antcrate-src
    PLUGIN="$ROOT/plugin"
    HOOKS_JSON="$PLUGIN/hooks/hooks.json"
    MKT="$ROOT/.claude-plugin/marketplace.json"
    PJ="$PLUGIN/.claude-plugin/plugin.json"
}

# every command string in hooks.json, with the plugin root substituted
wired_commands() {
    jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$HOOKS_JSON" \
        | sed "s|\${CLAUDE_PLUGIN_ROOT}|$PLUGIN|g"
}

@test "marketplace.json parses and names the plugin" {
    run jq -e '.plugins | map(.name) | index("antcrate")' "$MKT"
    [ "$status" -eq 0 ]
}

@test "plugin.json parses and carries name plus version" {
    run jq -e '.name == "antcrate" and (.version | type == "string")' "$PJ"
    [ "$status" -eq 0 ]
}

@test "hooks.json parses" {
    run jq -e '.hooks | type == "object"' "$HOOKS_JSON"
    [ "$status" -eq 0 ]
}

@test "every wired command resolves to an executable file" {
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ -f "$c" ] || { echo "missing: $c"; false; }
        [ -x "$c" ] || { echo "not executable: $c"; false; }
    done < <(wired_commands)
}

@test "every wired command uses \${CLAUDE_PLUGIN_ROOT}, never \$HOME or an absolute path" {
    run jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$HOOKS_JSON"
    [[ "$output" != *"\$HOME"* ]]
    [[ "$output" != *"/home/"* ]]
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [[ "$c" == "\${CLAUDE_PLUGIN_ROOT}/"* ]] || { echo "bad prefix: $c"; false; }
    done <<< "$output"
}

@test "the five v1 guards are wired" {
    out="$(wired_commands)"
    for h in gateway-guard.sh env-guard.sh local-install-guard.sh \
             activity-emitter.sh shellcheck-on-save.sh session-digest.sh; do
        [[ "$out" == *"$h"* ]] || { echo "not wired: $h"; false; }
    done
}

@test "the budget pair ships in the tree but stays UNWIRED" {
    [ -f "$PLUGIN/hooks/claude/cost-anticipator.sh" ]
    [ -f "$PLUGIN/hooks/claude/session-budget-guard.sh" ]
    out="$(wired_commands)"
    [[ "$out" != *"cost-anticipator.sh"* ]]
    [[ "$out" != *"session-budget-guard.sh"* ]]
}

@test "gateway-guard and env-guard are wired on PreToolUse Bash" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$HOOKS_JSON"
    [[ "$output" == *"gateway-guard.sh"* ]]
    [[ "$output" == *"env-guard.sh"* ]]
}

@test "session-digest is wired on SessionStart" {
    run jq -r '.hooks.SessionStart[].hooks[].command' "$HOOKS_JSON"
    [[ "$output" == *"session-digest.sh"* ]]
}
