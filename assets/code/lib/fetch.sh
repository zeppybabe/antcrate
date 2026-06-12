#!/usr/bin/env bash
# antcrate :: lib/fetch.sh — generic no-LLM web fetcher (spec 2026-06-11 Unit 6)
#
# Research order: TH duty -> --fetch -> model research LAST. Reuses the intel
# normalizer (_ac_intel_normalize — intel.sh is always sourced by the wrapper
# before this file). Snapshots are append-only, hash-keyed like intel's.
# Unlike intel there is NO host allowlist: this is user/orchestrator-directed
# retrieval, not a timer. http(s) only.

: "${ANTCRATE_FETCH_DIR:=${ANTCRATE_HOME:-$HOME/.antcrate}/fetch}"
: "${ANTCRATE_FETCH_MAX_TIME:=20}"

_ac_fetch_slug() {
    local u="${1#*://}"
    u="${u%%\?*}"; u="${u%/}"
    printf '%s\n' "${u//[^a-zA-Z0-9._-]/-}" | cut -c1-80
}

# ac_fetch <url> [--name slug] — fetch, normalize, snapshot, print path
ac_fetch() {
    local url="" name=""
    while (( $# > 0 )); do
        case "$1" in
            --name) name="${2:-}"; shift 2 ;;
            *) url="$1"; shift ;;
        esac
    done
    [[ -z "$url" ]] && { ac_error "fetch: usage: --fetch <url> [--name slug]"; return 2; }
    case "$url" in http://*|https://*) ;; *) ac_error "fetch: http(s) URLs only"; return 2 ;; esac
    [[ -n "$name" ]] || name=$(_ac_fetch_slug "$url")

    local body
    if ! body=$(curl -fsSL --max-time "$ANTCRATE_FETCH_MAX_TIME" "$url"); then
        ac_error "fetch: unreachable ($url)"
        return 1
    fi
    local norm sha sdir snap ts last=""
    norm=$(_ac_intel_normalize <<< "$body")
    sha=$(sha256sum <<< "$norm" | awk '{print $1}')
    sdir="$ANTCRATE_FETCH_DIR/$name"
    mkdir -p "$sdir"
    [[ -f "$sdir/latest.sha256" ]] && last=$(< "$sdir/latest.sha256")
    if [[ "$sha" == "$last" ]]; then
        snap=$(find "$sdir" -maxdepth 1 -name "*-${sha:0:8}.body" 2>/dev/null | sort | tail -1)
        printf 'fetch: unchanged — %s\n' "$snap"
        return 0
    fi
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    snap="$sdir/${ts}-${sha:0:8}.body"
    printf '%s\n' "$norm" > "$snap.tmp" && mv "$snap.tmp" "$snap"
    printf '%s\n' "$sha" > "$sdir/latest.sha256.tmp" && mv "$sdir/latest.sha256.tmp" "$sdir/latest.sha256"
    ac_info "fetch: $name -> $snap"
    printf 'fetch: %s\n' "$snap"
}
