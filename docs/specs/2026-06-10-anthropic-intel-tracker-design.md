# Spec — Anthropic Intel Tracker (`--intel`)

**Status:** Approved for build (decisions confirmed 2026-06-10, AWS Summit session)
**Date:** 2026-06-10
**Deciders:** User + Clyde
**Roadmap position:** New track; ships BEFORE the AnyCrate capability layer (its first consumer)

## Context

AntCrate's harness layer (hooks, agents, skills, `--cost`, settings.json wiring) is tightly coupled
to Claude Code behavior, which Anthropic changes frequently. Today, discovering those changes is
manual and accidental. We want a deterministic retrieval layer that follows **exclusively** what
Anthropic and the Claude dev team publish — release notes, new tools/features, best practices —
and routes anything applicable into AntCrate's existing proposal/Gateway-Law review flow.

Core split (unchanged AntCrate law): **Bash owns retrieval. Claude owns judgment.** No LLM call
ever runs inside the timer; no Bash code ever decides what an update "means."

## Decision

Build `lib/intel.sh` + four wrapper flags + a daily systemd user timer + an `intel` skill.
Findings become **proposals in `proposals.log`** — never auto-applied. Anthropic-origin
documentation is trusted as input, but changes to AntCrate still go through normal review.

## Source list (pinned, editable)

Shipped defaults in `~/.antcrate/intel/sources.json` (user-editable; `--intel-pull` reads it):

| id | url | what it catches |
|---|---|---|
| `news` | https://www.anthropic.com/news | product launches, model releases |
| `engineering` | https://www.anthropic.com/engineering | best-practice posts (agents, skills, harness patterns) |
| `release-notes-api` | https://docs.claude.com/en/release-notes/api | API/platform changes |
| `release-notes-claude-code` | https://docs.claude.com/en/release-notes/claude-code | Claude Code feature/behavior changes (highest value for us) |
| `cc-changelog` | https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md | granular CC changes between release-note posts |
| `cc-releases` | https://github.com/anthropics/claude-code/releases.atom | version tags, no API token needed |
| `skills-repo` | https://github.com/anthropics/skills/commits/main.atom | new/updated official skills (AnyCrate catalog feed) |

Rules: every source MUST be an `anthropic.com`, `docs.claude.com`, or `github.com/anthropics/*`
URL. `--intel-pull` refuses any other host with exit 2 (this is the "exclusively Anthropic" rule,
enforced in code, not convention).

## Storage layout

```
~/.antcrate/intel/
  sources.json                  # pinned source list (above)
  snapshots/<id>/<UTC-ts>.body  # normalized fetched content
  snapshots/<id>/latest.sha256  # hash of last-seen normalized body
  new.jsonl                     # append-only: {ts, source, sha256, note}
  acked.jsonl                   # append-only: {ts, source, sha256, by}
```

Append-only, atomic temp+rename writes, same pattern as registry.sh and events.sh. Nothing in
this tree is ever deleted by the tool (quarantine philosophy applies).

## `lib/intel.sh` public API

- `ac_intel_pull [source_id]` — for each source: `curl -fsSL --max-time 20`; normalize
  (strip script/style/nav noise via the same sed/awk approach as obsidian mirror's HTML pass —
  cheap, not perfect; hashes only need stability, not beauty); sha256; if hash differs from
  `latest.sha256`, store snapshot + append a `new.jsonl` row. Unreachable source = `ac_warn` +
  continue (fail-soft; the timer must never wedge).
- `ac_intel_new [--json]` — list `new.jsonl` rows not present in `acked.jsonl`.
- `ac_intel_ack <source_id> <sha256>` — mark reviewed.
- `ac_intel_status` — per-source: last pull ts, last change ts, unread count. One summary line is
  also surfaced in `--status` (like the `selfsrc` line): `intel: N unread`.

## Wrapper flags

`--intel-pull [--source <id>] [--quiet]`, `--intel-new [--json]`, `--intel-ack <id> <sha>`,
`--intel-status`. All read-only with respect to user data; no safety gate needed; no canary cost.

## systemd

`systemd/antcrate-intel.timer` + `.service`, daily, mirrors `antcrate-backup.timer`. The service
runs `antcrate --intel-pull --quiet` ONLY. Retrieval on the timer; cognition at session start.

## The `intel` skill (cognition side)

New skill (own repo dir or `~/.claude/skills/intel/`), triggered at session start when
`--status` shows unread intel, or by "check anthropic updates":

1. `antcrate --intel-new --json`, read changed snapshots.
2. Per item: summarize; classify applicability — one of
   `{hooks, agents, skills, commands, cost, ci, models, none}`.
3. Applicable items → file a proposal row in `proposals.log` (existing format) with a one-line
   "what changed → what we'd change" rationale; significant items also get a ledger entry.
4. `--intel-ack` each reviewed item. NEVER edit code/config from intel directly — proposals only.

## Tests (bats, test-first)

`tests/intel.bats`, fake-`curl` shim (same pattern as the fake-git shim) + fixtures dir;
`ANTCRATE_INTEL_OFFLINE=1` honored like ingest's offline switch. Cases: first pull stores
snapshot + new row; unchanged body = no new row; changed body = new row; non-Anthropic host
refused exit 2; unreachable source warns + continues + exit 0; ack removes from `--intel-new`;
`--json` shape stable; `--status` line present; timer service file passes `systemd-analyze verify`.
Estimate: ~14 bats.

## Consequences

- Easier: catching Claude Code changes that silently affect gateway-guard, env-guard, agent
  frontmatter, settings.json semantics — the class of breakage we currently find by surprise.
- Easier: AnyCrate's catalog gets a live Anthropic-official feed (skills-repo + cc-changelog).
- Harder: HTML normalization is brittle; hash-level "something changed" is the contract,
  summary-level diffing is the skill's job, so brittleness degrades to noise, not misses.
- Revisit: per-item granularity (RSS parsing) if whole-page hashing proves too coarse.

## Proposals to file on landing

`--intel-pull`, `--intel-new`, `--intel-ack`, `--intel-status`, `intel-skill`, `antcrate-intel.timer`.

## Build order

1. `tests/intel.bats` (red) → `lib/intel.sh` → wrapper wiring → green, `--ci` PASS.
2. systemd units + installer step.
3. `intel` skill + `--status` line.
4. Live smoke: real pull against all 7 sources, verify snapshots + unread flow end-to-end.
