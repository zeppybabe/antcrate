# AntCrate — Pattern Catalog (Flag-by-Intent Index)

Goal of this file: Claude Code (or any agent) reads this **before** reaching for a bare shell command. Every common developer intent maps to an AntCrate flag here. If an intent has no flag, the answer is `antcrate propose` — never a bare command.

---

## The two governing rules

1. **No bare destructive command on a registered project.** Use a flag. If no flag fits, `antcrate propose <name> "<intent>"` and wait for user approval.
2. **No bare `cd` into a registered project.** Use `antcrate in <project> [--addr <code>] -- <cmd>` for one-shots, or `eval "$(antcrate anchor <project>)"` for shell sessions. The anchor is the canonical "current project working directory" and is exposed as `$ANTCRATE_ANCHOR`.

---

## Project lifecycle

| Intent | Command | Notes |
|---|---|---|
| See what's registered | `antcrate st` | Always first. Status + doctor: daemon, projects, intel (unread · sources · last pull), audit, duties (count + oldest), backups, and health checks — every miss prints its fix command. |
| List projects in detail | `antcrate list` | Tab-separated. |
| Show one project's full record | `antcrate info <project>` | Path, domain, git_remote, linked, backups, branch, last commit, working state. Replaces `jq '.projects.<n>'`. |
| Create a new project | `antcrate new <name> --domain <domain> [--meta "csv"]` | Domain ∈ {webapps, scripts, notes, projects, _generic}. Auto-scaffolds `docs/diagrams/architecture.mmd`. |
| Register an existing tree (no scaffold) | `antcrate reg <name> <existing-path> [--domain <d>]` | Adds a registry entry for a tree that's already on disk. Domain defaults to parent dir name. |
| Bootstrap git tracking on a registered project (one-liner) | `antcrate bootstrap <project> [-m "<msg>"] [--with-remote --public/--private]` | Idempotent: runs `--git-init`, writes a default `.gitignore` (rule #13 secret-pattern denylist + cleanup-prune giants), commits everything. `--with-remote` chains `--gh-init` (private default per AGENTS.md #15). Re-runs on a clean tree are no-ops. Replaces the post-`--register` first-commit dance. |
| Local git init only (no commit, no .gitignore) | `antcrate --git-init <project>` | Idempotent. Wires `core.hooksPath .githooks` if the project ships a `.githooks/` dir. Counterpart to `--gh-init` for the local-only case. |
| Branch from an existing project | `antcrate branch <name> --domain <domain> [--meta "from=<base>"]` | Inherits structure of `<base>`. |
| Bidirectionally link two projects | `antcrate link <a> --rel <b>` | Stored under `linked_nodes`. |
| Sub-branch / nest under a new parent | `antcrate --resume <new_parent> --expand <child>` | Atomic; backup-protected. |
| Rename a project | `antcrate mv <project> <new-name>` | Backup + approval; rewrites registry, parent refs, linked_nodes. |
| Archive a project | `antcrate arc <project>` | Backup + approval; moves to `~/projects/.archive/<project>`, marks parent=`_archived`, stores `previous_parent`. |
| Restore an archived project | `antcrate arc -u <project>` | Backup + approval; reads `previous_parent` and moves back to `~/projects/<previous_parent>/<name>`. |
| Permanently delete a project | `antcrate rm <project>` | Backup + approval + loud "PERMANENT DELETE" banner. `rm -rf` + registry purge. Recovery only via the printed backup tarball. Prefer `--archive` if uncertain. |
| List ghost entries (registered but path gone) | `antcrate ghosts` | Read-only. Lists every registry entry whose on-disk `path` no longer exists. Run before a hygiene pass. |
| Drop a ghost registry entry (registry-only) | `antcrate deregister <project>` | For a GHOST only — capture-first to `~/.antcrate/deregistered/<project>/<ts>/` (`entry.json`+`registry.json`+`manifest.json`), then `ac_registry_delete`. **REFUSES (exit 1) if the path still exists** → use `--archive` instead. No `rm` of user data; not the safety-guard path. See AGENTS.md #19 (three fates). |

## Anchor & address (replaces `cd`)

The anchor mechanism gives every project (and every file in it) a stable handle that we operate against without `cd`.

| Intent | Command | Notes |
|---|---|---|
| Resolve a layered address to a path | `antcrate --addr <project> <code>` | Address grammar: alternating `digit`/`letter` segments, depth 1 = digit. `1a3` = 3rd entry inside the 1st sub-branch of the 1st top-level dir. Letters are bijective base-26 (`a`=1, `z`=26, `aa`=27). |
| Print addressed map of a project | `antcrate map <project>` | Tree with addresses + `[d]`/`[s]` (dynamic/static) tags. Static = lockfiles, .env, Dockerfile, tooling dotfiles, LICENSE. |
| Export anchor into the current shell | `eval "$(antcrate anchor <project>)"` | Sets `$ANTCRATE_ANCHOR`, `$ANTCRATE_ANCHOR_NAME` (and `$ANTCRATE_ANCHOR_FILE` if address pointed to a file). |
| Anchor on a specific file | `eval "$(antcrate anchor <project> --addr <code>)"` | Anchor dir is the parent; basename in `$ANTCRATE_ANCHOR_FILE`. |
| Run one command anchored | `antcrate in <project> -- <cmd...>` | Runs `<cmd>` with cwd = project root; no shell-state leak. |
| Run anchored at a sub-path | `antcrate in <project> --addr <code> -- <cmd...>` | E.g. `antcrate in randomize --addr 4 -- bun test`. |

**Address conventions:** entries at each depth are sorted lexicographically (`LC_ALL=C`), then indexed 1-based. Hidden files (`.foo`) and noise dirs (`.git`, `node_modules`, `target`, `dist`, `build`, `__pycache__`, `.next`, `.cache`, `.svelte-kit`) are filtered. Override with `ANTCRATE_ADDR_INCLUDE_HIDDEN=1`.

## Non-interactive by default (audit 2026-07-10)

Every command is TTY-free: `-y` and the `ANTCRATE_*_PREAPPROVED` prefixes are RETIRED (2026-07-10). Commits/`pp` show the Gateway preview and proceed; destructive ops back up first, proceed, and append a `[command]` review duty (`antcrate duty ls`) when no human is at the terminal. A TTY still gets the y/N prompt. Compact words are the ONLY leading form — a leading legacy `--flag` exits 2 with a pointer to the word (`antcrate st` → `antcrate st`); modifier flags after a word (`-m`, `--json`, `--domain`, …) are unchanged.

## Retrieval (rag — read BEFORE grepping a big tree cold)

Deterministic FTS5/BM25 over project text: zero keys, zero models, reproducible ranking. Bash owns retrieval; Claude owns judgment. No MCP needed — the Bash tool is the integration.

| Intent | Command | Notes |
|---|---|---|
| Provision a project's retrieval db | `antcrate rag init <project>` | One sqlite db per project under the XDG data dir (`rag/<p>.db`). |
| (Re)index after edits | `antcrate rag index <project>` | Incremental (mtime-driven); noise dirs pruned, text-only, 1MB cap, 60-line chunks with overlap; drops vanished files. ~1.4s for a 194-file tree. |
| Ask before you grep | `antcrate rag q <project> "<query>" [n]` | BM25 top-n as `path:line \| snippet` — jump straight to the hot files. Default n=8. |

## Destructive ops (always backed by AGENTS.md rule #1)

Every entry forces a backup tarball before touching disk; approval is the TTY prompt or the non-interactive review-duty record (rule #1 as amended). Never use bare `mv`/`rm` on a registered project path.

| Intent | Command | Notes |
|---|---|---|
| On-demand backup | `antcrate bak <project>` | Fans to every enabled target (config `backup_targets=`, default `local`): `local` = tar.gz + sha256 manifest in the backups dir; `git-mirror` = dev/ pushed to the private `<project>-dev` companion. Per-target OK/FAIL report. |
| List backups | `antcrate bak ls <project>` | Reverse-chronological. |
| Restore from latest | `antcrate bak restore <project>` | Pre-restore backup auto-created if target tree non-empty. |
| Restore a specific snapshot | `antcrate bak restore <project> --at <ts>` | `<ts>` matches the `-YYYYMMDDTHHMMSSZ` filename suffix. |
| Rename | `antcrate mv <project> <new-name>` | See "Project lifecycle" — rewires registry. |
| Archive | `antcrate arc <project>` | See "Project lifecycle". |
| Unarchive | `antcrate arc -u <project>` | See "Project lifecycle". |
| Permanently delete | `antcrate rm <project>` | See "Project lifecycle". Backup tarball is sole recovery path. |

## Git

| Intent | Command | Notes |
|---|---|---|
| Commit + push with conflict triage | `antcrate pp <project> [--no-mirror]` | Prints the bundled pre-push panel FIRST (branch, last/stable/current version, last commit, unpushed, working state, milestone from ledger heads, newest plan, backup age, open duties), then commits (if dirty) + pushes. On rejection: emails truncated diff, full log at `/tmp/antcrate_conflict.log`. Never bare `git push`. Successful pushes print `verify: <upstream> in sync at <SHA>`, then mirror dev/ to the private `<project>-dev` companion when config `mirror_dev=` lists the project (`--no-mirror` skips once; mirror failure never fails the push). |
| Read the same panel without pushing | `antcrate info <project>` | Registry record + the pp panel, fully read-only. |
| Commit only (no push), unattended | `antcrate commit <project> -m "<msg>" --all-tracked -y` | `-y` skips the y/N prompt for non-TTY use (proposal #83). |
| `git status` + `git diff` (no cd) | `antcrate diff <project>` | Uses `git -C`. |
| Initialize GitHub repo (HTTPS) | `antcrate --gh-init <project> [--public]` | Defaults to private. Requires `gh` authed. |
| GitHub onboarding hint | `antcrate --gh-help` | Prints HTTPS onboarding steps. |

## Logs & introspection

| Intent | Command | Notes |
|---|---|---|
| Tail wrapper + daemon + conflict logs | `antcrate logs [project] [lines]` | If `<project>` registered, also shows `git log --oneline -n 5`. Default 50 lines. |
| Daemon + registry summary | `antcrate st` | |
| Raw registry dump | `jq . ~/.antcrate/registry.json` | |
| Tail conflict log only | `tail -f /tmp/antcrate_conflict.log` | |

## Developer ops on AntCrate itself

AntCrate develops AntCrate. These flags route the build/test/edit loop through the wrapper so I never `cd` into the skill source.

| Intent | Command | Notes |
|---|---|---|
| Print skill source root | `antcrate self src` | Persisted in `~/.antcrate/config` as `ANTCRATE_SELFSRC=` at install. |
| Reinstall after edits | `antcrate self install` | Runs `install.sh` from selfsrc; copies libs to `~/.local/share/antcrate/`. |
| Run all bats tests | `antcrate self test` | Requires `bats-core` on PATH. |
| Run a specific test file | `antcrate self test <name>` | E.g. `antcrate self test address` → runs `tests/address.bats`. |
| Resolve a file under selfsrc | `antcrate self edit <relpath>` | E.g. `antcrate self edit lib/registry.sh` → echoes absolute path. Pipe to `$EDITOR`: `$EDITOR "$(antcrate self edit lib/registry.sh)"`. |

## Diagrams (text-as-source-of-truth per `DIAGRAM_AUTOMATION_GUIDE.md`)

| Intent | Command | Notes |
|---|---|---|
| Render all diagram sources in a project | `antcrate --diagrams <project>` | Walks `docs/diagrams/*.{mmd,puml,d2}`. Renders if `mmdc`/`plantuml`/`d2` are on PATH; warns and continues if any are missing (text source still renders inline on GitHub). |
| Mermaid view of the entire registry | `antcrate --registry-diagram [out.mmd]` | Default out: `~/.antcrate/registry.mmd`. Archived projects styled dimmed. Linked projects connected with `<-->`. |
| Mermaid view of a project's addressed tree | `antcrate --tree-diagram <project> [out.mmd]` | Default out: `<project>/docs/diagrams/tree.mmd`. Reflects current addresses (`1`, `1a3`, etc.). |

Mermaid `.mmd` files render inline on GitHub without any tool installed — that's the default. SVG rendering is opt-in via `mmdc -i in.mmd -o out.svg`.

**Auto-regen.** Every mutating wrapper action (`--start`, `--register`, `--branch`, `--link`, `--resume --expand`, `--rename`, `--archive`, `--unarchive`, `--remove`, `--restore`) silently refreshes `~/.antcrate/registry.mmd` and (when applicable) `<project>/docs/diagrams/tree.mmd` after the operation succeeds. You normally never need to call `--registry-diagram` or `--tree-diagram` by hand — they exist as a manual override / repair path.

Disable with `export ANTCRATE_AUTO_DIAGRAMS=0` (e.g. for batch scripted mutations where you want a single explicit regen at the end). Failures are swallowed: a diagram refresh never blocks the action that triggered it.

## CI

| Intent | Command | Notes |
|---|---|---|
| Run shellcheck + bats + cmake/ctest | `antcrate self ci [--snapshot] [--source <path>]` | One command, fail-fast on any stage. Use before any change. PASS records to `ci-baseline.json`; `--snapshot` sets the audit baseline; `--source` CIs an alternate tree (worktrees). |

## Intel (retrieval = Bash, judgment = the session — procedure folded into SKILL.md 2026-07-10; kinds + user sources added 2026-07-11)

| Intent | Command | Notes |
|---|---|---|
| Fetch intel sources now | `antcrate intel pull [--quiet] [<id>]` | Seed list in intel data dir `sources.json` (anthropic.com / docs.claude.com / github.com/anthropics/* ONLY — any other seed host exits 2) PLUS human-curated extras in `~/.config/antcrate/intel-sources.json` (`{id,url,kind?}`, https-only, **agents read it, NEVER write it** — the human vouches for a foreign host by hand-editing). Snapshot + unread row on hash change. Daily timer: `antcrate-intel.timer`. |
| See unread intel | `antcrate intel ls [--json] [--kind dev\|security]` | new.jsonl minus acked.jsonl; `--kind` filters by source kind (seed sources are all `dev`). |
| Close out a review | `antcrate intel ack all` / `ack <id>` / `ack <id> <sha256>` | Bulk, per-source, or per-item. Append-only; nothing is ever deleted from the intel tree. |
| Per-source intel summary | `antcrate intel st` | kind + last-pull / last-change / unread per source (user extras marked `(user)`); `antcrate st` also carries an `intel: N unread · S sources · last pull <age>` line. |

Findings become proposals (`antcrate propose`) — never direct code/config edits (Bash owns retrieval, Claude owns judgment).


## Hooks (full management surface — see `HOOK_PLAN.md` for design history)

| Intent | Command | Notes |
|---|---|---|
| List active git hooks for a project | `antcrate hook ls <project>` | Honors `core.hooksPath`; flags antcrate's `.githooks` opt-in when active; shows `active`/`disabled` per hook. |
| Install a hook from a shipped template | `antcrate hook install <project> <template> [hook-name] [--force]` | Templates: `pre-commit-ci`, `pre-commit-secrets`, `pre-commit-stack-bash`, `pre-push-tests` (at `assets/code/hooks/templates/`). Idempotent; `--force` backs up then overwrites. |
| Remove a hook (audited) | `antcrate hook rm <project> <hook> [--force]` | Backs up to `<hook>.bak.<ts>`; audit-logged to `~/.antcrate/hooks.log` + `.git/antcrate-hook-audit.log`. |
| Preview a template without installing | `antcrate hook render <template> [project]` | Renders to stdout with placeholder substitution + bypass-check injection — catches injection bugs before install. |
| Re-run a hook with trace | `antcrate hook debug <project> [hook] [--with-stash] [--no-trace]` | Annotated `bash -x` + captured output; `--with-stash` mirrors the staged set; exits with the hook's exit code. Audit-logged. |
| Single-shot bypass (human-run) | `antcrate hook bypass <project> --reason "<text>"` | Next antcrate-shipped hook consumes the flag, logs bypass + reason to both audit sinks, exits 0. Agents PROPOSE; humans run (rule #14). |
| Unified audit view | `antcrate hook audit <project> [N]` | All three audit sinks (global JSONL, per-project, human-readable), N lines each (default 20). Read-only. |
| Profile-driven auto-install | `antcrate hook auto <project> [--dry-run]` | Reads `--profile` recommendations, installs the picked template per slot, patches `.gitignore`. Idempotent. |
| Debug a blocked commit | `antcrate hook log <project> [lines]` | Tails `.git/antcrate-hook.log` (the file the shipped pre-commit tees to). Default 50 lines. |
| Smoke-test a Claude Code hook (guard FP debugging) | `antcrate hook smoke <hook-script> --command '<cmd>'` (or `--file <path>` / `--payload '<json>'`, `--tool <name>`) | Pipes a synthetic PreToolUse/PostToolUse payload into the hook, surfaces its stderr + a verdict line, propagates exit (0 allow / 1 warn / 2 block). NOTE: a literal destructive string in `--command` also sits in YOUR shell command — the LIVE guard may block the smoke itself; use benign/warn-tier text live and assert block paths in bats. |

The shipped opt-in pre-commit (`.githooks/pre-commit` in the antcrate
repo) runs `antcrate self ci` and writes to that log. Enable with
`git config core.hooksPath .githooks` per-clone.


## Filename triggers (Positional Extension Schema)

Equivalent to wrapper invocations — the daemon decodes them.

| Filename | Equivalent flag |
|---|---|
| `coolapp.webapps.start.#html,css,ts#` | `antcrate new coolapp --domain webapps --meta "html,css,ts"` |
| `auth.scripts.branch.#from=base#` | `antcrate branch auth --domain scripts --meta "from=base"` |
| `note.notes.start` | `antcrate new note --domain notes` |

Use the wrapper directly inside Claude Code sessions; reserve filename triggers for editor-driven workflows.

## Setup / state

| Intent | Command |
|---|---|
| First-run setup | `antcrate --init` |

## Bundles (research → dev handshake)

A *bundle* is the typed artifact that crosses between research-AntCrate (on
the research machine) and dev-AntCrate (on this machine). Spec lives at
`assets/docs/BUNDLE_SPEC.md`; complete examples under
`assets/docs/examples/bundles/`.

| Intent | Command | Status |
|---|---|---|
| Ingest a bundle into a registered project | `antcrate ingest <bundle-path>` | **shipped** (local-path bundles) |
| Peek the queue of ready bundles | `antcrate --queue` | **planned** |
| Claim and ingest the next ready bundle | `antcrate --next` | **planned** |
| Mark a project complete and close its bundle | `antcrate --conclude <project>` | **planned** |

`--ingest` validates `manifest.json` per BUNDLE_SPEC §4 before any disk
write; on failure, sets `STATUS=failed: <reason>` and aborts with no
partial state. Source materializers cover all four `source.type`
variants (`none` / `git` / `archive` / `composite`). Relationships
honored: `supersedes` invokes AGENTS.md rule #1 (backup + approval
before overwrite); `extends` merges the bundle's research/skill into an
existing project without re-cloning; `duplicate_of` and `depends_on`
are informational warnings. Set `ANTCRATE_INGEST_OFFLINE=1` to skip
reachability network checks (used by tests). Queue/next/conclude
remain planned.

## Cleanup (per-project)

| Intent | Command |
|---|---|
| List test/cache/empty-dir candidates (read-only) | `antcrate gc <project>` |
| Remove specific candidates by ID | `antcrate gc <project> --apply <id>[,<id>...]` |

Categories detected: **`test-tmp`** (`__pycache__`, `.pytest_cache`,
`.mypy_cache`, `.tox`, `.cache`, `.turbo`, `.nyc_output`, `coverage` and
file-pattern matches `*.test.tmp`, `*.pyc`, `*.bats.log`) and
**`empty-dir`** (zero-entry dirs). `.git`, `.github`, `.githooks`,
`node_modules` are pruned at any depth.

`--apply` runs each removal through `ac_safety_guard_destructive` (rule
#1 backup + approval), emits a `delete` event with category as label
(`--watch` paints a 1s tombstone), and appends to
`projects.<n>.recent_removals` (capped at `ANTCRATE_CLEANUP_RECENT_CAP`,
default 50).

## Activity stream (live agent awareness)

| Intent | Command |
|---|---|
| Append an activity event | `antcrate --emit-activity <project> <kind> <relpath> [--ttl-ms N] [--label X] [--agent A]` |
| Watch the project tree painted by active events | `antcrate watch <project> [--once] [--interval-ms N] [--no-color] [--depth N]` |
| Watch whatever project the agent is touching (second terminal) | `antcrate watch --follow` — full-screen, height-clamped, auto-switches projects; fed by the activity-emitter hook |
| Emit one event then render the tree once (smoke shortcut) | `antcrate --watch-smoke <project> [kind] [relpath] [--ttl-ms N] [--depth N] [--no-color]` |
| Spawn a detached terminal window running --watch | `antcrate --watch-window <project> [--terminal alacritty]` |

Kinds: `modify` (yellow), `read` (cyan), `think` (magenta), `delegate`
(green), `delete` (bright red strikethrough). Default TTLs are
kind-specific. The event stream is durable JSONL at
`~/.antcrate/events/<project>.jsonl` — agents emit; watchers tail.
Severity ordering: delete > modify > delegate > think > read; ancestor
directories paint with the highest-severity descendant kind.

## Proposing new patterns (the escape valve)

When no flag fits the current intent, **do not** fall back to a bare command. Instead:

```
antcrate propose <short-name> "<one-line description of the intent>"
```

This appends to `~/.antcrate/proposals.log` for user review. Examples:

```
antcrate propose remove "Backup-protected project removal with registry purge"
antcrate propose dockerize "Generate Dockerfile + compose stub from project meta"
antcrate propose env-rotate "Rotate .env values; backup the prior file under ~/.antcrate/secrets/"
```

Inspect: `antcrate proposals` or `cat ~/.antcrate/proposals.log`.

The user reviews proposals and decides which become real flags. Until that happens, the bare command remains off-limits — the proposal log is how Claude says "I would have needed this" without bypassing the safety boundary.

## User duties (human-only actions)

Actions only the human can perform — control-plane jq seeds, `systemctl --user enable`, rule-#13 config edits, key rotation, policy approvals — go on the `duties.md` checklist (repo root), not into state.md prose.

| Intent | Command | Notes |
|---|---|---|
| Record an action only the human can do | `antcrate duty add [--type <t>] "<text>"` | Appends `- [ ] <date> — [<type>] <text>` to duties.md. Types: `policy\|command\|research\|debug` (untyped reads as policy). Surfaced in `--status` and the session-budget gate's wrap-up checklist. |
| See open human duties | `antcrate duty ls` | Numbered list of open items only, typed tags shown; flat indices stay valid for `--duty-done`. |
| Mark a duty done | `antcrate duty done <n>` | User-driven (or agent on explicit user instruction). Flips to `- [x]` + done-date; items are never deleted. |
| Check how involved the user wants to be | `antcrate --duty-involvement` | `lean\|standard\|hands-on`; env > config `duty_involvement=` line > lean. Config line is rule-#13 human-only. Gates research routing (AGENTS.md rule #21). |

## Least-cost layer (policy, prediction, no-LLM retrieval)

Research order of record: **TH duty → `--fetch` → model research LAST** (AGENTS.md rule #21).

| Intent | Command | Notes |
|---|---|---|
| See model tiers / budgets / classes | `antcrate policy` | Pretty-prints `~/.antcrate/anycrate/policy.json`. Only `budgets.fable` is agent-adjustable (rule #22). |
| Seed the policy file | `antcrate --policy-init` | Idempotent — never clobbers an existing file. |
| Fetch a web page without spending model tokens | `antcrate fetch <url> [--name <slug>]` | Normalizes (script/tag-strip) + snapshots to `~/.antcrate/fetch/<slug>/`, append-only and hash-keyed; unchanged content = no new snapshot. http(s) only. |

Hooks backing this layer (wired in `~/.claude/settings.json`): `session-budget-guard.sh` is the REACTIVE gate (model-aware budgets — Fable soft 250k / hard 400k, default 100k/140k); `cost-anticipator.sh` is the PREDICTIVE gate (PreToolUse Skill|Agent|Read — estimates the call's token load first, warns past soft, blocks past hard/window naming a cheaper path). Both fail open; DISABLE hatches are human-only.

## Plugins & external tools (let-it / feed-it / gate-it)

AntCrate is a **mediator, not a dominator**. It supplements tools so work can run locally; when a plugin/MCP already does that, AntCrate stays out of the way. It only steps in when something is missing or an AntCrate guideline is at stake. Every external surface sorts into one of three buckets:

- **🟢 LET IT** — pure capability that touches no AntCrate invariant. Use freely; no antcrate involvement. Examples: `context7` (live library docs), `clangd-lsp` + the `cpp-check` skill (C++ for `antcrate-core`), `security-guidance` / `security-review`, `superpowers` method-skills (TDD, brainstorming, systematic-debugging — the *how*; AGENTS.md is the *what-you-may-touch*), `code-review` (cloud, opt-in deeper pass — `--ci` stays the must-pass LOCAL gate), `claude-code-setup`.
- **🔵 FEED IT** — AntCrate generates, the surface renders; AntCrate stays the source of truth. (Obsidian mirroring was atticked 2026-07-10 — branch `attic`.) **Google Drive** is the research/producer side of `BUNDLE_SPEC` (proposal `drive-bundle`).
- **🟡 GATE IT** — overlaps an AntCrate guideline, so the gate-bearing flag stays mandatory **for registered projects** (AGENTS.md rule #18). The `commit-commands` + `github` plugins overlap `--commit` / `--pp`: those flags own the commit/push step for any registered project (secret-guard, push-triage, private-default, Gateway-Law). The plugins handle non-registered trees + read-only GitHub queries.

When a new plugin/MCP arrives, classify it into one of these buckets before reaching for it; if it would touch a registered project's structure, commits, or destructive ops, it's GATE-IT and the antcrate flag wins.

## Quick index by verb

- **see**: `--status`, `--list`, `--map`, `--logs`, `--diff`, `--proposals`, `--registry-diagram`, `--tree-diagram`, `--watch`, `--watch-smoke`, `--watch-window`, `--selfcheck`, `--intel-new`, `--intel-status`
- **make**: `--start`, `--register`, `--branch`, `--link`, `--gh-init`, `--diagrams`
- **point at**: `--addr`, `--anchor`, `--in`
- **change**: `--rename`, `--resume --expand`, `--restore`
- **soft-delete / restore**: `--archive`, `--unarchive`
- **hard-delete**: `--remove` (backup-only recovery)
- **safeguard**: `--backup`, `--backups`, `--restore`
- **ship**: `--pp`
- **build self**: `--selfsrc`, `--selfinstall`, `--install-from-source`, `--selftest`, `--selfedit`, `--ci`
- **propose**: `--propose`, `--proposals`
- **duties**: `--duty`, `--duties`, `--duty-done`, `--duty-involvement`
- **least-cost**: `--policy`, `--policy-init`, `--fetch`
