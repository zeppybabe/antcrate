#!/usr/bin/env bash
# antcrate :: lib/selfcheck.sh — self-source persistence health check
#
# Born from the 2026-06-09 incident: ~/projects/antcrate vanished on a
# session-limit reset, eating a working tree + 8 unpushed commits.
# ac_selfcheck verifies the dev tree is present, reachable, and insured:
#   source path  registry entry resolves on disk           (FAIL if missing)
#   skill link   ANTCRATE_SKILL_LINK resolves               (FAIL if dangling)
#   git repo     .git present at source path                (FAIL if missing)
#   unpushed     commits ahead of @{u}                      (WARN — run --pp)
#   uncommitted  dirty working tree                         (WARN)
#   backup       newest tarball age vs threshold            (WARN if stale/none)
#
# Exit: 0 = all ok, 1 = critical FAIL, 2 = warnings only.
# Sourced by wrapper. No side effects on source.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_BACKUP_DIR:=$ANTCRATE_HOME/backups}"
: "${ANTCRATE_SELF_NAME:=antcrate}"
: "${ANTCRATE_SKILL_LINK:=$HOME/.claude/skills/antcrate}"
: "${ANTCRATE_SELFCHECK_BACKUP_MAX_AGE_HOURS:=48}"

# ac_selfcheck [--quiet]
ac_selfcheck() {
    local quiet=""
    [[ "${1:-}" == "--quiet" ]] && quiet=1

    local fails=0 warns=0
    local report=""

    _sc_line() {  # <label> <verdict> <detail>
        report+="$(printf '  %-12s: %s %s' "$1" "$2" "$3")"$'\n'
        case "$2" in
            FAIL) fails=$((fails + 1)) ;;
            WARN) warns=$((warns + 1)) ;;
        esac
    }

    local self="$ANTCRATE_SELF_NAME"
    local path=""

    # source path (registry → disk)
    if ! ac_registry_has "$self"; then
        _sc_line "source path" "FAIL" "'$self' not registered"
    else
        path=$(ac_registry_get "$self" path)
        if [[ -d "$path" ]]; then
            _sc_line "source path" "ok" "($path)"
        else
            _sc_line "source path" "FAIL" "(missing: $path)"
            path=""
        fi
    fi

    # skill link (symlink must resolve; a real dir is also fine)
    if [[ -d "$ANTCRATE_SKILL_LINK" ]]; then
        if [[ -L "$ANTCRATE_SKILL_LINK" ]]; then
            _sc_line "skill link" "ok" "-> $(readlink "$ANTCRATE_SKILL_LINK")"
        else
            _sc_line "skill link" "ok" "(real directory)"
        fi
    elif [[ -L "$ANTCRATE_SKILL_LINK" ]]; then
        _sc_line "skill link" "FAIL" "(dangling -> $(readlink "$ANTCRATE_SKILL_LINK"))"
    else
        _sc_line "skill link" "FAIL" "(missing: $ANTCRATE_SKILL_LINK)"
    fi

    # git checks need a live source path
    if [[ -n "$path" ]]; then
        if [[ -d "$path/.git" ]]; then
            _sc_line "git repo" "ok" "(branch $(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null))"

            local ahead
            ahead=$(git -C "$path" rev-list --count '@{u}..HEAD' 2>/dev/null)
            if [[ -z "$ahead" ]]; then
                _sc_line "unpushed" "WARN" "(no upstream configured)"
            elif (( ahead > 0 )); then
                _sc_line "unpushed" "WARN" "($ahead commit(s) — run --pp $self)"
            else
                _sc_line "unpushed" "ok" "(0)"
            fi

            local dirty
            dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l)
            if (( dirty > 0 )); then
                _sc_line "uncommitted" "WARN" "($dirty file(s) dirty)"
            else
                _sc_line "uncommitted" "ok" ""
            fi
        else
            _sc_line "git repo" "FAIL" "(no .git at $path)"
        fi
    fi

    # backup freshness
    local newest
    newest=$(find "$ANTCRATE_BACKUP_DIR/$self" -maxdepth 1 -name '*.tar.gz' \
                 -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)
    if [[ -z "$newest" ]]; then
        _sc_line "backup" "WARN" "(none found — run --backup $self)"
    else
        local age_h
        age_h=$(( ($(date +%s) - ${newest%%.*}) / 3600 ))
        if (( age_h > ANTCRATE_SELFCHECK_BACKUP_MAX_AGE_HOURS )); then
            _sc_line "backup" "WARN" "(stale: ${age_h}h old — run --backup $self)"
        else
            _sc_line "backup" "ok" "(age ${age_h}h)"
        fi
    fi

    # verdict
    local verdict rc
    if (( fails > 0 )); then
        verdict="FAIL ($fails critical, $warns warning(s))"; rc=1
    elif (( warns > 0 )); then
        verdict="OK-WITH-WARNINGS ($warns warning(s))"; rc=2
    else
        verdict="OK"; rc=0
    fi

    if [[ -n "$quiet" ]]; then
        printf 'selfcheck: %s\n' "$verdict"
    else
        printf 'selfcheck: %s\n' "$self"
        printf '%s' "$report"
        printf 'result: %s\n' "$verdict"
    fi
    return "$rc"
}
