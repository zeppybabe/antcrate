#!/usr/bin/env bash
# antcrate :: lib/cost.sh — real-dollar cost engine over Claude Code session JSONL
#
# Parses ~/.claude/projects/*/*.jsonl transcripts (message.model + message.usage)
# into dollar figures. Replaces the loop engine's wall-clock budget proxy.
#
# Price model (per MTok; validated against USAGE ON CLAUDE.pdf 2026-06-10 —
# reproduces the $26.04 opus figure exactly):
#   cost = in*R.in + out*R.out + cache_read*R.in*0.1
#        + write_5m*R.in*1.25 + write_1h*R.in*2.0
#
# Lines are deduped by message id (Claude Code writes the same assistant
# message multiple times while streaming; last record wins). Unknown
# claude-* models price at fable rates (most expensive — conservative).
# Non-claude models (e.g. "<synthetic>") contribute zero.
#
# Sourced by wrapper. No side effects on source.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_CLAUDE_PROJECTS_DIR:=$HOME/.claude/projects}"

# Price table (USD per MTok). Override wholesale with a JSON file via
# ANTCRATE_COST_PRICES_FILE. "__unknown__" prices unrecognized claude-* models.
_ac_cost_prices() {
    if [[ -n "${ANTCRATE_COST_PRICES_FILE:-}" && -f "$ANTCRATE_COST_PRICES_FILE" ]]; then
        cat "$ANTCRATE_COST_PRICES_FILE"
        return 0
    fi
    cat <<'JSON'
{
  "claude-fable-5":    {"in": 10.0, "out": 50.0},
  "claude-opus-4-8":   {"in": 5.0,  "out": 25.0},
  "claude-opus-4-7":   {"in": 5.0,  "out": 25.0},
  "claude-opus-4-6":   {"in": 5.0,  "out": 25.0},
  "claude-opus-4-5":   {"in": 5.0,  "out": 25.0},
  "claude-sonnet-4-6": {"in": 3.0,  "out": 15.0},
  "claude-sonnet-4-5": {"in": 3.0,  "out": 15.0},
  "claude-haiku-4-5":  {"in": 1.0,  "out": 5.0},
  "__unknown__":       {"in": 10.0, "out": 50.0}
}
JSON
}

# Normalize a --since value (epoch seconds or ISO datetime) to YYYY-MM-DDTHH:MM:SS.
_ac_cost_norm_since() {
    local v="$1"
    [[ -z "$v" ]] && { printf '\n'; return 0; }
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        date -u -d "@$v" +%Y-%m-%dT%H:%M:%S
    else
        date -u -d "$v" +%Y-%m-%dT%H:%M:%S
    fi
}

# _ac_cost_aggregate [--since <ts>] [--session <file>]
# Emits a JSON array: per-model {model, in, out, read, w5m, w1h, msgs, cost}
# plus computes from all transcripts under ANTCRATE_CLAUDE_PROJECTS_DIR.
_ac_cost_aggregate() {
    local since="" session=""
    while (( $# > 0 )); do
        case "$1" in
            --since)   since="${2:-}"; shift 2 ;;
            --session) session="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local since_norm; since_norm=$(_ac_cost_norm_since "$since") || {
        ac_error "cost: cannot parse --since '$since'"; return 2; }

    local files=()
    if [[ -n "$session" ]]; then
        [[ -f "$session" ]] || { ac_error "cost: no such session file: $session"; return 2; }
        files=("$session")
    else
        while IFS= read -r f; do files+=("$f"); done \
            < <(find "$ANTCRATE_CLAUDE_PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' 2>/dev/null | sort)
    fi

    if (( ${#files[@]} == 0 )); then
        printf '[]\n'
        return 0
    fi

    local prices; prices=$(_ac_cost_prices)
    # jq -R + fromjson tolerates the occasional malformed line in a transcript.
    cat "${files[@]}" | jq -R -n \
        --argjson prices "$prices" --arg since "$since_norm" '
        def rate($m):
            ($prices[$m]) //
            ([ $prices | to_entries[] | .key as $k
               | select($k != "__unknown__" and ($m | startswith($k))) ]
             | sort_by(.key | length) | last | .value?) //
            (if ($m | startswith("claude-")) then $prices["__unknown__"] else null end);

        [ inputs | (try fromjson catch null)
          | select(type == "object")
          | select((.message.usage? != null) and (.message.model? != null))
          | select($since == "" or ((.timestamp // "")[0:19] >= $since))
          | { id: (.message.id // .uuid // ""),
              model: .message.model,
              u: .message.usage } ]
        | group_by(.id) | map(.[-1])
        | group_by(.model)
        | map(
            { model: .[0].model,
              in:   (map(.u.input_tokens // 0) | add),
              out:  (map(.u.output_tokens // 0) | add),
              read: (map(.u.cache_read_input_tokens // 0) | add),
              w5m:  (map(.u.cache_creation.ephemeral_5m_input_tokens
                         // (.u.cache_creation_input_tokens // 0)) | add),
              w1h:  (map(.u.cache_creation.ephemeral_1h_input_tokens // 0) | add),
              msgs: length }
            | . + { cost:
                (rate(.model) as $r
                 | if $r == null then 0
                   else (.in * $r.in + .out * $r.out + .read * $r.in * 0.1
                         + .w5m * $r.in * 1.25 + .w1h * $r.in * 2.0) / 1000000
                   end),
                priced: (rate(.model) != null),
                exact: ($prices[.model] != null) } )
        | sort_by(-.cost)'
}

# ac_cost_total [--since <ts>] [--session <file>] — bare USD float on stdout.
ac_cost_total() {
    local agg; agg=$(_ac_cost_aggregate "$@") || return $?
    printf '%s\n' "$agg" | jq -r '(map(.cost) | add // 0) | . * 10000 | round / 10000 | tostring
        | if test("\\.") then (. + "0000") | capture("(?<w>[^.]*)\\.(?<f>.*)") | .w + "." + .f[0:4]
          else . + ".0000" end'
}

# ac_cost_report [--since <ts>] [--session <file>] [--porcelain]
ac_cost_report() {
    local args=() porcelain=""
    while (( $# > 0 )); do
        case "$1" in
            --porcelain) porcelain=1; shift ;;
            *) args+=("$1"); shift ;;
        esac
    done
    if [[ -n "$porcelain" ]]; then
        ac_cost_total "${args[@]}"
        return $?
    fi

    local agg; agg=$(_ac_cost_aggregate "${args[@]}") || return $?
    printf 'cost: %s\n' "${ANTCRATE_CLAUDE_PROJECTS_DIR}"
    printf '  %-28s %10s %10s %12s %12s %6s %10s\n' MODEL IN OUT CACHE-R CACHE-W MSGS COST
    printf '%s\n' "$agg" | jq -r '.[] |
        "  \(.model)\t\(.in)\t\(.out)\t\(.read)\t\(.w5m + .w1h)\t\(.msgs)\t$\(.cost * 100 | round / 100)\(if .exact then "" else " ~" end)"' \
        | awk -F'\t' '{ printf "  %-28s %10s %10s %12s %12s %6s %10s\n", $1, $2, $3, $4, $5, $6, $7 }'
    local total; total=$(printf '%s\n' "$agg" | jq -r '(map(.cost) | add // 0) | . * 10000 | round / 10000 | tostring
        | if test("\\.") then (. + "0000") | capture("(?<w>[^.]*)\\.(?<f>.*)") | .w + "." + .f[0:4]
          else . + ".0000" end')
    printf 'total: $%s\n' "$total"
}
