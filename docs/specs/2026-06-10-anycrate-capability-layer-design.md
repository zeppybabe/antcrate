# Spec — AnyCrate Capability Layer (catalog + acquirer + commands + allocation)

**Status:** Approved for build (decisions confirmed 2026-06-10)
**Date:** 2026-06-10
**Deciders:** User + Clyde
**Roadmap position:** ABSORBS roadmap #4 (agent roles) and #5 (provisioning). Builds on
BUNDLE_SPEC/`--ingest` (the existing "small aspect" of this idea). Depends on the intel tracker
spec (same date) for its Anthropic-official feed.

## Context

Goal: a person with zero Claude Code experience installs AntCrate and gets the swiss army knife —
AnyCrate assesses what is being built (task, objective, plan, ledger/state, archival) and brings
in the skills, plugins, tools, repos, and commands that genuinely help, while allocating
agents/models by capability and usage cost. Connectors and MCP servers are SUGGESTED with setup
instructions; the user performs auth (never the tool).

AnyCrate is an aspect of AntCrate, not a separate binary: same registry, same Gateway Law, same
fail-closed posture.

## Decisions (locked)

1. **Trust tiers with hard enforcement.** `anthropic` | `vetted` | `unvetted`.
   - `anthropic` = source verifiably from `github.com/anthropics/*`, `docs.claude.com`, or
     `anthropic.com`, pinned by sha. **Only this tier is eligible for automatic install**
     (and still only when `ANTCRATE_ACQUIRE_AUTO=1` is set in config).
   - `vetted` / `unvetted` = staged-approval only: download → pin sha → staging dir → Claudia
     review brief → human y/N → install. A skill or plugin is executable instruction; installing
     one is treated like a destructive op (prompt-injection / supply-chain surface), so it gets
     the destructive-op ceremony. The novice taps y/N; they never configure anything.
2. **Claude Commands are a first-class capability kind** (user addition, 2026-06-10). AnyCrate
   provisions Claude Code slash commands so every important command is discoverable from the
   `/` menu, and AnyCrate itself may invoke any antcrate/Claude Code commands it needs during
   acquisition — within existing AGENTS rules (gateway-guard still applies; no new bypass).
3. **Model allocation = roadmap #4, done here.** Policy file formalizes the live
   Clyde(orchestrate)/Cody(build)/Claudia(review) tiering and wires it to `--cost` budgets.

## Catalog

`~/.antcrate/anycrate/catalog.json` — jq-managed, atomic temp+rename, same conventions as
registry.json. Entry schema:

```json
{
  "id": "frontend-design",
  "kind": "skill",            // skill | plugin | command | repo | mcp | connector
  "source": { "type": "git", "url": "https://github.com/anthropics/skills", "ref": "main",
              "subpath": "frontend-design", "sha256": "<pinned>" },
  "trust": "anthropic",       // anthropic | vetted | unvetted
  "triggers": ["ui", "svelte", "css", "component"],
  "install": { "dest": "~/.claude/skills/frontend-design/" },
  "version": "2026-06-01",
  "notes": "official skill; feeds from intel skills-repo source"
}
```

Seeded at install time with the Anthropic-official set (from the intel tracker's `skills-repo`
feed) plus AntCrate's own command pack (below). `mcp`/`connector` entries carry a
`setup_instructions` field instead of `install` — `--acquire` on those PRINTS instructions and
exits 0 without touching the system.

## Acquirer — `lib/anycrate.sh`

- `ac_any_acquire <id|url> [--kind k]` — resolve catalog entry (or construct a transient one
  from a URL); verify trust tier; fetch via the `--ingest` machinery where the kind is `repo`
  (BUNDLE_SPEC validation reused wholesale, not duplicated); otherwise fetch → sha256 verify →
  stage. `anthropic` tier + `ANTCRATE_ACQUIRE_AUTO=1` → install directly with a ledger line.
  Any other combination → stage and stop.
- Staging: `~/.antcrate/anycrate/staging/<id>/<UTC-ts>/` with payload + `manifest.json`
  (source, sha, tier, requested-by). The tool NEVER deletes staged items — rejected stages sit
  until the user removes them (quarantine philosophy).
- `ac_any_approve <id>` — interactive only (fails closed non-TTY, same as the removal guard):
  show Claudia's review verdict + manifest, y/N, install on y.
- `ac_any_install_commands [--project <p>]` — render the command pack (below) into
  `~/.claude/commands/` or `<project>/.claude/commands/`. Idempotent; marker-based like hook
  templates so re-runs are clean.
- Per-kind install dests: skill → `~/.claude/skills/<id>/`; plugin → the documented Claude Code
  plugin install path for the user's CC version (verify against intel snapshots at build time —
  do NOT trust memory here); command → `.claude/commands/`; repo → through `--ingest` into the
  registry like any project.

## Wrapper flags

`--acquire <id|url> [--kind k]`, `--stage-list`, `--stage-approve <id>`, `--catalog [--json]`,
`--catalog-add <json|flags>`, `--suggest <project>`, `--commands-install [--project <p>]`.
No `--stage-purge` (user deletes staging manually, ever).

## Command pack (kind = command, trust = anthropic/own)

Slash-command markdown files generated FROM the antcrate surface so they can't drift — a small
generator reads the flag table (PATTERNS.md source of truth) and emits one command file per
high-value flag. Starter set: `/ac-status`, `/ac-start`, `/ac-map`, `/ac-pp`, `/ac-ci`,
`/ac-cost`, `/ac-loop`, `/ac-selfcheck`, `/ac-backup`, `/ac-suggest`, `/ac-acquire`,
`/ac-intel`. Each file: one-line description, the exact wrapper invocation, and the relevant
AGENTS rule numbers so an agent invoking it inherits the law. `/session-close` stays a skill
(already shipped). The intel tracker watches CC release notes for new built-in command/feature
surfaces worth adding to the pack.

## Resolver — the `anycrate` skill (cognition side)

Inputs: registry entry (objective, parent, stack), project `state.md` top-of-mind, the active
task/plan, recent ledger entries. Output: ranked suggestion set — capability, why it helps,
trust tier, and the exact `--acquire` line. Resolver SUGGESTS; only `--acquire` installs; only
tier rules decide automation. The skill also runs at `--start` time for new projects ("what does
a fresh <domain> project of this objective need?") which is the novice-onboarding moment.

## Model allocation policy (roadmap #4 folded in)

`~/.antcrate/anycrate/policy.json`:

```json
{
  "classes": {
    "orchestrate": { "agent": "clyde",   "model": "inherit" },
    "build":       { "agent": "cody",    "model": "haiku"  },
    "review":      { "agent": "claudia", "model": "sonnet" },
    "bulk":        { "agent": "cody",    "model": "haiku"  }
  },
  "budget": { "session_usd": 5.00, "check": "--cost --porcelain --since today" }
}
```

A dispatch helper reads the class → emits the agent brief header (subagent_type, model,
report-back contract). Budget breach (per `--cost`) downgrades non-review classes one model tier
and surfaces a warning — never silently blocks. This codifies the active usage policy
(Cable/Cody/Claudia split + `/clear` discipline) instead of leaving it in `~/CLAUDE.md` prose.

## AGENTS.md additions

- New rule: NO capability (skill/plugin/command/repo) may be installed except through
  `--acquire`. Hand-copying into `~/.claude/skills/` by an agent is a violation.
- New rule: only `trust: anthropic` entries may auto-install, and only under
  `ANTCRATE_ACQUIRE_AUTO=1`. Agents MUST NOT set that variable (same law as the canary DISABLE).
- New rule: the agent that fetched/staged a capability may not be the agent that approves it
  (Claudia reviews; human approves).

## Tests (bats, test-first)

`tests/anycrate.bats` + `tests/commands_pack.bats`. Cases: catalog CRUD + atomicity; tier
enforcement (unvetted `--acquire` stages and refuses install, exit 3; anthropic without
AUTO=1 stages; anthropic with AUTO=1 installs); sha mismatch fails closed with no partial
state; staging manifest shape; approve fails closed non-TTY; mcp/connector prints instructions
and writes nothing; command pack idempotent re-render; policy lookup + budget downgrade;
`--suggest` is read-only. Estimate: ~30 bats.

## Consequences

- Easier: novice onboarding (install AntCrate → `--start` → resolver suggests → y/N → working
  toolkit); future verticals (accounting/legal agent packs are just catalog namespaces + policy
  classes — explicitly out of scope now, dev tools only).
- Harder: catalog freshness is a new maintenance surface — mitigated by the intel feed.
- Revisit: vetting workflow for promoting `unvetted` → `vetted` (manual ledger decision for now).

## Build order (after intel ships)

1. Catalog + tier enforcement + staging (`lib/anycrate.sh`, test-first) → `--ci` PASS.
2. `--acquire` repo-kind path through `--ingest` (reuse, don't fork).
3. Command pack generator + `--commands-install`, live-smoke in Claude Code `/` menu.
4. Resolver skill; wire into `--start`.
5. Policy file + dispatch helper (closes roadmap #4); ledger the absorption of #4/#5.
