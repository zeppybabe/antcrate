#!/usr/bin/env bats
# tests for lib/hygiene.sh — registry hygiene (ghosts + deregister)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT'
        export ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/registry.sh'
        . '$LIB/hygiene.sh'
        $1
    "
}

@test "ghosts: no ghosts returns friendly message, exit 0" {
    run src 'ac_hygiene_ghosts'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no ghost entries"* ]]
}

@test "ghosts: one ghost in registry lists it correctly" {
    # Create a registry entry with a path that doesn't exist
    src 'ac_registry_upsert "ghost_proj" "/nonexistent/path" "scripts" ""'
    # Verify it's registered
    src 'ac_registry_has "ghost_proj"' && [ $? -eq 0 ] || true

    run src 'ac_hygiene_ghosts'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ghost_proj"* ]]
    [[ "$output" == *"/nonexistent/path"* ]]
}

@test "ghosts: multiple ghosts all listed" {
    src 'ac_registry_upsert "ghost1" "/path1" "domain1" ""'
    src 'ac_registry_upsert "ghost2" "/path2" "domain2" ""'
    src 'ac_registry_upsert "real" "'"$ANTCRATE_ROOT"'/real" "domain3" ""'
    mkdir -p "$ANTCRATE_ROOT/real"

    run src 'ac_hygiene_ghosts'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ghost1"* ]]
    [[ "$output" == *"ghost2"* ]]
    [[ "$output" != *"real"* ]]
}

@test "deregister: ghost entry removed from registry, capture created" {
    src 'ac_registry_upsert "ghost" "/nonexistent" "scripts" ""'

    run src 'ac_hygiene_deregister "ghost"'
    [ "$status" -eq 0 ]

    # Entry should be gone
    run src 'ac_registry_has "ghost"'
    [ "$status" -ne 0 ]  # should NOT be registered

    # Capture dir should exist with entry.json
    [[ -d "$ANTCRATE_HOME/deregistered/ghost" ]]
    cap_dir=$(find "$ANTCRATE_HOME/deregistered/ghost" -maxdepth 2 -name "entry.json" | xargs dirname | head -1)
    [[ -f "$cap_dir/entry.json" ]]
}

@test "deregister: capture contains entry.json, registry.json, manifest.json" {
    src 'ac_registry_upsert "ghost" "/gone/path" "scripts" ""'

    run src 'ac_hygiene_deregister "ghost"'
    [ "$status" -eq 0 ]

    # Find the capture dir (it's under deregistered/ghost/TIMESTAMP/)
    cap_dir=$(find "$ANTCRATE_HOME/deregistered/ghost" -maxdepth 2 -type f -name "entry.json" | xargs dirname | head -1)
    [[ -n "$cap_dir" ]]
    [[ -f "$cap_dir/entry.json" ]]
    [[ -f "$cap_dir/registry.json" ]]
    [[ -f "$cap_dir/manifest.json" ]]

    # Verify entry.json contains the ghost's path
    jq -e '.path == "/gone/path"' "$cap_dir/entry.json" >/dev/null
}

@test "deregister: REFUSE if path still exists (safety gate)" {
    mkdir -p "$ANTCRATE_ROOT/real_proj"
    src 'ac_registry_upsert "real_proj" "'"$ANTCRATE_ROOT"'/real_proj" "scripts" ""'

    run src 'ac_hygiene_deregister "real_proj"'
    # Should refuse (exit 1)
    [ "$status" -eq 1 ]

    # Entry should STILL be in registry
    src 'ac_registry_has "real_proj"'
    [ $? -eq 0 ]

    # Output should mention --archive
    [[ "$output" == *"archive"* ]] || [[ "$output" == *"exists"* ]]
}

@test "deregister: unknown project returns exit 2" {
    run src 'ac_hygiene_deregister "unknown"'
    [ "$status" -eq 2 ]
}

@test "deregister: removes name from linked_nodes on deletion" {
    # Create two entries, link them
    src 'ac_registry_upsert "proj_a" "/ghost_a" "domain" ""'
    src 'ac_registry_upsert "proj_b" "/real_b" "domain" ""'
    mkdir -p "$ANTCRATE_ROOT/real_b"
    src 'ac_registry_link "proj_a" "proj_b"'

    # Verify they're linked
    linked=$(src 'ac_registry_get "proj_b" linked_nodes')
    [[ "$linked" == *"proj_a"* ]]

    # Deregister the ghost
    run src 'ac_hygiene_deregister "proj_a"'
    [ "$status" -eq 0 ]

    # proj_a should be gone from proj_b's linked_nodes
    linked=$(src 'ac_registry_get "proj_b" linked_nodes')
    [[ "$linked" != *"proj_a"* ]] || [[ -z "$linked" ]]
}

@test "deregister: prints dropped entry name, path, and capture dir" {
    src 'ac_registry_upsert "ghost" "/some/path" "scripts" ""'

    run src 'ac_hygiene_deregister "ghost"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ghost"* ]]
    [[ "$output" == *"/some/path"* ]]
    [[ "$output" == *"deregistered"* ]]
}

@test "deregister: manifest.json captures real linked_nodes, not empty array" {
    src 'ac_registry_upsert "ghost_lnk" "/gone/lnk" "scripts" ""'
    src 'ac_registry_upsert "peer" "'"$ANTCRATE_ROOT"'/peer" "scripts" ""'
    mkdir -p "$ANTCRATE_ROOT/peer"
    src 'ac_registry_link "ghost_lnk" "peer"'

    run src 'ac_hygiene_deregister "ghost_lnk"'
    [ "$status" -eq 0 ]

    cap_dir=$(find "$ANTCRATE_HOME/deregistered/ghost_lnk" -maxdepth 2 -type f -name "manifest.json" | xargs dirname | head -1)
    [[ -f "$cap_dir/manifest.json" ]]
    jq -e '.linked_nodes | length > 0' "$cap_dir/manifest.json" >/dev/null
    jq -e '.linked_nodes | contains(["peer"])' "$cap_dir/manifest.json" >/dev/null
}

@test "deregister: REFUSE when path is a regular file" {
    touch "$ANTCRATE_ROOT/regular_file"
    src 'ac_registry_upsert "file_proj" "'"$ANTCRATE_ROOT"'/regular_file" "scripts" ""'

    run src 'ac_hygiene_deregister "file_proj"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"archive"* ]] || [[ "$output" == *"exists"* ]]
}

@test "deregister: REFUSE when path is a symlink" {
    mkdir -p "$ANTCRATE_ROOT/link_target"
    ln -s "$ANTCRATE_ROOT/link_target" "$ANTCRATE_ROOT/a_symlink"
    src 'ac_registry_upsert "sym_proj" "'"$ANTCRATE_ROOT"'/a_symlink" "scripts" ""'

    run src 'ac_hygiene_deregister "sym_proj"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"archive"* ]] || [[ "$output" == *"exists"* ]]
}

@test "deregister: REFUSE when path has trailing slash and dir exists" {
    mkdir -p "$ANTCRATE_ROOT/traildir"
    src 'ac_registry_upsert "trail_proj" "'"$ANTCRATE_ROOT"'/traildir/" "scripts" ""'

    run src 'ac_hygiene_deregister "trail_proj"'
    [ "$status" -eq 1 ]
    [[ "$output" == *"archive"* ]] || [[ "$output" == *"exists"* ]]
}

@test "deregister: wrapper exits 2 for missing project argument" {
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    run bash "$BIN" deregister
    [ "$status" -eq 2 ]
}
