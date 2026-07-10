# AntCrate

Bash, jq, and inotify. One controllable surface for human + AI development.

AntCrate is a pure-Bash orchestration shell that wraps every structural, destructive, or remote-facing operation a solo developer — or the AI agent working beside them — repeats across projects: scaffolding, a JSON registry as single source of truth, guarded commits and pushes, backups with verified manifests, git-hook management, autonomous work loops with hard budget stops, and a safety layer that makes the dangerous paths *narrow, audited, and reversible*.

It began as a project scaffolder. It has evolved into an **agent-governance layer**: the boundary that lets a coding agent operate at full speed inside registered project trees while every risky action — rename, remove, push, hook execution, secret exposure — routes through a single auditable entry point with backup and approval gates. Nothing runs elevated; all state lives under your XDG base directories (`~/.config`, `~/.local/share`, `~/.local/state`) and the registered trees.

## The contract

Five rules shape everything in this repo:

1. **No destructive operation without a backup and explicit human approval.** Enforced in code (`ac_safety_guard_destructive`), not by convention.
2. **Quarantine over destruction.** User data is never deleted by automation — it is archived and moved to `~/.local/state/antcrate/quarantine/`. There is deliberately no purge flag; only the human deletes.
3. **Updates and removals come last** in any roadmap or operation chain (the *Gateway Law*): read state → confirm no dependents → backup → show the human the verify output → receive approval → only then execute.
4. **Agents propose, humans approve.** When no flag fits an intent, the agent files `antcrate --propose` instead of falling back to a bare command. The proposal log is how the agent says "I needed this" without crossing the boundary.
5. **Bash owns retrieval, the human/agent owns judgment.** Timers fetch and snapshot; nothing automated ever decides meaning or edits code on its own.

## Quick start

```bash
# 1. Dependencies (Debian/Ubuntu shown — see Dependencies for dnf/pacman/zypper)
sudo apt-get install -y jq git inotify-tools

# 2. Install — no root; the installer checks deps and runs --init for you
git clone https://github.com/zeppybabe/antcrate.git ~/antcrate-src
bash ~/antcrate-src/assets/code/install.sh

# 3. Use it
antcrate --status                                               # selfsrc: OK-WITH-WARNINGS on a fresh install
antcrate --start coolapp --domain webapps --meta html,css,js    # scaffolds under ~/Projects
antcrate --map coolapp
```

**Where things live (XDG).** Binaries in `~/.local/bin`; libs, templates, hooks, and the registry under `~/.local/share/antcrate/`; config at `~/.config/antcrate/config`; logs, backups, and locks under `~/.local/state/antcrate/`. Projects scaffold under `~/Projects` by default (override with `ANTCRATE_ROOT`). All locations honor the `XDG_*_HOME` variables, and upgrading from a pre-XDG install migrates `~/.antcrate/` automatically, once. A fresh install reports `selfsrc: OK-WITH-WARNINGS` (not `FAIL`) — the warnings are just "no backup yet / unpushed".

**Dev tools, no root.** `antcrate --tool-install bats|shellcheck` provisions pinned, SHA256-verified tools under the XDG data dir; the bundled `local-install-guard.sh` hook steers reflexive `sudo apt` / `curl | bash` installs toward that path. The installer prints a per-distro hint if a required tool is missing — see [Dependencies](#dependencies).

**Full reference:** every flag, file, environment variable, and exit code is documented man-page style in [docs/MANUAL.md](docs/MANUAL.md). The flag-by-intent index — what agents read before reaching for a shell command — is [PATTERNS.md](assets/docs/PATTERNS.md).

## How it works

**Schema.** Filenames are argument arrays. `Name.Domain.Action.#Meta#` maps to positional indices: creating `coolapp.webapps.start.#html,css,js#` is exactly equivalent to `antcrate --start coolapp --domain webapps --meta html,css,js`. No parsing ambiguity; both paths produce the same registry write.

**Daemon.** `antcrated` is an `inotifywait` background process watching a configured directory. A file whose name matches the schema dispatches the corresponding CLI command — editor file-creation becomes a first-class invocation path. The daemon also keeps per-project Mermaid tree diagrams live on every filesystem event, debounced per project.

**Registry.** `~/.local/share/antcrate/registry.json` is the single source of truth: paths, domains, parent/child nesting, linked nodes, git remotes, recent removals. Every read and write goes through `lib/registry.sh` using atomic jq + temp-file replacement. No direct edits, no concurrent corruption.

**Safety gate.** Destructive operations funnel through one chokepoint that enforces backup-before-touch and human approval, and is itself gated by the *compaction canary* (below). The `--pp` push-pipe captures git rejection, generates a truncated diff, and routes it to email before halting — never a silent failed push.

## Capability tour

AntCrate ships **88 commands** backed by 41 lib modules. The groups below are the shape of the tool; [docs/MANUAL.md](docs/MANUAL.md) documents every flag.

### Project lifecycle and navigation

`--start`, `--register`, `--branch`, `--link`, `--resume --expand` (atomic sub-branching), `--rename`, `--archive` / `--unarchive`, `--touch` / `--mkdir`, `--info`, `--list`, `--map`.

No `cd` is ever needed: `--in <project> -- <cmd>` runs anchored at the project root, `--anchor` exports a stable handle, and the **layered address system** gives every file a positional code (`1a3` = 3rd entry inside the 1st sub-branch of the 1st top-level dir) resolvable via `--addr`.

### Safety architecture

- **Backups:** `--backup` / `--backups` / `--restore [--at <ts>]` — verified tar.gz + sha256 manifests, retention pruning, pre-restore auto-backup.
- **Quarantine:** `--quarantine-list` / `--quarantine-restore` — capture-first removal staging. No purge flag exists, by design.
- **Compaction canary:** `--canary-init` / `--canary-verify` / `--canary-status` — a token-and-TTL gate (backed by the C++ `antcrate-core` binary) that forces an agent to re-read the hard rules before any destructive op when its context may have been compacted. Every destructive flag runs through it.
- **Registry hygiene:** `--ghosts` lists entries whose path vanished; `--deregister` drops a ghost capture-first, and *refuses* if the path still exists.

### Git, GitHub, and hooks

- `--commit` — staged commit with a secret-pattern guard and Gateway-Law preview prompt.
- `--pp` — push-pipe with conflict triage: rejection emails a truncated diff, full log kept at `/tmp/antcrate_conflict.log`.
- `--gh-init` — GitHub repo creation over HTTPS, **private by default**; `--bootstrap` chains init + `.gitignore` + first commit in one idempotent call.
- **Hook suite:** `--hooks`, `--hook-install` (4 shipped templates: CI, secrets, stack-aware bash, pre-push tests), `--hook-remove`, `--hook-debug` (annotated re-run with trace), `--hook-bypass` (single-shot, reason-required, dual audit-logged), `--hook-render`, `--hook-audit`, `--hook-autoinstall` (profile-driven), `--hook-log`, `--hook-smoke` (pipe a synthetic payload into any Claude Code hook and propagate its verdict).

### Agent governance

The layer that makes AntCrate an AI-development boundary rather than just a CLI:

- **Claude Code hooks** (`assets/code/hooks/claude/`): `gateway-guard.sh` blocks bare destructive shell commands before they execute; `env-guard.sh` keeps secret *values* out of the transcript (names and assignment are fine; display sinks are blocked); `session-budget-guard.sh` gates on context-window size — soft warn at 100k tokens, hard block at 140k with a wrap-up whitelist, so a session can never run itself off a cliff; `shellcheck-on-save.sh` lints every shell edit on write; `local-install-guard.sh` blocks reflexive system-wide and opaque (`curl | bash`) installs, steering to the local, pinned `--tool-install` path with an audited bypass.
- **Delegation:** `--delegate` hands a focused edit to a project-scoped agent with an attempt counter that refuses after a threshold — no infinite retry loops. `--agent-init`, `--md-scaffold`, `--profile`, and `--env-scan` provision a project for agent work.
- **Duties:** `--duty` / `--duties` / `--duty-done` — a first-class checklist for actions only the human may perform (key rotation, policy approvals, config edits). Agents file duties; they never close them.
- **Proposals:** `--propose` / `--proposals` — the escape valve described in the contract above.

### Loop engine

`--loop "<objective>" --project <p>` starts a durable autonomous work loop that composes with Claude Code's `/loop`: each `--loop-tick` advances the objective under **three hard stops** (max iterations, no-progress detection, budget — wall-clock seconds or real USD) and a **two-key verify**: the loop cannot sign itself off; a reviewer records the semantic verdict via `--loop-signoff`. `--loop-status`, `--loop-list`, `--loop-resume`, `--loop-halt` manage the fleet. Halts checkpoint and quarantine — nothing is lost mid-objective.

### Awareness and accounting

- **Activity stream:** `--emit-activity` appends durable JSONL events; `--watch` paints a live colored project tree from them (severity-ordered: delete > modify > delegate > think > read); `--watch-window` spawns it in a detached terminal.
- **Intel tracker:** `--intel-pull` / `--intel-new` / `--intel-ack` / `--intel-status` — snapshot-on-change tracking of pinned Anthropic-official sources (any other host is refused before fetch). A daily timer retrieves; classification stays with the human/agent. Append-only; nothing is ever deleted.
- **Cost:** `--cost` computes real-dollar spend from Claude Code session transcripts, per-model — and backs the loop engine's USD budget mode.
- **Health:** `--selfcheck` verifies the tool's own persistence (registry path, skill link, git state, unpushed work, backup age); `--status` carries one-line summaries of intel, audit cadence, and open duties.
- **Diagrams:** Mermaid views of the whole registry and every project tree, auto-regenerated on every mutating action and filesystem event. Diagrams are a function of state, not a snapshot.

### Bundles

`--ingest` consumes typed research bundles (manifest-validated before any disk write, four source types, relationship semantics including backup-gated `supersedes`) per [BUNDLE_SPEC.md](assets/docs/BUNDLE_SPEC.md) — the handshake that lets a research machine hand work to a dev machine.

## Documentation

| Document | What it covers |
|---|---|
| [docs/MANUAL.md](docs/MANUAL.md) | **The manual** — every command, file, env var, exit code, man-page style |
| [assets/docs/PATTERNS.md](assets/docs/PATTERNS.md) | Flag-by-intent index (what agents read first) |
| [assets/docs/architecture.md](assets/docs/architecture.md) | System blueprint: schema, daemon, registry, triage |
| [assets/code/AGENTS.md](assets/code/AGENTS.md) | The hard rules for agents and automated tools |
| [assets/code/README.md](assets/code/README.md) | Codebase walkthrough for contributors |
| [assets/docs/BUNDLE_SPEC.md](assets/docs/BUNDLE_SPEC.md) | Research-to-dev bundle handshake contract |
| [assets/docs/HOOK_PLAN.md](assets/docs/HOOK_PLAN.md) | Hook surface design and history |
| [SKILL.md](SKILL.md) | Claude Code skill manifest (agent integration metadata) |

## Dependencies

**Required:** Bash 5+, jq, inotify-tools, git, mailx or sendmail, flock (util-linux). `--init` reports anything missing.

**Optional:** `gh` for GitHub repo creation; `mmdc` / `plantuml` / `d2` for diagram rendering (Mermaid sources render inline on GitHub regardless); `cmake` + `g++` for the `antcrate-core` C++ helper; `bats-core` + `shellcheck` to run the test/lint suite — fetch both locally with `antcrate --tool-install bats` / `--tool-install shellcheck` (no root). `--ci` detects absent optional tools and skips their stage with a log line.

## CI

`antcrate --ci` runs shellcheck on every `.sh` file, the full bats suite, and cmake build + ctest for the C++ core — fail-fast, exit 0 only when all pass. Every PASS records a snapshot to `~/.local/state/antcrate/ci-baseline.json`, which drives a periodic codebase-audit cadence surfaced in `--status`.

The same `--ci` runs in GitHub Actions on every push and PR, and is available locally as an opt-in pre-commit hook:

```bash
git config core.hooksPath .githooks
```

## Status

**746 bats tests** across 66 files, shellcheck clean, 17 doctest cases on the C++ core (`antcrate-core`, Wave 1: the compaction-canary subsystem). Baseline sha `12d147d`.

Solo-maintained, pre-1.0; the CLI surface may still shift before a v1 tag. The live work queue and append-only decision log are kept in the maintainers' local `dev/` records (not published). AntCrate develops AntCrate: this repo is itself a registered project, pushed via `antcrate --pp antcrate`, gated by its own hooks and CI.

## Contributing

Issues are welcome; PRs are reviewed against current in-flight work — read `state.md` first. See [CONTRIBUTING.md](CONTRIBUTING.md) for the test gate, commit style, and proposal process.

## Security

AntCrate wraps `git push`, executes repo-local hooks, runs an `inotifywait` daemon, and sits in the path of AI-agent tool calls — a non-trivial attack surface even at user privilege. Secret values are kept out of agent transcripts by design (`env-guard`), remotes default to private, and no automated path deletes user data. Vulnerability reports go through GitHub's private vulnerability reporting, not public issues; details in [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
