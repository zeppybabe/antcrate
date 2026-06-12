#!/usr/bin/env bats
# tests for hooks/claude/activity-emitter.sh — PostToolUse hook that feeds
# the live watch view. Fail-open contract: ALWAYS exit 0; emit an activity
# event only when the touched file resolves to a registered project.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    HOOK="$BATS_TEST_DIRNAME/../hooks/claude/activity-emitter.sh"
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_EVENTS_DIR="$ANTCRATE_HOME/events"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    P="$ANTCRATE_ROOT/projects/alpha"
    mkdir -p "$P/src"
    : > "$P/src/a.ts"
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'" ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'" ANTCRATE_LOG_LEVEL=error
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/registry.sh"
        ac_registry_init; ac_registry_upsert alpha "'"$P"'" projects ""
    '
    # the hook shells out to the wrapper; point it at the source-tree binary
    export ANTCRATE_BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export P
}

payload() {
    # payload <tool> <file>
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"
}

events_file() { printf '%s/alpha.jsonl' "$ANTCRATE_EVENTS_DIR"; }

@test "emitter: Edit inside registered project emits modify event" {
    run bash -c "$(printf 'printf %%s %q | %q' "$(payload Edit "$P/src/a.ts")" "$HOOK")"
    [ "$status" -eq 0 ]
    [ -f "$(events_file)" ]
    tail -n 1 "$(events_file)" | jq -e '.kind == "modify" and .path == "src/a.ts" and .agent == "claude"'
}

@test "emitter: Write maps to modify" {
    printf '%s' "$(payload Write "$P/src/new.ts")" | "$HOOK"
    tail -n 1 "$(events_file)" | jq -e '.kind == "modify" and .path == "src/new.ts"'
}

@test "emitter: Read maps to read kind" {
    printf '%s' "$(payload Read "$P/src/a.ts")" | "$HOOK"
    tail -n 1 "$(events_file)" | jq -e '.kind == "read" and .path == "src/a.ts"'
}

@test "emitter: file outside any registered project → exit 0, no event" {
    run bash -c "printf '%s' '$(payload Edit /tmp/elsewhere.txt)' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -f "$(events_file)" ]
}

@test "emitter: unknown tool → exit 0, no event" {
    run bash -c "printf '%s' '$(payload Bash "$P/src/a.ts")' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -f "$(events_file)" ]
}

@test "emitter: malformed JSON → exit 0, no event" {
    run bash -c "printf 'not json' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ ! -f "$(events_file)" ]
}

@test "emitter: missing registry → exit 0" {
    rm -f "$ANTCRATE_REGISTRY"
    run bash -c "printf '%s' '$(payload Edit "$P/src/a.ts")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "emitter: longest prefix wins for nested projects" {
    # register a nested project under alpha
    N="$P/nested"
    mkdir -p "$N/lib"
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'" ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'" ANTCRATE_LOG_LEVEL=error
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/registry.sh"
        ac_registry_upsert nested "'"$N"'" projects ""
    '
    printf '%s' "$(payload Edit "$N/lib/x.sh")" | "$HOOK"
    [ -f "$ANTCRATE_EVENTS_DIR/nested.jsonl" ]
    tail -n 1 "$ANTCRATE_EVENTS_DIR/nested.jsonl" | jq -e '.path == "lib/x.sh"'
}
