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

# ---- 5. backslash-newline continuation (audit 2026-07-25, finding A) ----
#
# bash joins `cmd \<newline>args` into ONE command; a line-oriented scanner saw
# two, so the operands landed in a segment whose argv0 was a path fragment and
# no rule matched. Reproduced live before the fix: `rm -rf \` + `/etc` drew
# "WARN neutral-zone delete: <cwd>/\" instead of a block.

@test "continuation: critical-zone delete split across lines is blocked" {
    run guard "$(printf 'rm -rf \\\n/etc')"
    [ "$status" -eq 2 ]
    [[ "$output" == *"critical-zone delete: /etc"* ]]
}

@test "continuation: registered-root delete split across lines is blocked" {
    run guard "$(printf 'rm -rf \\\n%s' "$ROOT")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"registered project root"* ]]
}

@test "continuation: recursive delete inside a tree, split across lines, is blocked" {
    run guard "$(printf 'rm -rf \\\n%s/src' "$ROOT")"
    [ "$status" -eq 2 ]
}

@test "continuation: tab-indented continuation line is blocked" {
    run guard "$(printf 'rm -rf \\\n\t/etc')"
    [ "$status" -eq 2 ]
}

@test "continuation: interpreter indirection split across lines is blocked" {
    run guard "$(printf 'bash -c \\\n"rm -rf /etc"')"
    [ "$status" -eq 2 ]
}

# An ESCAPED backslash does not continue the line — folding it anyway would
# glue two genuinely separate commands together.
@test "continuation: an escaped trailing backslash is not a continuation" {
    run guard "$(printf 'echo one \\\\\nls /etc')"
    [ "$status" -ne 2 ]
}

# Ordering guard: heredoc bodies are neutralised BEFORE the fold. Fold first and
# a body line ending in a backslash hides the closing marker, swallowing every
# following command as heredoc data — which would be a NEW bypass.
@test "continuation: a heredoc body backslash does not swallow the next command" {
    run guard "$(printf 'cat <<EOF\nx \\\nEOF\nrm -rf /etc\n')"
    [ "$status" -eq 2 ]
    [[ "$output" == *"critical-zone delete: /etc"* ]]
}

@test "continuation: heredoc bodies are still treated as data" {
    run guard "$(printf 'cat <<EOF\nrm -rf /etc\nEOF\n')"
    [ "$status" -ne 2 ]
}

# ---- 6. xargs (audit 2026-07-25, finding B) ----
#
# `… | xargs rm -rf` was read as an invocation of "xargs" and drew no verdict at
# all, while find -delete, rsync --delete, git clean -f, truncate and shred were
# each covered.

@test "xargs: a literal critical-zone operand is blocked" {
    run guard "find . | xargs rm -rf /etc"
    [ "$status" -eq 2 ]
    [[ "$output" == *"critical-zone delete: /etc"* ]]
}

@test "xargs: a literal registered-root operand is blocked" {
    run guard "echo x | xargs rm -rf $ROOT"
    [ "$status" -eq 2 ]
}

@test "xargs: stdin-fed deletion warns rather than passing silently" {
    run guard "find . -name '*.log' | xargs rm -rf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"via xargs"* ]]
}

@test "xargs: option values are skipped when finding the inner command" {
    run guard "echo x | xargs -n 1 -P 4 rm -rf /etc"
    [ "$status" -eq 2 ]
}

@test "xargs: the dangerous-argv0 catalogue applies to the inner command" {
    run guard "echo x | xargs dd of=/dev/sda"
    [ "$status" -eq 2 ]
    [[ "$output" == *"dangerous command: dd"* ]]
}

@test "xargs: a harmless inner command is still silent" {
    run guard "echo x | xargs echo"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "xargs: bare xargs with no inner command does not crash" {
    run guard "echo x | xargs"
    [ "$status" -eq 0 ]
}
