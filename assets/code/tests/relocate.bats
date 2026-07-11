#!/usr/bin/env bats
# tests for lib/relocate.sh — relocate a project out of the skill tree into $ANTCRATE_ROOT

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    # the "claude config tree" stand-in: relocate only moves projects out of this
    export ANTCRATE_RELOCATE_SRC_PREFIX="$BATS_TEST_TMPDIR/claudeconfig"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT" "$ANTCRATE_RELOCATE_SRC_PREFIX"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT'
        export ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        export ANTCRATE_CANARY_DISABLE='1'
        export ANTCRATE_RELOCATE_SRC_PREFIX='$ANTCRATE_RELOCATE_SRC_PREFIX'
        . '$LIB/log.sh'
        . '$LIB/registry.sh'
        . '$LIB/backup.sh'
        . '$LIB/safety.sh'
        . '$LIB/relocate.sh'
        $1
    "
}

# helper: make a fake project under the relocatable prefix (the "claude" tree),
# which is OUTSIDE $ANTCRATE_ROOT, and register it.
mk_outside_project() {
    local name="$1"
    local dir="$ANTCRATE_RELOCATE_SRC_PREFIX/skills/$name"
    mkdir -p "$dir"
    printf 'hello\n' > "$dir/file.txt"
    src "ac_registry_upsert '$name' '$dir' 'claude-skills' ''"
    printf '%s' "$dir"
}

@test "relocate: missing project arg returns 2" {
    run src 'ac_relocate'
    [ "$status" -eq 2 ]
    [[ "$output" == *"requires <project>"* ]]
}

@test "relocate: unknown project returns 1" {
    run src 'ac_relocate nope'
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown project"* ]]
}

@test "relocate: project already under ANTCRATE_ROOT is refused" {
    mkdir -p "$ANTCRATE_ROOT/already"
    src "ac_registry_upsert 'already' '$ANTCRATE_ROOT/already' 'projects' ''"
    run src 'ac_relocate already'
    [ "$status" -eq 1 ]
    [[ "$output" == *"already in the projects tree"* ]]
}

@test "relocate: source outside the claude prefix is refused" {
    local dir="$ANTCRATE_HOME/elsewhere/stray"
    mkdir -p "$dir"; printf 'x\n' > "$dir/f"
    src "ac_registry_upsert 'stray' '$dir' 'misc' ''"
    run src 'ac_relocate stray'
    [ "$status" -eq 1 ]
    [[ "$output" == *"not under"* ]]
}

@test "relocate: refuses when destination already exists" {
    mk_outside_project clash >/dev/null
    mkdir -p "$ANTCRATE_ROOT/clash"
    run src 'ac_relocate clash'
    [ "$status" -eq 1 ]
    [[ "$output" == *"destination already exists"* ]]
}

@test "relocate: happy path moves tree, creates symlink, updates registry path" {
    local oldpath; oldpath=$(mk_outside_project demo)
    run src 'ac_relocate demo'
    [ "$status" -eq 0 ]
    # tree moved
    [ -d "$ANTCRATE_ROOT/demo" ]
    [ -f "$ANTCRATE_ROOT/demo/file.txt" ]
    # old path is now a symlink -> new path
    [ -L "$oldpath" ]
    [ "$(readlink "$oldpath")" = "$ANTCRATE_ROOT/demo" ]
    # registry path updated
    run src 'ac_registry_get demo path'
    [ "$output" = "$ANTCRATE_ROOT/demo" ]
}

@test "relocate --no-watch sets daemon_ignore true" {
    mk_outside_project quiet >/dev/null
    run src 'ac_relocate quiet --no-watch'
    [ "$status" -eq 0 ]
    run bash -c "jq -r '.projects.quiet.daemon_ignore' '$ANTCRATE_REGISTRY'"
    [ "$output" = "true" ]
}

@test "relocate without --no-watch leaves daemon_ignore unset" {
    mk_outside_project loud >/dev/null
    run src 'ac_relocate loud'
    [ "$status" -eq 0 ]
    run bash -c "jq -r '.projects.loud.daemon_ignore // \"null\"' '$ANTCRATE_REGISTRY'"
    [ "$output" = "null" ]
}
