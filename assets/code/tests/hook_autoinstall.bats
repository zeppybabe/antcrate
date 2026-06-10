#!/usr/bin/env bats
# tests for lib/hook_autoinstall.sh

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
    )
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/quarantine.sh"
        . "'"$LIB"'/hooks.sh"
        . "'"$LIB"'/profile.sh"
        . "'"$LIB"'/env_scan.sh"
        . "'"$LIB"'/hook_autoinstall.sh"
        '"$1"
}

@test "hook_autoinstall: empty project installs pre-commit-secrets and patches .gitignore" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_hook_autoinstall proj"
    [ "$status" -eq 0 ]
    [ -x "$R/.git/hooks/pre-commit" ]
    grep -q "antcrate-template: pre-commit-secrets" "$R/.git/hooks/pre-commit"
    [ -f "$R/.gitignore" ]
    grep -qFx ".env"           "$R/.gitignore"
    grep -qFx ".env.local"     "$R/.gitignore"
    grep -qFx ".env.*.local"   "$R/.gitignore"
}

@test "hook_autoinstall: bash project picks pre-commit-secrets first; reports stack-bash skipped" {
    mkdir -p "$R/scripts"
    printf '#!/bin/bash\necho ok\n' > "$R/scripts/run.sh"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_hook_autoinstall proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"picked pre-commit: pre-commit-secrets"* ]]
    [[ "$output" == *"skipped"*"pre-commit-stack-bash"* ]]
}

@test "hook_autoinstall: --dry-run does not write hooks or .gitignore" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_hook_autoinstall proj --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run"* ]]
    [ ! -f "$R/.git/hooks/pre-commit" ]
    [ ! -f "$R/.gitignore" ]
}

@test "hook_autoinstall: idempotent (re-run is no-op)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_hook_autoinstall proj"
    cs1=$(sha256sum "$R/.git/hooks/pre-commit" "$R/.gitignore" | sort | sha256sum)
    run src "ac_hook_autoinstall proj"
    [ "$status" -eq 0 ]
    cs2=$(sha256sum "$R/.git/hooks/pre-commit" "$R/.gitignore" | sort | sha256sum)
    [ "$cs1" = "$cs2" ]
}

@test "hook_autoinstall: refuses pre-commit collision (existing different content) without breaking" {
    src "ac_registry_upsert proj '$R' scripts ''"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$R/.git/hooks/pre-commit"
    chmod +x "$R/.git/hooks/pre-commit"
    run src "ac_hook_autoinstall proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"refused"* ]]
    # Existing hook content must survive.
    grep -q "exit 0" "$R/.git/hooks/pre-commit"
    # Env step still ran.
    [ -f "$R/.gitignore" ]
}

@test "hook_autoinstall: refuses unknown project" {
    run src "ac_hook_autoinstall ghost"
    [ "$status" -ne 0 ]
}

@test "hook_autoinstall: refuses non-git path" {
    NOT="$BATS_TEST_TMPDIR/notgit"
    mkdir -p "$NOT"
    src "ac_registry_upsert nogit '$NOT' scripts ''"
    run src "ac_hook_autoinstall nogit"
    [ "$status" -ne 0 ]
}

@test "hook_autoinstall: refuses missing project name" {
    run src "ac_hook_autoinstall"
    [ "$status" -ne 0 ]
}
