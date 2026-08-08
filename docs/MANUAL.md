# ANTCRATE(1) — User Manual

## NAME

**antcrate** — pure-Bash deterministic project orchestrator and agent-governance layer

## SYNOPSIS

```
antcrate --<command> [arguments] [options]
antcrated                  # the daemon (inotifywait event pipe)
```

All invocations go through a single dispatcher; a compact WORD selects the command (`antcrate st`, `antcrate pp <p>`, `antcrate duty ls`, …). The `--flag` forms below are the internal canonical map — leading use was retired 2026-07-10 and exits 2 with a pointer to the word; only flag-only surfaces (`--emit-activity`, `--gh-init`, diagram/quarantine/addr commands, …) still lead with a flag. Modifier flags after a word are unchanged. Running `antcrate` with no arguments prints the compact usage.

## DESCRIPTION

AntCrate wraps the structural, destructive, and remote-facing operations of a project workspace behind one auditable command surface. Project state lives in a jq-managed JSON registry (`~/.local/share/antcrate/registry.json`); every mutation is atomic (jq + temp-file replacement). Destructive operations are gated by mandatory backup and human approval. Nothing runs elevated.

The intended operator is a solo developer working with an AI coding agent: the agent gets full speed inside registered project trees, and AntCrate is the boundary it cannot cross — pushes, removals, renames, hook execution, and secret exposure all route through gated flags.

## CONCEPTS

### The registry

`~/.local/share/antcrate/registry.json` is the single source of truth: per-project path, domain, parent/child nesting, linked nodes, git remote, recent removals. All reads and writes go through `lib/registry.sh`. Direct edits are prohibited (and guarded against).

### Positional Extension Schema

Filenames are argument arrays: `Name.Domain.Action.#Meta#`. Position 1 is the project name, 2 the domain (`webapps`, `scripts`, `notes`, `projects`, `_generic`), 3 the action (`start`, `branch`, `link`, `rel`), 4 the meta block (`#csv,values#` or `key=value`). Creating the file `coolapp.webapps.start.#html,css,ts#` in a watched directory is exactly equivalent to running `antcrate --start coolapp --domain webapps --meta html,css,ts`.

### The daemon

`antcrated` is a single-instance (`flock`-coordinated) `inotifywait` process. It watches for `create | close_write | moved_to | moved_from | delete` events, filters editor swap/dot files, decodes schema-matching filenames into wrapper invocations, and regenerates the per-project Mermaid tree diagram on every filesystem event (debounced per project, default 600 ms). A pause flag (`~/.local/state/antcrate/pipe.paused`) suspends it atomically during structural refactors.

### Anchor and address

No command ever requires `cd`. `--anchor` exports a stable project handle (`$ANTCRATE_ANCHOR`); `--in` runs a single command with its working directory set to the project root. The **layered address system** assigns every file a positional code: alternating digit/letter segments, depth 1 = digit, letters bijective base-26. `1a3` = the 3rd entry inside the 1st sub-branch of the 1st top-level directory. Entries sort lexicographically (`LC_ALL=C`), 1-based; hidden files and noise directories (`.git`, `node_modules`, `dist`, …) are filtered unless `ANTCRATE_ADDR_INCLUDE_HIDDEN=1`.

### The safety model

Three mechanisms compose, strictest innermost:

1. **Rule #1 chokepoint** — `ac_safety_guard_destructive` forces backup + explicit approval before any destructive action (`mv`, `arc`, `rm`, `gc --apply`, `--resume --expand`, bundle `supersedes`) touches disk.
2. **Gateway Law** — updates/removals are always the *last* step of any chain: read state → confirm no dependents → backup → show the human the verify output → receive approval → execute.
3. **Quarantine over destruction** — automated paths never delete user data; they capture it (archive + manifest) into the quarantine directory. There is deliberately no purge command.

> A fourth mechanism, the Wave-1 **compaction canary**, was retired on 2026-07-10 (AGENTS.md rule #15). Harness-level context summaries made compaction-loss a non-threat, and the gate silently blocked every destructive op on installs without a built helper binary. Its code lives on the `attic` branch.

### The agent boundary

Codified in `assets/code/AGENTS.md` (the hard rules). The operational summary: agents use wrapper flags, never bare structural/destructive/push commands; when no flag fits, they file `--propose`; actions only the human may take are filed with `--duty`; `~/.config/antcrate/config` is human-only territory, as are endpoints in `policy.json`; escape hatches (`ANTCRATE_SESSION_GATE_DISABLE`, `ANTCRATE_ENV_GUARD_DISABLE`, `ANTCRATE_SANDBOX_DISABLE`) exist for CI and are off-limits to agents.

## COMMANDS

### Setup and status

**`antcrate --init`**
First-run setup: creates the XDG config/data/state directories (`~/.config/antcrate`, `~/.local/share/antcrate`, `~/.local/state/antcrate`), writes the default config, reports missing dependencies. The only sanctioned automated write to `~/.config/antcrate/config` (the rule-#13 carve-out).

**`antcrate --status`**
One-screen summary: root, state dir, registry path, daemon state, pipe state, project count, self-source health, unread intel count, audit cadence (`last/due`), open duties count.

The doctor's `wrapper` row reports not just that a wrapper is installed but whether it MATCHES `ANTCRATE_SELFSRC` — libs compared byte-for-byte, binaries with the single `LIB_DIR` line rewritten the way `install.sh` writes it, plus a count of retired libs still present in the install. Drift turns the row into a miss carrying `antcrate self install`. Added after a stale install silently ran an obsolete `self ci` that reported PASS with both of its gates skipped (audit 2026-07-25, finding D).

**`antcrate --list`**
Compact tab-separated project list.

**`antcrate --info <project>`**
Formatted single-project record: path, domain, git remote, linked nodes, backups, current branch, last commit, working-tree state.

**`antcrate --logs [project] [lines]`**
Tails wrapper, daemon, and conflict logs (default 50 lines); with a registered project, also shows `git log --oneline -n 5`.

**`antcrate --selfcheck [--quiet]`**
Self-source persistence health: registry path, skill link, git state, unpushed commits, dirty tree, backup age. Exit **0** healthy / **1** critical / **2** warnings. Pairs with the daily backup timer.

**`antcrate --help`**
Built-in usage summary.

### Project lifecycle

**`antcrate --start <name> --domain <domain> [--meta "<csv|k=v>"]`**
Scaffold + register a new project from the domain template. Auto-scaffolds `docs/diagrams/architecture.mmd`.

**`antcrate --register <name> <existing-path> [--domain <d>]`**
Add a registry entry for a tree already on disk (no scaffold). Domain defaults to the parent directory name.

**`antcrate --branch <name> --domain <domain> [--meta "from=<base>"]`**
New project inheriting the structure of `<base>`.

**`antcrate --link <a> --rel <b>`**
Bidirectional link between two projects, stored under `linked_nodes`.

**`antcrate --resume <parent> --expand <child>`**
Atomic sub-branch / nesting refactor: pauses the daemon, moves the tree, rewrites the registry and `linked_nodes`, resumes. Backup-protected.

**`antcrate --rename <project> <new-name>`**
Backup + approval; rewrites registry, parent refs, and linked nodes.

**`antcrate --archive <project>`** / **`antcrate --unarchive <project>`**
Backup + approval; moves to `~/Projects/.archive/<project>` (storing `previous_parent`) and back.

**`antcrate --remove <project>`**
PERMANENT delete: backup + approval + loud banner; `rm -rf` + registry purge. Recovery only via the printed backup tarball. Prefer `--archive` when uncertain.

**`antcrate --relocate <project> [--no-watch]`**
Move a project out of `~/.claude` into `~/Projects`, leaving a symlink behind; `--no-watch` keeps the daemon off it.

### Registry hygiene

**`antcrate --ghosts`**
Read-only list of registry entries whose on-disk path no longer exists.

**`antcrate --deregister <project>`**
Drop a *ghost* entry from the registry — capture-first (entry, registry snapshot, manifest under `~/.local/state/antcrate/deregistered/`), then delete the entry. **Refuses (exit 1) if the path still exists** — use `--archive` instead. Never touches user data.

### Files and navigation

**`antcrate --addr <project> <code>`**
Resolve a layered address (e.g. `1a3`) to an absolute path.

**`antcrate --anchor <project> [--addr <code>]`**
Emit eval-able exports: `ANTCRATE_ANCHOR` (directory), `ANTCRATE_ANCHOR_NAME`, and `ANTCRATE_ANCHOR_FILE` when the address points at a file. Usage: `eval "$(antcrate --anchor myproj)"`.

**`antcrate --in <project> [--addr <code>] -- <cmd...>`**
Run one command with cwd set to the project root (or addressed sub-path). No shell-state leak.

**`antcrate --map <project>`**
Addressed tree view with `[d]`/`[s]` dynamic/static tags.

### Backups and quarantine

**`antcrate bak <project>`**
On-demand backup, fanned to every enabled target (config `backup_targets=`, comma list, default `local`) with a per-target OK/FAIL report: `local` = verified tar.gz + sha256 manifest under the backups dir with retention pruning (`ANTCRATE_BACKUP_RETENTION`); `git-mirror` = the project's `dev/` pushed to its private companion repo. Non-zero only when every eligible target failed.

**`antcrate --backups <project>`**
Reverse-chronological backup list.

**`antcrate --restore <project> [--at <ts>]`**
Restore from the latest backup, or the snapshot matching the `-YYYYMMDDTHHMMSSZ` filename suffix. If the target tree is non-empty, a pre-restore backup is created automatically.

**`antcrate --quarantine-list <project>`**
Read-only list of quarantine entries, newest first.

**`antcrate --quarantine-restore <project> --at <ts>`**
Restore a quarantined entry to its original path; **refuses (exit 1)** if the original path already exists. There is no `--quarantine-purge`: only the human deletes the quarantine root.

### Git and GitHub

**`antcrate commit <project> -m "<msg>" [--all-tracked | -- <files...>]`**
Stage + commit through the wrapper: secret-pattern guard on the diff, Gateway-Law preview, y/N prompt on a TTY; non-TTY proceeds (the `-y` flag and PREAPPROVED envs were retired 2026-07-10). Replaces bare `git add` + `git commit`.

**`antcrate pp <project> [--no-mirror]`**
Push-pipe: commit (if dirty) and push, with conflict triage. On rejection: stderr captured, `git diff @{u}..HEAD` truncated to 300 lines and emailed (`ANTCRATE_EMAIL`), full log at `/tmp/antcrate_conflict.log`. Successful pushes print a `verify: <upstream> in sync at <SHA>` line, then — when config `mirror_dev=` lists the project — push the git-ignored `dev/` tree to the private `<owner>/<project>-dev` companion repo (created on first push; `--no-mirror` skips once; mirror failure warns but never fails the public push). Replaces bare `git push`.

**`antcrate --diff <project>`**
`git status` + `git diff` via `git -C` — no cd.

**`antcrate --git-init <project>`**
Local-only idempotent `git init`; wires `core.hooksPath .githooks` when the project ships a `.githooks/` directory.

**`antcrate --bootstrap <project> [-m "<msg>"] [--with-remote [--public|--private]]`**
One-liner: `--git-init` + default `.gitignore` (secret-pattern denylist + cleanup-prune giants) + first commit. `--with-remote` chains `--gh-init`. Idempotent — re-runs on a clean tree are no-ops.

**`antcrate --gh-init <project> [--public]`**
Create the GitHub repo over HTTPS via the `gh` CLI and push the initial commit. **Private by default**; `--public` is explicit opt-in. No plaintext PATs.

**`antcrate --gh-help`**
Print the GitHub HTTPS onboarding steps.

### Git hooks

**`antcrate --hooks <project>`**
Read-only list of active git hooks; honors `core.hooksPath`, marks each hook `active`/`disabled`, flags AntCrate's own opt-in `.githooks`.

Linked worktrees and submodules are first-class since the 2026-07-24 audit: every gated command uses `ac_is_git_repo` (`lib/git.sh`), which accepts a `.git` FILE, and every git-dir path goes through `ac_git_path` → `git rev-parse --git-path`. So hooks resolve to the shared common dir (one install covers all worktrees) while hook logs, audit logs, and bypass flags stay per-worktree.

**`antcrate --hook-install <project> <template> [hook-name] [--force]`**
Install a shipped template (`pre-commit-ci`, `pre-commit-secrets`, `pre-commit-stack-bash`, `pre-push-tests`). Idempotent; `--force` backs up then overwrites.

**`antcrate --hook-remove <project> <hook> [--force]`**
Remove a hook — backs up to `<hook>.bak.<ts>`, audit-logged to both `~/.local/state/antcrate/hooks.log` and `.git/antcrate-hook-audit.log`.

**`antcrate --hook-render <template> [project]`**
Render a template to stdout without installing (placeholder substitution + bypass-check injection) — preview after edits to catch injection bugs.

**`antcrate --hook-debug <project> [hook] [--with-stash] [--no-trace]`**
Re-run a hook with annotated `bash -x` trace and captured stdout/stderr; `--with-stash` mirrors the commit-time staged set. Audit-logged; exits with the hook's exit code.

**`antcrate --hook-bypass <project> --reason "<text>"`**
Write a single-shot bypass flag; the next AntCrate-shipped hook consumes it, logs the bypass + reason to both audit sinks, deletes the flag, and exits 0. Agents may *propose* a bypass; humans run it (rule #14).

**`antcrate --hook-audit <project> [N]`**
Unified read-only view of the three hook audit sinks (global JSONL, per-project plain, human-readable log), N lines per sink (default 20).

**`antcrate --hook-log <project> [lines]`**
Tail `.git/antcrate-hook.log` — the file the shipped pre-commit tees to. Default 50 lines.

**`antcrate --hook-autoinstall <project> [--dry-run]`**
One-shot: read `--profile` recommendations, install the picked template per hook slot, patch `.gitignore` for env safety. Idempotent; `--dry-run` prints the plan.

**`antcrate --hook-smoke <hook-script> (--command '<cmd>' | --file <path> | --payload '<json>') [--tool <name>]`**
Pipe a synthetic Claude Code PreToolUse/PostToolUse payload into a hook script, surface its stderr and a verdict line, and **propagate its exit code** (0 allow / 1 warn / 2 block). Note: a literal destructive string in `--command` also sits in *your* shell command — live guards may block the smoke itself; use benign text live and assert block paths in tests.

### Agent layer

**`antcrate --agent-init <project>`**
Drop a project-scoped agent pointer at `<project>/.claude/agents/<project>-cody.md` and initialize the attempt counter. Idempotent.

**`antcrate --md-scaffold <project> [--force]`**
Write `CLAUDE.md` / `AGENTS.md` / `state.md` / `ledger.md` at the project root from internal templates. Refresh-only by default; `--force` backs up existing files first.

**`antcrate --profile <project> [--raw]`**
Read-only stack/tooling/env profile + hook recommendations. `--raw` emits TAB-separated output for downstream consumption.

**`antcrate --env-scan <project> [--apply]`**
List `.env` files + environment-variable references. `--apply` idempotently adds standard `.env` patterns to `.gitignore`. Never modifies `.env` files themselves.

### Duties and proposals

**`antcrate --duty "<text>"`**
Append a human-only action to the `duties.md` checklist (key rotation, policy approvals, config edits, systemd enables). Surfaced in `--status` and in the session-budget gate's wrap-up message.

**`antcrate --duties`** / **`antcrate --duty-done <n>`**
Numbered list of open duties; mark the nth done (user-driven — agents file duties, never close them). Items are never deleted.

**`antcrate --propose <name> "<description>"`**
Log a proposed flag/pattern to `~/.local/state/antcrate/proposals.log` — the escape valve when no flag fits an intent. The bare command stays off-limits until the human turns the proposal into a real flag.

**`antcrate --proposals`**
List all logged proposals.

### Activity stream and watch

**`antcrate --emit-activity <project> <kind> <relpath> [--ttl-ms N] [--label X] [--agent A]`**
Append an event to the durable JSONL stream (`~/.local/state/antcrate/events/<project>.jsonl`). Kinds: `modify` (yellow), `read` (cyan), `think` (magenta), `delegate` (green), `delete` (bright-red strikethrough, 1 s tombstone). Kind-specific default TTLs.

**`antcrate --watch [<project>] [--follow] [--once] [--interval-ms N] [--no-color] [--depth N]`**
Live colored project tree painted by active events. Full-screen loop: alternate screen buffer (scrollback preserved), cursor hidden, autowrap off, frame clamped to terminal height with a `… (+N more lines)` marker. `--follow` tracks the registered project with the newest active event each frame (project arg optional; with `--once` it renders the hot project once, exit 1 if none). Severity ordering: delete > modify > delegate > think > read; ancestors paint with their highest-severity descendant. The `activity-emitter.sh` Claude Code hook (PostToolUse `Edit|Write|Read|NotebookEdit`) feeds the stream automatically.

**`antcrate --watch-smoke <project> [kind] [relpath] [--ttl-ms N] [--depth N] [--no-color]`**
Emit one event then render once — the smoke shortcut.

**`antcrate --watch-window <project> [--terminal NAME]`**
Spawn a detached terminal (default: alacritty) running `--watch`, deduplicated by PID file.

### Cleanup

**`antcrate --cleanup <project> [--apply <id>[,<id>...]]`**
Without `--apply`: read-only listing of removal candidates — `test-tmp` (`__pycache__`, `.pytest_cache`, `coverage`, `*.pyc`, …) and `empty-dir`. With `--apply`: each removal runs through the rule-#1 backup gate, emits a tombstone event, and is recorded in the project's `recent_removals`.

### Diagrams

**`antcrate --diagrams <project>`**
Render every `docs/diagrams/*.{mmd,puml,d2}` source to SVG when `mmdc`/`plantuml`/`d2` are present; warns and continues otherwise (Mermaid sources render inline on GitHub regardless).

**`antcrate --registry-diagram [out.mmd]`** / **`antcrate --tree-diagram <project> [out.mmd]`**
Mermaid graph of the entire registry (archived projects dimmed, links drawn `<-->`), and of one project's addressed tree. Normally unneeded by hand: every mutating wrapper action and every filesystem event under a registered project auto-regenerates both (disable with `ANTCRATE_AUTO_DIAGRAMS=0`; failures never block the triggering action).

### Bundles

**`antcrate --ingest <bundle-path>`**
Consume a research bundle per `BUNDLE_SPEC.md` v1.0: `manifest.json` is validated *before any disk write*; on failure the bundle status is set and nothing partial lands. All four `source.type` variants are materialized (`none`/`git`/`archive`/`composite`); `supersedes` invokes the rule-#1 backup gate; `extends` merges into an existing project; `duplicate_of`/`depends_on` warn. `ANTCRATE_INGEST_OFFLINE=1` skips reachability checks.

### Intel

**`antcrate intel pull [--quiet] [<id>]`**
Fetch the pinned Anthropic seed sources (intel data dir `sources.json`; anthropic.com / docs.claude.com / github.com/anthropics/* only — **any other seed host fails the whole pull with exit 2, before any fetch**) plus any human-curated extras from `~/.config/antcrate/intel-sources.json` (`{sources:[{id,url,kind?}]}`; https-only, duplicate ids refused, and **human-only: agents read the file, never write it**). Hash change → snapshot + unread row. A daily systemd timer runs this; no LLM in the timer.

**`antcrate intel ls [--json] [--kind <k>]`**
Unread items (new minus acked, both append-only). `--kind` filters by source kind (`dev`, `security`, …); every seed source is `dev`.

**`antcrate intel ack all | <id> [<sha256>]`** / **`antcrate intel st`**
Mark reviewed (everything, one source, or one item); per-source kind / last-pull / last-change / unread summary (user extras marked `(user)`). Nothing in the intel tree is ever deleted.

### Model endpoints & sandbox

`~/.local/state/antcrate/anycrate/policy.json` carries an `.endpoints` map (spec 2026-07-16) describing where local/remote model inference may run. Three kinds, validated by `ac_policy_endpoints_validate` (reports every defect, not just the first):

| Kind | Requires | Notes |
|---|---|---|
| `local` | `exec` | Optional `model_file` (passed as `-m`, `~` expanded) and `sandbox` (bool, default `true`). The only kind AntCrate ever launches. |
| `vllm` | `url` | Remote; `http://` allowed (LAN reality). Read/reference only — never launched by `ac_endpoint_run`. |
| `api` | `url` | Remote; `url` **must** be `https://`. Read/reference only. |

**`antcrate policy`**
Pretty-prints the whole policy file, then an `.endpoints` table (`name  [kind]  url-or-exec`), an edit hint, and the schema line above. Also runs the endpoints validator and surfaces every defect found.

**`antcrate policy seed`**
Idempotent seed (compact-word form of `--policy-init`): writes the file only if absent, never clobbers an existing one.

Endpoints are **HUMAN-ONLY**: agents may read `.endpoints` and reference an endpoint by name, but must never add, edit, or remove one — file `antcrate propose` instead (AGENTS.md rule #23; same standing as `~/.config/antcrate/config` and the intel-sources file). Edit by hand at `~/.local/state/antcrate/anycrate/policy.json`.

`antcrate st` shows a one-line summary — `policy: N endpoints (M local) · sandbox available|unavailable|unavailable (macOS)` — or, if the file is missing, `policy: missing — fix: antcrate policy seed`. The doctor also carries an optional `policy` row (`present` / `policy.json absent — budget guards inert`, fix `antcrate policy seed`).

**Launching a local endpoint — `ac_endpoint_run <name> [args...]`** (lib function, no wrapper flag): reads the prompt on stdin, writes completion to stdout. Refuses (never downgrades) unknown names, non-`local` kinds, and endpoints with no `exec` — all rc 1. Endpoint names are allowlisted to `^[A-Za-z0-9._-]+$` before being interpolated into a jq path (injection guard). Sandboxed by default; an endpoint may opt out with `"sandbox": false` (human-set field, same as every other endpoint property).

**Sandbox behavior** (`lib/sandbox.sh`, `ac_sandbox_run <write_path> -- <cmd...>`): `systemd-run --user` hardening — `PrivateNetwork=yes`, `ProtectHome=read-only`, `ReadWritePaths=<write_path>`, `PrivateTmp=yes`, `NoNewPrivileges=yes`. `<write_path>` must be absolute and whitespace-free (rc 2 otherwise — whitespace would silently widen `ReadWritePaths` to multiple paths).

| Host | Behavior |
|---|---|
| Linux, hardening verified | Enforced. `ac_sandbox_capable` launches a real hardened probe unit and checks confinement *from inside* it (only-loopback networking, unwritable `$HOME`) — not merely "did `systemd-run` exit 0". |
| Linux, degraded (`kernel.apparmor_restrict_unprivileged_userns=1`, the Ubuntu 23.10+/24.04 default) | `systemd-run` succeeds but the kernel silently drops `PrivateNetwork`/`ProtectHome`; the probe's from-inside check catches this. Warns "hardening not enforceable on this host (kernel/AppArmor restriction?)" and runs unsandboxed. |
| macOS | No non-deprecated user-space isolation primitive (`sandbox-exec` is deprecated). Warns "unavailable on this OS" and runs unsandboxed (owner decision 2026-07-16: enforced-on-Linux, warn-on-macOS). |
| Any host, endpoint `"sandbox": false` | Per-endpoint human opt-out; runs unsandboxed, no warning (it's a deliberate policy setting, not a degrade). |
| Any host, `ANTCRATE_SANDBOX_DISABLE=1` | Human escape hatch, warned. Agents MUST NOT set this (AGENTS.md rule #24) — if a launch fails under the sandbox, report it, don't bypass it. |

**One-shot only.** V1 launches are single inference calls, not persistent servers: `PrivateNetwork=yes` is safe precisely because nothing outside the unit needs to reach in. A long-running server inside a private network namespace would be unreachable from the caller, so persistent sandboxed serving is out of scope (tracked for a future data-egress-classes design).

**Testing:** `tests/fixtures/mock-llm` is a deterministic model stand-in — reads the prompt on stdin, emits canned output, ignores argv. `MOCK_LLM_MODE` selects behavior: `ok` (default, echoes a char-count summary), `slow` (2s sleep then done), `garbage` (unparseable bytes), `tries-network` (attempts an outbound connection — must fail under `PrivateNetwork=yes`; a positive proof the sandbox is real). `ac_endpoint_run` carries `MOCK_LLM_MODE` through explicitly via `env(1)` since `systemd-run` units don't inherit the caller's environment. Also the designated test double for BizCrate v0.5's local tier.

### post — X update drafting

Two modes, one command. `antcrate post x <project>` with no `--draft` emits **MATERIAL**: a secret-guarded git log (every commit since the last post, or `HEAD~10..HEAD`/`HEAD` on a first post) plus a draft update string, printed for an AI or human to word by hand. `antcrate post x <project> --draft "<text>"` is the **delivery** step: it prepends the worded post to the project's git-ignored `X-POSTS.md`, and the human copies it into X. This tool never touches X at all — the copy-paste is the deliberate publish gate, trivially compliant with X's automation rules. (The v1 web-intent browser delivery, `--open` + `x-accounts.json`, was retired 2026-07-18 by owner decision in favor of this simpler drafts-folder flow; an API/MCP delivery backend remains a possible future opt-in.)

**`antcrate post x <project>`**
Prints `=== MATERIAL (<project>, <range>) ===`, the redacted commit log for the range, the repo URL if known, then `=== DRAFT ===` and a redacted ≤280-char draft built from commit subjects. Exit 3 if there's nothing new since the last post (or ever, for a fresh project); exit 2 if `<project>` isn't registered or isn't a git repo.

**`antcrate post x <project> --draft "<text>"`**
Guards `<text>` against credential-shaped content (refuses, exit 1, without echoing the match), then checks length with `ac_post_x_len` (URLs count as the t.co-wrapped 23 chars regardless of actual length; exit 1 with the computed count if over 280). Then prepends an entry to `<project-root>/X-POSTS.md` — newest first, each entry a `## <date> — <range> — drafted` header followed by the post text ready to copy — appends an update-log record (handle field `-`, status `drafted`), and advances the project's range pointer. On first use it ensures `X-POSTS.md` is git-ignored: if no ignore rule covers it, a single `X-POSTS.md` line is appended to the project's `.gitignore` (that one-line change is tracked and rides into the next commit — visible, deliberate). Drafts themselves never reach the public repo. Exit 2 on an unknown project or an unborn-HEAD repo (no commits yet — nothing to announce).

**`antcrate post x log <project>`**
Newest-first view of the project's update log. Exit 1 if nothing has been drafted for it yet.

**Update log** — `$ANTCRATE_POSTS_DIR/<project>.log` (default `~/.local/state/antcrate/posts/<project>.log`), append-only, tab-separated: `ISO8601Z<TAB>handle<TAB>range<TAB>status<TAB>text` (handle is `-` for drafts; the field order is a stable contract — antcrate-mcp's `antcrate_posts` tool parses it). The `range` field (`<last-sha>..<new-sha>`, or `start..<sha>` for a first post) is both the audit trail and the pointer the next MATERIAL call resumes from.

**Known trade-off:** the range pointer advances at `--draft` time, not at confirmed publish — a drafted-but-never-pasted entry still consumes its range. To re-draft a range, hand-edit the last log record's range field back to the prior end.

**Character counting — the ASCII stance.** `ac_post_x_len` counts *characters* (`wc -m`), after substituting each URL with the 23 characters t.co wraps it to. X's own rule is weighted: code points up to U+10FF (plus a few punctuation blocks) count as 1, and **everything else counts as 2** — so CJK, emoji and most symbols cost double there. AntCrate deliberately does not implement the weighted table: the counter is a pure-Bash pipeline that has to agree byte-for-byte across mawk/gawk/BSD awk, and per-code-point classification is exactly where this codebase has already been bitten (see the mawk interval-bound note above `AC_POST_SECRET_ERE`). The practical consequence: for Latin, Cyrillic, Greek, Hebrew and Arabic text the count is **exact**; for a post containing CJK or emoji it **under-counts**, and a draft that measures 280 here can be rejected by X. If you write such a post, budget roughly two characters for each non-Latin glyph, or paste it into X and check the counter before posting.

Exit codes: **0** material printed or draft written + logged · **1** guard refusal (secret-shaped text) or over-length text (count included in the message) · **2** unknown/unregistered project, unborn-HEAD repo, or a range `git log` could not read · **3** MATERIAL mode with nothing new to post.

### CI and self-development

**`antcrate --ci [--snapshot] [--source <path>]`**
Three fail-fast stages: shellcheck, full bats suite, cmake build + ctest. Every PASS records `{ts, bats, sha, branch}` to `~/.local/state/antcrate/ci-baseline.json`; `--snapshot` also sets the audit baseline; `--source` runs CI against an alternate tree (e.g. a git worktree). A check tool that is missing after `$ANTCRATE_TOOLS_BIN` is prepended is a hard FAIL, never a skip — a PASS that verified nothing is worse than no run, because it gets quoted as evidence afterwards. The shellcheck stage covers `lib/*.sh`, both binaries, `install.sh`, the hook source tree `hooks/claude/*.sh` and the hand-written `plugin/hooks/*.sh`; the generated copies under `plugin/hooks/claude/` are covered instead by `self plugin --check` (audit 2026-07-25, finding C).

**`antcrate --selfsrc`** / **`antcrate --selfedit <relpath>`**
Print the skill source root; resolve a file under it (pipe into `$EDITOR`).

**`antcrate --selfinstall`** / **`antcrate --install-from-source`**
Run `install.sh` from selfsrc; or from the registered `antcrate` project path, bypassing the cached `ANTCRATE_SELFSRC`. Installs use temp + rename — never truncating the executing binary's inode.

**`antcrate --selftest [pattern]`**
Run the bats suite, or one file (`--selftest address` → `tests/address.bats`).

### Daemon and schema

**`antcrate --pipe-file <basename>`**
Decode a positional filename and dispatch the equivalent command — the daemon's entry point, also callable directly.

`antcrated` runs as a foreground process or via the optional user-mode systemd unit (`systemd/antcrated.service`). Two more timers ship alongside: `antcrate-backup.timer` and `antcrate-intel.timer` (both daily).

## CLAUDE CODE HOOKS

Shipped under `assets/code/hooks/claude/`, wired into `~/.claude/settings.json`:

| Hook | Event | What it does |
|---|---|---|
| `gateway-guard.sh` | PreToolUse (Bash) | Blocks bare destructive shell commands on registered projects before they execute; heredoc-aware (data bodies excluded, interpreter-fed bodies scanned) |
| `env-guard.sh` | PreToolUse (Bash + Read) | Secret *values* never enter the transcript: blocks env dumps (`env`, `printenv`, `set`, `declare -p`), echo/printf of secret-named vars, and read sinks on secret files (`.env`, keys, `.netrc`, credentials). Assignment and by-name reference stay allowed |
| `session-budget-guard.sh` | PreToolUse (all) | Context-window gate: soft warn at 100k tokens (throttled), hard block at 140k except a wrap-up whitelist (commit, push, state files, duties), released only by the user running `/clear`. Fails open |
| `shellcheck-on-save.sh` | PostToolUse (Edit/Write) | Lints every shell-file edit on write |

Smoke-test any of them with `antcrate --hook-smoke`. Override knobs (`ANTCRATE_SESSION_SOFT/HARD`) are human-only config; the `*_DISABLE` escape hatches are for CI and must never be set by agents.

## FILES

| Path | Purpose |
|---|---|
| `~/.local/share/antcrate/registry.json` | Project registry — single source of truth |
| `~/.local/share/antcrate/registry.mmd` | Auto-regenerated Mermaid view of the registry |
| `~/.config/antcrate/config` | User defaults — human-only (rule #13); written once by `--init` |
| `~/.local/state/antcrate/backups/<project>/` | Verified tar.gz + sha256 manifests |
| `~/.local/state/antcrate/quarantine/` | Captured (never deleted) user data |
| `~/.local/state/antcrate/deregistered/<project>/<ts>/` | Capture-first ghost-drop records |
| `~/.local/state/antcrate/events/<project>.jsonl` | Durable activity stream |
| `~/.local/state/antcrate/proposals.log` | Append-only proposal log |
| `~/.local/state/antcrate/ci-baseline.json` | Last CI pass + audit baseline |
| `~/.local/share/antcrate/intel/` | Pinned-source snapshots + `new.jsonl`/`acked.jsonl` (append-only) |
| `~/.local/state/antcrate/anycrate/policy.json` | Model/budget/endpoint policy — human-only except `budgets.fable` (rule #22) and endpoints (rule #23); seed with `antcrate policy seed` |
| `~/.local/state/antcrate/log/{wrapper,daemon}.log` | Leveled logs |
| `~/.local/state/antcrate/daemon.{pid,lock}`, `pipe.paused` | Daemon coordination |
| `<project>/duties.md` | Human-only action checklist (antcrate repo root) |
| `.git/antcrate-hook.log`, `.git/antcrate-hook-audit.log` | Per-repo hook logs |
| `/tmp/antcrate_conflict.log` | Push-rejection triage log |

## ENVIRONMENT

| Variable | Default | Meaning |
|---|---|---|
| `ANTCRATE_ROOT` | `~/Projects` | Project root |
| `ANTCRATE_HOME` | `~/.local/state/antcrate` | State directory (alias of `ANTCRATE_STATE_HOME`) |
| `ANTCRATE_EMAIL` | — | Push-triage email recipient |
| `ANTCRATE_LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |
| `ANTCRATE_TREE_DEBOUNCE_MS` | `600` | Daemon per-project diagram debounce |
| `ANTCRATE_AUTO_DIAGRAMS` | `1` | `0` disables auto-regeneration |
| `ANTCRATE_ADDR_INCLUDE_HIDDEN` | `0` | `1` includes hidden files in addressing |
| `ANTCRATE_BACKUP_RETENTION` | — | Backup pruning depth |
| `ANTCRATE_TRIAGE_LINES` | `300` | Diff truncation for triage email |
| `ANTCRATE_INGEST_OFFLINE` | `0` | Skip bundle reachability checks |
| `ANTCRATE_SESSION_SOFT` / `_HARD` | `100000` / `140000` | Session-budget gate thresholds (human-only) |
| `ANTCRATE_ALLOW_OUTSIDE_ROOT` | unset | Required guard for any path mutation outside `$ANTCRATE_ROOT` |
| `ANTCRATE_SESSION_GATE_DISABLE`, `ANTCRATE_ENV_GUARD_DISABLE`, `ANTCRATE_SANDBOX_DISABLE` | unset | CI/test escape hatches — **agents must never set these** |
| `MOCK_LLM_MODE` | `ok` | Selects `tests/fixtures/mock-llm` behavior: `ok`\|`slow`\|`garbage`\|`tries-network` — test-only |

## EXIT STATUS

Convention across the surface: **0** success · **1** operational failure or guarded refusal (e.g. `deregister` on a live path, `--quarantine-restore` onto an existing path, `self check` critical) · **2** usage error, blocked operation, or policy refusal (unknown or retired flag, hook block verdict, non-Anthropic intel host) · `hook smoke` propagates the hook's own code.

> **Caveat, and a known wart.** Exit **2** currently means two different things: a usage error *and* `self check` finishing with warnings only. A CI job cannot distinguish "you typed it wrong" from "healthy, with notes". Tracked as a duty; do not rely on 2 alone to mean failure.

## SECURITY MODEL

User-privilege only; nothing elevated. Remotes are created private by default. Secret values are kept out of agent transcripts by the env-guard hook; commit diffs pass a secret-pattern guard; `.gitignore` scaffolding denylists secret files. No automated path deletes user data (quarantine over destruction). Hook bypass is single-shot, reason-required, and dual-logged. The intel fetcher refuses non-Anthropic hosts before any network call. Vulnerability reporting: GitHub private vulnerability reporting (see `SECURITY.md`).

## SEE ALSO

`assets/docs/PATTERNS.md` (flag-by-intent index) · `assets/docs/architecture.md` (blueprint) · `assets/code/AGENTS.md` (hard rules) · `assets/docs/BUNDLE_SPEC.md` · `assets/docs/HOOK_PLAN.md` · `README.md`
