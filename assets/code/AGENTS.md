# AntCrate — Agent Operating Rules

These rules govern any AI agent (Claude Code, Cursor, etc.) operating on or with AntCrate. They are **non-negotiable defaults**. The user can relax them per-session by stating so explicitly.

## Hard rules (refuse unless explicit user approval)

1. **No destructive ops, anywhere, without (a) backup AND (b) human approval.**
   - Applies to: `rm`, `rm -rf`, `mv` away from the project's registered path, `find -delete`, `> file` truncation, `git clean -fdx`, `git reset --hard` on uncommitted work, `--restore` overwriting a non-empty tree, `--resume --expand` (sub-branch is a destructive move), template overwrites.
   - Precondition: a successful tarball under `~/.antcrate/backups/<project>/`. **No backup → no removal.**
   - Approval (audit 2026-07-10): at a TTY, interactive `y/N` prompt. Non-interactively (daemon, agent), the op **proceeds after the verified backup** and appends a `[command]` review duty to the duty ledger — approval is satisfied out-of-band by the human's review of `antcrate duties`, with Claude Code's own permission layer as the outer gate. The `ANTCRATE_*_PREAPPROVED` bypasses and `-y` were RETIRED 2026-07-10 (evening session) along with leading legacy `--flags`; internal wrapper sub-steps use `_AC_APPROVED` (see `ac_gate_confirm`).
   - Override `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` does **not** bypass this rule — it only widens the path zone, not the backup requirement.
2. **No path-mutating ops outside `$ANTCRATE_ROOT`** (default `~/projects/`) and `$ANTCRATE_HOME` (`~/.antcrate/`) without `ANTCRATE_ALLOW_OUTSIDE_ROOT=1` AND human approval.
3. **Never delete `~/.antcrate/registry.json`.** Mutations only via `lib/registry.sh` helpers (atomic temp-file replacement). Suspected corruption → copy to `registry.json.bak.<timestamp>` first.
4. **Never delete `/tmp/antcrate_conflict.log`** without user approval — evidence for the most recent push failure.
5. **No `git push --force` / `--force-with-lease`** unless the user types the exact command.
6. **No `sudo`** for any AntCrate operation.
7. **No edits outside the AntCrate write zones** (`$ANTCRATE_ROOT`, `~/.antcrate/`, `~/.local/bin/antcrate*`, `~/.local/share/antcrate/`, `~/.config/systemd/user/antcrated.service`) without explicit user approval. Includes `~/.bashrc`, `~/.zshrc`, `~/.profile`, `/etc/*`.
8. **No network calls** other than `git push/pull/fetch` against configured remotes, `gh` CLI for repo create/auth (user-initiated), `mailx`/`sendmail` SMTP for triage dispatch (user-configured recipient).
9. **No reading of secrets in plaintext logs.** `.env*` is gitignored by default; agents must not `cat` them into chat.
10. **No bare `cd` into a registered project.** Use `antcrate in <project> [--addr <code>] -- <cmd>` for one-shot execution, or `eval "$(antcrate anchor <project>)"` for the calling shell. Anchor is exposed as `$ANTCRATE_ANCHOR`. Bare `cd` leaks shell state and bypasses the wrapper as the canonical entry point. See `assets/docs/PATTERNS.md`.
11. **No bare command on a registered project when a wrapper exists.** Read `assets/docs/PATTERNS.md` first. If your intent isn't listed, use `antcrate propose <name> "<intent>"` and wait for user review — never silently fall back to `mv`/`rm`/`git push`/etc.

12. **The Gateway Law — verify-before-update/remove, removal needs executive joint decision.** Two restrictions and one ordering rule that operate ON TOP of rule #1.

    **Two restrictions:**
    - **Update gateway** (`git push`, version bumps, release tags, dependency upgrades touching remote state): locked by default. Unlocks per-action only after backup + verification chain + explicit user approval. Past consent does not roll forward to a new push — each push is its own decision.
    - **Removal gateway** (universal: local `rm`, registry delete, `--remove`, archive→remove escalation, dropping branches, deleting issues/PRs, dropping db tables): requires *executive joint decision* — agent attaches reasoning, antcrate produces verification output, user explicitly approves. Never auto-approved. Never scripted past. Never bypassed by hooks. No "I already approved similar earlier in the session."

    **Verification chain order (mandatory; the destructive step is always LAST):**
    1. Read entity's role in registry, roadmap, active dependents (`linked_nodes`, bundle relationships, in-flight work).
    2. Confirm no active dependents block the action.
    3. Run backup — `antcrate bak <name>`.
    4. Show user verify output: `--status`, `jq .projects[name]`, `find <path>`, dependents map.
    5. Receive explicit user approval (the executive decision).
    6. THEN execute the destructive command.

    **Compress-or-remove default:** if unsure between removal and compression, default to compression — `antcrate arc` keeps the project under `_archived` parent in the registry, on disk under `~/projects/.archive/`, recoverable via `--unarchive` or `--restore`. Removal is a strictly later, separately-approved decision.

    **Why:** Removals leak data, leak security state, destroy in-progress work. The Gateway Law treats them as security events, not workflow events. Spans development / infrastructure / security tiers — dedicated antcrate per-tier on servers will apply the same law, eventually hardened with native plugins so an AI literally cannot bypass the gate.

13. **`~/.antcrate/config` is human-only territory.** Agents MAY read it (the wrapper sources it on startup to load bypass flags like `ANTCRATE_ALLOW_OUTSIDE_ROOT`, `ANTCRATE_ALLOW_SYSTEM_INSTALL`, and any future bypass). Agents MUST NEVER write or edit it — no `Write`, no `Edit`, no `sed -i`, no `echo >>`, no shell heredoc redirection. Any change to bypass flags is an *executive decision made by the human directly via `$EDITOR`*.

    **Why:** Bypass flags exist to neutralize rule #1 and rule #12 by design. They are escape valves *for the human*, not for the agent. If the agent could write to the config file, the agent could disarm its own gates — which defeats the entire security model. Same logic applies to `~/.antcrate/config.local`, any future per-tier config (e.g., `~/.antcrate/security.conf`, `~/.antcrate/infra.conf`), and any equivalent sanctioned-bypass file.

    **How to apply:**
    - Never propose `Write` / `Edit` / `sed -i` / `echo >>` targeting `~/.antcrate/config`.
    - If the agent believes a bypass is warranted, the agent surfaces the reasoning and asks the human to make the edit themselves: *"Please edit `~/.antcrate/config` to add `FOO=1` if you want to grant this bypass."*
    - The wrapper reading the config is fine; that's a load-time pass-through. Programmatic mutation is what's banned.
    - Extends to mirrors of the config (e.g., the systemd unit's `EnvironmentFile=`): same write-ban applies wherever bypass values can be sourced.
    - Sanctioned carve-out (615-bats audit, 2026-06-11): `cmd_init` in `bin/antcrate` writes the config ONCE on first run, gated `[[ ! -f config ]]`, and the bootstrap content is commented-out defaults with no active bypass values. That is the only code path allowed to create the file; nothing may ever modify an existing one.

14. **Hook bypass is a logged, single-shot, human-only action.** `antcrate hook bypass <project> --reason "<text>"` writes `.git/antcrate-hook-bypass` — a one-shot flag that the next antcrate-shipped hook reads, logs to both audit sinks, then deletes. Agents MAY propose a bypass (surface the reasoning + the exact command); the human runs the command. Agents MUST NOT call `--hook-bypass` directly, MUST NOT create the `.git/antcrate-hook-bypass` flag file by hand (Write / Edit / `echo >`), and MUST NOT use `git commit --no-verify` to skip a hook. Reusing a stale flag, attempting to suppress the log entry, or wrapping `--hook-bypass` in a script that fires without explicit per-invocation approval are also rule violations.

    **Why:** Hooks exist precisely to catch the "I'll just skip it this once" case. A bypass flag is the sanctioned escape valve, but only when there's a human reason on record (incident, broken hook for an unrelated cause, urgent revert). Letting agents flip the flag programmatically lets them silently disarm the gate that protects the project — which defeats the audit trail the hook+bypass surface was built to produce. Same logic as rule #13 for `~/.antcrate/config`: bypass surfaces are for humans, not for agents.

    **How to apply:**
    - When a hook is blocking and the agent believes a bypass is warranted, the agent surfaces *what's blocking*, *why the bypass is justified*, and the exact command: *"This pre-commit hook is failing on an unrelated issue. Please run `antcrate hook bypass <project> --reason "<text>"` if you want to skip it for the next commit."* Then waits.
    - The agent NEVER runs `antcrate hook bypass` itself, even in an environment where it has permission to execute antcrate commands. The flag's audit invariant — "every bypass is logged with a human's reason" — is meaningful only if the reason is the human's, not the agent's.
    - The agent NEVER uses `git commit --no-verify`, `git push --no-verify`, or any other `--no-verify` variant. That bypasses the hook *without* the audit log entry, which is strictly worse than `--hook-bypass`.
    - If the agent observes a stale `.git/antcrate-hook-bypass` flag (left over from a prior bypass that wasn't consumed), it surfaces the discovery to the human but does NOT delete the flag itself — deletion is also a human-only action (it discards a pending sanctioned bypass).

15. **RETIRED (atticked 2026-07-10).** The Wave-1 compaction-canary gate is gone: harness-level context summaries made compaction-loss a non-threat, and the gate had silently blocked every destructive op on installs without a built `antcrate-core`. Code preserved on the `attic` branch. Historical text follows for the record only. The Wave 1 canary gate (`antcrate-core canary gate-check`, fired from `ac_safety_guard_destructive`) protects rule #1 from context-compaction-induced safety-rule loss. When the gate refuses a destructive op with the framed `COMPACTION CANARY GATE` message, the agent MUST: (a) re-read `~/CLAUDE.md` in full — specifically Write Zones, Rule #1, the Gateway Law; (b) run `antcrate --canary-verify <TOKEN>` with the token from `~/CLAUDE.md` "## Safety Canary" section; (c) re-issue the destructive command. Agents MUST NOT mutate `~/.antcrate/canary/state.json` directly. Agents MUST NOT `unset` or `export ANTCRATE_CANARY_DISABLE=1` outside of CI/test contexts (the env exists only for those). Agents MUST NOT call `antcrate-core canary verify <TOKEN>` to short-circuit the re-read — the re-read is the whole point of the gate.

    **Why:** Long sessions trigger summary-compaction; safety rules get paraphrased away; the next destructive op fires against stale safety context (the Meta OpenClaw inbox-deletion incident is the canonical example). The canary's freshness check (wall-clock TTL + invocation count) is a wrapper-side mechanical proxy for "have you re-read the rules recently?" — bypassing it via env-flipping or direct token verification defeats the gate's only purpose.

    **How to apply:**
    - When you see the framed gate message, treat it as a structural signal that safety context is stale, not as an annoyance. Re-read `~/CLAUDE.md` actually, not performatively.
    - If `~/.antcrate/canary/state.json` is missing on a fresh install, the gate exits 2 (treated as stale). Run `antcrate --canary-init [--with-claudemd]` once at setup.
    - For CI: set `ANTCRATE_CANARY_DISABLE=1` in the CI environment's setup. Bats tests do this by default in `setup()`.

16. **No `rm $VAR` outside `_ac_unlink_internal`.** (Shipped with the quarantine pivot, commit `d83e2ce`; promoted from reserved 2026-06-09 after the audit confirmed enforcement.) User-data destruction routes through `_ac_quarantine_capture` (archive + move, only the user deletes). `_ac_unlink_internal` is THE single audited rm-with-variable site; its allowance covers `$ANTCRATE_HOME`, `.git`-resident AntCrate artifacts, and `antcrate-*`-named scratch under the system temp dir. Prefer remove-by-rename (`mv` to a backup name) over any unlink when the artifact has a natural backup form — see `ac_hook_remove`.

17. _**Reserved** for in-flight Wave 1 (designed 2026-05-29, not yet shipped): no output-suppression (`2>/dev/null` / `>/dev/null`) inherited under `--dry`. This number is claimed by the `--dry` contract; do not reuse._

18. **Registered-project commits and pushes route through `antcrate commit` / `--pp` — never through plugins or bare git.** With the `commit-commands` and `github` Claude Code plugins installed (and `gh` / bare `git` always present), there are now several ways to commit and push. For any project IN THE REGISTRY, the antcrate flags remain the mandatory path: `--commit` carries the secret-pattern guard + Gateway-Law preview/prompt; `--pp` carries push-rejection triage + the in-sync verify; created remotes default to private (see `feedback_private_by_default`). A bare `git commit` / `git push`, the `commit-commands` skill (`/commit`, `/commit-push-pr`), or the `github` plugin's write operations bypass all of that.

    **Why:** the entire value of `--commit` / `--pp` is the guards bolted onto them. A second, ungated commit path silently reintroduces the exact risks those flags exist to prevent — leaked secrets, un-triaged push rejections, accidental public remotes. The plugins are additive capability for everything OUTSIDE the registered set; inside it, the gate is the gate. This is mediation, not domination: antcrate neither wraps nor disables the plugins.

    **How to apply:**
    - Agents (Clyde, Cody) MUST use `antcrate commit <project>` / `antcrate pp <project>` for any registered project. Do NOT invoke the `commit-commands` plugin skills or the `github` plugin's commit/push/merge operations against a registered project's tree.
    - The plugins ARE fine for: trees that are NOT registered AntCrate projects, and read-only GitHub queries (issue/PR/run listing, `repo view`) where no antcrate invariant applies.
    - The durable local backstop is the antcrate pre-commit hook (`--hook-install`, or the opt-in `.githooks/pre-commit`): even if a human drives a commit via a plugin, an installed hook still runs the secret-scan + `--ci`. Keep the hook installed on registered projects so the gate holds regardless of the commit path. Hook bypass stays rule #14 (human-only).

19. **Three fates for "removing" a project — match the fate to the situation; `--deregister` is registry-only and may NOT touch live data.** "Anything that needs to be removed is basically quarantine." The three distinct outcomes:
    - **Deregister → `~/.antcrate/deregistered/<project>/<UTC-ts>/`** (`antcrate deregister <project>`): for a GHOST — a registered entry whose on-disk `path` no longer exists. Drops the stale registry entry ONLY. Capture-first (writes `entry.json` + full `registry.json` + `manifest.json`), then `ac_registry_delete` (atomic, `linked_nodes`-aware). **REFUSES with exit 1 if the path still exists on disk**, redirecting to `--archive` — this is the invariant that stops `--deregister` becoming a backdoor around rule #1 / the Gateway Law. Read-only sibling: `--ghosts` lists all entries whose path is missing. Deregister is deliberately SEPARATE from quarantine so a registry-cleanup is visibly different from data removal.
    - **Quarantine → `~/.antcrate/quarantine/`** (Wave 1, rule #16): actual user-data removal = archive + compress + timestamp + move. Only the user deletes the quarantine root; no `--quarantine-purge`.
    - **Archive → `~/projects/.archive/`** (`antcrate arc`, `_archived` parent in registry): a live-but-retired project, fully recoverable via `--unarchive`. Test-purpose fixtures are archived, never removed.
    Agents pick the fate by inspecting on-disk reality first (`--ghosts`, `find <path>`). When unsure between archive and any removal, default to archive (compress-or-remove default under rule #12).

20. **Builder-role agents load `antcrate-builder`, not `antcrate`.** Cody, Claudia, cody-tester, and any T3 fleet agent get the command-surface-only skill at `assets/skills/builder/` (`antcrate-builder` in the skill menu). Briefing a builder/reviewer agent to load the full `antcrate` orchestrator skill is a rule violation — it spends ~3× the tokens for context the agent must not act on (registry governance, roadmap state, self-host maintenance). The orchestrator (T0) is the only role that loads `antcrate`.

21. **Cost-governance hatches and knobs are human-only; research is cheapest-path-first.** Agents MUST NOT set `ANTCRATE_COST_GUARD_DISABLE` or `ANTCRATE_DUTY_INVOLVEMENT`, and never close duties (`--duty-done` is user-driven, unchanged). Before any model-driven research pass, the agent MUST: (a) check `antcrate --duty-involvement`; (b) try `antcrate fetch <url>` for raw-source questions. At `standard` involvement or above, a research subagent spawned without that check is a rule violation; at `hands-on`, prefer filing `--duty --type research` and asking the user first.

22. **`policy.json` is human territory except one grant.** In `~/.antcrate/anycrate/policy.json`, only `budgets.fable` is agent-adjustable — by the orchestrator (Cable), evidence-backed, with a ledger entry recorded at change time. Every other key (`models`, `classes`, other models' budgets, `skill_overrides`, `budget_usd`) is human-only or goes through `--propose`. Seeding via `--policy-init` is allowed anywhere (idempotent, never clobbers).

23. **Endpoints in `policy.json` are HUMAN-ONLY.** Agents may read `.endpoints` and reference endpoints by name (e.g. `ac_endpoint_run <name>`), but NEVER add, edit, or remove one — file a proposal (`antcrate propose`) instead. Same standing as `~/.antcrate/config` (rule #13) and the intel-sources file (`~/.config/antcrate/intel-sources.json`, human-curated per `antcrate intel pull`): agents get read access, never write access.

24. **Agents MUST NOT set `ANTCRATE_SANDBOX_DISABLE`.** The sandbox around local-inference launches (`ac_sandbox_run`, `ac_endpoint_run`) is a safety boundary, not a convenience. If a launch fails under the sandbox — degraded host, missing `systemd-run`, whatever the cause — report it and stop; do not bypass it. Same class as `ANTCRATE_COST_GUARD_DISABLE` (rule #21) and the other CI-only escape hatches.

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
