# AntCrate

**One controllable surface for solo and AI-assisted development.** AntCrate is the governance layer that lets you — and the AI agent working beside you — move fast across many projects while every risky action stays *backed up, approved, and reversible*.

Modern development, especially with an AI coding agent in the loop, means a lot of powerful, occasionally irreversible actions — renames, deletes, pushes, hook execution, secret handling — scattered across projects. The usual choice is speed *or* control. AntCrate removes that trade-off: it makes one auditable entry point the only way those actions happen, so the agent (or you at 2am) can work at full speed inside a project while the dangerous paths stay narrow and gated. Nothing runs elevated; everything lives under your own home directory.

It began as a project scaffolder. It became a **boundary** — the single place where structural, destructive, and remote-facing operations route through backup-and-approval gates before they touch disk or a remote.

---

## What AntCrate is for

- **A safety boundary around risky operations.** Rename, remove, push, restore, hook execution — none of them happen without passing one gate that enforces a backup and an explicit approval first.
- **A governance layer for AI agents.** An agent can operate freely inside your projects, but every action that could lose work or leak a secret is intercepted, logged, and either approved or refused — never silently executed.
- **A single source of truth for your projects.** One registry knows every project, its layout, its remotes, and its history — so tools and agents stop guessing and start asking.
- **A calm, honest status surface.** One command tells you the real state of everything and, for anything wrong, prints the exact command to fix it.

Built in Bash so it runs anywhere a shell does, at user privilege, with no daemon running as root and no service you have to trust.

---

## The Gateway Law

Five principles shape everything AntCrate does. They are enforced in code, not left to discipline:

1. **No destructive operation without a verified backup and explicit human approval.** This is checked before the action runs, every time.
2. **Quarantine over deletion.** Automation never deletes your data — it archives and sets it aside. Only a human ever permanently removes anything; there is deliberately no "purge" shortcut.
3. **Updates and removals come last.** Any change that could break something follows a fixed chain: read the current state → confirm nothing depends on it → back up → show you the result → get approval → only then execute.
4. **Agents propose, humans approve.** When an agent needs something the gates don't allow, it files a proposal instead of forcing the action. The proposal log is how it says "I needed this" without crossing the line.
5. **Automation retrieves; people decide.** Background tasks fetch, snapshot, and watch — but nothing automated ever interprets meaning or edits your code on its own.

---

## Installation

AntCrate installs without root and keeps all of its state in your home directory. It runs on **Linux** and **macOS** (Apple Silicon and Intel).

### Dependencies

The installer hard-requires only three things and refuses to proceed without them: **bash ≥ 4**, **jq**, **git**, and a file watcher (`inotifywait` on Linux, `fswatch` on macOS). Everything else is optional — but each unlocks a specific advertised feature, and without it that feature degrades with a printed notice rather than failing silently:

| Optional | Unlocks |
|---|---|
| `sqlite3` **built with FTS5** | `antcrate rag` — the BM25 retrieval index |
| `gh` (GitHub CLI) | `antcrate pp` remote creation, `gh-init`, the private `-dev` mirror |
| `gitleaks` | the secrets stage of `antcrate scan` |
| `shellcheck`, `bats` | `antcrate self ci` — the test and lint gate |
| `mailx` or `sendmail` | e-mail notification on push-rejection triage |

`shellcheck`, `bats`, and `gitleaks` do not need a package manager — `antcrate tool install <name>` fetches pinned binaries into AntCrate's own data directory, no root involved.

### Linux

```bash
# 1. Dependencies (Debian/Ubuntu shown; the installer prints the right hint for dnf/pacman/zypper)
sudo apt-get install -y bash jq git inotify-tools sqlite3

# 2. Install — no root; the installer checks your system and sets everything up
git clone https://github.com/zeppybabe/antcrate.git ~/antcrate-src
bash ~/antcrate-src/assets/code/install.sh

# 3. Put the wrapper on your PATH (the installer does NOT edit your shell rc)
export PATH="$HOME/.local/bin:$PATH"          # add this line to ~/.bashrc or ~/.zshrc

# 4. Confirm
antcrate st
```

### macOS

```bash
# 1. Dependencies — Homebrew is the supported source (macOS ships an ancient bash;
#    AntCrate uses whichever modern bash is on your PATH)
xcode-select --install     # git + developer tools, once
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install bash jq fswatch gh sqlite

# 2. Install — the same installer detects macOS and adapts (fswatch for the live
#    watcher, launchd agents in place of systemd services)
git clone https://github.com/zeppybabe/antcrate.git ~/antcrate-src
bash ~/antcrate-src/assets/code/install.sh

# 3. Put the wrapper on your PATH (the installer does NOT edit your shell rc)
export PATH="$HOME/.local/bin:$PATH"          # add this line to ~/.zshrc

# 4. Confirm
antcrate st
```

> **Step 3 is not optional.** The installer deliberately never edits a shell rc file — that is your territory. It prints the `export` line it needs and the status panel repeats it under `health:` until you act. If `antcrate st` returns `command not found`, this is why.

> **Installing from inside Claude Code?** AntCrate's own shipped hook blocks `sudo apt-get install`, `brew install`, and `curl | sh` — including the step-1 lines above. That is the local-install guard doing its job. Prefix the command with `ANTCRATE_ALLOW_SYSTEM_INSTALL=1`, or run step 1 in a normal terminal.

### What the installer actually does

It is idempotent, runs entirely at user privilege, and writes nothing outside your home directory. In full, it:

1. **Checks your shell and tools** and fails fast with a per-platform hint if bash is too old or a required tool is missing.
2. **Installs the wrapper** — `antcrate` and `antcrated` into `~/.local/bin`, and the libraries, templates, and hook templates into `~/.local/share/antcrate/`. Copies use a temp-and-rename so a running wrapper is never truncated mid-execution.
3. **Prunes retired libraries** — installed `*.sh` files that no longer exist in the source are removed, so a lib deleted upstream does not live on forever in your install.
4. **Migrates a legacy layout** — an older `~/.antcrate/` tree is moved once into the XDG directories.
5. **Creates your workspace root** — `~/Projects` (override with `ANTCRATE_ROOT`), and prints a short orientation the first time it does.
6. **Records the source path** as `ANTCRATE_SELFSRC` in `~/.config/antcrate/config`, so `self src`, `self test`, and `self edit` can find the checkout.
7. **Registers the clone itself** as a project named `antcrate`, and symlinks `~/.claude/skills/antcrate` → your checkout so Claude Code can load the skill. An existing non-symlink at that path is left alone and reported.
8. **Renders background units** — five systemd user units on Linux (`antcrated`, `antcrate-backup.{service,timer}`, `antcrate-intel.{service,timer}`), or three launchd agents on macOS. **They are written but never started.** Enabling them stays a human decision; the status panel prints the command until you do.
9. **Seeds the model/budget policy** at `~/.local/state/antcrate/anycrate/policy.json` if absent. A file that already exists is your territory and is left untouched.
10. **Prints the status panel** — the installer is also the doctor. Anything left to do appears there with a copy-pasteable fix beside it. There is no separate `init` or `doctor` step.

### Where your state lives

Everything follows the XDG layout and honors the usual overrides:

| Path | Holds |
|---|---|
| `~/Projects` | your projects (override: `ANTCRATE_ROOT`) |
| `~/.config/antcrate/config` | your settings — **human-only; agents read it, never write it** |
| `~/.local/share/antcrate/` | registry, installed libs, templates, hooks, intel snapshots, pinned tools |
| `~/.local/state/antcrate/` | backups, quarantine, logs, proposals, policy |
| `~/.claude/skills/antcrate` | symlink to your checkout, for Claude Code |

Uninstalling is removing those paths and the two binaries in `~/.local/bin`.

---

## Everyday use

You drive AntCrate with short, readable words. A typical day looks like this:

```bash
antcrate st                    # the whole picture: projects, daemon, backups, health — misses show their fix
antcrate new site --domain webapps   # scaffold a new project, registered from birth
antcrate map site              # see its live structure
antcrate commit site -m "..."  # a guarded commit: previews the change, scans for secrets first
antcrate pp site               # push with a pre-flight panel and conflict handling — never a silent failure
antcrate bak site              # a verified, restorable backup on demand
antcrate duty ls               # the running list of things only you (not an agent) should do
```

Two ideas make the daily flow smooth:

- **You never need to `cd`.** Every command takes the project by name and runs anchored at its root.
- **The tool is self-describing.** `antcrate st` is the single place to learn what's healthy, what isn't, and exactly how to fix what isn't — so you rarely have to consult the manual.

### The whole command surface

You type **words**, not flags. Leading `--flags` were retired as input in July 2026; typing one exits 2 and prints the word form to use instead. (`antcrate help --all` still prints the legacy flag names — that page is the *internal* action map, not the CLI you type. `antcrate help` is the real one.)

| Command | What it does |
|---|---|
| `st` | Status and health for everything: daemon, registry, duties, backups, ghosts, unread intel. Every problem prints its own fix. |
| `list` · `info <p>` · `diff <p>` · `logs [p] [n]` | Read-only views: all projects, one project's record, its working diff, its logs. |
| `new <n> --domain <d>` | Scaffold a project — directory layout, git init, markdown skeletons, agent pointer — registered from birth. |
| `reg <n> <path>` | Register a tree that already exists. |
| `commit <p> -m "…"` | Guarded commit: previews the change and scans for secret patterns before staging. `--all-tracked` or `-- <files…>`. |
| `pp <p>` | Pre-push panel, then commit and push. **Read the note below — this one restructures your repo.** |
| `bak <p>` · `bak ls <p>` · `bak restore <p> [--at <ts>]` | Take, list, and restore verified backups. Restore refuses a non-empty target unless you set `ANTCRATE_RESTORE_OVERWRITE=1`. |
| `mv <old> <new>` · `arc [-u] <p>` · `rm <p>` | Rename, archive/unarchive, remove. All three back up first and file a review duty. |
| `duty [ls\|add "…"\|done N\|clear]` | The checklist of things only a human should do. Agents can add; only you can check off. |
| `propose <name> "<intent>"` · `proposals` | How an agent asks for something the gates do not allow, instead of forcing it. |
| `hook <ls\|log\|install\|rm\|debug\|smoke\|render\|bypass\|audit\|auto> <p>` | Manage repository-local git hooks from one place. |
| `self <check\|test\|ci\|plugin\|src\|edit\|install>` | AntCrate operating on itself: verify, run the suite, lint gate, build the Claude Code plugin, locate or update the install. |
| `tool <install\|ls\|path>` | Fetch pinned `shellcheck` / `bats` / `gitleaks` binaries into AntCrate's data dir. No root. |
| `scan [path]` | Publication gate: secret scan, dev-tree leak check, marker check. This is what CI runs. |
| `rag <init\|index\|q> <p> ["<query>" [n]]` | Deterministic BM25/FTS5 retrieval over a project. Self-healing index — query it before you grep. |
| `intel <pull\|ls\|ack\|st>` | Change feed for upstream sources, seeded with Anthropic's. Retrieval is automated; judgment is not — nothing is ever auto-applied. |
| `map <p>` · `in <p> -- <cmd>` · `anchor <p>` | See a project's addressed structure; run a command anchored at its root; export its path to your shell. |
| `watch [<p>]` · `fetch <url>` · `gc <p>` · `gc ghosts` | Live watcher, guarded download, cleanup candidates, stale-registry sweep. |
| `policy [seed]` | Model, budget, and endpoint policy used by the agent-facing gates. |
| `post x <p> [--draft "…"]` | Draft a project update into the repo's `X-POSTS.md` for you to copy out. Nothing is ever posted for you. |

> ### What `pp` does to your repository
>
> `antcrate pp <project>` is more than commit-and-push, and this deserves to be explicit before you first run it.
>
> AntCrate maintains a **publication boundary**: agent-facing context (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `ledger.md`, `state.md`, `duties.md`, `X-POSTS.md`, `.cursor/`, `.windsurf/`) is kept out of your project's public tree and moved into a git-ignored `dev/` directory. On first `pp`, AntCrate therefore adds exclude rules to `.git/info/exclude`, copies that material into `dev/context/`, and runs `git rm --cached` on any of those paths that were previously tracked — so **your next push records a deletion of files you had committed**. This is intentional and reversible (the content is in `dev/`, and `.git/info/exclude` is local), but it is not what "push" usually means.
>
> Because that boundary would otherwise be a silent delete, `pp` also **creates a private companion repository** named `<owner>/<project>-dev` via the `gh` CLI, so the dev material has a home. This is **on by default** since July 2026.
>
> To opt out, in `~/.config/antcrate/config`: `mirror_dev_exclude=<project>` for one project, or `mirror_dev_all=0` globally.

The full command reference lives in **[docs/MANUAL.md](docs/MANUAL.md)**, and the by-intent index an agent reads first is **[PATTERNS.md](assets/docs/PATTERNS.md)**. Both predate the move to word commands in places and are being brought forward; `antcrate help` is always authoritative.

---

## How it works

- **A single registry is the source of truth.** One record holds every project's path, layout, relationships, and remotes. Every read and write goes through it atomically — no hand-edited state, no drift, no two tools disagreeing about reality.

- **A live daemon keeps everything current.** A lightweight background watcher (inotify on Linux, fswatch on macOS) notices filesystem changes and keeps each project's structure diagram up to date automatically. Diagrams are a function of the current state, never a stale snapshot.

- **One safety gate guards the dangerous paths.** Anything that could lose work or expose a secret funnels through a single chokepoint that backs up first and asks for approval. Push failures are captured and surfaced, never swallowed.

- **Scheduled work is retrieval only, and opt-in.** Two background timers ship alongside the daemon: a periodic backup and an upstream-intel fetch. The installer writes the units but never starts them — you enable them, and the status panel keeps printing the command until you do. They fetch, snapshot, and watch; **nothing automated ever interprets meaning or edits your code.**

- **It runs the same on Linux and macOS.** A small compatibility layer probes for what the host actually provides and adapts — the Linux world of inotify and systemd and the macOS world of fswatch and launchd are both first-class, from one codebase.

---

## Working alongside an AI agent

This is what makes AntCrate more than a CLI. When a coding agent operates inside your projects, AntCrate sits in the path of its actions:

- **Destructive shell commands are intercepted** before they run, and routed through the same backup-and-approval gate a human would face.
- **Secret *values* stay out of the conversation** — an agent can reference and set them, but never print them into a transcript.
- **A running session can't drive itself off a cliff** — it's warned as its working context fills and stopped before it overruns, with room reserved to wrap up cleanly.
- **Duties and proposals draw the human line.** Actions only a person should take (rotating a key, approving a policy, editing protected config) live on a checklist an agent can add to but never check off; when an agent needs something out of bounds, it proposes rather than forces.

The result is an agent that can be genuinely useful at speed without you having to watch its every keystroke.

### The Claude Code plugin

Those protections are delivered as a **Claude Code plugin**, shipped in this repository under [`plugin/`](plugin/) and listed in `.claude-plugin/marketplace.json`. Installing it wires AntCrate's perimeter into Claude Code:

- blocks recursive deletes and whole-root moves inside registered projects, and writes to critical-zone paths;
- keeps secret *values* out of the transcript;
- injects your open duties and unread intel at session start;
- warns as the session's context budget fills, and stops it before it overruns.

Build or refresh it with `antcrate self plugin`. Setup lives in [`plugin/README.md`](plugin/README.md) — follow that file rather than wiring hooks into `settings.json` by hand.

### Backups, quarantine, and getting your work back

Every destructive command backs up *before* it acts, and every backup is a plain `.tar.gz` under `~/.local/state/antcrate/backups/<project>/` that you can open with ordinary tools. Nothing about recovery depends on AntCrate still working.

When no human is present to approve, a destructive command does not silently proceed and does not silently refuse: it takes the backup, performs the action, prints a warning, and **files a review duty naming the backup path**, so the decision waits for you in `antcrate duty ls`.

Automation never deletes. It quarantines — `antcrate --quarantine-list <p>` shows what is set aside, `antcrate --quarantine-restore <p> --at <ts>` puts it back. There is deliberately no purge command; only a human ever permanently removes anything.

> After restoring a project that was fully removed, its registry entry does not come back with it. Re-add it with `antcrate reg <name> <path>` — otherwise later commands will report the project as unknown.

---

## BizCrate — the business-facing sibling

The same governance philosophy, packaged for organizations rather than developers. **BizCrate** is a "backend-in-a-box": one command installs a governed, **local-first** AI-operations layer for small businesses and non-profits — data stays on the machine by default, every AI action is budgeted and written to an append-only audit trail, and the pipeline produces useful output even with zero AI spend. It's built with AntCrate and ships standalone (no AntCrate dependency on the client's machine).

Think of it as a family: **AntCrate** governs *developer* operations, **BizCrate** governs *business* operations, both on the same principle — make the risky paths narrow, audited, and reversible, and keep the human in the loop.

---

## Documentation

| Document | What it covers |
|---|---|
| [docs/MANUAL.md](docs/MANUAL.md) | The full reference — every command, file, and setting |
| [assets/docs/PATTERNS.md](assets/docs/PATTERNS.md) | By-intent index: "I want to do X" → the command for it |
| [assets/docs/architecture.md](assets/docs/architecture.md) | System blueprint: registry, daemon, safety gate |
| [assets/code/AGENTS.md](assets/code/AGENTS.md) | The hard rules for agents and automated tools |
| [SECURITY.md](SECURITY.md) | Security posture and how to report a vulnerability |
| [plugin/README.md](plugin/README.md) | Installing and configuring the Claude Code plugin |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Test gate, commit style, and proposal process |

---

## Project status

Solo-maintained and pre-1.0 — the surface may still shift before a v1 tag. The full test suite runs on **both Linux and macOS in CI** and stays green, with shellcheck clean across the codebase. AntCrate develops AntCrate: this repository is itself a registered project, backed up, committed, and pushed through its own gates.

## Security

AntCrate wraps `git push`, executes repository-local hooks, runs a filesystem-watching daemon, and sits in the path of AI-agent actions — a real attack surface even at user privilege. Secret values are kept out of agent transcripts by design, new remotes default to private, and no automated path ever deletes your data. Please report vulnerabilities through GitHub's private vulnerability reporting rather than public issues — see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
