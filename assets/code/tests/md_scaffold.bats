#!/usr/bin/env bats
# tests for lib/md_scaffold.sh

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
        . "'"$LIB"'/md_scaffold.sh"
        '"$1"
}

@test "md_scaffold: creates all four files at project root" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_md_scaffold proj"
    [ "$status" -eq 0 ]
    [ -f "$R/CLAUDE.md" ]
    [ -f "$R/AGENTS.md" ]
    [ -f "$R/state.md" ]
    [ -f "$R/ledger.md" ]
}

@test "md_scaffold: routes records to dev/ when the project has a dev/ boundary" {
    mkdir -p "$R/dev"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_md_scaffold proj"
    [ "$status" -eq 0 ]
    # dev-internal records land under dev/, never as root stubs
    [ -f "$R/dev/state.md" ]
    [ -f "$R/dev/ledger.md" ]
    [ ! -f "$R/state.md" ]
    [ ! -f "$R/ledger.md" ]
    # agent-rules files stay at the project root
    [ -f "$R/CLAUDE.md" ]
    [ -f "$R/AGENTS.md" ]
}

@test "md_scaffold: substitutes __NAME__ / __DOMAIN__ / __DATE__" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_md_scaffold proj"
    grep -q "Name:.*proj" "$R/CLAUDE.md"
    grep -q "Domain:.*scripts" "$R/CLAUDE.md"
    grep -q "$(date +%Y-%m-%d)" "$R/state.md"
    ! grep -q "__NAME__" "$R/CLAUDE.md"
    ! grep -q "__DOMAIN__" "$R/CLAUDE.md"
    ! grep -q "__DATE__" "$R/CLAUDE.md"
}

@test "md_scaffold: refresh-only by default (skips existing files)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_md_scaffold proj"
    printf '%s\n' "USER EDIT" >> "$R/CLAUDE.md"
    run src "ac_md_scaffold proj"
    [ "$status" -eq 0 ]
    grep -q "USER EDIT" "$R/CLAUDE.md"
}

@test "md_scaffold: --force backs up then overwrites" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_md_scaffold proj"
    printf '%s\n' "USER EDIT" >> "$R/CLAUDE.md"
    run src "ac_md_scaffold proj --force"
    [ "$status" -eq 0 ]
    # Backup file with timestamp suffix should exist.
    ls "$R" | grep -q "CLAUDE.md.bak."
    # Original CLAUDE.md should be the fresh template (no USER EDIT).
    ! grep -q "USER EDIT" "$R/CLAUDE.md"
}

@test "md_scaffold: ledger.md template includes registration entry" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_md_scaffold proj"
    grep -q "Project registered with AntCrate" "$R/ledger.md"
    grep -q "domain.*scripts" "$R/ledger.md"
}

@test "md_scaffold: defaults domain to _generic when registry parent is empty" {
    src "ac_registry_upsert proj '$R' '' ''
         ac_md_scaffold proj"
    grep -q "Domain:.*_generic" "$R/CLAUDE.md"
}

@test "md_scaffold: errors when project unregistered" {
    run src "ac_md_scaffold nonexistent"
    [ "$status" -ne 0 ]
}

@test "md_scaffold: errors when project name missing" {
    run src "ac_md_scaffold"
    [ "$status" -ne 0 ]
}

@test "md_scaffold: errors when project path missing on disk" {
    run src "ac_registry_upsert ghost '$BATS_TEST_TMPDIR/does-not-exist' scripts ''
             ac_md_scaffold ghost"
    [ "$status" -ne 0 ]
}
