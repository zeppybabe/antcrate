#!/usr/bin/env bats
# tests for lib/diagrams.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"/{src,docs}
    touch "$R/README.md" "$R/Dockerfile"
    touch "$R/src/main.sh"
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/address.sh"
        . "'"$LIB"'/devops.sh"
        . "'"$LIB"'/diagrams.sh"
        '"$1"
}

@test "scaffold: writes architecture.mmd if absent" {
    run src "ac_diagrams_scaffold $R alpha"
    [ "$status" -eq 0 ]
    [ -f "$R/docs/diagrams/architecture.mmd" ]
    grep -q '^graph TD' "$R/docs/diagrams/architecture.mmd"
    grep -q "alpha" "$R/docs/diagrams/architecture.mmd"
}

@test "scaffold: idempotent (does not overwrite existing)" {
    mkdir -p "$R/docs/diagrams"
    echo "custom" > "$R/docs/diagrams/architecture.mmd"
    src "ac_diagrams_scaffold $R alpha"
    [ "$(cat "$R/docs/diagrams/architecture.mmd")" = "custom" ]
}

@test "registry_to_mermaid: emits header + node lines" {
    out=$(src '
        ac_registry_upsert alpha /tmp/alpha proj r1
        ac_registry_upsert beta  /tmp/beta  proj r2
        ac_registry_link alpha beta
        ac_diagrams_registry_to_mermaid')
    [[ "$out" == *"graph LR"* ]]
    [[ "$out" == *"alpha"* ]]
    [[ "$out" == *"beta"* ]]
    [[ "$out" == *"<-->"* ]]
}

@test "registry_to_mermaid: archived projects get archived class" {
    out=$(src '
        ac_registry_upsert ghost /t/g _archived r
        ac_diagrams_registry_to_mermaid')
    [[ "$out" == *"classDef archived"* ]]
    [[ "$out" == *"class ghost archived"* ]]
}

@test "tree_to_mermaid: emits root + addressed nodes + edges" {
    out=$(src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_tree_to_mermaid proj")
    [[ "$out" == *"graph TD"* ]]
    [[ "$out" == *'root(["proj"])'* ]]
    [[ "$out" == *"main.sh"* ]]
    [[ "$out" == *"src"* ]]
}

@test "render: skips gracefully when tools missing" {
    src "ac_registry_upsert proj '$R' scripts ''"
    mkdir -p "$R/docs/diagrams"
    cp "$R/Dockerfile" "$R/docs/diagrams/sample.mmd"   # any text file
    run src '
        export PATH="/nonexistent"
        ac_diagrams_render proj'
    [ "$status" -eq 0 ]   # never errors out, just warns
}

@test "_parent_addr: 1a3 -> 1a, 1a -> 1, 1 -> empty" {
    [ "$(src 'export -f _ac_diagrams_parent_addr 2>/dev/null; _ac_diagrams_parent_addr 1a3')" = "1a" ]
    [ "$(src '_ac_diagrams_parent_addr 1a')" = "1" ]
    [ "$(src '_ac_diagrams_parent_addr 1')" = "" ]
    [ "$(src '_ac_diagrams_parent_addr 11ab2')" = "11ab" ]
}
