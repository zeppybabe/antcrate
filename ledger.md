# AntCrate — Ledger

Append-only log. Newest entries on top. ISO-8601 dates. Never delete.

---

## 2026-05-08 — `--delegate` (#93): agent layer feature-complete (sixteenth pass)

Closed proposal #93 — the last unfinished piece of the agent layer designed in the 2026-05-07 pass. Clyde now has a deterministic Clyde-to-Cody handoff with a per-key attempt budget enforced at the wrapper level instead of relying on Cody self-policing.

**New surface:**

- `antcrate --delegate <project> --key <key> --task "<desc>" [--file <relpath>]`
  Increments `<project>/.antcrate/cody-attempts.json[$key]`, refuses with exit 3 when the count reaches `ANTCRATE_DELEGATE_THRESHOLD` (default 3), emits a `delegate` activity event (`agent=clyde`, `label=key=<k> attempt=N/T`), prints the copy-pasteable handoff block.
- `antcrate --delegate-reset <project> [--key <key>]` — zero one key (with `--key`) or replace the whole file with `{}` (without). The reset path exists for legitimate re-delegation after the user has reframed the problem; without it, the threshold trap would be terminal.
- `antcrate --delegate-status <project>` — list non-zero counters, sorted by count desc.

**New file:** `lib/delegate.sh` (~190 lines). Public API: `ac_delegate_run`, `ac_delegate_reset`, `ac_delegate_status`. Internals (`_ac_delegate_*`) marked do-not-call from outside per the lib-header convention codified in 2026-05-04. Sourced by `bin/antcrate` after `lib/lifecycle.sh`. Depends on `registry.sh`, `events.sh`, `log.sh`.

**Test count: 251 → 269** (18 new in `tests/delegate.bats`). Full `antcrate --ci` PASS — shellcheck clean across all libs + bins, bats 269/269 green.

**Non-obvious decisions:**

- **Pre-increment threshold check** (counter at 0..N-1 → succeed and increment; counter at >= N → refuse). Means three delegations succeed with counter ending at 1, 2, 3, and the fourth call refuses at the read of count==3. Matches cody.md's three-attempt rule cleanly. Considered post-increment-then-refuse but it conflates "did the delegation succeed" with "did the increment win," and the diagnostic at refusal time wants `current >= threshold` to be a clean predicate.
- **Refusal exit code 3.** Distinct from validation errors (`2`) and operational failures (`1`) so wrappers / shell scripts can branch on `$?` to detect the threshold case specifically — useful when chaining `--delegate || handle_threshold`.
- **Atomic JSON replacement.** `_ac_delegate_attempts_write` reads new content from stdin, writes to `<file>.tmp.$$`, then `mv -f`. Same shape as `registry.sh` so jq partial writes can't leave the counter file in a torn state. Matters because both `--delegate` and `--delegate-reset` may be invoked from automation or under signal pressure.
- **Lazy attempts file.** If `cody-attempts.json` is missing (project predates lifecycle wiring or the file was deleted manually), `ac_delegate_run` creates it on demand with `{}`. Tested. Avoids requiring a separate `--agent-init` retrofit pass for older projects.
- **Event path falls back to key.** When `--file` is omitted and the key isn't a path (e.g. `validateInput`, `bug-1234`), the activity event's `path` field is the raw key string. Watch view will paint a synthetic node for it; documentary, not validated.
- **Reset has two shapes.** `--delegate-reset proj` clears the entire counter (post-context-shift escape valve); `--delegate-reset proj --key X` clears one entry. Both go through `ac_with_lock` for cross-project mutex consistency with the rest of the lifecycle flags.
- **Status output shape.** Three-line header (`project`, `threshold`, `attempts`) followed by `<count>  <key>` rows. Sorted desc so the loudest signal is at the top. Empty case prints `attempts  : (none)`. Missing-counter-file case prints `(counter file missing)` rather than `(none)` so a torn-down project is distinguishable from a clean one.
- **Lock policy.** Mutating paths (`--delegate`, `--delegate-reset`) take `ac_with_lock`; status is read-only and skips it. Cross-project mutex is overkill for per-project writes but matches every other wrapper convention and removes a special case for reasoners.

**Refusal block content** (worth reproducing here because it's the user-facing UX):
```
─── REFUSED: --delegate threshold reached ───
project   : <p>
key       : <k>
attempts  : N (>= threshold of T)
─────────────────────────────────────────────
<p>-cody has been delegated to N times on this key
without success. Per cody.md's three-attempt rule, escalate to the
user instead of delegating again — four shallow attempts cost more
than one deeper investigation.

To deliberately reset and continue (e.g. after the user reframed the
problem):
  antcrate --delegate-reset <p> --key '<k>'
```

The "four shallow attempts cost more than one deeper investigation" line is lifted verbatim from cody.md so the refusal output reinforces the same heuristic Cody is operating under.

**Smoke-test:**

- Live run against the `antcrate` self-project: first `--delegate` produced attempt 1/3, counter `{"lib/delegate.sh:1": 1}`, event written to `~/.antcrate/events/antcrate.jsonl`. Reset cleared it.
- Isolated `dlg_smoke` fixture at `/tmp/ac_delegate_smoke`: three successful delegations bumped the counter to 1, 2, 3; the fourth printed the REFUSED block and exited 3. `--delegate-status` showed `3  foo`. `--delegate-reset --key foo` cleared the entry; the next `--delegate` returned to attempt 1/3.

**Known minor:** `dlg_smoke` registry entry remains because the path is in `/tmp/` (outside allowed safety zones) and `--remove` correctly refused per AGENTS.md rule #1. Per the user's standing memory ("removals require executive Claude+antcrate+user joint decision"), I left the entry rather than override the safety guard. Will surface for cleanup at next opportunity.

**Wrapper changes:**
- `bin/antcrate` — sourced `delegate.sh`; new flags `--delegate`, `--delegate-reset`, `--delegate-status`; new globals `DELEGATE_KEY`, `DELEGATE_TASK`, `DELEGATE_FILE`; usage text expanded; dispatch table extended with three cases.
- `~/.local/bin/antcrate` updated via `--selfinstall` so the installed wrapper has the new flags. Verified.

**What this unblocks.** The agent layer is now operationally complete for the Clyde→Cody handshake. With `--delegate` enforcing the three-attempt rule at the wrapper level, Clyde's prompt no longer needs to manually track attempt counts inline — the counter file is the source of truth, and the refusal block forces a real escalation to the user. The next focus area is the HOOK_PLAN follow-ups (composite pre-commit umbrella template, `--hook-remove`, `--hook-bypass` with audit log, `--hook-debug` re-run with annotation) — these no longer block the agent layer.

---

## 2026-05-07 — Cody / agent layer + auto-treatment chain (fifteenth pass)

Eight tickets closed in one session. The agent layer is now operational and every project lifecycle event auto-applies the AntCrate treatment.

**Tickets closed:** #88, #89, #90, #91, #92, #109, #110, #111. Test count 199 → 251 (52 new tests). Full `--ci` PASS (shellcheck clean across all libs, all 251 bats tests green).

**New libs / files:**

- `~/.claude/agents/cody.md` — home-level Cody subagent (sonnet, scoped tools: Read/Edit/Write/Bash/Grep/Glob/TodoWrite/Skill). System prompt encodes inheritance from AGENTS.md, the three-attempt rule with failure-report template, `simplify`/`review`/`security-review` skill hookups. Agent-tool-listed types still exclude custom subagents — Cody surfaces via Claude Code's `/agents` after session restart, not the Agent tool.
- `lib/agent_init.sh` (#89) — drops `<project>/.claude/agents/<project>-cody.md` and initializes `<project>/.antcrate/cody-attempts.json` with `{}`. Idempotent; both files preserved on re-run. 8 tests.
- `lib/md_scaffold.sh` (#91) + `assets/code/templates/md/{CLAUDE,AGENTS,state,ledger}.md` — internal-md skeletons with `__NAME__` / `__DOMAIN__` / `__DATE__` token substitution (matches existing scaffold.sh convention). Refresh-only by default; `--force` backs up existing files to `<file>.bak.<UTC-ts>`. 9 tests.
- `assets/code/hooks/templates/` (#90) — first 4 templates per HOOK_PLAN steps 1+2: `pre-commit-secrets` (universal secret-pattern guard, mirrors `lib/commit.sh`'s patterns), `pre-commit-stack-bash` (shellcheck on changed `*.sh`, no-op if shellcheck missing), `pre-commit-ci` (runs `antcrate --ci`), `pre-push-tests` (runs `test_cmd` from registry). Tokens: `__PROJECT_NAME__`, `__ANTCRATE_BIN__`. Header line `antcrate-template-version: 1.0` for staleness tracking.
- `lib/hooks.sh` extended (#90) with `ac_hook_install <project> <template> [hook-name] [--force]`. Default hook-name resolved from template prefix (`pre-commit-*` → `pre-commit`, etc.). Conflict behavior: identical content = no-op; different content = refuse (default) or backup-then-overwrite (`--force`). 11 new tests added to existing 12 in tests/hooks.bats.
- `lib/profile.sh` (#109) — read-only project profiler. `ac_profile_raw` emits TAB-separated `<category>\t<key>\t<value>` stream (categories: domain | stack | tooling | env | recommend); `ac_profile` renders human table. Stack signals: package.json, Cargo.toml, go.mod, pyproject.toml, *.sh count, *.sql count, etc. Skips heavy dirs (node_modules, .git, .venv, dist, build, target). 11 tests.
- `lib/env_scan.sh` (#110) — env-var detector + .gitignore guard. Lists `.env` files (excludes `.env.example`/`.env.sample`), counts env-var references in source via single regex covering JS/TS/Py/Rb/Java/PHP. `--apply` idempotently appends `.env`, `.env.local`, `.env.*.local` to `.gitignore`. Refuses to touch `.env` files (that's #85 territory). 11 tests.
- `lib/hook_autoinstall.sh` (#111) — orchestrator. Reads `ac_profile_raw`, picks ONE template per git-hook slot (priority order = profile order), calls `ac_hook_install` for each pick, calls `ac_env_scan --apply`. Phase-1 single-slot constraint: git runs only one file per event, so multiple `pre-commit-*` recommendations result in one install + a "skipped" report. `--dry-run` prints plan only. 8 tests.
- `lib/lifecycle.sh` (#92) — `ac_lifecycle_treatment <project>` fires the chain: `ac_agent_init` → `ac_md_scaffold` → (if `.git` exists) `ac_hook_autoinstall`. Idempotent; individual step failures warn but don't error. 5 tests. Wired into `bin/antcrate` after `start`, `register`, `rename` action handlers.

**Bin wiring:** new flags `--agent-init`, `--md-scaffold`, `--profile [--raw]`, `--env-scan [--apply]`, `--hook-autoinstall [--dry-run]`, `--hook-install <project> <template> [hook-name] [--force]`. Globals `MD_FORCE`, `PROFILE_RAW`, `ENV_APPLY`, `HOOK_AUTO_DRY`, `HOOK_TEMPLATE`/`HOOK_NAME`/`HOOK_FORCE` initialized at top of parser block.

**install.sh:** added missing copy of `assets/code/hooks/` to `$PREFIX/share/antcrate/hooks/` so `lib/hooks.sh`'s `_ac_hook_template_path` finds templates after install. The relative path `../hooks/templates/` from `$LIB_DIR` works in-tree AND post-install thanks to install.sh laying out the same structure.

**Non-obvious decisions:**

- **HOOK_PLAN alignment over invention.** Original ticket #90 was `--hooks-init` (a one-shot bundle). Discovered HOOK_PLAN.md already designed a template-based per-template install pattern (`--hook-install <project> <template>`). Aligned to HOOK_PLAN — the bundle behavior moved into the new `--hook-autoinstall` (#111). The two surfaces compose: `--hook-install` is the granular flag; `--hook-autoinstall` is the user-friendly wrapper that picks templates from profile recommendations.
- **Phase-1 single-slot for pre-commit.** Git only runs one file per hook event. For `friendly_cars` both `pre-commit-secrets` and `pre-commit-stack-bash` are recommended, but autoinstall picks `pre-commit-secrets` (universal, ranked first) and reports the other as `skipped (single-slot)`. Composite-template approach (one umbrella `pre-commit` that calls multiple checks) is HOOK_PLAN-queued.
- **Cody discovery requires session restart.** `~/.claude/agents/*.md` is loaded at Claude Code session start, not hot-reloaded. New agents don't appear in `/agents` until the next `/clear` or restart. Documented in the home AGENTS.md is implied; this is a Claude Code harness behavior, not an antcrate constraint.
- **Registry domain field naming.** Registry stores `parent` (legacy field name from when AntCrate organized projects under domain dirs); CLI flag is `--domain`. `ac_registry_get "$proj" parent` is the correct lookup.
- **Conflict on existing hook content.** `ac_hook_install` refuses-by-default on existing-but-different content (no `--force`) so accidental overwrites don't happen. `--force` backs up to `<hook>.bak.<UTC-ts>` then overwrites. Autoinstall handles refusal gracefully — surfaces `refused` in the summary, still runs the env-scan apply step.
- **Empty-string trap on `ac_registry_get`.** Returns empty string (not error code) when a field is missing. New libs use `[[ -z "$x" ]] && x="default"` rather than `||` fallback.

**End-to-end smoke (live):** `antcrate --register lc_test /tmp/lc_test --domain projects` on a freshly-`git init`'d directory produced all five artifacts in one command — Cody pointer, attempt counter, four .md skeletons (token-substituted with `lc_test` / `projects` / `2026-05-07`), executable `pre-commit` hook, and three-line `.gitignore`. No manual flag invocations needed.

**What's left for the agent layer:**

- **#93 `--delegate <project> <task>`** — Clyde-side wrapper that increments the attempt counter, refuses on >=3, emits a delegate event, prints the delegation block. Last piece. Without it, Cody tracks attempts inline only (per the system prompt) — there's no shared file:line counter that Clyde and Cody both honor.

**HOOK_PLAN follow-ups queued (not ticketed yet):** composite pre-commit umbrella template, `--hook-remove`, `--hook-bypass` with audit log + AGENTS.md rule, `--hook-debug` re-run with annotation, `--start --hooks <preset>` auto-install on scaffold.

---

## 2026-05-05 — Trio pass: `--commit -y` (#83) + `--info` (#82) + post-push verify (#87 Shape B)

Three small flags landed together. None large enough to merit its own pass; bundling reduces commit overhead and keeps the dispatch table coherent.

**`--commit -y` (#83).** The `ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit ...` muscle-memory pattern was clutter. Added `-y` to the inner-loop parser of `--commit` (mirroring the existing `--pp -y` shape). Dispatch reuses the global `AUTO_YES` variable: when set, the commit case prefixes `ANTCRATE_COMMIT_PREAPPROVED=1` to `ac_commit_run`. No new tests — the env-var path already had coverage; the wrapper-level wiring is integration-tested via the friendly_cars onboarding flow.

**`--info <project>` (#82).** New function `ac_registry_info` in `lib/registry.sh` (kept colocated with the other read-only registry helpers; didn't justify a new file). Output:
```
project    : friendly_cars
path       : /home/twntydotsix/projects/friendly_cars
domain     : projects
git_remote : (none)
linked     : (none)
removals   : 0 tracked
backups    : 2
last_commit: 2ccaaeb chore(tree): stabilize tree.mmd post-#81 fix
branch     : master
working    : clean
```
Reads the registry record + counts `~/.antcrate/backups/<project>/*.tar.gz` + (if git repo) reports `last_commit`, `branch`, `working clean/dirty`. Replaces the `jq '.projects.<n>' ~/.antcrate/registry.json` pattern that ran twice this session and is the most common project-scoped read. Five new tests in `tests/registry.bats` cover the formatted-output contract, error paths (unregistered, missing name), the git-repo branch (clean), and the dirty-tree branch.

**Post-push verify (#87, Shape B).** Picked Shape B over a new `--ship` flag — smaller surface, every existing `--pp` invocation gets the safety net for free. Added to `lib/git_triage.sh` `ac_git_push` post-success path: read local HEAD, read `@{u}` (upstream tracking ref), compare. Match → print `verify: <upstream> in sync at <SHA>`. Mismatch → `ac_warn` with both SHAs. No extra network call — the upstream ref was just updated by the successful `git push`. Mismatch is rare (push succeeded, ref-update is atomic) but possible if a force-push from another client races; worth knowing.

**Tests landed: 199 → 204** (5 new `--info` tests in `tests/registry.bats`). Shellcheck clean. No regressions in 199 prior tests. Live smoke verified all three: `antcrate --info friendly_cars` printed the formatted record; `antcrate --commit antcrate -m "..." -y` committed without prompt; the `--pp` verify line is exercised on every push (this commit's push will demonstrate it).

**Soft-reset note.** During the smoke test I accidentally committed the trio-pass WIP with the literal message `"smoke (should be no-op)"`. Caught immediately, `git reset --soft HEAD~1` un-committed (changes preserved as staged), redid with the proper message + docs included. No history rewrite past `HEAD~1`; nothing pushed. Filed mentally as a UX note: smoke-testing destructive-by-accident commands against a real repo needs scoping discipline (use a temp tree like the `--bootstrap` smoke test did).

**What this unblocks.** The trivials-first pass clears the easiest leverage points before #76 (`--mirror` + landmarks), which is the next non-trivial. `--info` will be the natural fall-back when reading a project's state, replacing several muscle-memory `jq` patterns. The `verify` line in `--pp` makes "did my push really land?" answerable without a separate `git ls-remote`.

---

## 2026-05-05 — `--git-init` (#77) + `--bootstrap` (#80) one-liner ship

The friendly_cars onboarding pass on 2026-05-04 ran a manual sequence: `git init` → `git config core.hooksPath` → write `.gitignore` → `ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit ... --all-tracked`. Asked to fold that into a single flag. Two new libs cover the surface:

**`lib/git_init.sh` — `ac_git_init <project>`**

Local-only counterpart to `lib/gh.sh`'s `--gh-init`. Idempotent: if `.git` already exists, log + return 0. Otherwise `git init -q` plus `git config core.hooksPath .githooks` when `.githooks/` is present. Errors on unregistered project / missing path on disk. Five exit paths, all tested in `tests/git_init.bats` (7 tests, all green).

**`lib/bootstrap.sh` — `ac_bootstrap <project> [<msg>] [<with_remote>] [<visibility>]`**

Composes:
1. `ac_git_init` (idempotent)
2. Default `.gitignore` (never overwrites existing) — patterns mirror `ac_commit_secret_match` (`.env`, `*.pem`, `*.key`, `id_*`, `*.p12`, `*.pfx`, `secrets.y*ml`, `*.credentials`, `credentials.json`, `.netrc`) plus the `lib/cleanup.sh` skip-prune giants (`node_modules/`, `__pycache__/`, `.venv/`, `venv/`, `.tox/`, `.pytest_cache/`, `.mypy_cache/`, `.cache/`, `.turbo/`, `.nyc_output/`, `coverage/`, `dist/`, `build/`, `.next/`, `target/`). The two lists agree by construction so the gitignore and cleanup logic don't drift.
3. **Pre-stage** `ac_diagrams_auto_regen` — twice. The first regen creates `docs/diagrams/tree.mmd`; the second regen sees it and converges. Without the double-call, the staged tree.mmd is one node short and a second `--bootstrap` call would commit a "+tree.mmd self-reference" diff, breaking idempotency. Bug #81's skip-write-when-stable then makes the post-commit regen a no-op for free.
4. `ac_commit_run` with mode `"all"` — auto-message `feat(init): bootstrap <project> via antcrate` if `-m` omitted, custom message if given. Uses `ANTCRATE_COMMIT_PREAPPROVED=1` inline (rule #13 sanctioned, env-var bypass for non-TTY). Once #83 lands, this becomes a `-y` passthrough.
5. Optional `--with-remote` chains `ac_gh_init_repo` with `private` default (per memory + queued rule #15). `--public` is opt-in.

All five steps idempotent. Re-running on a clean tree commits nothing and returns 0. Verified via bats test #2 (idempotency: SHA stable across two calls) and live smoke test against a temp project (`mktemp -d` + register + bootstrap + bootstrap → 1 commit total).

**Wrapper wiring (`bin/antcrate`):**
- Sourced both libs after `cleanup.sh`
- Help text (lines ~99–104) shows both flags with the inheritance arrow
- Inner-loop parser for `--bootstrap` accepts `-m "<msg>" --with-remote --public --private`, mirrors the `--commit` pattern
- Dispatch wraps `ac_bootstrap` in `ac_with_lock` (commit needs the lock; bootstrap composes commit) and runs `ac_diagrams_auto_regen` post-call as belt-and-suspenders (no-op given the in-function pre-stage regen + #81)
- New variable: `BOOTSTRAP_WITH_REMOTE=""`

**Tests landed (16 new, 182 → 199 total):**
- `tests/git_init.bats` — 7 tests covering all exit paths
- `tests/bootstrap.bats` — 10 tests:
  - happy path (creates .git + .gitignore + commit)
  - idempotent on second call (SHA stable)
  - **leaves working tree clean after first commit (no tree.mmd loop)**
  - respects existing .gitignore (no overwrite)
  - `-m` custom message
  - auto-message when `-m` omitted
  - errors when unregistered
  - errors when name missing
  - secret-pattern guard catches `.env` not gitignored (refuses to commit)
  - works on a tree with one file

Shellcheck clean. Live smoke test passed end-to-end with isolated `ANTCRATE_HOME` + `ANTCRATE_ROOT` so the real registry stayed untouched.

**What this unblocks.** The friendly_cars onboarding sequence now collapses to:
```bash
antcrate --register friendly_cars ~/projects/friendly_cars --domain projects
antcrate --bootstrap friendly_cars
```
Plus future `--init` (#84) which would orchestrate `--start || --register` + scaffold `CLAUDE.md` + `--bootstrap` in one call. The composition cascade keeps each layer testable in isolation.

---

## 2026-05-05 — Bug #81: tree.mmd timestamp non-idempotency fixed

`ac_diagrams_auto_regen` was rewriting `docs/diagrams/tree.mmd` on every invocation because the file's first line is a `%% <project> tree — generated <ISO-8601>` header. Fresh timestamp every regen = file always "modified" by git's eyes. Symptom: every `antcrate --commit <project>` triggered a post-commit auto-regen, which dirtied tree.mmd, which appeared in the next `git status`, prompting another commit. Infinite loop.

Surfaced concretely during the friendly_cars init pass on 2026-05-04: after the initial commit landed, `git status --short` showed `M docs/diagrams/tree.mmd`. Diff between commit-time and post-commit content was a single line — the timestamp. The same loop is masked in antcrate's own repo only because the user accepted the auto-commit as a one-shot.

**Fix shape: skip-write-when-stable, not strip-the-timestamp.**

Considered three approaches:
- *Drop the timestamp from the header* — simplest, but the timestamp is genuinely useful "last regen at" metadata users want.
- *Replace timestamp with content hash* — also stable, but the hash is only meaningful relative to the file you're computing it from; not human-readable.
- *Compare new content modulo line 1, write only if differs.* This preserves the timestamp value when it's earned (content actually changed) and skips the write entirely when nothing semantic changed.

Picked door #3. New helper `ac_diagrams_write_if_changed` in `lib/diagrams.sh`:
- Reads stdin into a temp file
- If destination exists and `tail -n +2` of both files matches via `diff -q`, removes the temp and returns success — *no write, no mtime bump, working tree stays clean*
- Otherwise `mv` the temp to destination

`ac_diagrams_auto_regen` now pipes both writes through the helper:
```bash
ac_diagrams_registry_to_mermaid 2>/dev/null | ac_diagrams_write_if_changed "$out"
ac_diagrams_tree_to_mermaid "$project" 2>/dev/null | ac_diagrams_write_if_changed "$tree_out" || true
```

Four new bats tests:
- `write_if_changed: creates file on first write`
- `write_if_changed: skips write when only the header (line 1) differs`
- `write_if_changed: writes when body differs (header may also differ)`
- `auto_regen: tree.mmd is stable across consecutive regens (no timestamp loop)` — uses two warm-up regens to settle (the first regen creates `tree.mmd`, which the second sees as a new tree node) before the stability check.

Verified live on friendly_cars: after installing the patched lib via `--selfinstall`, `antcrate --backup friendly_cars` triggered auto-regen but `git status --short` came back empty. Loop confirmed broken.

**Why the helper is internal.** It bypasses the contract that "every auto-regen produces a fresh file." The Reason: line in its header documents that the bypass is the whole point — the contract was the bug. Future libs that reach for "compare-then-skip" semantics should consult this pattern.

Test count: 162 → 166. Shellcheck clean. Files changed: `lib/diagrams.sh`, `tests/diagrams.bats`. No public-API change.

Pairs with task #80 (`--bootstrap`): without this fix, every `--bootstrap` first-commit would leave the tree dirty, defeating the "one-liner" UX goal.

---

## 2026-05-04 — `--cleanup` + `--watch` + activity event stream ship (file-bus first, ztcp queued)

After `--ingest` landed earlier today, the user pointed back at the live-watch + cleanup conversation we'd had: cleanup protocol per-project, agents emit kind-tagged events, registry tracks recent removals, watch view shows colored tree with 1s deletion afterglow. This pass implements that whole arc — minus the optional ztcp fast-path, which stays queued behind the file bus per the design wager. Single user request: "go top to bottom; --ingest first." Ingest is in; this is the next layer.

**The architecture, restated.** Disk is the log, socket is the signal. The durable record is `~/.antcrate/events/<project>.jsonl` — append-only JSONL, one event per line, every event survives crashes, every consumer can replay. Watch readers tail it. The optional ztcp broadcast is a notification-only fast-path that doesn't change the record; if no listener is attached, no event is lost. This commit ships the disk side. ztcp lives in `AGENT_SPEC.md` (paper-only).

**`lib/events.sh`.** Five event kinds — `modify`, `read`, `think`, `delegate`, `delete` — chosen to cover the four agent-state transitions that matter for live awareness: editing files, reading files, agent reasoning (no FS event, must be explicitly emitted), and handoff between agents. Default TTLs differ by kind: modify=5000ms (changes are interesting longer than reads), read=2000ms, think=3000ms, delegate=5000ms (handoffs deserve more attention), delete=1000ms (the tombstone afterglow the user explicitly asked for, "for 1s so it is also visually confirmed"). Schema: `{ts, ts_ms, kind, path, agent, ttl_ms, label?}`. `ts_ms` is included alongside `ts` so TTL filtering can be done with integer math via jq without re-parsing the ISO timestamp every time.

**`lib/watch.sh`.** Pure bash, no ncurses, no TUI library — the user explicitly preferred lightweight + customizable over TUI overhead. Two-step renderer: (1) build an overlay map by walking active events, propagating each event up to all ancestor directories (so coloring a deep file also paints the dir chain back to the root) plus a `__root__` row carrying the highest-severity kind anywhere; (2) walk the tree, lookup overlay per path, paint with the matching ANSI escape. Severity ordering deliberate: delete > modify > delegate > think > read. When a directory has multiple descendants with different kinds, the highest-severity kind wins so the eye is drawn to the most disruptive event. Tombstones are ANSI `\033[91;9m` (bright red + strikethrough) — distinct from regular delete and impossible to confuse with modify. `--once` mode prints one frame and exits, used by tests + scripting; the loop mode does clear-and-redraw at 200ms via a hardcoded timer (no inotify dependency for the renderer — the events file itself is updated atomically and the loop reads the latest tail every tick).

**`lib/cleanup.sh`.** The classifier scans only two categories in v1: `test-tmp` (caches, snapshots, build artifacts that are safe to nuke) and `empty-dir`. Build outputs (`dist`, `build`, `target`) and gitignored-on-disk are deliberately omitted — `.gitignore` can include `.env*` and other secrets, and an auto-classifier that suggests `.env` files for deletion is a footgun. The pattern set is hardcoded and explicit: directory exact-names plus a tight glob list for files. Skip-prune covers `.git`, `.github`, `.githooks`, `node_modules` at any depth (basename match, not path-prefix — earlier draft used `-path` and missed the root-level `.git`).

**Apply flow** is rule-#1 native: each ID is resolved against the persisted list at `~/.antcrate/cleanup/<project>.list`, then run through `ac_safety_guard_destructive` (which itself does mandatory backup + interactive approval, with the existing `ANTCRATE_REMOVAL_PREAPPROVED=1` bypass for non-interactive contexts). On success, the path is removed, a `delete` event fires with `--label <category>` (so the watch view paints `test-tmp` deletions distinctly from `empty-dir` deletions), and `projects.<name>.recent_removals` gains one entry capped at `ANTCRATE_CLEANUP_RECENT_CAP` (default 50). The recent-removals log is the registry's contribution to the user's "registry can keep track of this information easily" requirement.

**`lib/backup.sh` extension.** `ac_backup_create` previously hard-required `[[ -d "$path" ]]` and refused single files. Cleanup needs to back up files like `scratch.test.tmp` before removal — the rule #1 floor must apply uniformly to files, not just directories. tar handles both equally; the only change was widening the existence check from `-d` to `-e`. This is a small but meaningful rule #1 strengthening: every destructive op (cleanup, supersedes, archive, remove) now backs up regardless of file/dir distinction.

**Lib header convention codified.** When the user asked what the "Public API" comment block meant, the question pulled out an inconsistency: I'd added headers to the new libs (ingest, events, watch) but the existing 17 libs use only per-function comments. The user picked option 2: keep the convention, propagate to existing libs over time, with security in mind. The standardized format names public entry points, lists internal helpers, and adds a `Reason:` line specifically when an internal would bypass an invariant if called directly. Example from cleanup.sh: the internal scanners produce raw rows with no IDs; only `ac_cleanup_classify` dedupes, numbers, and persists. An agent calling `ac_cleanup_scan_test_tmp` would skip that contract. The Reason line documents why those helpers are private without depending on naming conventions. Propagation to the existing 17 libs is task #69 — separated so this commit stays focused.

**Tests.** 27 new bats across three files: events.bats (10 tests — emit/active/TTL/malformed-line tolerance/kind validation/agent override/label propagation), watch.bats (8 tests — render layout/no-color/colored kinds/severity propagation/depth limit/unknown project), cleanup.bats (9 tests — classify/persist/empty-project/apply-with-backup/event-emission/registry-recent-removals/unknown-id/comma-separated/skip-prune). Combined with prior suites: 162/162 bats green, shellcheck clean.

**What's queued next.** Task #69 (header propagation), task #58 already done. Next major surfaces: `AGENT_SPEC.md` (the multi-agent delegation paper — would consume the events stream + add inboxes/outboxes + ztcp fast-path), `QUEUE_SPEC.md` (the multi-machine bundles repo). The user has a project (`friendly_cars`) ready for an end-to-end test of the antcrate stack — that's the immediate priority post-commit.

---

## 2026-05-04 — `--ingest` consumer ships (BUNDLE_SPEC v1.0 end-to-end on this machine)

The bundle pipeline now has a working consumer end. With BUNDLE_SPEC v1.0 spec'd back on 2026-04-28 and four reference bundles already on disk, this pass closes the consumer loop: `antcrate --ingest <bundle-path>` validates, materializes, registers, and surfaces a registered project ready for development.

**`lib/ingest.sh` (~400 lines).** Organized into five sections: validation, source materialization, opaque-file copy, relationship handling, top-level orchestrator. Validation runs §4 in declared order (manifest existence → JSON parse → spec_version major → required fields → name rules → domain shape → source.type sub-fields → registry collision → reachability), and any failure short-circuits before any disk write outside tmp. The orchestrator (`ac_ingest`) writes `STATUS=claimed` only after validation passes; transitions to `ingested` on success or `failed: <reason>` on any later failure.

**All four `source.type` variants implemented.**
- `none`: empty scaffold, just `mkdir -p target`. Used by theoretical bundles.
- `git`: `git clone -q [--branch <b>] <url> <target>` then optional `git checkout -q <commit>` for reproducibility. Local paths and `file://` URLs supported (test-friendly).
- `archive`: download via curl/wget OR copy local file/`file://`, optional sha256 verify, extract via `tar -xzf` (with `--strip-components=1` heuristic) or `unzip` fallback.
- `composite`: each sub-source materialized into a private staging dir, then `cp -rn` (no-clobber) merged into target in declaration order — first source wins on path conflicts. Matches BUNDLE_SPEC §2.2.

**Relationships honored.**
- `supersedes`: invokes `ac_safety_guard_destructive` against the existing project tree (AGENTS.md rule #1 — backup + approval gate). On approval, removes the existing tree + per-project skill (also backed up) and re-materializes under the same name. Sets `AC_INGEST_MODE=supersedes`.
- `extends`: refuses if the target project isn't registered; on success, redirects materialization to merge into the existing tree without re-cloning. Sets `AC_INGEST_MODE=extends`.
- `duplicate_of`: warning only, ingest proceeds.
- `depends_on`: warns if dep not registered, ingest proceeds.

**Opaque file copy** (per BUNDLE_SPEC §1, §5). `research.md → docs/`, `claude.md → CLAUDE.md`, `skill/ → ~/.claude/skills/<skill_name>/` (defaults to `<name>`, overrideable via `claude.skill_name`), `diagrams/* → docs/diagrams/`, `attachments/* → docs/attachments/`. Bundle contents outside `manifest.json` are never parsed — just routed.

**Wrapper wired** (`bin/antcrate`): `--ingest <bundle-path>` dispatches through `ac_with_lock ac_ingest "$NAME"`. Auto-regen lives inside `ac_ingest` itself rather than at the wrapper case — `AC_INGEST_NAME` doesn't survive the lock subshell, and `set -u` in the outer wrapper would fault on the unbound variable. Cleaner to keep all post-success bookkeeping inside the locked context.

**Test envs added.** `ANTCRATE_INGEST_OFFLINE=1` skips reachability checks (used by every test that doesn't actually want to hit the network). `ANTCRATE_INGEST_SKIP_FETCH=1` skips actual clone/download (validation-only smoke runs).

**22 new bats tests in `tests/ingest.bats`.** Coverage broken down: 13 validation tests (good path + every failure mode in §4), 5 ingest-success tests across source variants (none, git from local repo, archive from local tarball, composite, opaque-file copy), 3 relationship tests (supersedes with rule-#1 backup, extends merge, depends_on warning), 1 sha256 mismatch path. **135/135 bats passing** (was 113), shellcheck clean.

**Smoke test** against `assets/docs/examples/bundles/theoretical/` confirmed end-to-end: STATUS goes `ready → ingested`, registry entry created with `objective` field populated, research.md copied to `docs/research.md`, auto-regen fires (project's tree.mmd appears).

**Why this lands the highest-priority next-step.** state.md "Next steps" had `--ingest` as item #1 with everything else (queue, conclude, GitHub auth model, per-project skill composition, LLM orchestrator hook) explicitly listed as downstream. Without the consumer end, the producer (research-AntCrate, eventually) had nothing to talk to; the spec was authored but unimplemented. With `--ingest` shipped against local-path bundles, the producer side can be developed against a known-good consumer, and the GitHub-backed queue (`--queue` / `--next` / `--conclude`) becomes the next focused pass — adds the bundle source (a remote git-backed bundles repo) on top of an already-working consumer.

**Why test envs matter.** Bats can't reasonably hit github.com from CI, and `git ls-remote` adds non-determinism to the test run. The `ANTCRATE_INGEST_OFFLINE=1` flag was carved out so tests describe the *consumer logic*, not network state. The producer side will need its own offline mode (TBD) when it's spec'd in `QUEUE_SPEC.md`.

**What's queued next** (per state.md): `QUEUE_SPEC.md` (bundles repo + `queue.json` + per-bundle `STATUS` semantics for multi-machine coordination), `--queue` / `--next` / `--conclude` flags, GitHub auth model (fine-grained PAT scoped to `research-bundles`), per-project skill composition pattern (Phase 3 doc), local Ollama producer hook (Phase 4).

---

## 2026-05-01 — Skill polish + DIAGRAM_PLAN.md captures case-by-case diagram selection

After the hooks pass + GH_PIPELINE_PLAN.md landed, the user requested a session pause to polish the skills themselves. The skill files (`SKILL.md`, `composes.md`, `stack.md`) had drifted significantly from current reality — they were last touched on 2026-04-27, well before the daemon hook, `--commit` wrapper, Gateway Law (rule #12), config-human-only (rule #13), BUNDLE_SPEC v1.0, hook plan, gh-pipeline plan, and POST_DEV_BACKLOG all landed. This pass rewrites the three skill files to match current state and adds `DIAGRAM_PLAN.md` to capture an under-articulated design surface the user flagged: diagrams are first-class AntCrate output, not an external tooling concern.

**`SKILL.md` rewritten.** The old version pointed at a `project-forge` skill that doesn't exist on this machine and at `/mnt/skills/...` paths from a different setup. The new version:
- Trims the orientation list to the four files an agent should genuinely read first: `assets/docs/PATTERNS.md` (flag-by-intent index), `state.md` (truth-of-now), `assets/code/AGENTS.md` (with rules #1, #10, #11, #12, #13 named explicitly), and the top of `ledger.md`.
- Lists every current `lib/*.sh` module with a one-line purpose so an agent doesn't have to grep to learn the surface.
- Lists every current `assets/docs/` design doc with status (shipped / queued).
- Names the GitHub repo URL.
- Codifies the maintenance protocol with actual antcrate flags (`--ci`, `--commit`, `--pp`) instead of the now-defunct "activate project-forge" handoff.
- Expands trigger phrases to include the new surfaces (Gateway Law, BUNDLE_SPEC, research-bundles, HOOK_PLAN, GH_PIPELINE_PLAN, live-tree auto-regen, secret-pattern guard, sub-branching, addressing).

**`composes.md` rewritten.** The old version referenced six skills (`project-forge`, `research-recon`, `research-swarm`, `docx`, `pdf`, `pdf-reading`, `frontend-design`) that don't exist for this user, plus an "activation protocol" referencing `/mnt/skills/user/<n>/SKILL.md` paths from a different filesystem layout. The honest replacement covers:
- **What's auto-loaded every session**: the memory files at `~/.claude/projects/-home-twntydotsix/memory/` (with MEMORY.md as the index — three feedback memories named explicitly), and `~/CLAUDE.md` (the home-directory orchestration layer).
- **Available harness skills**: the actual list (`update-config`, `schedule`, `loop`, `fewer-permission-prompts`, `claude-api`, `security-review`, `review`, plus tangentials). Reframed as "AntCrate cooperates with these on demand" rather than "AntCrate depends on these."
- **Future per-project skill composition**: when `--ingest` ships, the runtime composition becomes `antcrate skill (orchestration) + <project> skill (knowledge) + <project>/CLAUDE.md (conventions)`. Captured as the Phase-3 design target.

**`stack.md` updated.** Added: pinned `bats-core` 1.13.0 + `shellcheck` 0.10.0 (the actual versions used in `--ci` today), `gh` as a required dep (was missing — needed for `--gh-init` and the queued gh-pipeline flags), the full current `lib/*.sh` enumeration (was a 4-module summary, now lists all 17), the `.github/workflows/` and `.githooks/` directories, the installed-layout section (`~/.local/bin`, `~/.local/share/antcrate/`), the reserved `_archived` registry parent value, the bypass env vars (`ANTCRATE_REMOVAL_PREAPPROVED`, `ANTCRATE_COMMIT_PREAPPROVED`, `ANTCRATE_ALLOW_OUTSIDE_ROOT`) with rule #13 callout, the auto-regen / debounce env vars (`ANTCRATE_AUTO_DIAGRAMS`, `ANTCRATE_TREE_DEBOUNCE_MS`), `ANTCRATE_SELFSRC` (set by installer for `--selfsrc`/`--selftest`/`--selfedit`), and AGENTS.md rule numbers most cited at runtime.

**Why I dropped `project-forge` specifically.** The user asked the rationale explicitly. Three reasons: (a) the skill doesn't exist on this machine — the actually-available skills are `update-config`, `keybindings-help`, `simplify`, `fewer-permission-prompts`, `loop`, `schedule`, `claude-api`, `antcrate`, `init`, `review`, `security-review`. Pointing at a non-existent skill is a footgun: a future agent either tries to invoke it and fails, or skips the maintenance step entirely. (b) What `project-forge` was supposed to do — append to `ledger.md`, update `state.md`, persist cross-session learnings — is now done directly by Claude Code with `Edit`/`Write`, plus the memory system handles the durable cross-session piece. The middle layer collapsed. (c) The pattern matches AntCrate's design philosophy: if a workflow can be expressed entirely in antcrate flags + native edits, don't insert a third party.

**`DIAGRAM_PLAN.md` added.** The user pushed back on my framing of diagram tooling as "graceful-degradation external dependency" in `composes.md` and asked for diagrams to be treated as a first-class AntCrate feature with case-by-case tool selection per project type. The new plan captures:
- **What's shipped today**: universal pair (`~/.antcrate/registry.mmd` + `<project>/docs/diagrams/tree.mmd`) auto-regenerated everywhere — wrapper-side on every mutating action AND daemon-side on every direct filesystem event under a registered project. Architecture seed dropped on `--start`. `--diagrams` bulk-renders to SVG when tools present.
- **Selection inputs (queued)**: bundle manifest hints (`manifest.stack`), project domain, file extensions present, explicit user `--diagram-preset` choice. Priority order codified.
- **Preset library (queued)**: ten presets covering the common cases — `bash` (call graph from shell function defs), `node`/`js` (Madge dep graph), `svelte` (`node` + request-flow sequence via PlantUML), `python` (pyreverse class/package), `rust` (cargo-depgraph), `go` (godepgraph), `terraform`/`iac` (Inframap), `k8s` (k8sviz), `db` (SchemaSpy live or DBML text), `cloud-arch` (mingrammer/diagrams Python DSL).
- **Wrapper flags (queued)**: `--diagram-preset <project> [<preset>]`, `--diagram-detect <project>`, `--diagrams <project> --refresh-all`, `--start --diagrams <preset>` for auto-install on scaffold.
- **Registry schema extension**: `projects.<name>.diagrams = { preset, active, last_regen }`. Backward-compatible (missing field → preset defaults to `auto`).
- **Surface boundaries**: won't fabricate structure, won't auto-publish to external services, won't regenerate on every keystroke (debounced), won't require renderers (Mermaid renders inline on GitHub).
- **Order of implementation**: 7-step sequence starting from preset infrastructure → first non-trivial preset (`bash`, dogfooded against `lib/registry.sh`) → auto-detection → `--start` integration → stack-specific presets in priority order → bundle-driven selection (depends on `--ingest`) → `--refresh-all`.

`DIAGRAM_AUTOMATION_GUIDE.md` is reframed as the underlying *tool catalog* (Quick Picker, the seven core tools, source-of-truth-by-type sections); `DIAGRAM_PLAN.md` is the AntCrate-specific *selection logic* on top.

**Why this matters for the bigger arc.** The skill files are what loads into a future agent's context first. If they're stale, every subsequent decision compounds the drift. After this pass, an agent landing on antcrate cold will see: (a) accurate orientation pointing at the right files, (b) the AGENTS.md rules named explicitly, (c) every current surface enumerated with status, (d) the maintenance protocol matching what actually works today. The DIAGRAM_PLAN piece in particular closes a roadmap gap: previously the "what's next for diagrams beyond registry/tree" question was implicit; now it's a captured spec the next focused implementation pass can pick up cleanly.

**Files touched:**
- `SKILL.md` (rewritten, was 47 lines / 5KB → ~110 lines / 7KB)
- `composes.md` (rewritten)
- `stack.md` (rewritten)
- `assets/docs/DIAGRAM_PLAN.md` (new, ~210 lines)
- `state.md` (tenth pass entry)
- `ledger.md` (this entry)

`antcrate --ci`: shellcheck **clean**, bats **109/109 passing** (no test changes; this pass is docs-only).

---

## 2026-05-01 — Hooks: CI workflow + opt-in local pre-commit + read-only inspection (`--hooks` / `--hook-log`)

Closed the "no enforcement layer" gap before the antcrate skill repo's first batch of substantial commits ships to GitHub. Until now, every CI signal came from the human running `antcrate --ci` by hand. With this pass, both ends are covered: a GitHub Actions workflow runs the same checks server-side on every push/PR, and an opt-in local pre-commit hook (versioned with the repo, enabled per-clone) catches issues before the commit even completes.

**What landed.**

1. **`.github/workflows/ci.yml`** — runs on push to `master`/`main` and on PRs. Installs `jq` + `shellcheck` (via apt), `bats-core` (clone + upstream installer), then `bash assets/code/install.sh`, then `$HOME/.local/bin/antcrate --ci`. The same command path the local hook uses, so green here = green there.

2. **`.githooks/pre-commit`** — opt-in. Enable per-clone with `git config core.hooksPath .githooks`. Runs `antcrate --ci`, tees output to `<repo>/.git/antcrate-hook.log`. Refuses with a clear message if `antcrate` isn't on PATH (so a fresh clone without an install doesn't fail mysteriously). Writes a timestamped `pre-commit] PASS` or `pre-commit] FAIL (exit N)` line on every run, plus a hint pointing at `antcrate --hook-log <project>`.

3. **`lib/hooks.sh`** — three small helpers, all read-only:
   - `ac_hooks_dir <project_path>` — resolves the effective hooks dir. Honors `core.hooksPath` whether relative (resolved against project root) or absolute. Falls back to `<project>/.git/hooks`. Returns nonzero for non-git paths.
   - `ac_hooks_list <project>` — lists active hooks (filters `*.sample`). Header line announces the effective dir + whether antcrate's `.githooks` opt-in is enabled (matched by literal `core.hooksPath=.githooks`). Tab-separated output: name, status (`active` if executable, `disabled` otherwise), absolute path.
   - `ac_hooks_log <project> [lines]` — tails `<project>/.git/antcrate-hook.log`. Friendly notice when no log exists yet (so first-time users know the file appears once a hook actually runs).

4. **Wrapper flags wired:**
   - `--hooks <project>` — read-only inspection.
   - `--hook-log <project> [lines]` — debug a blocked commit. Default 50 lines.

5. **`assets/docs/HOOK_PLAN.md`** — design contract for the queued surface. Captures the install/remove/bypass plan in enough detail that a follow-up session can implement it without re-deriving the design. Sections: shipped today, queued (template library + 5 new flags + AGENTS.md rule for bypass), surface boundaries (what hooks WILL NOT do), versioning + portability, proposed implementation order.

6. **PATTERNS.md** — new "Hooks" section with the two shipped flags and an explicit pointer at `HOOK_PLAN.md` for the rest.

7. **README.md** — "Local pre-commit hook (opt-in)" + "Continuous integration" sections explaining the enable steps and where the CI lives.

**Tests added.** 12 new bats tests in `tests/hooks.bats` covering: `ac_hooks_dir` (default, relative core.hooksPath, absolute core.hooksPath, non-git path); `ac_hooks_list` (default dir + sample filter, `disabled` status for non-exec, antcrate opt-in indicator, unknown project, missing hooks dir); `ac_hooks_log` (no log yet, tail with line count, unknown project). **109/109 passing** (was 97). Shellcheck clean.

**Why split now: shipped vs queued.** The full hook-management surface (install/remove with rule-#1 backup integration, single-shot audit-logged bypass, hook templates per stack, auto-install on `--start`) is a multi-pass feature that needs its own focused implementation session. Shipping read-only inspection + the two safety nets (CI workflow + opt-in local hook) right now means today's batch of substantial uncommitted work (`--commit`, daemon hook, BUNDLE_SPEC) lands behind a real CI gate, with debuggability for blocked commits, without coupling to the larger hook-management refactor. HOOK_PLAN.md preserves the full design so the next pass can pick up cleanly.

**Self-host check.** `antcrate --hooks antcrate` correctly reports `hooks-dir: /home/twntydotsix/.claude/skills/antcrate/.git/hooks (default)` — the antcrate repo itself hasn't enabled `core.hooksPath=.githooks` yet (will do so after this batch is committed, so the very first commit still goes via `antcrate --commit` + `antcrate --pp` and the hook activates from the next commit forward). `antcrate --hook-log antcrate` correctly prints the friendly "no hook log yet" notice. End-to-end behavior matches design.

**Files touched (this pass):**
- `assets/code/lib/hooks.sh` (new)
- `assets/code/bin/antcrate` (sourced lib/hooks.sh; usage; arg parser; dispatcher)
- `assets/code/tests/hooks.bats` (new, 12 tests)
- `.github/workflows/ci.yml` (new)
- `.githooks/pre-commit` (new, executable)
- `assets/docs/HOOK_PLAN.md` (new)
- `assets/docs/PATTERNS.md` (Hooks section)
- `README.md` (hook + CI sections)
- `state.md` (ninth pass entry)
- `assets/docs/POST_DEV_BACKLOG.md` (added install.sh sed-i and `--pp` secret-guard bypass items)

---

## 2026-05-01 — Daemon hook for live-tree auto-regen shipped + verified on real hardware

Closed the last gap in the diagram-automation story. Until now, `ac_diagrams_auto_regen` only fired from mutating wrapper actions (`--start`, `--touch`, `--rename`, etc.). Direct edits inside a registered project — vim, an editor outside the wrapper, `git checkout`, anything that didn't go through `bin/antcrate` — would leave `tree.mmd` stale until the next wrapper-side mutation. This is the prerequisite for the per-project skill composition pattern (Phase 3): a project's `docs/diagrams/tree.mmd` and `~/.antcrate/registry.mmd` need to be a function of registry+disk state, not a snapshot from "whenever someone last ran a flag."

**Implementation.**

1. New helper `ac_diagrams_resolve_project_for_path <abs_path>` in `lib/diagrams.sh`. Walks the registry and returns the project name whose registered `path` is the **longest prefix** of the input. Longest-prefix-match handles sub-branches correctly: an event under `~/projects/parent/child/x.sh` resolves to `child`, not `parent`. Returns nonzero (and emits nothing) for paths outside any project. Tolerant of trailing slashes; rejects empty input.

2. `bin/antcrated` rewritten to fire two parallel paths per event:
   - **Schema-dispatch path** (existing) — basename decodes per Positional Extension Schema → `antcrate --pipe-file`.
   - **Live-tree auto-regen path** (new) — any structural event inside a registered project tree → `ac_diagrams_auto_regen <project>`.

   Both paths share the same swap/dot-file early filter (`.*|*~|*.swp|*.swo|*.swx|*.tmp|"4913"`) so editor noise never reaches either dispatcher. Schema path retains its per-basename debounce; tree-regen path adds a separate per-project debounce (`ANTCRATE_TREE_DEBOUNCE_MS`, default 600ms) so bursts (`git checkout`, batch saves, scaffolds) coalesce into one regen.

3. Watched events broadened from `create | close_write | moved_to` to also include `moved_from` and `delete`. Required so renames and removals refresh the tree (a rename is a `moved_from` + `moved_to` pair; without `moved_from` the source dir's loss is invisible). Directory events (`CREATE,ISDIR`, `DELETE,ISDIR`, `MOVED_*,ISDIR`) flow into the tree-regen path but are still filtered out before schema dispatch (the schema applies to files only).

4. **Daemon-local registry cache.** Per-event resolution would otherwise be O(N projects × jq invocations). The daemon keeps `(REG_NAMES[], REG_PATHS[])` in memory and reloads only when `stat -c %Y` on `registry.json` shows a newer mtime. One jq call per registry change, zero per quiet event.

**End-to-end validation on real hardware** (8 tests, all green):

1. **New file via `touch`** — `handler.sh` appears in `tree.mmd` within the debounce window. Follow-up CLOSE_WRITE on tree.mmd itself is debounce-dropped (no cascade).
2. **`mkdir lib/`** — `lib` shows as `[/lib/]` (parallelogram) via `CREATE,ISDIR`. Confirms ISDIR events reach the tree path even though they bypass schema dispatch.
3. **Editor swap files** (`.editorswap.swp`, `foo~`) — early-filtered, no regen, no tree pollution. Daemon log silent on these.
4. **`rm handler.sh`** — `DELETE` event fires regen, file gone from tree.mmd.
5. **`mv main.sh entry.sh`** — `MOVED_FROM` fires regen, follow-up `MOVED_TO` is debounce-dropped within the same window. Net effect: tree shows `entry.sh`, `main.sh` gone.
6. **Burst of 5 appends** — 4 of 5 close_write events get debounce-dropped, single regen fires. Coalescing works.
7. **Orphan file in watched root but outside any project** (`~/projects/scripts/orphan-file.txt`) — event seen by daemon, but resolver returns no match, no `auto-regen tree` log line. Confirms the resolver's negative path.
8. **Registry-level diagram** — `~/.antcrate/registry.mmd` reflects all 4 registered projects (antcrate, test-scaffold, ac-validation-renamed, ac-livetest).

Daemon stopped cleanly via `SIGTERM`; PID file removed by `cleanup` trap.

**Bats coverage.** Six new tests in `tests/diagrams.bats` for `ac_diagrams_resolve_project_for_path`: file inside project, project root itself, path outside any project, longest-prefix wins for nested sub-branches, trailing-slash tolerance, empty input. Total: **78/78 passing** (was 72). `antcrate --ci`: shellcheck **clean** + bats **green**.

**Pre-delete verify gate adopted as standard practice.** Before invoking any `antcrate --remove` (which itself enforces AGENTS.md rule #1 backup+approval), the agent runs three independent checks: (1) `--status` shows the project registered, (2) `jq .projects[<name>]` matches the expected entry, (3) `find <path>` lists only files the test created. The output is shown to the user *before* the destructive command runs. This is one notch tighter than rule #1's interactive prompt: it ensures the prompt fires against the right target and that the agent has a coherent picture of what it's about to destroy. Codified in this entry.

**Why this matters for the bigger arc.** With auto-regen now firing on both wrapper-side actions AND raw filesystem events, an agent loading a project's per-project skill sees diagrams that match disk state. That's a hard prerequisite for treating per-project skills as reliable handoff artifacts in the bundle pipeline (BUNDLE_SPEC v1.0). Next implementation step is `antcrate --ingest <bundle-path>` against the four reference bundles in `assets/docs/examples/bundles/`.

**Files touched:**
- `assets/code/lib/diagrams.sh` (+33 lines: resolver helper)
- `assets/code/bin/antcrated` (rewritten: cache, two-path event handler, broadened events)
- `assets/code/tests/diagrams.bats` (+6 tests)
- Reinstalled via `antcrate --selfinstall` so `~/.local/bin/antcrated` and `~/.local/share/antcrate/lib/` reflect source.

---

## 2026-04-28 — BUNDLE_SPEC v1.0 drafted (consumer-side implementation deferred)

Wrote the typed handshake contract between the two AntCrate instances (research-AntCrate as producer, dev-AntCrate as consumer). The user's framing was explicit: this is a handshake between two equally complex systems, not a one-way data drop. The producer side has its own deterministic identity ("acquire deterministically"); the consumer side's identity is unchanged ("build deterministically"); the bundle is what binds them.

**Design decisions worth preserving:**

1. **`manifest.json` is the only file AntCrate parses.** Everything else in a bundle is opaque — copied to documented locations on ingest, never read or validated by the wrapper. This is deliberate: the research producer needs freedom to record arbitrary research artifacts (papers, captured articles, schemas, math notation, scanned diagrams) without bumping the spec. The *meaning* of the research belongs to whatever consumes it (Claude Code, in our case); AntCrate's job is just to route the bundle correctly.

2. **Four `source.type` variants from day one** rather than retrofitting them later: `git` (with optional commit pin), `archive` (tarball with optional sha256), `none` (theoretical / research-only — registers an empty scaffold), `composite` (multi-source merge with first-source-wins on path conflicts). The `none` variant matters: the user emphasized that research isn't only about repos, it's also articles, mathematical methods, theoretical proposals. A bundle with no baseline code is a first-class case.

3. **Status lifecycle baked into the spec** even though solo-developer with one consumer doesn't strictly need it. `ready → claimed → ingested → consumed`, plus `failed`. Spec'ing it now means a future multi-consumer setup or queue replay works without protocol changes. Single-line `STATUS` file alongside `manifest.json` keeps it git-trackable.

4. **`relationships` array** with four kinds: `duplicate_of` (informational, producer-side dedup), `supersedes` (replaces a registered project — triggers AGENTS.md rule #1 backup + approval), `extends` (adds research/scope to existing project, no re-clone), `depends_on` (informational only). The `supersedes` semantics are the tricky one — they're how a research producer can later say "the upstream we picked was abandoned, here's a healthier fork" without the dev side losing in-progress work.

5. **Validate-before-write contract.** Every validation step (manifest parses, required fields present, name rules, source reachability, name-collision check) runs before any disk side effects. A failed ingest writes nothing except optionally `STATUS = failed`. This mirrors the safety pattern from `ac_safety_guard_destructive`.

6. **Forward compatibility.** Minor `spec_version` bumps add optional fields; consumer ignores unknowns and warns once per ingest. Major bumps signal breaking changes; consumer refuses with a clear upgrade message.

**Reference bundles** (`assets/docs/examples/bundles/`):
- `git-pinned/` — full payload (manifest + research + claude.md + skill + diagram seed). Standard case, tasklite-flavored example.
- `theoretical/` — `source.type: "none"`, demonstrates a literature-review bundle for the submodular-scheduler design problem.
- `composite/` — two upstream sources (auth-starter + svelte-admin) merged into one project with a documented conflict resolution table.
- `supersedes/` — replaces the original tasklite bundle when its upstream goes stale; demonstrates how `relationships` interacts with rule #1.

All four manifests jq-validated for required fields. Empty placeholder dirs pruned.

**What was deliberately deferred:**
- Consumer implementation (`antcrate --ingest`) — wanted spec stability before code.
- Bundle signing (`signature` field) — punted to v1.1+ alongside cross-trust-boundary scenarios.
- "Bundle bundles" (campaign manifests grouping multiple bundles for atomic ingest) — punted to v1.1+; would benefit from one round of real-world ingest first to know what natural groupings look like.
- Live source tracking (`source.tracking: "head"`) — interesting for projects where the upstream evolves faster than research can re-bundle, but it complicates the reproducibility story.

**What we explicitly did NOT spec:**
- The research producer's internals. Whatever generates the bundle (Python, Claude Code with web tools, Ollama agent, human curator) is interchangeable as long as it conforms to BUNDLE_SPEC.md. AntCrate's job ends at "ingest a valid bundle"; the research-machine's AntCrate will have its own commands, but they're not part of *this* spec.

**Why this ordering matters.** The next implementation step is the consumer-side `--ingest` flag, which we can prove against hand-crafted local bundles before involving the GitHub-backed queue. That order isolates risk: get one machine's wrapper working with one local bundle, then layer queue/transport on top. The temptation was to start with the GitHub queue (because it's the visible new-shaped thing), but the queue is just a fancy way of selecting which bundle to hand to `--ingest` — `--ingest` is the actual semantic work.

---

## 2026-04-28 — Auto-regen of diagrams on every mutating action

Closed the Phase-2 design intent that was still open: diagrams now refresh themselves whenever the registry or a project's tree changes. Manual `--registry-diagram` / `--tree-diagram` flags remain as a fallback / repair path, but no human or AI agent has to remember to run them.

**Implementation.** New `ac_diagrams_auto_regen [project]` in `lib/diagrams.sh`. Behavior:

- Registry diagram (`~/.antcrate/registry.mmd`) regenerated unconditionally — single jq pass, cheap.
- Project tree diagram (`<path>/docs/diagrams/tree.mmd`) regenerated only when (a) project arg supplied, (b) project still in registry, (c) path still on disk. So `--archive` / `--remove` only refresh the registry view, since the project's tree no longer lives at its original path.
- Silent: all stdout suppressed via redirection, stderr to `/dev/null`, errors swallowed with `|| true`. A diagram refresh must never block or corrupt the action that triggered it. Critically, this preserves the `--touch` / `--mkdir` contract that prints the absolute path to stdout for shell composition (`Write "$(antcrate --touch ...)"`).
- Opt-out: `export ANTCRATE_AUTO_DIAGRAMS=0` skips both regens. Useful for batch scripted mutations where a single explicit regen at the end is preferable.

**Hook points.** All twelve mutating actions in `bin/antcrate` now call `ac_diagrams_auto_regen` after the underlying op succeeds: `start`, `register`, `branch`, `link`, `resume --expand` (passes the new parent), `rename` (passes the new name), `archive` (no project arg), `unarchive`, `remove` (no project arg), `touch`, `mkdir`, `restore`. Read-only actions (`pp`, `gh-init`, `map`, `addr`, `anchor`, `in`, `diff`, `logs`, `status`, `list`) do not trigger regen.

**Tests added** (`tests/diagrams.bats`, +5 cases):

1. `auto_regen: emits registry.mmd and project tree.mmd` — happy path produces both files with expected headers + entries.
2. `auto_regen: opt-out via ANTCRATE_AUTO_DIAGRAMS=0` — neither file written.
3. `auto_regen: works with no project arg (registry only)` — registry.mmd written, tree.mmd not.
4. `auto_regen: silent on stdout` — function emits empty string when captured.
5. `auto_regen: does not fail when project missing from disk` — degrades to registry-only without erroring.

**End-to-end validation.** Created `ac-autoregen-test` via `--start scripts`. `~/.antcrate/registry.mmd` and `~/projects/scripts/ac-autoregen-test/docs/diagrams/tree.mmd` both materialized. `antcrate --touch ac-autoregen-test src/main.sh` echoed the abs path on stdout (no leakage), and the post-touch `tree.mmd` now contains `main.sh` as a `1` (top-level src) entry. `antcrate --remove` (preapproved) wiped both project tree and the registry-diagram entry. Then `antcrate --ci` → shellcheck **clean** + bats **72/72 passing** (was 67).

**Why this matters for the larger picture.** The Phase-2 diagram-automation guide framed diagrams as "source-of-truth text that always reflects the current state." Without auto-regen, a single stale `--rename` or `--archive` could silently desync the visual from reality, defeating the purpose. With auto-regen, the visual is now a function of registry state — there is no "regenerate the diagrams" step in any agent's workflow, only "do the operation." This is a prerequisite for the per-project skill composition pattern (Phase 3): when an agent loads a project's per-project skill, the embedded `tree.mmd` / `architecture.mmd` it sees in the repo IS what's true on disk, not a snapshot from whenever someone last ran a manual flag.

---

## 2026-04-28 — Phase 2 diagrams + `--register` + `--ci`; skill source registered for upload

**Phase 2 — diagram automation per `assets/docs/DIAGRAM_AUTOMATION_GUIDE.md`:**

- `lib/diagrams.sh` (new):
  - `ac_diagrams_scaffold <project_path> <name>` — idempotently writes `docs/diagrams/architecture.mmd` (Mermaid). Wired into `--start` so every new project ships with one diagram source out of the box.
  - `ac_diagrams_registry_to_mermaid` — emits `graph LR` over all registry projects. Each project becomes a labeled node `name["name\n(parent)"]`; archived projects get a `classDef archived` style; `linked_nodes` render as `<-->` edges (deduped by sorted-pair).
  - `ac_diagrams_tree_to_mermaid <project>` — emits `graph TD` over the project's addressed tree. Directories get `[/dir/]` (parallelogram); static files (lockfiles, `.env`, Dockerfile, etc., classified by `ac_devops_classify`) get `[(file)]` (stadium); dynamic files get `["file"]` (box). Edges follow address parent chain via the new `_ac_diagrams_parent_addr` helper that strips the trailing same-kind segment (`1a3` → `1a`, `1a` → `1`, `1` → empty).
  - `ac_diagrams_render <project>` — bulk-renders `*.mmd`/`*.puml`/`*.d2` to `.svg` if `mmdc`/`plantuml`/`d2` are on PATH. Missing tools yield one-line warns (with install hints) but **never** fail the call — Mermaid sources render inline on GitHub regardless.

- Wrapper flags: `--diagrams <project>`, `--registry-diagram [out.mmd]`, `--tree-diagram <project> [out.mmd]`. Default outputs: `~/.antcrate/registry.mmd` and `<project>/docs/diagrams/tree.mmd`.

- Template: `templates/_generic/docs/diagrams/architecture.mmd` ships with `__NAME__`/`__DATE__` substitution and a comment pointing at `--tree-diagram` for regeneration.

**`--register` flag:**

- New `ac_action_register <name> <existing-path> [<domain>]` in `lib/scaffold.sh`: registers a pre-existing tree without scaffolding. Domain defaults to `basename(dirname(path))`. Refuses missing path, refuses duplicate name. Required for registering the AntCrate skill source itself as a project.

**Safety zones expanded:**

- `ac_safety_allowed_zones` now also yields `dirname "$ANTCRATE_SELFSRC"` when set. With `ANTCRATE_SELFSRC=~/.claude/skills/antcrate/assets/code`, that adds `~/.claude/skills/antcrate/` as a write zone — so the skill source can host a git repo and accept `--pp` pushes through the wrapper without needing `ANTCRATE_ALLOW_OUTSIDE_ROOT=1`.

**`--ci` shim (`ac_devops_ci`):**

- Single entry point: shellcheck on `lib/*.sh + bin/antcrate + bin/antcrated + install.sh`, then `bats tests/`. Each step prints a header and pass/fail line; final `=== ci result: PASS/FAIL ===`. Returns nonzero on any failure. Skips a step (with warn) if its tool isn't installed.

**Pre-existing scaffold bug fixed:**

- `ac_scaffold_resolve_templates` was picking the **first** existing candidate dir, but `antcrate --init` creates `~/.antcrate/templates/` empty. Resolver thus locked onto an empty dir and never fell through to the populated `~/.local/share/antcrate/templates/`. Result: `--start` produced projects without their template content (just empty parent dir + git init). Fix: candidates now require an actual `_generic/` or domain subdir before being selected. Confirmed: `--start ac-diag --domain scripts` now correctly stages `main.sh` (from `templates/scripts/`) plus the auto-scaffolded `docs/diagrams/architecture.mmd` (via the new diagrams hook).

**Skill source registered + pushed to GitHub (private):**

- `antcrate --register antcrate ~/.claude/skills/antcrate --domain claude-skills` → registry entry created.
- Sanity check: `antcrate --map antcrate` walks the full skill tree (SKILL.md, state.md, ledger.md, composes.md, stack.md, plus assets/code/{bin,lib,tests,templates,systemd} and assets/docs/) — addresses resolve correctly, safety zone widening confirms.
- User refreshed `gh auth login -h github.com -p https` (account: zeppybabe). I added a top-level `README.md` (one-paragraph intro + pointer table) and `.gitignore` (logs, swp, .env*, IDE noise) — the user explicitly delegated this in their message.
- `antcrate --gh-init antcrate --private` → created `https://github.com/zeppybabe/antcrate` (PRIVATE), wired origin, pushed initial commit (`e6b64fb antcrate: initial commit (antcrate)`). 55 files committed. Registry `git_remote` field now set to the HTTPS URL.
- `antcrate --diff antcrate` → clean (working tree matches remote).

**Tests added:**

- `tests/diagrams.bats` (7 tests): scaffold writes + idempotency, registry_to_mermaid header/nodes/links/archived class, tree_to_mermaid root + addresses + tags, render-when-tools-missing graceful skip, `_parent_addr` four cases.
- `tests/register.bats` (6 tests): registers existing tree, default-domain behavior, explicit-domain wins, refuses missing path, refuses duplicate name, requires both args.

**Final pass:** `antcrate --ci` → **shellcheck clean + 67/67 bats tests passing.** One real shellcheck fix during the round (`SC2034` unused `expect` var in `_ac_diagrams_parent_addr`).

---

## 2026-04-27 — Test suite green; three real bugs fixed during the bats pass

Installed `bats-core` 1.13.0 (cloned upstream and ran installer into `~/.local`) and `shellcheck` 0.10.0 (static x86_64 release into `~/.local/bin`). `antcrate --selftest` now runs the full bats suite via the installed wrapper.

**Initial run:** 50 / 54 passing. Investigated each failure:

1. **`address.bats` #13 (mine):** `ac_addr_list_dir` used `ls -1` which never returns hidden files — `awk -v inc=1` had nothing to filter from. Fix: `ls -1A`.

2. **`registry.bats` #38:** `ac_registry_has` used `jq -e '.projects[$n] // empty'` which returns exit 4 in jq 1.7+ (the modern "no output produced" code) instead of exit 1 (false/null). Test expected `has_a=1` after delete. Fix: filter rewritten to `.projects[$n]` — null → jq -e exit 1, present → exit 0. Stable contract restored.

3. **`backup.bats` #20:** Restore test wrote "modified", backed up, wrote "post-backup-mod", then restored, expecting to see "modified". Got "post-backup-mod". Root cause: `ac_backup_create` uses second-resolution timestamps. The pre-restore backup (created when the target tree is non-empty) collides with the original tarball name, `tar -czf` overwrites, the captured `tarball` var still points at the now-clobbered path, and restore extracts the wrong content. Fix: collision suffix loop in `ac_backup_create` (`-<ts>_<n>.tar.gz` when the natural name is taken). Backwards-compatible with existing tarballs.

4. **`scaffold.bats` #43:** `subbranch.sh` calls `ac_safety_guard_destructive` (added when subbranch became backup-protected). The test's `src()` source list didn't include `safety.sh` or `backup.sh`, so the function was unbound. Fix: added both sources + `ANTCRATE_BACKUP_DIR` and `ANTCRATE_REMOVAL_PREAPPROVED=1` to the test setup.

**After fixes:** **54 / 54 passing** across 7 suites.

**Shellcheck pass:** Initially 30+ findings, mostly info-level. Categorized:
- **Real fixes:** SC2059 in `ac_addr_int_to_letters` (variable in printf format) — replaced with array-style index into `abcdefghijklmnopqrstuvwxyz`. SC2295 in `_ac_addr_walk` — `${full#$root/}` quoted to `${full#"$root"/}`. Unused `line` var in `ac_devops_map`.
- **Idiom rewrites:** `A && B || true` patterns in `git_triage.sh` and `scaffold.sh` rewritten to `if A; then B; fi || true` (or split into separate statements where the suppression target was on `git commit`).
- **Targeted disables:** SC2016 file-level on `registry.sh` and `devops.sh` (jq filter strings legitimately use literal `$n`); SC2034 file-level on `safety.sh` (`AC_LAST_BACKUP_PATH` is contract-output for callers), `schema.sh` (AC_META_* consumed by scaffold.sh), `bin/antcrate` and `bin/antcrated` (AC_COMPONENT consumed by log.sh); SC1091 inline on the runtime config source line; SC2012 inline on the trusted `ls -1A | awk` pipeline.

Final: `shellcheck -x lib/*.sh bin/antcrate bin/antcrated install.sh` exits 0 with no output.

---

## 2026-04-27 — Closing the wrapper gaps: --unarchive, --remove, --touch, --mkdir

Four wrappers added to eliminate the remaining "no flag fits" cases on common ops.

- **`--unarchive <project>`** — paired with `--archive`, which now stores `previous_parent` in the registry on archive. Unarchive reads it, mvs back to `~/projects/<previous_parent>/<name>`, restores parent, deletes `previous_parent` field. Backup-protected via `ac_safety_guard_destructive`.
- **`--remove <project>`** — hard delete with extra-loud "PERMANENT DELETE" banner printed to stderr before the safety guard. Backup tarball is the sole recovery path; the path is printed on success along with the `--restore` recipe. After `rm -rf`, registry purged via `ac_registry_delete` (which also cleans linked_nodes references in other projects).
- **`--touch <project> <relpath>`** — creates an empty file via the wrapper; auto-mkdirs parents; rejects absolute paths, `..` traversal, and overwrite of existing entries. Stdout is the absolute path so it composes with `Write` / `$EDITOR` (e.g., `EDITOR vim "$(antcrate --touch foo src/new.sh)"`).
- **`--mkdir <project> <relpath>`** — `mkdir -p` with the same path-safety rules. Idempotent. Stdout = absolute path.

**Validation cycle on `ac-touchtest` fixture:**
1. `--start` → registered.
2. `--touch README.md`, `--touch src/utils/helper.sh`, `--mkdir tests/integration`, `--touch tests/integration/api.bats` → 3 files + 4 dirs created via wrapper, no bare touch/mkdir.
3. `--map` shows correct addresses (`2a1` for `src/utils/helper.sh`, `3a1` for the bats file).
4. `--touch README.md` again → refused (existing entry).
5. `--touch /etc/passwd` → refused (absolute).
6. `--touch ../escape` → refused (.. traversal).
7. `--archive` → moves to `.archive/`, registry shows `previous_parent: "scripts"`.
8. `--unarchive` → restores to `~/projects/scripts/ac-touchtest`, `previous_parent` deleted from registry.
9. `--remove` → loud banner, `rm -rf`, registry entry purged. Backup tarball printed.

**Files changed:**
- `lib/devops.sh` — five new functions: `ac_devops_archive` extended (now writes `previous_parent`), `ac_devops_unarchive`, `ac_devops_remove`, `ac_devops_touch`, `ac_devops_mkdir`. Plus internal `_ac_devops_check_relpath` for shared path-safety.
- `bin/antcrate` — six new args (`--unarchive`, `--remove`, `--touch`, `--mkdir`, `RELPATH`), four new dispatch cases, usage text expanded.
- `assets/docs/PATTERNS.md` — Project lifecycle table now lists the four new flags with parameters; Destructive table cross-references; verb-index updated (`change`/`soft-delete`/`hard-delete`).

**Why this closes the gap:** PATTERNS.md previously said "Remove a project: No flag yet — propose one." That was a real hole — agents would propose, but the operation still couldn't happen via AntCrate. With `--remove`, every common destructive intent (rename, archive, unarchive, remove) is now wrappered. The `--propose` channel is now reserved for genuinely novel intents (banner output, dockerize, env-rotate, etc.), not a placeholder for missing flags.

---

## 2026-04-27 — Anchor + Address architecture; AntCrate-on-AntCrate dev wrappers

User direction: "instead of jumping around from a directory to directory using cd, bundle that logic into antcrate by anchoring you to a temporary variable that is activated by antcrate." Layered file addressing (`1a3` style) to algorithmically separate dynamic from static files.

**New libs (3):**
- **`lib/address.sh`** — bijective base-26 letters + alternating-depth grammar. `ac_addr_decode 1a3` → `1 1 3`. `ac_addr_letters_to_int aa` → 27. `ac_addr_resolve <root> <addr>` walks the sorted, hidden-filtered listing at each depth. `ac_addr_render_tree` produces `<addr>\t<relpath>` lines for any project. Hidden files + noisy build dirs (`.git`, `node_modules`, `target`, `dist`, `build`, `__pycache__`, `.next`, `.cache`, `.svelte-kit`) filtered by default; override via `ANTCRATE_ADDR_INCLUDE_HIDDEN=1`.
- **`lib/anchor.sh`** — `ac_anchor_path` (resolve to abs path), `ac_anchor_export` (eval-able exports of `ANTCRATE_ANCHOR`/`_NAME`/`_ADDR`/`_FILE`), `ac_anchor_run` (subshell `cd` + exec). Replaces every `cd <project>` pattern. When the address points at a file, the anchor dir becomes the parent and the basename surfaces as `$ANTCRATE_ANCHOR_FILE`.
- **`lib/devops.sh`** — bundled developer ops:
  - `ac_devops_map` — addressed tree with `[d]`/`[s]` tags using a static-file pattern list (lockfiles, `.env*`, Dockerfile, tooling dotfiles, LICENSE).
  - `ac_devops_rename` — backup+approval, `mv`, registry rewrite (renames the key, fixes `parent` refs and `linked_nodes`).
  - `ac_devops_archive` — backup+approval, moves to `$ANTCRATE_ROOT/.archive/<project>`, sets parent=`_archived`.
  - `ac_devops_logs` — tails wrapper/daemon/conflict logs; appends `git -C log --oneline -n 5` if a project is named.
  - `ac_devops_diff` — `git -C status --short` + `git -C diff` (no `cd`).
  - `ac_devops_selfsrc/_selfinstall/_selftest/_selfedit` — AntCrate develops AntCrate. `ANTCRATE_SELFSRC` persisted to `~/.antcrate/config` by `install.sh` so source root is always known.

**Wrapper flags wired (12 new):** `--addr`, `--anchor`, `--in`, `--map`, `--rename`, `--archive`, `--logs`, `--diff`, `--selfsrc`, `--selfinstall`, `--selftest`, `--selfedit`. Arg parsing handles `--in <project> [--addr <code>] -- <cmd...>` and `--anchor <project> [--addr <code>]` cleanly; the previously merged `--addr` token is also accepted standalone.

**AGENTS.md tightened:**
- Rule #10: **no bare `cd` into a registered project** — use `--in` or `--anchor`.
- Rule #11: **no bare command when a wrapper exists** — read `PATTERNS.md` first; if intent isn't listed, use `--propose`.

**`PATTERNS.md` rewritten:** 8 sections (lifecycle, anchor/address, destructive, git, logs, dev-on-self, filename triggers, propose) + verb-based quick index. The previous "Move/rename — no bare command" gap is now `--rename`; the remaining "remove" gap is documented as a `--propose` candidate.

**`install.sh`:** appends `ANTCRATE_SELFSRC="<src>"` to `~/.antcrate/config` (or rewrites if present) so `--selfsrc` works without env vars.

**Tests:** `tests/address.bats` (12 tests covering decode, letter conversion, resolve at every depth, hidden-file handling, render_tree). Unrun — `bats` not on PATH this machine. `--selftest` correctly reports the missing dependency.

**Validation:** Created `ac-validation` fixture, populated via `antcrate --in ac-validation -- bash -c 'mkdir... touch...'`. Verified:
- `--map ac-validation` → 13 entries, 7 dynamic + 2 static + 4 dirs, addresses correct (`5b` = `src/main.sh`, `5c2` = `src/utils/log.sh`).
- `--addr ac-validation 5b` → resolved to absolute path.
- `--in ac-validation --addr 5 -- ls -1` → listed src/ contents from the right cwd.
- `--anchor ac-validation --addr 5b` → emitted exports including `ANTCRATE_ANCHOR_FILE=main.sh`.
- `--rename ac-validation ac-validation-renamed` → backup created, project moved on disk, registry key + path updated, parent ref preserved.
- `--archive ac-validation-renamed` → moved to `~/projects/.archive/`, parent=`_archived`.
- `--logs` → tailed wrapper.log and showed both rename + archive entries.
- `--selfsrc` / `--selfedit lib/registry.sh` → resolved correctly.
- `--propose` (sanity check) → still works.

**Final state:** `ac-validation-renamed` archived under `~/projects/.archive/`. Backups retained at `~/.antcrate/backups/{ac-validation,ac-validation-renamed}/`. Test-scaffold untouched.

**Why this design:** the anchor/address pair gives every file in every project a stable, short, algorithmically-derived handle. Combined with the static/dynamic classification, dynamic files (the things that actually change for security/bug reasons) are visually separable from static ones (set-once configs) at any depth. Eliminating bare `cd` collapses repeated `cd ... && cmd && cd back` sequences into single `--in` calls — fewer tokens per action, no leaked shell state, and the wrapper stays the single security boundary.

---

## 2026-04-27 — Pattern catalog + `--propose` escape valve shipped

Two mitigations against AntCrate's growing surface area:

1. **`assets/docs/PATTERNS.md`** — flag-by-intent index. Every common developer intent (project lifecycle, destructive ops, git, filename triggers, state introspection) maps to an AntCrate flag. SKILL.md now lists it as the **first** orientation step ahead of state.md, so Claude reads it before reaching for any project-level shell command. Closes the discoverability gap as wrappers proliferate.

2. **`lib/propose.sh` + `--propose <name> "<description>"` + `--proposals`** — escape valve for novel intents. Instead of falling back to bare `mv`/`rm`/`git push` when no flag fits, agents (and humans) log a proposal to `~/.antcrate/proposals.log` (tab-separated, append-only, owned by AntCrate's state dir, not the skill dir). User reviews proposals to decide which become real flags. Format: `iso8601\tproposer\tname\tdescription`. Validation: name required, no whitespace; description required; embedded tabs/newlines stripped to keep records single-line. Wrapper validation surfaces clear `exit 2` on missing args (defensively shifts safely under `set -e`).

**Files added/changed:**
- `assets/code/lib/propose.sh` (new, 60 lines)
- `assets/code/bin/antcrate` — sourced propose.sh, added `--propose`/`--proposals` arg parsing + dispatch + usage()
- `assets/code/tests/propose.bats` (new, 8 tests)
- `assets/docs/PATTERNS.md` (new)
- `SKILL.md` — added "Pattern catalog" pointer ahead of "Current state"
- `state.md` — Top-of-mind refreshed; tooling note about missing bats/shellcheck

**Validation:** install.sh re-run; `--help` shows new flags; happy path appends correctly; missing-name/missing-description/whitespace-name all exit 2 with clear errors; `--proposals` renders empty notice and existing entries. `bats` not installed on this machine, so tests/propose.bats unrun — install bats-core to run.

**Why this matters:** AntCrate is on a path to absorb more bundles (banners, ASCII art, removal patterns, archives). Without a catalog the wrapper is unfindable, and without a propose channel novel intents leak back to bare commands — both erode the "AntCrate as sole structural surface" property. PATTERNS.md is the discovery surface; `--propose` is the controlled overflow.

---

## 2026-04-26 — Two blocking bugs fixed; first live registry write confirmed

**Bug 1 — Nested flock deadlock** (`assets/code/lib/scaffold.sh` lines 94, 130, 134):
`ac_action_start` and `ac_action_branch` were calling `ac_with_lock mkdir -p` and `ac_with_lock cp -r` while already running inside an outer `ac_with_lock` in the wrapper. `flock -x` on the same lockfile from within a subshell of the holding process blocked forever. Fix: replaced the inner `ac_with_lock` calls with bare `mkdir -p` / `cp -r` — filesystem ops don't need the registry lock.

**Bug 2 — jq `--arg` argument parsing** (`assets/code/lib/registry.sh` line 27–37):
`ac_registry_apply` captured only `$1` as `filter`, then called `jq "$filter" "$ANTCRATE_REGISTRY"`. Callers pass `--arg k v ... 'filter_expr'` as a variadic arg list, so `$1` was `--arg`, and jq errored: `--arg takes two parameters`. Fix: replaced `local filter="$1"` + `jq "$filter"` with `jq "$@"` to pass all args through.

Both fixes applied to installed lib (`~/.local/share/antcrate/lib/`) and skill source (`assets/code/lib/`).

**First live test confirmed**: `antcrate --start test-scaffold --domain scripts` → project registered at `~/projects/scripts/test-scaffold`, registry correctly updated with path/parent/linked_nodes/git_remote.

**Home directory CLAUDE.md** rewritten as AntCrate orchestration meta-config: defines Claude Code's role as coding agent, deterministic protocol for project lifecycle, write zones, and objective tracking rules.

---

## 2026-04-26 — Mandatory backup-before-removal + AntCrate-as-orchestrator pivot

Architectural pivot logged: AntCrate is **orchestration infrastructure**, not a coding agent. It owns directory layout, registry state, branch automation, push/triage, diagram regeneration. Claude Code (or human, or any LLM) uses AntCrate as a tool. Project source code is developed under separate per-project skills composed alongside AntCrate. This separates "how the project is structured/shipped" (AntCrate's job) from "what the code does" (the per-project skill's job).

Implementation of the **backup-before-removal hard rule** (the most critical safety addition to date):

1. **`assets/code/lib/backup.sh`** — `ac_backup_create <project> <path>` produces a verified `tar.gz` under `~/.antcrate/backups/<project>/` with sidecar manifest (sha256, size, source, timestamp). `ac_backup_restore` for rollback. `ac_backup_prune` honors `ANTCRATE_BACKUP_RETENTION` (default 20).

2. **`assets/code/lib/safety.sh`** extended with `ac_safety_guard_destructive <project> <op> <path>`:
   - Step 1: path-zone check (existing).
   - Step 2: **mandatory** `ac_backup_create` — if backup fails, op is refused. _No backup, no removal._
   - Step 3: human approval via interactive y/N prompt; non-interactive contexts (daemon, headless agent) refuse unless `ANTCRATE_REMOVAL_PREAPPROVED=1` is set in `~/.antcrate/config`.
   - `AC_LAST_BACKUP_PATH` exported on success so callers can reference the tarball.
   - `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` does **not** bypass this — only widens path zones, never bypasses backup/approval.

3. **`subbranch.sh`** wired through `ac_safety_guard_destructive` — the sub-branch `mv` is now backup-protected.

4. **AGENTS.md rule #1** rewritten as: "No destructive ops, anywhere, without (a) backup AND (b) human approval." Old rule #1 (path-zone) became #2.

5. **Wrapper CLI flags**:
   - `--backup <project>` — on-demand tarball
   - `--backups <project>` — list backups
   - `--restore <project> [--at <ts>]` — roll back from latest or specific timestamp
   - Restore over a non-empty tree requires `ANTCRATE_RESTORE_OVERWRITE=1` AND creates a pre-restore backup of the current state before clobbering.

6. **Config template** updated to expose `ANTCRATE_REMOVAL_PREAPPROVED`, `ANTCRATE_ALLOW_OUTSIDE_ROOT`, `ANTCRATE_BACKUP_RETENTION` with safe defaults.

7. **`tests/backup.bats`** — 7 tests: tarball creation+verification, refuse-without-tty, preapproved-allows, refuse-outside-zones, subbranch-creates-backup, restore-latest, retention-pruning.

Net effect: even an agent that completely ignores `AGENTS.md` cannot delete a project tree via the AntCrate runtime — `ac_safety_guard_destructive` is mandatory before any `mv`/`rm`-class operation, fails closed, and produces a recoverable tarball as a precondition.

## 2026-04-26 — Claude Code support, safety guard, GitHub HTTPS init

Added three things to make AntCrate immediately usable from Claude Code:

1. **`assets/code/AGENTS.md`** — agent operating rules. 8 hard rules (no destructive ops outside `~/projects/`, no `sudo`, no force-push, no rc-file edits, no plaintext secrets, scoped network access) + soft rules + approval format + recovery checklist + test-before-modify protocol. Claude Code reads this automatically when the skill is loaded.

2. **`assets/code/lib/safety.sh`** — runtime path-safety guard. `ac_safety_guard <op> <path>` resolves the target via `realpath -m` and aborts unless the canonical path is under `$ANTCRATE_ROOT` or `$ANTCRATE_HOME`. Override requires explicit `ANTCRATE_ALLOW_OUTSIDE_ROOT=1`. Wired into `subbranch.sh` (both source and target paths checked before mv). `ac_safety_safe_rm` and `ac_safety_safe_mv` exposed for general use. This makes the protection defense-in-depth — even if an agent ignores `AGENTS.md`, the Bash runtime refuses.

3. **`assets/code/lib/gh.sh`** + `--gh-init` action — GitHub via HTTPS using the `gh` CLI (credentials in system keychain, no PAT in plaintext). `ac_gh_init_repo <project> [public|private]` runs: gh auth check → fetch user via `gh api user` → `gh repo create --source=. --remote=origin --push` → updates registry with HTTPS URL. Idempotent: skips create if repo exists, just wires origin and pushes. `--gh-help` prints onboarding steps. New wrapper flags: `--gh-init <project>`, `--public`/`--private`, `--gh-help`.

4. **`assets/code/CLAUDE_CODE.md`** — install + onboarding guide for Claude Code users. Covers skill install (`unzip antcrate.skill -d ~/.claude/skills/`), runtime install via `install.sh`, safety guarantees summary, gh HTTPS setup, and an example natural-language prompt showing what Claude Code does end-to-end.

5. Annotated `registry.sh::ac_registry_delete` — clarifies that it only removes the registry entry, not the on-disk project; on-disk deletion must go through `safety.sh` helpers.

## 2026-04-26 — Fixed phantom brace-named dirs in package

Initial scaffold left three literal-named directories from a failed `mkdir -p` brace expansion (compound `mkdir -p ... && cd` ran in a context where braces weren't expanded):
- `antcrate/{assets`
- `antcrate/assets/code/templates/{_generic,webapps,projects,scripts,notes}`
- `antcrate/assets/code/templates/_generic/{src,docs}`
- `antcrate/assets/code/templates/projects/{src,tests,docs}`

These rendered the `.skill` zip uninstallable (Claude.ai rejects archive entries with `{` `}` in path components). All four phantom dirs purged; real subdirs (`src/`, `docs/`, `tests/`) recreated with `.gitkeep` files. Repackaged.

Process note: any future `mkdir -p` of brace-set subdirs must be a single argument list, not a compound `&&` chain — and a `find ... | grep '[{}]'` sweep is now standard before packaging.

## 2026-04-26 — v0 codebase scaffolded

Generated full v0 Bash codebase under `assets/code/` from the architectural blueprint:

- Wrapper CLI (`bin/antcrate`) with `--start`, `--branch`, `--link`, `--rel`, `--pp`, `--resume --expand`, `--init`, `--status`.
- Daemon (`bin/antcrated`) using `inotifywait -m` with debounce + swap-file filter + `flock` coordination.
- Library modules: `registry.sh`, `schema.sh`, `git_triage.sh`, `subbranch.sh`, `log.sh`, `lock.sh`.
- Scaffold templates for `webapps`, `projects`, `scripts`, `notes` domains.
- Systemd user unit for daemon supervision.
- bats-core test scaffolding covering schema decode, registry CRUD, triage flow (mocked git), sub-branch atomicity.
- `install.sh` first-run setup.

Diagram-automation integration explicitly **deferred to Phase 2** per user direction — `DIAGRAM_AUTOMATION_GUIDE.md` staged at `assets/docs/` for later.

## 2026-04-26 — Project skill bootstrapped

Initial scaffold via `project-forge`. Seeded state from the AntCrate spec PDF and conversation context.
