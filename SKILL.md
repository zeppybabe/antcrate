---
name: antcrate
description: Persistent project context for AntCrate — the deterministic Bash orchestration shell for solo-developer project ops. Covers the wrapper CLI (start, branch, link, pp, commit, rename, archive, unarchive, remove, touch, mkdir, in, anchor, addr, map, hooks, hook-log, ci, diagrams, registry-diagram, tree-diagram, propose, ingest, emit-activity, watch, cleanup, git-init, bootstrap), the inotifywait daemon (live-tree auto-regen + filename-trigger schema dispatch), the jq-backed registry at ~/.antcrate/registry.json, the Gateway Law (AGENTS.md rule #12), the secret-pattern guard in --commit, the bundle handshake spec (BUNDLE_SPEC.md v1.0), git fail-safe conflict triage to /tmp/antcrate_conflict.log, and the hook + gh-pipeline roadmaps. Use when the user mentions "AntCrate", "antcrate", filenames of form name.domain.action.#meta#, "the Wrapper", "the Pipe", "registry.json" under ~/.antcrate/, "research-bundles", "bundle ingest", "Gateway Law", "BUNDLE_SPEC", "HOOK_PLAN", "GH_PIPELINE_PLAN", any antcrate flag, or wants to log a decision, run bats tests, audit the codebase, or work in ~/projects/.
---

# AntCrate

Pure-Bash deterministic project scaffolder + orchestration wrapper. Filenames decode positionally as argument arrays. An `inotifywait` daemon translates filesystem events into project actions and keeps `docs/diagrams/tree.mmd` + `~/.antcrate/registry.mmd` live. One `jq`-managed JSON file (`~/.antcrate/registry.json`) is the single source of truth. `git push` is wrapped with a fail-safe that emails truncated diffs on rejection.

Designed to be the **single controllable surface** for solo-developer ops — every common destructive or structural action becomes one wrapped command that enforces backup + approval gates and leaves the user (or an AI agent) without a reason to fall back to bare shell.

## Read first (in this order)

1. **`assets/docs/PATTERNS.md`** — flag-by-intent index. **Always** before any project-level shell command. If your intent isn't listed, `antcrate --propose <name> "<intent>"` instead of falling back to `mv`/`rm`/`git push`.
2. **`state.md`** — "Top of mind" + "Next steps" + "Already shipped." Truth-of-now in one place.
3. **`assets/code/AGENTS.md`** — hard rules. Read at minimum:
   - **#1**: no destructive op without backup + explicit user approval (enforced by `ac_safety_guard_destructive`)
   - **#10**: no bare `cd` into a registered project — use `--in` or `--anchor`
   - **#11**: no bare command if a wrapper exists — propose via `--propose` instead
   - **#12** (Gateway Law): updates/removals are always LAST in any roadmap; verify chain is read state → confirm no dependents → backup → show user verify output → receive explicit approval → THEN execute
   - **#13**: `~/.antcrate/config` is human-only territory — agents read but never write
4. **`ledger.md`** — top ~5 entries for fresh context on what just changed. Append-only, never rewrite.

## Where things live

### Code (`assets/code/`)

- **`bin/antcrate`** — the Wrapper CLI (single dispatcher, sources all libs)
- **`bin/antcrated`** — the Pipe (inotifywait daemon: schema dispatch + live-tree auto-regen, longest-prefix project resolution, per-project debounce, registry-cache mtime keyed)
- **`lib/*.sh`** — sourced helpers:
  - `registry.sh` — atomic jq CRUD on `registry.json`
  - `schema.sh` — positional filename decoder
  - `scaffold.sh` — `--start` / `--branch` / `--link` / `--register`
  - `subbranch.sh` — atomic `--resume --expand` nesting (backup-protected)
  - `safety.sh` — path-zone guard + `ac_safety_guard_destructive` (rule #1 enforcement)
  - `backup.sh` — verified tar.gz + sha256 manifests, retention pruning, restore
  - `commit.sh` — `--commit` wrapper with secret-pattern guard + Gateway-Law preview/prompt (rule #12)
  - `git_triage.sh` — `--pp` push wrapper with conflict triage to `/tmp/antcrate_conflict.log`
  - `gh.sh` — `--gh-init` (HTTPS via `gh` CLI, no plaintext PATs)
  - `address.sh` — layered positional addressing (`1a3` = 3rd entry inside the 1st sub-branch of the 1st top-level dir; bijective base-26 letters)
  - `anchor.sh` — `--in` / `--anchor` (no bare `cd`)
  - `devops.sh` — `--map`, `--rename`, `--archive`, `--unarchive`, `--remove`, `--touch`, `--mkdir`, `--logs`, `--diff`, `--selfsrc`/`--selfinstall`/`--selftest`/`--selfedit`, `--ci`
  - `diagrams.sh` — Mermaid registry + tree generation, `ac_diagrams_auto_regen` (silent, opt-out via `ANTCRATE_AUTO_DIAGRAMS=0`)
  - `hooks.sh` — `--hooks` (read-only listing) + `--hook-log` (debug blocked commits)
  - `events.sh` — append-only activity stream (`~/.antcrate/events/<project>.jsonl`); `--emit-activity` writes
  - `watch.sh` — colored tree renderer over the active event overlay; `--watch` loops, `--once` for scripts
  - `cleanup.sh` — classifier + apply for test-tmp / empty-dir candidates; `--cleanup <project> [--apply <id>...]`
  - `git_init.sh` — local-only `git init` for a registered project (idempotent + `core.hooksPath` wire); `--git-init <project>`
  - `bootstrap.sh` — one-liner: `--git-init` + default `.gitignore` + first commit; `--bootstrap <project> [-m] [--with-remote --public/--private]`
  - `propose.sh` — `--propose` / `--proposals` (escape valve when no flag fits)
  - `log.sh` — leveled logging (logfile only, stderr only for warn/error)
  - `lock.sh` — flock + pause-flag helpers
- **`templates/<domain>/`** — scaffolding templates per domain (`webapps`, `scripts`, `notes`, `projects`, `_generic`)
- **`tests/*.bats`** — bats coverage; run all via `antcrate --ci`
- **`install.sh`** — idempotent installer; copies binaries to `~/.local/bin`, libs to `~/.local/share/antcrate/`
- **`systemd/antcrated.service`** — optional user-mode daemon unit

### Docs (`assets/docs/`)

- **`PATTERNS.md`** — the orientation index (always read first)
- **`architecture.md`** — original blueprint (Core Objectives, Glossary, Schema, Registry, Triage, Sub-Branching)
- **`BUNDLE_SPEC.md`** (v1.0) — typed handshake between research-AntCrate (producer) and dev-AntCrate (consumer). Defines `manifest.json`, four `source.type` variants, `relationships`, status lifecycle, validate-before-write contract. Consumer-side `--ingest` is the next planned implementation pass.
- **`examples/bundles/`** — four reference bundles: `git-pinned/`, `theoretical/`, `composite/`, `supersedes/`
- **`HOOK_PLAN.md`** — git-hook surface roadmap. Shipped: `--hooks`, `--hook-log`, opt-in `.githooks/pre-commit`, `.github/workflows/ci.yml`. Queued: `--hook-install` / `--hook-remove` / `--hook-bypass` + template library.
- **`GH_PIPELINE_PLAN.md`** — running ledger of `gh` CLI usage being absorbed into antcrate flags. Every `gh` use logged here as a candidate. Proposed first pass: `--gh-info`, `--runs`, `--watch-run`, `--run-log`, `--issues`, `--issue-new`, `--prs`.
- **`DIAGRAM_PLAN.md`** — case-by-case diagram selection algorithm. Shipped: universal pair (`registry.mmd` + `tree.mmd`) auto-regenerated everywhere. Queued: stack-aware presets (`bash`, `node`, `svelte`, `python`, `rust`, `go`, `terraform`, `db`, `k8s`), `--diagram-preset`, `--diagram-detect`, auto-install on `--start`. Diagrams are first-class AntCrate output, not an external dependency.
- **`POST_DEV_BACKLOG.md`** — items deferred until GA: native-plugin gateway enforcement, per-tier antcrate (dev/infra/sec), bundle signing, backup encryption, `--pp` secret-guard fix.
- **`DIAGRAM_AUTOMATION_GUIDE.md`** — underlying tool catalog (Quick Picker, the seven core tools, source-of-truth-by-type sections). The reference that backs `DIAGRAM_PLAN.md`.

### Hooks + CI (root of skill repo)

- **`.github/workflows/ci.yml`** — runs `antcrate --ci` on push to master/main + PRs
- **`.githooks/pre-commit`** — opt-in local hook (enable per-clone via `git config core.hooksPath .githooks`); runs `antcrate --ci`, tees output to `.git/antcrate-hook.log`

### State (`~/.antcrate/`)

- `registry.json` — single source of truth (jq-mutated, atomic temp-file replacement)
- `registry.mmd` — auto-regenerated Mermaid view of the whole registry (archived dimmed)
- `config` — user defaults (rule #13: human-only)
- `proposals.log` — `--propose` append-only log
- `backups/<project>/` — verified tar.gz snapshots
- `log/{wrapper,daemon}.log` — leveled logs
- `daemon.{pid,lock}` — single-instance + flock coord
- `pipe.paused` — pause flag (atomic sub-branching)

## Self-host

The skill source is itself a registered AntCrate project (`antcrate`, domain `claude-skills`). Push via `antcrate --pp antcrate`. Repo is private at `https://github.com/zeppybabe/antcrate`. CI fires on every push.

## Key invariants to preserve across chats

- **Language**: pure POSIX Bash 5+. No Python/Node/Go in runtime. Deps: `jq`, `inotify-tools`, `git`, `mailx`/`sendmail`, `flock` (in `util-linux`).
- **Schema**: filenames decode positionally — `Name.Domain.Action.#Meta#`. Meta is `#csv,values#` or `key=value`.
- **State mutation**: only via `lib/registry.sh` helpers (atomic jq + temp-file replacement). Never `jq … > registry.json` directly.
- **Daemon events**: `create | close_write | moved_to | moved_from | delete`. Editor swap/dot files filtered. Per-project debounce (`ANTCRATE_TREE_DEBOUNCE_MS`, default 600ms).
- **Triage**: on `git push` rejection, capture stderr → `git diff @{u}..HEAD` → truncate to 300 lines → `mailx`. Full log retained at `/tmp/antcrate_conflict.log`.
- **Sub-branch atomicity**: pause daemon → mkdir/mv → rewrite registry → fix `linked_nodes` → resume daemon. Pre-step backup mandatory.
- **Editor parity**: `antcrate --start name --domain webapps --meta html,css` ≡ `nano name.webapps.start.#html,css#` (daemon decodes the latter and dispatches the former).
- **Auto-regen**: every mutating wrapper action AND every direct filesystem event under a registered project triggers `ac_diagrams_auto_regen`. Diagrams are a function of state, not a snapshot.

## Maintenance protocol

- **Code change**: edit → `antcrate --ci` → append `ledger.md` entry (newest first, ISO date) → update `state.md` "Top of mind" → `antcrate --commit antcrate -m "..."` → `antcrate --pp antcrate`.
- **Decision / policy change**: append to `ledger.md`. If it's a rule, also add to `assets/code/AGENTS.md`. If it's cross-session feedback, save to `~/.claude/projects/-home-twntydotsix/memory/` and link in `MEMORY.md`.
- **Phase / state change**: rewrite `state.md` freely (overwrite mode). Never rewrite `ledger.md` (append-only).
- **Skill metadata change**: edit `SKILL.md` when major new surfaces land.
- **gh CLI use**: log every invocation in `assets/docs/GH_PIPELINE_PLAN.md` "Observed `gh` usage" section. The rule is durable — see memory file `feedback_gh_pipeline.md`.

## Trigger phrases

AntCrate · antcrate · the Wrapper · the Pipe · the Crate · Positional Indexing · Positional Extension Schema · registry.json · ~/.antcrate/ · ~/projects/ · `name.domain.action.#meta#` · any `antcrate --<flag>` · inotifywait daemon · Conflict Triage · `/tmp/antcrate_conflict.log` · Gateway Law · ac_safety_guard_destructive · BUNDLE_SPEC · research-bundles · bundle ingest · HOOK_PLAN · GH_PIPELINE_PLAN · POST_DEV_BACKLOG · live-tree auto-regen · `--commit` secret-pattern guard · sub-branching · `--pp` push triage · `--in` / `--anchor` / `--addr` / `--map`
