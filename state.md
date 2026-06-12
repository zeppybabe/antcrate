# AntCrate — Current State

_Last updated: 2026-06-11_

## Top of mind

**2026-06-11 (latest) — SPEC LANDED + APPROVED: Least-Cost Allocation Layer + Skill Scoping (`docs/specs/2026-06-11-least-cost-allocation-and-skill-scoping-design.md`). This build now PRECEDES AnyCrate.**

- ✅ Spec approved by user (all decisions locked): (1) **three-tier skill cut** — `antcrate` trimmed to ~1.5k-token orchestrator skill, NEW `antcrate-builder` (~1k tokens, command-surface-only, for Cody/Claudia/cody-tester; lives at `assets/skills/builder/`), `anycrate` unchanged; (2) **`cost-anticipator.sh`** predictive hook (PreToolUse Skill|Agent|Read; warn at soft, BLOCK on window/hard-budget overflow — the 264k claude-api incident becomes mechanically impossible); (3) **`policy.json` fully defined here** (models cost table + classes + budgets); orchestrator model is NEVER policy-assigned (`inherit` = user's session choice; Clyde/Cable are personas of the role); (4) **`Bash(antcrate *)` permission allowlist** — wrapper's internal gates are the safety layer, not the prompt; (5) **per-model session budgets: Fable soft 250k / hard 400k** (evidence: 2026-06-10 session >300k clean; user directive) + self-governance grant — Cable may adjust `budgets.fable` ONLY, evidence-backed, ledger-recorded; DISABLE hatches stay human-only; (6) **TH human tier** — typed duties (policy/command/research/debug), `duty_involvement` knob in config (user = `hands-on`, fresh-install default `lean`), `--fetch <url>` no-LLM web fetcher (intel normalizer reuse); research order = TH duty → `--fetch` → model research LAST.
- Absorbs proposals `model-tiers` + `skill-research-guard` and the prior session's resume target. ~40 bats estimated, 8 build steps (spec "Build order").
- **NEXT: write the implementation plan (`docs/plans/`), then build step 1 (`policy.json` + `tests/policy.bats`, test-first).** Plan-writing started this session if budget allowed; check `docs/plans/` for `2026-06-11-least-cost-*`.
- Deferred archive roll DONE this session (RESUME-QUEUE-CLEARED + PUBLIC-FACE-REVAMP blocks → state-archive.md).

**2026-06-11 (prior) — MODEL-TIER RESEARCH delivered; session ended early — claude-api skill load alone pushed context to 264k, tripping the 140k hard gate.**

- ✅ Research done (delivered in-chat; data cached 2026-06-04 from the claude-api skill, verified recent): Fable 5 = 1M ctx / 128K out / $10-$50 per MTok; Opus 4.8 = 1M / 128K / $5-$25; Sonnet 4.6 = 1M / 64K / $3-$15; Haiku 4.5 = **200K** / 64K / $1-$5. Cost ratio Haiku:Sonnet:Opus:Fable = 1:3:5:10 on both input and output. Fable tokenizer counts ~30% MORE tokens for identical content vs Opus-tier (normalize before comparing). `effort` param is NOT supported on Haiku 4.5 (so "effort high+" can't be expressed there). Cache reads ≈0.1×, writes 1.25×; spawned agents start cache-cold.
- Resume target (tiered token-limit + least-cost orchestration spec) → **DELIVERED as the 2026-06-11 spec above**; queued proposals `model-tiers` + `skill-research-guard` absorbed by it.

---

## Rolling state protocol (since 2026-06-10)

This file holds ONLY the current + immediately-prior session blocks under "Top of mind."
When a new session block lands on top, move blocks older than the prior session — verbatim,
newest-first — into `state-archive.md` (append-only, never rewrite). Decisions still go to
`ledger.md` at decision time; the archive preserves narrative context only.

Pointers: history `state-archive.md` · decisions `ledger.md` (append-only) · hard rules
`assets/code/AGENTS.md` · flag index `assets/docs/PATTERNS.md` · cross-session memory
`~/.claude/projects/-home-twntydotsix/memory/MEMORY.md`.

**Standing facts (survive the roll):** audit cadence baseline 615 bats / next audit at 715 ·
repo at `~/projects/antcrate`, symlinked from `~/.claude/skills/antcrate` (recovery: newest
`~/.antcrate/backups/antcrate/*.tar.gz` or `git clone https://github.com/zeppybabe/antcrate.git`,
then repoint registry + `ANTCRATE_SELFSRC` + settings.json hook paths) · push via `--pp` only ·
daily timers: antcrate-backup + antcrate-intel (both ENABLED).
