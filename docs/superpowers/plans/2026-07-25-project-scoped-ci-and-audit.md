# Plan — project-scoped ci and per-project audit baselines

_2026-07-25. Owner decisions recorded below. Written for execution in a fresh
session; every anchor is a real file:line as of commit `7cb9171`._

## The complaint

`antcrate ci` and the `audit:` status line are antcrate-only, and silently so.
One device-local baseline file, no project key anywhere:

```json
{"last":{"ts":"…","bats":1024,"sha":"9dac4f0","branch":"master"},
 "baseline":{"ts":"…","bats":871,"sha":"93fd935","branch":"master"}}
```

Working in `rfm-music` shows antcrate's audit progress, which is noise at best
and misleading at worst. Three things are missing: the baseline is not keyed by
project, `ci` cannot resolve which project you are in, and — the real blocker —
**nothing anywhere declares what "ci" means for a non-antcrate project.**

`ac_devops_ci` (`assets/code/lib/devops.sh:432`) hardwires antcrate's shape:

```bash
shellcheck -x "$src"/lib/*.sh "$src/bin/antcrate" "$src/bin/antcrated" "$src/install.sh"
bats "$src/tests/"
```

`rfm-music` is SvelteKit, `antcrate-mcp` is Python, `friendly-cars` is SQL.
There is no universal test command, and the registry holds only `path`,
`parent`, `linked_nodes`, `git_remote` — no place to put one.

## Owner decisions (settled — do not relitigate)

1. **Check commands live in a committed `.antcrate/ci.json` per project**, with
   autodetection as the fallback when the file is absent. Rejected: registry
   metadata (device-local, so ci would be irreproducible on another machine and
   invisible in review).
2. **Scope is ci + audit baseline only.** `antcrate ci [project]`, project
   resolved from cwd or an explicit argument. `self ci` stays as an alias for
   the antcrate project. `self plugin|src|edit|install` stay antcrate-only —
   they manage the antcrate installation itself and do not generalize.
3. **Cadence is per-project and opt-in via `--snapshot`.** No baseline until the
   owner takes one in that project; until then the audit line reports the last
   count and no cadence. Nothing nags about a project you have not opted into.

## The security decision this creates (NEW — read before Task 3)

`.antcrate/ci.json` holds **shell commands that antcrate will execute**. Reading
a committed file out of a repo and running it is a code-execution vector: clone
a hostile repo, run `antcrate ci`, lose. That is exactly the class of thing the
Gateway Law exists to refuse, so it needs a gate before it ships, not after.

Design, consistent with how `antcrate tool install` already pins by sha256 and
how policy endpoints are human-only (AGENTS.md rules 23/24):

- Commands run **only for registered projects**. Registration is a human act.
- **Trust on first use, keyed by content hash.** The first time antcrate sees a
  project's `ci.json` — and on every content change — ci REFUSES, prints the
  commands it would run, and requires an explicit human `antcrate ci <p>
  --trust` that records the sha256. Store trusted hashes in device-local state
  (`$ANTCRATE_STATE_HOME/ci-trust.json`), never in the repo: a repo that could
  vouch for itself is not a gate.
- **Autodetected commands need no trust prompt** — they come from antcrate's own
  table, not from the repo.
- An agent must never run `--trust`. Add it to the human-only list in
  `assets/code/AGENTS.md` alongside the existing rules.

If the executing session disagrees with this gate, stop and raise it with the
owner rather than shipping the feature without one.

## Tasks

Each task is TDD: write the failing test first, run it, confirm it fails for the
stated reason, then implement. Full `antcrate self ci` must pass before each
commit. Commit via the gateway only:
`antcrate commit antcrate -m "…" -- <files>`.

---

### Task 1 — `ac_registry_project_at <path>`: resolve a project from a path

**Why first:** every later task needs it, and the logic already exists twice in
copy-pasted form — `assets/code/hooks/claude/activity-emitter.sh:36` (jq
longest-prefix match) and `gateway-guard.sh`'s `_under_root`. Put one
implementation in `assets/code/lib/registry.sh` and leave the hook copies alone
for now (hooks must stay dependency-free; note it as follow-up, do not refactor
them in this task).

**Contract:** print the project name whose registered `path` is the longest
prefix of the given path; rc 1 and no output if none matches. Longest-prefix
matters — nested registered projects must resolve to the innermost.

**Tests** (`assets/code/tests/registry_project_at.bats`, new):
- exact project root resolves
- a deep subdirectory resolves to its project
- longest prefix wins when one project is nested inside another
- an unrelated path returns rc 1, empty output
- a path that shares a *string* prefix but not a *path* boundary does NOT match
  (`/p/myproj-old` must not resolve to `/p/myproj`) — this is the bug the naive
  `startswith` spelling has
- trailing slashes normalize
- `..` in the input is collapsed before matching (mirror `_normalize` in
  `gateway-guard.sh:99`; lexical only, never `realpath` — registry roots are
  stored unresolved and symlink resolution would make the match disagree)

---

### Task 2 — per-project baselines, with migration

**Files:** `assets/code/lib/devops.sh` — `ac_devops_ci_record` (:381),
`ac_devops_audit_status_line` (:405).

**Note the duplicate definition:** `ANTCRATE_CI_BASELINE` is set in *two* places,
`devops.sh:368` (`$ANTCRATE_HOME/…`) and `paths.sh:41`
(`$ANTCRATE_STATE_HOME/…`). They agree today only because `ANTCRATE_HOME`
aliases the state home. Collapse to one definition as part of this task.

**New shape** — keyed by project, preserving the existing record shape per key:

```json
{"version": 2,
 "projects": {
   "antcrate":  {"last": {…}, "baseline": {…}},
   "rfm-music": {"last": {…}}
 }}
```

**Migration:** a v1 file (top-level `.last`/`.baseline`, no `.version`) is read
as if it were `projects.antcrate`, and rewritten to v2 on the next record. Do
not lose the current `871`/`1024` — that history is the whole point of the
cadence.

**Tests** (extend `assets/code/tests/ci_snapshot.bats`):
- v1 file reads as antcrate's baseline (migration is transparent)
- recording rewrites to v2 preserving the old baseline values exactly
- two projects keep independent `last` and `baseline`
- recording for project A never mutates project B's record
- `--snapshot` sets `.baseline` only for the named project
- a project with no record yet reports "no baseline", not zero
- v2 file is not re-migrated on subsequent reads (idempotent)

---

### Task 3 — check resolution: `.antcrate/ci.json` + autodetect + the trust gate

**New file:** `assets/code/lib/checks.sh`.

**`ac_checks_resolve <project>`** → emits the lint/test/count commands for a
project, from `<path>/.antcrate/ci.json` if present, else autodetection:

| Signal | lint | test | count |
|---|---|---|---|
| `tests/*.bats` + `lib/` + `bin/` | `shellcheck -x lib/*.sh bin/*` | `bats tests/` | `bats --count tests/` |
| `package.json` with a `test` script | package `lint` script if present | `npm test` | — |
| `pytest.ini`/`pyproject.toml` with pytest | — | `pytest` | `pytest --collect-only -q \| wc -l` |
| `Cargo.toml` | `cargo clippy` | `cargo test` | — |
| none of the above | — | — | — → ci reports "no checks defined" and exits 0 with a hint, never a false PASS |

That last row matters: **a project with no checks must not report PASS.** It is
the same defect as the hollow PASS fixed in `9ff7641` — say "nothing to check",
never "checked, fine".

**`ac_checks_trusted <project>`** → the gate from the section above. sha256 of
the `ci.json` bytes compared against `$ANTCRATE_STATE_HOME/ci-trust.json`.

**Tests** (`assets/code/tests/checks_resolve.bats`, new):
- explicit `ci.json` wins over every autodetect signal
- each autodetect row fires on its fixture and only its own
- a project matching no row yields empty commands, and ci then reports "no
  checks defined" rather than PASS
- malformed `ci.json` is a hard error, never a silent fallthrough to autodetect
  (silently downgrading a declared config is how a project stops being checked
  without anyone noticing)
- untrusted `ci.json` refuses, prints the commands, exits non-zero
- changing a trusted `ci.json` by one byte re-arms the refusal
- autodetected commands need no trust record
- a trusted project runs (use a fixture whose "test" command is `true`, and a
  second whose command is `false`, to prove rc propagates)

---

### Task 4 — wire it into the CLI and the status line

`ci` is already a top-level word (`assets/code/bin/antcrate:653` maps it to
`--ci`), so no new verb is needed — it just is not project-aware.

- `antcrate ci [project] [--snapshot] [--trust] [--source <path>]`
  - explicit `<project>` wins
  - else resolve from `$PWD` via Task 1
  - else fall back to the antcrate project, preserving today's bare-`antcrate
    ci` behavior for anyone outside a project tree
- `self ci` → alias for `ci antcrate`. Keep it: it is in the MANUAL, in
  `.github/workflows/ci.yml:42,71`, and in muscle memory.
- **Do not break `--source`.** `ci_toolchain.bats` depends on it, and it is how
  ci is tested against fixture trees.
- The pinned-toolchain PATH prepend and the fail-loud-on-missing-tool behavior
  from `9ff7641` apply to *antcrate's own* checks. For a project whose test
  command is `npm test`, missing-tool detection is that command's job — do not
  try to generalize `ac_devops_ci_missing_tool` across ecosystems.
- `ac_devops_audit_status_line` takes a project argument; `cmd_status` passes
  the cwd-resolved project, falling back to antcrate. When inside a project with
  no baseline, print the opt-in hint naming *that* project.

**Tests** (extend `assets/code/tests/ci_snapshot.bats` + `selfcheck.bats`):
- `ci` inside a project tree resolves that project (assert on the recorded key)
- explicit argument beats cwd
- outside every project tree, falls back to antcrate
- `self ci` still records under antcrate
- `--source` still works and does not consult the registry
- status line renders per project: no-record, record-without-baseline, and
  record-with-baseline including the AUDIT-DUE branch

---

### Task 5 — docs, records, and the audit the owner is about to run

- `docs/MANUAL.md`: rewrite the ci/audit section. State plainly that baselines
  are per project, that cadence is opt-in per project, and document the trust
  gate with the exact refusal message.
- `assets/code/AGENTS.md`: add `ci --trust` to the human-only list next to the
  existing rules 23/24.
- `dev/ledger.md`: an entry covering the decisions, especially the trust gate
  and *why* a repo-supplied command file needs one.
- `dev/state.md`: new top-of-mind block, rolling the prior one per the protocol
  at `dev/state.md:31`.
- Re-baseline once, deliberately, after the suite settles:
  `antcrate ci antcrate --snapshot`. The suite is at **1024** against baseline
  **871**, so the cadence is already DUE — expect it to fire during this work.

## Verification before calling it done

```bash
# from /home/alexk/antcrate-src
ANTCRATE_SELFSRC=/home/alexk/antcrate-src/assets/code \
  assets/code/bin/antcrate self ci        # shellcheck clean + bats all green

cd ~/Projects/rfm-music && antcrate ci    # resolves rfm-music, not antcrate
cd /tmp && antcrate ci                    # falls back to antcrate
```

The installed runtime at `~/.local/share/antcrate/lib/` lags the repo — run
everything through `assets/code/bin/antcrate` directly, or `antcrate self
install` first. This bit the previous session and cost a real debugging detour.

## Explicitly out of scope

- Making `st`, duties or intel project-aware (owner chose scope 2 of 3).
- Refactoring the two copy-pasted prefix matchers in the hooks onto Task 1's
  helper. Hooks stay dependency-free; revisit separately.
- Any CI-server integration. This is the local `ci` verb only.
