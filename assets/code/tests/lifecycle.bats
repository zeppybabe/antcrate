#!/usr/bin/env bats
# tests for lib/lifecycle.sh

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/agent_init.sh"
        . "'"$LIB"'/md_scaffold.sh"
        . "'"$LIB"'/hooks.sh"
        . "'"$LIB"'/profile.sh"
        . "'"$LIB"'/env_scan.sh"
        . "'"$LIB"'/hook_autoinstall.sh"
        . "'"$LIB"'/lifecycle.sh"
        '"$1"
}

@test "lifecycle: agent_init + md_scaffold fire (no .git → no autoinstall)" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_lifecycle_treatment proj"
    [ "$status" -eq 0 ]
    [ -f "$R/.claude/agents/proj-cody.md" ]
    [ -f "$R/.antcrate/cody-attempts.json" ]
    [ -f "$R/CLAUDE.md" ]
    [ -f "$R/AGENTS.md" ]
    [ -f "$R/state.md" ]
    [ -f "$R/ledger.md" ]
    # No autoinstall because no .git
    [ ! -f "$R/.gitignore" ]
}

@test "lifecycle: with .git, hook autoinstall also fires" {
    (cd "$R" && git init -q -b master && git config user.email t@t && git config user.name t)
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_lifecycle_treatment proj"
    [ "$status" -eq 0 ]
    [ -f "$R/.claude/agents/proj-cody.md" ]
    [ -f "$R/CLAUDE.md" ]
    [ -x "$R/.git/hooks/pre-commit" ]
    [ -f "$R/.gitignore" ]
    grep -qFx ".env" "$R/.gitignore"
}

@test "lifecycle: idempotent (re-run is safe)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_lifecycle_treatment proj"
    cs1=$(find "$R" -type f ! -path '*/.git/*' | sort | xargs sha256sum | sha256sum)
    run src "ac_lifecycle_treatment proj"
    [ "$status" -eq 0 ]
    cs2=$(find "$R" -type f ! -path '*/.git/*' | sort | xargs sha256sum | sha256sum)
    [ "$cs1" = "$cs2" ]
}

@test "lifecycle: no-op on unregistered project (returns 0, mutates nothing)" {
    run src "ac_lifecycle_treatment ghost"
    [ "$status" -eq 0 ]
    [ ! -d "$R/.claude" ]
}

@test "lifecycle: no-op on missing project name (returns 0)" {
    run src "ac_lifecycle_treatment"
    [ "$status" -eq 0 ]
}
