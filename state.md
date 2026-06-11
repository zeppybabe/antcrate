# AntCrate — Current State

_Last updated: 2026-06-11_

## Top of mind

**2026-06-11 (latest) — PUBLIC-FACE REVAMP: README rewritten, docs/MANUAL.md shipped, PATTERNS hook-drift fixed; duties CLOSED; env-vault proposal filed.**

- ✅ Planning + presentation session (user-directed, docs only): (1) both duties closed on user decision — gh repos stay private-by-default with changes via config applying on next antcrate update; key rotation = service-default expiry, self-assigned SHA/encrypted API keys WEEKLY, HTTPS-gh until natural expiry; (2) Claude Managed Agents **vault env-var credentials** (released today) assessed — cloud provisioning layer vs our env-guard exposure layer, complementary not redundant → proposal `env-vault` (--vault-set/--vault-run/--vault-due + rotation metadata); (3) **README.md fully rewritten** (agent-governance framing, five-rule contract, capability tour, 615-bats status); (4) **NEW docs/MANUAL.md** — man-page-grade: all 88 commands, CONCEPTS, FILES, ENVIRONMENT, EXIT STATUS, SECURITY MODEL; (5) **PATTERNS.md drift fixed** (hook suite no longer "queued"; loop-engine section added; --ci row current); (6) proposal `man-page` filed (roff antcrate.1 + --man). `--ci --source` worktree PASS 615. Built in worktree `repo-revamp`.
- Intel: fresh pull landed 3 new snapshots today (news, release-notes-api, release-notes-claude-code) — **7 unread total await the next `/intel` cognition pass** (only the vault item was read, for the env-guard comparison; nothing acked).
- **NEXT (queue unchanged from 2026-06-10):** (1) no-decision mediums: `repoint` + `recover-from-backup` (recovery pair), `ci-core`, `hook-internal-md-guard`, `obsidian-prune` (pairs with `obsidian-vault-zone-guard`); (2) roadmap #6 `--health` (own session; absorb `session-telemetry`); (3) AnyCrate build (spec step 1: catalog + tiers + staging, test-first); (4) LAST: intel-report proposals (4). Quick-win candidates: `gate-whitelist-propose-ci`, `env-vault` (new), `man-page` (new).

**2026-06-11 (prior) — RESUME QUEUE CLEARED: 615 verified, gate smoke-closed, 615-bats AUDIT done, baseline re-snapshotted.**

- ✅ All six resume items done: (1) full `--ci` PASS **615 bats**; (2) gate `--hook-smoke` checks closed (fixtures rebuilt after /tmp wipe: low 50k = allow rc0, high 176k = block rc2); (3) 2 duties filed (gh public-repo policy, key-rotation cadence) + 2 proposals (`session-telemetry`, `gate-whitelist-propose-ci`) + ~/CLAUDE.md part-3 duties-review line; (4) SKILL.md duties+hooks entries, state rolled; (5) **AUDIT at 615**: rules CLEAN, disables justified, 2 MINOR (cmd_init config bootstrap → documented as sanctioned rule-#13 carve-out in AGENTS.md; obsidian.sh vault writes → proposal `obsidian-vault-zone-guard`), 2 DRIFT fixed (HOOK_PLAN.md status, SKILL.md "Queued" hooks); orphan scan clean. **New baseline 615 via `--ci --snapshot`; next audit at 715.** (6) memory updated: ~/.claude carve-out note corrected, worktree note below.
- **Worktree `session-gate-duties`:** still on disk, zero unique commits (editing pen; leftover files verified byte-identical to master). User can `git -C ~/projects/antcrate worktree remove .claude/worktrees/session-gate-duties --force` when no session is using it.

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
