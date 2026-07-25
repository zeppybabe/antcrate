#!/usr/bin/env bats
# tests for hooks/claude/_zones.sh path resolution (XDG vs legacy ~/.antcrate)

setup() {
    ZONES="$BATS_TEST_DIRNAME/../hooks/claude/_zones.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.antcrate" "$HOME/.local/share/antcrate" "$HOME/.local/state/antcrate"
    # legacy stub — exactly what the real machine has post-migration
    printf '{"projects":{}}\n' > "$HOME/.antcrate/registry.json"
    # live registry with one project
    jq -n '{projects:{live:{path:"/tmp/live",parent:"x",linked_nodes:[],git_remote:""}}}' \
        > "$HOME/.local/share/antcrate/registry.json"
    unset ANTCRATE_REGISTRY ANTCRATE_HOME ANTCRATE_DATA_HOME XDG_DATA_HOME
    unset ANTCRATE_POLICY_FILE ANTCRATE_STATE_HOME XDG_STATE_HOME
}

zsrc() { bash -c '. "'"$ZONES"'"; '"$1"; }

@test "registry: XDG data path wins over the legacy stub" {
    run zsrc '_zones_registry'
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.local/share/antcrate/registry.json" ]
}

@test "registry: registered roots come from the XDG registry, not the stub" {
    run zsrc 'zones_registered_roots'
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/live" ]
}

@test "registry: ANTCRATE_REGISTRY overrides everything" {
    export ANTCRATE_REGISTRY="$BATS_TEST_TMPDIR/custom.json"
    run zsrc '_zones_registry'
    [ "$output" = "$BATS_TEST_TMPDIR/custom.json" ]
}

@test "registry: ANTCRATE_DATA_HOME is honored ahead of XDG_DATA_HOME" {
    export ANTCRATE_DATA_HOME="$BATS_TEST_TMPDIR/dh"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg"
    run zsrc '_zones_registry'
    [ "$output" = "$BATS_TEST_TMPDIR/dh/registry.json" ]
}

@test "registry: XDG_DATA_HOME is honored when ANTCRATE_DATA_HOME is unset" {
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg"
    mkdir -p "$BATS_TEST_TMPDIR/xdg/antcrate"
    printf '{"projects":{}}\n' > "$BATS_TEST_TMPDIR/xdg/antcrate/registry.json"
    run zsrc '_zones_registry'
    [ "$output" = "$BATS_TEST_TMPDIR/xdg/antcrate/registry.json" ]
}

@test "registry: falls back to legacy when no XDG registry exists" {
    rm -f "$HOME/.local/share/antcrate/registry.json"
    run zsrc '_zones_registry'
    [ "$output" = "$HOME/.antcrate/registry.json" ]
}

@test "policy: XDG state path wins when no legacy policy.json exists" {
    run zsrc '_zones_policy_file'
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.local/state/antcrate/anycrate/policy.json" ]
}

@test "policy: ANTCRATE_POLICY_FILE overrides everything" {
    export ANTCRATE_POLICY_FILE="$BATS_TEST_TMPDIR/custom-policy.json"
    run zsrc '_zones_policy_file'
    [ "$output" = "$BATS_TEST_TMPDIR/custom-policy.json" ]
}

@test "policy: ANTCRATE_STATE_HOME is honored ahead of XDG_STATE_HOME" {
    export ANTCRATE_STATE_HOME="$BATS_TEST_TMPDIR/sh"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdgstate"
    run zsrc '_zones_policy_file'
    [ "$output" = "$BATS_TEST_TMPDIR/sh/anycrate/policy.json" ]
}

@test "policy: XDG_STATE_HOME is honored when ANTCRATE_STATE_HOME is unset" {
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/xdgstate"
    run zsrc '_zones_policy_file'
    [ "$output" = "$BATS_TEST_TMPDIR/xdgstate/antcrate/anycrate/policy.json" ]
}

@test "policy: falls back to legacy ~/.antcrate/anycrate/policy.json when no XDG policy file exists" {
    mkdir -p "$HOME/.antcrate/anycrate"
    printf '{}\n' > "$HOME/.antcrate/anycrate/policy.json"
    run zsrc '_zones_policy_file'
    [ "$output" = "$HOME/.antcrate/anycrate/policy.json" ]
}

@test "policy: XDG state relocation wins over a legacy policy.json, even when the relocated dir is empty" {
    mkdir -p "$HOME/.antcrate/anycrate"
    printf '{}\n' > "$HOME/.antcrate/anycrate/policy.json"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/relocated"
    run zsrc '_zones_policy_file'
    [ "$output" = "$BATS_TEST_TMPDIR/relocated/antcrate/anycrate/policy.json" ]
}

@test "control plane: covers state, data and config homes" {
    run zsrc 'zones_control_plane'
    [[ "$output" == *"$HOME/.local/state/antcrate"* ]]
    [[ "$output" == *"$HOME/.local/share/antcrate"* ]]
    [[ "$output" == *"$HOME/.config/antcrate"* ]]
}
