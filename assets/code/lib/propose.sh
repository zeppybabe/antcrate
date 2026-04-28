#!/usr/bin/env bash
# antcrate :: lib/propose.sh — pattern-proposal escape valve
#
# When an agent (or user) needs an action that has no AntCrate flag, they call
#   antcrate --propose <name> "<description>"
# instead of running a bare destructive shell command. The proposal is appended
# to ~/.antcrate/proposals.log for human review. The user later promotes
# accepted proposals into real flags. This keeps AntCrate as the sole
# structural surface even for novel intents.
#
# Log format (tab-separated, append-only):
#   <iso8601-utc>\t<proposer>\t<name>\t<description>
#
# Sourced by wrapper. No side effects on source.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_PROPOSALS_LOG:=$ANTCRATE_HOME/proposals.log}"

ac_propose_pattern() {
    # ac_propose_pattern <name> <description>
    local name="${1:-}" description="${2:-}"

    if [[ -z "$name" ]]; then
        ac_error "propose: missing <name>"
        return 2
    fi
    if [[ -z "$description" ]]; then
        ac_error "propose: missing <description>"
        return 2
    fi
    if [[ "$name" =~ [[:space:]] ]] || [[ "$name" == *$'\t'* ]]; then
        ac_error "propose: <name> must not contain whitespace (got: '$name')"
        return 2
    fi

    local proposer="${ANTCRATE_PROPOSER:-${USER:-unknown}}"
    local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local clean_desc="${description//$'\t'/ }"
    clean_desc="${clean_desc//$'\n'/ }"

    mkdir -p "$(dirname "$ANTCRATE_PROPOSALS_LOG")"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$proposer" "$name" "$clean_desc" \
        >> "$ANTCRATE_PROPOSALS_LOG"

    ac_info "propose: logged '$name' to $ANTCRATE_PROPOSALS_LOG"
    printf 'Proposed pattern "%s" recorded. Review with:\n  cat %s\n' \
        "$name" "$ANTCRATE_PROPOSALS_LOG"
}

ac_propose_list() {
    if [[ ! -s "$ANTCRATE_PROPOSALS_LOG" ]]; then
        printf 'No proposals logged yet (%s).\n' "$ANTCRATE_PROPOSALS_LOG"
        return 0
    fi
    printf '%s\n' "Proposals (newest last) — $ANTCRATE_PROPOSALS_LOG:"
    printf '%s\n' "----"
    awk -F '\t' '{ printf "  %s  by %-12s  %-20s  %s\n", $1, $2, $3, $4 }' \
        "$ANTCRATE_PROPOSALS_LOG"
}
