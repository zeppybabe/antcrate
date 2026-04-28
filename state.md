# AntCrate — Current State

_Last updated: 2026-04-27_

## Top of mind

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
- Skill source registered: `antcrate → ~/.claude/skills/antcrate (parent=claude-skills)`. Awaiting user `gh auth login` refresh + decision on top-level README before `--gh-init antcrate --private` and `--pp antcrate`.

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

1. Upload to GitHub (user-managed, HTTPS via `gh`).
2. Connect repo to Claude / Claude Code → audit + bats run on real hardware.
3. **Phase 2 — Diagram automation**: extend `start` action to emit `assets/diagrams/` with Mermaid/PlantUML/D2/SchemaSpy hooks per `DIAGRAM_AUTOMATION_GUIDE.md`. Diagrams regenerate on every registry mutation so the visual is always current. Critical workflow: when an incorrect directory or branch is created, the diagram auto-updates so the developer (or agent in the project's per-project skill) immediately sees the misalignment.
4. **Phase 3 — Per-project skill composition pattern**: document the canonical setup where Claude Code loads `antcrate` skill (orchestration) + `<my-project>` skill (code knowledge) simultaneously. AntCrate skill contributes commands; per-project skill contributes context.
5. **Phase 4 — LLM orchestrator hook**: thin wrapper letting a local Ollama agent emit Positional-Extension filenames for deterministic execution.

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
