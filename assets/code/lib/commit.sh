#!/usr/bin/env bash
# antcrate :: lib/commit.sh — staged commit wrapper with secret-pattern guard
#
# Closes the gap where bare `git add` + `git commit` was the only path. Per
# AGENTS.md rule #11 (no bare command on a registered project when a wrapper
# exists) and rule #12 (Gateway Law: updates require backup + verify chain +
# explicit user approval, destructive step LAST).
#
# ac_commit_run <project> <msg> <mode> [files...]
#   mode is "all" (stage all modified+untracked under project root) or
#   "explicit" (stage only the listed files, paths relative to project root).
#
# Behaviors:
#  - Refuses on missing project, missing -m, missing files in explicit mode,
#    not-a-git-repo, or empty staged set after staging.
#  - Scans staged set for secret-pattern basenames (.env, *.pem, *.key,
#    id_rsa/dsa/ed25519/ecdsa, *.p12, *.pfx, secrets.y*ml, *.credentials,
#    credentials.json, .netrc). On match: unstages, lists matches, aborts.
#  - Shows diff stat + commit message preview (Gateway Law step 4).
#  - Approval (Gateway Law step 5): TTY prompts y/N; non-TTY proceeds — the
#    diff preview + Claude Code's permission layer are the approval surface
#    (audit 2026-07-10; the PREAPPROVED env retired the same day — internal
#    wrapper sub-steps use _AC_APPROVED, see ac_gate_confirm).
#  - Then commits (Gateway Law step 6). Echoes new commit SHA to stdout.

# git.sh self-source: ac_is_git_repo used below; the load guard makes
# re-sourcing free (bats tests source libs directly, without the wrapper preamble).
# scan.sh brings ac_scan_gitleaks_bin for the content guard.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git.sh"
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan.sh"

# ac_commit_unstage <repo> <pre_tree> — undo OUR staging, keep the user's.
#
# Audit 2026-07-24 (finding D). Both abort paths used to run `git reset HEAD`,
# which unstages everything — including work the user had staged before ever
# calling the wrapper. Someone who spent ten minutes in `git add -p` lost the
# lot because a stray .env rode along. The wrapper may only undo what the
# wrapper itself did.
#
# <pre_tree> is a tree object captured before staging; read-tree restores that
# exact index content, blob for blob. Empty <pre_tree> means the snapshot was
# impossible (unmerged index mid-conflict, where write-tree refuses) — then the
# old reset is still the best available answer.
ac_commit_unstage() {
    local p="$1" pre_tree="$2"
    if [[ -n "$pre_tree" ]] && git -C "$p" read-tree "$pre_tree" 2>/dev/null; then
        return 0
    fi
    git -C "$p" reset HEAD >/dev/null 2>&1 || true
}

# ac_commit_content_leaks <repo> — 0 clean, 1 leaks (findings on stdout),
# 2 gitleaks unavailable.
#
# Audit 2026-07-24 (finding E). ac_commit_secret_match only ever saw file
# NAMES, so a key pasted into config.py committed clean while a harmless
# empty .env was blocked. gitleaks was already pinned and installed with no
# caller at all. Scanning the staged DIFF (not the tree) is deliberate: this
# guard answers "does THIS commit introduce a secret", which is the question
# a commit gate should ask. Pre-existing secrets elsewhere in the repo are
# `antcrate scan`'s job.
#
# Only ADDED lines are fed to gitleaks (2026-07-27). Piping the whole diff
# meant the '-' lines counted too, so removing a secret looked exactly like
# adding one and the gate blocked the single commit that fixes a leak — found
# the hard way while committing the fix for CI's own gitleaks failure. The
# docstring above already said the question is what the commit INTRODUCES;
# the implementation just did not ask it that way. '+++' file headers are
# dropped so a path never reads as content.
ac_commit_content_leaks() {
    local p="$1" gl out rc
    gl=$(ac_scan_gitleaks_bin) || return 2
    out=$(git -C "$p" diff --cached \
            | grep '^+' | grep -v '^+++' | cut -c2- \
            | "$gl" stdin --no-banner --redact 2>&1); rc=$?
    (( rc == 0 )) && return 0
    printf '%s\n' "$out"
    return 1
}

# ac_commit_secret_match <basename> — exit 0 if it matches a secret pattern
ac_commit_secret_match() {
    local b="$1"
    case "$b" in
        .env|.env.*) return 0 ;;
        *.pem|*.key) return 0 ;;
        id_rsa|id_dsa|id_ed25519|id_ecdsa) return 0 ;;
        *.p12|*.pfx) return 0 ;;
        secrets.yml|secrets.yaml) return 0 ;;
        *.credentials|credentials.json) return 0 ;;
        .netrc) return 0 ;;
    esac
    return 1
}

ac_commit_run() {
    local project="$1" msg="$2" mode="$3"; shift 3
    local files=("$@")

    if ! ac_registry_has "$project"; then
        ac_error "commit: unknown project '$project'"; return 1
    fi
    [[ -z "$msg" ]] && { ac_error "commit: -m <message> required"; return 1; }
    [[ -n "$mode" ]] || { ac_error "commit: must pass --all-tracked or -- <files...>"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "commit: path missing: $p"; return 1; }
    ac_is_git_repo "$p" || { ac_error "commit: not a git repo: $p"; return 1; }

    # Snapshot whatever the user already had staged, so any abort below can put
    # it back exactly (finding D). Empty on an unmerged index — see ac_commit_unstage.
    local pre_tree; pre_tree=$(git -C "$p" write-tree 2>/dev/null) || pre_tree=""

    # stage
    case "$mode" in
        all)
            git -C "$p" add -A || { ac_error "commit: git add -A failed"; return 1; }
            ;;
        explicit)
            (( ${#files[@]} > 0 )) || { ac_error "commit: no files given (use --all-tracked or pass files after --)"; return 1; }
            local f
            for f in "${files[@]}"; do
                if ! git -C "$p" add -A -- "$f" 2>/dev/null; then
                    # a git-rm'd path matches nothing on disk or in the index,
                    # but its deletion may already be staged — that counts
                    if ! git -C "$p" diff --cached --name-only -- "$f" | grep -q .; then
                        ac_error "commit: failed to stage '$f'"
                        ac_commit_unstage "$p" "$pre_tree"
                        return 1
                    fi
                fi
            done
            ;;
        *)
            ac_error "commit: invalid mode '$mode'"; return 1 ;;
    esac

    # collect staged set
    local staged_files=()
    mapfile -t staged_files < <(git -C "$p" diff --cached --name-only)
    if (( ${#staged_files[@]} == 0 )); then
        printf 'commit: nothing staged (working tree clean for the requested set)\n'
        return 0
    fi

    # secret-pattern guard
    local matched=() f b
    for f in "${staged_files[@]}"; do
        b=$(basename "$f")
        if ac_commit_secret_match "$b"; then matched+=("$f"); fi
    done
    if (( ${#matched[@]} > 0 )); then
        ac_error "commit: secret-pattern files in staged set:"
        local m
        for m in "${matched[@]}"; do printf '  %s\n' "$m" >&2; done
        ac_error "commit: aborting; unstaging now. Remove or .gitignore these and retry."
        ac_commit_unstage "$p" "$pre_tree"
        return 2
    fi

    # content guard (finding E) — names cleared above, now the bytes.
    local leaks cs=0
    leaks=$(ac_commit_content_leaks "$p") || cs=$?
    if (( cs == 1 )); then
        ac_error "commit: secret CONTENT in staged diff (gitleaks, redacted):"
        printf '%s\n' "$leaks" >&2
        ac_error "commit: aborting; unstaging now. Remove the secret and retry."
        ac_commit_unstage "$p" "$pre_tree"
        return 2
    elif (( cs == 2 )); then
        ac_warn "commit: content scan SKIPPED (gitleaks unavailable — antcrate tool install gitleaks)"
    fi

    # preview (Gateway Law step 4)
    printf '\n=== antcrate --commit %s ===\n' "$project"
    printf 'project path : %s\n' "$p"
    printf 'message      : %s\n' "$msg"
    printf '\nstaged diff stat:\n'
    git -C "$p" diff --cached --stat
    printf '\nstaged file count: %d\n\n' "${#staged_files[@]}"

    # approval (Gateway Law step 5) — the preview above + Claude Code's own
    # permission gate are the approval surface; non-TTY proceeds (audit
    # 2026-07-10; PREAPPROVED env retired same day).
    if ! ac_gate_confirm "Proceed with commit?"; then
        ac_warn "commit: aborted by user; staged set preserved for inspection"
        return 0
    fi

    # execute (Gateway Law step 6)
    if ! git -C "$p" commit -qm "$msg"; then
        ac_error "commit: git commit failed"
        return 1
    fi
    local sha; sha=$(git -C "$p" rev-parse HEAD)
    ac_info "commit: $project @ $sha — $msg"
    printf '%s\n' "$sha"
}
