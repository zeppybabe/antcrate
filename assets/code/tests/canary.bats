#!/usr/bin/env bats
# tests for lib/canary.sh + antcrate-core canary subcommand

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"

    # Resolve antcrate-core from the build directory next to this skill source.
    # $BATS_TEST_DIRNAME is .../assets/code/tests; core binary is in
    # .../assets/code/core/build/antcrate-core (or the installed copy).
    local core_candidate="$BATS_TEST_DIRNAME/../core/build/antcrate-core"
    if [[ -x "$core_candidate" ]]; then
        export ANTCRATE_SELFSRC="$BATS_TEST_DIRNAME/.."
    elif command -v antcrate-core >/dev/null 2>&1; then
        : # use PATH copy
    else
        skip "antcrate-core not built (run: cd core && cmake --build build)"
    fi

    # Helper: run antcrate wrapper sourcing all libs
    WRAPPER="$BATS_TEST_DIRNAME/../bin/antcrate"
}

run_canary() {
    # Direct call — env vars are already exported in the test scope.
    # (The previous bash -c '"$@"' pattern split multi-arg invocations across
    # bash positional args, breaking the heredoc body.)
    "$WRAPPER" "$@"
}

# ─── case 1: --canary-init writes state.json and emits 32-hex-char token ────

@test "canary-init: writes state.json and emits 32-hex token" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    run run_canary --canary-init
    [ "$status" -eq 0 ]
    token=$(echo "$output" | grep -E '^[0-9a-f]{32}$' | head -1)
    [ ${#token} -eq 32 ]
    [ -f "$ANTCRATE_HOME/canary/state.json" ]
}

# ─── case 2: --canary-verify with correct token: exit 0, state mutates ──────

@test "canary-verify: correct token exits 0 and bumps last_verified_ts" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    run run_canary --canary-init
    [ "$status" -eq 0 ]
    token=$(echo "$output" | grep -E '^[0-9a-f]{32}$' | head -1)

    ts_before=$(jq '.last_verified_ts' "$ANTCRATE_HOME/canary/state.json")
    sleep 1
    run run_canary --canary-verify "$token"
    [ "$status" -eq 0 ]
    ts_after=$(jq '.last_verified_ts' "$ANTCRATE_HOME/canary/state.json")
    [ "$ts_after" -ge "$ts_before" ]
    invocations=$(jq '.invocations_since_verify' "$ANTCRATE_HOME/canary/state.json")
    [ "$invocations" -eq 0 ]
}

# ─── case 3: --canary-verify with wrong token: exit 1, state unchanged ──────

@test "canary-verify: wrong token exits 1 and leaves state byte-identical" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    run run_canary --canary-init
    [ "$status" -eq 0 ]

    before=$(cat "$ANTCRATE_HOME/canary/state.json")
    run run_canary --canary-verify 00000000000000000000000000000000
    [ "$status" -eq 1 ]
    after=$(cat "$ANTCRATE_HOME/canary/state.json")
    [ "$before" = "$after" ]
}

# ─── case 4: --canary-status (no init): prints 'initialized: no', exit 0 ───

@test "canary-status: no state prints 'initialized: no'; exit 0" {
    export ANTCRATE_CANARY_DISABLE=1
    run run_canary --canary-status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'initialized: no'
}

# ─── case 5: --canary-status after init: prints masked token + timestamps ───

@test "canary-status: after init prints masked token and timestamps" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    run run_canary --canary-init
    [ "$status" -eq 0 ]
    run run_canary --canary-status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'initialized: yes'
    # masked token: first 4 chars + ellipsis
    echo "$output" | grep -qE '^token: +[0-9a-f]{4}…'
}

# ─── case 6: with DISABLE=0 and stale state, --rename is gated ─────────────

@test "canary-gate: stale state blocks --rename, output contains COMPACTION CANARY GATE" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    export ANTCRATE_CANARY_TTL_SECONDS=0

    # init so state exists
    run run_canary --canary-init
    [ "$status" -eq 0 ]

    # register a project to rename
    P="$ANTCRATE_ROOT/canary_proj"
    mkdir -p "$P"
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        ac_registry_init
        ac_registry_upsert canary_proj '"$P"' projects ""
    '

    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_CANARY_DISABLE=0
        export ANTCRATE_CANARY_TTL_SECONDS=0
        [[ -n "${ANTCRATE_SELFSRC:-}" ]] && export ANTCRATE_SELFSRC="'"${ANTCRATE_SELFSRC:-}"'"
        '"$WRAPPER"' --rename canary_proj canary_proj_new 2>&1
    '
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'COMPACTION CANARY GATE'
}

# ─── case 7: after --canary-verify, same --rename succeeds ──────────────────

@test "canary-gate: after verify, --rename succeeds" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    export ANTCRATE_CANARY_TTL_SECONDS=3600
    export ANTCRATE_CANARY_MAX_INVOCATIONS=30

    run run_canary --canary-init
    [ "$status" -eq 0 ]
    token=$(echo "$output" | grep -E '^[0-9a-f]{32}$' | head -1)

    run run_canary --canary-verify "$token"
    [ "$status" -eq 0 ]

    P="$ANTCRATE_ROOT/canary_ok"
    mkdir -p "$P"
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        ac_registry_init
        ac_registry_upsert canary_ok '"$P"' projects ""
    '

    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_CANARY_DISABLE=0
        export ANTCRATE_CANARY_TTL_SECONDS=3600
        export ANTCRATE_CANARY_MAX_INVOCATIONS=30
        export ANTCRATE_REMOVAL_PREAPPROVED=1
        [[ -n "${ANTCRATE_SELFSRC:-}" ]] && export ANTCRATE_SELFSRC="'"${ANTCRATE_SELFSRC:-}"'"
        '"$WRAPPER"' --rename canary_ok canary_ok_new 2>&1
    '
    [ "$status" -eq 0 ]
}

# ─── case 8: ANTCRATE_CANARY_DISABLE=1 skips gate even with no state ────────

@test "canary-gate: ANTCRATE_CANARY_DISABLE=1 skips gate with no state" {
    export ANTCRATE_CANARY_DISABLE=1

    P="$ANTCRATE_ROOT/disable_proj"
    mkdir -p "$P"
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        ac_registry_init
        ac_registry_upsert disable_proj '"$P"' projects ""
    '

    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_REMOVAL_PREAPPROVED=1
        [[ -n "${ANTCRATE_SELFSRC:-}" ]] && export ANTCRATE_SELFSRC="'"${ANTCRATE_SELFSRC:-}"'"
        '"$WRAPPER"' --rename disable_proj disable_proj_new 2>&1
    '
    [ "$status" -eq 0 ]
}

# ─── case 9: TTL_SECONDS=0 forces immediate staleness ───────────────────────

@test "canary-gate: ANTCRATE_CANARY_TTL_SECONDS=0 makes state immediately stale" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    export ANTCRATE_CANARY_TTL_SECONDS=0

    run run_canary --canary-init
    [ "$status" -eq 0 ]

    run run_canary --canary-gate-check
    [ "$status" -eq 4 ]
}

# ─── case 10: MAX_INVOCATIONS=1 flips stale after one gate-check ────────────

@test "canary-gate: ANTCRATE_CANARY_MAX_INVOCATIONS=1 stale after one check" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    export ANTCRATE_CANARY_TTL_SECONDS=3600
    export ANTCRATE_CANARY_MAX_INVOCATIONS=1

    # init with max-invocations=1
    run run_canary --canary-init --max-invocations 1
    [ "$status" -eq 0 ]
    token=$(echo "$output" | grep -E '^[0-9a-f]{32}$' | head -1)

    # first gate-check bumps count to 1, which equals max → stale
    run run_canary --canary-gate-check
    [ "$status" -eq 4 ]
}

# ─── case 11: --canary-init --with-claudemd patches __CANARY_TOKEN__ ────────

@test "canary-init --with-claudemd patches __CANARY_TOKEN__ in fixture" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0

    # Create a fixture CLAUDE.md in tmp dir
    local fixture="$BATS_TEST_TMPDIR/CLAUDE.md"
    printf '## Safety Canary\ntoken: __CANARY_TOKEN__\n' > "$fixture"
    export ANTCRATE_CLAUDEMD="$fixture"

    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_CANARY_DISABLE=0
        export ANTCRATE_CLAUDEMD="'"$fixture"'"
        [[ -n "${ANTCRATE_SELFSRC:-}" ]] && export ANTCRATE_SELFSRC="'"${ANTCRATE_SELFSRC:-}"'"
        # Non-interactive: pipe "y" to the patch prompt
        printf "y\n" | '"$WRAPPER"' --canary-init --with-claudemd 2>/dev/null
    '
    [ "$status" -eq 0 ]

    # Verify __CANARY_TOKEN__ was replaced
    run grep '__CANARY_TOKEN__' "$fixture"
    [ "$status" -ne 0 ]  # placeholder should be gone

    # Verify a hex token is present
    run grep -E '[0-9a-f]{32}' "$fixture"
    [ "$status" -eq 0 ]
}

# ─── case 12: --canary-gate-check returns 4 on stale, 0 on fresh ────────────

@test "canary-gate-check: returns 4 on stale; returns 0 on fresh" {
    unset ANTCRATE_CANARY_DISABLE
    export ANTCRATE_CANARY_DISABLE=0
    export ANTCRATE_CANARY_TTL_SECONDS=3600
    export ANTCRATE_CANARY_MAX_INVOCATIONS=30

    run run_canary --canary-init
    [ "$status" -eq 0 ]
    token=$(echo "$output" | grep -E '^[0-9a-f]{32}$' | head -1)

    run run_canary --canary-verify "$token"
    [ "$status" -eq 0 ]

    run run_canary --canary-gate-check
    [ "$status" -eq 0 ]

    # Force stale via TTL=0
    export ANTCRATE_CANARY_TTL_SECONDS=0
    run run_canary --canary-gate-check
    [ "$status" -eq 4 ]
}
