# AntCrate — Stack & Specs

## Languages & runtimes

- **Bash 5.0+** (associative arrays, `mapfile`, `${var,,}`)
- **POSIX coreutils** (mv, mkdir, cp, rm, find, stat)

## Required deps

| Tool | Purpose | Install (Debian/Ubuntu) |
|---|---|---|
| `jq` | registry.json read/write | `sudo apt install jq` |
| `inotify-tools` | daemon filesystem watch | `sudo apt install inotify-tools` |
| `git` | version control automation | `sudo apt install git` |
| `mailx` _or_ `sendmail` | conflict triage dispatch | `sudo apt install bsd-mailx` |
| `flock` | wrapper/daemon lock coord | (in `util-linux`, ships everywhere) |

## Optional deps

- `bats-core` — for running the unit test suite (`sudo apt install bats`)
- `systemd` (user mode) — for daemon supervision via `antcrated.service`
- `shellcheck` — pre-commit linting of all `.sh` files

## Paths

- `$HOME/projects/` — default `ANTCRATE_ROOT` (overridable)
- `$HOME/.antcrate/` — state directory:
  - `registry.json` — single source of truth for project relationships
  - `config` — user defaults (email, git remote prefix, root path)
  - `log/` — leveled logs (`wrapper.log`, `daemon.log`)
  - `daemon.pid` — running daemon PID
  - `daemon.lock` — flock target for wrapper/daemon coordination
- `/tmp/antcrate_conflict.log` — full git diff on push rejection
- `~/.config/systemd/user/antcrated.service` — daemon unit (optional)

## Network / external

- Outbound SMTP via local MTA (`mailx`/`sendmail`) for conflict notifications
- Outbound HTTPS/SSH to git remote for `--pp` push automation
- No inbound listeners. AntCrate is fully local.

## Schema constants

- Filename delimiter: `.` (literal period)
- Meta delimiters: `#` (hash) for CSV-style, `=` for key-value
- Reserved actions (`$2`): `start`, `branch`, `link`, `rel`
- Reserved domains seeded by templates: `webapps`, `projects`, `scripts`, `notes` (any other domain is allowed; templates fall back to a generic skeleton)

## Known-good configs

- `assets/code/templates/_generic/` — fallback when no domain template exists
- `assets/code/systemd/antcrated.service` — drop-in user unit
- `assets/code/install.sh` — idempotent first-run installer
