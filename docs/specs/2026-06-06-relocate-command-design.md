# Design — `antcrate --relocate <project>`

_Date: 2026-06-06 · Status: approved (design), pending implementation plan_

## Problem

Claude Code carves its own `~/.claude/` tree out of **non-interactive (background-subagent) file writes** — a guard above the configurable permission layer that no `acceptEdits` / `additionalDirectories` / `Write(//…)` rule can override (proven by controlled experiment 2026-06-06; see `feedback_permissions_session_restart.md` + ledger 2026-06-06). The entire antcrate repo (its `.git` root, `SKILL.md`, docs, `ledger.md`, `state.md`, and `assets/code/`) lives at `~/.claude/skills/antcrate/`, so **no background agent can edit antcrate's own code**. Foreground agents and the main session can, but background parallelism is off the table for antcrate self-development.

`~/projects/**` is outside the carve-out and background-editable. Moving antcrate there fixes the limitation. This design also captures the move as a **reusable command** so any future `.claude`-resident project hits one audited path.

## Command

`antcrate --relocate <project> [--no-watch] [-y]` — relocate a registered project that lives **outside** `$ANTCRATE_ROOT` (in practice, the `~/.claude/` skill tree) out to `$ANTCRATE_ROOT/<name>` (default `~/projects/<name>`), leave a symlink at the old path, rewire every reference. `--no-watch` flags the entry so the daemon ignores it (used when relocating a skill/tool like antcrate itself; normal projects stay watched).

- New `lib/relocate.sh` exposing `ac_relocate <project>`; wired as `--relocate` in `bin/antcrate`.
- Reuses `ac_backup`, `lib/registry.sh`, the canary gate, and `ac_safety_guard_destructive` — no new safety primitives.

## Refusals (fail-closed, evaluated before any move)

1. Project not registered → error.
2. Registry `path` already under `$ANTCRATE_ROOT` → refuse ("already in the projects tree; nothing to relocate"). (The safety guard separately restricts the source to allowed zones — the skill tree, `$ANTCRATE_ROOT`, `$ANTCRATE_HOME` — so in practice only the `~/.claude` skill tree qualifies as a relocatable source.)
3. Destination `$ANTCRATE_ROOT/<name>` already exists → refuse (no clobber).
4. Gateway-Law: mandatory `--backup <project>` tarball first; canary gate applies; interactive `y/N` unless `-y`.

## Steps (with rollback)

1. **Backup** → tarball. Abort everything if backup fails.
2. `mv "$SRC" "$DST"` — the tree carries its own `.git`.
3. **Symlink back:** `ln -s "$DST" "$SRC"`. (Always, not only for skills — preserves external references; required for skill discovery when `SKILL.md` is present.)
4. **Registry:** rewrite `path` `$SRC → $DST` via `lib/registry.sh` (atomic temp-file replace); reassign `parent` (e.g. `claude-skills` → `projects`) to reflect the new home; if `--no-watch` was given, set `daemon_ignore: true` on the entry. Destination is always flat top-level `$ANTCRATE_ROOT/<name>` (not domain-nested), so antcrate lands at exactly `~/projects/antcrate`.
5. **Rewire references:**
   - Re-run `"$DST/assets/code/install.sh"` if present — fixes `ANTCRATE_SELFSRC` in `~/.antcrate/config` and refreshes the `~/.local/bin` wrapper from the new source.
   - Rewrite the two hook paths in `~/.claude/settings.json` from `$SRC/...` → `$DST/...`.
6. **Daemon ignore:** `antcrated`'s watch loop skips registry entries flagged `daemon_ignore: true` (honors the decision to keep antcrate out of the live-tree watch once it sits inside `~/projects`).
7. **Verify:** `$DST` exists; `$SRC` is a symlink resolving to `$DST`; registry `path` updated; run `bash "$DST/assets/code/bin/antcrate" --ci`.

**Rollback:** if any step after the `mv` fails — restore by moving `$DST` back to `$SRC`, revert the registry entry, remove a partial symlink — then report. The backup tarball is the final safety net.

## Skill-discovery caveat (restart-gated, no silent auto-fallback)

The symlink cannot be verified inside the running session — Claude Code loads skills at startup. `--relocate` sets up the symlink and **prints a post-restart checklist**: restart Claude Code, confirm the `antcrate` skill still loads (`ls ~/.claude/skills/antcrate/SKILL.md` resolves through the symlink). If discovery does not follow the symlinked directory, the documented fallback is to replace the symlink with a real `~/.claude/skills/antcrate/` directory containing a `SKILL.md` shim that points at `~/projects/antcrate`. This is an explicit manual confirm, not an automatic fallback.

## Build order (resolves the chicken-and-egg)

`--relocate` must be written *into* `~/.claude/skills/antcrate`, which background agents cannot touch. Therefore:

1. Build `lib/relocate.sh` + `--relocate` wiring + `tests/relocate.bats` via **foreground** edits (main session or a foreground Cody). `bash bin/antcrate --ci` green.
2. Dogfood: `antcrate --backup antcrate` then `antcrate --relocate antcrate`.
3. Restart Claude Code; confirm skill loads + `--ci` from the new location.
4. After the move, antcrate edits use background agents like any other `~/projects` project.

## Testing

`tests/relocate.bats` (backup mocked, registry on a temp fixture):
- refuses unregistered project;
- refuses a project whose path is outside `~/.claude/`;
- refuses when destination already exists;
- moves the tree to `$ANTCRATE_ROOT/<name>`;
- creates the old path as a symlink → new location;
- rewrites the registry `path` and sets `daemon_ignore: true`.

Plus the live dogfood smoke on antcrate itself. Shellcheck-clean; follows "every new lib fn gets a bats test."

## Out of scope (next cycle)

Obsidian mirror re-focus onto `~/projects` (which will then include antcrate) — its own spec after relocation lands.
