# AntCrate Harness-Enforcement Layer — Design Spec

- **Date:** 2026-05-31
- **Status:** Approved (pending spec review)
- **Author:** Clyde (orchestrator) + user
- **Scope:** Promote four prose-only protocols from `~/CLAUDE.md` into real Claude Code harness automations.

## Problem

`~/CLAUDE.md` encodes many *automatic* protocols (shellcheck-must-pass, no bare
`git push`/`mv`/`rm` on registered projects, the 3-part session-close sweep), but
`~/.claude/settings.json` has **no `hooks` block**. Every rule is honor-system —
enforced by the model remembering prose, not by the harness. This converts the
highest-stakes rules into mechanical enforcement, and packages the recurring audit
and session-close work into reusable units.

## Goals

1. Make AntCrate the colony's **whole-system perimeter** — the only sanctioned
   create/destroy zone is a registered project tree; all other destructive ops
   on the system are gated (Gateway Law, system-wide).
2. Enforce the "shellcheck must pass" convention at edit time.
3. Make the AGENTS-rule codebase audit a reusable, read-only subagent.
4. Make the 3-part session-close protocol a single user-invoked skill.
5. Stay consistent with AntCrate philosophy: scripts versioned in the AntCrate
   repo; each new surface logged via `antcrate --propose`.

## Guiding principle — the colony perimeter

AntCrate exists to keep the colony continuously running. An autonomous agent that
can perform destructive filesystem or system operations *anywhere* on the machine
is not safe and not at ease. So the perimeter is the **entire system**, not just
registered projects. **Sanctioned destruction happens only through project-scoped
AntCrate channels** — deghosting (`--ghosts`), file/project audits, quarantine
(`--quarantine-*`), and root `--remove`/`--rename`. Everything else destructive —
to system paths, to identity/config files, or via dangerous system commands
(a daemon that goes haywire can do hidden hardware-level damage) — is what the
guard exists to limit. This principle threads through the entire
harness-enforcement layer, with the gateway-guard as its primary instrument.

## Non-goals (YAGNI)

- `bash-language-server` LSP integration — separate, optional, not built here.
- Replacing the existing git-hook `templates/` (pre-commit etc.) — untouched.
- Routing this build through Cody/Claudia — these are harness-config artifacts
  outside any registered project's scope; built directly by the orchestrator.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Perimeter scope | **Whole system**, tiered by zone (sanctioned / critical / neutral) — not just registered projects |
| Sanctioned zone (project trees) | Edits flow; only root wipe/rename + recursive delete gated → `--remove`/`--rename`/quarantine/deghost/audit. Single-file `rm` allowed |
| Critical zone (system + identity + control plane) | **Hard-block** destructive fs ops **and** dangerous system commands |
| Neutral zone (rest of `~`, `/tmp`) | **Warn** (advisory), op proceeds — never wedge scratch cleanup |
| `git push` (any zone) | **Warn** → name `antcrate --pp` |
| shellcheck-on-save | **Block-style** (exit 2 surfaces findings the model must address); clean = silent |
| Auditor model | **Sonnet** (matches Cody) |
| `/session-close` invocation | **User-only** (`disable-model-invocation: true`) |

## Protection zones

| Zone | Paths | Treatment |
|---|---|---|
| **Sanctioned** | Registered project trees (`.projects[].path`) + quarantine machinery | Edits allowed; root wipe/rename + recursive delete **blocked** (→ sanctioned channels); single-file `rm` allowed |
| **Critical** | `/etc /usr /bin /sbin /lib /boot /sys /proc /dev /var`, root `/`; identity/shell files `~/.bashrc ~/.zshrc ~/.profile ~/.ssh ~/.gnupg ~/.config`; AntCrate control plane `~/.antcrate` (and the `antcrate` registered root) | **Hard-block** destructive fs ops + dangerous commands |
| **Neutral** | Everything else under `~` and `/tmp` not in the above | Destructive op → **warn**, proceeds |

**Sanctioned destruction channels** (the only blessed ways to remove): `antcrate
--ghosts` (deghost), project file/audit flows, `antcrate --quarantine-*`, and
`antcrate --remove` / `--rename` for whole roots.

**Dangerous-command class** (hard-blocked regardless of path, since they can damage
the system/hardware): `dd`, `mkfs*`, `fdisk`/`parted`/`mkswap`, writes to
`/dev/sd*`/`/dev/nvme*`, recursive `chmod -R`/`chown -R` on non-project paths,
fork bombs (`:(){ :|:& };:`), kernel-module loads (`modprobe`/`insmod`/`rmmod`),
installing/enabling new daemons (`systemctl enable|start|disable`,
`service … start`, `crontab` installs), `> /dev/...` redirects.

## Registry facts (verified)

`~/.antcrate/registry.json` shape: `{ "projects": { "<name>": { "path": "<abs>", ... } } }`.
Registered roots resolve via `jq -r '.projects[].path'`. The `antcrate` project's
own root is `/home/twntydotsix/.claude/skills/antcrate`, so the guard also protects
AntCrate's code tree (desired).

## Placement

All Claude-Code hook scripts live in:

```
~/.claude/skills/antcrate/assets/code/hooks/claude/
  _zones.sh             # shared: registered roots (from .projects[].path) +
                        #   static CRITICAL_PATHS + DANGEROUS_CMD patterns
  gateway-guard.sh      # PreToolUse / Bash — tiered perimeter
  shellcheck-on-save.sh # PostToolUse / Edit|Write
```

The critical-path set and dangerous-command patterns live as auditable arrays in
`_zones.sh` — one place to review the guard's security surface.

This is a write-zone and the AntCrate git repo, distinct from the existing
git-hook `hooks/templates/`. Hooks are referenced from settings.json by absolute
path (Claude Code does not reliably expand `~`).

---

## Component 1 — `gateway-guard.sh` (PreToolUse / Bash)

**Input:** hook JSON on stdin; reads `.tool_input.command`.

**Logic:**

1. Resolve registered roots via `_zones.sh` (reads `.projects[].path`). Critical
   paths and the dangerous-command list are **static** (no registry needed).
2. Tokenize the command string (split on `;`, `&&`, `||`, `|`; per segment pull
   the argv0 and path-like args, resolving `./`-relative args against `$PWD`).
3. Classify each segment, **most-protective rule wins**:
   - **BLOCK — dangerous command** (any zone): argv0/pattern matches the
     dangerous-command class (`dd`, `mkfs*`, `fdisk`/`parted`/`mkswap`, `modprobe`
     /`insmod`/`rmmod`, `systemctl enable|start|disable`, `service … start`,
     `crontab` install, fork-bomb signature, `> /dev/...`, writes to
     `/dev/sd*`/`/dev/nvme*`, `chmod -R`/`chown -R` on a non-sanctioned path).
   - **BLOCK — critical zone:** any `rm`/`mv`/redirect whose target lands in the
     critical zone (system paths, identity/shell files, `~/.antcrate`, the
     `antcrate` root) — including writes to `~/.antcrate/registry.json`.
   - **BLOCK — sanctioned zone, root/recursive:** `rm`/`mv` whose target **is** a
     registered root, OR a recursive-delete form (`-r`/`-R`/`-rf`/`--recursive`)
     naming any path under a registered root.
   - **WARN — neutral zone:** a destructive `rm`/`mv` whose target is under `~`
     (not in a registered tree, not critical) or under `/tmp`.
   - **WARN — push:** a `git push` not part of an `antcrate --pp` invocation.
   - **ALLOW:** single-file `rm` inside a registered tree (normal editing); reads
     and non-destructive commands everywhere.

**Output / exit codes:**

- BLOCK → `exit 2`; stderr states the zone, the violation, and the sanctioned
  AntCrate channel (`--remove`/`--rename`/`--ghosts`/`--quarantine-*`, or "mutate
  via lib/registry.sh", or "system op outside the colony perimeter — not
  permitted"). Claude Code treats PreToolUse exit 2 as *deny* and feeds stderr to
  the model.
- WARN → `exit 0`; advisory to stderr (non-blocking) naming the sanctioned channel.
- ALLOW → `exit 0`, silent.

**Fail-open boundary:** if `jq`/registry is unreadable, the registry-dependent
rules (sanctioned-zone root/recursive, neutral-vs-sanctioned classification) fail
**open** with a one-line stderr note — the guard must never wedge the session.
**Critical-zone and dangerous-command rules are static and still fire** even with a
broken registry, so system protection never depends on registry health. When a
target path cannot be resolved, critical-zone and recursive-delete rules fall back
to literal substring match against the known critical/root path set to stay safe.

## Component 2 — `shellcheck-on-save.sh` (PostToolUse / Edit|Write)

**Input:** hook JSON on stdin; reads `.tool_input.file_path`.

**Logic:**

1. If path does not end in `.sh`, or is not under
   `~/.claude/skills/antcrate/assets/code/`, → `exit 0` silent.
2. If `shellcheck` is absent → `exit 0` with one-line note (token-efficient skip).
3. Run `shellcheck -x <file>`.

**Output / exit codes:**

- Findings → `exit 2` with the shellcheck report on stderr (block-style: the
  model must address before proceeding).
- Clean → `exit 0`, silent.

## Component 3 — `agents-rule-auditor` subagent

**File:** `~/.claude/agents/agents-rule-auditor.md`

**Frontmatter:**

```yaml
---
name: agents-rule-auditor
description: Read-only AGENTS.md rule + doc-drift scan of the AntCrate codebase. Dispatch (foreground) during session-close part 2, or on demand, to grep lib/*.sh + bin/antcrate for hard-rule violations and Shipped-claim drift. Returns a classified report; never edits.
tools: Read, Grep, Glob, Bash
model: sonnet
---
```

**Behavior (body):** read-only scan of `assets/code/lib/*.sh` + `assets/code/bin/antcrate` for the greppable AGENTS hard rules:

- bare `git push` (#12)
- bare `cd` into `~/projects/...` (#10)
- direct `registry.json` writes not via `lib/registry.sh` (#3)
- writes to `~/.antcrate/config` (#13)
- path-mutating ops outside `$ANTCRATE_ROOT` lacking the
  `ANTCRATE_ALLOW_OUTSIDE_ROOT` guard (#2)
- `--no-verify` references (#14)
- new/unjustified `# shellcheck disable=SC...` lines

Plus **doc-drift:** every "Shipped" claim in `HOOK_PLAN.md` / `BUNDLE_SPEC.md` /
`state.md` is confirmed against an actual flag in `bin/antcrate` and a lib
function. Output: a classified findings report; anything unclassifiable →
"file via `antcrate --propose`". No Edit/Write — strictly read-only.

## Component 4 — `/session-close` skill

**File:** `~/.claude/skills/session-close/SKILL.md`

**Frontmatter:**

```yaml
---
name: session-close
description: Run the 3-part AntCrate session-close sweep (command-sweep, codebase audit, end-of-session learning) before any wrap statement.
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash, Edit, Write, Agent, Skill
---
```

**Behavior (body) — operationalizes `~/CLAUDE.md` Session-Close Protocol:**

1. **Command-sweep:** walk the session for long/repeated/multi-step command
   patterns; for each candidate emit `antcrate --propose "<flag>" "<rationale>"`.
2. **Codebase audit:** read bats count delta vs `~/.antcrate/ci-baseline.json`
   (fallback: last `Test count NNN → MMM` line in `ledger.md`). When delta ≥ 100,
   **dispatch the `agents-rule-auditor` subagent foreground** (per the
   permissions memory: background agents cannot write; this one is read-only but
   foreground keeps dispatch uniform) and fold its report in.
3. **Learning:** update `state.md` top-of-mind with the resume target; append
   `ledger.md` if a non-obvious decision was made; save any cross-session
   user-preference/feedback/workflow change to `~/.claude/memory/`.

Skill ends by printing the sweep summary; it does not itself declare the session
closed (the orchestrator does, after reviewing).

## Component 5 — settings.json wiring (approval gate)

Add to `~/.claude/settings.json` (only the `hooks` block is new):

```json
"hooks": {
  "PreToolUse": [
    { "matcher": "Bash",
      "hooks": [{ "type": "command",
        "command": "/home/twntydotsix/.claude/skills/antcrate/assets/code/hooks/claude/gateway-guard.sh" }] }
  ],
  "PostToolUse": [
    { "matcher": "Edit|Write",
      "hooks": [{ "type": "command",
        "command": "/home/twntydotsix/.claude/skills/antcrate/assets/code/hooks/claude/shellcheck-on-save.sh" }] }
  ]
}
```

Applied via the `update-config` skill, only after explicit user OK. The exact diff
is shown before writing.

## AntCrate proposals

Log four `--propose` entries (recorded, not shipped), consistent with the
gh/obsidian fold-in pattern:

- `--gateway-guard` — PreToolUse Bash guard enforcing the Gateway Law
- `--shellcheck-gate` — PostToolUse shellcheck-on-save for `.sh`
- `--rule-audit` — wrapper to dispatch the agents-rule-auditor
- `--session-close` — wrapper/entry for the session-close sweep

## Testing

Bash fixture tests under `assets/code/tests/` (honors "new code gets a test"):

- `gateway-guard` — sanctioned zone:
  - `rm -rf <registered-root>/x` → exit 2
  - `mv <registered-root> <other>` → exit 2
  - `rm <root>/src/one.txt` (single file) → exit 0 silent
- `gateway-guard` — critical zone:
  - `rm -rf /etc/foo`, `mv ~/.ssh/id_rsa /tmp`, `rm ~/.bashrc` → exit 2
  - `jq ... > ~/.antcrate/registry.json` → exit 2
- `gateway-guard` — dangerous commands (any path):
  - `dd if=/dev/zero of=/dev/sda`, `mkfs.ext4 /dev/sdb1`,
    `systemctl enable myd.service`, `chmod -R 777 /usr`, fork-bomb signature → exit 2
- `gateway-guard` — neutral zone:
  - `rm /tmp/x`, `rm ~/scratch.txt` → exit 0 + advisory on stderr (warn, proceeds)
- `gateway-guard` — push & fail-open:
  - `git push origin main` → exit 0 + advisory
  - unreadable registry: registry-dependent rules fail-open (exit 0), but
    `rm -rf /etc/x` and a dangerous command **still** → exit 2 (static rules fire)
- `shellcheck-on-save`:
  - `.sh` with a known SC code under the code tree → exit 2 with report
  - clean `.sh` → exit 0 silent
  - non-`.sh` or out-of-tree path → exit 0 silent
- subagent + skill: manual smoke (dispatch auditor, eyeball report; dry-run
  `/session-close`).

## Implementation order

1. `_zones.sh` + `gateway-guard.sh` + its fixture tests.
2. `shellcheck-on-save.sh` + its fixture tests.
3. `agents-rule-auditor.md` subagent.
4. `session-close/SKILL.md` (wires to the subagent).
5. Show settings.json diff → on approval, apply via `update-config`.
6. Four `antcrate --propose` entries; update `state.md` / `ledger.md`.

## Risks

- **Over-blocking** the whole-system guard → mitigated by the tiered model:
  neutral zone only *warns*, single-file edits in projects are allowed, and the
  hard blocks are confined to the critical zone + a finite dangerous-command list.
- **Critical-zone list completeness** → the path set and command list are the
  guard's security surface; kept in one auditable table in `_zones.sh`,
  reviewed when the AGENTS rules change. Better to add a path than miss one.
- **Registry health** → critical-zone + dangerous-command protection is static and
  independent of the registry, so a corrupt/locked registry cannot disable
  system protection (only the project-scoped niceties fail open).
- **PostToolUse exit-2 friction** on shellcheck → accepted per decision; scoped to
  AntCrate code tree only.
- **Path-resolution false negatives** in the guard → critical-zone and
  recursive-delete rules fall back to literal substring match to stay safe.
