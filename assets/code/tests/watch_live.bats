#!/usr/bin/env bats
# tests for lib/watch.sh live-loop helpers — frame clamping, hot-project
# resolution (--follow), and loop arg validation. The loop itself is an
# infinite full-screen renderer; everything it composes is tested here.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_EVENTS_DIR="$ANTCRATE_HOME/events"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    PA="$ANTCRATE_ROOT/projects/alpha"
    PB="$ANTCRATE_ROOT/projects/beta"
    mkdir -p "$PA/src" "$PB/src"
    : > "$PA/src/a.ts"
    : > "$PB/src/b.ts"
    src 'ac_registry_init; ac_registry_upsert alpha '"$PA"' projects ""; ac_registry_upsert beta '"$PB"' projects ""'
    export PA PB
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_EVENTS_DIR="'"$ANTCRATE_EVENTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/events.sh"
        . "'"$LIB"'/watch.sh"
        '"$1"
}

# ---------- ac_watch_clamp_frame ----------

@test "clamp_frame: short frame passes through unchanged" {
    out=$(printf 'a\nb\nc\n' | src "ac_watch_clamp_frame 10")
    [ "$out" = "$(printf 'a\nb\nc')" ]
}

@test "clamp_frame: frame at exactly max rows passes through" {
    out=$(printf 'a\nb\nc\n' | src "ac_watch_clamp_frame 3")
    [ "$out" = "$(printf 'a\nb\nc')" ]
}

@test "clamp_frame: long frame truncated with +N marker" {
    out=$(printf '1\n2\n3\n4\n5\n6\n' | src "ac_watch_clamp_frame 4")
    # 3 content lines + 1 marker line = 4 rows total
    [ "$(echo "$out" | wc -l)" -eq 4 ]
    echo "$out" | head -n 3 | grep -qx '3'
    echo "$out" | tail -n 1 | grep -q '+3 more'
}

@test "clamp_frame: marker counts all dropped lines" {
    out=$(seq 1 100 | src "ac_watch_clamp_frame 10")
    [ "$(echo "$out" | wc -l)" -eq 10 ]
    echo "$out" | tail -n 1 | grep -q '+91 more'
}

# ---------- ac_watch_term_rows ----------

@test "term_rows: prints a positive integer" {
    out=$(src "ac_watch_term_rows")
    [[ "$out" =~ ^[0-9]+$ ]]
    [ "$out" -gt 0 ]
}

# ---------- ac_watch_hot_project ----------

@test "hot_project: no events dir → exit 1, no output" {
    run src "ac_watch_hot_project"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "hot_project: single active event resolves that project" {
    src "ac_events_emit alpha modify src/a.ts --ttl-ms 60000"
    out=$(src "ac_watch_hot_project")
    [ "$out" = "alpha" ]
}

@test "hot_project: newest active event wins across projects" {
    src "ac_events_emit alpha modify src/a.ts --ttl-ms 60000"
    sleep 0.05
    src "ac_events_emit beta read src/b.ts --ttl-ms 60000"
    out=$(src "ac_watch_hot_project")
    [ "$out" = "beta" ]
}

@test "hot_project: expired events do not count" {
    src "ac_events_emit alpha modify src/a.ts --ttl-ms 1"
    sleep 0.1
    run src "ac_watch_hot_project"
    [ "$status" -eq 1 ]
}

@test "hot_project: unregistered project events are skipped" {
    src "ac_events_emit alpha modify src/a.ts --ttl-ms 60000"
    # forge an events file for a project not in the registry, newer than alpha's
    sleep 0.05
    now=$(date +%s%3N)
    printf '{"ts":"x","ts_ms":%s,"kind":"modify","path":"y","agent":"t","ttl_ms":60000}\n' "$now" \
        > "$ANTCRATE_EVENTS_DIR/ghost.jsonl"
    out=$(src "ac_watch_hot_project")
    [ "$out" = "alpha" ]
}

# ---------- ac_watch_loop arg validation ----------

@test "loop: no project and no --follow → exit 2" {
    run src "ac_watch_loop"
    [ "$status" -eq 2 ]
}

# ---------- wrapper dispatch: --watch --follow ----------

@test "wrapper: --watch with no project and no --follow exits 2" {
    run "$BATS_TEST_DIRNAME/../bin/antcrate" watch --once
    [ "$status" -eq 2 ]
}

@test "wrapper: --watch --once --follow renders the hot project" {
    src "ac_events_emit beta modify src/b.ts --ttl-ms 60000"
    run "$BATS_TEST_DIRNAME/../bin/antcrate" watch --once --follow --no-color
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '^beta/'
}

@test "wrapper: --watch --once --follow with no active events exits 1" {
    run "$BATS_TEST_DIRNAME/../bin/antcrate" watch --once --follow
    [ "$status" -eq 1 ]
}

# ---------- render_once --no-color is authoritative ----------

@test "render_once: --no-color wins even with FORCE_COLOR=1 and active events" {
    src "ac_events_emit alpha modify src/a.ts --ttl-ms 60000"
    out=$(ANTCRATE_WATCH_FORCE_COLOR=1 src "ANTCRATE_WATCH_FORCE_COLOR=1 ac_watch_render_once alpha --no-color")
    plain=$(echo "$out" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    [ "$out" = "$plain" ]
}
