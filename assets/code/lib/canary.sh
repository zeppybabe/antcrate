#!/usr/bin/env bash
# antcrate :: lib/canary.sh — compaction canary (Wave 1 safety gate)
#
# Public API:
#   ac_canary_core_bin              — echoes path to antcrate-core; nonzero if not found
#   ac_canary_init [opts]           — init or refresh the canary state
#   ac_canary_verify <token>        — verify a token against live state
#   ac_canary_status                — pretty-print canary status JSON
#   ac_canary_gate_check            — 0=fresh, 4=stale (prints UX), 2=missing
#   ac_canary_patch_claudemd <tok>  — substitute __CANARY_TOKEN__ in $ANTCRATE_CLAUDEMD
#
# Internal (do not call directly):
#   _ac_canary_format_stale_message  — framed UX box for stale-gate output

: "${ANTCRATE_CANARY_DISABLE:=0}"
: "${ANTCRATE_CANARY_TTL_SECONDS:=3600}"
: "${ANTCRATE_CANARY_MAX_INVOCATIONS:=30}"
: "${ANTCRATE_CLAUDEMD:=$HOME/CLAUDE.md}"

# ─── core binary resolution ──────────────────────────────────────────────────

ac_canary_core_bin() {
    local bin
    if bin=$(command -v antcrate-core 2>/dev/null); then
        printf '%s\n' "$bin"; return 0
    fi
    if [[ -n "${ANTCRATE_HOME:-}" && -x "$ANTCRATE_HOME/bin/antcrate-core" ]]; then
        printf '%s\n' "$ANTCRATE_HOME/bin/antcrate-core"; return 0
    fi
    if [[ -n "${ANTCRATE_SELFSRC:-}" && -x "$ANTCRATE_SELFSRC/core/build/antcrate-core" ]]; then
        printf '%s\n' "$ANTCRATE_SELFSRC/core/build/antcrate-core"; return 0
    fi
    ac_error "canary: antcrate-core not found; run 'antcrate --install-from-source' or 'cmake --build core/build'"
    return 1
}

# ─── init ────────────────────────────────────────────────────────────────────

ac_canary_init() {
    local ttl="" maxv="" with_claudemd=""
    while (( $# > 0 )); do
        case "${1:-}" in
            --ttl-seconds)     ttl="$2"; shift 2 ;;
            --max-invocations) maxv="$2"; shift 2 ;;
            --with-claudemd)   with_claudemd=1; shift ;;
            *) shift ;;
        esac
    done

    # Env-var defaults if not overridden by CLI flag.
    # Both ANTCRATE_CANARY_TTL_SECONDS and ANTCRATE_CANARY_MAX_INVOCATIONS
    # are documented at the top of this file; here we wire them through
    # so test scenarios setting TTL=0 actually result in stale state.
    [[ -z "$ttl"  && -n "${ANTCRATE_CANARY_TTL_SECONDS:-}"     ]] && ttl="$ANTCRATE_CANARY_TTL_SECONDS"
    [[ -z "$maxv" && -n "${ANTCRATE_CANARY_MAX_INVOCATIONS:-}" ]] && maxv="$ANTCRATE_CANARY_MAX_INVOCATIONS"

    local core; core=$(ac_canary_core_bin) || return 1

    local args=("init")
    [[ -n "$ttl"  ]] && args+=(--ttl-seconds "$ttl")
    [[ -n "$maxv" ]] && args+=(--max-invocations "$maxv")
    [[ -n "$with_claudemd" ]] && args+=(--with-claudemd)

    local output; output=$("$core" canary "${args[@]}") || {
        ac_error "canary: antcrate-core canary init failed"
        return 1
    }

    local token=""
    local do_patch=0
    while IFS= read -r line; do
        if [[ "$line" == "__WITH_CLAUDEMD__" ]]; then
            do_patch=1
        elif [[ -z "$token" && ${#line} -eq 32 ]]; then
            token="$line"
        fi
    done <<< "$output"

    if [[ -z "$token" ]]; then
        ac_error "canary: core did not emit a token"
        return 1
    fi

    ac_info "canary: initialized (token: ${token:0:4}…)"
    printf '%s\n' "$token"

    if (( do_patch )); then
        ac_canary_patch_claudemd "$token" || return 1
    fi
}

# ─── verify ──────────────────────────────────────────────────────────────────

ac_canary_verify() {
    local token="${1:-}"
    [[ -z "$token" ]] && { ac_error "canary: verify requires <token>"; return 1; }
    local core; core=$(ac_canary_core_bin) || return 1
    "$core" canary verify "$token"
}

# ─── status ──────────────────────────────────────────────────────────────────

ac_canary_status() {
    local core; core=$(ac_canary_core_bin) || return 1
    local raw; raw=$("$core" canary status) || {
        ac_error "canary: status failed"
        return 1
    }

    if printf '%s' "$raw" | jq -e '.initialized == false' >/dev/null 2>&1; then
        printf 'initialized: no\n'
        return 0
    fi

    local tok last_ts inv ttl maxv
    tok=$(printf '%s' "$raw" | jq -r '.token // ""')
    last_ts=$(printf '%s' "$raw" | jq -r '.last_verified_ts // 0')
    inv=$(printf '%s' "$raw" | jq -r '.invocations_since_verify // 0')
    ttl=$(printf '%s' "$raw" | jq -r '.freshness_ttl_seconds // 3600')
    maxv=$(printf '%s' "$raw" | jq -r '.freshness_max_invocations // 30')

    local masked="${tok:0:4}…"
    local now; now=$(date +%s)
    local age=$(( now - last_ts ))

    printf 'initialized: yes\n'
    printf 'token:       %s\n' "$masked"
    printf 'last verify: %s ago\n' "$(printf '%dh %dm %ds' $((age/3600)) $(( (age%3600)/60 )) $((age%60)))"
    printf 'invocations: %s / %s\n' "$inv" "$maxv"
    printf 'ttl:         %ss\n' "$ttl"
}

# ─── gate check ──────────────────────────────────────────────────────────────

ac_canary_gate_check() {
    local core; core=$(ac_canary_core_bin) || return 2
    "$core" canary gate-check
    local rc=$?
    if (( rc == 4 )); then
        local raw; raw=$("$core" canary status 2>/dev/null) || true
        local last_ts=0 inv=0 maxv=$ANTCRATE_CANARY_MAX_INVOCATIONS ttl=$ANTCRATE_CANARY_TTL_SECONDS
        if [[ -n "$raw" ]]; then
            last_ts=$(printf '%s' "$raw" | jq -r '.last_verified_ts // 0' 2>/dev/null) || last_ts=0
            inv=$(printf '%s' "$raw" | jq -r '.invocations_since_verify // 0' 2>/dev/null) || inv=0
            maxv=$(printf '%s' "$raw" | jq -r '.freshness_max_invocations // 30' 2>/dev/null) || maxv=30
            ttl=$(printf '%s' "$raw" | jq -r '.freshness_ttl_seconds // 3600' 2>/dev/null) || ttl=3600
        fi
        local now; now=$(date +%s)
        local age=$(( now - last_ts ))

        local reason details
        if (( inv >= maxv )); then
            reason="invocation-count exceeded"
            details="$inv / $maxv invocations since last verify"
        else
            reason="wall-clock TTL exceeded"
            details="${age}s elapsed vs ${ttl}s TTL"
        fi
        _ac_canary_format_stale_message "$reason" "$details" "$last_ts" "$inv" "$maxv" >&2
        return 4
    fi
    return $rc
}

# ─── CLAUDE.md patching ──────────────────────────────────────────────────────

ac_canary_patch_claudemd() {
    local token="${1:-}"
    [[ -z "$token" ]] && { ac_error "canary: patch_claudemd requires <token>"; return 1; }

    local target="$ANTCRATE_CLAUDEMD"
    if [[ ! -f "$target" ]]; then
        ac_error "canary: CLAUDE.md not found at $target"
        return 1
    fi

    if ! grep -q '__CANARY_TOKEN__' "$target"; then
        ac_warn "canary: __CANARY_TOKEN__ placeholder not found in $target — skipping patch"
        return 0
    fi

    local tmpfile; tmpfile=$(mktemp "${target}.canary.XXXXXX")
    sed "s/__CANARY_TOKEN__/$token/g" "$target" > "$tmpfile"

    printf '\n=== diff preview ===\n' >&2
    diff "$target" "$tmpfile" >&2 || true
    printf '=== end diff ===\n\n' >&2

    printf 'Apply patch to %s? [y/N] ' "$target" >&2
    local ans; read -r ans
    case "${ans,,}" in
        y|yes)
            mv "$tmpfile" "$target"
            ac_info "canary: patched $target with token ${token:0:4}…"
            ;;
        *)
            rm -f "$tmpfile"
            ac_warn "canary: patch aborted — token printed above; patch manually"
            ;;
    esac
}

# ─── internal: stale UX ──────────────────────────────────────────────────────

_ac_canary_format_stale_message() {
    local reason="${1:-unknown}" details="${2:-}" last_ts="${3:-0}" inv="${4:-0}" maxv="${5:-30}"
    local now; now=$(date +%s)
    local age=$(( now - last_ts ))
    local ago
    ago=$(printf '%dh %dm %ds' $((age/3600)) $(( (age%3600)/60 )) $((age%60)))

    printf '┌──────────────────────────────────────────────────────────────┐\n'
    printf '│  COMPACTION CANARY GATE — safety context may be stale       │\n'
    printf '├──────────────────────────────────────────────────────────────┤\n'
    printf '│  Reason: %-52s│\n' "$reason"
    printf '│  Details: %-51s│\n' "$details"
    printf '│  Last verified: %-45s│\n' "$ago ago"
    printf '│  Invocations since verify: %-34s│\n' "$inv / $maxv"
    printf '│                                                              │\n'
    printf '│  To proceed:                                                 │\n'
    printf '│    1. Re-read ~/CLAUDE.md (Safety Canary section + Rule #1)  │\n'
    printf '│    2. Run: antcrate --canary-verify <TOKEN>                  │\n'
    printf '│    3. Re-issue: <the destructive command that triggered>      │\n'
    printf '│                                                              │\n'
    printf '│  Token location: ~/CLAUDE.md "## Safety Canary" section     │\n'
    printf '└──────────────────────────────────────────────────────────────┘\n'
}
