#!/usr/bin/env bash
# antcrate :: lib/git.sh — the single "is this a git repo?" predicate
#
# Audit 2026-07-24 (finding A). Sixteen call sites each open-coded
# `[[ -d "$p/.git" ]]` with its own error string. That test is FALSE inside a
# linked worktree or a submodule working tree, where `.git` is a regular FILE
# containing `gitdir: …` — so commit, post, diff, scan, and every hook op
# refused a perfectly valid repo. This project uses worktrees itself, so the
# refusal was reachable, not theoretical.
#
# Why not plain `git rev-parse --git-dir`: that walks UP to the nearest
# enclosing repo, so any subdirectory (or an unrelated tree nested under one)
# would answer yes and the caller would act on the wrong project root.
# Anchoring on `$p/.git` first keeps the predicate about THIS directory, and
# rev-parse then confirms the entry is a real gitlink rather than a stray file.
# A bare repo has no `.git` entry at all and is correctly rejected: callers
# want a working tree to stage, diff, and hook.

[[ -n "${_AC_GIT_LOADED:-}" ]] && return 0
_AC_GIT_LOADED=1

# ac_is_git_repo <path> — rc 0 iff <path> is the root of a git WORKING TREE
# (plain clone, linked worktree, or submodule). No output.
ac_is_git_repo() {
    local p="${1:-}"
    [[ -n "$p" && -e "$p/.git" ]] || return 1
    git -C "$p" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# ac_git_path <repo> <name> — absolute path to a file inside the repo's git
# dir. rc 1 (and no output) when <repo> is not a working tree.
#
# Why not "$repo/.git/$name": once ac_is_git_repo admits worktrees, that
# string is wrong twice over — $repo/.git is a FILE there, so a `>>` redirect
# fails outright, and `hooks` is not per-worktree at all. `rev-parse
# --git-path` is git's own resolver and gets both right: shared entries
# (hooks, config) land in the common dir, per-repo state (our hook log, audit
# log, bypass flag) lands in .git/worktrees/<name>/, which is precisely where
# a hook running in that worktree will look for it.
#
# --path-format=absolute would be tidier but needs git 2.31+; prefixing a
# relative answer with $repo is version-independent and identical in effect,
# since `git -C "$repo"` resolves relative output against $repo.
ac_git_path() {
    local p="${1:-}" name="${2:-}" out
    [[ -n "$p" && -n "$name" ]] || return 1
    ac_is_git_repo "$p" || return 1
    out=$(git -C "$p" rev-parse --git-path "$name" 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    [[ "$out" == /* ]] || out="$p/$out"
    printf '%s\n' "$out"
}
