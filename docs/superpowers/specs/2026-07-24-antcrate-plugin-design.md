# Design: `antcrate` Claude Code plugin — enforcement core (v1)

**Date:** 2026-07-24
**Status:** Approved design, pending implementation plan
**Home:** inside `antcrate-src` at `plugin/`, with a repo-root
`.claude-plugin/marketplace.json`. No new repo. Local install first
(`/plugin marketplace add ~/antcrate-src`); the identical layout serves a public
GitHub install later with no changes.

## Problem

AntCrate's Claude Code perimeter is **written but not loaded**.

Seven hook scripts live in `assets/code/hooks/claude/` and are installed to
`~/.local/share/antcrate/hooks/claude/` by `self install`:
`gateway-guard.sh`, `env-guard.sh`, `local-install-guard.sh`,
`cost-anticipator.sh`, `session-budget-guard.sh`, `activity-emitter.sh`,
`shellcheck-on-save.sh`.

`~/.claude/settings.json` wires **one** of them — `local-install-guard.sh`.
`gateway-guard.sh`, the Gateway Law perimeter itself, has never fired. Neither
has `env-guard.sh`. The Law is therefore enforced today only by agent goodwill:
an agent that has read `AGENTS.md` complies, an agent that has not does whatever
it likes.

Two further defects make the gap worse than "unwired":

1. **Wrong registry path.** `_zones.sh` resolves the registry as
   `${ANTCRATE_REGISTRY:-${ANTCRATE_HOME:-$HOME/.antcrate}/registry.json}`.
   That file exists but is a post-migration stub containing `{"projects":{}}`.
   The live registry has been at `$ANTCRATE_DATA_HOME/registry.json`
   (`~/.local/share/antcrate/registry.json`, 7 projects) since the XDG
   migration. `lib/paths.sh:30` gets this right; the hooks never followed.
   Consequence: **every registry-dependent rule in `gateway-guard` sees zero
   registered projects and falls open.** `activity-emitter.sh` carries its own
   copy of the same legacy default and exits 0 on every call, which is why the
   watch view never lights up.
2. **Double-fire risk.** The existing `settings.json` entry for
   `local-install-guard.sh` would run alongside the plugin's copy.

Wiring the hooks without fixing (1) ships a perimeter that guards nothing —
a worse outcome than the current state, because it *looks* enforced.

## Why a plugin rather than more `settings.json` entries

Editing `~/.claude/settings.json` by hand is exactly the un-versioned,
un-testable, un-removable configuration that the Gateway exists to abolish
everywhere else. A plugin makes the perimeter:

- **versioned** — the wiring is a file in the repo, reviewed and CI-checked;
- **atomic** — installs and uninstalls as one unit, no partial hand-edit state;
- **portable** — the same tree serves this machine and, later, anyone else;
- **inherited** — plugin hooks apply to subagents too, which is where an
  unenforced Law bites hardest.

This is the harness layer. AntCrate already owns the CLI layer (the wrapper),
the repo layer (git hooks), and the read layer (`antcrate-mcp`). The plugin is
the missing fourth.

## Decision summary (2026-07-24)

| Fork | Decision |
|---|---|
| v1 scope | **Enforcement core only** — hooks. No slash commands, no bundled MCP, no agents. |
| Audience | **Local first**, public once tested. Layout must not need rework to go public. |
| Script source of truth | **`assets/code/hooks/claude/` stays authoritative**; the plugin carries generated copies, drift-tested in `self ci`. |
| Hook set | **Five wired** (gateway, env, local-install, activity-emitter, shellcheck-on-save). `cost-anticipator` + `session-budget-guard` ship unwired, opt-in. |
| SessionStart | **Deltas only, silent when clean.** Read-only, no provisioning, no `antcrate` shellout. |
| Path defect | **Fixed at source** in `_zones.sh` + `activity-emitter.sh`, not papered over with plugin env. |

### Why generated copies rather than thin wiring

A `hooks.json` pointing at `$HOME/.local/share/antcrate/hooks/claude/*.sh` has
zero duplication and zero drift — but the plugin then does nothing on a machine
without AntCrate installed, so it can never ship standalone. Bundling copies
costs a build step and a drift test; it buys public distribution. The drift test
is what keeps the cost honest: a copy that diverges from its source fails CI.

### Why the budget pair stays unwired

`cost-anticipator.sh` and `session-budget-guard.sh` both parse the session
transcript and can block `Skill`, `Agent` and `Read` calls. Neither has run in a
real session. A misfire stalls the orchestrator's own workflow, which is a much
worse failure than a missing warning. They ship in the tree, documented, behind
a commented block in `hooks.json`. Promote in v1.1 once the perimeter is proven
live.

## Structure

```
antcrate-src/
  .claude-plugin/
    marketplace.json              # repo is its own marketplace (1 plugin)
  plugin/
    .claude-plugin/
      plugin.json                 # name, version, description, author
    hooks/
      hooks.json                  # HAND-WRITTEN wiring
      claude/                     # GENERATED — copies, never edited in place
        _zones.sh
        gateway-guard.sh
        env-guard.sh
        local-install-guard.sh
        activity-emitter.sh
        shellcheck-on-save.sh
        cost-anticipator.sh       # shipped, unwired
        session-budget-guard.sh   # shipped, unwired
      session-digest.sh           # NEW, hand-written, lives outside claude/
    README.md                     # install, what each hook does, how to disable
```

`plugin/hooks/claude/` is generated output and is **committed**. A consumer
installing from GitHub must not need a build step. `session-digest.sh` sits at
`hooks/` rather than `hooks/claude/` precisely so the generator can treat
`hooks/claude/` as wholly owned — it may delete anything there that has no
source counterpart.

## Component 1 — the wiring (`plugin/hooks/hooks.json`)

Every `command` is `${CLAUDE_PLUGIN_ROOT}`-relative. No `$HOME`, no absolute
paths.

| Event | Matcher | Hooks (in order) |
|---|---|---|
| `PreToolUse` | `Bash` | `gateway-guard.sh`, `env-guard.sh`, `local-install-guard.sh` |
| `PreToolUse` | `Read` | `env-guard.sh` |
| `PostToolUse` | `Edit\|Write\|Read\|NotebookEdit` | `activity-emitter.sh` |
| `PostToolUse` | `Edit\|Write` | `shellcheck-on-save.sh` |
| `SessionStart` | — | `session-digest.sh` |

`env-guard.sh` already handles both the Bash and Read shapes (it reads
`.tool_input.command` and `.tool_input.file_path`), so the same script is
registered under two matchers rather than split.

**Contract preserved unchanged:** these scripts communicate by exit code —
`2` blocks and feeds stderr back to the model, `0` allows. That is the same
contract they were written against for `settings.json`; plugin hooks execute
identically. No script logic changes for wiring purposes.

## Component 2 — the path fix (blocker)

In `assets/code/hooks/claude/_zones.sh`, replace the registry resolution with
the same order `lib/paths.sh` uses:

```
ANTCRATE_REGISTRY
  → ${ANTCRATE_DATA_HOME}/registry.json
  → ${XDG_DATA_HOME:-$HOME/.local/share}/antcrate/registry.json
  → $HOME/.antcrate/registry.json          # legacy, last
```

`ANTCRATE_HOME` keeps its own meaning (state home) and is no longer consulted
for the registry at all — conflating the two is the original bug.

`activity-emitter.sh` carries a duplicate legacy default at its top; it moves to
sourcing `_zones.sh` rather than re-deriving, so there is one resolver.

Fixed at source, then regenerated into the plugin, so `self install` and the
plugin both benefit. Existing fixture tests that set `ANTCRATE_REGISTRY`
explicitly are unaffected — the override still wins.

**Tests:** the XDG path wins when both it and the legacy stub exist; the legacy
path is still honored when it is the only one present; an explicit
`ANTCRATE_REGISTRY` overrides both.

## Component 3 — the SessionStart digest (`plugin/hooks/session-digest.sh`)

Purpose: replace the tokens an agent currently spends *asking* for state with a
bounded, automatic injection — and spend nothing at all when there is nothing to
say.

**Sources, all read directly as files. No `antcrate` invocation, no daemon
dependency:**

- **Duties** — `ANTCRATE_DUTIES_FILE`, else `<selfsrc>/dev/duties.md`, else
  `<selfsrc>/duties.md`, mirroring `_ac_duties_file`. Counts unchecked `- [ ]`
  lines and extracts the oldest ISO date among them.
- **Intel** — `$ANTCRATE_INTEL_DIR/new.jsonl` minus `acked.jsonl`, matched on
  `{source, sha256}`, the same predicate `ac_intel_new` uses. Count only.
- **Working trees** — for each project path in the registry, whether it is dirty
  (`git status --porcelain --untracked-files=no`) and whether it has unpushed
  commits (`git rev-list --count @{u}..HEAD`). Counts only, plus up to three
  project names.

**Output shape** — at most four lines, e.g.:

```
antcrate: 7 duties open (oldest 2026-07-17) · 26 intel unread · 2 dirty (rfm-music, antcrate) · 1 unpushed
```

**Silence when clean.** All three signals empty → exit 0 with no output. A quiet
session pays zero tokens. This is the property that makes an always-on
SessionStart hook acceptable at all.

**Bounded cost.** The git sweep is the only part that touches the filesystem
beyond a few small files. It carries a wall-clock budget (default 2s): once
exceeded, remaining projects are skipped and the line reports what was measured,
never a partial count presented as total. `ANTCRATE_DIGEST_GIT=0` skips the git
sweep entirely; `ANTCRATE_DIGEST_DISABLE=1` skips the whole hook.

**Read-only.** No provisioning, no `ac_dev_ensure`, no writes anywhere. A hook
that fires before the user has typed anything must not modify repositories.

**Fails open, always.** Unreadable registry, missing `jq`, absent duties file,
git not on PATH — each degrades to "that signal is omitted", never to an error
and never to a non-zero exit. Same contract as `activity-emitter.sh`.

## Component 4 — build and drift test

**`antcrate self plugin`** (new subcommand in `lib/selfcheck.sh`, or a sibling
`lib/plugin.sh` if `selfcheck.sh` is already dense):

1. Copies `assets/code/hooks/claude/*.sh` → `plugin/hooks/claude/`, preserving
   the executable bit.
2. Removes any file in `plugin/hooks/claude/` with no source counterpart.
3. Reports what changed. `--check` mode makes no changes and exits non-zero on
   any difference — this is what CI calls.

**`assets/code/tests/plugin.bats`**, added to `self ci`:

- `self plugin --check` is clean (no drift between source and copies).
- `plugin.json` and `marketplace.json` parse and carry required fields.
- Every `command` in `hooks.json` resolves, after `${CLAUDE_PLUGIN_ROOT}`
  substitution, to a file that exists and is executable.
- Every hook wired in `hooks.json` exists in `plugin/hooks/claude/` **or** is
  `session-digest.sh`; and the two budget hooks are present but *not* wired
  (pins the deliberate opt-in decision so a later edit cannot quietly enable
  them).
- `session-digest.sh` prints nothing given fixtures with zero duties, zero
  unread intel, and a clean tree.
- `session-digest.sh` exits 0 with a missing registry, a missing duties file,
  and malformed JSON in `new.jsonl`.

## Component 5 — install and the `settings.json` overlap

Install (local):

```
/plugin marketplace add ~/antcrate-src
/plugin install antcrate@antcrate
```

Then **one hand edit, owner's to make**: delete the `local-install-guard.sh`
entry from `~/.claude/settings.json`, which the plugin now supplies. Left in
place it double-fires — harmless in effect (the guard is idempotent) but it
means an uninstall of the plugin silently leaves one guard behind, which is
exactly the un-versioned state this work removes. Recorded as a duty and in the
plugin README; no agent edits that file as part of this work.

`settings.json` is not covered by Rule #13 (that rule governs
`~/.config/antcrate/config`), but it is user configuration adjacent to it, and
the conservative treatment costs one line of typing.

## Verification — non-vacuous, per the +100 audit pattern

A passing test that would pass anyway proves nothing. The acceptance evidence
for v1 is:

1. With the plugin installed and the `settings.json` entry removed, a Bash call
   attempting a recursive delete inside a registered project is **blocked**, and
   the block is attributable to the plugin path (not a leftover settings entry
   or the wrapper's own guard).
2. That same call is **allowed** when `gateway-guard.sh` is temporarily reverted
   to the stub-registry resolution — proving the path fix, not the wiring, is
   what makes the registry rules fire.
3. `activity-emitter.sh` produces an event visible to `antcrate watch` after an
   Edit — the first time that path has ever worked end to end.
4. `session-digest.sh` emits its line on this machine (7 duties, 26 unread
   intel), and emits nothing against clean fixtures.

Steps 1 and 2 are one test each in `plugin.bats` where they can be driven by
fixture, plus a manual live check for the parts that require a real session.

## Out of scope for v1

Deferred deliberately, each already scoped enough to pick up later:

- **Slash commands** (`/ac-ship`, `/ac-close`, `/ac-intel`) encoding the
  maintenance, session-close and intel-review protocols that are prose in
  `SKILL.md` today. Highest-value follow-up.
- **Bundled `.mcp.json`** shipping `antcrate-mcp`, removing the manual
  `claude mcp add` step.
- **Cheap-tier agents** (ledger writer, CI runner) wired to `policy.json`
  budgets.
- **Moving the skill into the plugin.** The skill currently loads from
  `~/.claude/skills/antcrate`, a symlink to the repo. Folding it in is a strict
  improvement but touches how the skill is discovered, so it does not belong in
  the release that first proves the hooks.
- **Public publish.** Layout is public-ready by construction; the decision to
  publish is separate and owner-gated.
- **Promoting `cost-anticipator` and `session-budget-guard`** to wired.
