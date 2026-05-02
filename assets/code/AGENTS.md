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

12. **The Gateway Law — verify-before-update/remove, removal needs executive joint decision.** Two restrictions and one ordering rule that operate ON TOP of rule #1.

    **Two restrictions:**
    - **Update gateway** (`git push`, version bumps, release tags, dependency upgrades touching remote state): locked by default. Unlocks per-action only after backup + verification chain + explicit user approval. Past consent does not roll forward to a new push — each push is its own decision.
    - **Removal gateway** (universal: local `rm`, registry delete, `--remove`, archive→remove escalation, dropping branches, deleting issues/PRs, dropping db tables): requires *executive joint decision* — agent attaches reasoning, antcrate produces verification output, user explicitly approves. Never auto-approved. Never scripted past. Never bypassed by hooks. No "I already approved similar earlier in the session."

    **Verification chain order (mandatory; the destructive step is always LAST):**
    1. Read entity's role in registry, roadmap, active dependents (`linked_nodes`, bundle relationships, in-flight work).
    2. Confirm no active dependents block the action.
    3. Run backup — `antcrate --backup <name>`.
    4. Show user verify output: `--status`, `jq .projects[name]`, `find <path>`, dependents map.
    5. Receive explicit user approval (the executive decision).
    6. THEN execute the destructive command.

    **Compress-or-remove default:** if unsure between removal and compression, default to compression — `antcrate --archive` keeps the project under `_archived` parent in the registry, on disk under `~/projects/.archive/`, recoverable via `--unarchive` or `--restore`. Removal is a strictly later, separately-approved decision.

    **Why:** Removals leak data, leak security state, destroy in-progress work. The Gateway Law treats them as security events, not workflow events. Spans development / infrastructure / security tiers — dedicated antcrate per-tier on servers will apply the same law, eventually hardened with native plugins so an AI literally cannot bypass the gate.

13. **`~/.antcrate/config` is human-only territory.** Agents MAY read it (the wrapper sources it on startup to load bypass flags like `ANTCRATE_REMOVAL_PREAPPROVED`, `ANTCRATE_COMMIT_PREAPPROVED`, `ANTCRATE_ALLOW_OUTSIDE_ROOT`, and any future bypass). Agents MUST NEVER write or edit it — no `Write`, no `Edit`, no `sed -i`, no `echo >>`, no shell heredoc redirection. Any change to bypass flags is an *executive decision made by the human directly via `$EDITOR`*.

    **Why:** Bypass flags exist to neutralize rule #1 and rule #12 by design. They are escape valves *for the human*, not for the agent. If the agent could write to the config file, the agent could disarm its own gates — which defeats the entire security model. Same logic applies to `~/.antcrate/config.local`, any future per-tier config (e.g., `~/.antcrate/security.conf`, `~/.antcrate/infra.conf`), and any equivalent sanctioned-bypass file.

    **How to apply:**
    - Never propose `Write` / `Edit` / `sed -i` / `echo >>` targeting `~/.antcrate/config`.
    - If the agent believes a bypass is warranted, the agent surfaces the reasoning and asks the human to make the edit themselves: *"Please edit `~/.antcrate/config` to add `FOO=1` if you want to grant this bypass."*
    - The wrapper reading the config is fine; that's a load-time pass-through. Programmatic mutation is what's banned.
    - Extends to mirrors of the config (e.g., the systemd unit's `EnvironmentFile=`): same write-ban applies wherever bypass values can be sourced.

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
