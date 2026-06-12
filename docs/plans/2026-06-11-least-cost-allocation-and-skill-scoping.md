# Least-Cost Allocation Layer + Skill Scoping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the spec at `docs/specs/2026-06-11-least-cost-allocation-and-skill-scoping-design.md` — policy.json, the cost-anticipator hook, per-model session budgets (the Fable raise), typed duties + involvement knob, `--fetch`, the three-tier skill split, and the `antcrate *` permission allowlist.

**Architecture:** Pure Bash 5 + jq, matching every existing lib (`lib/*.sh` sourced by `bin/antcrate`; hooks under `hooks/claude/` are self-contained scripts that never invoke the antcrate runtime). All work is RED-first bats. Hooks fail OPEN; tier/budget data lives in one jq-managed file `~/.antcrate/anycrate/policy.json`.

**Tech Stack:** Bash 5, jq, bats, shellcheck, curl (fetch), awk (normalizer reuse from `lib/intel.sh`).

**Conventions that bind every task (read once):**
- Work in a git worktree under `.claude/worktrees/`; run `antcrate --ci --source <worktree>` before copy-back; copy back with `cp` + `cmp` verify; final commit via `ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate -m "..." -- <files>`; push via `antcrate --pp antcrate -y`. Never bare `git push`.
- bats files follow `tests/duties.bats` style: `setup()` exports `ANTCRATE_HOME=$BATS_TEST_TMPDIR/.antcrate`, `ANTCRATE_LOG_LEVEL=error`; a `src` helper re-sources libs in a clean `bash -c`. Hooks are tested by piping a synthetic payload JSON to the script (see `antcrate --hook-smoke`), with `ANTCRATE_*` env overrides pointing at fixtures.
- Every new `.sh` must pass `shellcheck`. Every new lib function gets bats coverage (project rule).
- Commit messages: `type(scope): description`, one logical change per commit. Commit inside the worktree after each GREEN.

**File map (created/modified across the whole plan):**

| File | Task | Responsibility |
|---|---|---|
| `assets/code/lib/policy.sh` (new) | 1 | seed + read `policy.json` |
| `assets/code/tests/policy.bats` (new) | 1 | policy seed/lookup/atomicity |
| `assets/code/hooks/claude/cost-anticipator.sh` (new) | 2 | predictive PreToolUse gate |
| `assets/code/tests/cost_anticipator.bats` (new) | 2 | hook behavior matrix |
| `assets/code/hooks/claude/session-budget-guard.sh` (modify) | 3 | per-model budgets |
| `assets/code/tests/session_budget_guard_models.bats` (new) | 3 | model-aware lookup |
| `assets/code/lib/duties.sh` (modify) | 4 | typed duties + involvement |
| `assets/code/tests/duties_typed.bats` (new) | 4 | types/backcompat/knob |
| `assets/code/lib/fetch.sh` (new) | 5 | no-LLM web fetcher |
| `assets/code/tests/fetch.bats` (new) | 5 | snapshot/append-only/fail |
| `SKILL.md` (rewrite), `assets/docs/LIB_MAP.md` (new), `assets/skills/builder/SKILL.md` (new) | 6 | skill split |
| `assets/code/tests/skills_builder.bats` (new) | 6 | marker + flag-drift check |
| `~/.claude/settings.json`, `~/.claude/agents/{cody,claudia,cody-tester}.md` | 2/6/7 | wiring (user zone) |
| `assets/code/bin/antcrate` (modify) | 1/4/5 | flag parse + dispatch + help |
| `assets/code/AGENTS.md`, `assets/docs/PATTERNS.md`, `ledger.md`, `state.md` | 8 | governance + docs |

---

### Task 1: `policy.json` seed + reader (`lib/policy.sh`)

**Files:** Create `assets/code/lib/policy.sh`, `assets/code/tests/policy.bats`. Modify `assets/code/bin/antcrate` (parse + dispatch + help + source line).

- [ ] **Step 1: Write the failing tests** — `assets/code/tests/policy.bats`:

```bash
#!/usr/bin/env bats
# tests for lib/policy.sh — model/tier/budget policy file

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/policy.sh'
        $1
    "
}

@test "policy: seed creates file with models/budgets/classes" {
    run src "ac_policy_seed"
    [ "$status" -eq 0 ]
    f="$ANTCRATE_HOME/anycrate/policy.json"
    [ -f "$f" ]
    [ "$(jq -r '.models.haiku.window' "$f")" = "200000" ]
    [ "$(jq -r '.budgets.fable.hard' "$f")" = "400000" ]
    [ "$(jq -r '.budgets.default.hard' "$f")" = "140000" ]
    [ "$(jq -r '.classes.orchestrate.model' "$f")" = "inherit" ]
    [ "$(jq -r '.classes.lookup.tier' "$f")" = "TH" ]
}

@test "policy: seed is idempotent (does not clobber user edits)" {
    src "ac_policy_seed" >/dev/null
    jq '.budgets.fable.soft = 999' "$ANTCRATE_HOME/anycrate/policy.json" > "$BATS_TEST_TMPDIR/t" \
        && mv "$BATS_TEST_TMPDIR/t" "$ANTCRATE_HOME/anycrate/policy.json"
    src "ac_policy_seed" >/dev/null
    [ "$(jq -r '.budgets.fable.soft' "$ANTCRATE_HOME/anycrate/policy.json")" = "999" ]
}

@test "policy: ac_policy_get reads a jq path" {
    src "ac_policy_seed" >/dev/null
    run src "ac_policy_get '.models.fable.tokenizer_factor'"
    [ "$status" -eq 0 ]
    [ "$output" = "1.3" ]
}

@test "policy: ac_policy_get on missing file returns 1, empty output" {
    run src "ac_policy_get '.models.fable.window'"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "policy: ac_policy_show prints the whole file" {
    src "ac_policy_seed" >/dev/null
    run src "ac_policy_show"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"fable"'* ]]
}

@test "policy: seed validates with jq (no trailing garbage / parse errors)" {
    src "ac_policy_seed" >/dev/null
    run jq -e . "$ANTCRATE_HOME/anycrate/policy.json"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify RED** — `bats assets/code/tests/policy.bats` → all FAIL (`ac_policy_seed: command not found` class).
- [ ] **Step 3: Implement** — `assets/code/lib/policy.sh`:

```bash
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

_ac_policy_file() {
    printf '%s/anycrate/policy.json\n' "${ANTCRATE_HOME:-$HOME/.antcrate}"
}

# Idempotent: writes only if absent (a present file is user/grant territory).
ac_policy_seed() {
    local f; f=$(_ac_policy_file)
    [[ -f "$f" ]] && { ac_info "policy: already present at $f"; return 0; }
    mkdir -p "$(dirname "$f")"
    jq -n '{
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
    }' > "$f.tmp" && mv "$f.tmp" "$f"
    ac_info "policy: seeded $f"
    printf 'policy seeded: %s\n' "$f"
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
```

- [ ] **Step 4: Wire the wrapper** — in `assets/code/bin/antcrate`: add `. "$ANTCRATE_LIB/policy.sh"` next to the other lib source lines; in the arg parser add (following the `--pp` pattern at bin/antcrate:482):

```bash
--policy)       ACTION="policy" ; shift ;;
--policy-init)  ACTION="policy_init"; shift ;;
```

and in the dispatch case (bin/antcrate:905 region):

```bash
policy)      ac_policy_show ;;
policy_init) ac_policy_seed ;;
```

plus two lines in the help text mirroring neighbors.
- [ ] **Step 5: Run to verify GREEN** — `bats assets/code/tests/policy.bats` → 6 PASS; `shellcheck assets/code/lib/policy.sh` → clean.
- [ ] **Step 6: Commit** — `git add assets/code/lib/policy.sh assets/code/tests/policy.bats assets/code/bin/antcrate && git commit -m "feat(policy): policy.json seed + reader (models/budgets/classes; Fable 250k/400k)"`

---

### Task 2: `cost-anticipator.sh` — predictive PreToolUse hook

**Files:** Create `assets/code/hooks/claude/cost-anticipator.sh`, `assets/code/tests/cost_anticipator.bats`. (settings.json wiring is Step 7, user zone.)

- [ ] **Step 1: Write the failing tests** — `assets/code/tests/cost_anticipator.bats`:

```bash
#!/usr/bin/env bats
# tests for hooks/claude/cost-anticipator.sh — predictive cost gate
# Payloads are piped on stdin exactly as Claude Code delivers them.

setup() {
    HOOK="$BATS_TEST_DIRNAME/../hooks/claude/cost-anticipator.sh"
    export ANTCRATE_POLICY_FILE="$BATS_TEST_TMPDIR/policy.json"
    export ANTCRATE_COST_SKILLS_DIR="$BATS_TEST_TMPDIR/skills"
    T="$BATS_TEST_TMPDIR/transcript.jsonl"
    jq -n '{models:{fable:{window:1000000,tokenizer_factor:1.3},haiku:{window:200000,tokenizer_factor:1.0}},
            budgets:{default:{soft:100000,hard:140000},fable:{soft:250000,hard:400000}},
            skill_overrides:{"claude-api":{extra_bytes:700000}}}' > "$ANTCRATE_POLICY_FILE"
    mkdir -p "$ANTCRATE_COST_SKILLS_DIR/smallskill" "$ANTCRATE_COST_SKILLS_DIR/claude-api"
    head -c 4000   /dev/zero | tr '\0' 'a' > "$ANTCRATE_COST_SKILLS_DIR/smallskill/SKILL.md"
    head -c 40000  /dev/zero | tr '\0' 'a' > "$ANTCRATE_COST_SKILLS_DIR/claude-api/SKILL.md"
}

# transcript with a given context size + model id
mk_transcript() {
    jq -cn --argjson n "$1" --arg m "$2" \
        '{message:{model:$m,usage:{input_tokens:$n,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' > "$T"
}

payload_skill() { jq -cn --arg t "$T" --arg s "$1" '{transcript_path:$t,tool_name:"Skill",tool_input:{skill:$s}}'; }

@test "anticipator: small skill at low context allows (rc 0)" {
    mk_transcript 50000 "claude-fable-5"
    run bash -c "payload=\$(jq -cn --arg t '$T' '{transcript_path:\$t,tool_name:\"Skill\",tool_input:{skill:\"smallskill\"}}'); printf '%s' \"\$payload\" | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: claude-api skill (extra_bytes) at 130k on fable BLOCKS past hard" {
    # 130k + (40000+700000)/4*1.3 ≈ 130k + 240k = 370k < fable hard 400k -> allow
    mk_transcript 130000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
    # but at 200k projected 440k > 400k -> block rc 2
    mk_transcript 200000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "${lines[*]}" == *"cheaper"* ]]
}

@test "anticipator: unknown model uses default budgets (claude-api at 50k blocks: 50k+240k>140k)" {
    mk_transcript 50000 "claude-mystery-9"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "anticipator: soft crossing warns on stdout systemMessage, rc 0" {
    # smallskill est ≈ 1300 tok; context 249500 -> projected 250800 > fable soft 250k
    mk_transcript 249500 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"smallskill\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *systemMessage* ]]
}

@test "anticipator: Agent prompt overflowing target model window blocks" {
    mk_transcript 10000 "claude-fable-5"
    big=$(head -c 1000000 /dev/zero | tr '\0' 'b')   # ~250k tok > haiku 200k window
    run bash -c "jq -cn --arg t '$T' --arg p '$big' '{transcript_path:\$t,tool_name:\"Agent\",tool_input:{prompt:\$p,model:\"haiku\"}}' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "anticipator: Read of huge file blocks past hard budget" {
    mk_transcript 130000 "claude-mystery-9"   # default hard 140k
    big="$BATS_TEST_TMPDIR/big.txt"; head -c 200000 /dev/zero | tr '\0' 'c' > "$big"  # ~50k tok
    run bash -c "jq -cn --arg t '$T' --arg f '$big' '{transcript_path:\$t,tool_name:\"Read\",tool_input:{file_path:\$f}}' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "anticipator: fail-open on missing policy file" {
    rm -f "$ANTCRATE_POLICY_FILE"
    mk_transcript 999999 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: fail-open on garbage payload" {
    run bash -c "printf 'not json' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: DISABLE hatch honored" {
    mk_transcript 999999 "claude-fable-5"
    ANTCRATE_COST_GUARD_DISABLE=1 run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"claude-api\"}}' | env ANTCRATE_COST_GUARD_DISABLE=1 '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "anticipator: unknown skill name fails open (no dir to size)" {
    mk_transcript 130000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"tool_name\":\"Skill\",\"tool_input\":{\"skill\":\"no-such\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: RED** — `bats assets/code/tests/cost_anticipator.bats` → FAIL (no such file).
- [ ] **Step 3: Implement** — `assets/code/hooks/claude/cost-anticipator.sh`:

```bash
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

est_from_bytes() { printf '%s' "$(( $1 / 4 * factor10 / 10 ))"; }

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
        [ "$bytes" -lt 262144 ] && exit 0                    # small reads: free pass
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
        est=$(( plen / 4 * factor10 / 10 ))
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
```

- [ ] **Step 4: GREEN + shellcheck** — `bats assets/code/tests/cost_anticipator.bats` → 10 PASS; `shellcheck assets/code/hooks/claude/cost-anticipator.sh` → clean. `chmod +x` the hook.
- [ ] **Step 5: Live smoke** — `antcrate --hook-smoke assets/code/hooks/claude/cost-anticipator.sh --payload '<synthetic Skill payload from a fixture transcript>'` — verify allow (rc 0) on a small skill and block (rc 2) on a claude-api payload against a high-context fixture transcript.
- [ ] **Step 6: Commit** — `git commit -m "feat(hooks): cost-anticipator predictive PreToolUse gate (Skill/Agent/Read)"`
- [ ] **Step 7: Wire into `~/.claude/settings.json`** (user zone — at execution, after copy-back): add to `hooks.PreToolUse` a `{"matcher": "Skill|Agent|Read", "hooks": [{"type": "command", "command": "/home/twntydotsix/.claude/skills/antcrate/assets/code/hooks/claude/cost-anticipator.sh"}]}` entry, mirroring the existing three. Verify with one `--hook-smoke` run post-wire.

---

### Task 3: session-budget-guard becomes model-aware (the Fable raise goes LIVE here)

**Files:** Modify `assets/code/hooks/claude/session-budget-guard.sh:17-18`. Create `assets/code/tests/session_budget_guard_models.bats`.

- [ ] **Step 1: Write the failing tests** — `assets/code/tests/session_budget_guard_models.bats`:

```bash
#!/usr/bin/env bats
# per-model budget lookup in session-budget-guard (spec 2026-06-11 Unit 5)

setup() {
    HOOK="$BATS_TEST_DIRNAME/../hooks/claude/session-budget-guard.sh"
    export ANTCRATE_POLICY_FILE="$BATS_TEST_TMPDIR/policy.json"
    export ANTCRATE_SESSION_GATE_DIR="$BATS_TEST_TMPDIR/gate"
    T="$BATS_TEST_TMPDIR/transcript.jsonl"
    jq -n '{budgets:{default:{soft:100000,hard:140000},fable:{soft:250000,hard:400000}}}' \
        > "$ANTCRATE_POLICY_FILE"
}

mk() { jq -cn --argjson n "$1" --arg m "$2" \
    '{message:{model:$m,usage:{input_tokens:$n,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' > "$T"; }

run_hook() { printf '%s' "{\"transcript_path\":\"$T\",\"session_id\":\"s1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" | "$HOOK"; }

@test "gate: 176k on fable ALLOWS (fable hard 400k)" {
    mk 176000 "claude-fable-5"; run run_hook; [ "$status" -eq 0 ]
}

@test "gate: 401k on fable BLOCKS" {
    mk 401000 "claude-fable-5"; run run_hook; [ "$status" -eq 2 ]
}

@test "gate: 176k on unknown model BLOCKS (default 140k — bitwise-identical to today)" {
    mk 176000 "claude-mystery-9"; run run_hook; [ "$status" -eq 2 ]
}

@test "gate: env override beats policy (human-only escape unchanged)" {
    mk 176000 "claude-fable-5"
    run bash -c "printf '%s' '{\"transcript_path\":\"'$T'\",\"session_id\":\"s1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}' | env ANTCRATE_SESSION_HARD=150000 ANTCRATE_POLICY_FILE='$ANTCRATE_POLICY_FILE' ANTCRATE_SESSION_GATE_DIR='$ANTCRATE_SESSION_GATE_DIR' '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "gate: missing policy file -> default budgets still enforced" {
    rm -f "$ANTCRATE_POLICY_FILE"; mk 176000 "claude-fable-5"
    run run_hook; [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: RED** — first and (if budgets resolve wrong) others FAIL against the current hardcoded 140k.
- [ ] **Step 3: Implement** — in `session-budget-guard.sh`, replace lines 17–18 (`SOFT=`/`HARD=`) with placeholders and resolve AFTER the transcript is known (insert right after the `case "$context"` fail-open at line 33):

```bash
# ---- per-model budgets (spec 2026-06-11 Unit 5) ------------------------------
# env override (human-only) > policy.budgets.<model> > policy.budgets.default
# > builtin 100k/140k. Fable raise: user directive 2026-06-11, evidence-backed.
POLICY="${ANTCRATE_POLICY_FILE:-$HOME/.antcrate/anycrate/policy.json}"
model_id="$(tail -n 200 "$transcript" 2>/dev/null \
    | jq -R 'fromjson? | .message.model? // empty | select(. != "")' 2>/dev/null | tail -n 1 | tr -d '"')"
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
```

(Lines 17–18 become comments pointing here; everything below line 35 is untouched.)
- [ ] **Step 4: GREEN + regression** — `bats assets/code/tests/session_budget_guard_models.bats` → 5 PASS; `bats assets/code/tests/session_budget_guard.bats` (existing 14) → still PASS (they pin default behavior); shellcheck clean.
- [ ] **Step 5: Commit** — `git commit -m "feat(hooks): per-model session budgets — Fable soft 250k / hard 400k via policy.json (user directive 2026-06-11)"`

---

### Task 4: typed duties + `duty_involvement` knob

**Files:** Modify `assets/code/lib/duties.sh`, `assets/code/bin/antcrate` (`--duty` parse gains `--type`; new `--duty-involvement`). Create `assets/code/tests/duties_typed.bats`.

**Design notes:** line format becomes `- [ ] 2026-06-11 — [research] text` (untyped legacy lines read as `policy`). `--duties` keeps FILE-ORDER numbering (indices must stay valid for `--duty-done`) but prints group headers per type with each item keeping its flat index.

- [ ] **Step 1: Write the failing tests** — `assets/code/tests/duties_typed.bats` (same `setup`/`src` helpers as `tests/duties.bats`, plus `export ANTCRATE_DUTY_INVOLVEMENT=` unset by default):

```bash
@test "duty: --type research records typed line" {
    run src "ac_duty_add --type research 'look up bats parallel flags'"
    [ "$status" -eq 0 ]
    grep -Eq '^- \[ \] [0-9-]{10} — \[research\] look up bats parallel flags$' "$ANTCRATE_DUTIES_FILE"
}

@test "duty: invalid type rejected rc2" {
    run src "ac_duty_add --type banana 'x'"
    [ "$status" -eq 2 ]
}

@test "duty: untyped add stays format-identical to legacy (backcompat)" {
    run src "ac_duty_add 'plain item'"
    grep -Eq '^- \[ \] [0-9-]{10} — plain item$' "$ANTCRATE_DUTIES_FILE"
}

@test "duties: list shows type tags, flat indices match duty-done" {
    src "ac_duty_add 'legacy one'" >/dev/null
    src "ac_duty_add --type command 'run antcrate --ci'" >/dev/null
    run src "ac_duty_list"
    [[ "$output" == *"[policy]"* && "$output" == *"[command]"* ]]
    src "ac_duty_done 2" >/dev/null
    grep -q '^- \[x\].*run antcrate --ci' "$ANTCRATE_DUTIES_FILE"
    grep -q '^- \[ \].*legacy one' "$ANTCRATE_DUTIES_FILE"
}

@test "involvement: env override > config > default lean" {
    run src "ac_duty_involvement"; [ "$output" = "lean" ]
    printf 'duty_involvement=hands-on\n' >> "$ANTCRATE_HOME/config"
    run src "ac_duty_involvement"; [ "$output" = "hands-on" ]
    run bash -c "export ANTCRATE_DUTY_INVOLVEMENT=standard ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_DUTIES_FILE='$ANTCRATE_DUTIES_FILE' ANTCRATE_LOG_LEVEL=error; . '$LIB/log.sh'; . '$LIB/duties.sh'; ac_duty_involvement"
    [ "$output" = "standard" ]
}

@test "involvement: garbage config value falls back to lean" {
    printf 'duty_involvement=chaotic\n' >> "$ANTCRATE_HOME/config"
    run src "ac_duty_involvement"; [ "$output" = "lean" ]
}
```

- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement** in `lib/duties.sh`:

```bash
# valid duty types; untyped legacy lines read as "policy"
_ac_duty_type_ok() { case "$1" in policy|command|research|debug) return 0;; *) return 1;; esac; }

# involvement: env (test/orchestrator read) > config line > lean.
# Config is rule-#13 human-only — only the user sets their own involvement.
ac_duty_involvement() {
    local v="${ANTCRATE_DUTY_INVOLVEMENT:-}"
    if [[ -z "$v" && -f "${ANTCRATE_HOME:-$HOME/.antcrate}/config" ]]; then
        v=$(grep -E '^duty_involvement=' "${ANTCRATE_HOME:-$HOME/.antcrate}/config" | tail -1 | cut -d= -f2)
    fi
    case "$v" in lean|standard|hands-on) printf '%s\n' "$v" ;; *) printf 'lean\n' ;; esac
}
```

`ac_duty_add` gains arg parsing before the existing body (`--type t` consumed; invalid type → `ac_error` + return 2; typed text rendered as `[${dtype}] $clean` in the printf, untyped printf unchanged). `ac_duty_list` keeps `grep '^- \[ \]' | nl -w2 -s'. '` as the index source, then post-processes: print each line, tagging untyped ones `[policy]` (sed: insert `[policy] ` after the `— ` when no `[type]` present in display only — never rewrites the file).
- [ ] **Step 4: Wire wrapper** — `--duty` parse: collect optional `--type <t>` before the text arg (follow the `--hook-smoke` multi-arg parse pattern); new `--duty-involvement) ACTION="duty_involvement"; shift;;` → dispatch `duty_involvement) ac_duty_involvement ;;`. Help lines added.
- [ ] **Step 5: GREEN + regression** — new bats PASS, existing `tests/duties.bats` (10) still PASS, shellcheck clean.
- [ ] **Step 6: Commit** — `git commit -m "feat(duties): typed duties (policy/command/research/debug) + duty_involvement knob (TH tier routing)"`
- [ ] **Step 7 (execution checkpoint, user zone):** append `duty_involvement=hands-on` to `~/.antcrate/config` — rule-#13 write pre-approved in the spec (decision 6), confirm with the user at the checkpoint before writing; ledger the config change in Task 8.

---

### Task 5: `--fetch` — no-LLM web fetcher

**Files:** Create `assets/code/lib/fetch.sh`, `assets/code/tests/fetch.bats`. Modify `bin/antcrate` (parse/dispatch/help + source line).

- [ ] **Step 1: Write the failing tests** — `assets/code/tests/fetch.bats`. Network is stubbed with a `curl` PATH shim:

```bash
setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_FETCH_DIR="$BATS_TEST_TMPDIR/fetch"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_CURL_FAIL:-0}" = "1" ] && exit 22
printf '<html><script>x</script><body>Hello <b>fetch</b> world</body></html>\n'
SH
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

src() { bash -c "export PATH='$PATH' ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_FETCH_DIR='$ANTCRATE_FETCH_DIR' ANTCRATE_LOG_LEVEL=error; . '$LIB/log.sh'; . '$LIB/intel.sh'; . '$LIB/fetch.sh'; $1"; }

@test "fetch: snapshots normalized body and prints path" {
    run src "ac_fetch https://example.com/docs/page --name expage"
    [ "$status" -eq 0 ]
    snap=$(ls "$ANTCRATE_FETCH_DIR/expage/"*.body)
    grep -q 'Hello fetch world' "$snap"
    ! grep -q '<script>' "$snap"
    [[ "$output" == *"$snap"* ]]
}

@test "fetch: default slug derived from url" {
    src "ac_fetch https://example.com/a/b" >/dev/null
    ls "$ANTCRATE_FETCH_DIR"/example.com-a-b/*.body
}

@test "fetch: unchanged content -> no duplicate snapshot (append-only, hash-keyed)" {
    src "ac_fetch https://example.com/x --name x" >/dev/null
    src "ac_fetch https://example.com/x --name x" >/dev/null
    [ "$(ls "$ANTCRATE_FETCH_DIR/x/"*.body | wc -l)" -eq 1 ]
}

@test "fetch: curl failure -> rc 1, nothing written" {
    FAKE_CURL_FAIL=1 run src "FAKE_CURL_FAIL=1 ac_fetch https://example.com/x --name x"
    [ "$status" -eq 1 ]
    [ ! -d "$ANTCRATE_FETCH_DIR/x" ]
}

@test "fetch: missing url rc2; non-http scheme refused rc2" {
    run src "ac_fetch"; [ "$status" -eq 2 ]
    run src "ac_fetch file:///etc/passwd"; [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement** — `assets/code/lib/fetch.sh`:

```bash
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
        snap=$(ls -1 "$sdir/"*"-${sha:0:8}.body" 2>/dev/null | tail -1)
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
```

- [ ] **Step 4: Wire wrapper** — source line for `fetch.sh` AFTER `intel.sh`; parse `--fetch) ACTION="fetch"; NAME="$2"; shift 2;;` capturing trailing `--name` via the remaining-args pattern; dispatch `fetch) ac_fetch "$NAME" ${FETCH_NAME:+--name "$FETCH_NAME"} ;;` (follow the exact multi-arg style used by `--hook-smoke` parsing). Help line added.
- [ ] **Step 5: GREEN + shellcheck; one real smoke** — `antcrate --fetch https://docs.claude.com/en/release-notes/claude-code --name cc-notes-smoke` prints a snapshot path.
- [ ] **Step 6: Commit** — `git commit -m "feat(fetch): --fetch no-LLM web fetcher (intel normalizer reuse, append-only snapshots)"`

---

### Task 6: skill split — trim `antcrate`, create `antcrate-builder`

**Files:** Rewrite `SKILL.md` (repo root); create `assets/docs/LIB_MAP.md` (relocated lib catalog — VERBATIM move, nothing deleted), `assets/skills/builder/SKILL.md`; create `assets/code/tests/skills_builder.bats`; symlink + agent pointers (user zone).

- [ ] **Step 1: Write the failing test** — `assets/code/tests/skills_builder.bats`:

```bash
setup() { ROOT="$BATS_TEST_DIRNAME/../../.."; }

@test "builder skill: exists with generated-section markers" {
    f="$ROOT/assets/skills/builder/SKILL.md"
    [ -f "$f" ]
    grep -q 'ac:builder:flags:start' "$f"
    grep -q 'ac:builder:flags:end' "$f"
}

@test "builder skill: every flag in the marker section exists in bin/antcrate (drift check)" {
    f="$ROOT/assets/skills/builder/SKILL.md"
    flags=$(sed -n '/ac:builder:flags:start/,/ac:builder:flags:end/p' "$f" | grep -oE '\-\-[a-z-]+' | sort -u)
    [ -n "$flags" ]
    for fl in $flags; do
        grep -q -- "$fl" "$ROOT/assets/code/bin/antcrate" || { echo "DRIFT: $fl not in wrapper"; return 1; }
    done
}

@test "orchestrator SKILL.md: trimmed under 8000 bytes and points at LIB_MAP/MANUAL/PATTERNS" {
    f="$ROOT/SKILL.md"
    [ "$(wc -c < "$f")" -lt 8000 ]
    grep -q 'LIB_MAP.md' "$f"; grep -q 'MANUAL.md' "$f"; grep -q 'PATTERNS.md' "$f"
}

@test "LIB_MAP.md: carries the relocated lib catalog (registry.sh present)" {
    grep -q 'registry.sh' "$ROOT/assets/docs/LIB_MAP.md"
}
```

- [ ] **Step 2: RED.**
- [ ] **Step 3: Create `assets/docs/LIB_MAP.md`** — move the "Where things live" lib/bin/hook catalog out of the current `SKILL.md` VERBATIM (cut-paste under a `# AntCrate — Lib Map` heading with one intro line; this is the relocation the spec promises — git history keeps the original).
- [ ] **Step 4: Rewrite root `SKILL.md`** (target < 8000 bytes ≈ 1.5–2k tokens). Keep frontmatter `name`/`description` as-is. Body sections, in order: (1) one-paragraph role statement ("AntCrate is the single controllable surface; you are the orchestrator"); (2) Gateway Law digest — three one-liners for rules #1 (no destructive op without backup + explicit approval), #12 (removals LAST; verify chain), #13 (config human-only); (3) "Light by default, deep on demand" — read `assets/docs/PATTERNS.md` before project-level shell, `assets/code/AGENTS.md` when an op touches a rule, `docs/MANUAL.md` for full command reference, `assets/docs/LIB_MAP.md` for internals, `state.md`+`ledger.md` head for context — AT THE MOMENT OF NEED, never as a session-start tax (the "unless inline" rule); (4) dispatch table — which skill each role loads (orchestrator: this; builders: `antcrate-builder`; resolver: `anycrate`; wrap-up: `session-close`; intel: `intel`) + pointer to `~/.antcrate/anycrate/policy.json` for tiers/budgets; (5) maintenance protocol + self-host pointers (keep the existing "Maintenance protocol" and "Self-host" sections verbatim — they're short); (6) trigger phrases line (keep verbatim).
- [ ] **Step 5: Create `assets/skills/builder/SKILL.md`** (~1k tokens), frontmatter `name: antcrate-builder`, `description: Run AntCrate commands inside a registered project — for builder/review agents (Cody, Claudia). How to USE antcrate, never how to modify it.` Body: (1) the law in five lines (backup before structural, no bare git push / mv / rm / cd — use the wrapper, config is human-only, removals need the user, no flag fits → `--propose`); (2) the flag table between `<!-- ac:builder:flags:start -->` and `<!-- ac:builder:flags:end -->`:

```markdown
| Intent | Command |
|---|---|
| where am I / what exists | `antcrate --status`, `antcrate --map <project>` |
| enter a project | `antcrate --in <project>` (never bare cd) |
| commit | `antcrate --commit <project> -m "type(scope): msg" -- <files>` |
| push | `antcrate --pp <project>` (never bare git push) |
| run tests | `antcrate --ci [--source <tree>]` |
| backup before structural change | `antcrate --backup <project>` |
| log activity | `antcrate --emit-activity <project> <text>` |
| need a missing wrapper | `antcrate --propose "<name>" "<why>"` |
| file human-only work | `antcrate --duty --type <policy\|command\|research\|debug> "<text>"` |
```

(3) escalation: surface to the orchestrator for anything structural/destructive/cross-project; (4) one line: "Do NOT load the `antcrate` orchestrator skill — this file is your whole surface."
- [ ] **Step 6: GREEN** — `bats assets/code/tests/skills_builder.bats` → 4 PASS.
- [ ] **Step 7 (execution, user zone):** `ln -s ~/projects/antcrate/assets/skills/builder ~/.claude/skills/antcrate-builder`; append to `~/.claude/agents/cody.md`, `claudia.md`, `cody-tester.md` (after their existing antcrate references): `Load the **antcrate-builder** skill for all antcrate usage — do NOT load the full `antcrate` skill.` Verify `/` skill menu shows antcrate-builder.
- [ ] **Step 8: Commit** — `git commit -m "feat(skills): three-tier skill cut — trim orchestrator SKILL.md, add antcrate-builder, LIB_MAP relocation"`

---

### Task 7: permission allowlist

- [ ] **Step 1 (execution, user zone):** via the **update-config skill**, add to `~/.claude/settings.json` `permissions.allow`: the entry for antcrate Bash invocations — verify the exact current syntax (`Bash(antcrate *)` vs `Bash(antcrate:*)`) against the live Claude Code docs at execution time (do NOT trust memory; the update-config skill knows).
- [ ] **Step 2: Verify** — in a fresh session context, `antcrate --status` runs without a permission prompt; a non-antcrate structural command still prompts.

---

### Task 8: governance, docs, ledger, CI, ship

- [ ] **Step 1: AGENTS.md** — append three rules (next free numbers): (a) builder-role agents load `antcrate-builder`, not `antcrate`; briefing a T3 agent to load the orchestrator skill is a violation; (b) agents MUST NOT set `ANTCRATE_COST_GUARD_DISABLE` or `ANTCRATE_DUTY_INVOLVEMENT`, and never close duties; before any model-driven research pass: check involvement, try `--fetch` — a research spawn without that check is a violation at `standard`+; (c) `policy.json`: only `budgets.fable` is agent-adjustable (Cable, evidence-backed, ledger-recorded at change time); all else human-only or via `--propose`.
- [ ] **Step 2: PATTERNS.md** — add rows: `--policy` / `--policy-init`, `--duty --type`, `--duty-involvement`, `--fetch`; note the cost-anticipator + per-model gate under the hooks section.
- [ ] **Step 3: Proposals** — `antcrate --propose "skill-render" "generator emitting antcrate-builder's flag table from PATTERNS.md so it cannot drift (mirrors AnyCrate command-pack generator); manual table shipped 2026-06-11 with audit drift-check as interim"`. Ledger records `model-tiers` + `skill-research-guard` as ABSORBED by this build (proposals.log is append-only — the ledger entry IS the retirement record, same as 2026-06-10).
- [ ] **Step 4: Full CI** — `antcrate --ci --source <worktree>` → expect ~615 + ~40 new ≈ 655 bats PASS, shellcheck clean. Then copy back all changed files (`cp` + `cmp` loop), run full local `antcrate --ci`.
- [ ] **Step 5: Ledger + state** — ledger entry (shipped units, bats N→M, the config/settings user-zone changes, absorbed proposals); state.md roll per protocol with next-step pointer (AnyCrate build is next in queue).
- [ ] **Step 6: Ship** — `ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate -m "feat: least-cost allocation layer + skill scoping (spec 2026-06-11)" -- <files>` then `antcrate --pp antcrate -y`.

---

## Self-review notes (done at plan time)

- **Spec coverage:** Unit 1→Task 6, Unit 2→Task 2, Unit 3→Task 1, Unit 4→Task 7, Unit 5→Task 3, Unit 6→Tasks 4+5, AGENTS/docs/absorptions→Task 8. The `claude-api` `extra_bytes` override and the orchestrator-never-policy-assigned note are in Task 1's seed; the involvement consent model is in Task 4.
- **Known judgment calls recorded:** `--duties` keeps flat numbering (duty-done index integrity) with type tags instead of physically grouped sections — satisfies the spec's intent without breaking `--duty-done`. The builder drift check is a bats test rather than an audit-only step, so it runs on every `--ci`.
- **Verify-at-execution items (deliberate, not placeholders):** the `Bash(antcrate *)` permission syntax (Task 7, via update-config) and the plugin-cache skill path for non-`~/.claude/skills` skills (Task 2 sizes only `$SKILLS_DIR/<name>/SKILL.md`; plugin-cache skills fail open by design in v1).
