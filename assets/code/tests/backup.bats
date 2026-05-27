#!/usr/bin/env bats
# tests for lib/backup.sh + safety guard

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_TEMPLATES="$BATS_TEST_DIRNAME/../templates"
    export ANTCRATE_LOG_LEVEL="error"
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
        export ANTCRATE_REMOVAL_PREAPPROVED="${ANTCRATE_REMOVAL_PREAPPROVED:-0}"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/lock.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/scaffold.sh"
        . "'"$LIB"'/subbranch.sh"
        '"$1"
}

@test "backup: creates verified tarball + manifest" {
    run src '
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        out=$(ac_backup_create alpha "$path")
        echo "TARBALL=$out"
        test -f "$out" && echo "EXISTS"
        test -f "${out}.manifest" && echo "MANIFEST"
        tar -tzf "$out" >/dev/null && echo "VALID"'
    [[ "$output" == *"TARBALL="* ]]
    [[ "$output" == *"EXISTS"* ]]
    [[ "$output" == *"MANIFEST"* ]]
    [[ "$output" == *"VALID"* ]]
}

@test "destructive guard: refuses without TTY and no preapproval" {
    run src '
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        ac_safety_guard_destructive alpha "test-rm" "$path"
        echo "rc=$?"'
    [[ "$output" == *"rc=1"* ]]
}

@test "destructive guard: PREAPPROVED=1 allows op with backup" {
    ANTCRATE_REMOVAL_PREAPPROVED=1 run src '
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        ac_safety_guard_destructive alpha "test-rm" "$path"
        echo "rc=$? backup=$AC_LAST_BACKUP_PATH"
        test -f "$AC_LAST_BACKUP_PATH" && echo "BACKUP_EXISTS"'
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"BACKUP_EXISTS"* ]]
}

@test "destructive guard: refuses path outside zones" {
    ANTCRATE_REMOVAL_PREAPPROVED=1 run src '
        ac_safety_guard_destructive alpha "test-rm" "/etc/passwd"
        echo "rc=$?"'
    [[ "$output" == *"rc=1"* ]]
}

@test "subbranch: backup is created before move" {
    ANTCRATE_REMOVAL_PREAPPROVED=1 run src '
        ac_action_start photoapp webapps html
        ac_subbranch_expand coolwebapps photoapp
        ls "$ANTCRATE_BACKUP_DIR/photoapp"/*.tar.gz | wc -l'
    [[ "$output" == *"1"* ]]
}

@test "restore: latest backup restores tree" {
    ANTCRATE_REMOVAL_PREAPPROVED=1 ANTCRATE_RESTORE_OVERWRITE=1 run src '
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        echo "modified" > "$path/index.html"
        ac_backup_create alpha "$path" >/dev/null
        echo "post-backup-mod" > "$path/index.html"
        ac_backup_restore alpha
        cat "$path/index.html"'
    [[ "$output" == *"modified"* ]]
    [[ ! "$output" == *"post-backup-mod"* ]]
}

@test "backup retention: prunes oldest beyond ANTCRATE_BACKUP_RETENTION" {
    ANTCRATE_BACKUP_RETENTION=2 run src '
        ac_action_start alpha webapps html
        path=$(ac_registry_get alpha path)
        for i in 1 2 3 4; do
            ac_backup_create alpha "$path" >/dev/null
            sleep 1.1
        done
        ls "$ANTCRATE_BACKUP_DIR/alpha"/*.tar.gz | wc -l'
    [[ "$output" == *"2"* ]]
}
