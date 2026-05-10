#!/usr/bin/env bats
# tests for lib/agent_init.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    touch "$R/README.md"
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/agent_init.sh"
        '"$1"
}

@test "agent_init: creates project-scoped cody.md and attempts counter" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_agent_init proj"
    [ "$status" -eq 0 ]
    [ -f "$R/.claude/agents/proj-cody.md" ]
    [ -f "$R/.antcrate/cody-attempts.json" ]
}

@test "agent_init: pointer file contains project name and path in the body" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_agent_init proj"
    grep -q "name: proj-cody" "$R/.claude/agents/proj-cody.md"
    grep -q "$R" "$R/.claude/agents/proj-cody.md"
}

@test "agent_init: attempts counter is initialized to {}" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_agent_init proj"
    out=$(cat "$R/.antcrate/cody-attempts.json")
    [ "$out" = "{}" ]
}

@test "agent_init: idempotent (does not overwrite existing pointer)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_agent_init proj"
    # User-edited content should survive a re-init.
    printf '%s\n' "USER EDIT MARKER" >> "$R/.claude/agents/proj-cody.md"
    run src "ac_agent_init proj"
    [ "$status" -eq 0 ]
    grep -q "USER EDIT MARKER" "$R/.claude/agents/proj-cody.md"
}

@test "agent_init: idempotent (does not overwrite existing attempts counter)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_agent_init proj"
    printf '%s\n' '{"src/foo.sh:42":2}' > "$R/.antcrate/cody-attempts.json"
    run src "ac_agent_init proj"
    [ "$status" -eq 0 ]
    grep -q '"src/foo.sh:42":2' "$R/.antcrate/cody-attempts.json"
}

@test "agent_init: errors when project unregistered" {
    run src "ac_agent_init nonexistent"
    [ "$status" -ne 0 ]
    [ ! -d "$R/.claude" ]
}

@test "agent_init: errors when project name missing" {
    run src "ac_agent_init"
    [ "$status" -ne 0 ]
}

@test "agent_init: errors when project path missing on disk" {
    run src "ac_registry_upsert ghost '$BATS_TEST_TMPDIR/does-not-exist' scripts ''
             ac_agent_init ghost"
    [ "$status" -ne 0 ]
}
