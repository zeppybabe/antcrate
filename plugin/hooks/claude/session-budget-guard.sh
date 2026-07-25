#!/usr/bin/env bash
# session-budget-guard.sh — Claude Code PreToolUse hook (matcher: *).
#
# Gates the session on CONTEXT-WINDOW health (spec:
# docs/specs/2026-06-10-session-budget-gate-and-duties-design.md).
# context = input + cache_read + cache_creation of the LAST usage record in
# the transcript. Soft limit warns (throttled per 10k growth); hard limit
# blocks everything except the wrap-up whitelist until the USER runs /clear —
# a fresh transcript measures small, so the measurement IS the state (no flag
# files). Fails OPEN: a health guard must never brick the session it guards.
#
# NOTE: no `set -e` — the guard must always exit with its own computed code.
set -uo pipefail

[ "${ANTCRATE_SESSION_GATE_DISABLE:-0}" = "1" ] && exit 0

GATE_DIR="${ANTCRATE_SESSION_GATE_DIR:-$HOME/.antcrate/session-gate}"

payload="$(cat)"

transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
{ [ -n "$transcript" ] && [ -r "$transcript" ]; } || exit 0    # fail open

# Single-pass parse: extract context and model_id from last usage record.
# fromjson? makes garbage lines a no-op, not an error.
_parsed="$(tail -n 200 "$transcript" 2>/dev/null \
    | jq -Rs 'split("\n") | map(select(length>0) | (try fromjson catch null)) | map(select(. != null)) |
              { ctx: (map(select(.message.usage.input_tokens != null)) | last
                      | .message.usage | .input_tokens + (.cache_read_input_tokens//0) + (.cache_creation_input_tokens//0)),
                mdl: (map(select(.message.model != null and .message.model != "")) | last | .message.model // "") }' 2>/dev/null)"
context="$(printf '%s' "$_parsed" | jq -r '.ctx // empty' 2>/dev/null)"
model_id="$(printf '%s' "$_parsed" | jq -r '.mdl // empty' 2>/dev/null)"
[ -n "$context" ] || exit 0                               # fail open
case "$context" in *[!0-9]*) exit 0 ;; esac               # fail open

# ---- per-model budgets (spec 2026-06-11 Unit 5) ------------------------------
# env override (human-only) > policy.budgets.<model> > policy.budgets.default
# > builtin 100k/140k. Fable raise: user directive 2026-06-11, evidence-backed.
POLICY="${ANTCRATE_POLICY_FILE:-$HOME/.antcrate/anycrate/policy.json}"
case "$model_id" in
    *fable*) mkey=fable ;; *opus*) mkey=opus ;; *sonnet*) mkey=sonnet ;; *haiku*) mkey=haiku ;;
    *) mkey=default ;;
esac
psoft=""; phard=""
if [ -r "$POLICY" ]; then
    psoft="$(jq -r ".budgets.\"$mkey\".soft // .budgets.default.soft // empty" "$POLICY" 2>/dev/null)"
    phard="$(jq -r ".budgets.\"$mkey\".hard // .budgets.default.hard // empty" "$POLICY" 2>/dev/null)"
fi
case "$psoft" in ''|*[!0-9]*) psoft=100000 ;; esac
case "$phard" in ''|*[!0-9]*) phard=140000 ;; esac
SOFT="${ANTCRATE_SESSION_SOFT:-$psoft}"
HARD="${ANTCRATE_SESSION_HARD:-$phard}"

[ "$context" -lt "$SOFT" ] && exit 0

session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || session_id="$(printf '%s' "$transcript" | cksum | cut -d' ' -f1)"

# ---- soft stage: warn, throttled per 10k growth -----------------------------
if [ "$context" -lt "$HARD" ]; then
    mkdir -p "$GATE_DIR" 2>/dev/null || exit 0
    # stale markers are gate-internal state (not user data) — prune >7 days
    find "$GATE_DIR" -name '*.lastwarn' -mtime +7 -delete 2>/dev/null
    marker="$GATE_DIR/$session_id.lastwarn"
    last=0
    [ -f "$marker" ] && last="$(cat "$marker" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $(( context - last )) -ge 10000 ]; then
        printf '%s\n' "$context" > "$marker"
        printf '{"systemMessage":"session-budget-guard: context %sk — soft limit %sk (hard %sk). Wrap up after the current task: commit, push, state.md objective, review duties, then /clear."}\n' \
            "$(( context / 1000 ))" "$(( SOFT / 1000 ))" "$(( HARD / 1000 ))"
    fi
    exit 0
fi

# ---- hard stage: wrap-up whitelist only -------------------------------------

block() {
    duties_note=""
    if command -v antcrate >/dev/null 2>&1; then
        n="$(antcrate duty ls 2>/dev/null | grep -c '^ *[0-9]')" || n=""
        [ -n "$n" ] && duties_note=" ($n open)"
    fi
    printf 'SESSION HARD LIMIT: context %sk >= %sk. %s\nWrap up now — only wrap-up tools are allowed:\n  1. commit:  antcrate commit <project> -m "..."\n  2. push:    antcrate pp <project>\n  3. state:   write the resume objective into state.md (rolling protocol)\n  4. duties:  antcrate duty ls%s — review with the user\n  5. then the USER runs /clear to start a fresh session.\n' \
        "$(( context / 1000 ))" "$(( HARD / 1000 ))" "$1" "$duties_note" >&2
    exit 2
}

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"

_seg_allowed() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"    # ltrim
    [ -z "$s" ] && return 0
    case "$s" in
        antcrate\ commit*|antcrate\ pp*|antcrate\ st|antcrate\ st\ *|antcrate\ status*|antcrate\ duty*|antcrate\ duties*) return 0 ;;
        antcrate\ --emit-activity*) return 0 ;;
        git\ status*|git\ diff*|git\ log*|git\ add*) return 0 ;;
    esac
    return 1
}

case "$tool" in
    Read|Grep|Glob) exit 0 ;;
    Edit|Write|MultiEdit)
        fpath="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
        case "$(basename "$fpath")" in
            state.md|ledger.md|state-archive.md|duties.md) exit 0 ;;
        esac
        block "(edit target is not a wrap-up state file)"
        ;;
    Bash)
        cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        # quoted spans cannot start a new command segment — drop before split
        stripped="$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"
        case "$stripped" in *"\$("*|*"\`"*) block "(command substitution not allowed past the hard limit)" ;; esac
        ok=1
        while IFS= read -r seg; do
            _seg_allowed "$seg" || { ok=0; break; }
        done <<EOF
$(printf '%s\n' "$stripped" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g')
EOF
        [ "$ok" -eq 1 ] && exit 0
        block "(command is not on the wrap-up whitelist)"
        ;;
    *) block "(tool '${tool:-<unknown>}' not allowed past the hard limit)" ;;
esac
