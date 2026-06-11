# AntCrate — Current State

_Last updated: 2026-06-11_

## Top of mind

**2026-06-11 (latest) — RESUME QUEUE CLEARED: 615 verified, gate smoke-closed, 615-bats AUDIT done, baseline re-snapshotted.**

- ✅ All six resume items done: (1) full `--ci` PASS **615 bats**; (2) gate `--hook-smoke` checks closed (fixtures rebuilt after /tmp wipe: low 50k = allow rc0, high 176k = block rc2); (3) 2 duties filed (gh public-repo policy, key-rotation cadence — **2 open, awaiting user review**) + 2 proposals (`session-telemetry`, `gate-whitelist-propose-ci`) + ~/CLAUDE.md part-3 duties-review line; (4) SKILL.md duties+hooks entries, state rolled; (5) **AUDIT at 615**: rules CLEAN, disables justified, 2 MINOR (cmd_init config bootstrap → documented as sanctioned rule-#13 carve-out in AGENTS.md; obsidian.sh vault writes → proposal `obsidian-vault-zone-guard`), 2 DRIFT fixed (HOOK_PLAN.md status, SKILL.md "Queued" hooks); orphan scan clean. **New baseline 615 via `--ci --snapshot`; next audit at 715.** (6) memory updated: ~/.claude carve-out note corrected, worktree note below.
- **Worktree `session-gate-duties`:** still on disk, zero unique commits (editing pen; leftover files verified byte-identical to master). User can `git -C ~/projects/antcrate worktree remove .claude/worktrees/session-gate-duties --force` when no session is using it.
- **NEXT (queue unchanged from 2026-06-10):** (1) no-decision mediums: `repoint` + `recover-from-backup` (recovery pair), `ci-core`, `hook-internal-md-guard`, `obsidian-prune` (now pairs with the audit's `obsidian-vault-zone-guard`); (2) roadmap #6 `--health` (own session; absorb `session-telemetry`); (3) AnyCrate build (spec step 1: catalog + tiers + staging, test-first); (4) LAST: intel-report proposals (4). Gate whitelist tweak (`gate-whitelist-propose-ci`) is a quick-win candidate whenever the gate next bites.

**2026-06-11 (prior) — SESSION-BUDGET GATE + DUTIES SHIPPED AND LIVE; gate's first block was its own build session (176k).**

- ✅ Shipped + committed + wired: `lib/duties.sh` (10 bats) + wrapper flags + `duties: N open` status line; `hooks/claude/session-budget-guard.sh` (14 bats) live in settings.json PreToolUse `*` (hot-reloaded instantly). Spec + plan + ledger entries in repo. Dogfood event: the gate's FIRST live block was its own 176k build session — working as designed; the 2026-06-09 reset error class is now mechanically impossible.
- **Gate posture:** fresh transcript measures small → gate passes. Soft 100k / hard 140k; `ANTCRATE_SESSION_SOFT/HARD` overrides live in config (human-only). Agents MUST NOT set `ANTCRATE_SESSION_GATE_DISABLE`.
- **STANDING POLICY (user, 2026-06-10): least-cost operation** — small turns, no speculative spawns, break BEFORE token limits.

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

