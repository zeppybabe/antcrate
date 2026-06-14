#!/usr/bin/env bash
# antcrate :: lib/git_triage.sh — automated push with fail-safe conflict triage
#
# Protocol (from blueprint §5):
#   1. Halt on push rejection.
#   2. git diff vs remote → /tmp/antcrate_conflict.log (full)
#   3. Truncate first 300 lines, prepend header.
#   4. Dispatch via mailx (preferred) or sendmail (fallback).

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_CONFLICT_LOG:=/tmp/antcrate_conflict.log}"
: "${ANTCRATE_TRIAGE_LINES:=300}"

ac_triage_email() {
    # ac_triage_email — read email from config, fallback to $ANTCRATE_EMAIL
    if [[ -n "${ANTCRATE_EMAIL:-}" ]]; then
        printf '%s' "$ANTCRATE_EMAIL"; return
    fi
    if [[ -f "$ANTCRATE_CONFIG" ]]; then
        # shellcheck disable=SC1090,SC1091  # user config path resolved at runtime; not statically followable
        . "$ANTCRATE_CONFIG"
        printf '%s' "${ANTCRATE_EMAIL:-}"
    fi
}

ac_triage_dispatch() {
    # ac_triage_dispatch <project> <body_file>
    local project="$1" body_file="$2"
    local subject="AntCrate Auto-Push Failed: ${project}"
    local to; to=$(ac_triage_email)
    if [[ -z "$to" ]]; then
        ac_warn "no ANTCRATE_EMAIL configured — skipping mail dispatch (body retained at $body_file)"
        return 0
    fi
    if command -v mailx >/dev/null 2>&1; then
        if mailx -s "$subject" "$to" < "$body_file"; then
            ac_info "triage email dispatched via mailx → $to"
        else
            ac_warn "mailx failed; body retained at $body_file"
        fi
    elif command -v sendmail >/dev/null 2>&1; then
        if { printf 'To: %s\nSubject: %s\nContent-Type: text/plain\n\n' "$to" "$subject"
             cat "$body_file"; } | sendmail -t; then
            ac_info "triage email dispatched via sendmail → $to"
        else
            ac_warn "sendmail failed; body retained at $body_file"
        fi
    else
        ac_warn "neither mailx nor sendmail available — triage email skipped (body at $body_file)"
    fi
}

# ac_git_push <project> [path]  — wraps git push, engages triage on rejection.
# Operates on <path> (default $PWD) via `git -C`; no cwd mutation. If the current
# branch has no upstream, the push sets it (-u origin <branch>) so first-pushes
# route through the same triage instead of a bare hand-rolled push.
ac_git_push() {
    local project="$1" path="${2:-$PWD}"
    local stderr_file; stderr_file=$(mktemp)
    local rc=0

    # upstream-aware push (auto set-upstream on first push), stderr captured
    local up branch
    up=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [[ -z "$up" ]]; then
        branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
        git -C "$path" push -u origin "$branch" 2> "$stderr_file"; rc=$?
    else
        git -C "$path" push 2> "$stderr_file"; rc=$?
    fi

    if (( rc == 0 )); then
        rm -f "$stderr_file"
        ac_info "push ok ($project)"
        # Post-push remote-sync verification (proposal #87, Shape B).
        # Compare local HEAD to the remote-tracking ref. Mismatch here is
        # rare (push succeeded, ref-update should be atomic) but possible
        # if a force-push from another client lands between our push and
        # this check, or if something weird happens with shallow clones.
        # One extra ref read; no extra network beyond what `git push`
        # already updated locally.
        local local_head remote_head upstream
        local_head=$(git -C "$path" rev-parse HEAD 2>/dev/null || true)
        upstream=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
        if [[ -n "$upstream" ]]; then
            remote_head=$(git -C "$path" rev-parse "$upstream" 2>/dev/null || true)
            if [[ -n "$local_head" && "$local_head" == "$remote_head" ]]; then
                printf 'verify: %s in sync at %s\n' "$upstream" "${local_head:0:7}"
            else
                ac_warn "verify: $upstream divergent (local=${local_head:0:7} remote=${remote_head:0:7})"
            fi
        fi
        return 0
    fi

    ac_warn "push rejected ($project, rc=$rc) — engaging triage"

    # determine remote-tracking ref (reuse pre-push upstream; fall back to origin/<branch>)
    local upstream
    upstream="$up"
    if [[ -z "$upstream" ]]; then
        local branch; branch=$(git -C "$path" rev-parse --abbrev-ref HEAD)
        upstream="origin/$branch"
    fi

    # full diff to /tmp
    {
        printf 'AntCrate Conflict Triage Report\n'
        printf 'Project   : %s\n' "$project"
        printf 'Timestamp : %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf 'Upstream  : %s\n' "$upstream"
        printf '\n=== git push stderr ===\n'
        cat "$stderr_file"
        printf '\n=== git diff %s..HEAD ===\n' "$upstream"
        git -C "$path" diff "${upstream}..HEAD" 2>&1 || true
    } > "$ANTCRATE_CONFLICT_LOG"

    # truncated body for email
    local body; body=$(mktemp)
    {
        printf 'AntCrate Auto-Push Failed. Merge conflict detected in %s. ' "$project"
        printf 'Displaying first %s lines. Full log saved locally at %s.\n\n' \
            "$ANTCRATE_TRIAGE_LINES" "$ANTCRATE_CONFLICT_LOG"
        head -n "$ANTCRATE_TRIAGE_LINES" "$ANTCRATE_CONFLICT_LOG"
    } > "$body"

    ac_triage_dispatch "$project" "$body"

    rm -f "$stderr_file" "$body"
    return "$rc"
}
