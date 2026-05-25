# AntCrate

Bash, jq, and inotify. One controllable surface for solo-developer project ops.

AntCrate is a pure-Bash CLI that wraps the structural and destructive operations a solo developer repeats across every project: scaffolding directories, managing a lightweight JSON registry, pushing to git with a fail-safe on rejection, running CI, and tracking project state. It is designed for developers who work alone or with a small AI agent layer and need every risky operation — rename, remove, push, hook execution — to go through a single auditable entry point rather than bare shell commands. Nothing runs elevated; all state lives in `~/.antcrate/` and the registered project trees. Read [PATTERNS.md](assets/docs/PATTERNS.md) for the full flag index.

## Quick start

```bash
git clone https://github.com/zeppybabe/antcrate.git ~/antcrate-src
bash ~/antcrate-src/assets/code/install.sh
antcrate --init
antcrate --start coolapp --domain webapps --meta html,css,js
antcrate --map coolapp
antcrate --status
```

Installs to `~/.local/bin` and `~/.local/share/antcrate/`; the registry lives at `~/.antcrate/registry.json`. See [Dependencies](#dependencies) below if `--init` errors on a missing tool.

## How it works

**Schema.** Filenames are argument arrays. The format `Name.Domain.Action.#Meta#` maps directly to positional indices: `coolapp.webapps.start.#html,css,js#` is exactly equivalent to `antcrate --start coolapp --domain webapps --meta html,css,js`. No parsing ambiguity; both paths produce the same registry write.

**Daemon.** `antcrated` is a background `inotifywait` process that watches a configured directory. When you create or write a file whose name matches the schema, the daemon dispatches the corresponding CLI command. This makes editor file-creation — a `nano coolapp.webapps.start.#html,css,js#` — a first-class invocation path, identical to typing the flag.

**Registry.** `~/.antcrate/registry.json` is the single source of truth for project state: paths, parent/child relationships, linked nodes, git remotes. All reads and writes go through `lib/registry.sh` using atomic jq + temp-file replacement. No direct edits; no concurrent corruption.

**Safety gate.** Destructive operations — remove, rename, structural moves — require an explicit backup step before they proceed. The `--pp` push-pipe captures git rejection, generates a truncated diff, and routes it to email via mailx before halting. No operation reaches the destructive step without a checkpoint. See [architecture.md](assets/docs/architecture.md) for the full blueprint.

## Command basics

AntCrate ships 69 flags across 11 buckets; the dozen below are what you'll hit on day one. The exhaustive flag-by-intent index lives in [PATTERNS.md](assets/docs/PATTERNS.md).

### Lifecycle

| Flag | What it does |
|---|---|
| `--start <name> --domain <d>` | Scaffold + register a new project |
| `--status` | Show all registered projects |
| `--list` | Compact project list |
| `--info <project>` | Registry record + git state for one project |
| `--archive <project>` | Mark project inactive, keep registry entry |
| `--remove <project>` | Remove with mandatory backup + approval gate |

### Navigation

| Flag | What it does |
|---|---|
| `--map <project>` | Print project tree with live event overlay |
| `--in <project> -- <cmd>` | Run a command scoped to the project root |
| `--anchor <project>` | Print the project path for shell cd |

### Git + CI

| Flag | What it does |
|---|---|
| `--bootstrap <project>` | Init git, stage everything, first commit |
| `--pp <project>` | Push-pipe: triage on rejection, log conflicts |
| `--ci` | Shellcheck + bats + cmake/ctest in sequence |

### Daemon + diagnostics

| Flag | What it does |
|---|---|
| `--watch <project>` | Live project tree with latest-event pin |
| `--logs [project]` | Tail antcrate daemon and hook logs |

## Layout

| Document | What it covers |
|---|---|
| [SKILL.md](SKILL.md) | Skill manifest (agent integration metadata) |
| [assets/code/README.md](assets/code/README.md) | Codebase walkthrough for contributors |
| [assets/docs/PATTERNS.md](assets/docs/PATTERNS.md) | Full flag index, organized by intent |
| [assets/docs/architecture.md](assets/docs/architecture.md) | System blueprint: schema, daemon, registry, triage |
| [assets/code/AGENTS.md](assets/code/AGENTS.md) | Hard rules for agent and automated tool usage |
| [assets/docs/BUNDLE_SPEC.md](assets/docs/BUNDLE_SPEC.md) | Agent bundle handshake contract |

## Dependencies

### Required

Bash 5+, jq, inotify-tools, git, mailx or sendmail, flock. All must be on `PATH` before running `install.sh`. `--init` will report which tools are missing.

### Optional

`gh` for `--gh-init` (GitHub repo creation); `mmdc`, `plantuml`, or `d2` for diagram generation via `--diagrams`; `cmake` and `g++` for the `antcrate-core` C++ helper — `--ci` detects absence and skips the cmake/ctest step with a log line.

## CI and hooks

`--ci` runs three stages in sequence: shellcheck on all `.sh` files, bats on the full test suite, then cmake build + ctest for the C++ core. All three must pass for a green result. Exit code 0 means clean; any failure prints the stage that broke and exits non-zero.

An opt-in pre-commit hook is available. Enable it with one line:

```bash
git config core.hooksPath .githooks
```

The hook tees output to `.git/antcrate-hook.log`; inspect recent runs with `antcrate --hook-log antcrate`. Full hook design and the planned hook-management surface are in [HOOK_PLAN.md](assets/docs/HOOK_PLAN.md).

`.github/workflows/ci.yml` runs the same `antcrate --ci` on every push and pull request, with cmake and g++ installed in the workflow environment alongside the Bash toolchain.

## Status

316 bats tests passing, shellcheck clean, cmake/ctest 1/1 (C++ Wave 0 — `antcrate-core` doctest scaffold wired into `--ci`). Baseline sha `80385c3`. Solo-maintained, pre-1.0; the CLI surface may shift before a v1 tag. Current work queue and blockers live in [`state.md`](state.md); decision history in [`ledger.md`](ledger.md).

## Contributing

AntCrate is solo-maintained. Issues are welcome; PRs reviewed against current in-flight work — read `state.md` first. See [CONTRIBUTING.md](CONTRIBUTING.md) for the test gate, commit style, and proposal process.

## Security

AntCrate wraps `git push`, executes repo-local hooks under `--ci` and `--hook-debug`, and runs an `inotifywait` daemon — a non-trivial attack surface even at user privilege. Vulnerability reports go through GitHub's private vulnerability reporting, not public issues; details in [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
