# Fix 3 AGENTS-rule violations (gh.sh + cmd_pp) — Design Spec

- **Date:** 2026-06-01
- **Status:** Approved (design); pending plan + implementation
- **Author:** Clyde (orchestrator) + user
- **Source:** `agents-rule-auditor` findings during the 2026-06-01 live `/session-close` run.
- **Scope:** Resolve three AGENTS hard-rule violations by fixing one shared root cause; delegate implementation (Cody build → Claudia review → Clyde verify).

## Problem

The `agents-rule-auditor` flagged three real violations in pre-existing code:

| Site | Rule | Violation |
|---|---|---|
| `lib/git_triage.sh:54` (root) | — | `ac_git_push` documented "Operates in `$PWD`; caller is expected to `cd`" |
| `bin/antcrate:301` `cmd_pp` | #10 | bare non-subshell `cd "$p"` into a registered project path |
| `lib/gh.sh:36` `ac_gh_init_repo` | #10 | bare non-subshell `cd "$path"` into a registered project path |
| `lib/gh.sh:69` `ac_gh_init_repo` | #12 | bare `git push -u origin "$branch"` bypassing `ac_git_push` triage |

These are interlinked. `ac_git_push` operates on `$PWD`, forcing every caller to `cd`
first (the two #10 sites). And because `ac_git_push` only does a plain `git push` with
no upstream-setting, gh.sh's *initial* push cannot use it and hand-rolls a bare
`git push -u origin` (the #12 site). Fix the root and all three resolve.

## Guiding principles (from the user)

1. **Per-project versatility via explicit path** — functions should operate on an
   explicit per-project path (a `local` variable), not implicit cwd. → `git -C "$path"`.
2. **Gateway Law: no command without intent** — gh.sh's bare push must route *through*
   `ac_git_push`'s triage (the sanctioned push channel), not bypass it.

## Decisions (locked)

| Decision | Choice |
|---|---|
| cd-elimination strategy | **`git -C "$path"` everywhere** — no `cd`, path passed explicitly |
| Initial-push handling | **Upstream-auto-set** — `ac_git_push` detects a missing `@{u}` and pushes `-u origin <branch>`; no new flag. Closes the `git-push-initial-mode` proposal |
| `gh.sh` test coverage | **shellcheck + review only** (no bats — gh needs auth/network; pre-existing gap, not introduced here) |
| Minor disable findings | **Out of scope** (`subbranch.sh:70`, `watch.sh:267`) — separate pass |
| Implementation | Delegated: Cody (Sonnet, foreground) test-first → Claudia (Sonnet, foreground) review → Clyde verify + `--ci` + commit + `--pp` |

## Design

### Unit 1 — `ac_git_push` becomes path-explicit + upstream-aware (`lib/git_triage.sh`)

- New signature: `ac_git_push <project> [path]`. `path` defaults to `$PWD` so the
  refactor is non-breaking at every step.
- Every internal git invocation uses `git -C "$path"`: the `git push`, the post-push
  remote-sync verify rev-parses, the branch rev-parse, and the triage `git diff`.
- **Upstream-auto-set:** before pushing, resolve `git -C "$path" rev-parse --abbrev-ref
  --symbolic-full-name '@{u}'`. If empty (no upstream), the push is
  `git -C "$path" push -u origin "$(current-branch)"`; otherwise `git -C "$path" push`.
  **Both forms capture stderr and route a non-zero exit through the existing triage**
  (conflict log + `ac_triage_dispatch`) unchanged.
- Remove the "caller is expected to cd into the project dir" comment; document the
  `path` parameter instead.

### Unit 2 — `cmd_pp` (`bin/antcrate`)

- Drop `cd "$p"`. Use `git -C "$p" status --porcelain`, `git -C "$p" add -A`,
  `git -C "$p" commit …`, then `ac_git_push "$project" "$p"`.

### Unit 3 — `ac_gh_init_repo` (`lib/gh.sh`)

- Drop `cd "$path"`. Use `git -C "$path"` for `init`, `add`, `commit`, `remote add`,
  `rev-parse`.
- Change `gh repo create … --source=.` → `--source "$path"` so the gh-driven create+push
  no longer depends on cwd.
- Replace the bare `git push -u origin "$branch"` with `ac_git_push "$project" "$path"`.
  Upstream-auto-set handles the first-push upstream; triage now engages on rejection
  (previously a bare `ac_warn` + `return 1`).

## Testing

`tests/git_triage.bats` (git is mocked via a PATH shim keyed on `$1`):

- **Fixture update (required):** the fake `git` switches on `$1`. With `git -C <path> <sub>`,
  `$1` becomes `-C`. Teach the shim to shift past `-C <path>` before matching the
  subcommand (push/rev-parse/diff). Without this every existing case breaks.
- Keep all existing cases green (success-push, rejected-push-triage, email dispatch).
- **Add:** (a) path-explicit push — `ac_git_push proj /some/path` runs with no `cd` and
  the fake git receives `-C /some/path push`; (b) no-upstream branch — `rev-parse @{u}`
  empty → push command includes `-u origin <branch>`; (c) rejection with upstream-set
  still writes the conflict log and dispatches triage.

`lib/gh.sh`: shellcheck-clean + Claudia review; its push path is covered transitively by
the Unit 1 tests. No new bats (pre-existing coverage gap).

Full `bash bin/antcrate --ci` must pass (shellcheck + cmake/ctest + all bats) before and
after.

## Risks

- **Fake-git shim breakage** — the `-C` prefix is the single highest-risk detail; called
  out explicitly above and covered test-first.
- **Other `ac_git_push` callers** — audited: only `cmd_pp` (bin/antcrate:310) calls it
  today. Default `path=$PWD` keeps it safe even if a caller is missed.
- **Live gateway-guard during build** — Cody's bats runs use local fixtures/mocked git,
  not real pushes, so the live PreToolUse guard won't block them. Real `--pp` happens only
  at the end, by Clyde, through the sanctioned channel.

## Implementation order

1. `git_triage.bats` fixture + new cases (RED).
2. `ac_git_push` refactor (GREEN).
3. `cmd_pp` update.
4. `ac_gh_init_repo` update.
5. shellcheck + `--ci`.
6. Clyde independent verify → commit boundary → `--pp`.
