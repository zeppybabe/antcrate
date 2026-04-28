---
name: antcrate
description: Persistent project context for AntCrate — pure-Bash deterministic project scaffolder driven by Positional Filename Indexing, with inotifywait daemon, jq-backed registry.json, and Git fail-safe conflict triage. Use whenever the user mentions "AntCrate", "antcrate", "Positional Indexing", "Positional Extension Schema", "the Pipe", "the Wrapper", "registry.json" under ~/.antcrate/, "antcrate --start", "--branch", "--pp", "--resume --expand", filenames of form `name.domain.action.#meta#` (e.g. `coolgifwebapp.webapps.start.#html,css,js#`), works under ~/projects/, asks about conflict triage, sub-branching, sendmail/mailx push-failure dispatch, `/tmp/antcrate_conflict.log`, or wants to integrate the diagram-automation guide (Mermaid, PlantUML, D2, SchemaSpy) into scaffold templates. Also use when logging an AntCrate decision, recording a fix, updating state, running bats tests, or auditing the codebase post-GitHub upload.
---

# AntCrate

Pure-Bash deterministic project scaffolder. Filenames are arguments. The daemon translates filesystem events into project actions. State lives in one jq-managed JSON file. Git is automated with a fail-safe that emails truncated diffs on push rejection.

> _"Designing the extension schema as a Positional Index rather than a string to be parsed is a brilliant architectural pivot. By treating the periods as absolute delimiters, you effectively turn a filename into an argument array."_ — design rationale, AntCrate spec v0

## Orientation

- **Pattern catalog** → read `assets/docs/PATTERNS.md` **before any project-level shell command** — flag-by-intent index. If your intent isn't listed, use `antcrate --propose <name> "<description>"` instead of falling back to bare `mv`/`rm`/`git push`.
- **Current state** → read `state.md` — phase, what's built, what's next, blockers.
- **History** → `ledger.md` is the append-only log of every decision, fix, and milestone. Skim the top ~5 entries on entry.
- **Stack & paths** → `stack.md` has Bash version target, jq/inotify-tools requirements, file layout, daemon socket/PID locations.
- **Composed skills** → `composes.md` lists the skills that pair with AntCrate (research-recon for tooling discovery, docx for spec deliverables, frontend-design for any future TUI/dashboard).
- **Codebase** → `assets/code/` holds the runnable Bash codebase. Layout inside:
  - `bin/antcrate` — the Wrapper CLI
  - `bin/antcrated` — the Pipe (inotifywait daemon)
  - `lib/*.sh` — sourced helper modules (registry, schema parser, git triage, sub-branch)
  - `templates/` — per-action scaffolding templates (start, branch, link, rel)
  - `systemd/` — user-level systemd unit for the daemon
  - `tests/` — bats-core unit tests
- **Reference docs** → `assets/docs/` holds:
  - `architecture.md` — the official blueprint (Core Objectives, Glossary, Schema, Registry, Triage, Sub-Branching)
  - `DIAGRAM_AUTOMATION_GUIDE.md` — staged for integration; AntCrate will eventually generate per-project diagrams via Mermaid/PlantUML/D2/SchemaSpy
- **Diagrams** → `assets/diagrams/` will hold the auto-rendered PlantUML/D2 sources for the AntCrate architecture itself (dogfooding).

## Trigger phrases

AntCrate • antcrate • the Wrapper • the Pipe • Positional Indexing • Positional Extension Schema • registry.json • ~/.antcrate/ • antcrate --start • antcrate --branch • antcrate --pp • antcrate --resume • antcrate --expand • inotifywait daemon • Conflict Triage • /tmp/antcrate_conflict.log • `name.domain.action.#meta#`

## Key facts to preserve across chats

- **Language**: pure POSIX Bash 5+, plus `jq`, `inotify-tools`, `git`, `mailx` or `sendmail`. No Python, no Node, no Go in the runtime.
- **Schema**: filenames decode positionally — `$0.Name . $1.Domain . $2.Action . $3.Meta` where Meta is `#csv,values#` or `key=value`.
- **State**: one file, `~/.antcrate/registry.json`, mutated only via `jq` with atomic temp-file replacement.
- **Daemon**: `inotifywait -m -e create,close_write,moved_to` on the watched roots. Debounce by waiting for a `close_write` after `create` so editor swap files don't fire false positives.
- **Triage**: on `git push` rejection, capture stderr → `git diff @{u}..HEAD` (or origin/branch..HEAD) → truncate to 300 lines → `mailx` to configured address. Full log retained at `/tmp/antcrate_conflict.log`.
- **Sub-branch atomicity**: pause daemon → mkdir/mv → rewrite registry → fix relational links → resume daemon.
- **Editor agnosticism**: invocation parity between `antcrate --start name --domain webapps --meta html,css` (CLI) and `nano name.webapps.start.#html,css#` (filename trigger). The daemon never touches a file the wrapper is currently writing — it uses an advisory `flock` on the registry.

## Maintenance

To log a decision, fix, or milestone: activate `project-forge` and say "log this to the AntCrate ledger". Never rewrite `ledger.md` — append only. To update phase/state: rewrite `state.md` directly. Codebase changes get a ledger entry referencing the file path under `assets/code/`.
