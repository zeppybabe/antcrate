#!/usr/bin/env bash
# antcrate :: lib/intel.sh — Anthropic intel tracker (deterministic retrieval layer)
#
# Bash owns retrieval; Claude owns judgment. Pulls a pinned, Anthropic-ONLY
# source list, normalizes HTML noise, hashes the result; a changed hash stores
# a snapshot and appends a new.jsonl row. The cognition pass (SKILL.md "Intel
# review") reads `intel ls`, files proposals, and closes with `intel ack all`.
# Append-only: nothing under $ANTCRATE_INTEL_DIR is ever deleted by the tool
# (quarantine philosophy). No LLM call ever runs inside the timer.
#
# Layout ($ANTCRATE_INTEL_DIR):
#   sources.json                  pinned source list (user-editable)
#   snapshots/<id>/<ts>-<sha8>.body   normalized fetched content
#   snapshots/<id>/latest.sha256  hash of last-seen normalized body
#   new.jsonl                     append-only {ts, source, sha256, note}
#   acked.jsonl                   append-only {ts, source, sha256, by}
#
# Public API:
#   ac_intel_pull [--quiet] [source_id]   fetch + snapshot-on-change
#   ac_intel_new [--json]                 unread rows (new minus acked)
#   ac_intel_ack <source_id> <sha256>     mark reviewed
#   ac_intel_status                       per-source pull/change/unread
#   ac_intel_status_line                  one-liner for cmd_status
#
# Internal (do not call from outside this file):
#   _ac_intel_host_allowed, _ac_intel_normalize, _ac_intel_seed_sources
# Reason: the host allowlist and normalizer must run uniformly inside pull so
# the "exclusively Anthropic" rule cannot be bypassed per-call.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_INTEL_DIR:=$ANTCRATE_HOME/intel}"
: "${ANTCRATE_INTEL_OFFLINE:=0}"        # 1 = skip all network fetching
: "${ANTCRATE_INTEL_MAX_TIME:=20}"      # curl --max-time per source

# The "exclusively Anthropic" rule, enforced in code, not convention.
# raw.githubusercontent.com/anthropics/* is the raw-content CDN for the same
# GitHub org, so it rides the github.com/anthropics/* rule.
_ac_intel_host_allowed() {
    case "$1" in
        https://www.anthropic.com/*|https://anthropic.com/*)  return 0 ;;
        https://docs.claude.com/*)                            return 0 ;;
        https://github.com/anthropics/*)                      return 0 ;;
        https://raw.githubusercontent.com/anthropics/*)       return 0 ;;
        *)                                                    return 1 ;;
    esac
}

_ac_intel_seed_sources() {
    local f="$ANTCRATE_INTEL_DIR/sources.json"
    [[ -f "$f" ]] && return 0
    mkdir -p "$ANTCRATE_INTEL_DIR"
    jq -n '{sources: [
        {id: "news",                     url: "https://www.anthropic.com/news"},
        {id: "engineering",              url: "https://www.anthropic.com/engineering"},
        {id: "release-notes-api",        url: "https://docs.claude.com/en/release-notes/api"},
        {id: "release-notes-claude-code", url: "https://docs.claude.com/en/release-notes/claude-code"},
        {id: "cc-changelog",             url: "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"},
        {id: "cc-releases",              url: "https://github.com/anthropics/claude-code/releases.atom"},
        {id: "skills-repo",              url: "https://github.com/anthropics/skills/commits/main.atom"}
    ]}' > "$f.tmp" && mv "$f.tmp" "$f"
}

# stdin -> stdout: drop script/style/nav blocks, strip tags, collapse
# whitespace, drop empty lines. Cheap, not perfect — hashes only need
# stability, not beauty (summary-level diffing is the review session's job).
_ac_intel_normalize() {
    awk '
    BEGIN { skip = 0 }
    {
        s = $0; out = ""
        while (length(s) > 0) {
            if (skip == 0) {
                i = match(s, /<(script|style|nav)[ >]/)
                if (i == 0) { out = out s; s = "" }
                else {
                    out = out substr(s, 1, i - 1)
                    s = substr(s, i + RLENGTH)
                    skip = 1
                }
            } else {
                i = match(s, /<\/(script|style|nav)>/)
                if (i == 0) { s = "" }
                else { s = substr(s, i + RLENGTH); skip = 0 }
            }
        }
        print out
    }' \
    | sed -e 's/<[^>]*>/ /g' \
    | tr -s ' \t' ' ' \
    | sed -e 's/^ //' -e 's/ $//' \
    | awk 'NF'
}

# ac_intel_pull [--quiet] [source_id]
ac_intel_pull() {
    local quiet="" only=""
    while (( $# > 0 )); do
        case "$1" in
            --quiet) quiet=1; shift ;;
            *)       only="$1"; shift ;;
        esac
    done

    _ac_intel_seed_sources
    local sources="$ANTCRATE_INTEL_DIR/sources.json"

    # validate EVERY source before fetching ANY (fail-closed on a bad host)
    local id url found=""
    while IFS=$'\t' read -r id url; do
        if ! _ac_intel_host_allowed "$url"; then
            ac_error "intel: source '$id' host not Anthropic-origin — refusing ($url)"
            return 2
        fi
        [[ -n "$only" && "$id" == "$only" ]] && found=1
    done < <(jq -r '.sources[] | "\(.id)\t\(.url)"' "$sources")

    if [[ -n "$only" && -z "$found" ]]; then
        ac_error "intel: unknown source '$only' (see $sources)"
        return 2
    fi

    if [[ "$ANTCRATE_INTEL_OFFLINE" == "1" ]]; then
        ac_warn "intel: pull skipped (ANTCRATE_INTEL_OFFLINE=1)"
        return 0
    fi

    local body norm sha last sdir snap ts
    while IFS=$'\t' read -r id url; do
        [[ -n "$only" && "$id" != "$only" ]] && continue

        if ! body=$(curl -fsSL --max-time "$ANTCRATE_INTEL_MAX_TIME" "$url"); then
            ac_warn "intel: source '$id' unreachable — continuing ($url)"
            continue
        fi
        norm=$(_ac_intel_normalize <<< "$body")
        sha=$(sha256sum <<< "$norm" | awk '{print $1}')

        sdir="$ANTCRATE_INTEL_DIR/snapshots/$id"
        mkdir -p "$sdir"
        last=""
        [[ -f "$sdir/latest.sha256" ]] && last=$(< "$sdir/latest.sha256")

        if [[ "$sha" == "$last" ]]; then
            touch "$sdir/latest.sha256"   # mtime doubles as last-pull marker
            [[ -z "$quiet" ]] && printf 'intel: %s unchanged\n' "$id"
        else
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            snap="$sdir/${ts}-${sha:0:8}.body"
            printf '%s\n' "$norm" > "$snap.tmp" && mv "$snap.tmp" "$snap"
            printf '%s\n' "$sha" > "$sdir/latest.sha256.tmp" \
                && mv "$sdir/latest.sha256.tmp" "$sdir/latest.sha256"
            jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                   --arg source "$id" --arg sha "$sha" \
                   --arg note "$(basename "$snap")" \
                   '{ts: $ts, source: $source, sha256: $sha, note: $note}' \
                >> "$ANTCRATE_INTEL_DIR/new.jsonl"
            [[ -z "$quiet" ]] && printf 'intel: %s CHANGED -> %s\n' "$id" "$snap"
        fi
    done < <(jq -r '.sources[] | "\(.id)\t\(.url)"' "$sources")
    return 0
}

# ac_intel_new [--json] — rows in new.jsonl not present in acked.jsonl
ac_intel_new() {
    local json=""
    [[ "${1:-}" == "--json" ]] && json=1
    local newf="$ANTCRATE_INTEL_DIR/new.jsonl"
    local ackf="$ANTCRATE_INTEL_DIR/acked.jsonl"
    [[ -f "$newf" ]] || return 0

    local acked="[]"
    [[ -f "$ackf" ]] && acked=$(jq -cs '[.[] | {source, sha256}]' "$ackf")

    if [[ -n "$json" ]]; then
        jq -c --argjson acked "$acked" \
            'select(. as $r | $acked | map(.source == $r.source and .sha256 == $r.sha256) | any | not)' \
            "$newf"
    else
        jq -r --argjson acked "$acked" \
            'select(. as $r | $acked | map(.source == $r.source and .sha256 == $r.sha256) | any | not)
             | "\(.source)\t\(.sha256)\t\(.ts)"' \
            "$newf"
    fi
}

# ac_intel_ack <source_id> <sha256>
ac_intel_ack() {
    local source="${1:-}" sha="${2:-}"
    if [[ -z "$source" || -z "$sha" ]]; then
        ac_error "intel: usage: --intel-ack <source_id> <sha256>"
        return 2
    fi
    mkdir -p "$ANTCRATE_INTEL_DIR"
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg source "$source" --arg sha "$sha" \
           --arg by "${ANTCRATE_AGENT:-clyde}" \
           '{ts: $ts, source: $source, sha256: $sha, by: $by}' \
        >> "$ANTCRATE_INTEL_DIR/acked.jsonl"
    printf 'intel: acked %s %s\n' "$source" "${sha:0:8}"
}

# ac_intel_ack_all [source_id] — bulk-ack unread (all, or one source's items).
# The bundled review close-out: reading happened, per-sha ceremony didn't.
ac_intel_ack_all() {
    local only="${1:-}" n=0 source sha
    while IFS=$'\t' read -r source sha; do
        [[ -n "$source" ]] || continue
        [[ -n "$only" && "$source" != "$only" ]] && continue
        ac_intel_ack "$source" "$sha" >/dev/null
        n=$((n + 1))
    done < <(ac_intel_new --json | jq -r '"\(.source)\t\(.sha256)"')
    if (( n == 0 )); then
        printf 'intel: nothing unread%s\n' "${only:+ for $only}"
    else
        printf 'intel: acked %s item(s)%s\n' "$n" "${only:+ ($only)}"
    fi
}

ac_intel_status() {
    local sources="$ANTCRATE_INTEL_DIR/sources.json"
    if [[ ! -f "$sources" ]]; then
        printf 'intel: no sources.json yet — run --intel-pull\n'
        return 0
    fi
    local unread_all
    unread_all=$(ac_intel_new --json)
    printf 'intel status\n'
    local id url marker lp lc n
    while IFS=$'\t' read -r id url; do
        marker="$ANTCRATE_INTEL_DIR/snapshots/$id/latest.sha256"
        lp="never"
        [[ -f "$marker" ]] && lp=$(date -u -d "@$(stat -c %Y "$marker")" +%Y-%m-%dT%H:%M:%SZ)
        lc=$(jq -rs --arg s "$id" '[.[] | select(.source == $s)] | (last.ts // "-")' \
                "$ANTCRATE_INTEL_DIR/new.jsonl" 2>/dev/null || printf '%s' "-")
        n=$(printf '%s\n' "$unread_all" | jq -rs --arg s "$id" '[.[] | select(.source == $s)] | length')
        printf '  %-26s last-pull %-22s last-change %-22s unread %s\n' "$id" "$lp" "$lc" "$n"
    done < <(jq -r '.sources[] | "\(.id)\t\(.url)"' "$sources")
    printf 'unread total: %s\n' "$(printf '%s' "$unread_all" | grep -c '^{' || true)"
}

# _ac_intel_age <seconds> — humanize, mirrors pp.sh's _ac_pp_age (kept local so
# this lib stays sourceable on its own)
_ac_intel_age() {
    local s=$1
    if (( s >= 86400 )); then printf '%sd %sh' $((s / 86400)) $((s % 86400 / 3600))
    elif (( s >= 3600 )); then printf '%sh %sm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%ss' "$s"; fi
}

# one-liner for cmd_status (mirrors the selfsrc line) — unread count alone says
# nothing about whether the feed is even alive, so carry sources + last pull
ac_intel_status_line() {
    local n=0 srcs=0 last="never" newest=0 m t
    n=$(ac_intel_new --json | grep -c '^{') || true
    [[ -f "$ANTCRATE_INTEL_DIR/sources.json" ]] && \
        srcs=$(jq -r '.sources | length' "$ANTCRATE_INTEL_DIR/sources.json" 2>/dev/null || printf 0)
    for m in "$ANTCRATE_INTEL_DIR"/snapshots/*/latest.sha256; do
        [[ -f "$m" ]] || continue
        t=$(stat -c %Y "$m" 2>/dev/null) || continue
        (( t > newest )) && newest=$t
    done
    (( newest > 0 )) && last="$(_ac_intel_age $(( $(date +%s) - newest ))) ago"
    printf 'intel: %s unread · %s sources · last pull %s\n' "$n" "$srcs" "$last"
}
