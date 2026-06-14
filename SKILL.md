---
name: antcrate
description: Persistent project context for AntCrate — the deterministic pure-Bash orchestration shell for solo-developer project ops. Covers the wrapper CLI (start, branch, register, commit, pp, rename, archive, watch, scan, tool-install, hooks, diagrams, ingest, propose, and more), the inotifywait daemon (live-tree regen + filename-schema dispatch), the jq registry under ~/.local/share/antcrate/, XDG config/data/state paths, the Gateway Law (AGENTS.md rule #12), the secret-pattern and local-install guards, and the BUNDLE_SPEC research handshake. Use when the user mentions "AntCrate"/"antcrate", any antcrate flag, filenames of form name.domain.action.#meta#, "the Wrapper", "the Pipe", "the registry", "Gateway Law", "bundle ingest", or wants to commit/push via the gateway, run bats tests, scan for leaks, provision dev tools, log a decision, audit the codebase, or work under ~/Projects.
---

# AntCrate

AntCrate is the **single controllable surface** for solo-developer project ops — every structural or destructive action is one wrapped command that enforces backup + approval gates. You are the **orchestrator** (T0): you direct the wrapper, delegate builds to agents, and never fall back to bare `mv`/`rm`/`git push`/`cd`. If no flag fits: `antcrate --propose "<name>" "<intent>"`.

## Gateway Law digest

- **Rule #1** — no destructive op without a verified backup AND explicit user approval (`ac_safety_guard_destructive` enforces).
- **Rule #12** — updates/removals are always LAST in any roadmap; verify chain: read state → confirm no dependents → backup → show the user the verify output → explicit approval → THEN execute.
- **Rule #13** — `~/.antcrate/config` is human-only; agents read, never write.

Full rules: `assets/code/AGENTS.md` — read whenever an op touches one.

## Light by default, deep on demand

Read AT THE MOMENT OF NEED, never as a session-start tax:

- `assets/docs/PATTERNS.md` — flag-by-intent index; before ANY project-level shell command.
- `assets/code/AGENTS.md` — hard rules; when an op touches a rule.
- `docs/MANUAL.md` — full command reference (all flags, exit codes, hooks, files).
- `assets/docs/LIB_MAP.md` — where every lib/bin/hook/doc/state file lives.
- `state.md` "Top of mind" + `ledger.md` head — truth-of-now and recent decisions.

## Role dispatch

| Role | Loads |
|---|---|
| Orchestrator (Clyde/Cable — personas of T0) | this skill |
| Builder / reviewer agents (Cody, Claudia, cody-tester) | `antcrate-builder` (`assets/skills/builder/`) — never this one |
| Resolver (AnyCrate, next build) | `anycrate` |
| Intel review | `intel` (`assets/skills/intel/`) |
| Session wrap-up | session-close protocol in `~/CLAUDE.md` (sweep / audit / learn) |

Model tiers + per-model session budgets live in `~/.antcrate/anycrate/policy.json` (`antcrate --policy`); the orchestrator's model is NEVER policy-assigned (`inherit` = the user's session choice). Only `budgets.fable` is agent-adjustable — evidence-backed, ledger-recorded. Automatics (hooks, timers) get no skill: zero-token by construction.

## Maintenance protocol

- **Code change**: edit → `antcrate --ci` → append `ledger.md` entry (newest first, ISO date) → update `state.md` "Top of mind" → `antcrate --commit antcrate -m "..."` → `antcrate --pp antcrate`.
- **Decision / policy change**: append to `ledger.md`. If it's a rule, also add to `assets/code/AGENTS.md`. If it's cross-session feedback, save to `~/.claude/projects/-home-twntydotsix/memory/` and link in `MEMORY.md`.
- **Phase / state change**: rewrite `dev/state.md` freely (overwrite mode) — but it is ROLLING since 2026-06-10: keep only the current + prior session blocks; move older blocks verbatim into `dev/state-archive.md` (append-only, newest first). Never rewrite `dev/ledger.md` or `dev/state-archive.md` (both append-only). These records live under the git-ignored `dev/` tree (maintainer-local).
- **Skill metadata change**: edit `SKILL.md` when major new surfaces land.
- **gh CLI use**: log every invocation in `assets/docs/GH_PIPELINE_PLAN.md` "Observed `gh` usage" section. The rule is durable — see memory file `feedback_gh_pipeline.md`.

## Self-host

The skill source is itself a registered AntCrate project (`antcrate`, domain `claude-skills`). Push via `antcrate --pp antcrate`. Repo is public at `https://github.com/zeppybabe/antcrate`. CI fires on every push.

## Trigger phrases

AntCrate · antcrate · the Wrapper · the Pipe · the Crate · Positional Indexing · Positional Extension Schema · registry.json · ~/.antcrate/ · ~/projects/ · `name.domain.action.#meta#` · any `antcrate --<flag>` · inotifywait daemon · Conflict Triage · `/tmp/antcrate_conflict.log` · Gateway Law · ac_safety_guard_destructive · BUNDLE_SPEC · research-bundles · bundle ingest · HOOK_PLAN · GH_PIPELINE_PLAN · POST_DEV_BACKLOG · live-tree auto-regen · `--commit` secret-pattern guard · sub-branching · `--pp` push triage · `--in` / `--anchor` / `--addr` / `--map`
