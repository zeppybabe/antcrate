# AntCrate — Current State

_Last updated: 2026-05-09_

## Top of mind

**Git history catch-up landed (2026-05-09, seventeenth pass):** three sessions of work (dogfood trio #82/#83/#87, agent layer #88-#92/#109-#111, --delegate #93) were sitting in the working tree from 2026-05-05 onward. Split into 4 commits (`f670f4f` dogfood, `d90aa11` agent-layer, `2a14155` delegate, `5116045` docs catch-up) and pushed via `antcrate --pp antcrate -y`. The new post-push verify from #87 fired on its own first push: `verify: origin/master in sync at 5116045`. CI green at HEAD (269/269 bats, shellcheck clean). Working tree clean. Pick up next session from the resume points below.

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
