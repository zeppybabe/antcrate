#!/usr/bin/env bats
# non-TTY destructive gate: proceed + duty record; canary fail-open (audit 2026-07-10)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_TEMPLATES="$BATS_TEST_DIRNAME/../templates"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_TEMPLATES="'"$ANTCRATE_TEMPLATES"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_DUTIES_FILE="'"$ANTCRATE_DUTIES_FILE"'"
        export ANTCRATE_CANARY_DISABLE="${ANTCRATE_CANARY_DISABLE:-0}"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/lock.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/devops.sh"
        . "'"$LIB"'/duties.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/quarantine.sh"
        . "'"$LIB"'/scaffold.sh"
        . "'"$LIB"'/subbranch.sh"
        '"$1"
}

@test "destructive: non-TTY proceeds after backup + records review duty" {
    run src '
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        ac_safety_guard_destructive alpha "test-op" "$path" </dev/null
        echo "rc=$? backup=$AC_LAST_BACKUP_PATH"'
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"backup=$ANTCRATE_BACKUP_DIR"* ]]
    grep -q '\[command\] review: test-op on alpha' "$ANTCRATE_DUTIES_FILE"
}

@test "destructive: ASSUME_TTY decline still refuses (rc=1)" {
    run src '
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        ANTCRATE_ASSUME_TTY=1 ac_safety_guard_destructive alpha "test-op" "$path" <<< "n"
        echo "rc=$?"'
    [[ "$output" == *"rc=1"* ]]
}

@test "destructive: duty recorder absent is fail-soft (no duties.sh sourced)" {
    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'" ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'" ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_TEMPLATES="'"$ANTCRATE_TEMPLATES"'" ANTCRATE_LOG_LEVEL=error
        export ANTCRATE_CANARY_DISABLE=1
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/lock.sh"; . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"; . "'"$LIB"'/safety.sh"; . "'"$LIB"'/quarantine.sh"
        . "'"$LIB"'/scaffold.sh"; . "'"$LIB"'/subbranch.sh"
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        ac_safety_guard_destructive alpha "test-op" "$path" </dev/null
        echo "rc=$?"'
    [[ "$output" == *"rc=0"* ]]
}

# (canary fail-open test removed with the canary module — atticked 2026-07-10)
