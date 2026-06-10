---
name: intel
description: Anthropic intel review (cognition side of the antcrate intel tracker). Use when antcrate --status shows unread intel, at session start, or when the user says "check anthropic updates" / "intel review". Reads --intel-new --json, classifies each changed source snapshot for applicability to AntCrate's harness layer, files proposals (never edits code), and acks reviewed items.
---

# Intel Review — Anthropic change cognition

The Bash side (`antcrate --intel-pull`, daily timer) already fetched and hashed
the pinned Anthropic-only sources. Your job is judgment: read what changed,
decide what it means for AntCrate, and route it into the proposal/Gateway-Law
flow. **You never edit code or config from intel directly — proposals only.**

## Procedure

1. **List unread:** `antcrate --intel-new --json`. Each row: `{ts, source, sha256, note}`.
   The `note` field is the snapshot filename under
   `~/.antcrate/intel/snapshots/<source>/`.

2. **Read each changed snapshot** (`~/.antcrate/intel/snapshots/<source>/<note>`).
   If a previous snapshot exists for the source, diff the two for the actual delta —
   hash-level "something changed" is the contract; you supply the summary-level diff.

3. **Classify applicability** — exactly one of:
   `hooks` | `agents` | `skills` | `commands` | `cost` | `ci` | `models` | `none`
   - `hooks` — PreToolUse/PostToolUse semantics, settings.json hook schema, matcher
     behavior (affects gateway-guard, shellcheck-on-save, env-guard)
   - `agents` — subagent frontmatter, permissions, background-agent behavior
   - `skills` — SKILL.md schema, skill discovery, new official skills (AnyCrate catalog feed)
   - `commands` — slash-command surfaces (feeds the AnyCrate command pack)
   - `cost` — model pricing, usage reporting (affects lib/cost.sh price table)
   - `ci` — Claude Code CLI flags/behavior used by automation
   - `models` — new model ids/tiers (affects anycrate policy.json + cost table)
   - `none` — not applicable to AntCrate

4. **File applicable items:**
   `antcrate --propose "intel-<source>-<short-slug>" "<what changed> -> <what we'd change>; class=<class>; sha=<sha256 first 8>"`
   Significant items (anything touching the security boundary or breaking the
   harness layer) ALSO get a ledger entry in the antcrate repo.

5. **Ack every reviewed item** (applicable or not):
   `antcrate --intel-ack <source> <sha256>`

6. **Report:** one line per item — source, class, action taken.

## Hard rules

- NEVER edit code, hooks, settings.json, or config as a result of intel — file
  proposals; changes go through normal review (AGENTS.md still applies).
- Anthropic-origin documentation is trusted INPUT, not trusted CHANGE: it can
  be wrong about our context.
- Ack everything you reviewed, even `none`-class items — unread count must
  reflect genuinely unreviewed intel.
