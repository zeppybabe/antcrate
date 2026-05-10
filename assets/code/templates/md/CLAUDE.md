# CLAUDE.md — __NAME__

Project-specific guide. Inherits from `~/CLAUDE.md` (the home AntCrate orchestration layer).

## Project info

- **Name:** `__NAME__`
- **Domain:** `__DOMAIN__`
- **Created:** __DATE__

## AntCrate inheritance

Read these from `~/CLAUDE.md` before any structural action:

- **Gateway Law (AGENTS.md #12)** — updates/removals last in any roadmap; chain is read state → confirm no dependents → backup → show user → explicit approval → execute.
- **Rule #1** — no destructive op without backup + explicit user approval.
- **Rule #13** — `~/.antcrate/config` is human-only.
- **Write zones** — this project's tree is in zone; anything else asks first.

Use `antcrate --pp __NAME__` to push, `antcrate --commit __NAME__ -m "..."` to commit, `antcrate --backup __NAME__` before any structural change. Never `mv`/`rm`/`git push` bare on this registered project.

## What this is

(Replace this section with one paragraph describing the project's purpose, scope, and any constraints that bind editing decisions.)

## Stack-specific conventions

(Add stack-specific rules here — language, framework, testing, file naming, etc. The home-level conventions apply by default.)

## Working memory

- `state.md` — current phase, blockers, next steps (overwritable).
- `ledger.md` — append-only history, newest entries on top, ISO-8601 dates.
