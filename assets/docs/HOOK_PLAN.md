# AntCrate — Git Hooks Plan

Status: **shipped as of 2026-06-11** (status block refreshed at the 615-bats
audit). `--hooks`, `--hook-log`, `--hook-install`, `--hook-remove`,
`--hook-bypass`, `--hook-debug`, `--hook-autoinstall`, and `--hook-smoke` are
all live in `bin/antcrate` + `lib/hooks.sh`. The "Order of implementation"
section at the bottom records shipped dates. This document remains the design
contract so the surface stays coherent across sessions.

---

## Why hooks at all

AntCrate's wrapper-side gates (rule #1, rule #12, secret-pattern guard in
`--commit`) catch destructive ops at the boundary an agent or human
deliberately crosses. Git hooks are the *automatic* gate that catches a
bypass — when someone (or something) reaches for bare `git commit` /
`git push` outside the wrapper. Both layers are needed; neither alone is
enough.

Hooks also give us a hook (pun intended) for project-local checks that
shouldn't be in the global `--ci`: a SvelteKit project's `pre-commit`
might run `tsc --noEmit`; a Bash project's might run `shellcheck`; a
Rust project's might run `cargo check`. The wrapper is generic; the
hooks are stack-specific.

## What's shipped today (2026-05-01)

### `.githooks/pre-commit` (versioned with the antcrate skill repo)

Opt-in. Enable with `git config core.hooksPath .githooks`. Runs
`antcrate --ci` against the working tree, tees output to
`.git/antcrate-hook.log`. Exits nonzero on any failure (shellcheck dirty,
bats fail).

### `antcrate --hooks <project>`

Lists active hooks for a registered project. Reports the effective hooks
directory (honors `core.hooksPath`; falls back to `.git/hooks`). Output
columns: hook name, status (`active` if executable, `disabled` if not),
absolute path. Calls out whether antcrate's opt-in `.githooks` dir is
the active source.

### `antcrate --hook-log <project> [lines]`

Tails `<project>/.git/antcrate-hook.log`. Default 50 lines. The shipped
pre-commit appends a timestamped block per run, so this answers "what
went wrong on the last blocked commit?" without re-running the hook.

### `.github/workflows/ci.yml`

GitHub Actions workflow. On push to `master`/`main` and on PRs, installs
`jq` + `shellcheck` + `bats-core`, runs `install.sh`, then
`antcrate --ci`. The remote-side equivalent of the local pre-commit.

---

## What's queued (not yet implemented)

### Hook template library — `assets/code/hooks/templates/`

A versioned directory of hook templates AntCrate can install into
projects on demand. Each template is a stand-alone shell script with a
header naming its purpose, prerequisites, and which projects it suits.
Initial set:

| Template | Hook | Purpose |
|---|---|---|
| `pre-commit-ci` | pre-commit | Runs `antcrate --ci` (the antcrate-on-antcrate case). |
| `pre-commit-secrets` | pre-commit | Runs only the secret-pattern guard from `lib/commit.sh` standalone — for projects that want secret-blocking but don't have a full CI hook. |
| `pre-commit-stack-bash` | pre-commit | shellcheck on changed `.sh` files. |
| `pre-commit-stack-svelte` | pre-commit | `bunx tsc --noEmit` + `bunx eslint` on changed files. |
| `pre-push-tests` | pre-push | Runs project test command (read from `~/.antcrate/registry.json` `test_cmd` field). |
| `commit-msg-format` | commit-msg | Enforces `type(scope): description` format. |

Templates use a small token-substitution language (`__PROJECT_NAME__`,
`__ANTCRATE_BIN__`, etc.) at install time so the resulting hook is
self-contained and doesn't depend on env at execution time.

### `antcrate --hook-install <project> <template> [hook-name]`

Copies the named template into the project's effective hooks dir,
substitutes tokens, marks executable. If a hook of the same name already
exists, behavior is governed by AGENTS.md rule #1: backup the existing
hook to `~/.antcrate/backups/<project>/hooks/` before overwrite,
require approval. Logs the install to `~/.antcrate/hooks.log`.

### `antcrate --hook-remove <project> <hook-name>` — **shipped 2026-05-10**

Removes a hook. Backs the file up to `<hook>.bak.<UTC-timestamp>`
adjacent to the original (mirroring `--hook-install --force`'s pattern),
captures sha256 of the pre-removal file, and appends an audit entry to
**two** sinks:

- Global JSONL at `~/.antcrate/hooks.log` (one well-formed object per
  line — `{ts, ts_ms, action, project, hook, hooks_dir, sha256, backup}`).
- Per-project plain-text at `<project>/.git/antcrate-hook-audit.log`.

No-op friendly: removing a hook that isn't there returns 0 with a
notice and writes nothing to either log. `--force` is reserved (parsed
but currently a no-op) for the future case of skipping the backup.

The dual-sink shape is intentional: the global JSONL is the cross-
project audit feed (consumed later by a `--hook-audit` flag, mirrors
`events.jsonl` shape); the per-project plain-text lives with the
project so a `git log` reviewer can see hook history without touching
antcrate state.

`--hook-bypass` (next pass) will reuse the same `_ac_hooks_audit_append`
helper with `action: "hook-bypass"`.

### `antcrate --hook-bypass <project> --reason "<text>"` — **shipped 2026-05-11**

Sanctioned-bypass for a single commit. Writes a JSON flag file
(`.git/antcrate-hook-bypass`) with `{ts, reason, project}`. The next
antcrate-shipped hook to fire reads the flag's `.reason`, logs the
bypass + reason to **both** `.git/antcrate-hook.log` (human tail) and
`.git/antcrate-hook-audit.log` (audit), deletes the flag, and exits 0.
Single-shot — the flag is consumed by the first hook that sees it.

`--reason "<text>"` is **mandatory**. A reason-less bypass defeats the
audit invariant ("every bypass is logged with a human's reason") and is
refused with a validation error before any flag is written.

If a flag already exists, `--hook-bypass` refuses (no silent overwrite —
a stale flag plus a new reason would lose the prior reason and quietly
extend the bypass). The human consumes it (run a commit) or `rm`s it
deliberately.

Audit invariant. Three writes per bypass life-cycle:
- Wrapper-side, at write time: one row in `~/.antcrate/hooks.log` with
  `action: "hook-bypass"`, `backup: "reason:<text>"`, plus one row in
  the per-project plain-text audit log with the same fields.
- Hook-side, at consume time: one row in `.git/antcrate-hook.log`
  (`BYPASSED via antcrate --hook-bypass; reason=<text>`) and one row in
  the per-project audit log (`hook-bypass-consumed project=<name>
  hook=<name> reason=<text>`).

**Hook template injection.** The bypass-check logic is shared across
every antcrate-shipped hook template via a marker line:
`# __ANTCRATE_BYPASS_CHECK__`. `_ac_hook_render` replaces the marker at
install time with the canonical ~13-line bypass-check block, delivered
via awk's `ENVIRON` (not `-v`, which would interpret `\n` as a real
newline and break the snippet's `printf` format strings). Templates
without the marker — e.g. a future `commit-msg-format` — pass through
unchanged, appropriate when bypass doesn't make semantic sense.

This is the **escape valve** for cases where the hook itself is broken
(the prior `--ci` is dirty for an unrelated reason and we need to land
a fix). It is *not* a general "skip the gate" — that's what the human
editing `~/.antcrate/config` is for.

### AGENTS.md rule for hook bypass — **rule #14, added 2026-05-11**

See `AGENTS.md` rule #14 ("Hook bypass is a logged, single-shot, human-
only action"). Agents MAY propose `antcrate --hook-bypass`; humans run
the command. Agents MUST NOT call `--hook-bypass` directly, MUST NOT
create the flag by hand, MUST NOT use `git commit --no-verify`. The
rule also forbids deleting a stale flag — discarding a queued sanctioned
bypass is itself a human-only action.

### `--start --hooks <preset>` (auto-install on scaffold)

When creating a new project, optionally install a stack-appropriate hook
preset:

```
antcrate --start coolapp --domain webapps --meta html,css,ts --hooks svelte
```

`<preset>` maps to a list of templates. Default presets:
- `bash` → `pre-commit-stack-bash`, `commit-msg-format`
- `svelte` / `node` → `pre-commit-stack-svelte`, `commit-msg-format`
- `none` (default) → no hooks installed

Per-project meta in `registry.json` gains a `hooks_preset` field so
`--hooks` listing can show "preset: svelte" alongside the file list.

### `antcrate --hook-debug <project> [hook] [--with-stash] [--no-trace]` — **shipped 2026-05-11**

Re-runs the named hook (default `pre-commit`) with annotated output so
the human/agent can see exactly which check fired and what each one
emitted. Trace is pinned to `BASH_XTRACEFD` so xtrace lives in its own
stream — the hook's real stdout and stderr stay clean. `PS4` is set to
`+ <file>:<line>: ` so every trace line carries source coords.

`--with-stash` stashes unstaged changes with `--keep-index
--include-untracked` before running, then pops after. The hook then sees
exactly the staged set a real commit would use. Stash detection is via
stash-list-count delta (push returns 0 even when nothing is stashed).
Pop failures (e.g. conflict between staged + unstaged edits to the same
file) leave the stash in place and surface a `[warn]` line in primary
output.

`--no-trace` skips the xtrace pass — useful when the hook is already
verbose enough.

Audit-logged via the same `_ac_hooks_audit_append` helper introduced by
`--hook-remove`. Action `hook-debug`; sha256 captures the hook file's
content; `backup` field carries the stash refspec when `--with-stash`
created one (`stash:antcrate-hook-debug-<UTC-ts>`) so a future
`--hook-audit` consumer can recover the pre-debug worktree. The
annotated run is also appended to `.git/antcrate-hook.log` so
`--hook-log` tails surface debug runs alongside real commit-time runs.

Exits with the underlying hook's exit code so callers can branch on it.

---

## Surface boundaries (what hooks WILL NOT do)

- **Hooks will not silently mutate the project.** Auto-formatting in a
  hook is a footgun — it surprises the user. If an agent wants
  formatting, it should run the formatter explicitly. Hooks are read-
  and-decide, not read-and-rewrite.
- **Hooks will not push.** `pre-push` checks are fine; `pre-push` that
  pushes to a different remote is not. `git push` semantics belong to
  `--pp` (the wrapper command), not to a hook.
- **Hooks will not bypass the wrapper.** A hook that detects a violation
  should report and refuse — never "fix" the violation by routing
  through some side channel.

## Versioning + portability

Hook templates ship with the antcrate skill source (`assets/code/hooks/
templates/`) and are versioned with the rest of the codebase. Installing
a hook into a project copies the template at install time — the project's
hook is a snapshot, not a live link. Reinstall to upgrade.

`antcrate --hooks <project>` will surface the template version embedded
in installed hooks (a header comment line `# antcrate-template-version:
1.0`). When the template library updates, the listing shows which
projects are out of date.

---

## Order of implementation

1. Hook template library scaffolding (`assets/code/hooks/templates/`,
   loader in `lib/hooks.sh`). **Shipped 2026-05-07.**
2. `--hook-install` (without rule-#1 backup integration first; add the
   gate immediately after). **Shipped 2026-05-07.**
3. Rule #1 backup integration on overwrite/remove. **Shipped 2026-05-07**
   (`--hook-install --force` backs up to `<hook>.bak.<ts>`).
4. `--hook-remove`. **Shipped 2026-05-10** (dual audit-log infrastructure
   introduced here; reused by `--hook-bypass`).
5. `--hook-bypass` + audit log + AGENTS.md rule. **Shipped 2026-05-11**
   (shared bypass-check snippet auto-injected into every antcrate-shipped
   pre-commit/pre-push template via the `__ANTCRATE_BYPASS_CHECK__` marker;
   AGENTS.md rule #14 added).
6. `--start --hooks <preset>` auto-install. **Shipped 2026-05-07** as
   `--hook-autoinstall` (Phase 1 — single-slot constraint).
7. `--hook-debug` (re-run with annotation). **Shipped 2026-05-11.**
8. Composite pre-commit umbrella template (lifts the Phase-1 single-slot
   constraint so multiple stack checks can coexist). **Queued.**

Each step is one focused pass with bats coverage and a state.md /
ledger.md entry.
