# AntCrate — Ledger

Append-only log. Newest entries on top. ISO-8601 dates. Never delete.

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

**Skill source registered (pre-upload):**

- `antcrate --register antcrate ~/.claude/skills/antcrate --domain claude-skills` → registry now contains:
  ```
  antcrate → /home/twntydotsix/.claude/skills/antcrate (parent=claude-skills)
  ```
- Sanity check: `antcrate --map antcrate` walks the full skill tree (SKILL.md, state.md, ledger.md, composes.md, stack.md, plus assets/code/{bin,lib,tests,templates,systemd} and assets/docs/) — addresses resolve correctly, the safety zone widening confirms.
- **Pending user action:** `gh auth status` reports an invalid token. User must run `gh auth login -h github.com -p https` before `--gh-init antcrate --private` can fire. README/`.gitignore` decision deferred to user.

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
