# AntCrate

Pure-Bash deterministic project scaffolder + orchestration wrapper. Filenames decode positionally as argument arrays; an `inotifywait` daemon translates filesystem events into project actions; one `jq`-managed JSON file is the single source of truth for state; `git push` is wrapped with a fail-safe that emails truncated diffs on rejection.

Designed to be the **single controllable surface** for solo-developer ops — every common destructive or structural action becomes one wrapped command (`--start`, `--rename`, `--archive`, `--remove`, `--touch`, `--mkdir`, `--in`, `--anchor`, `--addr`, `--map`, `--diagrams`, `--pp`, `--ci`, …) that enforces backup + approval gates and leaves the user (or an AI agent) without a reason to fall back to bare shell.

## Quick start

```bash
git clone https://github.com/zeppybabe/antcrate.git ~/antcrate-src
bash ~/antcrate-src/assets/code/install.sh        # installs to ~/.local
antcrate --init                                    # state dir + config stub
antcrate --start coolapp --domain webapps --meta html,css,js
antcrate --map coolapp                             # see addressed tree
antcrate --pp coolapp                              # commit + push with conflict triage
```

## Where to look

| File | What it is |
|---|---|
| `SKILL.md` | Claude Code skill metadata — how the AntCrate persistent context loads. |
| `assets/code/README.md` | The AntCrate codebase walkthrough (lib/, bin/, templates/, tests/). |
| `assets/code/AGENTS.md` | Hard rules every AI agent (Claude Code, Cursor, …) must follow when operating on AntCrate-managed projects. |
| `assets/docs/PATTERNS.md` | Flag-by-intent index — read this before any project-level shell command. |
| `assets/docs/architecture.md` | The blueprint: Core Objectives, Glossary, Schema, Registry, Triage, Sub-Branching. |
| `assets/docs/DIAGRAM_AUTOMATION_GUIDE.md` | Source-of-truth-text diagram tooling reference (Mermaid, PlantUML, D2, SchemaSpy). |
| `state.md` / `ledger.md` | Live development state and append-only decision log. |

## Status

v0 codebase, real-machine validated. **`antcrate --ci` (shellcheck + bats) is green** — see `assets/code/tests/`. Phase 2 (diagram automation) shipped; Phase 3 (per-project skill composition) and Phase 4 (LLM orchestrator hook) queued in `state.md`.

## License

See `assets/code/AGENTS.md` for operating rules. Code license to be added by the maintainer.
