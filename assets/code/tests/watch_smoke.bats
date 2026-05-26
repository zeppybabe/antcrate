#!/usr/bin/env bats
# tests for ac_watch_smoke in lib/watch.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_EVENTS_DIR="$ANTCRATE_HOME/events"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_WATCH_FORCE_COLOR=0
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    P="$ANTCRATE_ROOT/mybun"
    mkdir -p "$P/src"
    : > "$P/src/foo.ts"
    src "ac_registry_init; ac_registry_upsert mybun '$P' projects \"\""
    export P
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_EVENTS_DIR="'"$ANTCRATE_EVENTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_WATCH_FORCE_COLOR="'"$ANTCRATE_WATCH_FORCE_COLOR"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/events.sh"
        . "'"$LIB"'/watch.sh"
        '"$1"
}

@test "watch-smoke: default invocation renders anchor with ▶ .   ← latest modify" {
    out=$(src "ac_watch_smoke mybun")
    echo "$out" | grep -q '▶ .'
    echo "$out" | grep -q '← latest modify'
}

@test "watch-smoke: custom kind shows correct anchor label" {
    out=$(src "ac_watch_smoke mybun delete src/foo.ts")
    echo "$out" | grep -q '← latest delete'
}

@test "watch-smoke: custom relpath shows ● marker next to that file" {
    out=$(src "ac_watch_smoke mybun modify src/foo.ts")
    foo_line=$(echo "$out" | grep 'foo.ts')
    echo "$foo_line" | grep -q '●'
}

@test "watch-smoke: custom --ttl-ms stored in JSONL entry" {
    src "ac_watch_smoke mybun modify . --ttl-ms 99999"
    f="$ANTCRATE_EVENTS_DIR/mybun.jsonl"
    last=$(tail -1 "$f")
    ttl=$(echo "$last" | jq '.ttl_ms')
    [ "$ttl" = "99999" ]
}

@test "watch-smoke: invalid kind exits non-zero without rendering" {
    run src "ac_watch_smoke mybun wiggle ."
    [ "$status" -ne 0 ]
    # render_once would print project header; ensure it didn't run
    ! echo "$output" | grep -q 'mybun/'
}

@test "watch-smoke: unknown project exits non-zero with error" {
    run src "ac_watch_smoke ghost_project"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown"* ]] || [[ "$output" == *"ghost_project"* ]]
}

@test "watch-smoke: unknown project does NOT create ghost JSONL" {
    run src "ac_watch_smoke ghost_project"
    [ "$status" -ne 0 ]
    [ ! -e "$ANTCRATE_EVENTS_DIR/ghost_project.jsonl" ]
}

@test "watch-smoke: --depth 1 passes through (no nested entries)" {
    mkdir -p "$P/src/deep"
    : > "$P/src/deep/nested.ts"
    out=$(src "ac_watch_smoke mybun modify . --depth 1")
    # depth 1 shows the project header + immediate children only;
    # src/ appears but nested.ts should not
    echo "$out" | grep -q 'mybun/'
    ! echo "$out" | grep -q 'nested.ts'
}
