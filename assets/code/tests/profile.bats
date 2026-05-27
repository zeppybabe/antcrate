#!/usr/bin/env bats
# tests for lib/profile.sh

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
        . "'"$LIB"'/profile.sh"
        '"$1"
}

@test "profile: empty project still emits domain + recommend pre-commit-secrets" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"domain"$'\t'"registry"$'\t'"scripts"* ]]
    [[ "$output" == *"recommend"$'\t'"hook"$'\t'"pre-commit-secrets"* ]]
}

@test "profile: detects node stack via package.json" {
    printf '{}' > "$R/package.json"
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stack"$'\t'"node"$'\t'"true"* ]]
}

@test "profile: detects rust stack via Cargo.toml" {
    printf '[package]\nname = "foo"\n' > "$R/Cargo.toml"
    run src "ac_registry_upsert proj '$R' projects ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stack"$'\t'"rust"$'\t'"true"* ]]
}

@test "profile: detects bash stack and counts *.sh files" {
    mkdir -p "$R/scripts"
    printf '#!/bin/bash\necho ok\n' > "$R/scripts/run.sh"
    printf '#!/bin/bash\necho ok\n' > "$R/scripts/reset.sh"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stack"$'\t'"bash"$'\t'"2"* ]]
    [[ "$output" == *"recommend"$'\t'"hook"$'\t'"pre-commit-stack-bash"* ]]
}

@test "profile: detects sql by file count" {
    mkdir -p "$R/sql"
    printf 'SELECT 1;\n' > "$R/sql/q1.sql"
    run src "ac_registry_upsert proj '$R' projects ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stack"$'\t'"sql"$'\t'"1"* ]]
}

@test "profile: detects tooling configs (tsconfig.json + tests dir)" {
    printf '{}' > "$R/tsconfig.json"
    mkdir -p "$R/tests"
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tooling"$'\t'"typescript"$'\t'"true"* ]]
    [[ "$output" == *"tooling"$'\t'"tests-dir"$'\t'"true"* ]]
}

@test "profile: detects .env file presence and recommends gitignore entries" {
    printf 'API_KEY=test\n' > "$R/.env"
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"env"$'\t'"env-files"$'\t'"1"* ]]
    [[ "$output" == *"recommend"$'\t'"gitignore"$'\t'".env"* ]]
    [[ "$output" == *"recommend"$'\t'"gitignore"$'\t'".env.local"* ]]
}

@test "profile: human-readable mode renders a header" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_profile proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"profile: proj"* ]]
    [[ "$output" == *"category"* ]]
}

@test "profile: errors when project unregistered" {
    run src "ac_profile_raw nonexistent"
    [ "$status" -ne 0 ]
}

@test "profile: errors when project name missing" {
    run src "ac_profile_raw"
    [ "$status" -ne 0 ]
}

@test "profile: skips heavy directories (node_modules / .git)" {
    mkdir -p "$R/node_modules/junk"
    printf 'console.log(1)\n' > "$R/node_modules/junk/a.sh"   # would inflate sh count
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_profile_raw proj"
    [ "$status" -eq 0 ]
    # No stack:bash record because the only .sh is inside node_modules.
    [[ "$output" != *"stack"$'\t'"bash"* ]]
}
