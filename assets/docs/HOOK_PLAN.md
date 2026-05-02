# AntCrate — Git Hooks Plan

Status: **partial implementation as of 2026-05-01.** Read-only inspection
landed (`--hooks`, `--hook-log`); install/remove/bypass + template library
queued for follow-up. This document is the design contract for that
follow-up so the surface stays coherent across sessions.

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

### `antcrate --hook-remove <project> <hook-name>`

Removes a hook. Falls under rule #1 (backup + approval). Logs removal
with the file's sha256 so audit can detect tampering.

### `antcrate --hook-bypass <project> [--reason "<why>"]`

Sanctioned-bypass for a single commit. Writes a flag file
(`.git/antcrate-hook-bypass`) that the antcrate-shipped hooks check at
the top: if present, the hook logs the bypass + reason to
`.git/antcrate-hook.log`, deletes the flag, and exits 0. Single-shot —
the flag is consumed by the first hook that sees it.

Audit invariant: every bypass is logged. The flag file's deletion is
the proof of consumption; the log line names the timestamp + reason.

This is the **escape valve** for cases where the hook itself is broken
(the prior `--ci` is dirty for an unrelated reason and we need to land
a fix). It is *not* a general "skip the gate" — that's what the human
editing `~/.antcrate/config` is for.

### AGENTS.md rule for hook bypass

Add (rule #14 or fold into #13):

> **Hook bypass is a logged, single-shot human-approved action.** Agents
> may PROPOSE `antcrate --hook-bypass` with a reason; the human runs the
> command. Agents MUST NOT call `--hook-bypass` directly, MUST NOT
> manually create `.git/antcrate-hook-bypass`, and MUST NOT
> `git commit --no-verify`. The bypass log is part of the project's
> audit trail.

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

### `antcrate --hook-debug <project>` (richer than `--hook-log`)

Beyond just tailing the log: on demand, **re-runs** the failing hook in
verbose mode and pipes output through line-by-line annotation so the
human/agent can see exactly which check failed. Optional flag
`--with-stash` to stash unstaged changes first (so the run reflects the
staged set the commit would actually use).

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

## Order of implementation (proposed)

1. Hook template library scaffolding (`assets/code/hooks/templates/`,
   loader in `lib/hooks.sh`).
2. `--hook-install` (without rule-#1 backup integration first; add the
   gate immediately after).
3. Rule #1 backup integration on overwrite/remove.
4. `--hook-remove`.
5. `--hook-bypass` + audit log + AGENTS.md rule.
6. `--start --hooks <preset>` auto-install.
7. `--hook-debug` (re-run with annotation).

Each step is one focused pass with bats coverage and a state.md /
ledger.md entry.
