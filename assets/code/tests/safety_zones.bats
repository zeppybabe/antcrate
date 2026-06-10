#!/usr/bin/env bats
# tests for lib/safety.sh zone derivation — proposal safety-skill-zone-fix.
# ac_safety_allowed_zones must put the antcrate PROJECT ROOT in-zone (not the
# assets/ midpoint dirname(SELFSRC) used to produce), without ever widening
# the zone ABOVE the repo for flat layouts.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    # canonical layout: <skillroot>/assets/code
    SKILLROOT="$BATS_TEST_TMPDIR/skill/antcrate"
    mkdir -p "$SKILLROOT/assets/code"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT'
        export ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        export ANTCRATE_SELFSRC='${SELFSRC_OVERRIDE:-$SKILLROOT/assets/code}'
        . '$LIB/log.sh'
        $1
    "
}

@test "zones: ANTCRATE_ROOT and ANTCRATE_HOME always present" {
    run src '. "'"$LIB"'/safety.sh"; ac_safety_allowed_zones'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$ANTCRATE_ROOT"* ]]
    [[ "$output" == *"$ANTCRATE_HOME"* ]]
}

@test "zones: assets/code SELFSRC derives the PROJECT ROOT, not assets/" {
    run src '. "'"$LIB"'/safety.sh"; ac_safety_allowed_zones'
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx "$SKILLROOT"
    [[ "$output" != *"$SKILLROOT/assets"* ]]
}

@test "zones: a path at the project root passes ac_safety_check_path" {
    run src '. "'"$LIB"'/safety.sh"; ac_safety_check_path "'"$SKILLROOT"'/ledger.md"'
    [ "$status" -eq 0 ]
}

@test "zones: registry antcrate path is preferred when registry.sh is loaded" {
    REGROOT="$BATS_TEST_TMPDIR/elsewhere/antcrate"
    mkdir -p "$REGROOT/assets/code"
    SELFSRC_OVERRIDE="$REGROOT/assets/code"
    run src '. "'"$LIB"'/registry.sh"; . "'"$LIB"'/safety.sh";
             ac_registry_init >/dev/null
             ac_registry_upsert antcrate "'"$REGROOT"'" claude-skills ""
             ac_safety_allowed_zones'
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qx "$REGROOT"
}

@test "zones: flat SELFSRC (no assets/code suffix) does NOT widen above itself" {
    FLAT="$BATS_TEST_TMPDIR/flatrepo"
    mkdir -p "$FLAT"
    SELFSRC_OVERRIDE="$FLAT"
    run src '. "'"$LIB"'/safety.sh"; ac_safety_allowed_zones'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$FLAT"* ]]
    # the PARENT of the flat repo must not be in-zone
    run src '. "'"$LIB"'/safety.sh"; ac_safety_check_path "'"$BATS_TEST_TMPDIR"'/some-sibling"'
    [ "$status" -eq 1 ]
}

@test "zones: registry root that is not an ancestor of SELFSRC is ignored" {
    BOGUS="$BATS_TEST_TMPDIR/bogus-root"
    mkdir -p "$BOGUS"
    run src '. "'"$LIB"'/registry.sh"; . "'"$LIB"'/safety.sh";
             ac_registry_init >/dev/null
             ac_registry_upsert antcrate "'"$BOGUS"'" claude-skills ""
             ac_safety_allowed_zones'
    [ "$status" -eq 0 ]
    [[ "$output" != *"$BOGUS"* ]]
    [[ "$output" == *"$SKILLROOT"* ]]
}
