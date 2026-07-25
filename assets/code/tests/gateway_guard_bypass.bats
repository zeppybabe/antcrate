#!/usr/bin/env bats
# tests for the command-semantics bypass classes in hooks/claude/gateway-guard.sh
# (duty 2026-07-25, from the plugin final review finding 6).
#
# Every case below reaches the SAME destructive effect as a command the guard
# already blocks, by a route that argv0 pattern-matching alone does not see:
#   1. interpreter indirection   — bash -c '...', sh -c "...", eval "..."
#   2. argv0 escapes             — \rm, command rm, exec rm
#   3. equivalent destructive tools — find -delete / -exec rm, git clean, rsync
#                                     --delete, truncate -s 0
#   4. un-normalized .. traversal   — a/../a defeats the prefix match

setup() {
    HOOKS="$BATS_TEST_DIRNAME/../hooks/claude"
    GUARD="$HOOKS/gateway-guard.sh"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    ROOT="$ANTCRATE_ROOT/myproj"
    mkdir -p "$ROOT/src"
    jq -n --arg p "$ROOT" \
        '{projects:{myproj:{path:$p,parent:"webapps",linked_nodes:[],git_remote:""}}}' \
        > "$ANTCRATE_REGISTRY"
}

guard() {
    jq -n --arg c "$1" '{tool_input:{command:$c}}' | "$GUARD"
}

# ---- 1. interpreter indirection ----

@test "bypass: bash -c wrapping a recursive project delete is blocked" {
    run guard "bash -c 'rm -rf $ROOT/src'"
    [ "$status" -eq 2 ]
}

@test "bypass: sh -c with double quotes is blocked" {
    run guard "sh -c \"rm -rf $ROOT/src\""
    [ "$status" -eq 2 ]
}

@test "bypass: eval wrapping a recursive project delete is blocked" {
    run guard "eval \"rm -rf $ROOT/src\""
    [ "$status" -eq 2 ]
}

@test "bypass: operators inside the -c string are still segmented" {
    run guard "bash -c 'cd /tmp && rm -rf $ROOT/src'"
    [ "$status" -eq 2 ]
}

@test "bypass: bash -c reaching the critical zone is blocked" {
    run guard "bash -c 'rm -rf $ANTCRATE_HOME'"
    [ "$status" -eq 2 ]
}

@test "bypass: nested bash -c inside bash -c is blocked" {
    run guard "bash -c \"bash -c 'rm -rf $ROOT/src'\""
    [ "$status" -eq 2 ]
}

@test "allow: bash -c doing something harmless stays silent" {
    run guard "bash -c 'echo hello'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- 2. argv0 escapes ----

@test "bypass: backslash-escaped rm is blocked" {
    run guard "\\rm -rf $ROOT/src"
    [ "$status" -eq 2 ]
}

@test "bypass: 'command rm' is blocked" {
    run guard "command rm -rf $ROOT/src"
    [ "$status" -eq 2 ]
}

@test "bypass: 'builtin' and 'exec' wrappers are peeled" {
    run guard "exec rm -rf $ROOT/src"
    [ "$status" -eq 2 ]
}

@test "bypass: absolute path to rm is blocked" {
    run guard "/bin/rm -rf $ROOT/src"
    [ "$status" -eq 2 ]
}

# ---- 3. equivalent destructive tools ----

@test "bypass: find -delete inside a project tree is blocked" {
    run guard "find $ROOT -name '*.js' -delete"
    [ "$status" -eq 2 ]
}

@test "bypass: find -exec rm inside a project tree is blocked" {
    run guard "find $ROOT -type f -exec rm -f {} ;"
    [ "$status" -eq 2 ]
}

@test "bypass: find -delete in the critical zone is blocked" {
    run guard "find $ANTCRATE_HOME -name '*.json' -delete"
    [ "$status" -eq 2 ]
}

@test "allow: find without a destructive action is silent" {
    run guard "find $ROOT -name '*.js'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "bypass: git clean -xfd on a project tree is blocked" {
    run guard "git -C $ROOT clean -xfd"
    [ "$status" -eq 2 ]
}

@test "allow: git clean -n (dry run) is not blocked" {
    run guard "git -C $ROOT clean -n"
    [ "$status" -eq 0 ]
}

@test "bypass: rsync --delete into a project tree is blocked" {
    run guard "rsync -a --delete /tmp/empty/ $ROOT/"
    [ "$status" -eq 2 ]
}

@test "allow: rsync without --delete is not blocked" {
    run guard "rsync -a /tmp/empty/ $ROOT/"
    [ "$status" -eq 0 ]
}

@test "bypass: truncate -s 0 in the critical zone is blocked" {
    run guard "truncate -s 0 $ANTCRATE_REGISTRY"
    [ "$status" -eq 2 ]
}

# ---- 4. .. path normalization ----

@test "bypass: .. traversal into the critical zone is blocked" {
    run guard "rm -rf $ANTCRATE_HOME/../.antcrate"
    [ "$status" -eq 2 ]
}

@test "bypass: .. traversal into a registered root is blocked" {
    run guard "rm -rf $ROOT/src/../src"
    [ "$status" -eq 2 ]
}

# The two above still literally prefix-match, so they pass even unnormalized.
# These are the real under-block shape from the finding: the .. escapes BEFORE
# the protected segment, so no prefix match exists until the path is collapsed.
@test "bypass: .. that re-enters the critical zone from outside is blocked" {
    run guard "rm -rf $BATS_TEST_TMPDIR/elsewhere/../.antcrate"
    [ "$status" -eq 2 ]
}

@test "bypass: .. that re-enters a registered root from outside is blocked" {
    run guard "rm -rf $ANTCRATE_ROOT/other/../myproj/src"
    [ "$status" -eq 2 ]
}

@test "bypass: redirect through .. into the critical zone is blocked" {
    run guard "echo x > $ANTCRATE_HOME/../.antcrate/registry.json"
    [ "$status" -eq 2 ]
}

@test "allow: .. that leaves the protected zones is not blocked" {
    run guard "rm -rf $ANTCRATE_ROOT/myproj/../../elsewhere/tmpdir"
    [ "$status" -ne 2 ]
}
