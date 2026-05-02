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
#  - Prompts y/N (Gateway Law step 5). Bypass with ANTCRATE_COMMIT_PREAPPROVED=1
#    (sanctioned for non-TTY automation; analogous to ANTCRATE_REMOVAL_PREAPPROVED
#    for rule #1).
#  - Then commits (Gateway Law step 6). Echoes new commit SHA to stdout.

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
    [[ -d "$p/.git" ]] || { ac_error "commit: not a git repo: $p"; return 1; }

    # stage
    case "$mode" in
        all)
            git -C "$p" add -A || { ac_error "commit: git add -A failed"; return 1; }
            ;;
        explicit)
            (( ${#files[@]} > 0 )) || { ac_error "commit: no files given (use --all-tracked or pass files after --)"; return 1; }
            local f
            for f in "${files[@]}"; do
                if ! git -C "$p" add -- "$f"; then
                    ac_error "commit: failed to stage '$f'"
                    git -C "$p" reset HEAD >/dev/null 2>&1 || true
                    return 1
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
        git -C "$p" reset HEAD >/dev/null 2>&1 || true
        return 2
    fi

    # preview (Gateway Law step 4)
    printf '\n=== antcrate --commit %s ===\n' "$project"
    printf 'project path : %s\n' "$p"
    printf 'message      : %s\n' "$msg"
    printf '\nstaged diff stat:\n'
    git -C "$p" diff --cached --stat
    printf '\nstaged file count: %d\n\n' "${#staged_files[@]}"

    # approval (Gateway Law step 5)
    if [[ "${ANTCRATE_COMMIT_PREAPPROVED:-0}" != "1" ]]; then
        if [[ ! -t 0 ]]; then
            ac_error "commit: not a TTY and ANTCRATE_COMMIT_PREAPPROVED=1 not set; refusing"
            git -C "$p" reset HEAD >/dev/null 2>&1 || true
            return 3
        fi
        local ans
        read -r -p "Proceed with commit? [y/N] " ans
        if [[ "${ans,,}" != "y" ]]; then
            ac_warn "commit: aborted by user; staged set preserved for inspection"
            return 0
        fi
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
