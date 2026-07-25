#!/usr/bin/env bash
# cost-anticipator.sh — Claude Code PreToolUse hook (matcher: Skill|Agent|Read).
#
# The PREDICTIVE half of session-budget-guard: estimates the token cost of an
# expensive call BEFORE it executes (spec 2026-06-11). est_tokens = bytes/4 ×
# tokenizer_factor(model). Projection past the model's hard budget or window
# blocks (exit 2) naming a cheaper path; past soft warns. Reads ONLY
# policy.json + the transcript — never invokes antcrate. Fails OPEN.
# Agents MUST NOT set ANTCRATE_COST_GUARD_DISABLE (AGENTS.md).
set -uo pipefail

[ "${ANTCRATE_COST_GUARD_DISABLE:-0}" = "1" ] && exit 0

POLICY="${ANTCRATE_POLICY_FILE:-$HOME/.antcrate/anycrate/policy.json}"
SKILLS_DIR="${ANTCRATE_COST_SKILLS_DIR:-$HOME/.claude/skills}"
[ -r "$POLICY" ] || exit 0                                   # fail open

payload="$(cat)" || exit 0
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
[ -n "$tool" ] || exit 0

transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
{ [ -n "$transcript" ] && [ -r "$transcript" ]; } || exit 0  # fail open

# context = last usage record (same parse as session-budget-guard)
context="$(tail -n 200 "$transcript" 2>/dev/null \
    | jq -R 'fromjson? | .message.usage? // empty
             | select(type == "object" and .input_tokens != null)
             | .input_tokens + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null \
    | tail -n 1)"
case "$context" in ''|*[!0-9]*) exit 0 ;; esac

# model key from the transcript's last model id
model_id="$(tail -n 200 "$transcript" 2>/dev/null \
    | jq -R 'fromjson? | .message.model? // empty | select(. != "")' 2>/dev/null | tail -n 1 | tr -d '"')"
case "$model_id" in
    *fable*)  mkey=fable ;;
    *opus*)   mkey=opus ;;
    *sonnet*) mkey=sonnet ;;
    *haiku*)  mkey=haiku ;;
    *)        mkey=default ;;
esac

jqp() { jq -r "$1 // empty" "$POLICY" 2>/dev/null; }
soft="$(jqp ".budgets.\"$mkey\".soft")"; [ -n "$soft" ] || soft="$(jqp '.budgets.default.soft')"
hard="$(jqp ".budgets.\"$mkey\".hard")"; [ -n "$hard" ] || hard="$(jqp '.budgets.default.hard')"
window="$(jqp ".models.\"$mkey\".window")"; [ -n "$window" ] || window=1000000
factor10=13                                                 # ×10 int math
case "$(jqp ".models.\"$mkey\".tokenizer_factor")" in
    1.3) factor10=13 ;; 1.0|1|"") factor10=10 ;; *) factor10=10 ;;
esac
[ "$mkey" = "default" ] && factor10=10
case "$soft$hard" in *[!0-9]*|"") exit 0 ;; esac             # fail open

est_from_bytes() { printf '%s' "$(( $1 * factor10 / 4 / 10 ))"; }

est=0; target_window_block=""
case "$tool" in
    Skill)
        skill="$(printf '%s' "$payload" | jq -r '.tool_input.skill // empty' 2>/dev/null)"
        [ -n "$skill" ] || exit 0
        sdir="$SKILLS_DIR/$skill"
        [ -f "$sdir/SKILL.md" ] || exit 0                    # unknown skill: fail open
        bytes="$(wc -c < "$sdir/SKILL.md" 2>/dev/null)" || exit 0
        extra="$(jqp ".skill_overrides.\"$skill\".extra_bytes")"
        case "$extra" in *[!0-9]*|"") extra=0 ;; esac
        est="$(est_from_bytes $(( bytes + extra )))"
        cheap="cheaper paths: dispatch a subagent to fetch only the answer; read the skill's shared/ reference file directly with offset/limit; or file it as a duty (antcrate --duty --type research ...)"
        ;;
    Read)
        fpath="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
        { [ -n "$fpath" ] && [ -f "$fpath" ]; } || exit 0
        bytes="$(wc -c < "$fpath" 2>/dev/null)" || exit 0
        [ "$bytes" -lt 131072 ] && exit 0                    # small reads: free pass
        est="$(est_from_bytes "$bytes")"
        cheap="cheaper paths: Read with offset/limit; grep for the needed section; or a subagent summarizer"
        ;;
    Agent)
        plen="$(printf '%s' "$payload" | jq -r '.tool_input.prompt // "" | length' 2>/dev/null)"
        case "$plen" in ''|*[!0-9]*) exit 0 ;; esac
        tmodel="$(printf '%s' "$payload" | jq -r '.tool_input.model // empty' 2>/dev/null)"
        if [ -n "$tmodel" ]; then
            twin="$(jqp ".models.\"$tmodel\".window")"
            case "$twin" in ''|*[!0-9]*) twin="" ;; esac
            if [ -n "$twin" ] && [ $(( plen / 4 )) -ge "$twin" ]; then
                target_window_block="prompt ~$(( plen / 4 )) tokens exceeds $tmodel window ($twin)"
            fi
        fi
        est=$(( plen * factor10 / 4 / 10 ))
        cheap="cheaper paths: tighten the brief; split the task; pick the tier per policy.json classes"
        ;;
    *) exit 0 ;;
esac

if [ -n "$target_window_block" ]; then
    printf 'cost-anticipator BLOCK: %s. %s\n' "$target_window_block" "$cheap" >&2
    exit 2
fi

projected=$(( context + est ))
margin_window=$(( window * 8 / 10 ))
if [ "$projected" -ge "$hard" ] || [ "$projected" -ge "$margin_window" ]; then
    printf 'cost-anticipator BLOCK: projected context %sk (now %sk + est %sk) >= hard %sk (model %s, window %sk). %s\n' \
        "$(( projected / 1000 ))" "$(( context / 1000 ))" "$(( est / 1000 ))" \
        "$(( hard / 1000 ))" "$mkey" "$(( window / 1000 ))" "$cheap" >&2
    exit 2
fi
if [ "$projected" -ge "$soft" ]; then
    printf '{"systemMessage":"cost-anticipator: this %s call adds ~%sk tokens -> ~%sk total (soft %sk, hard %sk, model %s). Consider: %s"}\n' \
        "$tool" "$(( est / 1000 ))" "$(( projected / 1000 ))" \
        "$(( soft / 1000 ))" "$(( hard / 1000 ))" "$mkey" "$cheap"
fi
exit 0
