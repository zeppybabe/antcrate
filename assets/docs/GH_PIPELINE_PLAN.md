# AntCrate — `gh` Pipeline Plan

Status: **tracking, not yet implementing.** This document captures every
`gh` CLI command observed in use during AntCrate development sessions,
what it accomplished, whether AntCrate already wraps it, and a proposed
flag if it doesn't. The eventual implementation is a focused pass that
absorbs the high-frequency commands into AntCrate as a coherent set of
flags. Until then, this is the running ledger.

## Why a gh pipeline at all

Same logic as `HOOK_PLAN.md` and AGENTS.md rule #11: AntCrate is the
single controllable surface. Every external tool that gets reached for
ad-hoc is a candidate for absorption. The `gh` CLI is dual-use:

- **Operational** — repo create, push, run watch. Should be wrappable.
- **Read-only** — `gh repo view`, `gh api ...`. Less critical to wrap
  but still worth surfacing as flags for token efficiency / muscle memory.

## Invariants

- An AntCrate flag for a `gh` command MUST take a registered project
  name as its primary argument (resolves to repo via the project's
  `git_remote` field — same as `--pp`).
- Flags MUST honor `~/.antcrate/config` for any `gh` defaults the user
  wants to set (e.g., a default workflow name to watch).
- Destructive `gh` operations (issue/PR delete, branch delete via API,
  repo delete) fall under AGENTS.md rule #12 (Gateway Law) — full
  verify-chain + executive decision, never auto-approved.

---

## Observed `gh` usage (running ledger)

### Session: 2026-04-28 (Phase 2 + initial GitHub upload)

| Command | Purpose | Wrapped? | Proposed flag |
|---|---|---|---|
| `gh auth login -h github.com -p https` | Initial auth | partial — surfaced via `--gh-help` | n/a (interactive flow, stays manual) |
| `gh repo create ... --private --push --source=.` | Initial private repo + first push | **yes** — `antcrate --gh-init <project> --private` | (already shipped) |
| `gh repo view <repo> --json visibility,...` | Inspect repo settings | no | `antcrate --gh-info <project>` (read-only) |

### Session: 2026-05-01 (hooks pass + second push)

| Command | Purpose | Wrapped? | Proposed flag |
|---|---|---|---|
| `gh auth refresh -h github.com -s workflow` | Add `workflow` scope so push could include `.github/workflows/ci.yml` | no | `antcrate --gh-auth-scope <scope>` (interactive helper that names the right scope for a given file path) — **low priority** |
| `gh run list --repo <repo> --limit 3` | List recent CI runs for a project | no | `antcrate --runs <project> [N]` |
| `gh run watch <id> --repo <repo> --exit-status` | Block until a CI run finishes | no | `antcrate --watch-run <project> [<id>]` (default: latest run for the project's master/main) |

### Session: 2026-05-08 (public-mirror test — friendly_cars → friendly-cars-dealership)

| Command | Purpose | Wrapped? | Proposed flag |
|---|---|---|---|
| `gh repo view zeppybabe/friendly-cars-dealership` | Pre-flight: confirm dest name does NOT already exist remotely (collision check before --gh-init) | no | `antcrate --gh-name-free <name>` — exit 0 if free, exit 12 if taken (matches `--mirror` exit code 12 = remote-collision per proposal `mirror-fresh-history`) |
| `gh repo create ... --public --push --source=.` | Create public mirror repo + push initial commit | **yes** — `antcrate --gh-init <project> --public` | (already shipped) |

**Pattern observed:** the `--gh-name-free` precheck is a natural building block of `--mirror` (#76) and would also be useful as a standalone flag. When `--mirror` ships it should call this internally before `--gh-init`. Alternative: fold the precheck into `--gh-init` itself with a clear exit 12.

### Session: 2026-05-25 (public-release flip)

| Command | Purpose | Wrapped? | Proposed flag |
|---|---|---|---|
| `gh repo view zeppybabe/antcrate --json visibility,description,licenseInfo,repositoryTopics,url` | Inspect repo metadata before + after the public flip (verify license recognition, description, topic list) | no | `antcrate --gh-info <project>` (already proposed; same field set is the right default) |
| `gh repo edit zeppybabe/antcrate --description "..." --add-topic <t> ...` (10 topics in one call) | Set description + topics on a registered project's GitHub repo | no | `antcrate --gh-publish <project> --description "..." --topics t1,t2,...` (filed 2026-05-25 via `--propose`) |
| `gh repo edit zeppybabe/antcrate --visibility public` | Flip private→public | no | folded into `--gh-publish` above (with Gateway-Law gate since the flip is functionally irreversible) |

**Pattern observed:** the public-flip is exactly the kind of one-shot composite the gh pipeline should absorb. Three `gh repo edit` calls (description, topics, visibility) plus pre/post `gh repo view` for verification = five gh invocations for what is conceptually one action. `--gh-publish` collapses to one command + audit row + Gateway-Law approval. The earlier "Deferred" `--gh-public` line is now superseded by this richer proposal.

### Session: 2026-05-30 (plugin layer attached — `github` + `commit-commands` plugins installed)

No raw `gh` command this session, but a structural event for this plan: the
**`github`** and **`commit-commands`** plugins were installed, plus the
Obsidian + Google Drive MCP servers. The plugins overlap directly with the
surface this doc tracks (`commit-commands` → commit/push/PR; `github` →
repo/issue/PR/run ops).

**Mediation stance (not absorption-by-force):** AntCrate does not race the
plugins to wrap `gh`. Instead the boundary is *who the gate is for a
registered project*:

- For a **registered project**, `--commit` / `--pp` stay mandatory — they
  carry the secret-pattern guard, push-rejection triage, private-by-default,
  and Gateway-Law preview that a bare plugin commit/push does not. Filed
  proposal `plugin-commit-gate` (2026-05-30) to codify this as a guideline.
- For **non-registered trees** and **read-only GitHub-API queries**, let the
  plugin do it — that is exactly the "let the plugin run it locally" case the
  user described. These are no longer flag candidates; the plugin is the
  answer.
- The earlier "Proposed flag set" below (`--runs`, `--watch-run`, `--run-log`,
  `--issues`, `--prs`) is now **partially obsoleted by the `github` plugin**.
  Re-scope before implementing: only build an antcrate flag where the action
  must pass through an antcrate invariant (project-name → remote resolution,
  config defaults, Gateway-Law gate). Pure passthrough reads should defer to
  the plugin.

### Session: 2026-07-14 (SKILL.md stale-path fix — pp push triage)

| Command | Purpose | Wrapped? | Proposed flag |
|---|---|---|---|
| `gh auth status` | Diagnose `pp` rc=128 (`fatal: could not read Username for 'https://github.com'` in a non-interactive agent shell) — found the hosts.yml token INVALID while the keyring copy may still be valid desktop-side | no | none — but the `st` doctor's gh check could distinguish "token invalid/expired" from "not logged in" and say which store (keyring vs hosts.yml) it checked |

---

## Proposed flag set (first implementation pass)

When this gets implemented, the minimum viable set is:

| Flag | What it does | gh equivalent |
|---|---|---|
| `--gh-info <project>` | Print repo visibility, default branch, merge settings | `gh repo view <repo> --json visibility,defaultBranchRef,mergeCommitAllowed,...` |
| `--runs <project> [N]` | List recent CI runs (default N=10) with status + URL | `gh run list --repo <repo> --limit N` |
| `--watch-run <project> [<id>]` | Block until run completes; default = latest on default branch | `gh run watch <id> --repo <repo> --exit-status` |
| `--run-log <project> [<id>]` | Print logs of a CI run (failed steps highlighted) | `gh run view <id> --log` |
| `--issues <project> [open\|all\|closed]` | List issues for a project | `gh issue list --repo <repo>` |
| `--issue-new <project> -t "<title>" [-b "<body>"]` | File a new issue | `gh issue create --repo <repo>` |
| `--prs <project> [open\|all\|merged]` | List PRs (mainly for when public) | `gh pr list --repo <repo>` |

Deferred to a second pass:
- `--gh-protect <project>` — branch protection rules (require CI green, etc.)
- `--gh-public <project>` — visibility flip with Gateway-Law approval
- `--gh-clone <bundle-name>` — clone bundles repo for the ingest pipeline (depends on `BUNDLE_SPEC` consumer-side)
- `--gh-api <project> <endpoint>` — generic escape hatch, audit-logged

## Surface boundaries (what the gh pipeline WILL NOT do)

- **Will not paper over `gh auth login` / `gh auth refresh`.** Those
  remain interactive human-driven flows. AntCrate may *suggest* the
  right scope, but the auth flow itself stays in the user's terminal.
- **Will not silently change repo state.** Visibility flips,
  collaborator additions, branch protection changes are Gateway-Law
  events.
- **Will not wrap every `gh` subcommand for the sake of it.** A flag
  exists only if (a) it shows up >1 time in real use, or (b) it
  participates in a workflow AntCrate already orchestrates (CI signals,
  ingest, etc.).

## Maintenance

- **Append to "Observed `gh` usage" every session** that uses `gh`.
  This is the trigger for revisiting the plan.
- The "Proposed flag set" is mutable — flags get added/removed/renamed
  as the running ledger grows.
- Once the implementation pass starts, this doc becomes the spec; after
  the pass, it becomes the changelog plus any newly observed commands
  not yet wrapped.
