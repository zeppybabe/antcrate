#!/usr/bin/env bash
# session-digest.sh — Claude Code SessionStart hook.
#
# Injects the three state deltas an agent would otherwise spend tokens asking
# for: open duties, unread intel, and dirty/unpushed registered projects.
# Prints NOTHING when all three are clean, so a quiet session costs zero
# tokens. Read-only by construction: it opens files and runs read-only git
# queries, and writes nowhere.
#
# Fail-open contract: any missing file, absent tool, or malformed JSON drops
# that one signal. Every exit path is exit 0 — a SessionStart hook must never
# be able to stop a session from starting.
#
# Env: ANTCRATE_DIGEST_DISABLE=1  skip the hook entirely
#      ANTCRATE_DIGEST_GIT=0      skip the git sweep (the only slow part)
#      ANTCRATE_DIGEST_BUDGET     git sweep wall-clock budget, seconds (default 2)
#      ANTCRATE_REGISTRY / ANTCRATE_DATA_HOME / XDG_DATA_HOME  registry location
#      ANTCRATE_INTEL_DIR         intel dir (default <data home>/intel)
#      ANTCRATE_DUTIES_FILE       duties checklist (default <selfsrc>/dev/duties.md)
#
# NOTE: no `set -e` — a failed sub-check must skip its signal, not abort.
set -uo pipefail

[ "${ANTCRATE_DIGEST_DISABLE:-0}" = "1" ] && exit 0
cat >/dev/null 2>&1 || true          # drain the payload; we do not need it
command -v jq >/dev/null 2>&1 || exit 0

# ---- path resolution (mirrors lib/paths.sh and hooks/claude/_zones.sh) ------
data_home="${ANTCRATE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/antcrate}"
registry="${ANTCRATE_REGISTRY:-}"
if [ -z "$registry" ]; then
    if [ -r "$data_home/registry.json" ] || [ ! -r "$HOME/.antcrate/registry.json" ]; then
        registry="$data_home/registry.json"
    else
        registry="$HOME/.antcrate/registry.json"
    fi
fi
intel_dir="${ANTCRATE_INTEL_DIR:-$data_home/intel}"

duties_file="${ANTCRATE_DUTIES_FILE:-}"
if [ -z "$duties_file" ]; then
    selfsrc="${ANTCRATE_SELFSRC:-$HOME/.claude/skills/antcrate}"
    if   [ -f "$selfsrc/dev/duties.md" ]; then duties_file="$selfsrc/dev/duties.md"
    else duties_file="$selfsrc/duties.md"
    fi
fi

parts=()

# ---- duties: unchecked boxes, plus the oldest ISO date among them -----------
if [ -r "$duties_file" ]; then
    open_lines="$(grep -c -- '- \[ \]' "$duties_file" 2>/dev/null || true)"
    open_lines="${open_lines:-0}"
    if [ "$open_lines" -gt 0 ] 2>/dev/null; then
        oldest="$(grep -- '- \[ \]' "$duties_file" 2>/dev/null \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | head -n 1)"
        if [ -n "$oldest" ]; then
            parts+=("$open_lines duties open (oldest $oldest)")
        else
            parts+=("$open_lines duties open")
        fi
    fi
fi

# ---- intel: rows in new.jsonl absent from acked.jsonl, matched source+sha ---
if [ -r "$intel_dir/new.jsonl" ]; then
    acked='[]'
    [ -r "$intel_dir/acked.jsonl" ] && \
        acked="$(jq -cs '[.[] | {source, sha256}]' "$intel_dir/acked.jsonl" 2>/dev/null || echo '[]')"
    unread="$(jq -r --argjson acked "$acked" \
        'select(. as $r | $acked | map(.source == $r.source and .sha256 == $r.sha256) | any | not) | 1' \
        "$intel_dir/new.jsonl" 2>/dev/null | grep -c 1 || true)"
    unread="${unread:-0}"
    [ "$unread" -gt 0 ] 2>/dev/null && parts+=("$unread intel unread")
fi

# ---- working trees: dirty and unpushed counts, bounded by a time budget -----
if [ "${ANTCRATE_DIGEST_GIT:-1}" != "0" ] && [ -r "$registry" ] && command -v git >/dev/null 2>&1; then
    budget="${ANTCRATE_DIGEST_BUDGET:-2}"
    started=$SECONDS
    dirty=0; unpushed=0; skipped=0
    dirty_names=()
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ $(( SECONDS - started )) -ge "$budget" ]; then
            skipped=$(( skipped + 1 )); continue
        fi
        [ -e "$p/.git" ] || continue        # .git is a FILE in a worktree
        if [ -n "$(git -C "$p" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            dirty=$(( dirty + 1 ))
            [ "${#dirty_names[@]}" -lt 3 ] && dirty_names+=("$(basename "$p")")
        fi
        ahead="$(git -C "$p" rev-list --count '@{u}..HEAD' 2>/dev/null || true)"
        [ "${ahead:-0}" -gt 0 ] 2>/dev/null && unpushed=$(( unpushed + 1 ))
    done < <(jq -r '.projects[]?.path // empty' "$registry" 2>/dev/null)

    if [ "$dirty" -gt 0 ]; then
        names=""
        for n in "${dirty_names[@]:-}"; do
            [ -n "$n" ] || continue
            if [ -z "$names" ]; then names="$n"; else names="$names, $n"; fi
        done
        parts+=("$dirty dirty ($names)")
    fi
    [ "$unpushed" -gt 0 ] && parts+=("$unpushed unpushed")
    # Never present a partial sweep as a total.
    [ "$skipped" -gt 0 ] && parts+=("$skipped project(s) not checked — time budget")
fi

# ---- emit, or stay silent --------------------------------------------------
[ "${#parts[@]}" -eq 0 ] && exit 0
line=""
for p in "${parts[@]}"; do
    if [ -z "$line" ]; then line="$p"; else line="$line · $p"; fi
done
printf 'antcrate: %s\n' "$line"
exit 0
