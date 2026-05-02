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

@test "auto_regen: emits registry.mmd and project tree.mmd" {
    src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_auto_regen proj"
    [ -f "$ANTCRATE_HOME/registry.mmd" ]
    grep -q '^graph LR' "$ANTCRATE_HOME/registry.mmd"
    [ -f "$R/docs/diagrams/tree.mmd" ]
    grep -q '^graph TD' "$R/docs/diagrams/tree.mmd"
    grep -q "main.sh" "$R/docs/diagrams/tree.mmd"
}

@test "auto_regen: opt-out via ANTCRATE_AUTO_DIAGRAMS=0" {
    src "
        export ANTCRATE_AUTO_DIAGRAMS=0
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_auto_regen proj"
    [ ! -f "$ANTCRATE_HOME/registry.mmd" ]
    [ ! -f "$R/docs/diagrams/tree.mmd" ]
}

@test "auto_regen: works with no project arg (registry only)" {
    src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_auto_regen ''"
    [ -f "$ANTCRATE_HOME/registry.mmd" ]
    [ ! -f "$R/docs/diagrams/tree.mmd" ]   # no project arg → no tree
}

@test "auto_regen: silent on stdout (composes with --touch contract)" {
    out=$(src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_auto_regen proj")
    [ -z "$out" ]
}

@test "auto_regen: does not fail when project missing from disk" {
    src "
        ac_registry_upsert ghost /nonexistent/path scripts ''
        ac_diagrams_auto_regen ghost"
    # should still produce registry diagram, no error
    [ -f "$ANTCRATE_HOME/registry.mmd" ]
}

@test "resolve_project_for_path: resolves a file inside the project root" {
    out=$(src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_resolve_project_for_path '$R/src/main.sh'")
    [ "$out" = "proj" ]
}

@test "resolve_project_for_path: resolves the project root itself" {
    out=$(src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_resolve_project_for_path '$R'")
    [ "$out" = "proj" ]
}

@test "resolve_project_for_path: returns nonzero for path outside any project" {
    run src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_resolve_project_for_path '/tmp/somewhere-else'"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "resolve_project_for_path: longest-prefix wins for nested projects" {
    # Simulate a sub-branch: child sits inside parent.
    mkdir -p "$R/sub"
    out=$(src "
        ac_registry_upsert parent '$R' scripts ''
        ac_registry_upsert child  '$R/sub' parent ''
        ac_diagrams_resolve_project_for_path '$R/sub/file.txt'")
    [ "$out" = "child" ]
}

@test "resolve_project_for_path: tolerates trailing slash on target" {
    out=$(src "
        ac_registry_upsert proj '$R' scripts ''
        ac_diagrams_resolve_project_for_path '$R/src/'")
    [ "$out" = "proj" ]
}

@test "resolve_project_for_path: empty input returns nonzero" {
    run src "ac_diagrams_resolve_project_for_path ''"
    [ "$status" -ne 0 ]
}
