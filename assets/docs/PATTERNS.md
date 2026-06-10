# AntCrate — Pattern Catalog (Flag-by-Intent Index)

Goal of this file: Claude Code (or any agent) reads this **before** reaching for a bare shell command. Every common developer intent maps to an AntCrate flag here. If an intent has no flag, the answer is `antcrate --propose` — never a bare command.

---

## The two governing rules

1. **No bare destructive command on a registered project.** Use a flag. If no flag fits, `antcrate --propose <name> "<intent>"` and wait for user approval.
2. **No bare `cd` into a registered project.** Use `antcrate --in <project> [--addr <code>] -- <cmd>` for one-shots, or `eval "$(antcrate --anchor <project>)"` for shell sessions. The anchor is the canonical "current project working directory" and is exposed as `$ANTCRATE_ANCHOR`.

---

## Project lifecycle

| Intent | Command | Notes |
|---|---|---|
| See what's registered | `antcrate --status` | Always first. Shows daemon state + project count. |
| List projects in detail | `antcrate --list` | Tab-separated. |
| Show one project's full record | `antcrate --info <project>` | Path, domain, git_remote, linked, backups, branch, last commit, working state. Replaces `jq '.projects.<n>'`. |
| Create a new project | `antcrate --start <name> --domain <domain> [--meta "csv"]` | Domain ∈ {webapps, scripts, notes, projects, _generic}. Auto-scaffolds `docs/diagrams/architecture.mmd`. |
| Register an existing tree (no scaffold) | `antcrate --register <name> <existing-path> [--domain <d>]` | Adds a registry entry for a tree that's already on disk. Domain defaults to parent dir name. |
| Bootstrap git tracking on a registered project (one-liner) | `antcrate --bootstrap <project> [-m "<msg>"] [--with-remote --public/--private]` | Idempotent: runs `--git-init`, writes a default `.gitignore` (rule #13 secret-pattern denylist + cleanup-prune giants), commits everything. `--with-remote` chains `--gh-init` (private default per AGENTS.md #15). Re-runs on a clean tree are no-ops. Replaces the post-`--register` first-commit dance. |
| Local git init only (no commit, no .gitignore) | `antcrate --git-init <project>` | Idempotent. Wires `core.hooksPath .githooks` if the project ships a `.githooks/` dir. Counterpart to `--gh-init` for the local-only case. |
| Branch from an existing project | `antcrate --branch <name> --domain <domain> [--meta "from=<base>"]` | Inherits structure of `<base>`. |
| Bidirectionally link two projects | `antcrate --link <a> --rel <b>` | Stored under `linked_nodes`. |
| Sub-branch / nest under a new parent | `antcrate --resume <new_parent> --expand <child>` | Atomic; backup-protected. |
| Rename a project | `antcrate --rename <project> <new-name>` | Backup + approval; rewrites registry, parent refs, linked_nodes. |
| Archive a project | `antcrate --archive <project>` | Backup + approval; moves to `~/projects/.archive/<project>`, marks parent=`_archived`, stores `previous_parent`. |
| Restore an archived project | `antcrate --unarchive <project>` | Backup + approval; reads `previous_parent` and moves back to `~/projects/<previous_parent>/<name>`. |
| Permanently delete a project | `antcrate --remove <project>` | Backup + approval + loud "PERMANENT DELETE" banner. `rm -rf` + registry purge. Recovery only via the printed backup tarball. Prefer `--archive` if uncertain. |
| List ghost entries (registered but path gone) | `antcrate --ghosts` | Read-only. Lists every registry entry whose on-disk `path` no longer exists. Run before a hygiene pass. |
| Drop a ghost registry entry (registry-only) | `antcrate --deregister <project>` | For a GHOST only — capture-first to `~/.antcrate/deregistered/<project>/<ts>/` (`entry.json`+`registry.json`+`manifest.json`), then `ac_registry_delete`. **REFUSES (exit 1) if the path still exists** → use `--archive` instead. No `rm` of user data; not the canary/safety-guard path. See AGENTS.md #19 (three fates). |
| Create a file inside a project | `antcrate --touch <project> <relpath>` | Auto-mkdirs parents. Refuses overwrite, absolute paths, `..` traversal. Stdout = absolute path (composes with `Write` / `$EDITOR`). |
| Create a directory inside a project | `antcrate --mkdir <project> <relpath>` | `mkdir -p`. Same path-safety rules as `--touch`. Stdout = absolute path. |

## Anchor & address (replaces `cd`)

The anchor mechanism gives every project (and every file in it) a stable handle that we operate against without `cd`.

| Intent | Command | Notes |
|---|---|---|
| Resolve a layered address to a path | `antcrate --addr <project> <code>` | Address grammar: alternating `digit`/`letter` segments, depth 1 = digit. `1a3` = 3rd entry inside the 1st sub-branch of the 1st top-level dir. Letters are bijective base-26 (`a`=1, `z`=26, `aa`=27). |
| Print addressed map of a project | `antcrate --map <project>` | Tree with addresses + `[d]`/`[s]` (dynamic/static) tags. Static = lockfiles, .env, Dockerfile, tooling dotfiles, LICENSE. |
| Export anchor into the current shell | `eval "$(antcrate --anchor <project>)"` | Sets `$ANTCRATE_ANCHOR`, `$ANTCRATE_ANCHOR_NAME` (and `$ANTCRATE_ANCHOR_FILE` if address pointed to a file). |
| Anchor on a specific file | `eval "$(antcrate --anchor <project> --addr <code>)"` | Anchor dir is the parent; basename in `$ANTCRATE_ANCHOR_FILE`. |
| Run one command anchored | `antcrate --in <project> -- <cmd...>` | Runs `<cmd>` with cwd = project root; no shell-state leak. |
| Run anchored at a sub-path | `antcrate --in <project> --addr <code> -- <cmd...>` | E.g. `antcrate --in randomize --addr 4 -- bun test`. |

**Address conventions:** entries at each depth are sorted lexicographically (`LC_ALL=C`), then indexed 1-based. Hidden files (`.foo`) and noise dirs (`.git`, `node_modules`, `target`, `dist`, `build`, `__pycache__`, `.next`, `.cache`, `.svelte-kit`) are filtered. Override with `ANTCRATE_ADDR_INCLUDE_HIDDEN=1`.

## Destructive ops (always backed by AGENTS.md rule #1)

Every entry forces a backup tarball + human approval before touching disk. Never use bare `mv`/`rm` on a registered project path.

| Intent | Command | Notes |
|---|---|---|
| On-demand backup | `antcrate --backup <project>` | tar.gz + sha256 manifest under `~/.antcrate/backups/<project>/`. |
| List backups | `antcrate --backups <project>` | Reverse-chronological. |
| Restore from latest | `antcrate --restore <project>` | Pre-restore backup auto-created if target tree non-empty. |
| Restore a specific snapshot | `antcrate --restore <project> --at <ts>` | `<ts>` matches the `-YYYYMMDDTHHMMSSZ` filename suffix. |
| Rename | `antcrate --rename <project> <new-name>` | See "Project lifecycle" — rewires registry. |
| Archive | `antcrate --archive <project>` | See "Project lifecycle". |
| Unarchive | `antcrate --unarchive <project>` | See "Project lifecycle". |
| Permanently delete | `antcrate --remove <project>` | See "Project lifecycle". Backup tarball is sole recovery path. |

## Git

| Intent | Command | Notes |
|---|---|---|
| Commit + push with conflict triage | `antcrate --pp <project>` | On rejection: emails truncated diff, full log at `/tmp/antcrate_conflict.log`. Never bare `git push`. Successful pushes print `verify: <upstream> in sync at <SHA>` (proposal #87 Shape B). |
| Skip the commit y/N prompt | `antcrate --pp <project> -y` | Unattended only. |
| Commit only (no push), unattended | `antcrate --commit <project> -m "<msg>" --all-tracked -y` | `-y` skips the y/N prompt for non-TTY use (proposal #83). |
| `git status` + `git diff` (no cd) | `antcrate --diff <project>` | Uses `git -C`. |
| Initialize GitHub repo (HTTPS) | `antcrate --gh-init <project> [--public]` | Defaults to private. Requires `gh` authed. |
| GitHub onboarding hint | `antcrate --gh-help` | Prints HTTPS onboarding steps. |

## Logs & introspection

| Intent | Command | Notes |
|---|---|---|
| Tail wrapper + daemon + conflict logs | `antcrate --logs [project] [lines]` | If `<project>` registered, also shows `git log --oneline -n 5`. Default 50 lines. |
| Daemon + registry summary | `antcrate --status` | |
| Raw registry dump | `jq . ~/.antcrate/registry.json` | |
| Tail conflict log only | `tail -f /tmp/antcrate_conflict.log` | |

## Developer ops on AntCrate itself

AntCrate develops AntCrate. These flags route the build/test/edit loop through the wrapper so I never `cd` into the skill source.

| Intent | Command | Notes |
|---|---|---|
| Print skill source root | `antcrate --selfsrc` | Persisted in `~/.antcrate/config` as `ANTCRATE_SELFSRC=` at install. |
| Reinstall after edits | `antcrate --selfinstall` | Runs `install.sh` from selfsrc; copies libs to `~/.local/share/antcrate/`. |
| Run all bats tests | `antcrate --selftest` | Requires `bats-core` on PATH. |
| Run a specific test file | `antcrate --selftest <name>` | E.g. `antcrate --selftest address` → runs `tests/address.bats`. |
| Resolve a file under selfsrc | `antcrate --selfedit <relpath>` | E.g. `antcrate --selfedit lib/registry.sh` → echoes absolute path. Pipe to `$EDITOR`: `$EDITOR "$(antcrate --selfedit lib/registry.sh)"`. |

## Diagrams (text-as-source-of-truth per `DIAGRAM_AUTOMATION_GUIDE.md`)

| Intent | Command | Notes |
|---|---|---|
| Render all diagram sources in a project | `antcrate --diagrams <project>` | Walks `docs/diagrams/*.{mmd,puml,d2}`. Renders if `mmdc`/`plantuml`/`d2` are on PATH; warns and continues if any are missing (text source still renders inline on GitHub). |
| Mermaid view of the entire registry | `antcrate --registry-diagram [out.mmd]` | Default out: `~/.antcrate/registry.mmd`. Archived projects styled dimmed. Linked projects connected with `<-->`. |
| Mermaid view of a project's addressed tree | `antcrate --tree-diagram <project> [out.mmd]` | Default out: `<project>/docs/diagrams/tree.mmd`. Reflects current addresses (`1`, `1a3`, etc.). |

Mermaid `.mmd` files render inline on GitHub without any tool installed — that's the default. SVG rendering is opt-in via `mmdc -i in.mmd -o out.svg`.

**Auto-regen.** Every mutating wrapper action (`--start`, `--register`, `--branch`, `--link`, `--resume --expand`, `--rename`, `--archive`, `--unarchive`, `--remove`, `--touch`, `--mkdir`, `--restore`) silently refreshes `~/.antcrate/registry.mmd` and (when applicable) `<project>/docs/diagrams/tree.mmd` after the operation succeeds. You normally never need to call `--registry-diagram` or `--tree-diagram` by hand — they exist as a manual override / repair path.

Disable with `export ANTCRATE_AUTO_DIAGRAMS=0` (e.g. for batch scripted mutations where you want a single explicit regen at the end). Failures are swallowed: a diagram refresh never blocks the action that triggered it.

## CI

| Intent | Command | Notes |
|---|---|---|
| Run shellcheck + full bats suite | `antcrate --ci` | One command, fail-fast on either. Use before any change. |

## Safety canary (Wave 1 compaction-canary gate — see AGENTS.md rule #15)

| Intent | Command | Notes |
|---|---|---|
| Initialize canary state | `antcrate --canary-init [--ttl-seconds N] [--max-invocations N] [--with-claudemd]` | Generates 32-hex token, writes `~/.antcrate/canary/state.json`. With `--with-claudemd`, interactively patches the `__CANARY_TOKEN__` placeholder in `~/CLAUDE.md`. Without it, prints the snippet to add manually. Defaults: TTL=3600s, MAX=30 invocations. |
| Verify canary (after re-reading rules) | `antcrate --canary-verify <TOKEN>` | Bumps `last_verified_ts`, resets `invocations_since_verify`. Required when the gate fires. Token lives in `~/CLAUDE.md` "## Safety Canary" section. |
| Show canary state | `antcrate --canary-status` | Human-readable: initialized?, masked token, last verify, invocations / max, TTL. |
| Debug: standalone gate check | `antcrate --canary-gate-check` | Exit 0 fresh, 4 stale, 2 missing state. Increments invocation counter. |

The gate runs inside `ac_safety_guard_destructive` (rule #1 chokepoint) — so every destructive op (`--rename`, `--archive`, `--remove`, `--cleanup --apply`, `--ingest` supersedes, `--resume --expand` subbranch) is gated. Opt-out via `ANTCRATE_CANARY_DISABLE=1` is for CI/bats only; agents must not flip it (AGENTS.md rule #15).

## Hooks (read-only today; install/remove/bypass queued — see `HOOK_PLAN.md`)

| Intent | Command | Notes |
|---|---|---|
| List active git hooks for a project | `antcrate --hooks <project>` | Honors `core.hooksPath`; flags antcrate's `.githooks` opt-in when active; shows `active`/`disabled` per hook. |
| Debug a blocked commit | `antcrate --hook-log <project> [lines]` | Tails `.git/antcrate-hook.log` (the file the shipped pre-commit tees to). Default 50 lines. |

The shipped opt-in pre-commit (`.githooks/pre-commit` in the antcrate
repo) runs `antcrate --ci` and writes to that log. Enable with
`git config core.hooksPath .githooks` per-clone.

**Not yet implemented (queued in `assets/docs/HOOK_PLAN.md`):** hook
template library, `--hook-install`, `--hook-remove`, `--hook-bypass`
(single-shot, audit-logged), `--start --hooks <preset>` for
auto-install on scaffold, `--hook-debug` (re-run with annotation).

## Filename triggers (Positional Extension Schema)

Equivalent to wrapper invocations — the daemon decodes them.

| Filename | Equivalent flag |
|---|---|
| `coolapp.webapps.start.#html,css,ts#` | `antcrate --start coolapp --domain webapps --meta "html,css,ts"` |
| `auth.scripts.branch.#from=base#` | `antcrate --branch auth --domain scripts --meta "from=base"` |
| `note.notes.start` | `antcrate --start note --domain notes` |

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
| Ingest a bundle into a registered project | `antcrate --ingest <bundle-path>` | **shipped** (local-path bundles) |
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
| List test/cache/empty-dir candidates (read-only) | `antcrate --cleanup <project>` |
| Remove specific candidates by ID | `antcrate --cleanup <project> --apply <id>[,<id>...]` |

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
| Watch the project tree painted by active events | `antcrate --watch <project> [--once] [--interval-ms N] [--no-color] [--depth N]` |
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
antcrate --propose <short-name> "<one-line description of the intent>"
```

This appends to `~/.antcrate/proposals.log` for user review. Examples:

```
antcrate --propose remove "Backup-protected project removal with registry purge"
antcrate --propose dockerize "Generate Dockerfile + compose stub from project meta"
antcrate --propose env-rotate "Rotate .env values; backup the prior file under ~/.antcrate/secrets/"
```

Inspect: `antcrate --proposals` or `cat ~/.antcrate/proposals.log`.

The user reviews proposals and decides which become real flags. Until that happens, the bare command remains off-limits — the proposal log is how Claude says "I would have needed this" without bypassing the safety boundary.

## Plugins & external tools (let-it / feed-it / gate-it)

AntCrate is a **mediator, not a dominator**. It supplements tools so work can run locally; when a plugin/MCP already does that, AntCrate stays out of the way. It only steps in when something is missing or an AntCrate guideline is at stake. Every external surface sorts into one of three buckets:

- **🟢 LET IT** — pure capability that touches no AntCrate invariant. Use freely; no antcrate involvement. Examples: `context7` (live library docs), `clangd-lsp` + the `cpp-check` skill (C++ for `antcrate-core`), `security-guidance` / `security-review`, `superpowers` method-skills (TDD, brainstorming, systematic-debugging — the *how*; AGENTS.md is the *what-you-may-touch*), `code-review` (cloud, opt-in deeper pass — `--ci` stays the must-pass LOCAL gate), `claude-code-setup`.
- **🔵 FEED IT** — AntCrate generates, the surface renders; AntCrate stays the source of truth. **Obsidian** is the local read view-layer: `antcrate --obsidian-mirror [project] [--with-docs]` mirrors the registry graph + per-project tree/ledger/docs into `<vault>/AntCrate/` (one-way, read-only, never writes back). **Google Drive** is the research/producer side of `BUNDLE_SPEC` (proposal `drive-bundle`).
- **🟡 GATE IT** — overlaps an AntCrate guideline, so the gate-bearing flag stays mandatory **for registered projects** (AGENTS.md rule #18). The `commit-commands` + `github` plugins overlap `--commit` / `--pp`: those flags own the commit/push step for any registered project (secret-guard, push-triage, private-default, Gateway-Law). The plugins handle non-registered trees + read-only GitHub queries.

When a new plugin/MCP arrives, classify it into one of these buckets before reaching for it; if it would touch a registered project's structure, commits, or destructive ops, it's GATE-IT and the antcrate flag wins.

## Quick index by verb

- **see**: `--status`, `--list`, `--map`, `--logs`, `--diff`, `--proposals`, `--registry-diagram`, `--tree-diagram`, `--watch`, `--watch-smoke`, `--watch-window`, `--selfcheck`, `--cost`
- **make**: `--start`, `--register`, `--branch`, `--link`, `--gh-init`, `--touch`, `--mkdir`, `--diagrams`
- **point at**: `--addr`, `--anchor`, `--in`
- **change**: `--rename`, `--resume --expand`, `--restore`, `--touch`, `--mkdir`
- **soft-delete / restore**: `--archive`, `--unarchive`
- **hard-delete**: `--remove` (backup-only recovery)
- **safeguard**: `--backup`, `--backups`, `--restore`
- **ship**: `--pp`
- **build self**: `--selfsrc`, `--selfinstall`, `--install-from-source`, `--selftest`, `--selfedit`, `--ci`
- **propose**: `--propose`, `--proposals`
