# Spec — Least-Cost Allocation Layer + Skill Scoping (divide and conquer)

**Status:** Approved design, pending user spec review
**Date:** 2026-06-11
**Deciders:** User + Cable
**Roadmap position:** Builds BEFORE the AnyCrate build (queue #3 → #4). Absorbs the queued
proposals `model-tiers` and `skill-research-guard`, and the state.md resume target
"tiered token-limit + least-cost orchestration spec." Defines `policy.json` fully so the
AnyCrate build (spec 2026-06-10) inherits the tier map instead of re-deciding it.

## Context

Two incidents drive this spec. (1) The 2026-06-11 model-tier research session loaded the full
`claude-api` skill and pushed context to 264k, tripping the 140k hard gate — the cost was
foreseeable from file sizes *before* the load, but nothing measured it. (2) The antcrate skill
has grown into a monolith: every consumer (orchestrator, builder agents, automation) pays the
same session-start token tax (SKILL.md ~4k tokens + the mandated PATTERNS ~7k + AGENTS ~5k +
state/ledger read-first chain) regardless of how little of it their role needs.

Principle: **token cost of a skill must match the role that loads it**, and **foreseeable
context blowouts get blocked before the expensive call executes, not after.** Automatics
(daemon, timers, shell hooks) get no skill at all — they are deterministic Bash and already
zero-token.

Model facts (researched 2026-06-11, cached): Fable 5 = 1M ctx / 128K out / $10–$50 per MTok;
Opus 4.8 = 1M / 128K / $5–$25; Sonnet 4.6 = 1M / 64K / $3–$15; Haiku 4.5 = 200K / 64K / $1–$5.
Cost ratio Haiku:Sonnet:Opus:Fable = 1:3:5:10. The Fable tokenizer counts ~30% MORE tokens for
identical content vs Opus-tier. `effort` is not supported on Haiku 4.5. Cache reads ≈0.1×,
writes 1.25×; spawned agents start cache-cold.

## Decisions (locked, 2026-06-11)

1. **Three-tier skill cut + trim** — `antcrate` (orchestrator, trimmed), new
   `antcrate-builder` (command surface only), `anycrate` (resolver, already specced).
   `session-close` / `intel` / `cpp-check` stay separate as they are.
2. **Predictive cost engine as a standalone plugin-posture hook** (`cost-anticipator.sh`) —
   warn + block. Built in this repo for bats/`--hook-smoke` coverage, but self-contained at
   runtime (script + data file only; no antcrate invocation needed once installed).
3. **Blanket permission allowlist for `antcrate` invocations** — the wrapper's internal gates
   are the safety layer, not the permission prompt.
4. **This spec lands before the AnyCrate build** and owns the `policy.json` definition.
5. **Per-model session budgets; Fable's raised on evidence** (user directive, 2026-06-11):
   a prior session ran well above 300k context with no observed degradation. The uniform
   100k/140k gate underfits Fable's 1M window. Fable-tier thresholds are raised and made
   self-governable by Cable against recorded evidence (see Unit 5); the
   `ANTCRATE_SESSION_GATE_DISABLE` hatch remains human-only, unchanged.
6. **The human is a tier (TH)** (user directive, 2026-06-11): the cheapest executor in the
   system is the user — zero token rate. Duties expand from a policy-decision checklist into
   a typed, involvement-configurable work surface (Unit 6), and research routes through
   no-LLM fetch scripts or TH duties before any model spends. User's own involvement level:
   `hands-on`; fresh-install default: `lean`.

## Unit 1 — Skill split by consumer role

| Skill | Consumer | Size target | Content |
|---|---|---|---|
| `antcrate` (trimmed) | Orchestrator (Fable/Opus) | ~1.5k tokens | Role statement; Gateway Law digest (one-liners for rules #1/#12/#13); dispatch guidance (tier map pointer, which agent loads which skill); pointer table — PATTERNS for flags, AGENTS for rules, MANUAL.md for the full command reference, state.md/ledger.md for context. |
| `antcrate-builder` (new) | Cody / Claudia / cody-tester (Haiku/Sonnet) | ~1k tokens | How to RUN antcrate, never how to modify it: build-loop flag subset (`--in`/`--anchor`, `--commit`, `--pp`, `--ci`, `--backup`, `--status`, `--map`, `--propose`, `--emit-activity`); digest of the hard rules an agent can actually violate (#1, #2, #3, #10, #11, #12, #13, #14, #19); the escape valve — "no flag fits → `--propose`, never bare shell." |
| `anycrate` | Resolver | per its spec | Unchanged; consumes `policy.json` defined here. |

- The deep lib catalog and invariants currently in `antcrate` SKILL.md move out into the docs
  that already cover them (MANUAL.md commands; architecture.md design; SKILL.md keeps pointers).
  Nothing is deleted — content relocates and git history retains everything (Gateway Law:
  this spec performs no removals).
- The orchestrator's "unless inline" rule is encoded in the trimmed skill text: light by
  default; when building inline (agile mode), read PATTERNS/AGENTS **on demand at that
  moment** — never as a session-start tax.
- `antcrate-builder` lives in the repo at `assets/skills/builder/SKILL.md` (same pattern as
  `assets/skills/intel/`), symlinked to `~/.claude/skills/antcrate-builder`. Agent definition
  files (`~/.claude/agents/cody.md`, `claudia.md`, `cody-tester.md`) gain a line directing
  them to load `antcrate-builder` (and NOT `antcrate`).
- **Anti-drift:** v1 of the builder skill is hand-written but wrapped in generated-section
  markers (`<!-- ac:builder:flags:start/end -->`). The session-close part-2 audit gains a
  drift line: builder flag subset vs PATTERNS.md. A `--skill-render` generator (same pattern
  as the AnyCrate command-pack generator) is filed as a proposal, not built now.

## Unit 2 — Predictive cost engine: `hooks/claude/cost-anticipator.sh`

The missing half of `session-budget-guard.sh`: that hook reacts to context that already grew;
this one estimates the cost of an expensive call BEFORE it executes and stops foreseeable
blowouts. PreToolUse, matchers `Skill|Agent|Read` (separate settings entry; the session gate's
`*` matcher continues unchanged).

- **Estimator:** `est_tokens ≈ bytes / 4 × tokenizer_factor(model)` (Fable 1.3, others 1.0).
  Model detected from the transcript JSONL (last assistant entry's `model` field — same parse
  surface session-budget-guard already reads); unknown model → factor 1.0 + default budgets.
  Current context size measured the same way session-budget-guard measures it.
- **On `Skill`:** resolve the skill's directory under `~/.claude/skills/` /
  plugin cache; size SKILL.md plus any heavy companion files the skill is known to mandate
  (per-skill `extra_bytes` override in the cost table, seeded for `claude-api`). Project
  `current_context + est_load`:
  - projection > the model's hard budget (Unit 5) or > `window − 20% margin` → **block (exit 2)**
    with the cheaper path named in the message ("dispatch a subagent to fetch the answer";
    "read shared/models.md only"; "switch tier before loading").
  - projection > soft budget → warn (stderr, exit 0), throttled like the session gate.
- **On `Agent`:** read `model` + prompt size from `tool_input`. Checks: (a) prompt +
  expected shared context overflowing the target model's window (Haiku 200K is the real
  case) → block; (b) policy-class mismatch per `policy.json` `classes` (bulk work headed to
  Fable, ambiguous multi-file brief headed to Haiku) → warn naming the class. Warn-only on
  mismatch — selection judgment stays with the orchestrator; only window overflow blocks.
- **On `Read`:** file size > warn threshold (default 256 KiB) → warn with projected tokens;
  > block threshold (default: projection past hard budget) → block suggesting offset/limit or
  a subagent.
- **Law (same as session gate):** fails open on any parse/read error; `ANTCRATE_COST_GUARD_DISABLE`
  is human-only — agents MUST NOT set it; no network; logfile-only logging.
- Implements proposal `skill-research-guard`; absorbs `model-tiers` (tier map lands in Unit 3).

## Unit 3 — One policy file, two consumers: `~/.antcrate/anycrate/policy.json`

Already sketched in the AnyCrate spec; defined fully here. jq-managed, atomic temp+rename.

```json
{
  "models": {
    "fable":  { "window": 1000000, "max_out": 128000, "usd_in": 10, "usd_out": 50,
                "tokenizer_factor": 1.3, "effort": true },
    "opus":   { "window": 1000000, "max_out": 128000, "usd_in": 5,  "usd_out": 25,
                "tokenizer_factor": 1.0, "effort": true },
    "sonnet": { "window": 1000000, "max_out": 64000,  "usd_in": 3,  "usd_out": 15,
                "tokenizer_factor": 1.0, "effort": true },
    "haiku":  { "window": 200000,  "max_out": 64000,  "usd_in": 1,  "usd_out": 5,
                "tokenizer_factor": 1.0, "effort": false }
  },
  "budgets": {
    "default": { "soft": 100000, "hard": 140000 },
    "fable":   { "soft": 250000, "hard": 400000,
                 "evidence": "2026-06-10 session >300k, no degradation; user directive 2026-06-11" }
  },
  "classes": {
    "orchestrate": { "agent": "orchestrator", "tier": "T0", "model": "inherit" },
    "heavy":       { "agent": "cody",    "tier": "T1", "model": "opus"    },
    "review":      { "agent": "claudia", "tier": "T2", "model": "sonnet"  },
    "build":       { "agent": "cody",    "tier": "T3", "model": "haiku"   },
    "bulk":        { "agent": "cody",    "tier": "T3", "model": "haiku"   },
    "lookup":      { "agent": "human",   "tier": "TH", "model": "none"    }
  },
  "skill_overrides": { "claude-api": { "extra_bytes": 700000 } },
  "budget_usd": { "session_usd": 5.00, "check": "--cost --porcelain --since today" }
}
```

- `models` is the cost table the hooks read; `classes` is what the AnyCrate dispatch helper
  reads (T0 = orchestrator + inline edits; T1 Opus = heavy single-agent; T2 Sonnet =
  Claudia review/test; T3 Haiku = Cody fleet, precise briefs only — existing policy;
  TH = the human, Unit 6).
- **The orchestrator's model is NEVER policy-assigned.** `"model": "inherit"` means T0 runs
  whatever model the user selected for the session; "orchestrator" is the role, and
  Clyde/Cable are personas of it (Cable = the role on Fable). The policy file only assigns
  models to SPAWNED roles (T1–T3), where least-cost selection actually has a choice to make.
- Selection rule of record (documented in the file's companion doc, used by the orchestrator
  when choosing a tier): `cost = est_tokens × rate × (1 + rework_risk) + N × shared_context ×
  rate` — the second term is the spawn-duplication tax (spawned agents start cache-cold).
  TH has `rate = 0`: for TH-eligible task classes the rule degenerates to a consent check —
  route to the human whenever `duty_involvement` permits it (Unit 6). The trade is explicit:
  tokens for latency, and the involvement knob is the user's standing consent to that trade.
- Freshness: model pricing/window changes arrive via the intel tracker; the intel skill files
  a proposal to update `models` — it never edits the file directly.

## Unit 4 — Permissions: `antcrate` runs without prompts

Add `Bash(antcrate *)` (current Claude Code allow-syntax verified at build time via the
update-config skill) to the permission allowlist, for the orchestrator and subagents alike.
Safety does not regress because the prompt was never the safety layer:

- destructive ops still hit `ac_safety_guard_destructive` (backup + explicit approval; fails
  closed non-TTY — a background agent literally cannot approve its own removal);
- gateway-guard still blocks bare destructive shell;
- the Gateway Law still requires explicit user approval for removals.

Non-antcrate structural shell keeps prompting. This closes the loop on "an agent can commit
with antcrate": builders run `--commit`/`--pp`/`--ci` friction-free while the wrapper's
guards (secret-pattern scan, push triage, CI hook) do the actual guarding.

## Unit 5 — Per-model session budgets (the Fable raise)

`session-budget-guard.sh` becomes model-aware: detect the model from the transcript (same
parse as Unit 2), look up `budgets.<model>` in `policy.json`, fall back to
`budgets.default` (100k/140k) when the file or entry is missing — so behavior for every
non-Fable model is bitwise-identical to today, and the hook still works with no policy file.

**The Fable raise (user directive, 2026-06-11):** the 100k/140k gate was calibrated before
real Fable evidence existed. A 2026-06-10 session exceeded 300k context with no observed
degradation, and Fable's window is 1M with a tokenizer that counts ~30% more tokens for the
same content. Initial Fable budgets: **soft 250k / hard 400k** (in Fable's own token units).
The wrap-up whitelist and `/clear` release semantics are unchanged — the ceiling moves; the
mechanism doesn't.

**Self-governance grant (user directive, 2026-06-11):** Cable may adjust the Fable-tier
budget values in `policy.json` without a fresh user round-trip, under three conditions:
(1) each change is backed by named evidence (a session observation: degradation seen →
lower; sustained clean operation near the ceiling → raise); (2) each change is recorded in
`ledger.md` at change time with the evidence cited; (3) the change touches ONLY
`budgets.fable`. Other models' budgets and the `ANTCRATE_SESSION_GATE_DISABLE` /
`ANTCRATE_COST_GUARD_DISABLE` hatches remain human-only (AGENTS rule #13 posture). ENV
overrides `ANTCRATE_SESSION_SOFT/HARD` keep working and beat the policy file (human-only,
as today).

## Unit 6 — Human tier (TH): typed duties + involvement preference + `--fetch`

The cheapest executor in the system is the user — zero token rate, full trust, and for web
lookups often faster than a research fan-out (the 264k incident was a research query whose
answer the user could have pasted in). Duties grow from a policy-decision checklist into the
routing surface for that tier.

- **Typed duties** (`lib/duties.sh` extension, backward-compatible — untyped entries read as
  `policy`): `--duty [--type policy|command|research|debug] "<text>"`.
  - `policy` — decisions/approvals (today's behavior, unchanged).
  - `command` — an exact antcrate command for the user to run themselves, with expected
    output noted in the duty text. Doubles as antcrate practice for users who want to learn
    the surface instead of spending tokens on commands they can easily run.
  - `research` — an information request with suggested search terms or URLs; the user pastes
    findings back into the session or drops them in a file named by the duty.
  - `debug` — a user-side investigation (auth state, local env, account/billing pages) the
    agent cannot or should not reach.
  - `--duties` lists grouped by type; the `duties: N open` status line is unchanged. Agents
    still FILE duties and never close them (`--duty-done` stays user-driven).
- **`duty_involvement` knob** in `~/.antcrate/config` — `lean | standard | hands-on`.
  Rule-#13 territory is exactly right here: only the human sets their own involvement; an
  agent can neither lower it to dump work on the user nor raise it to skip work.
  - `lean` (fresh-install default): duties stay policy/approval-only — no work routing.
  - `standard`: `research` duties route to TH when the alternative is a model-driven
    web/research pass.
  - `hands-on` (THIS user's setting, set at build time): `research` + `command` + `debug`
    all route to TH first — the orchestrator files a duty BEFORE spending tokens whenever
    the task class is TH-eligible. The cost-anticipator's block message also names "file it
    as a duty (`--duty --type research ...`)" as a cheaper path.
- **`--fetch <url> [--name <slug>]`** — research without model tokens. Generalizes the intel
  tracker's proven machinery (curl + the awk normalizer, zero LLM, no web-search API) to
  arbitrary URLs: pull → normalize → snapshot to `~/.antcrate/fetch/<slug>/<ts>-<sha8>.body`,
  print the path. The model then reads a small normalized file locally instead of spawning a
  research agent. No allowlist (unlike intel — this is user/orchestrator-directed, not a
  timer), but same fail-closed fetch hygiene, same append-only snapshot convention, and the
  default research order is: TH duty (if involvement permits) → `--fetch` → model research
  as the LAST resort.

## AGENTS.md additions

- Builder-role agents load `antcrate-builder`, not `antcrate`; an agent brief that mandates
  loading the full orchestrator skill into a T3 agent is a violation.
- Agents MUST NOT set `ANTCRATE_COST_GUARD_DISABLE` (same law as the session-gate and canary
  DISABLE hatches).
- `policy.json` mutations: `budgets.fable` per the Unit 5 grant (ledger-recorded); everything
  else human-only or via a filed proposal.
- Agents MUST NOT set or change `duty_involvement` (rule-#13 territory), and never close
  duties. Before any model-driven research pass, check involvement + try `--fetch` first;
  a research spawn without that check is a violation at `standard` or above.

## Tests (bats, test-first)

`tests/cost_anticipator.bats` + `tests/policy.bats` + builder-skill checks. Cases: estimator
math incl. tokenizer factor; model detection from transcript fixture + unknown-model fallback;
Skill block at high-context fixture (the claude-api scenario, via `--hook-smoke` synthetic
payloads); Skill warn at soft; Agent window-overflow block (Haiku 200K) vs class-mismatch
warn-only; Read warn/block thresholds; fail-open on missing/corrupt policy.json; DISABLE hatch
honored; session gate per-model lookup (fable budgets picked up, default fallback, env
override wins); policy.json schema validation + atomic write; builder SKILL.md marker presence
+ flag-subset-vs-PATTERNS drift check. Unit 6: typed-duty CRUD + untyped-reads-as-policy
backcompat + grouped listing; involvement knob read (lean/standard/hands-on + unset default);
`--fetch` snapshot shape + normalizer reuse + append-only + bad-URL fail-closed. Estimate:
~40 bats total.

## Consequences

- Easier: builder agents (especially Haiku) stop paying the orchestrator's context tax;
  research-class blowouts (264k incident) become mechanically impossible; Fable sessions stop
  hitting an artificial 140k wall mid-task; AnyCrate's build step 5 (policy + dispatch)
  becomes a consumption job instead of a design job; token-limited users offload TH-eligible
  work to themselves by preference, and learn the antcrate surface doing it.
- Harder: two more surfaces to keep fresh (builder skill ↔ PATTERNS drift; cost table ↔
  pricing drift) — both covered by existing mechanisms (part-2 audit line; intel feed).
  TH routing adds latency where it's enabled — by design, and only ever by user consent.
- Revisit: raising Opus/Sonnet budgets when evidence exists (user decision, not covered by
  the Unit 5 grant); the `--skill-render` generator proposal; per-skill measured-size cache
  instead of bytes/4 estimation; `--fetch` allowlist if it ever feeds anything automatic.

## Build order

1. `policy.json` schema + seed (`models` from the cached research) + `tests/policy.bats`.
2. `cost-anticipator.sh` + bats + `--hook-smoke` live-smoke + settings.json wiring.
3. Session-gate model-awareness (Unit 5) + bats; Fable budgets live from this step.
4. Typed duties + `duty_involvement` knob (Unit 6) + bats; set user's config to `hands-on`
   (rule-#13: user types or explicitly approves the config line).
5. `--fetch` (Unit 6) + bats, reusing the intel normalizer.
6. Skill split: trim `antcrate` SKILL.md, author `assets/skills/builder/`, symlink, update
   agent .md pointers.
7. Permissions allowlist via the update-config skill.
8. Ledger + state roll; mark proposals `model-tiers` + `skill-research-guard` absorbed by
   this spec; file `--skill-render` proposal; AGENTS.md additions.
