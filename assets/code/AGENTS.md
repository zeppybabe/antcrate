# AntCrate — Agent Operating Rules

These rules govern any AI agent (Claude Code, Cursor, etc.) operating on or with AntCrate. They are **non-negotiable defaults**. The user can relax them per-session by stating so explicitly.

## Hard rules (refuse unless explicit user approval)

1. **No destructive ops, anywhere, without (a) backup AND (b) human approval.**
   - Applies to: `rm`, `rm -rf`, `mv` away from the project's registered path, `find -delete`, `> file` truncation, `git clean -fdx`, `git reset --hard` on uncommitted work, `--restore` overwriting a non-empty tree, `--resume --expand` (sub-branch is a destructive move), template overwrites.
   - Precondition: a successful tarball under `~/.antcrate/backups/<project>/`. **No backup → no removal.**
   - Approval: interactive `y/N` prompt unless `ANTCRATE_REMOVAL_PREAPPROVED=1` is set in `~/.antcrate/config` (the only sanctioned bypass).
   - Override `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` does **not** bypass this rule — it only widens the path zone, not the backup/approval requirement.
   - Refusal mode: if running non-interactively (daemon, agent without a TTY) and no pre-approval, the op aborts and the backup is retained for inspection.
2. **No path-mutating ops outside `$ANTCRATE_ROOT`** (default `~/projects/`) and `$ANTCRATE_HOME` (`~/.antcrate/`) without `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` AND human approval.
3. **Never delete `~/.antcrate/registry.json`.** Mutations only via `lib/registry.sh` helpers (atomic temp-file replacement). Suspected corruption → copy to `registry.json.bak.<timestamp>` first.
4. **Never delete `/tmp/antcrate_conflict.log`** without user approval — evidence for the most recent push failure.
5. **No `git push --force` / `--force-with-lease`** unless the user types the exact command.
6. **No `sudo`** for any AntCrate operation.
7. **No edits outside the AntCrate write zones** (`$ANTCRATE_ROOT`, `~/.antcrate/`, `~/.local/bin/antcrate*`, `~/.local/share/antcrate/`, `~/.config/systemd/user/antcrated.service`) without explicit user approval. Includes `~/.bashrc`, `~/.zshrc`, `~/.profile`, `/etc/*`.
8. **No network calls** other than `git push/pull/fetch` against configured remotes, `gh` CLI for repo create/auth (user-initiated), `mailx`/`sendmail` SMTP for triage dispatch (user-configured recipient).
9. **No reading of secrets in plaintext logs.** `.env*` is gitignored by default; agents must not `cat` them into chat.
10. **No bare `cd` into a registered project.** Use `antcrate --in <project> [--addr <code>] -- <cmd>` for one-shot execution, or `eval "$(antcrate --anchor <project>)"` for the calling shell. Anchor is exposed as `$ANTCRATE_ANCHOR`. Bare `cd` leaks shell state and bypasses the wrapper as the canonical entry point. See `assets/docs/PATTERNS.md`.
11. **No bare command on a registered project when a wrapper exists.** Read `assets/docs/PATTERNS.md` first. If your intent isn't listed, use `antcrate --propose <name> "<intent>"` and wait for user review — never silently fall back to `mv`/`rm`/`git push`/etc.

## Soft rules (proceed but log to ledger)

- New project creation via `--start` or `--branch` — fine, log path to ledger.
- Symlink creation — fine, log target.
- Template edits — fine, log which template.
- Registry queries (`--list`, `--status`, `ac_registry_get`) — fine, no log needed.

## Approval format

When a hard-rule action is needed, the agent asks:

> _"This requires approval per AGENTS.md rule #N: `<exact command>`. Proceed? [y/N]"_

Only on explicit `y` does the action run. Anything else aborts.

## Recovery checklist (when something goes wrong)

1. Check `/tmp/antcrate_conflict.log` for the most recent push triage.
2. Check `~/.antcrate/log/wrapper.log` and `~/.antcrate/log/daemon.log` for the failing call.
3. Check `~/.antcrate/registry.json` integrity: `jq . ~/.antcrate/registry.json`.
4. If the daemon is stuck paused, remove `~/.antcrate/pipe.paused` manually.
5. If the daemon PID is stale: `rm ~/.antcrate/daemon.pid && systemctl --user restart antcrated`.

## Test-before-modify protocol

Before any code change, the agent runs:

```bash
bats ~/.local/share/antcrate/tests/   # or wherever tests live in this checkout
```

A failing test must be reported before the agent proceeds. Skipping tests requires explicit user approval.
