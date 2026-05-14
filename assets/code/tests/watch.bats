#!/usr/bin/env bats
# tests for lib/watch.sh — colored tree renderer

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_EVENTS_DIR="$ANTCRATE_HOME/events"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_WATCH_FORCE_COLOR=1
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    # build a small project tree + register it
    P="$ANTCRATE_ROOT/projects/mybun"
    mkdir -p "$P/src" "$P/tests"
    : > "$P/src/foo.ts"
    : > "$P/src/bar.ts"
    : > "$P/tests/test_one.ts"
    src 'ac_registry_init; ac_registry_upsert mybun '"$P"' projects ""'
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

strip_ansi() { sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g'; }

@test "render_once: prints project header and tree" {
    out=$(src "ac_watch_render_once mybun --no-color")
    echo "$out" | grep -q '^mybun/'
    echo "$out" | grep -q 'src/'
    echo "$out" | grep -q 'foo.ts'
}

@test "render_once: --no-color emits plain text (no escapes)" {
    out=$(src "ac_watch_render_once mybun --no-color")
    # equality after strip means no ANSI in the original
    plain=$(echo "$out" | strip_ansi)
    [ "$out" = "$plain" ]
}

@test "render_once: with active modify event paints yellow" {
    src "ac_events_emit mybun modify src/foo.ts --ttl-ms 60000"
    out=$(src "ac_watch_render_once mybun")
    # yellow ANSI for modify is \033[33m
    echo "$out" | grep -q $'\033\[33m'
}

@test "render_once: with active delete paints red strikethrough" {
    src "ac_events_emit mybun delete src/foo.ts --ttl-ms 60000 --label test"
    out=$(src "ac_watch_render_once mybun")
    # bright red + strikethrough = \033[91;9m
    echo "$out" | grep -q $'\033\[91;9m'
}

@test "render_once: ancestor dir colored if descendant has event" {
    src "ac_events_emit mybun modify src/foo.ts --ttl-ms 60000"
    out=$(src "ac_watch_render_once mybun")
    # should see a color escape on the line containing src/
    line=$(echo "$out" | grep 'src/')
    echo "$line" | grep -q $'\033\['
}

@test "render_once: severity wins (delete beats modify)" {
    src "ac_events_emit mybun modify src/bar.ts --ttl-ms 60000"
    src "ac_events_emit mybun delete src/foo.ts --ttl-ms 60000"
    out=$(src "ac_watch_render_once mybun")
    # the parent src/ folds via max severity = delete → strikethrough
    line=$(echo "$out" | grep 'src/')
    echo "$line" | grep -q $'\033\[91;9m'
}

@test "render_once: refuses unknown project" {
    run src "ac_watch_render_once nope --no-color"
    [ "$status" -ne 0 ]
}

@test "render_once: depth limit honored" {
    mkdir -p "$P/src/deep/very/much"
    : > "$P/src/deep/very/much/file.ts"
    out=$(src "ac_watch_render_once mybun --no-color --depth 2")
    # depth 2: project root counts as level, so we should not see "much"
    ! echo "$out" | grep -q 'much'
}

@test "render_once: no active events → no anchor header" {
    out=$(src "ac_watch_render_once mybun --no-color")
    # anchor uses ▶ ; without events the line must not appear
    ! echo "$out" | grep -q '▶'
    # first non-empty line is the project header, not the anchor
    first=$(echo "$out" | grep -v '^$' | head -n 1)
    [ "$first" = "mybun/" ]
}

@test "render_once: one active event → anchor header pins path + kind" {
    src "ac_events_emit mybun modify src/foo.ts --ttl-ms 60000"
    out=$(src "ac_watch_render_once mybun --no-color")
    # header line carries the relative path and the kind label
    echo "$out" | grep -q '▶ src/foo.ts'
    echo "$out" | grep -q '← latest modify'
}

@test "render_once: latest path gets ● marker in tree" {
    src "ac_events_emit mybun modify src/foo.ts --ttl-ms 60000"
    out=$(src "ac_watch_render_once mybun --no-color")
    # the foo.ts row picks up the dot; other rows (bar.ts) do not
    foo_line=$(echo "$out" | grep 'foo.ts')
    bar_line=$(echo "$out" | grep 'bar.ts')
    echo "$foo_line" | grep -q '●'
    ! echo "$bar_line" | grep -q '●'
}

@test "render_once: anchor follows most-recent ts_ms when multiple events" {
    src "ac_events_emit mybun modify src/foo.ts --ttl-ms 60000"
    sleep 0.05  # ensures ts_ms strictly later for bar.ts
    src "ac_events_emit mybun modify src/bar.ts --ttl-ms 60000"
    out=$(src "ac_watch_render_once mybun --no-color")
    # anchor must reflect bar.ts (later), not foo.ts
    echo "$out" | grep -q '▶ src/bar.ts'
    ! echo "$out" | grep -q '▶ src/foo.ts'
    # only bar.ts's tree row carries the marker
    bar_line=$(echo "$out" | grep 'bar.ts')
    foo_line=$(echo "$out" | grep 'foo.ts')
    echo "$bar_line" | grep -q '●'
    ! echo "$foo_line" | grep -q '●'
}
