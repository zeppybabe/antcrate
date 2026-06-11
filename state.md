# AntCrate — Current State

_Last updated: 2026-06-11_

## Top of mind

**2026-06-11 (latest) — SESSION-BUDGET GATE + DUTIES SHIPPED AND LIVE; gate's first block was its own build session (176k). RESUME AFTER /clear:**

- ✅ Shipped + committed + wired: `lib/duties.sh` (10 bats) + wrapper flags + `duties: N open` status line; `hooks/claude/session-budget-guard.sh` (14 bats) live in settings.json PreToolUse `*` (hot-reloaded instantly). Spec + plan + ledger entries in repo. Suite expected **615** (600 verified mid-build via `--ci --source`; gate 14/14 standalone; full local `--ci` NOT yet run — gate blocked it, GitHub CI verifies on push).
- **RESUME QUEUE (fresh session, in order):** (1) full `antcrate --ci` (expect 615); (2) finish Task 6: re-run both `--hook-smoke` gate checks (low=allow rc0, high=block rc2; fixtures `/tmp/ac_gate_low.jsonl` + `_high`); (3) Task 7 seeds: `antcrate --duty` ×2 (gh public-repo policy; key-rotation cadence) + `--propose session-telemetry` (per-session accomplishment-per-token diffing, builds with #6 `--health`) + `--propose gate-whitelist-propose-ci` (wrap-up whitelist wants `--propose` + `--ci` — surfaced by first live block) + ~/CLAUDE.md part-3 duties-review line; (4) Task 8: SKILL.md lib+hooks entries, state roll to archive (the 2026-06-10-earlier block below is pending move), commit + `--pp`; (5) Task 9: codebase AUDIT (598 line crossed at 615) + `--ci --snapshot` new baseline; (6) memory updates: ~/.claude carve-out memory is STALE (settings.json write succeeded from this bg session), worktree `session-gate-duties` removable (zero unique commits — editing pen only).
- **Gate posture while resuming:** fresh transcript measures small → gate passes. Soft 100k / hard 140k; `ANTCRATE_SESSION_SOFT/HARD` overrides live in config (human-only). Agents MUST NOT set `ANTCRATE_SESSION_GATE_DISABLE`.

**2026-06-10 (prior) — INTEL TRACKER SHIPPED + two specs landed; AnyCrate (specs in `docs/specs/`) ABSORBS roadmap #4 + #5. bats 542 → 560.**

- ✅ **Two approved specs in `docs/specs/`**: `2026-06-10-anthropic-intel-tracker-design.md` + `2026-06-10-anycrate-capability-layer-design.md` (user spec'd on web; originals at `~/Documents/MD/`). **Roadmap restructure: AnyCrate absorbs #4 (agent roles → policy.json) and #5 (provisioning → catalog/acquirer); #3 token-limit auto-resume and #6 `--health` stay standalone.** 15 proposals filed (6 intel + 8 anycrate + ci-source-override).
- ✅ **Intel tracker LIVE** — `--intel-pull/-new/-ack/-status`, `lib/intel.sh` + 18 bats (TDD, RED first), Anthropic-only host allowlist enforced fail-closed in code, append-only new/acked.jsonl, `intel: N unread` in `--status`, `systemd/antcrate-intel.timer` (install.sh wired, NOT yet enabled — `systemctl --user enable --now antcrate-intel.timer`), `intel` skill at `assets/skills/intel/` symlinked into `~/.claude/skills/intel` (LOADED — verified in session skill list). Live-smoked: 7/7 real sources pulled, second pull all-unchanged. **7 unread items awaiting the first `/intel` cognition pass.**
- **AnyCrate build order (locked, after intel):** catalog+tiers+staging → `--acquire` repo-kind via `--ingest` → command pack + `--commands-install` → resolver skill → policy.json (#4 closed). **Locked security: only `trust:anthropic` auto-installs, only under `ANTCRATE_ACQUIRE_AUTO=1` (agents MUST NOT set it); everything else stages for Claudia review + human y/N; no `--stage-purge` ever.** AGENTS.md gets 3 new rules at AnyCrate build time.
- ✅ **First `/intel` pass DONE** (7/7 classified + acked, 4 proposals filed: mythos cost-table, source dedup, CC 2.1.172 nested-subagent policy, fable/mythos model tiers). ✅ **intel timer ENABLED** by user. ✅ **state.md TRIM DONE** (this file is now rolling; history → `state-archive.md`).
- **QUEUE (user-set 2026-06-10):** (1) backlog — untouched roadmaps (#3 token-limit auto-resume, #6 `--health`) + the pending proposals.log items, quick wins first; (2) AnyCrate build (spec step 1: catalog + tiers + staging, test-first); (3) LAST: integrate the intel-report proposals (the 4 above).
- ✅ **Backlog quick-win sweep DONE (bats 560 → 583):** heredoc-aware gateway-guard (+5), install.sh atomic rename-replace (+1), safety skill-zone derivation fix (+6, `tests/safety_zones.bats`), ci-baseline auto-record + `--ci --snapshot` + `--ci --source <path>` (+8, worktrees CI-able now), wrapper-dispatch exit-code pins (+3; bug found already fixed by `set -euo pipefail`). Also retired as shipped-by-other-means: `commit-loud-on-bad-flag`, `git-push-initial-mode`, `wrapper-exit-on-substep-fail`. **`audit:` line now in `--status`; `.baseline` initializes at the 598-audit via `--ci --snapshot`.**
- ✅ **`--hook-smoke` SHIPPED too (bats 583 → 591):** synthetic-payload smoke runner for Claude Code hooks; live-verified against gateway-guard (allow) + env-guard (block). Total today: bats **542 → 591**, 12 proposals shipped, 3 retired as already-fixed.
- ✅ **Retirements DONE (joint decision, replacements verified live):** 6 retired (`gateway-guard`, `shellcheck-gate`, `rule-audit`, `--audit`, `session-close`, `subagent-smoke-ping` — see ledger), 4 parked pending policy (`gh-publish`+`mirror`×3, `unnest`, `commit-patch-mode`, `drive-bundle`).
- **NEXT SESSION (after token reset, least-cost):** (1) seed audit baseline: user runs `jq '.baseline = {ts:"2026-06-09T00:00:00Z", bats:498, sha:"50b5699", branch:"master"}' ~/.antcrate/ci-baseline.json > /tmp/cb.json && mv /tmp/cb.json ~/.antcrate/ci-baseline.json` (guard blocks Cable, correctly). (2) no-decision mediums: `repoint` + `recover-from-backup` (recovery pair), `ci-core`, `hook-internal-md-guard`, `obsidian-prune`. (3) Then roadmaps #3 token-limit auto-resume + #6 `--health` (own sessions) → AnyCrate → intel-report (4).
- **STANDING POLICY (user, 2026-06-10): least-cost operation** — small turns, no speculative spawns, break BEFORE token limits (don't repeat the 2026-06-09 reset error).
- **Worktree note:** background-session edits now require worktree isolation OR `.claude/settings.json` `{"worktree":{"bgIsolation":"none"}}` (file now in repo, picked up at next session start). This session used a real git worktree + verified copy-back; `--ci` can't CI a worktree (proposal `ci-source-override`).

**2026-06-10 (earlier) — FULL SESSION QUEUE SHIPPED by Cable (Fable 5, orchestrator seat): selfcheck + audit + `--cost` + env-guard. bats 480 → 542, everything pushed.**

- ✅ **(1) Persistence insurance** — `--selfcheck [--quiet]` (`lib/selfcheck.sh`, 15 bats) + `selfsrc` line in `--status` + `systemd/antcrate-backup.timer` (ENABLED, daily).
- ✅ **(2) Codebase audit** (was due at 401) — 1 CRITICAL fixed (hooks.sh raw rm → remove-by-rename `mv` to backup), 6 minors fixed, AGENTS #16 promoted Reserved→live, loop engine CLEAN. **New baseline 498 / sha `50b5699`; next audit at 598** (~/CLAUDE.md counter updated).
- ✅ **(3) `--cost` engine** (roadmap #2 of 6) — real USD from `~/.claude/projects/` JSONL (`lib/cost.sh`, 20 bats); price table validated against USAGE ON CLAUDE.pdf to the cent; loop `--budget 5.00`/`'$5'` = dollars (integer = legacy seconds). Live: **$204 all-time local, ~$45 on 2026-06-10**.
- ✅ **(4) `env-guard.sh` rebuilt** — PreToolUse Bash+Read hook (24 bats): secret VALUES never enter the transcript; names/assignment only. Wired in settings.json (`Bash|Read`); arms at next session start.
- **Usage policy (active):** Cable builds inline (zero spawns today except the read-only auditor); Claudia only for safety-critical diffs; `/clear` between items; `--cost --porcelain --since <today>` for live spend.

---

## Rolling state protocol (since 2026-06-10)

This file holds ONLY the current + immediately-prior session blocks under "Top of mind."
When a new session block lands on top, move blocks older than the prior session — verbatim,
newest-first — into `state-archive.md` (append-only, never rewrite). Decisions still go to
`ledger.md` at decision time; the archive preserves narrative context only.

Pointers: history `state-archive.md` · decisions `ledger.md` (append-only) · hard rules
`assets/code/AGENTS.md` · flag index `assets/docs/PATTERNS.md` · cross-session memory
`~/.claude/projects/-home-twntydotsix/memory/MEMORY.md`.

**Standing facts (survive the roll):** audit cadence baseline 498 bats / next audit at 598 ·
repo at `~/projects/antcrate`, symlinked from `~/.claude/skills/antcrate` (recovery: newest
`~/.antcrate/backups/antcrate/*.tar.gz` or `git clone https://github.com/zeppybabe/antcrate.git`,
then repoint registry + `ANTCRATE_SELFSRC` + settings.json hook paths) · push via `--pp` only ·
daily timers: antcrate-backup + antcrate-intel (both ENABLED).

