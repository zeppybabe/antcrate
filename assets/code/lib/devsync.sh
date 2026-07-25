#!/usr/bin/env bash
# antcrate :: lib/devsync.sh — automatic dev/ provisioning + local-only context sync
#
# Why this exists (found 2026-07-24 on a real push, not in review):
# the publication boundary git-ignores CLAUDE.md, AGENTS.md, .claude/ and the
# record files so they never reach a public remote. The mirror, meanwhile, only
# carries dev/. A project that keeps its records at the repo ROOT therefore got
# the boundary WITHOUT the mirror: the files vanished from the published tree
# and were backed up nowhere. The boundary silently became a delete. rfm-music,
# antcrate-mcp and circular-pong were all in exactly that state.
#
# The obvious fix — move the records into dev/ — is wrong. Claude Code reads
# CLAUDE.md and .claude/ at the PROJECT ROOT; relocating them trades a backup
# gap for a broken toolchain. So the originals stay put and the local-only root
# surface is SYNCED into dev/context/, which the mirror already carries.
#
# Everything here is idempotent and runs unattended from `pp`, so a project
# heals itself on the next push with no operator involvement (owner directive
# 2026-07-24: "AntCrate should have everything automatically done").

[[ -n "${_AC_DEVSYNC_LOADED:-}" ]] && return 0
_AC_DEVSYNC_LOADED=1

# git.sh self-source: ac_is_git_repo + ac_git_path used below; the load guard
# makes re-sourcing free (bats tests source libs directly, without the preamble).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git.sh"

# Paths that are dev context worth mirroring. An explicit allowlist, NOT
# "everything that is git-ignored": ignored also covers .env, *.pem, *.key,
# node_modules/ and build output. Replicating credentials into a second remote
# would be a new leak, and sweeping build dirs would balloon the mirror.
_AC_DEV_CONTEXT_PATHS=(
    CLAUDE.md
    AGENTS.md
    ledger.md
    state.md
    state-archive.md
    duties.md
    composes.md
    X-POSTS.md
    .claude
    .cursor
    .windsurf
    .clinerules
    .opencode
)

# The whole boundary lives in .git/info/exclude, NOT .gitignore.
#
# Owner ruling 2026-07-24: every project should be AI-trace-free, because signs
# of AI are dev tooling and dev tooling belongs in the -dev companion. A
# .gitignore line reading '/CLAUDE.md' is itself a committed, publicly visible
# trace of AI tooling — it announces exactly what it was meant to conceal.
#
# info/exclude gives IDENTICAL local protection: git honours it for `add -A`,
# `status` and `check-ignore` the same way it honours .gitignore. The only
# difference is that it is per-repo and never committed, which is precisely the
# property wanted here. Tradeoff, accepted knowingly: a fresh clone on another
# machine starts unprotected until the first antcrate command re-provisions it,
# which `pp` now does automatically on every push.
_AC_DEV_EXCLUDE_PATHS=(
    "# AI/agent working context — mirrored to the private <project>-dev companion"
    "/CLAUDE.md"
    "/AGENTS.md"
    "/.claude/"
    "/.cursor/"
    "/.windsurf/"
    "/.clinerules/"
    "/.opencode/"
    "/.github/copilot-instructions.md"
    ""
    "# antcrate dev records + runtime state"
    "dev/"
    "/ledger.md"
    "/state.md"
    "/state-archive.md"
    "/duties.md"
    "/composes.md"
    "X-POSTS.md"
    ".antcrate/"
    ""
    "# editor / OS noise"
    "*.swp"
    "*.swo"
    "*~"
    ".DS_Store"
)

_AC_DEV_EXCLUDE_MARK="# --- antcrate publication boundary (local-only; never committed) ---"

# _ac_dev_append_block <file> <marker> <body...> — append once, never twice.
# Terminates the existing last line first: without that, the first new rule
# fuses onto an unterminated final line and BOTH rules break (audit 2026-07-24,
# finding B — that bug shipped in post.sh and is not hypothetical).
_ac_dev_append_block() {
    local file="$1" mark="$2"; shift 2
    [[ -f "$file" ]] || : > "$file"
    grep -qF "$mark" "$file" 2>/dev/null && return 0
    [[ -s "$file" && -n "$(tail -c 1 "$file")" ]] && printf '\n' >> "$file"
    { printf '%s\n' "$mark"; printf '%s\n' "$@"; } >> "$file"
}

# ac_dev_boundary <repo> — write the publication boundary into info/exclude.
# Resolved with ac_git_path so a linked worktree gets its real common dir
# instead of a path through the .git FILE (audit 2026-07-24, finding A2).
ac_dev_boundary() {
    local p="$1" ex
    ex=$(ac_git_path "$p" info/exclude) || return 1
    mkdir -p "$(dirname "$ex")" 2>/dev/null || true
    _ac_dev_append_block "$ex" "$_AC_DEV_EXCLUDE_MARK" "${_AC_DEV_EXCLUDE_PATHS[@]}"
}

# _ac_dev_is_ignored <repo> <relpath> — 0 when git would keep it out of the
# published tree. Directories are probed with and without a trailing slash so
# an anchored rule like '/.claude/' matches either spelling.
_ac_dev_is_ignored() {
    local p="$1" rel="$2"
    git -C "$p" check-ignore -q -- "$rel"   2>/dev/null && return 0
    git -C "$p" check-ignore -q -- "$rel/"  2>/dev/null && return 0
    return 1
}

# ac_dev_sync_context <repo> — mirror the local-only root surface into
# dev/context/. Copies only paths that are BOTH on the allowlist and actually
# ignored: a project that deliberately publishes its AGENTS.md keeps it out of
# the private mirror, because there it is product, not dev context.
ac_dev_sync_context() {
    local p="$1" rel src dst
    local ctx="$p/dev/context"
    mkdir -p "$ctx" || return 1
    for rel in "${_AC_DEV_CONTEXT_PATHS[@]}"; do
        src="$p/$rel"; dst="$ctx/$rel"
        if [[ -e "$src" ]] && _ac_dev_is_ignored "$p" "$rel"; then
            rm -rf -- "$dst"
            mkdir -p "$(dirname "$dst")"
            cp -a -- "$src" "$dst" || return 1
        else
            # Prune: the root file is gone (or became published), so the stale
            # context copy must go too, or the mirror keeps resurrecting a
            # record the owner deleted on purpose.
            rm -rf -- "$dst"
        fi
    done
    return 0
}

# ac_dev_untrack <repo> — drop boundary paths that are still in the index.
#
# Adding a path to .gitignore does NOT untrack it: git keeps honouring the
# index, so an already-committed CLAUDE.md keeps being published forever.
# rfm-music, antcrate-mcp and circular-pong were all in exactly that state and
# had to be corrected by hand. --cached means the working file survives; only
# the index entry goes, so the next commit records a deletion and the public
# tree stops carrying it. History is untouched — that is a separate, invasive
# operation and never something to do automatically.
ac_dev_untrack() {
    local p="$1" rel
    for rel in "${_AC_DEV_CONTEXT_PATHS[@]}"; do
        git -C "$p" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || continue
        _ac_dev_is_ignored "$p" "$rel" || continue
        git -C "$p" rm --cached -r -q --ignore-unmatch -- "$rel" 2>/dev/null || true
    done
    return 0
}

# ac_dev_ensure <repo> — the whole provisioning step, idempotent.
#
# Order is load-bearing and was got wrong first time round (caught by the
# pp_gate end-to-end test, not by review):
#   1. dev/ exists
#   2. boundary written to info/exclude — everything after it asks git what is
#      ignored, and the boundary is what makes the answer true
#   3. untrack anything the boundary now covers but the index still holds
#   4. sync the surviving local-only surface into dev/context/
#
# This MUST run before pp's `git add -A`. Provisioning after the push meant the
# auto-commit swept CLAUDE.md into the public remote and the boundary arrived
# one step too late to matter.
ac_dev_ensure() {
    local p="${1:-}"
    [[ -n "$p" ]] || return 1
    ac_is_git_repo "$p" || return 1
    mkdir -p "$p/dev" || return 1
    ac_dev_boundary "$p" || return 1
    ac_dev_untrack  "$p" || return 1
    ac_dev_sync_context "$p" || return 1
    return 0
}
