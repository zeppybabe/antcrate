# AntCrate — Stack & Specs

## Languages & runtimes

- **Bash 5.0+** (associative arrays, `mapfile`, `${var,,}`,
  `${var,,Pattern}`, namerefs)
- **POSIX coreutils** (mv, mkdir, cp, rm, find, stat, sort, sed, grep,
  date, tar, sha256sum)

## Required deps

| Tool | Purpose | Install (Debian/Ubuntu) |
|---|---|---|
| `jq` | registry.json read/write — atomic temp-file replacement | `sudo apt install jq` |
| `inotify-tools` | daemon filesystem watch (`inotifywait`) | `sudo apt install inotify-tools` |
| `git` | version control automation | `sudo apt install git` |
| `flock` | wrapper/daemon lock coord (in `util-linux`, ships everywhere) | (preinstalled) |
| `mailx` _or_ `sendmail` | conflict triage dispatch on `--pp` rejection | `sudo apt install bsd-mailx` |
| `gh` | `--gh-init` (HTTPS auth, no plaintext PATs) + the queued gh-pipeline flags | `sudo apt install gh` |

## Required for `antcrate --ci`

`--ci` is the canonical pre-change check; both the local pre-commit
hook and `.github/workflows/ci.yml` invoke it.

| Tool | Pinned version (last green) | Install |
|---|---|---|
| `bats-core` | 1.13.0 | `git clone --depth 1 https://github.com/bats-core/bats-core /tmp/bats && /tmp/bats/install.sh ~/.local` |
| `shellcheck` | 0.10.0 | static binary in `~/.local/bin/shellcheck`, or `apt install shellcheck` |

## Optional deps

- **Diagram renderers** — text-of-truth files render inline on GitHub
  without these; SVG promotion is a bonus when present:
  - `mmdc` (`@mermaid-js/mermaid-cli`) — Mermaid → SVG
  - `plantuml` — PlantUML → SVG
  - `d2` — D2 → SVG
  - `schemaspy` — DB → ERD (queued; see `DIAGRAM_PLAN.md`)
- `systemd` (user mode) — for daemon supervision via
  `~/.config/systemd/user/antcrated.service`. AntCrate degrades
  gracefully if absent.

## Paths

### Project & state

- `$HOME/projects/` — default `ANTCRATE_ROOT` (overridable)
- `$HOME/projects/.archive/` — destination for `--archive` (registered
  with `parent=_archived`)
- `$HOME/.antcrate/` — state directory:
  - `registry.json` — single source of truth (jq-mutated, atomic)
  - `registry.mmd` — auto-regenerated Mermaid view of the whole registry
  - `config` — user defaults; **rule #13: human-only territory**
  - `proposals.log` — `--propose` append-only log
  - `backups/<project>/` — verified `.tar.gz` snapshots + `.sha256` manifests
  - `events/<project>.jsonl` — append-only activity stream (lib/events.sh)
  - `cleanup/<project>.list` — persisted classify output for `--apply` (lib/cleanup.sh)
  - `log/{wrapper,daemon}.log` — leveled logs
  - `daemon.{pid,lock}` — single-instance + flock coord
  - `pipe.paused` — pause flag (atomic sub-branching)
- `/tmp/antcrate_conflict.log` — full git diff on push rejection
- `~/.config/systemd/user/antcrated.service` — daemon unit (optional)

### Skill source layout

- `assets/code/`
  - `bin/{antcrate,antcrated}` — wrapper + daemon
  - `lib/*.sh` — sourced helpers:
    `registry.sh`, `schema.sh`, `scaffold.sh`, `subbranch.sh`,
    `safety.sh`, `backup.sh`, `commit.sh`, `git_triage.sh`, `gh.sh`,
    `address.sh`, `anchor.sh`, `devops.sh`, `diagrams.sh`, `hooks.sh`,
    `propose.sh`, `log.sh`, `lock.sh`, `ingest.sh`, `events.sh`,
    `watch.sh`, `cleanup.sh`
  - `templates/<domain>/` — scaffolding per domain (`webapps`,
    `scripts`, `notes`, `projects`, `_generic`)
  - `tests/*.bats` — bats coverage; run via `antcrate --ci`
  - `install.sh` — idempotent installer (PREFIX-aware, default `~/.local`)
  - `systemd/antcrated.service` — drop-in user unit
- `assets/docs/` — design docs (PATTERNS, BUNDLE_SPEC, HOOK_PLAN,
  GH_PIPELINE_PLAN, DIAGRAM_PLAN, POST_DEV_BACKLOG, architecture,
  DIAGRAM_AUTOMATION_GUIDE, examples/bundles/)
- `.github/workflows/ci.yml` — GitHub Actions CI
- `.githooks/pre-commit` — opt-in local hook
  (`git config core.hooksPath .githooks`)

### Installed layout (after `install.sh`)

- `~/.local/bin/{antcrate,antcrated}` — installed binaries (with
  `LIB_DIR` rewritten on copy)
- `~/.local/share/antcrate/lib/*.sh` — installed libs
- `~/.local/share/antcrate/templates/<domain>/` — installed templates

## Network / external

- Outbound HTTPS to GitHub for `--pp` push automation, `--gh-init` repo
  create. Uses `gh` CLI auth (no plaintext PATs).
- Outbound SMTP via local MTA (`mailx`/`sendmail`) for conflict
  notifications when `ANTCRATE_EMAIL` is set in `~/.antcrate/config`.
- No inbound listeners. AntCrate is fully local.

## Schema constants

- Filename delimiter: `.` (literal period)
- Meta delimiters: `#` (hash) for CSV-style, `=` for key-value
- Reserved actions (`$2`): `start`, `branch`, `link`, `rel` —
  positional schema in filenames
- Reserved domains seeded by templates: `webapps`, `projects`,
  `scripts`, `notes`. Any other domain is permitted; templates fall
  back to `_generic/`.
- Reserved registry parent value: `_archived` (set by `--archive`,
  cleared by `--unarchive`)
- Reserved bypass-flag env vars (rule #13: editable only by human via
  `~/.antcrate/config`):
  - `ANTCRATE_REMOVAL_PREAPPROVED=1` — bypass interactive prompt for
    destructive ops (rule #1 backup still mandatory)
  - `ANTCRATE_COMMIT_PREAPPROVED=1` — bypass `--commit` y/N prompt
  - `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` — widen path-zone guard (backup +
    approval still apply)

## Environment variables (read by wrapper / daemon)

| Variable | Default | Purpose |
|---|---|---|
| `ANTCRATE_ROOT` | `$HOME/projects` | Project root |
| `ANTCRATE_HOME` | `$HOME/.antcrate` | State dir |
| `ANTCRATE_EMAIL` | (unset) | Conflict triage recipient |
| `ANTCRATE_LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `ANTCRATE_DEBOUNCE_MS` | `200` | Schema-dispatch debounce per filename |
| `ANTCRATE_TREE_DEBOUNCE_MS` | `600` | Tree-regen debounce per project |
| `ANTCRATE_AUTO_DIAGRAMS` | `1` | Diagram auto-regen on / off |
| `ANTCRATE_BACKUP_RETENTION` | `20` | Backups kept per project |
| `ANTCRATE_SELFSRC` | (set by installer) | Path to skill source root for `--selfsrc` / `--selftest` / `--selfedit` |
| `ANTCRATE_ADDR_INCLUDE_HIDDEN` | `0` | Address resolver — include hidden files |
| `ANTCRATE_INGEST_OFFLINE` | `0` | Skip `--ingest` reachability network checks (tests) |
| `ANTCRATE_INGEST_SKIP_FETCH` | `0` | Skip clone/download in `--ingest` (validation-only) |
| `ANTCRATE_EVENTS_TAIL` | `200` | Active-event scan window (lines from end of jsonl) |
| `ANTCRATE_WATCH_INTERVAL_MS` | `200` | `--watch` redraw cadence |
| `ANTCRATE_WATCH_FORCE_COLOR` | `0` | Emit ANSI even when stdout isn't a TTY |
| `ANTCRATE_CLEANUP_MAX_DEPTH` | `6` | `--cleanup` traversal depth |
| `ANTCRATE_CLEANUP_RECENT_CAP` | `50` | Cap on `projects.<n>.recent_removals` |
| `ANTCRATE_AGENT` | `clyde` | Name attached to emitted activity events |

## Code conventions

**Lib header convention** (applied progressively across `lib/*.sh`).
Each module top comments with: a one-line summary, context paragraph,
**Public API** list (entry points other modules / the wrapper may
call), and an **Internal** list of helpers that *must not* be called
from outside the file. When an internal would bypass an invariant if
called directly (e.g. skip a rule #1 backup gate), a `Reason:` line
documents what would break. Shipped today on `ingest.sh`, `events.sh`,
`watch.sh`, `cleanup.sh`; queued for the existing 17 libs.

## Known-good configs

- `assets/code/templates/_generic/` — fallback when no domain template
  exists; ships an `architecture.mmd` Mermaid seed
- `assets/code/systemd/antcrated.service` — drop-in user unit
- `assets/code/install.sh` — idempotent first-run installer
- `assets/code/AGENTS.md` — 13 hard rules; #1, #10, #11, #12, #13 are
  the most-cited at runtime

## Self-host

The skill source is itself a registered AntCrate project under domain
`claude-skills`. Repo: `https://github.com/zeppybabe/antcrate`
(private). Push via `antcrate --pp antcrate`. CI fires on every push.
