# AntCrate — Current State

_Last updated: 2026-05-27_

## Top of mind

**Session-Close Protocol active (codified in `~/CLAUDE.md` on 2026-05-11).** Three parts: command-sweep, codebase audit every +100 bats tests since last baseline, end-of-session learning. **Audit baseline: 301 bats / shellcheck clean / sha `80385c3`. Next audit due at 401 bats tests** (or when `--audit` itself ships).

**Wave 1 compaction canary SHIPPED (2026-05-26/27 session):** first real C++ workload landed in `antcrate-core`. Bundled commit `271d2a3` + auto-commit diagram regen `c88cbe5`, origin/master synced. **Test count: bats 341 → 353 (+12), doctest 2 → 17 (+15). Total surface +27 tests.** Same session also shipped the quickwins trio earlier (see "Earlier (2026-05-26 morning)" below).

- **`antcrate-core canary {init,verify,gate-check,status}`** — POSIX.1-2024 C++17 helper. Token gen via `/dev/urandom` (16 bytes → 32 hex), atomic state I/O via temp+rename at `~/.antcrate/canary/state.json`, freshness check uses `>=` for TTL so TTL=0 means "stale on next check." `cmd_gate_check` increments invocations counter BEFORE checking (so max=1 → first gate-check is stale, semantically "every gate-check costs one slot"). Runtime env-var overrides: `ANTCRATE_CANARY_TTL_SECONDS` / `MAX_INVOCATIONS` take precedence over state-stored values for the freshness check (lets users tighten without re-init).
- **nlohmann/json v3.11.3 vendored** at `core/include/json.hpp` (~900 KB, MIT). Builds clean under `-Wall -Wextra -Wpedantic -Werror`. State.json schema_version=1.
- **`lib/canary.sh`** — Bash wrapper for the four C++ subcommands + the framed UX (`COMPACTION CANARY GATE` box) on stale gate. `ac_canary_init` reads env defaults if no `--ttl-seconds`/`--max-invocations` flag passed. `ac_canary_patch_claudemd` does in-place sed substitution of `__CANARY_TOKEN__` in `$ANTCRATE_CLAUDEMD` (default `~/CLAUDE.md`), interactive preview-diff + y/N prompt (Gateway-Law honored).
- **`lib/safety.sh` integration** — single 5-line insert at the top of `ac_safety_guard_destructive` gates every destructive op in one shot (rename/archive/unarchive/remove/cleanup/ingest/subbranch). Opt-out via `ANTCRATE_CANARY_DISABLE=1` (CI/test only — AGENTS.md rule #15 forbids agents from flipping it).
- **bin/antcrate** — 4 new flags: `--canary-init [--ttl-seconds N] [--max-invocations N] [--with-claudemd]`, `--canary-verify <TOKEN>`, `--canary-status`, `--canary-gate-check` (debug aid).
- **Bats sweep** — added `export ANTCRATE_CANARY_DISABLE=1` to every `setup()` in all 29 existing bats files so destructive-op tests stay green by default.
- **AGENTS.md rule #15** — canary is non-bypassable; agents MUST re-read on gate, MUST NOT mutate state.json / flip DISABLE outside CI / call `canary verify` to short-circuit re-read.

**Agent-orchestrator fourth end-to-end run (2026-05-26/27 Wave 1):**

- **Plan agent** produced a 2500-word coherent spec (C++ + Bash + tests + docs + 6 open questions + headline-metrics format). User pre-confirmed two key decisions via AskUserQuestion: nlohmann/json vendored + `--with-claudemd` opt-in (other 4 questions took recommended defaults).
- **Cody invocation** hit a session limit mid-run; ALL 6 new files + 9 modified files were already on disk when the limit fired (bats sweep complete, C++ + Bash + tests all written). Cody never delivered a report. Clyde resumed verification on the partial state.
- **Cody's drift is now FOUR-of-FOUR** (2026-05-14, 2026-05-25, 2026-05-26 trio, 2026-05-26/27 canary). With the session-limit-interrupted run, Cody never even attempted the report — but the deliverables themselves were sound. Clyde verification stays the only reliable feedback path.
- **Clyde caught FOUR real bugs in Cody's output** during verify:
  1. `tests/canary.bats::run_canary` helper used `bash -c '... '"$@"'` interpolation which splits multi-arg invocations across bash positional args, breaking the heredoc on any verify-with-token call. Fixed: rewritten as direct `"$WRAPPER" "$@"` call (env vars already exported by setup).
  2. `lib/canary.sh::ac_canary_init` documented `ANTCRATE_CANARY_TTL_SECONDS` / `MAX_INVOCATIONS` env vars but didn't pass them through to the C++ init. Fixed: added env-default fallback before constructing `--ttl-seconds`/`--max-invocations` args.
  3. `core/src/canary.cpp::is_fresh` used strict `>` for TTL comparison; with TTL=0 + same-second check, returned fresh (wrong). Fixed: changed to `>=`.
  4. `core/src/canary.cpp::cmd_gate_check` read state-stored TTL/MAX only, ignored env-var overrides. Fixed: env vars now override state values at runtime for the freshness check.
- **Docs missing from Cody's run:** AGENTS.md rule #15, PATTERNS.md "## Safety canary" section, SKILL.md `canary.sh`/`core/` entries — Clyde added all three post-Cody.
- **End-to-end live smoke confirmed:** registered project + canary init + `--rename` with `ANTCRATE_CANARY_TTL_SECONDS=0` → framed gate UX printed, rename refused with `error [wrapper] safety: refusing rename to '<new>' — compaction canary gate failed`.
- **Pre-existing bug surfaced via smoke:** `bin/antcrate` multi-step dispatch (rename → diagrams_auto_regen → lifecycle_treatment) ignores return codes; if the first step fails, the script's exit code is the last step's, masking the gate refusal. Filed proposal `wrapper-exit-on-substep-fail`. NOT fixed in Wave 1 (out of scope) but worth a quick follow-up since silent failure on a refused destructive op is the worst case for a safety gate.

**Resume next session at one of (user's choice — multiple parallel tracks):**

- **Optional follow-up: patch `~/CLAUDE.md` with the canary section.** Run `antcrate --canary-init --with-claudemd` interactively; preview the diff; type `y` to substitute `__CANARY_TOKEN__` in the user's home CLAUDE.md. This is Gateway-Law gated (user's home file) so Clyde+user decision, not agent-auto. ~5min.
- **C++ migration Wave 1 continued** — remaining 4 wrapper guards: `--no-verify` strip via outer PATH-shim (Cat 7), `$HOME`-expansion detect on `rm` (Cat 1.2), compound-command splitter (Cat 10.2), bulk-delete count gate (Cat 1.4). Each can ride the canary's infrastructure (lib/canary.sh pattern + C++ subcommand pattern). ~2-3hr each.
- **`wrapper-exit-on-substep-fail`** — quick fix (~30min) for the multi-step dispatch silent-failure bug. High UX/safety value.
- **`--gh-publish`** — composite flag from 2026-05-25 proposal. ~90min.
- **`--ci-snapshot`** — automate audit cadence. ~60min.
- **`--audit`** — programmatic codebase audit. Medium-large pass.
- **`--ci-core`** — scoped --ci skipping bats for C++ iteration.
- **Composite pre-commit umbrella** — last item on `HOOK_PLAN.md`. ~2hr.
- **`commit-loud-on-bad-flag`** — quick UX win from 2026-05-26 trio session.

---

## Earlier (2026-05-26 morning) — Quickwins trio shipped

**Quickwins trio shipped (2026-05-26):** three antcrate flags landed in one bundled commit (`164d9df`), pushed cleanly (origin/master `7136b72` with auto-commit diagram regen). Test count 316 → 341 (+25 tests, all bats green, shellcheck clean). System wrapper at `~/.local/bin/antcrate` auto-refreshed mid-session via the new `--install-from-source`.

- **`--install-from-source`** — resolves antcrate skill path via registry, runs install.sh from there. Probes BOTH `<path>/install.sh` AND `<path>/assets/code/install.sh`. Live smoke caught the layout assumption between Cody-impl and commit.
- **`--watch-smoke`** — emit synthetic event + render-once in one call. Pre-validates project registration via `ac_registry_has` BEFORE emit (caught by simplify self-review).
- **`--watch-window`** — spawn `antcrate --watch <project>` in detached Alacritty window. PID-file-gated dedup (tracks terminal PID — user-meaningful "one window per project" entity). Validates antcrate binary resolution before spawn (also caught by simplify).

Cody's report-back drifted for the THIRD time. Pattern confirmed (and now confirmed FOUR times with Wave 1). Lesson: agent-spec verification against actual on-disk reality is a SEPARATE gate from spec-verification — pass both before commit. Filed propose: `commit-loud-on-bad-flag`.

---

## Earlier (2026-05-25) — Public-release flip: zeppybabe/antcrate is now PUBLIC

**Public-release flip landed (2026-05-25):** `zeppybabe/antcrate` is now **PUBLIC** on GitHub — https://github.com/zeppybabe/antcrate. MIT license recognized, description set ("Bash, jq, and inotify. One controllable surface for solo-developer project ops."), 10 topics added (bash, cli, jq, inotify, scaffolding, devops, project-management, agent-orchestration, ci, mit-license). Repo metadata polished, README rewritten for a public landing page (937 words, 12 anchor flags across 4 buckets, no badges, no emojis), SECURITY.md + CONTRIBUTING.md shipped. Five literal `/home/twntydotsix/` references sanitized to `~/`-prefixed forms; tracked-file grep for that path now returns zero hits.

**Agent-orchestrator second end-to-end run (2026-05-25 session):**

- **Three Explore-agent invocations** (one for the public-readiness audit producing a 7-bucket punch list with "SAFE TO FLIP" verdict + 2 minor cleanups; one for the full 69-flag command-surface inventory used as Plan input; one Plan agent for the 935-word README outline with anchor-flag cut list and Cody pitfalls). All three returned usable structured output in single shot.
- **One Cody invocation** for the four deliverables (LICENSE, README rewrite, SECURITY.md, CONTRIBUTING.md, path sanitization). Cody self-invoked `simplify` mid-task; removed one redundant phrase from README's Contributing teaser ("state.md Top of mind alignment" duplicated detail already in CONTRIBUTING.md).
- **Cody's "lead-with-headline" report-back drifted again.** Returned with the simplify findings as the lead paragraph instead of the explicit headline metrics. Same pattern as 2026-05-14. **Carry forward:** Cody's report format may need an enforcement mechanism (lint? checksum on the first paragraph?) rather than just a brief clause. Filed mentally; not a proposal yet. (Confirmed again 2026-05-26 — third occurrence.)
- **Two file-level commits** (`7ee2de0` catch-up + `a024771` public-prep), one auto-commit sync (`249a2a2`). Bundle split worked cleanly via `antcrate --commit antcrate -- <files...>` — file-level `--` argument list works in practice.
- **`--gh-publish` proposed.** Three `gh repo edit` + one `gh repo view` calls became the catalyst.

---

## Earlier (2026-05-14) — C++ migration Wave 0 + agent-orchestrator first run

**C++ migration Wave 0 landed + agent-orchestrator architecture first run (2026-05-14):**

- **Architecture shift in effect from this date.** Clyde (me) orchestrates and writes no code; Cody + named agents (Explore, Plan, general-purpose) do all building; max 5 concurrent. First end-to-end test of the multi-agent build model. Full design at `~/.claude/plans/sunny-strolling-book.md`. Wrapper-guard contract source: `~/Documents/PDF/File for Clyde, AntCrate.pdf` (12-category agent-failure taxonomy, ~30 `<wrapper>` fallback specs).
- **Migration shape: staged hybrid (locked).** Bash CLI surface stays as user-facing entry; new C++ helper binary `antcrate-core` (POSIX.1-2024, C++17, `-Wall -Wextra -Wpedantic -Werror`, `_POSIX_C_SOURCE=200809L _XOPEN_SOURCE=700`, doctest vendored at v2.4.11) takes wrapper-guard contracts, registry I/O, deep traversal, gap-fill guards. Full rewrite rejected — the 316-bats safety net is too expensive to recreate.
- **Wave 0 deliverables (this session, ~PASS):**
    - Backup: `antcrate --backup antcrate` → `~/.antcrate/backups/antcrate/antcrate-20260514T194402Z.tar.gz` (808 files, 2.3 MB, manifest sidecar). Eat-dogfood pass clean.
    - C++ scaffold: `assets/code/core/` — `CMakeLists.txt`, `src/main.cpp` (29-line `--version`/`--help` stub), `include/.gitkeep`, `tests/CMakeLists.txt`, `tests/test_smoke.cpp` (2 doctest cases), `tests/doctest/doctest.h` (fetched from upstream, fallback harness not needed), `README.md`.
    - `--ci` extended: cmake build + ctest now runs between shellcheck and bats. Implementation lives in `lib/devops.sh` (Cody's defensible architectural call — bin dispatches, libs implement, though brief specified `bin/antcrate`). Missing-toolchain branch skips with a log line; bats remains source of truth until Wave 1.
    - CI workflow updated: `.github/workflows/ci.yml` installs `cmake` + `g++`; new "Build & test antcrate-core" step before `antcrate --ci`. (Untested on GH Actions until next push.)
    - Local `bash bin/antcrate --ci` exits `=== ci result: PASS ===` with shellcheck clean + cmake+ctest 1/1 + 316/316 bats.
    - **Same-session evening (2026-05-14):** Catch-up shipped to origin/master as two feature-boundary commits — `512c356 feat(watch): anchor-on-latest` + `52ac50d feat(core): Wave 0 scaffold` (plus `a4175a3` antcrate auto-sync). Cody-authored `cpp-check` skill at `~/.claude/skills/cpp-check/` (SKILL.md + POSIX-`sh` run.sh + .cppcheck-suppressions) plus `.clang-tidy` config at `assets/code/core/.clang-tidy`. `cody.md` updated with three sections at lines 56/60/64: `cpp-check` in "When appropriate" skills list; "Report back format" template addressing Wave 0 summary-discipline drift; "C++ workflow guidance" describing the tight cmake→ctest→cpp-check loop. `--ci-core` proposal filed (token-efficient C++-only iteration). The harness's available-skills list now includes `cpp-check` (frontmatter validates at runtime).
- **Multi-agent orchestration observations from this first run (carry forward):**
    - **Cody's summary discipline drifted.** Returned with "three fixes applied" minutiae instead of leading with the headline (Wave 0 done? --ci green? what files?). Clyde had to re-inspect git status, run --ci, and check diffs to confirm completion. Future briefs to Cody must include an explicit "Report back: lead with headline metrics" clause. The orchestration model only delivers efficiency if the builder's summary is trustworthy at face value.
    - **Explore-agent in-flight inventory drifted.** First Explore claimed in-flight files were `bin/antcrate, lib/hooks.sh, tests/hooks.bats, HOOK_PLAN.md`; live `git status` showed `lib/devops.sh, lib/watch.sh, tests/watch.bats` (the 2026-05-11 anchor-on-latest work, still pending --pp). Lesson: when delegating "what's in-flight" questions, the agent must read `git status` directly, not infer from recent ledger/state passes.
    - **Cody routing `--ci` cmake/ctest into `lib/devops.sh` rather than `bin/antcrate`** is correct (dispatch vs implementation) but deviated from the brief. Future pattern: name the *behavior* and let Cody pick the file when the architecture is obvious; pin the exact file when it matters.
    - **Step-0 backup re-routed from Cody to Clyde mid-flight.** User's original answer queued Cody for `antcrate --backup antcrate`, but Cody's published scope excludes `~/.antcrate/` ops. Surfaced the conflict via AskUserQuestion, re-routed to Clyde. Lesson: agent-definition scope boundaries are guardrails — surface the conflict, don't silently override.

**Resume next session at one of (user's choice — multiple parallel tracks now):**

- **C++ migration Wave 1** — wrapper guards. Compaction canary first (Cat 4 of the PDF, the most structurally-Bash-impossible guard); then `--no-verify` strip via outer PATH-shim (Cat 7); then `$HOME`-expansion detect on `rm` (Cat 1.2); then compound-command splitter (Cat 10.2); then bulk-delete count gate (Cat 1.4). Pre-implementation design pass via Plan agent.
- **--watch-window** — queued before C++ pivot, still valid. Spawn-wrapper around `antcrate --watch <project>` in detached Alacritty with PID file dedup. ~60min.
- **Other queued (pre-existing, unaffected by C++ migration):** --ci-snapshot, --watch-smoke, --audit, --install-from-source, composite pre-commit umbrella, plus the new `--ci-core` proposal filed 2026-05-14 evening (scoped `--ci` skipping bats for C++ iteration).

---

## Earlier (2026-05-11, twenty-third pass) — `--watch` anchor-on-latest landed

**`--watch` anchor-on-latest landed (2026-05-11, twenty-third pass):**

- Symptom: user observed `antcrate --watch antcrate` "looped infinitely on the entire current project, instead of staying fixated on the current path that is being worked on." Root cause: `ac_watch_render_once` always walks the whole tree from project root (depth 8 by default), and active events only changed *coloring*, not *scope* — so the hot path scrolled off the viewport in any project bigger than a screenful.
- Fix shape (in `lib/watch.sh`): new `ac_watch_latest_event <project>` helper returns the max-`ts_ms` active event as `<ts_ms>\t<kind>\t<path>`. `ac_watch_render_once` pins a header line `▶ <path>   ← latest <kind>` (kind-colored) above the project root, with a blank-line separator. `ac_watch_walk_tree` now accepts an optional `latest_path` arg and appends `   ●` to the row whose `rel` matches — so the eye gets a pin in the tree even when the tree below scrolls.
- Why this had to land **before** `--watch-window`: the proposal is just a spawn-wrapper around `antcrate --watch <project>`. Shipping the wrapper without the anchor would relocate the symptom to a new window, not fix it.
- Live-smoke pattern: `antcrate --emit-activity antcrate modify composes.md --ttl-ms 60000 && antcrate --watch antcrate --once --no-color --depth 2`. Confirmed header pins composes.md and the in-tree row shows `composes.md   ●`. **Filed `--watch-smoke` proposal** to collapse the emit+render-once pair into one call.
- Printf gotcha worth carrying forward: **`%s` does NOT interpret `\x` escapes; only the format string does.** First attempt put `"\xe2\x96\xb6 "` as a `%s` argument and would have rendered the literal backslash-x-bytes instead of the unicode arrow. Caught before tests by re-reading the change. Carry forward to any future ANSI/UTF-8 work.

Test count 312 → 316 (4 new in `tests/watch.bats`: no-events → no header, single-event header, in-tree marker, most-recent-wins). Full `--ci` PASS (shellcheck clean, bats 316/316). `install.sh` re-run so the system wrapper at `~/.local/bin/antcrate` picks up the lib change.

**Resume next session here:**
- **`--watch-window`** — now safe to ship. ~60min. PID file at `~/.antcrate/watch/<project>.pid`, spawn-or-warn on duplicate, Alacritty-first via `--class ac-watch-<project>`.
- **Commit the now-FIVE-session catch-up** via `antcrate --pp antcrate -y` (`--hook-remove`, `--hook-debug`, `--hook-bypass`, `--hook-audit`, today's `--watch` anchor). Five feature-boundary commits.
- **`--ci-snapshot`** (persist baseline after `--ci` PASS, surface "+N since last snapshot" in `--status`). Last of the three easy-proposal trio.
- **`--watch-smoke`** filed today — emit + render-once in one call. Quick win that pairs with --watch-window since smoke verification will recur.
- **`--audit`** — programmatic codebase audit; medium-large, focused pass.
- **`--install-from-source`** — auto-fire `install.sh` after commits to the antcrate project so the system wrapper never goes stale. Filed earlier.
- **Composite pre-commit umbrella** — last item on `HOOK_PLAN.md`. ~2hr.
- **dlg_smoke + hookrm_smoke registry entries** — `/tmp` is outside safety zones; surface to user before next big pass.
- **Stale tickets to re-check:** #69 lib-header propagation, #76 `--mirror`, #78 three-tier agent context model, #79 AGENTS.md #15 private-by-default, #84 `--init`, #85 `--env-setup`.

---

## Earlier (this same session) — `--hook-audit` shipped + live-tree window pattern validated (twenty-second pass)

**`--hook-audit` shipped + live-tree window pattern validated (2026-05-11, twenty-second pass):**

- `antcrate --hook-audit <project> [N]` — three-section unified view of the global JSONL (jq-filtered to project), per-project audit plain log, and human-readable hook tail. Default N=20 lines per sink. Read-only. Each missing sink prints a friendly "no entries" notice instead of erroring.
- **Live-tree separate-window workflow validated.** Before delegating, Clyde spawned a detached Alacritty window via `setsid alacritty --class ac-watch-<project> --title "..." -e bash -lc 'antcrate --watch <project>' >/dev/null 2>&1 < /dev/null & disown`. The watch process runs independently of Claude's shell. `--class` is the Wayland-friendly grouping handle since `decorations = "None"` hides the title bar. The antcrate project lives outside the daemon's `~/projects/` watch root so paint events don't fire for THIS project — but the spawn-and-detach pattern is proven and will paint live for `~/projects/`-resident projects with the daemon running.
- **`--watch-window` flag filed as a proposal** to codify the pattern: PID file at `~/.antcrate/watch/<project>.pid`, re-invocation detects live PID and exits 0 ("already watching pid N") instead of duplicate-spawning. Wayland-first since `wmctrl` is X11-only.
- **Bashrc/profile cleanup landed this same session** (user-side dotfiles, not in repo; backups at `~/.bashrc.bak.20260511T222220Z`, `~/.profile.bak.<same>`). Fixed: dead-code PS1 override, triple `MICRO_TRUECOLOR=1`, duplicate `MOZ_ENABLE_WAYLAND=1`, missing `alacritty*)` arm on window-title block, double-prepended PATH, hex-case inconsistency in alacritty.toml.

Test count 307 → 312 (5 new in `tests/hooks.bats`). Full `--ci` PASS (shellcheck clean, bats 312/312).

**Resume next session here:**
- **`--watch-window`** — ship the proposal filed today. ~60min. Pairs with the dotfile cleanup that just landed.
- **`--ci-snapshot`** (persist baseline after `--ci` PASS, surface "+N since last snapshot" in `--status`). Last of the three easy-proposal trio.
- **`--audit`** — programmatic codebase audit; medium-large, focused pass.
- **`--install-from-source`** — auto-fire `install.sh` after commits to the antcrate project so the system wrapper never goes stale. Filed earlier this session.
- **Composite pre-commit umbrella** — last item on `HOOK_PLAN.md`. ~2hr.
- **dlg_smoke + hookrm_smoke registry entries** — `/tmp` is outside safety zones; surface to user before next big pass.
- **Stale tickets to re-check:** #69 lib-header propagation, #76 `--mirror`, #78 three-tier agent context model, #79 AGENTS.md #15 private-by-default, #84 `--init`, #85 `--env-setup`.

---

## Earlier (this same session) — `--hook-render` shipped (twenty-first pass)

**`--hook-render` shipped (2026-05-11, twenty-first pass — first easy-proposal pass):**

- `antcrate --hook-render <template> [project]` — renders a hook template to stdout (read-only, no install). Exposes the existing `_ac_hook_render` private helper as a public command. `project` defaults to `EXAMPLE_PROJECT` so a preview doesn't require a registered project. Unknown template errors with the available-templates listing.
- **End-to-end Clyde→Cody delegation dogfood.** Clyde ran `antcrate --delegate antcrate --key hook-render --task "..."` (attempt 1/3); handoff block produced; spawned the `cody` subagent with the spec. Cody returned with shellcheck clean + 6 new bats tests, plus a `simplify` self-review. Clyde verified the diff, ran `--ci` independently, ran `install.sh` to sync the system wrapper, and live-smoked three paths.
- **Re-install gotcha worth flagging.** `~/.local/bin/antcrate` is the installed copy; the source tree wrapper is at `assets/code/bin/antcrate`. After adding a new flag, `install.sh` must run before the system PATH wrapper picks it up. Candidate for an `--install-from-source` shortcut. Logged for future propose-sweep.
- **AGENTS.md / Gateway Law observation:** the agent-layer delegation flow worked end-to-end — `--delegate` logged the attempt, the subagent stayed in-project, returned a structured report. No three-attempt-rule trip. Good signal that the layer is operationally solid for routine "expose this helper as a flag" tasks.

Test count 301 → 307 (6 new in `tests/hooks.bats`). Full `--ci` PASS (shellcheck clean, bats 307/307).

---

## Earlier (this same session) — `--hook-bypass` shipped (twentieth pass)

**`--hook-bypass` shipped (2026-05-11, twentieth pass):** queued hook surface is now feature-complete except for the composite pre-commit umbrella. Same-night double pass with `--hook-debug` (nineteenth, earlier this session).

- `antcrate --hook-bypass <project> --reason "<text>"` — writes `.git/antcrate-hook-bypass` as a JSON flag (`{ts, reason, project}`). The next antcrate-shipped hook to fire reads the flag, logs the bypass + reason to both `.git/antcrate-hook.log` (human tail) and `.git/antcrate-hook-audit.log` (per-project audit), deletes the flag (single-shot), exits 0.
- `--reason` is **mandatory** — a reason-less bypass defeats the audit invariant and is refused before any flag is written.
- **No silent overwrite.** If `.git/antcrate-hook-bypass` is already present (a prior bypass that hasn't been consumed), `--hook-bypass` refuses with exit 1 + an instruction to consume it (run a commit) or `rm` deliberately.
- **Shared snippet via marker.** Every antcrate-shipped pre-commit/pre-push template carries a `# __ANTCRATE_BYPASS_CHECK__` marker. `_ac_hook_render` replaces the marker at install time with a canonical ~13-line bypass-check block. Templates that don't include the marker (e.g. a future `commit-msg-format`) pass through unchanged — appropriate when bypass doesn't apply.
- **awk ENVIRON, not `-v`.** First render attempt passed the snippet via `awk -v block="$snippet"`, which mangled `\n` inside the snippet's printf format strings into actual newlines (gawk: "escape sequences in val are interpreted"). Switched to `ENVIRON["AC_HOOK_BYPASS_SNIPPET"]` which is byte-for-byte. Live render verification before tests would have caught this; I caught it via test failure.
- **AGENTS.md rule #14 added.** Hook bypass is a logged, single-shot, human-only action. Agents MAY propose; humans run. Agents MUST NOT call `--hook-bypass` directly, MUST NOT create the flag by hand, MUST NOT use `git commit --no-verify`. Also: agents MUST NOT delete a stale flag — discarding a queued sanctioned bypass is itself a human-only action.
- **Audit fan-out is three writes per bypass life-cycle:** wrapper-side row at write time (global JSONL + per-project audit), then hook-side rows at consume time (`.git/antcrate-hook.log` + per-project audit). The wrapper's `backup` field overloads to `reason:<text>` (same overload pattern as hook-debug's `stash:<label>`).

Test count 293 → 301 (8 new in `tests/hooks.bats`). Full `--ci` PASS (shellcheck clean, bats 301/301). Live smoked end-to-end against the `antcrate` project: install pre-commit-secrets → write bypass with reason → run hook from repo root (`cd ~/.claude/skills/antcrate && bash .git/hooks/pre-commit`) → exit 0 → flag consumed → all three audit sinks populated as expected → hook removed via `--hook-remove`.

**Non-obvious decisions worth remembering:**

- **awk `-v` interprets escapes; awk `ENVIRON` does not.** This is the fix worth carrying forward to any future template-injection work.
- **Marker placement matters.** The marker sits right after `set -euo pipefail` so the bypass-check runs *before* any of the hook's logic. If the marker were further down, a failing check could short-circuit and the bypass would never fire.
- **Reason in `backup` field, not a new column.** Same overload pattern as hook-debug. Keeps the JSONL schema stable; consumers branch on `action` to interpret `backup` (`hook-remove` → backup path, `hook-debug` → `stash:<label>`, `hook-bypass` → `reason:<text>`).
- **Snippet uses `git rev-parse --git-dir`, not a hardcoded `.git`.** Honors `GIT_DIR` env, works inside worktrees, works when the hook is invoked by git from any subdirectory.
- **Snippet's jq path has a tr fallback.** A user who manually wrote a bare string to the flag (not JSON) still gets a clean consume — the snippet falls back to `tr '\n' ' '` and uses the file contents as the reason. Tested.
- **Run hooks from repo root cwd in tests.** Pre-commit hooks rely on cwd for `git diff --cached` and (in our case) `git rev-parse --git-dir`. Added `run_hook_from_repo` helper to `tests/hooks.bats`; tests that exercise the rendered hook use it.
- **Three sessions of work still uncommitted.** 2026-05-10 (`--hook-remove`), 2026-05-11 (`--hook-debug`), and 2026-05-11 (`--hook-bypass`) are all sitting in the working tree as M files. Next action is to commit + push via `antcrate --pp antcrate -y`.

**Resume next session here:**
- **Commit + push the three-session catch-up** (`--hook-remove`, `--hook-debug`, `--hook-bypass`) via `antcrate --pp antcrate -y`. Recommend three commits along feature boundaries.
- **Composite pre-commit umbrella** — lift the Phase-1 single-slot constraint so `--hook-autoinstall` can install multiple stack checks side-by-side. ~2hr. This is the last item on `HOOK_PLAN.md`.
- **dlg_smoke + hookrm_smoke registry entries** — surface to user before next big pass; `/tmp` is outside safety zones so `--remove` correctly refuses (rule #1, joint decision per Gateway Law).
- **Stale tickets to re-check status on:** #69 lib-header propagation, #76 `--mirror`, #78 three-tier agent context model, #79 AGENTS.md #15 private-by-default, #84 `--init` (folds /init into antcrate), #85 `--env-setup`, #86 AGENTS.md #14 AI-action denylist (now superseded — #14 is the hook-bypass rule).

---

## Earlier (this same session) — `--hook-debug` shipped (nineteenth pass)

**`--hook-debug` shipped (2026-05-11, nineteenth pass):** highest daily-UX HOOK_PLAN follow-up landed. Second-to-last queued hook surface; only `--hook-bypass` + the composite pre-commit umbrella remain.

- `antcrate --hook-debug <project> [hook] [--with-stash] [--no-trace]` — re-runs the named hook (default `pre-commit`) with annotated, source-coord-prefixed trace, then prints captured stdout / stderr separately. Exits with the hook's exit code so scripts/agents can branch on it.
- Trace strategy: `BASH_XTRACEFD` pinned to a dedicated fd so `bash -x` output lives in its own stream; the hook's real stdout and stderr never get mixed with xtrace noise. `PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '` so every trace line carries `<file>:<line>` coords.
- `--with-stash`: `git stash push --keep-index --include-untracked` before, pop after. Hook sees exactly the staged set a real commit would use. Detection is via stash-list-count delta (push returns 0 even when nothing's saved). Pop conflicts (overlapping staged+unstaged edits on the same file) leave the stash in place and emit a `[warn]` line.
- `--no-trace`: skip xtrace entirely for hooks that are already verbose.
- Audit: reuses `_ac_hooks_audit_append` with `action: "hook-debug"`. sha256 captures the hook file's content; the `backup` field carries `stash:antcrate-hook-debug-<UTC-ts>` when `--with-stash` created one. Also appends a labeled block to `<project>/.git/antcrate-hook.log` so `--hook-log` surfaces debug runs alongside real commit-time runs.

Test count 278 → 293 (15 new in `tests/hooks.bats`, includes the SIGPIPE regression below). Full `--ci` PASS (shellcheck clean, bats 293/293). Live smoke against the `antcrate` project itself: header → trace → stdout sections, audit visible in all three sinks, `--no-trace` + `--with-stash` (clean + piped-to-head) all verified.

**Non-obvious decisions worth remembering:**

- **SIGPIPE caught early via live smoke.** First smoke iteration piped `--hook-debug --with-stash` output through `| head -14`. The closed pipe SIGPIPE'd a mid-trace `printf`, `set -e` / `pipefail` from the wrapper aborted the function **before** `git stash pop`, and the entire WIP (yesterday's `--hook-remove` work plus tonight's `--hook-debug` work) ended up stranded in `stash@{0}`. Recovered via `git stash apply` (apply succeeded on retry; pop had failed under SIGPIPE). Fix: cleanup (stash pop + audit-log append + `.git/antcrate-hook.log` append) runs in a **file-only** section before any pipe-sensitive prints; all subsequent prints live in `( ... ) || true` subshells so SIGPIPE only kills the subshell. Regression test (`hook_debug: --with-stash pops even when downstream pipe closes early (SIGPIPE)`) drives the function under wrapper-equivalent `set -euo pipefail` and confirms post-pop stash count and audit row.
- **Pop ordering matters.** The original layout printed everything in sequence (header → run → trace → stdout → stderr → exit → pop → audit). After the SIGPIPE fix the contract is: header (subshell) → run (writes to files only) → pop (no pipe writes) → audit (file writes) → render (subshell) → final log. Live UX trade-off: the header still prints immediately so the user sees "stash pushed" right away, but the trace/stdout block comes after pop. Since re-runs are typically sub-second this is invisible.
- **Pop-failure warning is in stdout, not `ac_warn`.** `ANTCRATE_LOG_LEVEL=error` (the bats default) would suppress `ac_warn`. A stash-preservation notice is critical regardless of log level, so it's a direct `printf '[warn] ...'` in the render block.
- **`backup` field doubles as a stash refspec carrier.** For `--hook-remove` it's a file path; for `--hook-debug --with-stash` it's `stash:<label>`. Same column, different prefix tells a future `--hook-audit` consumer how to recover the pre-debug worktree.
- **`ac_info` calls have `2>/dev/null || true` belt-and-suspenders.** Even though `ac_info` writes to stderr (not the closed stdout pipe), a caller might `2>&1 | head` and close stderr too.
- **`--no-trace` reads as "plain (no xtrace)"** in the header so the mode is unambiguous when the user is comparing two runs.

**Resume next session here:**
- **`--hook-bypass`** — single-shot escape valve. Writes `.git/antcrate-hook-bypass` flag, antcrate-shipped hooks read+consume+log it, exits 0. Reuses `_ac_hooks_audit_append` with `action: "hook-bypass"`. Adds AGENTS.md rule (#14 or extension of #13): agents may **propose** bypass, not execute it; the human runs the command. ~90min. Now the last queued hook-surface item before the composite umbrella.
- **Composite pre-commit umbrella** — lift the Phase-1 single-slot constraint so `--hook-autoinstall` can install multiple stack checks side-by-side. ~2hr.
- **dlg_smoke + hookrm_smoke registry entries** — surface to user before next big pass; `/tmp` is outside safety zones so `--remove` correctly refuses (rule #1, joint decision per Gateway Law).
- **Uncommitted history catch-up:** the 2026-05-10 `--hook-remove` work and tonight's `--hook-debug` work are both sitting in the working tree (M files: bin/antcrate, lib/hooks.sh, tests/hooks.bats, HOOK_PLAN.md, state.md, ledger.md). Recommend splitting into two commits (`feat(hooks): --hook-remove + dual audit-log infra` then `feat(hooks): --hook-debug + SIGPIPE-safe cleanup`) and pushing via `antcrate --pp antcrate -y` before starting `--hook-bypass`.
- **Stale tickets to re-check status on:** #69 lib-header propagation, #76 `--mirror`, #78 three-tier agent context model, #79 AGENTS.md #15 private-by-default, #84 `--init` (folds /init into antcrate), #85 `--env-setup`, #86 AGENTS.md #14 AI-action denylist.

---

## Earlier (kept for history)

**Git history catch-up landed (2026-05-09, seventeenth pass):** three sessions of work (dogfood trio #82/#83/#87, agent layer #88-#92/#109-#111, --delegate #93) were sitting in the working tree from 2026-05-05 onward. Split into 4 commits (`f670f4f` dogfood, `d90aa11` agent-layer, `2a14155` delegate, `5116045` docs catch-up) and pushed via `antcrate --pp antcrate -y`. The new post-push verify from #87 fired on its own first push: `verify: origin/master in sync at 5116045`. CI green at HEAD (269/269 bats, shellcheck clean). Working tree clean.

**#93 `--delegate` shipped — agent layer is now feature-complete (2026-05-08, sixteenth pass):**

Closed proposal #93. Clyde now has a deterministic Clyde-to-Cody handoff with a per-key attempt budget. The full surface:

- `antcrate --delegate <project> --key <key> --task "<desc>" [--file <relpath>]`
  Increments `<project>/.antcrate/cody-attempts.json[$key]`, refuses with exit 3 when count >= `ANTCRATE_DELEGATE_THRESHOLD` (default 3), emits a `delegate` activity event (`agent=clyde`, `label=key=<k> attempt=N/T`), prints a copy-pasteable handoff block.
- `antcrate --delegate-reset <project> [--key <key>]` — zero one key (with `--key`) or replace the file with `{}` (without).
- `antcrate --delegate-status <project>` — list non-zero counters, sorted by count desc.

**End state:** the agent layer is now operationally complete. Every `--register`/`--start`/`--rename` lays the Cody pointer + attempt counter (lifecycle treatment, #92), and `--delegate` enforces the three-attempt rule from cody.md at the wrapper level instead of relying on Cody self-policing. Refusal output instructs the user to escalate or run `--delegate-reset` deliberately.

Test count 251 → 269 (18 new in `tests/delegate.bats`). Full `--ci` PASS (shellcheck clean across all libs incl. delegate.sh; bats 269/269 green). Smoke-tested end-to-end against the live `antcrate` project + an isolated `dlg_smoke` fixture: threshold trip at the 4th attempt, refusal block printed, `--delegate-reset --key foo` cleared the entry, next `--delegate` succeeded at attempt 1/3.

**Non-obvious decisions (full context in 2026-05-08 ledger entry):**
- **Pre-increment threshold check.** Three delegations succeed (counter ends at 1, 2, 3); the fourth refuses at count==3. Matches cody.md's "three-attempt rule" without off-by-one ambiguity.
- **Atomic JSON replacement** via `_ac_delegate_attempts_write` (temp+mv). Same shape as registry.sh.
- **Lazy attempts file** — if `cody-attempts.json` is missing (project predates lifecycle wiring or file was deleted), `ac_delegate_run` recreates it on demand. Tested.
- **Event path falls back to key.** If `--file` is omitted and the key isn't a path (e.g. function name), the activity event's `path` field is the raw key. Documentary, not validated.
- **Reset is two-shape.** `--delegate-reset proj` clears all keys (post-context-shift); `--delegate-reset proj --key X` clears one. Listed both in usage + smoke-tested.
- **Refusal is exit 3.** Distinct from validation errors (2) and operational failures (1) so callers / scripts can branch on intent.
- **Used `ac_with_lock` for mutating paths.** Cross-project mutex is overkill for per-project file writes, but matches every other lifecycle flag's convention; status path is read-only and skips the lock.
- **Smoke fixture cleanup.** `dlg_smoke` in `/tmp/ac_delegate_smoke` had its files deleted but the registry entry remains — `--remove` correctly refused (rule #1, path outside allowed zones) and the user-side memory rule says removals are joint decisions, not auto-approved. Will surface to user before next cleanup.

**Resume next session here:**
- **HOOK_PLAN follow-ups (still queued):** composite pre-commit umbrella template so multiple checks coexist in the single git slot (currently Phase 1 picks one and reports the rest as skipped); `--hook-remove`; `--hook-bypass` with audit log; `--hook-debug` re-run with annotation.
- **Stale tickets to re-check status on:** #69 lib-header propagation, #76 `--mirror`, #78 three-tier agent context model, #79 AGENTS.md #15 private-by-default, #84 `--init` (folds /init into antcrate), #85 `--env-setup` (human-only env wizard, complements #110), #86 AGENTS.md #14 AI-action denylist.
- **dlg_smoke registry entry** — surface to user, then either `--remove` with `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` (with explicit approval) or leave it.

---

## Earlier (kept for history)

**Cody / agent layer + auto-treatment chain shipped (2026-05-07, fifteenth pass):**

Eight tickets closed in one session: #88 (Cody scaffold at `~/.claude/agents/cody.md`), #89 (`--agent-init`), #90 (hook template library + `--hook-install` per HOOK_PLAN steps 1+2), #91 (`--md-scaffold`), #92 (lifecycle wiring), #109 (`--profile`), #110 (`--env-scan`), #111 (`--hook-autoinstall`).

End state: every `antcrate --register` / `--start` / `--rename` now auto-fires the AntCrate-treatment chain. A fresh `--register` produces:
- `<project>/.claude/agents/<project>-cody.md` — project-scoped Cody pointer (sonnet, project tools).
- `<project>/.antcrate/cody-attempts.json` — `{}` initial state for the attempt counter.
- `<project>/CLAUDE.md` + `AGENTS.md` + `state.md` + `ledger.md` from token-substituted templates at `assets/code/templates/md/`.
- `<project>/.git/hooks/pre-commit` (when git repo) — installed from `pre-commit-secrets` template.
- `<project>/.gitignore` patched with `.env`, `.env.local`, `.env.*.local`.

Test count 199 → 251 (52 new tests), full `--ci` PASS (shellcheck + bats). Smoke-tested end-to-end on `friendly_cars` and a fresh `lc_test` project.

**HOOK_PLAN follow-ups:** composite pre-commit template so multiple checks coexist in the single git slot (currently Phase 1 picks one and reports the rest as skipped); `--hook-remove`; `--hook-bypass` with audit log; `--hook-debug` re-run with annotation.

**Non-obvious decisions worth remembering** (full context in 2026-05-07 ledger entry):
- Aligned with existing `HOOK_PLAN.md` instead of inventing a parallel `--hooks-init` flag. Templates live at `assets/code/hooks/templates/`; `lib/hooks.sh` extended with `ac_hook_install`.
- Phase-1 single-slot constraint on pre-commit: git runs only one file per event, so `--hook-autoinstall` picks priority order (secrets > stack-bash > ci) and surfaces what was skipped.
- `~/.claude/agents/` files require Claude Code session restart to appear in `/agents` — loaded at session start, not hot-reloaded.
- Registry stores domain as `parent` (legacy field name); CLI flag is `--domain`. New libs use `ac_registry_get "$proj" parent`.
- `install.sh` was missing a copy step for `assets/code/hooks/`; fixed so post-install lib resolves templates correctly via `../hooks/templates/` relative path.

---

## Earlier (kept for history)

**`--git-init` (#77) + `--bootstrap` (#80) shipped (2026-05-05, fourteenth pass):**
- `lib/git_init.sh` — local-only `git init` counterpart to `--gh-init`. Idempotent. Wires `core.hooksPath .githooks` when `.githooks/` present.
- `lib/bootstrap.sh` — composes `--git-init` + default `.gitignore` (rule #13 secret denylist + cleanup-prune giants, agreement-by-construction with `ac_commit_secret_match` + `lib/cleanup.sh`) + first commit. Pre-stage diagram regen called twice for tree.mmd convergence. `--with-remote` chains `--gh-init` with private default per AGENTS.md #15 (queued).
- 16 new bats tests (182 → 199 total). Live smoke test against an isolated `ANTCRATE_HOME` / `ANTCRATE_ROOT` confirmed end-to-end: register → bootstrap → bootstrap = 1 commit, clean tree.
- Help text + dispatch wired in `bin/antcrate`. Inner-loop parser for `--bootstrap` accepts `-m`, `--with-remote`, `--public`, `--private`.
- Once `--init` (#84) lands, the full onboarding cascade becomes one flag: `antcrate --init <project>` → `--start | --register` + scaffold CLAUDE.md + `--bootstrap`.

**Bug #81 fixed (2026-05-05): tree.mmd timestamp non-idempotency.** `lib/diagrams.sh` now skips the write when only the timestamp header would change. Verified live on friendly_cars — `--backup` no longer leaves `M docs/diagrams/tree.mmd` in git status. Test count 162 → 166. Unblocked `--bootstrap` (#80) — without it, the one-liner UX would have shipped a dirty tree on first commit.

**friendly_cars onboarded (2026-05-04, externally — not antcrate-side):** The home-orchestration's first non-self project. Registered, backed up, SQL patched (idx_sale_status + Q3 LEFT JOIN form), CLAUDE.md expanded with O(n) execution plan + Test Bench Protocol. See `~/projects/friendly_cars/friendly-cars-dealership/ledger.md`. Onboarding revealed bug #81 + a queue of dogfood proposals (#76 `--mirror`, #77 `--git-init`, #80 `--bootstrap`, #82 `--info`, #83 `-y`, #84 `--init`, #85 `--env-setup`).

**`--cleanup` + `--watch` + activity event stream landed (2026-05-04, twelfth pass):**
- New `lib/events.sh`: append-only JSONL per project at
  `~/.antcrate/events/<project>.jsonl`. Schema: `{ts, ts_ms, kind, path,
  agent, ttl_ms, label?}`. Five kinds (modify/read/think/delegate/delete)
  with kind-specific default TTLs. `ac_events_active` filters expired
  events. Atomic append; tolerates malformed lines on read.
- New `lib/watch.sh`: pure-bash + ANSI colored tree renderer. Walks the
  project tree, paints each path according to active events; intermediate
  directories propagate the highest-severity descendant kind. Color map:
  delete (sev 5) = bright red strikethrough, modify (4) = yellow,
  delegate (3) = green, think (2) = magenta, read (1) = cyan.
  `--watch <project>` loops with clear-and-redraw at
  `ANTCRATE_WATCH_INTERVAL_MS` (default 200ms); `--once` prints a single
  frame for testability + scripting.
- New `lib/cleanup.sh`: classifier + apply. `--cleanup <project>` walks
  the tree and lists test-tmp candidates (exact-name match for
  `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.tox`, `.cache`,
  `.turbo`, `.nyc_output`, `coverage`; glob match for `*.test.tmp`,
  `*.pyc`, `*.bats.log`) plus empty directories. `--cleanup <project>
  --apply <id>[,<id>...]` removes per ID through
  `ac_safety_guard_destructive` (rule #1 backup + approval), emits a
  `delete` event with category as label so the watch view paints a 1s
  tombstone, and appends to `projects.<n>.recent_removals` (capped at 50
  via the new `ANTCRATE_CLEANUP_RECENT_CAP` env). Skip-prune list
  excludes `.git`, `.github`, `.githooks`, `node_modules` at any depth.
- `lib/backup.sh` widened: `ac_backup_create` now accepts files, not
  just dirs (tar handles both uniformly). Closes the gap that prevented
  `ac_safety_guard_destructive` from gating single-file removals — every
  destructive op now has a uniform backup floor.
- Wrapper flags: `--emit-activity <project> <kind> <relpath>
  [--ttl-ms N] [--label X] [--agent A]`, `--watch <project> [--once]
  [--interval-ms N] [--no-color] [--depth N]`, `--cleanup <project>
  [--apply <id>...]`.
- **Lib header convention codified.** New libs (events, watch, cleanup,
  ingest) carry a "Public API" + "Internal" header that lists which
  functions are entry points and which bypass invariants if called
  directly (e.g. cleanup's internal scanners produce raw rows that
  `classify` dedupes/numbers; calling them out-of-order would skip the
  contract). Propagation to the existing 17 libs is queued as task #69
  — separate focused pass so this commit stays cohesive.
- 27 new bats tests across `tests/{events,watch,cleanup}.bats`; with
  ingest still green, **162/162 passing** (was 135), shellcheck clean.

**`--ingest` consumer landed (2026-05-04, eleventh pass):**
- New `lib/ingest.sh` (~400 lines): validate-before-write per BUNDLE_SPEC §4
  (manifest parse, spec_version major check, required fields, name rules,
  domain shape, source.type sub-fields, registry-collision unless
  supersedes/extends declared, reachability per source type).
- All four `source.type` variants implemented:
  `none` (empty scaffold), `git` (clone + optional commit checkout),
  `archive` (download or local copy + optional sha256 verify + tar/zip
  extract), `composite` (each sub-source materialized in declaration
  order; `cp -rn` no-clobber merge — first source wins).
- Relationships: `supersedes` runs `ac_safety_guard_destructive` against
  the existing project tree (rule #1 — backup + approval), and also
  backs up the existing per-project skill, before re-materializing under
  the same name; `extends` merges research/skill/diagrams into the
  existing tree without re-cloning; `duplicate_of` and `depends_on`
  emit warnings only.
- STATUS lifecycle: `ready → claimed → ingested` on success;
  `failed: <reason>` on any failure with no partial registry/disk state.
  Atomic temp-file write per AGENTS.md guidance.
- Opaque file copy: `research.md → docs/`, `claude.md → CLAUDE.md`,
  `skill/ → ~/.claude/skills/<skill_name>/` (overrideable via
  `claude.skill_name`), `diagrams/* → docs/diagrams/`,
  `attachments/* → docs/attachments/`.
- Wrapper wired: `antcrate --ingest <bundle-path>`. Auto-regen runs
  inside the lock so `AC_INGEST_NAME` stays in scope (the wrapper-level
  call would have hit `set -u` after the lock subshell exits).
- Test envs added: `ANTCRATE_INGEST_OFFLINE=1` (skip reachability),
  `ANTCRATE_INGEST_SKIP_FETCH=1` (skip clone/download — validation-only
  pass).
- 22 new bats tests in `tests/ingest.bats` covering: §4 validators
  (good + every failure path), all four source.types, supersedes
  backup-and-replace, extends merge, composite first-wins, opaque file
  copy, skill_name override, sha256 mismatch, depends_on warning.
  **135/135 bats passing** (was 113), shellcheck clean.
- Smoke-tested end-to-end against `assets/docs/examples/bundles/theoretical/`
  — STATUS transitions, registry entry created with `objective` field,
  research.md copied, auto-regen fires.

**Skill polish + DIAGRAM_PLAN.md (2026-05-01, tenth pass):**
- `SKILL.md` rewritten: trimmed stale orientation list, added explicit AGENTS.md rule numbers (#1, #10, #11, #12 Gateway Law, #13 config-human-only) to "Read first", listed all current `lib/*.sh` modules, all current docs (BUNDLE_SPEC, HOOK_PLAN, GH_PIPELINE_PLAN, DIAGRAM_PLAN, POST_DEV_BACKLOG), pointed at the GitHub repo, codified the maintenance protocol with the actual antcrate flags (no longer references nonexistent `project-forge` skill).
- `composes.md` rewritten: dropped fictional skills (`project-forge`, `research-recon`, `research-swarm`, `docx`, `pdf`, `pdf-reading`, `frontend-design`) and `/mnt/skills/...` paths from a different setup. Replaced with what's real: memory files (auto-loaded), `~/CLAUDE.md`, harness skills loaded on demand, future per-project skill composition pattern from BUNDLE_SPEC. Reframed diagram tooling from "external dependency" to "first-class AntCrate output."
- `stack.md` updated: pinned versions for `bats-core` 1.13.0 and `shellcheck` 0.10.0, full `lib/*.sh` enumeration, all current env vars (incl. `ANTCRATE_AUTO_DIAGRAMS`, `ANTCRATE_TREE_DEBOUNCE_MS`, `ANTCRATE_COMMIT_PREAPPROVED`, `ANTCRATE_SELFSRC`), `.github/workflows/` and `.githooks/` dirs, `gh` listed as required (was missing), reserved `_archived` parent value, AGENTS.md rule references.
- New `assets/docs/DIAGRAM_PLAN.md` — case-by-case diagram selection roadmap. Shipped today documented (universal pair: registry.mmd + tree.mmd, both auto-regenerated wrapper-side AND daemon-side). Queued: stack-aware presets (`bash`, `node`, `svelte`, `python`, `rust`, `go`, `terraform`, `db`, `k8s`), `--diagram-preset`, `--diagram-detect`, auto-install on `--start --diagrams <preset>`. Bundle-manifest-driven preset selection threads through to BUNDLE_SPEC's `manifest.stack`. `DIAGRAM_AUTOMATION_GUIDE.md` is now framed as the underlying tool catalog backing this selection logic.

**Hooks: CI workflow + opt-in pre-commit + read-only inspection landed (2026-05-01, ninth pass):**
- `.github/workflows/ci.yml` — installs `jq` + `shellcheck` + `bats-core`, runs `install.sh`, then `antcrate --ci`. Fires on push to `master`/`main` and on PRs. Public-facing safety net for when the repo eventually goes public, regression-catcher today even while private.
- `.githooks/pre-commit` — opt-in (enable per-clone via `git config core.hooksPath .githooks`), runs `antcrate --ci`, tees output to `.git/antcrate-hook.log` so blocked commits leave debuggable evidence.
- New `lib/hooks.sh` with `ac_hooks_dir`, `ac_hooks_list`, `ac_hooks_log`. Wired as `--hooks <project>` (lists active hooks, honors `core.hooksPath`, flags antcrate opt-in when active) and `--hook-log <project> [lines]` (tails the hook log; default 50 lines).
- `assets/docs/HOOK_PLAN.md` — full design contract for the queued install/remove/bypass surface (template library, `--hook-install`, `--hook-remove`, `--hook-bypass` with audit log + AGENTS.md rule, `--start --hooks <preset>` auto-install). Single source of truth so the surface stays coherent across follow-up sessions.
- 12 new bats tests in `tests/hooks.bats`. **109/109 passing** (was 97), shellcheck clean.

**Daemon hook for live-tree auto-regen shipped + verified (2026-05-01, eighth pass):**
- New `ac_diagrams_resolve_project_for_path` in `lib/diagrams.sh` — longest-prefix-match maps an event's directory back to its registered project (handles sub-branches correctly).
- `bin/antcrated` rewritten with a two-path event handler: schema-dispatch (existing) + live-tree auto-regen (new). Per-project debounce (`ANTCRATE_TREE_DEBOUNCE_MS`, default 600ms) coalesces bursts (`git checkout`, batch saves) into a single regen. Watched events broadened to `create|close_write|moved_to|moved_from|delete` so renames and removals refresh the tree. Daemon-local registry cache (mtime-keyed) avoids per-event jq invocation.
- 8 end-to-end tests on real hardware all green: new file via `touch` updates tree.mmd; `mkdir` shows `[/dir/]`; swap/`~` files filtered (no spurious regens); `rm` and `mv` both refresh; bursts coalesce; orphan files inside the watched root but outside any project produce no regen; `registry.mmd` reflects all 4 projects. Daemon stopped cleanly via SIGTERM (PID file removed by cleanup trap).
- 6 new bats tests for the resolver. **78/78 passing** (was 72), shellcheck clean.
- **Pre-delete verify gate codified as standard practice**: before any `antcrate --remove`, agent runs `--status` + `jq .projects[<name>]` + `find <path>` and shows output to user before the destructive command runs. One notch tighter than AGENTS.md rule #1's interactive prompt.

**BUNDLE_SPEC v1.0 drafted (2026-04-28, seventh pass):**
- `assets/docs/BUNDLE_SPEC.md` — typed handshake between research-AntCrate (producer) and dev-AntCrate (consumer). Required `manifest.json` fields (`spec_version`, `name`, `domain`, `objective`, `generated_at`, `source`); four `source.type` variants (`git` / `archive` / `none` / `composite`); status lifecycle (`ready` → `claimed` → `ingested` → `consumed`, plus `failed`); `relationships` (`duplicate_of`, `supersedes`, `extends`, `depends_on`); validation contract (validate-then-write, no partial-disk-state failures); opaque-files policy (everything outside `manifest.json` is copied, never parsed).
- Four reference bundles under `assets/docs/examples/bundles/`: `git-pinned/` (standard case, full payload), `theoretical/` (no source code, research-only), `composite/` (multi-source merge), `supersedes/` (replaces a registered project under AGENTS.md rule #1). All four `manifest.json` files validated by jq for required fields.
- README.md + PATTERNS.md updated with pointers to the spec; PATTERNS.md gains a "Bundles" section with `--ingest` / `--queue` / `--next` / `--conclude` listed as **planned**.
- Spec is **authored, not implemented**. No code shipped yet on the consumer side. Next step is `antcrate --ingest <local-path>` against a hand-crafted bundle to prove the consumer end-to-end before wiring the GitHub-backed queue.

**Auto-regen wired (2026-04-28, sixth pass):**
- New helper `ac_diagrams_auto_regen [project]` in `lib/diagrams.sh` — silent on stdout, errors swallowed, opt-out via `ANTCRATE_AUTO_DIAGRAMS=0`. Always rewrites `~/.antcrate/registry.mmd`; if a project arg is given and it's still on disk, also rewrites `<path>/docs/diagrams/tree.mmd`.
- Hooked into every mutating wrapper action: `start`, `register`, `branch`, `link`, `resume --expand`, `rename`, `archive`, `unarchive`, `remove`, `touch`, `mkdir`, `restore`. Manual `--registry-diagram`/`--tree-diagram` flags are now a fallback/override path, not a required step.
- `--touch`/`--mkdir` stdout contract preserved (composition with `Write` / `$EDITOR` still works) — auto-regen writes only to logfiles, never to stdout.
- New tests in `tests/diagrams.bats` (5): emits both diagrams, opt-out via env var, registry-only when no project arg, stdout silent, doesn't fail when project missing from disk. Total: **72 / 72 bats passing**, shellcheck clean.
- PATTERNS.md updated with auto-regen note + opt-out documentation.

**Phase 2 + CI shipped (2026-04-28, fifth pass):**
- `lib/diagrams.sh` (per `DIAGRAM_AUTOMATION_GUIDE.md`): `ac_diagrams_scaffold` (drops `docs/diagrams/architecture.mmd` on `--start`), `ac_diagrams_registry_to_mermaid` (graph of all projects, archived dimmed), `ac_diagrams_tree_to_mermaid` (project's addressed tree → Mermaid). `ac_diagrams_render` skips gracefully when `mmdc`/`plantuml`/`d2` absent — text source still renders inline on GitHub.
- Wrapper flags: `--diagrams`, `--registry-diagram [out]`, `--tree-diagram <project> [out]`.
- `--register <name> <existing-path> [--domain <d>]` — registers a tree that already exists on disk (no scaffold). Used to register the antcrate skill source itself.
- Safety zones extended: parent of `$ANTCRATE_SELFSRC` (the skill root, e.g. `~/.claude/skills/antcrate/`) is now an allowed zone, so the skill repo can be pushed via `--pp` once gh-init runs.
- `--ci` shim: one command, runs `shellcheck -x` on libs+bins+installer then `bats tests/`. Fail-fast.
- Templates: `_generic/docs/diagrams/architecture.mmd` added with `__NAME__`/`__DATE__` token substitution.
- Pre-existing scaffold bug fixed: `ac_scaffold_resolve_templates` was picking the empty `~/.antcrate/templates/` (created by `--init`) over the populated `~/.local/share/antcrate/templates/`. Now requires a candidate to actually contain `_generic/` or a domain dir before selecting.
- New tests: `tests/diagrams.bats` (7), `tests/register.bats` (6).
- `antcrate --ci`: shellcheck **clean** + bats **67/67 passing** (was 54).
- **Skill source pushed to GitHub (private):** `https://github.com/zeppybabe/antcrate`. Initial commit `e6b64fb`, 55 files. Top-level `README.md` + `.gitignore` added. Registry `git_remote` updated. `antcrate --pp antcrate` is the canonical update path going forward.

**Wrapper coverage closed (2026-04-27, third pass):**
- `--unarchive` — paired with `--archive` (which now stores `previous_parent`).
- `--remove` — hard delete with loud banner; backup-tarball-only recovery.
- `--touch <project> <relpath>` / `--mkdir <project> <relpath>` — file/dir creation through the wrapper; rejects absolute/.. paths; stdout = abs path for composition.
- All four validated end-to-end on `ac-touchtest`; PATTERNS.md updated; "no flag yet" placeholder for remove is now retired.

**Anchor + Address architecture shipped (2026-04-27, second pass):**
- `lib/address.sh` — layered positional address scheme. `1a3` = 3rd entry inside the 1st sub-branch of the 1st top-level dir. Alternates digit/letter by depth; letters are bijective base-26.
- `lib/anchor.sh` — eliminates `cd` jumps. `eval "$(antcrate --anchor <project>)"` for shell sessions; `antcrate --in <project> [--addr <code>] -- <cmd>` for one-shots. `$ANTCRATE_ANCHOR` is the exposed handle.
- `lib/devops.sh` — `--map` (addressed tree with d/s tags), `--rename`, `--archive` (both backup+approval gated), `--logs`, `--diff`, `--selfsrc`, `--selfinstall`, `--selftest`, `--selfedit`. AntCrate now develops AntCrate without leaving the wrapper.
- `AGENTS.md` rules #10 and #11 codified: no bare `cd`, no bare command when a wrapper exists.
- `assets/docs/PATTERNS.md` rewritten: full flag-by-intent index across 8 sections + verb-based quick index; "Move/rename a registered tree" gap closed by `--rename`; "remove" still routed through `--propose`.
- Validation: `--map`/`--addr`/`--in`/`--anchor`/`--rename`/`--archive`/`--logs`/`--diff`/`--selfsrc`/`--selfedit` all exercised end-to-end against a `ac-validation` fixture; fixture archived to `~/projects/.archive/ac-validation-renamed`. Backups under `~/.antcrate/backups/{ac-validation,ac-validation-renamed}/`.

**Earlier this session:**
- `lib/propose.sh` + `--propose` + `--proposals` shipped. Escape valve into `~/.antcrate/proposals.log`.
- SKILL.md points to `PATTERNS.md` as first orientation step.

**Test suite green (2026-04-27, fourth pass):**
- `bats-core` 1.13.0 installed under `~/.local/bin/bats` (no sudo; cloned + ran upstream installer).
- `shellcheck` 0.10.0 installed under `~/.local/bin/shellcheck` (static binary).
- `antcrate --selftest`: **54 / 54 passing** across 7 suites (address, backup, git_triage, propose, registry, scaffold, schema).
- `shellcheck -x` on all libs + bins + installer: **clean exit 0**. Genuine fixes applied (SC2059 in address.sh int_to_letters, SC2295 in render_tree, unused `line` var in devops.sh map). Idiomatic `A && B || true` patterns rewritten to `if A; then B; fi || true` for clarity in git_triage.sh and scaffold.sh. File-level shellcheck disables added for legitimate cross-file usage (jq filter strings, AC_COMPONENT, AC_LAST_BACKUP_PATH, AC_META_*).
- Bugs fixed during the test run:
  1. `lib/address.sh` `ac_addr_list_dir` used `ls -1` which excludes hidden files before the awk filter could see them — switched to `ls -1A`. Hidden-include test now passes.
  2. `lib/registry.sh` `ac_registry_has` used `// empty` filter which returns exit 4 in jq 1.7+ (vs. exit 1 in older jq). Filter rewritten to `.projects[$n]` (null → exit 1 cleanly).
  3. `lib/backup.sh` `ac_backup_create` could collide on second-resolution timestamps, causing pre-restore backup to overwrite the intended restore source. Added `_<n>` suffix on collision.
  4. `tests/scaffold.bats` setup didn't source `safety.sh` / `backup.sh` — added (subbranch.sh now requires them via `ac_safety_guard_destructive`).

v0 codebase confirmed working on real hardware after two bugs fixed (nested flock deadlock in `scaffold.sh`; jq arg passthrough bug in `registry.sh`). First live registry write confirmed. Home directory `CLAUDE.md` rewritten as AntCrate orchestration meta-config.

Test project `test-scaffold` lives at `~/projects/scripts/test-scaffold` — can be removed with user approval per AGENTS.md rule #1.

**Open proposals stream:** `cat ~/.antcrate/proposals.log` (or `antcrate --proposals`).

Ready for GitHub upload.

## What's built (v0)

- Architecture spec at `assets/docs/architecture.md`.
- Wrapper CLI (`bin/antcrate`): `--start`, `--branch`, `--link`, `--rel`, `--pp`, `--resume --expand`, `--gh-init`, `--gh-help`, `--backup`, `--backups`, `--restore`, `--init`, `--status`, `--list`.
- Daemon (`bin/antcrated`): `inotifywait` + debounce + flock + swap-file filter.
- Library modules under `assets/code/lib/`:
  - `registry.sh` — atomic jq CRUD on `~/.antcrate/registry.json`
  - `schema.sh` — positional filename decoder
  - `git_triage.sh` — push wrapper with mailx/sendmail conflict triage
  - `subbranch.sh` — atomic project nesting (now backup-protected)
  - `safety.sh` — path-zone guard + **`ac_safety_guard_destructive`** (backup + approval, fail-closed)
  - `backup.sh` — verified tar.gz backups with sha256 manifests, retention pruning, restore
  - `gh.sh` — GitHub HTTPS via `gh` CLI (no plaintext PATs)
  - `log.sh` — leveled logging
  - `lock.sh` — flock + pause-flag helpers
- `AGENTS.md` — 9 hard rules (rule #1 = no destructive op without backup + approval).
- `CLAUDE_CODE.md` — install + onboarding for Claude Code users.
- Templates for `webapps`, `projects`, `scripts`, `notes`, `_generic`.
- Systemd user unit, idempotent installer.
- bats-core tests: `schema.bats`, `registry.bats`, `git_triage.bats`, `scaffold.bats`, `backup.bats` (7 backup-specific tests covering creation, fail-closed-without-tty, preapproved-bypass, zone refusal, subbranch-backup, restore-latest, retention).

## Blockers

None for v0 codebase. Real-machine validation needed for `inotifywait` debounce timing across editors, real `git push` against diverged history, real `mailx` MTA dispatch, systemd unit lifecycle.

## Next steps

Now (consumer side, this machine):

1. ~~`antcrate --ingest <bundle-path>`~~ **shipped 2026-05-04.** All four `source.type` variants + relationships (supersedes/extends/duplicate_of/depends_on) covered with bats.

Soon (queue + producer):

3. **`QUEUE_SPEC.md`** — defines `queue.json` at the bundles-repo root and per-bundle `STATUS` semantics for multi-machine coordination. Builds on BUNDLE_SPEC v1.0 lifecycle.
4. **`antcrate --queue` / `--next` / `--conclude`** — flags wired against a private GitHub `research-bundles` repo. `--next` claims oldest-ready, ingests, marks consumed.
5. **GitHub auth model** — fine-grained PAT scoped only to `research-bundles`, installed on the research machine. Same GitHub user for now; machine-user upgrade deferred until there's a reason.

Long horizon:

6. **Phase 3 — Per-project skill composition pattern**: codify the canonical `antcrate skill (orchestration) + <project> skill (knowledge) + project CLAUDE.md (conventions)` triple. Bundle ingest already drops the per-project skill in place; this is the doc + worked example.
7. **Phase 4 — LLM orchestrator hook**: thin wrapper letting a local Ollama agent on the research machine emit valid bundles deterministically. Conforms to BUNDLE_SPEC, runs unattended, queues bundles for human review.

Already shipped (this session):
- v0 codebase + GitHub upload (`https://github.com/zeppybabe/antcrate`)
- Phase 2 diagram automation + auto-regen on every mutating wrapper action
- Daemon hook for live-tree auto-regen (2026-05-01) — direct edits / git checkouts / outside-wrapper changes now refresh diagrams automatically
- `--ci` shellcheck + bats green (78/78, was 72/72)

## Open questions

- Editor swap-file rules across vim, kakoune, micro (current rules cover nano, helix, vim's `4913` probe).
- `mailx` vs `sendmail` runtime detection on minimal containers.
- `ANTCRATE_ROOT` default — keeping `$HOME/projects` but worth a config check on first-run.
- Domain whitelisting (typo prevention: `webaps` vs `webapps`).
- Backup encryption — currently plaintext tar.gz. If projects contain `.env*` (gitignored but present on disk), backups capture them. Consider opt-in `gpg` encryption for `~/.antcrate/backups/` as a Phase 2+ item.

## Blockers

None for v0 codebase generation. Real-world testing requires a Linux box with `inotify-tools`, `jq`, `git`, and a working `mailx` or `sendmail`. Anything that requires a live daemon (debounce timing, swap-file behavior across editors) needs to be validated on the user's actual machine before we lock the defaults.

## Next steps

1. Review v0 codebase, adjust paths/defaults to match the user's `~/projects/` layout.
2. Push to GitHub (user-managed). Connect repo to Claude (web search / GitHub MCP if available).
3. Audit + bats-core test pass on real hardware.
4. **Phase 2 — Diagram automation integration**: extend the `start` action so each new project ships with `assets/diagrams/` pre-wired (Mermaid in README, PlantUML for class/seq, D2 for arch, SchemaSpy hook for any project with a DB). Pull straight from `DIAGRAM_AUTOMATION_GUIDE.md`.
5. **Phase 3 — LLM orchestrator hook**: thin wrapper that lets a local Ollama-driven agent emit Positional-Extension filenames and have them executed deterministically.

## Open questions

- **Editor swap-file rules**: nano writes `name~`, helix writes `.name.swp`-style. Current debounce ignores any filename starting with `.` or ending in `~`. Need to confirm against vim, micro, neovim, kakoune.
- **`mailx` vs `sendmail` default**: spec says either; we default to `mailx -s` for portability but fall back to `sendmail -t` if `mailx` is missing.
- **`projects/` root**: spec uses `~/projects/` and `~/projects/coolwebapps/`. We expose this as `ANTCRATE_ROOT` env var, default `$HOME/projects`.
- **Domain whitelisting**: currently any `$1` value becomes a directory. Worth adding an optional allowlist in `~/.antcrate/config` to catch typos (`webaps` vs `webapps`).
