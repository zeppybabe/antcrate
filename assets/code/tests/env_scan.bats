#!/usr/bin/env bats
# tests for lib/env_scan.sh

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
        . "'"$LIB"'/env_scan.sh"
        '"$1"
}

@test "env_scan: empty project reports zero env files and zero refs" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_env_scan proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *".env files found (0)"* ]]
    [[ "$output" == *"env-var references in source: 0"* ]]
}

@test "env_scan: detects .env file" {
    printf 'API_KEY=test\n' > "$R/.env"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_env_scan proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *".env files found (1)"* ]]
    [[ "$output" == *"$R/.env"* ]]
}

@test "env_scan: ignores .env.example (safe to commit)" {
    printf 'API_KEY=\n' > "$R/.env.example"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_env_scan proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *".env files found (0)"* ]]
    [[ "$output" == *".env.example: present"* ]]
}

@test "env_scan: counts process.env references in JS" {
    printf 'const k = process.env.API_KEY\nconst u = process.env.URL\n' > "$R/app.js"
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_env_scan proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"env-var references in source: 2"* ]]
}

@test "env_scan: counts os.environ references in Python" {
    printf 'import os\nk = os.environ.get("KEY")\nu = os.getenv("URL")\n' > "$R/app.py"
    run src "ac_registry_upsert proj '$R' projects ''
             ac_env_scan proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"env-var references in source: 2"* ]]
}

@test "env_scan: --apply creates .gitignore with safe patterns" {
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_env_scan proj --apply"
    [ "$status" -eq 0 ]
    [ -f "$R/.gitignore" ]
    grep -qFx ".env"           "$R/.gitignore"
    grep -qFx ".env.local"     "$R/.gitignore"
    grep -qFx ".env.*.local"   "$R/.gitignore"
}

@test "env_scan: --apply is idempotent (re-run does not duplicate lines)" {
    src "ac_registry_upsert proj '$R' webapps ''
         ac_env_scan proj --apply"
    src "ac_env_scan proj --apply"
    cnt=$(grep -cFx ".env" "$R/.gitignore")
    [ "$cnt" = "1" ]
}

@test "env_scan: --apply skips entries already in .gitignore" {
    printf '%s\n' ".env" > "$R/.gitignore"
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_env_scan proj --apply"
    [ "$status" -eq 0 ]
    cnt=$(grep -cFx ".env" "$R/.gitignore")
    [ "$cnt" = "1" ]
    grep -qFx ".env.local"   "$R/.gitignore"
    grep -qFx ".env.*.local" "$R/.gitignore"
}

@test "env_scan: refuses unknown project" {
    run src "ac_env_scan ghost"
    [ "$status" -ne 0 ]
}

@test "env_scan: refuses missing project name" {
    run src "ac_env_scan"
    [ "$status" -ne 0 ]
}

@test "env_scan: skips heavy directories" {
    mkdir -p "$R/node_modules/junk"
    printf 'process.env.X\n' > "$R/node_modules/junk/x.js"
    run src "ac_registry_upsert proj '$R' webapps ''
             ac_env_scan proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"env-var references in source: 0"* ]]
}
