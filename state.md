# AntCrate — Current State

_Last updated: 2026-05-01_

## Top of mind

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

1. **`antcrate --ingest <bundle-path>`** — implement the consumer end-to-end against the four reference bundles in `assets/docs/examples/bundles/`. Start with local-path bundles only (no GitHub queue yet). Validation must run before any disk write per BUNDLE_SPEC §4. Bats coverage for each `source.type` variant + the `supersedes` rule-#1 path.

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
