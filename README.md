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

### Linux

```bash
# 1. Dependencies (Debian/Ubuntu shown; the installer prints the right hint for dnf/pacman/zypper)
sudo apt-get install -y bash jq git inotify-tools

# 2. Install — no root; the installer checks your system and sets everything up
git clone https://github.com/zeppybabe/antcrate.git ~/antcrate-src
bash ~/antcrate-src/assets/code/install.sh

# 3. Confirm
antcrate st
```

### macOS

```bash
# 1. Dependencies — Homebrew is the supported source (macOS ships an ancient bash;
#    AntCrate uses whichever modern bash is on your PATH)
xcode-select --install     # git + developer tools, once
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install bash jq fswatch gh

# 2. Install — the same installer detects macOS and adapts (fswatch for the live
#    watcher, launchd agents in place of systemd services)
git clone https://github.com/zeppybabe/antcrate.git ~/antcrate-src
bash ~/antcrate-src/assets/code/install.sh

# 3. Confirm
antcrate st
```

The installer **is** the setup and the health check in one — it finishes by printing the status panel, and anything still left to do (enable the background daemon, install optional dev tools, sign in to GitHub, set your git identity) is listed there with a copy-pasteable command next to it. There is no separate init or doctor step to remember.

**Where your state lives.** Projects scaffold under `~/Projects` by default. AntCrate's own files follow the standard home-directory layout — config, data, and state each in their conventional place — and honor the usual environment overrides. Nothing is written outside your home directory or the projects you register.

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

The full command reference lives in **[docs/MANUAL.md](docs/MANUAL.md)**, and the by-intent index an agent reads first is **[PATTERNS.md](assets/docs/PATTERNS.md)**.

---

## How it works

- **A single registry is the source of truth.** One record holds every project's path, layout, relationships, and remotes. Every read and write goes through it atomically — no hand-edited state, no drift, no two tools disagreeing about reality.

- **A live daemon keeps everything current.** A lightweight background watcher (inotify on Linux, fswatch on macOS) notices filesystem changes and keeps each project's structure diagram up to date automatically. Diagrams are a function of the current state, never a stale snapshot.

- **One safety gate guards the dangerous paths.** Anything that could lose work or expose a secret funnels through a single chokepoint that backs up first and asks for approval. Push failures are captured and surfaced, never swallowed.

- **It runs the same on Linux and macOS.** A small compatibility layer probes for what the host actually provides and adapts — the Linux world of inotify and systemd and the macOS world of fswatch and launchd are both first-class, from one codebase.

---

## Working alongside an AI agent

This is what makes AntCrate more than a CLI. When a coding agent operates inside your projects, AntCrate sits in the path of its actions:

- **Destructive shell commands are intercepted** before they run, and routed through the same backup-and-approval gate a human would face.
- **Secret *values* stay out of the conversation** — an agent can reference and set them, but never print them into a transcript.
- **A running session can't drive itself off a cliff** — it's warned as its working context fills and stopped before it overruns, with room reserved to wrap up cleanly.
- **Duties and proposals draw the human line.** Actions only a person should take (rotating a key, approving a policy, editing protected config) live on a checklist an agent can add to but never check off; when an agent needs something out of bounds, it proposes rather than forces.

The result is an agent that can be genuinely useful at speed without you having to watch its every keystroke.

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
| [CONTRIBUTING.md](CONTRIBUTING.md) | Test gate, commit style, and proposal process |

---

## Project status

Solo-maintained and pre-1.0 — the surface may still shift before a v1 tag. The full test suite runs on **both Linux and macOS in CI** and stays green, with shellcheck clean across the codebase. AntCrate develops AntCrate: this repository is itself a registered project, backed up, committed, and pushed through its own gates.

## Security

AntCrate wraps `git push`, executes repository-local hooks, runs a filesystem-watching daemon, and sits in the path of AI-agent actions — a real attack surface even at user privilege. Secret values are kept out of agent transcripts by design, new remotes default to private, and no automated path ever deletes your data. Please report vulnerabilities through GitHub's private vulnerability reporting rather than public issues — see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
