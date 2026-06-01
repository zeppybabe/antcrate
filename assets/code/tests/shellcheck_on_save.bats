#!/usr/bin/env bats
# tests for hooks/claude/shellcheck-on-save.sh — PostToolUse / Edit|Write
# shellcheck gate, scoped to .sh files under the AntCrate code tree.
# See docs/specs/2026-05-31-harness-enforcement-layer.md.

setup() {
    HOOKS="$BATS_TEST_DIRNAME/../hooks/claude"
    SAVE="$HOOKS/shellcheck-on-save.sh"
    export ANTCRATE_CODE_ROOT="$BATS_TEST_TMPDIR/code"
    mkdir -p "$ANTCRATE_CODE_ROOT"
}

# Pipe a file_path through the hook exactly as Claude Code would.
save() {
    jq -n --arg f "$1" '{tool_input:{file_path:$f}}' | "$SAVE"
}

@test "dirty .sh under the code tree is blocked with a report" {
    f="$ANTCRATE_CODE_ROOT/dirty.sh"
    printf '#!/usr/bin/env bash\necho $UNSET_VAR\n' > "$f"
    run save "$f"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SC"* ]]
}

@test "clean .sh under the code tree passes silently" {
    f="$ANTCRATE_CODE_ROOT/clean.sh"
    printf '#!/usr/bin/env bash\nx=1\nls "$x"\n' > "$f"
    run save "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "non-.sh file under the code tree is ignored silently" {
    f="$ANTCRATE_CODE_ROOT/notes.txt"
    printf 'ls $undefined\n' > "$f"
    run save "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a .sh file outside the code tree is ignored silently" {
    out="$BATS_TEST_TMPDIR/elsewhere"
    mkdir -p "$out"
    f="$out/dirty.sh"
    printf '#!/usr/bin/env bash\nls $x\n' > "$f"
    run save "$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "missing shellcheck binary skips with a one-line note (exit 0)" {
    export ANTCRATE_SHELLCHECK="antcrate-no-such-shellcheck-xyz"
    f="$ANTCRATE_CODE_ROOT/dirty.sh"
    printf '#!/usr/bin/env bash\nls $x\n' > "$f"
    run save "$f"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}
