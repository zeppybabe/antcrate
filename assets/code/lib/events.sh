#!/usr/bin/env bash
# antcrate :: lib/events.sh — append-only activity event stream
#
# One JSONL file per project at $ANTCRATE_HOME/events/<project>.jsonl. Each
# line: {ts, ts_ms, kind, path, agent, ttl_ms, label?}. The stream is
# durable — the renderer (lib/watch.sh) tails it; a future ztcp fast-path
# layers notification on top, but the file is the source of truth.
#
# Event kinds:
#   modify   — file/dir written (default ttl 5000ms)
#   read     — file/dir read     (default ttl 2000ms)
#   think    — agent reasoning   (default ttl 3000ms)
#   delegate — task handed off   (default ttl 5000ms)
#   delete   — file/dir removed  (default ttl 1000ms; tombstone)
#
# Public API (callable from the wrapper or other libs):
#   ac_events_path <project>                            — jsonl file path
#   ac_events_init <project>                            — ensure file exists, prints path
#   ac_events_emit <project> <kind> <relpath> [opts]    — append one event
#   ac_events_active <project> [now_ms] [tail_n]        — TTL-filtered events
#
# Internal (do not call from outside this file):
#   ac_events_default_ttl, ac_events_valid_kind,
#   ac_events_now_ms, ac_events_iso_ts
# Reason: format/policy helpers; callers should use ac_events_emit so
# kind validation + default TTL + JSON escaping all run uniformly.

# compat.sh self-source: shims used below; guard makes re-sourcing free
# (bats tests source libs directly, without the wrapper preamble).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_EVENTS_DIR:=$ANTCRATE_HOME/events}"
: "${ANTCRATE_EVENTS_TAIL:=200}"        # how many trailing lines to scan

ac_events_default_ttl() {
    case "$1" in
        modify)   echo 5000 ;;
        read)     echo 2000 ;;
        think)    echo 3000 ;;
        delegate) echo 5000 ;;
        delete)   echo 1000 ;;
        *)        echo 2000 ;;
    esac
}

ac_events_valid_kind() {
    case "$1" in
        modify|read|think|delegate|delete) return 0 ;;
        *) return 1 ;;
    esac
}

ac_events_path() {
    local project="$1"
    printf '%s/%s.jsonl\n' "$ANTCRATE_EVENTS_DIR" "$project"
}

ac_events_init() {
    local project="$1"
    mkdir -p "$ANTCRATE_EVENTS_DIR"
    local f; f=$(ac_events_path "$project")
    [[ -f "$f" ]] || : > "$f"
    printf '%s\n' "$f"
}

ac_events_now_ms() {
    # Epoch milliseconds in one call (avoids the s/ms race a two-call
    # version had). Portable via compat: EPOCHREALTIME / GNU %3N / seconds.
    ac_now_ms
}

ac_events_iso_ts() {
    ac_now_iso_ms
}

ac_events_emit() {
    # ac_events_emit <project> <kind> <relpath> [--ttl-ms N] [--label X] [--agent A]
    local project="$1" kind="$2" relpath="$3"; shift 3
    local ttl="" label="" agent="${ANTCRATE_AGENT:-clyde}"
    while (( $# > 0 )); do
        case "$1" in
            --ttl-ms) ttl="$2"; shift 2 ;;
            --label)  label="$2"; shift 2 ;;
            --agent)  agent="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if ! ac_events_valid_kind "$kind"; then
        ac_error "events: unknown kind '$kind' (modify|read|think|delegate|delete)"
        return 2
    fi
    [[ -z "$ttl" ]] && ttl=$(ac_events_default_ttl "$kind")
    [[ "$ttl" =~ ^[0-9]+$ ]] || { ac_error "events: --ttl-ms must be integer"; return 2; }

    local f; f=$(ac_events_init "$project")
    local ts ts_ms
    ts=$(ac_events_iso_ts)
    ts_ms=$(ac_events_now_ms)

    # Build JSON via jq for safe escaping
    local line
    line=$(jq -cn \
        --arg ts "$ts" --argjson ts_ms "$ts_ms" \
        --arg kind "$kind" --arg path "$relpath" \
        --arg agent "$agent" --argjson ttl "$ttl" --arg label "$label" \
        '{ts:$ts, ts_ms:$ts_ms, kind:$kind, path:$path, agent:$agent, ttl_ms:$ttl}
         + (if $label == "" then {} else {label:$label} end)')
    printf '%s\n' "$line" >> "$f"
}

ac_events_active() {
    # ac_events_active <project> [now_ms] [tail_n]
    # Emits JSON lines whose ts_ms + ttl_ms > now_ms. Malformed lines skipped.
    local project="$1" now_ms="${2:-}" tail_n="${3:-$ANTCRATE_EVENTS_TAIL}"
    [[ -z "$now_ms" ]] && now_ms=$(ac_events_now_ms)
    local f; f=$(ac_events_path "$project")
    [[ -f "$f" ]] || return 0
    tail -n "$tail_n" "$f" 2>/dev/null \
        | jq -c --argjson now "$now_ms" 'select(.ts_ms + .ttl_ms > $now)' 2>/dev/null \
        || true
}
