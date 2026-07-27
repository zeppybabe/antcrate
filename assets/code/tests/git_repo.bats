#!/usr/bin/env bats
# Tests for lib/git.sh — ac_is_git_repo, the single git-repo predicate.
#
# Audit 2026-07-24 finding A: sixteen call sites tested `[[ -d "$p/.git" ]]`,
# which is FALSE inside a git worktree or submodule (there `.git` is a regular
# file holding `gitdir: …`), so every gated command refused a valid repo.

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    T="$BATS_TEST_TMPDIR"
    R="$T/proj"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
        echo initial > README.md
        git add README.md
        git commit -qm initial
    )
}

src() { bash -c ". '$LIB/git.sh'; $1"; }

@test "git: plain repo is a repo" {
    run src "ac_is_git_repo '$R'"
    [ "$status" -eq 0 ]
}

@test "git: non-repo directory is not a repo" {
    mkdir -p "$T/plain"
    run src "ac_is_git_repo '$T/plain'"
    [ "$status" -ne 0 ]
}

@test "git: missing path is not a repo" {
    run src "ac_is_git_repo '$T/nope'"
    [ "$status" -ne 0 ]
}

@test "git: empty argument is not a repo" {
    run src "ac_is_git_repo ''"
    [ "$status" -ne 0 ]
}

@test "git: linked worktree IS a repo (.git is a file, not a dir)" {
    ( cd "$R" && git worktree add -q -b wt "$T/wt" )
    [ -f "$T/wt/.git" ]        # precondition: file, not directory
    [ ! -d "$T/wt/.git" ]
    run src "ac_is_git_repo '$T/wt'"
    [ "$status" -eq 0 ]
}

@test "git: submodule working tree IS a repo (.git is a file)" {
    S="$T/super"
    mkdir -p "$S"
    (
        cd "$S"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
        git -c protocol.file.allow=always submodule add -q "$R" sub 2>/dev/null
    )
    [ -f "$S/sub/.git" ]
    run src "ac_is_git_repo '$S/sub'"
    [ "$status" -eq 0 ]
}

@test "git: a subdirectory of a repo is NOT reported as its own repo" {
    # Callers pass a project root; walking up to a parent repo would let a
    # command act on the wrong tree.
    mkdir -p "$R/sub/dir"
    run src "ac_is_git_repo '$R/sub/dir'"
    [ "$status" -ne 0 ]
}

@test "git: bare repo directory is not a working tree" {
    git init -q --bare "$T/bare.git"
    run src "ac_is_git_repo '$T/bare.git'"
    [ "$status" -ne 0 ]
}

@test "gitpath: plain repo resolves under .git/" {
    run src "ac_git_path '$R' antcrate-hook.log"
    [ "$status" -eq 0 ]
    [ "$output" = "$R/.git/antcrate-hook.log" ]
}

@test "gitpath: output is always absolute" {
    run src "cd /; ac_git_path '$R' hooks"
    [ "$status" -eq 0 ]
    [[ "$output" == /* ]]
    [ -d "$output" ]
}

@test "gitpath: worktree hooks resolve to the SHARED common dir" {
    # git looks up hooks in the common dir for every worktree; a per-worktree
    # "$p/.git/hooks" would be a path that does not exist ($p/.git is a file).
    # Compared physically. git canonicalizes the worktree's gitdir pointer, so
    # on a host where the tmpdir sits under a symlink (macOS: /var ->
    # /private/var) the returned path is the resolved spelling while $R is not
    # — the assertion failed on macOS and passed on Linux for that reason
    # alone. Resolving both sides tests the same property on either host.
    ( cd "$R" && git worktree add -q -b wt "$T/wt" )
    run src "ac_git_path '$T/wt' hooks"
    [ "$status" -eq 0 ]
    [ -d "$output" ]
    [ "$(cd "$output" && pwd -P)" = "$(cd "$R/.git/hooks" && pwd -P)" ]
}

@test "gitpath: worktree per-repo files resolve to the worktree's own dir" {
    ( cd "$R" && git worktree add -q -b wt2 "$T/wt2" )
    run src "ac_git_path '$T/wt2' antcrate-hook.log"
    [ "$status" -eq 0 ]
    # the parent dir really exists, so a >> redirect will succeed
    [ -d "$(dirname "$output")" ]
    # compared physically — see the note on the hooks test above
    [ "$(cd "$(dirname "$output")" && pwd -P)" = "$(cd "$R/.git/worktrees/wt2" && pwd -P)" ]
    [ "$(basename "$output")" = "antcrate-hook.log" ]
}

@test "gitpath: non-repo fails, emits nothing" {
    mkdir -p "$T/plain"
    run src "ac_git_path '$T/plain' hooks"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "git: idempotent re-source" {
    run bash -c "set -euo pipefail; . '$LIB/git.sh'; . '$LIB/git.sh'; echo ok"
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
}
