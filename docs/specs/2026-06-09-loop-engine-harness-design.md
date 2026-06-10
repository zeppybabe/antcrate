# Loop Engine + Harness — Design

_Date: 2026-06-09 · Status: SHIPPED (lib/loop.sh, tests/loop.bats, bin/antcrate wiring; --ci PASS @ 480 bats)_
_Source idea: `~/Documents/PDF/Task List and How AntCrate fits in.pdf` — §3 "The Loop Discourse" + the "How AntCrate fits in" closing._
_Note: this doc was recreated after a session-limit reset destroyed the original `~/projects/antcrate` tree; the shipped code is the implementation source of truth._

## Goal

`antcrate --loop`: an objective-driven, self-verifying, hard-stopped orchestration loop that runs **unattended** (under `--dangerously-skip-permissions`) while AntCrate's own guards remain the safety floor. One loop run drives **one objective to "done"** using the existing Clyde → Cody → Claudia chain.

Sub-project **#1 of 6** (then: #2 cost/budget `--costs`, #3 token-limit auto-resume, #4 agent roles, #5 provisioning, #6 `--health`).

## Guiding principle — compose, don't duplicate

AntCrate works **with** Claude Code's native features, never rebuilds them — **except at the security boundary**, where deliberate interposition (quarantine-not-delete, backup-before-structural, canary gate) is the point. Here: Claude Code's `/loop` owns cadence; AntCrate owns durable state + stops + safety floor.

## Decisions (resolved in brainstorming)

| Fork | Decision |
|---|---|
| Tick substrate | AntCrate harness + Claude Code `/loop` + `ScheduleWakeup`. |
| Unit of work | One objective → done. Clyde is the loop body; dispatches Cody/Claudia. |
| Verify gate | **Two-key:** project CI (`--ci`) passes **AND** Claudia sign-off. |
| Stops | max-iter (default 25) · no-progress (3 ticks, same tree-sha or same error-sig) · budget (wall-clock proxy now; real $ in #2). |
| On halt | checkpoint (memory-file format) → quarantine WIP → `status=halted-<reason>` → stop. |
| State durability | `~/.antcrate/loops/<id>.json`, atomic temp+mv (delegate.sh idiom), AntCrate backup covers it. |

## Architecture (three layers, clean seams)

- **AntCrate `lib/loop.sh`** — durable harness: run-state, stop-checks, verify orchestration, checkpoint+quarantine on halt, budget interface. Pure Bash 5+, jq.
- **Claude Code `/loop` + `ScheduleWakeup`** — cadence. The `/loop` prompt is literally `antcrate --loop-tick <id>`.
- **Clyde** — the decision in the body each tick (which agent, is it done).

## Flag surface

`--loop "<obj>" --project <p> [--max-iter N] [--budget SECONDS]` · `--loop-tick <id>` · `--loop-signoff <id> <pass|fail> [note]` · `--loop-status <id> [--porcelain]` · `--loop-list` · `--loop-resume <id>` · `--loop-halt <id> [--reason r]`.

## Run-state (`~/.antcrate/loops/<id>.json`)

`id, objective, project, status, tick, max_iter, last_tree_sha, error_signature, stall_streak, signoff(none|pass|fail), budget_counter_start, budget_ceiling, checkpoint{step_completed,key_decisions,current_state,next_step}, created, updated`. `status ∈ running|done|halted-{max-iter,no-progress,budget,manual}`. The `checkpoint` block IS the doc's memory-file format → makes #3 (auto-resume) a small extension.

## One tick (`--loop-tick`) — Bash state-machine

`--loop-tick` is **Bash**: it cannot spawn Claudia. So it is the state-machine + CI runner + instruction emitter; Clyde does the agent dispatch and records Claudia's verdict via `--loop-signoff`.

1. If `status != running` → "LOOP COMPLETE — do not reschedule" (idempotent).
2. **Check stops first** (max-iter → no-progress → budget). Tripped → halt path.
3. Observe: `_ac_loop_tree_sha` (git) + `_ac_loop_run_ci` (project `--ci`, env-overridable in tests) → update stall streak via `_ac_loop_observe`.
4. `tick++`.
5. **Two-key done:** CI green AND `signoff==pass` → `status=done` → "LOOP COMPLETE".
6. Else emit Clyde instruction block + **"RESCHEDULE — call ScheduleWakeup … antcrate --loop-tick <id>"**.

## Integration with Claude Code `/loop` (the keystone)

| Concern | Owner |
|---|---|
| WHEN next tick fires (survives across turns) | CC `/loop` + `ScheduleWakeup` |
| WHAT the durable state is (stops, verify, checkpoint, quarantine) | `antcrate --loop*` |
| The decision each tick | Clyde |

**UX:** `antcrate --loop "<obj>" --project <p>` validates the safety floor, writes state, prints `/loop antcrate --loop-tick <id>` to paste. **Termination contract:** the tick prints RESCHEDULE (→ Claude calls ScheduleWakeup) or "LOOP COMPLETE — do not reschedule" (→ Claude omits it → loop ends). So AntCrate's durable hard stops *enforce* by telling Claude not to reschedule. Two modes: self-paced (`/loop antcrate --loop-tick <id>`) or interval (`/loop 10m …`).

## Safety floor (bypass-permissions ↔ Gateway Law)

The loop runs with prompts off, but: (1) it only calls AntCrate flags, so destruction routes through quarantine/backup/triage — never bare `rm`; (2) gateway-guard + canary stay armed below the loop; (3) `--loop` **refuses to start** unless the canary is armed and `gateway-guard.sh` is present (`_ac_loop_safety_floor_armed`; `ANTCRATE_LOOP_ALLOW_UNSAFE=1` bypasses for tests). **No autonomous loop without the safety floor armed.**

## Halt & resume

Halt → checkpoint + ledger append + `_ac_quarantine_capture` of WIP (sets `wip_quarantine=failed` + warns if capture fails) → `status=halted-<reason>`. `--loop-resume <id>` re-reads the checkpoint (Context-Recovery prompt), flips to running, continues. Token-limit *auto*-resume is #3.

## Testing

`tests/loop.bats` — 28 tests: state I/O + atomic write; safety-floor gate; init (well-formed/refuses-unregistered/refuses-unarmed); 3 stops; observe streak inc/reset; signoff; halt (status+ledger+quarantine, wip-failed path); tick (idempotent/stop-halts/two-key-done/CI-red-reschedule); status/list/resume/manual-halt. CI runner + git injected via env-overridable hooks so tests are pure Bash.
