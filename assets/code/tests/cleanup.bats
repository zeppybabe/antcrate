#!/usr/bin/env bats
# tests for lib/cleanup.sh — classifier + apply

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_CLEANUP_DIR="$ANTCRATE_HOME/cleanup"
    export ANTCRATE_EVENTS_DIR="$ANTCRATE_HOME/events"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    P="$ANTCRATE_ROOT/projects/mybun"
    mkdir -p "$P/src" "$P/__pycache__" "$P/.pytest_cache" "$P/empty_dir"
    : > "$P/src/foo.py"
    : > "$P/__pycache__/foo.pyc"
    : > "$P/scratch.test.tmp"
    src 'ac_registry_init; ac_registry_upsert mybun '"$P"' projects ""'
    export P
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_CLEANUP_DIR="'"$ANTCRATE_CLEANUP_DIR"'"
        export ANTCRATE_EVENTS_DIR="'"$ANTCRATE_EVENTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/quarantine.sh"
        . "'"$LIB"'/events.sh"
        . "'"$LIB"'/cleanup.sh"
        '"$1"
}

@test "classify: lists pycache, pytest_cache, test.tmp file, empty dir" {
    out=$(src "ac_cleanup_classify mybun")
    echo "$out" | grep -q '__pycache__'
    echo "$out" | grep -q '.pytest_cache'
    echo "$out" | grep -q 'scratch.test.tmp'
    echo "$out" | grep -q 'empty_dir'
}

@test "classify: persists list with sequential ids" {
    src "ac_cleanup_classify mybun"
    list="$ANTCRATE_CLEANUP_DIR/mybun.list"
    [ -f "$list" ]
    n=$(wc -l < "$list")
    [ "$n" -ge 3 ]
    # first column is 1..N
    first=$(head -n1 "$list" | cut -f1)
    [ "$first" = "1" ]
}

@test "classify: clean project produces 'no candidates' message" {
    rm -rf "$P/__pycache__" "$P/.pytest_cache" "$P/empty_dir" "$P/scratch.test.tmp"
    out=$(src "ac_cleanup_classify mybun")
    echo "$out" | grep -q 'No cleanup candidates'
}

@test "apply: removes one candidate by id with backup" {
    src "ac_cleanup_classify mybun"
    list="$ANTCRATE_CLEANUP_DIR/mybun.list"
    # find id of __pycache__
    id=$(awk -F'\t' '$5 ~ /__pycache__$/ {print $1; exit}' "$list")
    [ -n "$id" ]
    run src "ac_cleanup_apply mybun $id"
    [ "$status" -eq 0 ]
    [ ! -d "$P/__pycache__" ]
    # backup tarball exists
    n=$(find "$ANTCRATE_BACKUP_DIR/mybun" -name '*.tar.gz' | wc -l)
    [ "$n" -ge 1 ]
}

@test "apply: emits a delete event with category as label" {
    src "ac_cleanup_classify mybun"
    list="$ANTCRATE_CLEANUP_DIR/mybun.list"
    id=$(awk -F'\t' '$5 ~ /__pycache__$/ {print $1; exit}' "$list")
    src "ac_cleanup_apply mybun $id"
    eventsfile="$ANTCRATE_EVENTS_DIR/mybun.jsonl"
    [ -f "$eventsfile" ]
    grep -q '"kind":"delete"' "$eventsfile"
    grep -q '"label":"test-tmp"' "$eventsfile"
}

@test "apply: registry recent_removals records the deletion" {
    src "ac_cleanup_classify mybun"
    list="$ANTCRATE_CLEANUP_DIR/mybun.list"
    id=$(awk -F'\t' '$5 ~ /__pycache__$/ {print $1; exit}' "$list")
    src "ac_cleanup_apply mybun $id"
    n=$(jq '.projects.mybun.recent_removals | length' "$ANTCRATE_REGISTRY")
    [ "$n" -ge 1 ]
    label=$(jq -r '.projects.mybun.recent_removals[-1].label' "$ANTCRATE_REGISTRY")
    [ "$label" = "test-tmp" ]
}

@test "apply: refuses unknown id" {
    src "ac_cleanup_classify mybun"
    run src "ac_cleanup_apply mybun 9999"
    [ "$status" -ne 0 ]
}

@test "apply: comma-separated id list works" {
    src "ac_cleanup_classify mybun"
    list="$ANTCRATE_CLEANUP_DIR/mybun.list"
    id1=$(awk -F'\t' '$5 ~ /__pycache__$/ {print $1; exit}' "$list")
    id2=$(awk -F'\t' '$5 ~ /scratch.test.tmp$/ {print $1; exit}' "$list")
    src "ac_cleanup_apply mybun $id1,$id2"
    [ ! -d "$P/__pycache__" ]
    [ ! -f "$P/scratch.test.tmp" ]
}

@test "classify: skips .git, .github, .githooks, node_modules" {
    mkdir -p "$P/.git/__pycache__" "$P/node_modules/foo/__pycache__"
    : > "$P/.git/__pycache__/x.pyc"
    : > "$P/node_modules/foo/__pycache__/x.pyc"
    src "ac_cleanup_classify mybun"
    list="$ANTCRATE_CLEANUP_DIR/mybun.list"
    ! grep -q '\.git/__pycache__' "$list"
    ! grep -q 'node_modules.*__pycache__' "$list"
}
