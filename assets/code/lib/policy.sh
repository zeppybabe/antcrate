#!/usr/bin/env bash
# antcrate :: lib/policy.sh — model/tier/budget policy (spec 2026-06-11)
#
# One jq-managed file, two consumers: hooks read `.models`/`.budgets` directly
# (self-contained, no antcrate runtime); the AnyCrate dispatch helper will read
# `.classes`. The orchestrator's model is NEVER policy-assigned ("inherit" =
# the user's session choice; Clyde/Cable are personas of the role).
#
# Self-governance grant (user directive 2026-06-11): Cable may adjust
# .budgets.fable ONLY — evidence-backed, ledger-recorded at change time.
# Everything else: human-only or via --propose. Sourced by wrapper; no side
# effects on source.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"

_ac_policy_file() {
    printf '%s/anycrate/policy.json\n' "${ANTCRATE_HOME:-$HOME/.antcrate}"
}

# Idempotent: writes only if absent (a present file is user/grant territory).
ac_policy_seed() {
    local f json; f=$(_ac_policy_file)
    [[ -f "$f" ]] && { ac_info "policy: already present at $f"; return 0; }
    mkdir -p "$(dirname "$f")"
    # endpoints (spec 2026-07-16): where inference may run. HUMAN-ONLY —
    # agents read + propose, never write. kind local|vllm|api.
    json=$(jq -n '{
      endpoints: {},
      models: {
        fable:  {window: 1000000, max_out: 128000, usd_in: 10, usd_out: 50, tokenizer_factor: 1.3, effort: true},
        opus:   {window: 1000000, max_out: 128000, usd_in: 5,  usd_out: 25, tokenizer_factor: 1.0, effort: true},
        sonnet: {window: 1000000, max_out: 64000,  usd_in: 3,  usd_out: 15, tokenizer_factor: 1.0, effort: true},
        haiku:  {window: 200000,  max_out: 64000,  usd_in: 1,  usd_out: 5,  tokenizer_factor: 1.0, effort: false}
      },
      budgets: {
        default: {soft: 100000, hard: 140000},
        fable:   {soft: 250000, hard: 400000,
                  evidence: "2026-06-10 session >300k, no degradation; user directive 2026-06-11"}
      },
      classes: {
        orchestrate: {agent: "orchestrator", tier: "T0", model: "inherit"},
        heavy:       {agent: "cody",    tier: "T1", model: "opus"},
        review:      {agent: "claudia", tier: "T2", model: "sonnet"},
        build:       {agent: "cody",    tier: "T3", model: "haiku"},
        bulk:        {agent: "cody",    tier: "T3", model: "haiku"},
        lookup:      {agent: "human",   tier: "TH", model: "none"}
      },
      skill_overrides: { "claude-api": {extra_bytes: 700000} },
      budget_usd: {session_usd: 5.00, check: "--cost --porcelain --since today"}
    }') || return 1
    printf '%s\n' "$json" > "$f.tmp" && mv "$f.tmp" "$f"
    ac_info "policy: seeded $f"
    printf 'policy: seeded %s\n' "$f"
}

# ac_policy_get '<jq path>' — raw value, rc 1 if file missing
ac_policy_get() {
    local f; f=$(_ac_policy_file)
    [[ -f "$f" ]] || return 1
    jq -r "$1 // empty" "$f"
}

ac_policy_show() {
    local f; f=$(_ac_policy_file)
    [[ -f "$f" ]] || { ac_error "policy: no file at $f — run --policy-init"; return 1; }
    jq . "$f"
}

# ac_policy_endpoints_validate — validate .endpoints against the v1 schema
# (spec 2026-07-16). rc 0 clean; rc 1 with one ac_error line PER defect
# (report everything, make the human's single edit pass complete).
# Schema: kind local|vllm|api · local requires exec · vllm/api require url ·
# api url must be https:// (vllm may be http — LAN reality).
ac_policy_endpoints_validate() {
    local f; f=$(_ac_policy_file)
    [[ -f "$f" ]] || { ac_error "policy: no file at $f — run: antcrate policy seed"; return 1; }
    local errs
    errs=$(jq -r '
      (.endpoints // {}) | to_entries[] | .key as $n | .value as $e |
      ( if (["local","vllm","api"] | index($e.kind // "")) == null
        then "\($n): kind must be local|vllm|api (got: \($e.kind // "missing"))" else empty end ),
      ( if ($e.kind // "") == "local" and (($e.exec // "") == "")
        then "\($n): kind local requires exec" else empty end ),
      ( if ((($e.kind // "") == "vllm") or (($e.kind // "") == "api")) and (($e.url // "") == "")
        then "\($n): kind \($e.kind) requires url" else empty end ),
      ( if ($e.kind // "") == "api" and (($e.url // "") != "")
           and (($e.url // "") | startswith("https://") | not)
        then "\($n): api url must be https:// (got: \($e.url))" else empty end )
    ' "$f" 2>/dev/null) || { ac_error "policy: cannot read endpoints (invalid JSON?)"; return 1; }
    [[ -z "$errs" ]] && return 0
    local line
    while IFS= read -r line; do ac_error "policy endpoint $line"; done <<< "$errs"
    return 1
}
