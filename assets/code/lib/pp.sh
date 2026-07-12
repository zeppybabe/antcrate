#!/usr/bin/env bash
# antcrate :: lib/pp.sh — the bundled pre-push panel (Plan 2, audit 2026-07-10)
#
# ac_pp_panel <project> <path> — ONE dense read of everything a person checks
# before pushing: branch, versions (last/stable/current), last commit, unpushed
# count, working state, milestone (ledger heads + newest plan), backup age,
# open duties. Read-only; used by --pp (before commit+push) and --info.
# Every line degrades gracefully — no git, no tags, no ledger, no backups all
# print placeholders instead of failing under the wrapper's errexit.
#
# Sourced by wrapper. Depends on log.sh; duties count is fail-soft (declare -F).

# _ac_pp_age <epoch> — humanize seconds-since as "3d 4h" / "2h 5m" / "42s"
_ac_pp_age() {
    local then="$1" now age
    now=$(date +%s); age=$(( now - then ))
    if (( age >= 86400 )); then printf '%dd %dh' $((age/86400)) $(( (age%86400)/3600 ))
    elif (( age >= 3600 )); then printf '%dh %dm' $((age/3600)) $(( (age%3600)/60 ))
    else printf '%ds' "$age"; fi
}

ac_pp_panel() {
    local project="$1" p="$2"
    [[ -d "$p" ]] || { ac_warn "panel: path missing: $p"; return 0; }

    printf '=== %s — pre-push panel ===\n' "$project"
    local branch
    branch=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch="(not a git repo)"
    printf 'branch    : %s\n' "$branch"

    if [[ "$branch" != "(not a git repo)" ]]; then
        # versions: last tag, latest non-prerelease tag, live describe
        local last_tag stable cur
        last_tag=$(git -C "$p" describe --tags --abbrev=0 2>/dev/null) || last_tag="(none)"
        stable=$(git -C "$p" tag --sort=-v:refname 2>/dev/null \
            | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' | head -1) || stable=""
        cur=$(git -C "$p" describe --tags --always --dirty 2>/dev/null) || cur="(no commits)"
        printf 'version   : last=%s stable=%s current=%s\n' \
            "$last_tag" "${stable:-(none)}" "$cur"

        printf 'last      : %s\n' \
            "$(git -C "$p" log -1 --pretty='%h %s (%cr)' 2>/dev/null || echo '(no commits)')"

        local upstream ahead
        upstream=$(git -C "$p" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || upstream=""
        if [[ -n "$upstream" ]]; then
            ahead=$(git -C "$p" rev-list --count "$upstream..HEAD" 2>/dev/null) || ahead="?"
            printf 'unpushed  : %s commit(s) vs %s\n' "$ahead" "$upstream"
        else
            printf 'unpushed  : (no upstream)\n'
        fi

        local dirty
        dirty=$(git -C "$p" status --porcelain 2>/dev/null | wc -l)
        printf 'working   : %s change(s)\n' "$dirty"
        if (( dirty > 0 )); then
            git -C "$p" diff --stat 2>/dev/null | tail -1 | sed 's/^ */            /' || true
        fi
    fi

    # milestone: first two `## ` heads of the ledger (dev/ boundary aware)
    local f heads=""
    for f in "$p/dev/ledger.md" "$p/ledger.md"; do
        if [[ -f "$f" ]]; then
            heads=$(grep -m2 '^## ' "$f" | sed 's/^## //' | cut -c1-90) || heads=""
            break
        fi
    done
    if [[ -n "$heads" ]]; then
        printf 'milestone : %s\n' "$(printf '%s\n' "$heads" | sed -n 1p)"
        local prev; prev=$(printf '%s\n' "$heads" | sed -n 2p)
        [[ -n "$prev" ]] && printf 'previous  : %s\n' "$prev"
    fi
    local d plan=""
    for d in "$p/dev/docs/plans" "$p/docs/plans"; do
        if [[ -d "$d" ]]; then
            plan=$(find "$d" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | tail -1) || plan=""
            [[ -n "$plan" ]] && break
        fi
    done
    [[ -n "$plan" ]] && printf 'plan      : %s\n' "$plan"

    # backup age + open duties (both fail-soft)
    local bdir="${ANTCRATE_BACKUP_DIR:-${ANTCRATE_HOME:-$HOME/.antcrate}/backups}/$project"
    local newest
    newest=$(find "$bdir" -maxdepth 1 -name '*.tar.gz' -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -f2-) || newest=""
    if [[ -n "$newest" ]]; then
        printf 'backup    : %s ago (%s)\n' \
            "$(_ac_pp_age "$(stat -c %Y "$newest")")" "$(basename "$newest")"
    else
        printf 'backup    : (none)\n'
    fi
    if declare -F ac_duties_status_line >/dev/null 2>&1; then
        printf '%s\n' "$(ac_duties_status_line)" | sed 's/^duties:/duties    :/'
    fi
    return 0
}

# ── dev/ mirror on pp (G2, 2026-07-12) ──────────────────────────────────────

# _ac_pp_mirror_on <project> — 0 when the project is in config `mirror_dev=a,b`
# (rule-#13 human-only key: enabling the mirror creates a private companion
# repo, so it never happens without the human writing it into config)
_ac_pp_mirror_on() {
    local list=""
    if [[ -f "${ANTCRATE_CONFIG:-}" ]]; then
        list=$(grep -E '^mirror_dev=' "$ANTCRATE_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi
    [[ ",$list," == *",$1,"* ]]
}

# ac_pp_mirror_maybe <project> <path> [--no-mirror] — runs AFTER a successful
# public push. Mirror failure warns and returns 0: the public push already
# landed and is never rolled back or failed retroactively.
ac_pp_mirror_maybe() {
    local project="$1" p="$2" flag="${3:-}"
    [[ "$flag" == "--no-mirror" ]] && return 0
    _ac_pp_mirror_on "$project" || return 0
    declare -F target_git_mirror_push >/dev/null 2>&1 || return 0
    if ! target_git_mirror_available 2>/dev/null; then
        ac_warn "mirror: git-mirror unavailable — dev/ not mirrored"
        return 0
    fi
    if [[ ! -d "$p/dev" ]]; then
        ac_warn "mirror: $project has mirror_dev on but no dev/ directory"
        return 0
    fi
    local sha
    if sha=$(target_git_mirror_push "$project" "$p/dev" 2>/dev/null); then
        printf 'mirror    : dev/ -> %s-dev @ %s\n' "$project" "${sha:0:7}"
    else
        ac_warn "mirror: dev/ mirror FAILED (public push already landed, not rolled back)"
    fi
    return 0
}
