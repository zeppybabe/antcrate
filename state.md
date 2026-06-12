# AntCrate — Current State

_Last updated: 2026-06-12_

## Top of mind

**2026-06-12 (latest) — LEAST-COST LAYER SHIPPED COMPLETE: all 8 plan tasks live; Fable gate now 250k/400k; tests 615 → 653.**

- ✅ Everything in `docs/plans/2026-06-11-least-cost-allocation-and-skill-scoping.md` shipped (full detail in today's ledger entries): policy.json (`--policy`/`--policy-init`), model-aware session gate (**Fable soft 250k / hard 400k LIVE** — smoked on the wired hook), `cost-anticipator.sh` predictive hook (wired `Skill|Agent|Read`, live block verified rc2 at 399k), typed duties + `--duty-involvement` (user = hands-on), `--fetch` (real smoke vs docs.claude.com), three-tier skill cut (SKILL.md 5.2KB, `antcrate-builder` live in skill menu, LIB_MAP.md, agent pointers in cody/claudia/cody-tester), `Bash(antcrate *)` allowlist, AGENTS.md rules 20–22, PATTERNS least-cost section. Proposals `model-tiers` + `skill-research-guard` retired (absorbed); `skill-render` filed.
- Execution note: started subagent-driven per plan header; user redirected mid-build to single inline agent (session-limit pressure) — Tasks 2-fix/4/5/6/7/8 built inline by Cable. Build worktree `least-cost-build` retained (also stale: `least-cost-spec`, `session-gate-duties` — cleanup candidates, user call).
- **VERIFY NEXT SESSION (fresh-session items):** (1) `antcrate --status` runs without a permission prompt (allowlist); (2) `/` skill menu shows `antcrate-builder` from cold start; (3) cost-anticipator fires from settings (pipe-test passed; in-session fire untestable for already-loaded session).
- **NEXT (queue):** (1) AnyCrate build — consumes `policy.json` classes (spec step 1: catalog + tiers + staging, test-first); (2) no-decision mediums: `repoint` + `recover-from-backup`, `ci-core`, `hook-internal-md-guard`, `obsidian-prune`; (3) roadmap #6 `--health` (absorb `session-telemetry`); (4) LAST: intel-report proposals. 7 unread intel items still await an `/intel` pass.

**2026-06-11 (prior) — SPEC LANDED + APPROVED: Least-Cost Allocation Layer + Skill Scoping (`docs/specs/2026-06-11-least-cost-allocation-and-skill-scoping-design.md`). This build now PRECEDES AnyCrate.**

- ✅ Spec approved by user (all decisions locked): (1) **three-tier skill cut** — `antcrate` trimmed to ~1.5k-token orchestrator skill, NEW `antcrate-builder` (~1k tokens, command-surface-only, for Cody/Claudia/cody-tester; lives at `assets/skills/builder/`), `anycrate` unchanged; (2) **`cost-anticipator.sh`** predictive hook (PreToolUse Skill|Agent|Read; warn at soft, BLOCK on window/hard-budget overflow — the 264k claude-api incident becomes mechanically impossible); (3) **`policy.json` fully defined here** (models cost table + classes + budgets); orchestrator model is NEVER policy-assigned (`inherit` = user's session choice; Clyde/Cable are personas of the role); (4) **`Bash(antcrate *)` permission allowlist** — wrapper's internal gates are the safety layer, not the prompt; (5) **per-model session budgets: Fable soft 250k / hard 400k** (evidence: 2026-06-10 session >300k clean; user directive) + self-governance grant — Cable may adjust `budgets.fable` ONLY, evidence-backed, ledger-recorded; DISABLE hatches stay human-only; (6) **TH human tier** — typed duties (policy/command/research/debug), `duty_involvement` knob in config (user = `hands-on`, fresh-install default `lean`), `--fetch <url>` no-LLM web fetcher (intel normalizer reuse); research order = TH duty → `--fetch` → model research LAST.
- Plan written + landed by user as TH command-duty 2026-06-12 (`docs/plans/2026-06-11-least-cost-allocation-and-skill-scoping.md`) → **EXECUTED, see latest block.**

---

## Rolling state protocol (since 2026-06-10)

This file holds ONLY the current + immediately-prior session blocks under "Top of mind."
When a new session block lands on top, move blocks older than the prior session — verbatim,
newest-first — into `state-archive.md` (append-only, never rewrite). Decisions still go to
`ledger.md` at decision time; the archive preserves narrative context only.

Pointers: history `state-archive.md` · decisions `ledger.md` (append-only) · hard rules
`assets/code/AGENTS.md` · flag index `assets/docs/PATTERNS.md` · cross-session memory
`~/.claude/projects/-home-twntydotsix/memory/MEMORY.md`.

**Standing facts (survive the roll):** audit cadence baseline 615 bats / next audit at 715
(now at 653) · repo at `~/projects/antcrate`, symlinked from `~/.claude/skills/antcrate`
(recovery: newest `~/.antcrate/backups/antcrate/*.tar.gz` or
`git clone https://github.com/zeppybabe/antcrate.git`, then repoint registry +
`ANTCRATE_SELFSRC` + settings.json hook paths) · push via `--pp` only ·
daily timers: antcrate-backup + antcrate-intel (both ENABLED) · Fable session budgets
soft 250k / hard 400k via `~/.antcrate/anycrate/policy.json` (only `budgets.fable`
agent-adjustable, evidence + ledger required).
