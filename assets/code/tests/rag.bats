#!/usr/bin/env bats
# antcrate rag — deterministic FTS5/BM25 retrieval (Plan 4, audit 2026-07-10)

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_RAG_DIR="$BATS_TEST_TMPDIR/rag"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"

    R="$ANTCRATE_ROOT/proj"
    mkdir -p "$R/src" "$R/node_modules/junk"
    printf 'the flux capacitor charges the temporal circuit\n' > "$R/src/engine.txt"
    printf 'unrelated words about gardening and soil\n'        > "$R/src/other.txt"
    printf 'flux inside noise dir must never be indexed\n'     > "$R/node_modules/junk/noise.txt"
    export R

    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'" ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL=error
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/registry.sh"
        ac_registry_init
        ac_registry_upsert proj "'"$R"'" scripts ""'
}

@test "rag: init creates the per-project db" {
    run "$BIN" rag init proj
    [ "$status" -eq 0 ]
    [ -f "$ANTCRATE_RAG_DIR/proj.db" ]
}

@test "rag: index + query finds the term with path:line" {
    "$BIN" rag init proj
    run "$BIN" rag index proj
    [ "$status" -eq 0 ]
    run "$BIN" rag q proj "flux capacitor"
    [ "$status" -eq 0 ]
    [[ "$output" == *"src/engine.txt:1"* ]]
    [[ "$output" != *"other.txt"* ]]
}

@test "rag: noise dirs are pruned" {
    "$BIN" rag init proj
    "$BIN" rag index proj
    run "$BIN" rag q proj "flux"
    [[ "$output" != *"node_modules"* ]]
}

@test "rag: incremental reindex picks up modified files" {
    "$BIN" rag init proj
    "$BIN" rag index proj
    printf 'now with a zeppelin reference\n' >> "$R/src/other.txt"
    sleep 1
    touch "$R/src/other.txt"
    run "$BIN" rag index proj
    [ "$status" -eq 0 ]
    run "$BIN" rag q proj "zeppelin"
    [[ "$output" == *"src/other.txt"* ]]
}

@test "rag: query before init errors cleanly" {
    run "$BIN" rag q proj "anything"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rag"* ]]
}

@test "rag: index skips binary files" {
    "$BIN" rag init proj
    # deterministic binary: NUL bytes guarantee grep -I classifies it binary
    # (urandom had a ~13% chance of a NUL-free block -> flaky)
    printf 'blob\x00binary\x00payload' > "$R/src/blob.bin"
    run "$BIN" rag index proj
    [ "$status" -eq 0 ]
    run "$BIN" rag q proj "blob"
    [[ "$output" != *"blob.bin"* ]]
}
