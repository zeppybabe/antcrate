# Spec — Session-Budget Gate (`session-budget-guard.sh`) + User Duties (`--duty`)

**Status:** Approved for build (design confirmed 2026-06-10)
**Date:** 2026-06-10
**Deciders:** User + Cable (Fable 5)
**Roadmap position:** Roadmap #3 (token-limit auto-resume), reframed proactive. Duties surface is a
new small unit designed alongside it because the gate's wrap-up message references it.

## Context

The standing least-cost policy ("break BEFORE token limits") is pure discipline today, and
discipline already failed once (the 2026-06-09 token-reset error). The original roadmap #3 framing
was reactive — resume after hitting the limit. The user's reframe: gate the session *before*
degradation. Since state.md went rolling (2026-06-10), `/clear` + re-read state is the designed
recovery path, so the correct enforcement is: when the context window crosses a health threshold,
finish duties (commit, push, state objective), then refuse further work until the user `/clear`s.

Pattern precedent: gateway-guard (destructive ops) and env-guard (secrets) both turned model
discipline into hook-enforced law. This gate does the same for session health.

Second unit: actions only the human can perform (control-plane jq seeds, `systemctl --user enable`,
config edits under rule #13, key rotation, policy approvals) today live as prose inside state.md
bullets. They get a first-class checklist artifact, surfaced automatically so neither party relies
on memory.

**Key technical facts (verified):**
- No hook or agent can execute `/clear`; it is user-side. "Queue a /clear" therefore means
  hard-block non-wrap-up tool calls until the user clears.
- Hook payloads include `transcript_path`; the session JSONL's last assistant message carries
  `message.usage` — context size is measurable in-hook with `tail` + `jq`, no new plumbing.
- After `/clear` the new transcript measures small, so the gate passes naturally. **The measurement
  is the state — no pending-flag files, no SessionStart consumption.**

## Decision

Build two units, duties first (the gate references it):

1. `lib/duties.sh` + `duties.md` + `--duty` / `--duties` / `--duty-done` + `duties: N open` in
   `--status`.
2. `hooks/claude/session-budget-guard.sh` (PreToolUse, matcher `*`) + settings.json wiring,
   following the env-guard build pattern (TDD, `--hook-smoke`-compatible, escape hatch, fail-open).

---

## Unit 1 — duties surface (`lib/duties.sh`)

### File

`duties.md` at repo root, next to `state.md` / `ledger.md`. Versioned, human-readable markdown
checklist. Line format:

```
- [ ] 2026-06-10 — enable antcrate-intel.timer (`systemctl --user enable --now antcrate-intel.timer`) — why: agents cannot run systemd
- [x] 2026-06-10 — seed audit baseline jq one-liner (done 2026-06-10)
```

### Flags (cloned from the `propose.sh` pattern)

| flag | behavior |
|---|---|
| `--duty "<text>"` | append `- [ ] <ISO date> — <text>` to `duties.md`. Agents may call freely. |
| `--duties` | numbered list of OPEN items only (`- [ ]` lines), index = order of appearance. Exit 0 with "no open duties" when empty. |
| `--duty-done <n>` | flip the nth OPEN item to `- [x]` and append ` (done <ISO date>)`. Run by the user, or by an agent only on explicit user instruction (same convention as ledger retirements — the flip is recorded, never deleted). |

`duties.md` is append/flip only — items are never removed (quarantine-over-destruction applied to
prose). Editing item text happens via normal file edits by the user.

### Status line

`duties: N open` in `--status`, rc-guarded exactly like the `intel:` line (a failure in the duties
helper must not break `--status`).

### Seed entries (created at build time)

- Parked gh bucket policy decision (gh-publish + mirror — public-repo policy discussion).
- Decide key-rotation cadence for gh/remote credentials.
- (standing examples land here as they occur: systemd enables, `~/.antcrate/config` edits.)

---

## Unit 2 — `session-budget-guard.sh` (PreToolUse hook)

### Wiring

`hooks/claude/session-budget-guard.sh`, registered in `~/.claude/settings.json` PreToolUse with
matcher `*`. Arms at next session start. Lives beside gateway-guard / env-guard and shares
`_zones.sh` conventions where useful.

### Measurement

From the hook's stdin JSON take `transcript_path`. Tail the last ~200 lines, select the last
record carrying `message.usage`, compute:

```
context = input_tokens + cache_read_input_tokens + cache_creation_input_tokens
```

(Cumulative output is intentionally NOT counted — this measures what is *in the window*, matching
decision A: gate on context health, not spend.)

### Thresholds

| stage | default | override |
|---|---|---|
| soft | 100000 | `ANTCRATE_SESSION_SOFT` |
| hard | 140000 | `ANTCRATE_SESSION_HARD` |

Overrides live in `~/.antcrate/config` (rule #13: human-only; the hook reads, never writes).
Rationale for defaults: 200k window; wrap before quality degrades and before auto-compact ambush
territory (~150k+).

### Soft stage (soft ≤ context < hard)

Never blocks. Emits a single warning line ("session context 112k — soft limit 100k, hard 140k;
wrap up after the current task") via hook JSON `systemMessage` so both user and model see it.
Throttled: a marker file `~/.antcrate/session-gate/<session_id>.lastwarn` records the context size
at last warning; re-warn only when context has grown ≥ 10k past it. Marker dir is small state, not
user data; stale markers (> 7 days) are pruned opportunistically on hook run.

### Hard stage (context ≥ hard)

Exit 2 (block, stderr fed to the model) for every tool call EXCEPT the duty whitelist:

- **Bash** — command must anchored-match one of:
  `antcrate --commit …`, `antcrate --pp …`, `antcrate --status`, `antcrate --duties`,
  `antcrate --duty …`, `antcrate --duty-done …`, `antcrate --emit-activity …`,
  wrap-up git (read-only + staging): `git status`, `git diff …`, `git log …`, `git add …`.
  Deny-by-default: anything not matching blocks (compound/`;`/`&&` commands containing
  non-whitelisted segments block — same conservative posture as gateway-guard).
- **Edit / Write** — `file_path` basename must be one of: `state.md`, `ledger.md`,
  `state-archive.md`, `duties.md`.
- **Read / Grep / Glob** — always allowed (wrapping up requires reading).
- **Everything else** (Task/agent spawns, Web*, MCP tools, …) — blocked. No spawns at the limit.

Block message IS the wrap-up checklist (duties count embedded live via `--duties`):

```
SESSION HARD LIMIT: context 143k ≥ 140k.
Wrap up now — only wrap-up tools are allowed:
  1. commit:  antcrate --commit <project> -m "..."
  2. push:    antcrate --pp <project>
  3. state:   write the resume objective into state.md (rolling protocol)
  4. duties:  antcrate --duties  (N open — review with the user)
  5. then the USER runs /clear to start a fresh session.
```

### Safety posture

- **Fails OPEN**: missing/unreadable transcript, jq error, malformed usage → exit 0 + one warn
  line to the antcrate log. A health guard must never brick the session it guards.
- Escape hatch: `ANTCRATE_SESSION_GATE_DISABLE=1` (same law as env-guard / canary DISABLE: agents
  MUST NOT set it).
- Known accepted edge: if Claude Code auto-compacts, context drops and the gate reopens without a
  `/clear`. Accepted — compaction is native CC behavior; the gate's job is health, and a compacted
  window is below threshold by definition. The user's preference for `/clear` over compaction is
  served by gating well below the auto-compact zone.
- Performance: hook must stay fast — `tail -n 200 | jq` on one file, no registry reads, no
  subshelled antcrate invocations except the cheap `--duties` count in the hard-block message
  (rc-guarded; if it fails the message still prints without the count).

---

## Integration

- Hard-block checklist embeds the open-duties count (above).
- Session-close protocol (~/CLAUDE.md part 3) gains one line: review `antcrate --duties` with the
  user before the wrap statement.
- Proposal filed at build time: `session-telemetry` — per-session accomplishment-per-token record
  (tokens, USD, per-model split, bats delta, commits, ledger entries → `~/.antcrate/sessions.jsonl`
  + diff view). Builds with roadmap #6 `--health`. Out of scope here.
- Out of scope, noted for #6: plan-usage-window advisory (option C from design discussion).

## Testing

TDD, RED first, per house rules:

- `tests/duties.bats` (~8): append format, list indexing, done-flip idempotence, empty-file,
  status-line count, rc-guard.
- `tests/session_gate.bats` (~12): synthetic transcript fixtures (under/soft/hard contexts);
  soft warn emitted + throttle honored; hard blocks non-whitelisted Bash/Edit/Task; whitelist
  allows each wrap-up command; Edit allowed only on the four state files; fail-open on missing
  transcript / bad JSON; DISABLE hatch; compound-command deny.
- Live verification via `antcrate --hook-smoke hooks/claude/session-budget-guard.sh --command …`
  with a fixture `transcript_path` (benign payloads per the hook-smoke field note).

Expected count: 591 → ~611 bats — **crosses the 598 audit line.** Session close therefore includes
the codebase audit (AGENTS rule scan, drift scan, orphan scan, disable review) + `--ci --snapshot`
to set the new baseline.

## Build order

1. `lib/duties.sh` + tests + wrapper wiring + `--status` line.
2. `session-budget-guard.sh` + tests + settings.json wiring + `--hook-smoke` live check.
3. Seed `duties.md`, file `session-telemetry` proposal, ~/CLAUDE.md session-close line.
4. `--ci`, ledger entry, state.md roll, commit, `--pp`, codebase audit + `--ci --snapshot`.
