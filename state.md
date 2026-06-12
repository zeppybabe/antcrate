# AntCrate — Current State

_Last updated: 2026-06-12_

## Top of mind

**2026-06-12 session 2 (latest) — LIVE WATCH VIEW FIXED + activity-emitter hook live; daemon verified (enable = open user duty); tests 653 → 676. Commit f2380f5.**

- ✅ The second-terminal live view works end-to-end now: `antcrate --watch --follow` = full-screen colored tree of whatever project the agent is touching — alt-screen (no scroll spam, no flicker), height-clamped with "+N more" marker, `--follow` hops projects via new `ac_watch_hot_project`. New PostToolUse hook `activity-emitter.sh` (Edit|Write|Read|NotebookEdit, fail-open) feeds the event stream — before this, NOTHING emitted events, so the tree never lit. `--watch-window <project>` still spawns the Alacritty variant.
- ✅ Daemon (`antcrated`) verified working via direct timeout-run: live-tree regen fired ~3s after a project touch. systemctl is gateway-blocked for agents (correct), so persistent enable is an OPEN DUTY: `systemctl --user enable --now antcrated`.
- **VERIFY NEXT SESSION (carried + new):** (1) `antcrate --status` shows daemon running once the user enables it; (2) activity-emitter fires from settings on a fresh session (this session's wiring was live-smoked by hand); (3) prior session's three fresh-session checks (allowlist prompt-free `--status`, `antcrate-builder` in skill menu from cold start, cost-anticipator pipe-fire).
- Worktrees on disk, zero unique commits, cleanup = user call: `live-watch-fix`, `live-watch-docs` (this one), `least-cost-build`, `least-cost-spec`, `session-gate-duties`.
- **NEXT (queue, unchanged):** (1) AnyCrate build (consumes policy.json classes); (2) no-decision mediums: `repoint` + `recover-from-backup`, `ci-core`, `hook-internal-md-guard`, `obsidian-prune`; (3) roadmap #6 `--health` (absorb `session-telemetry`); (4) LAST: intel-report proposals. 7 unread intel items await an `/intel` pass.

**2026-06-12 session 1 (prior) — LEAST-COST LAYER SHIPPED COMPLETE: all 8 plan tasks live; Fable gate now 250k/400k; tests 615 → 653.**

- ✅ Everything in `docs/plans/2026-06-11-least-cost-allocation-and-skill-scoping.md` shipped (full detail in today's ledger entries): policy.json (`--policy`/`--policy-init`), model-aware session gate (**Fable soft 250k / hard 400k LIVE** — smoked on the wired hook), `cost-anticipator.sh` predictive hook (wired `Skill|Agent|Read`, live block verified rc2 at 399k), typed duties + `--duty-involvement` (user = hands-on), `--fetch` (real smoke vs docs.claude.com), three-tier skill cut (SKILL.md 5.2KB, `antcrate-builder` live in skill menu, LIB_MAP.md, agent pointers in cody/claudia/cody-tester), `Bash(antcrate *)` allowlist, AGENTS.md rules 20–22, PATTERNS least-cost section. Proposals `model-tiers` + `skill-research-guard` retired (absorbed); `skill-render` filed.
- Execution note: started subagent-driven per plan header; user redirected mid-build to single inline agent (session-limit pressure) — Tasks 2-fix/4/5/6/7/8 built inline by Cable. Build worktree `least-cost-build` retained (also stale: `least-cost-spec`, `session-gate-duties` — cleanup candidates, user call).
- **VERIFY NEXT SESSION (fresh-session items):** (1) `antcrate --status` runs without a permission prompt (allowlist); (2) `/` skill menu shows `antcrate-builder` from cold start; (3) cost-anticipator fires from settings (pipe-test passed; in-session fire untestable for already-loaded session).
- **NEXT (queue):** (1) AnyCrate build — consumes `policy.json` classes (spec step 1: catalog + tiers + staging, test-first); (2) no-decision mediums: `repoint` + `recover-from-backup`, `ci-core`, `hook-internal-md-guard`, `obsidian-prune`; (3) roadmap #6 `--health` (absorb `session-telemetry`); (4) LAST: intel-report proposals. 7 unread intel items still await an `/intel` pass.

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
(now at 676) · repo at `~/projects/antcrate`, symlinked from `~/.claude/skills/antcrate`
(recovery: newest `~/.antcrate/backups/antcrate/*.tar.gz` or
`git clone https://github.com/zeppybabe/antcrate.git`, then repoint registry +
`ANTCRATE_SELFSRC` + settings.json hook paths) · push via `--pp` only ·
daily timers: antcrate-backup + antcrate-intel (both ENABLED) · Fable session budgets
soft 250k / hard 400k via `~/.antcrate/anycrate/policy.json` (only `budgets.fable`
agent-adjustable, evidence + ledger required).
