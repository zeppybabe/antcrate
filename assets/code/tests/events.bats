#!/usr/bin/env bats
# tests for lib/events.sh — activity event stream

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_EVENTS_DIR="$ANTCRATE_HOME/events"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_EVENTS_DIR="'"$ANTCRATE_EVENTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/events.sh"
        '"$1"
}

@test "init creates jsonl file under events dir" {
    f=$(src "ac_events_init mybun")
    [ -f "$f" ]
    [[ "$f" == *"events/mybun.jsonl" ]]
}

@test "emit appends one valid JSON line per call" {
    src "ac_events_emit mybun modify src/foo.ts"
    src "ac_events_emit mybun read  src/bar.ts"
    f="$ANTCRATE_EVENTS_DIR/mybun.jsonl"
    n=$(wc -l < "$f")
    [ "$n" = "2" ]
    # both lines parse as JSON with required fields
    while IFS= read -r line; do
        echo "$line" | jq -e '.ts and .ts_ms and .kind and .path and .ttl_ms' >/dev/null
    done < "$f"
}

@test "emit rejects unknown kind" {
    run src "ac_events_emit mybun wiggle src/foo"
    [ "$status" -ne 0 ]
}

@test "emit rejects non-integer ttl-ms" {
    run src "ac_events_emit mybun modify src/foo --ttl-ms abc"
    [ "$status" -ne 0 ]
}

@test "active filters out expired events" {
    # emit with very short ttl, then wait past it
    src "ac_events_emit mybun modify foo --ttl-ms 100"
    sleep 0.3
    out=$(src "ac_events_active mybun")
    [ -z "$out" ]
}

@test "active includes still-live events" {
    src "ac_events_emit mybun modify foo --ttl-ms 60000"
    out=$(src "ac_events_active mybun")
    [ -n "$out" ]
    echo "$out" | jq -e '.kind == "modify"' >/dev/null
}

@test "active tolerates malformed lines without crashing" {
    src "ac_events_emit mybun modify foo --ttl-ms 60000"
    f="$ANTCRATE_EVENTS_DIR/mybun.jsonl"
    echo "this is not json" >> "$f"
    out=$(src "ac_events_active mybun")
    n=$(echo "$out" | grep -c modify || true)
    [ "$n" = "1" ]
}

@test "default ttl varies by kind" {
    src "ac_events_emit mybun delete foo"
    src "ac_events_emit mybun modify bar"
    f="$ANTCRATE_EVENTS_DIR/mybun.jsonl"
    del=$(jq -r 'select(.kind=="delete") | .ttl_ms' "$f")
    mod=$(jq -r 'select(.kind=="modify") | .ttl_ms' "$f")
    [ "$del" = "1000" ]
    [ "$mod" = "5000" ]
}

@test "label is preserved when provided" {
    src "ac_events_emit mybun delete foo --label test"
    f="$ANTCRATE_EVENTS_DIR/mybun.jsonl"
    label=$(jq -r '.label' "$f")
    [ "$label" = "test" ]
}

@test "agent override flows into the event" {
    src "ac_events_emit mybun think foo --agent cody"
    f="$ANTCRATE_EVENTS_DIR/mybun.jsonl"
    a=$(jq -r '.agent' "$f")
    [ "$a" = "cody" ]
}
