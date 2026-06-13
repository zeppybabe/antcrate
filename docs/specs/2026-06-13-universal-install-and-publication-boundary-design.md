# Design: Universal Linux Install + XDG Layout + Publication Boundary

- **Date:** 2026-06-13
- **Status:** Approved (brainstorming) — pending implementation plan
- **Author:** zeppybabe (with Claude Code)
- **Scope:** four independently-shippable sub-projects, sequenced 1 → 2 → 3 → 4

## Context

AntCrate currently installs to a mix of locations: code under `~/.local/{bin,share/antcrate}`,
but config + all runtime state under a single `~/.antcrate/`, and projects default to
`~/projects`. The installer copies files correctly but never (a) registers the dev tree as
the `antcrate` project nor (b) creates the `~/.claude/skills/antcrate` link — both required by
`antcrate --selfcheck`, so a fresh install reports `selfsrc: FAIL (2 critical)` and looks broken.
Separately, the public repo ships dev-internal records (`ledger.md`, `state-archive.md`,
`docs/plans/`, …) that contain dev-team home paths (e.g. `/home/twntydotsix`) and internal
chatter.

Two fixes already landed on the development machine ahead of this spec:

- `lib/selfcheck.sh:97` — appended `|| true` to the backup-freshness `find`. Under the wrapper's
  `set -euo pipefail`, a missing backup dir (the fresh-install state) made `find` exit 1 and
  aborted the whole `--selfcheck` run *before printing its report* — the reason the failure was
  invisible. Direct `antcrate --selfcheck` now prints and exits 2 (warnings only).
- `install.sh` — now self-registers the `antcrate` project (git-root detected by walking up from
  `SRC`) and creates the `~/.claude/skills/antcrate` symlink idempotently.

This spec covers the remaining hardening so a clean clone installs error-free for any Linux user,
and so the public repo never leaks dev-internal content.

## Decisions (locked during brainstorming)

| Topic | Decision |
|-------|----------|
| Directory model | Full XDG split |
| Existing `~/.antcrate` upgrade | Auto-migrate, idempotent, once |
| Leak-scan scope | Scan working tree **and** full git history; rewrite history only if genuine credentials found |
| Public/dev separation | Single repo; dev records moved to `dev/` and git-excluded from the public remote |
| Boundary enforcement | `pre-push` guard (extends existing secret guard) + GitHub Actions CI backstop |
| Projects root | `~/Projects` (capital P) |

## Sub-project 1 — XDG path layout (foundational; blocks #2)

### Target layout

```
~/.config/antcrate/        config, config.example          ($XDG_CONFIG_HOME)
~/.local/share/antcrate/   lib, templates, hooks, registry.json, intel/   ($XDG_DATA_HOME)
~/.local/state/antcrate/   log/, backups/, events/, locks, proposals.log,
                           ci-baseline.json, cleanup/, fetch/, daemon.lock ($XDG_STATE_HOME)
~/Projects/                project trees
```

### Architecture

Introduce one module **`lib/paths.sh`**, sourced first by both `bin/antcrate` and `bin/antcrated`
(before `log.sh`/`lock.sh`), establishing three base dirs that honor env overrides with XDG
fallbacks:

```sh
: "${ANTCRATE_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/antcrate}"
: "${ANTCRATE_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/antcrate}"
: "${ANTCRATE_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/antcrate}"
: "${ANTCRATE_ROOT:=$HOME/Projects}"
```

Derived `ANTCRATE_*` variables repoint by category:

- **config_home:** `ANTCRATE_CONFIG` (the `config` file)
- **data_home:** `ANTCRATE_REGISTRY`, `ANTCRATE_TEMPLATES`, `ANTCRATE_INTEL_DIR`
- **state_home:** `ANTCRATE_LOG_DIR`, `ANTCRATE_BACKUP_DIR`, `ANTCRATE_EVENTS_DIR`,
  `ANTCRATE_LOCK`, `ANTCRATE_PROPOSALS_LOG`, `ANTCRATE_CI_BASELINE`, `ANTCRATE_CLEANUP_DIR`,
  `ANTCRATE_FETCH_DIR`

The legacy `ANTCRATE_HOME` variable is retained as an alias pointing at `ANTCRATE_STATE_HOME`
for any third-party reference, but the codebase stops deriving new paths from it.

### Per-file `:=` defaults

The `: "${VAR:=default}"` idiom in each of the ~31 files is kept (so a lib sourced standalone in
a bats test still resolves), but each default is rewritten to derive from the new bases instead of
`$HOME/.antcrate`. Where a lib is sourced before `paths.sh` could run (none expected, but
`log.sh`/`lock.sh` are early), the lib carries a self-contained XDG fallback identical to
`paths.sh`.

### Migration shim (installer-run, idempotent)

```sh
if [ -d "$HOME/.antcrate" ] && [ ! -e "$HOME/.antcrate/MIGRATED" ]; then
    mkdir -p "$ANTCRATE_CONFIG_HOME" "$ANTCRATE_DATA_HOME" "$ANTCRATE_STATE_HOME"
    [ -f "$HOME/.antcrate/config" ]        && mv -n "$HOME/.antcrate/config"        "$ANTCRATE_CONFIG_HOME/config"
    [ -f "$HOME/.antcrate/registry.json" ] && mv -n "$HOME/.antcrate/registry.json" "$ANTCRATE_DATA_HOME/registry.json"
    [ -d "$HOME/.antcrate/intel" ]         && mv -n "$HOME/.antcrate/intel"         "$ANTCRATE_DATA_HOME/intel"
    for d in log backups events cleanup fetch; do
        [ -e "$HOME/.antcrate/$d" ] && mv -n "$HOME/.antcrate/$d" "$ANTCRATE_STATE_HOME/$d"
    done
    date -u +%FT%TZ > "$HOME/.antcrate/MIGRATED"   # breadcrumb; original dir left in place, now empty-ish
fi
```

`mv -n` never clobbers; the breadcrumb makes re-runs no-ops. The empty legacy dir is left for the
user to remove (we never delete a user data dir automatically).

## Sub-project 2 — Universal Linux install

- **Dependency preflight** in `install.sh`: required `jq`, `git`, `inotifywait` (from
  `inotify-tools`); optional-dev `bats`, `shellcheck`. On a miss, print the exact install line for
  the detected package manager (`apt-get` / `dnf` / `pacman`) and exit non-zero with a clear
  message — never a cryptic mid-script failure.
- **XDG dirs + migration shim** wired into `install.sh` (from sub-project 1).
- Keep the already-added self-register + skill-link steps; ensure every step is idempotent.
- **README** quickstart rewritten to match: clone target, `~/Projects`, XDG note, the dependency
  line, and the corrected post-install expectation (`--status` shows `selfsrc: OK-WITH-WARNINGS`
  on a fresh install, not `FAIL`).
- **Clean-machine proof:** run the installer under a throwaway `HOME=$(mktemp -d)` and assert
  `antcrate --selfcheck` exits 0/2 (not 1) and `--status` is clean, before claiming success.

## Sub-project 3 — Repo leak scan + remediation

- Install `gitleaks`. Scan **working tree** and **full git history** (`gitleaks detect` +
  `gitleaks detect --no-git` for the tree).
- **Triage:**
  - Genuine credentials (tokens, keys) → purge from history with `git-filter-repo`, then
    force-push. Rotate any real exposed secret.
  - Dev paths / usernames (`/home/twntydotsix`, etc.) → fix-forward in the working tree; no
    history rewrite.
  - Example emails (`bjoern@hoehrmann.de`, `evan@nemerson.com`, `*@example.com`) → confirmed as
    vendored-lib/license attribution and test fixtures before any action; expected to be benign.
- Produce a short findings report (file, kind, verdict) committed under `dev/` (not public).

## Sub-project 4 — Publication boundary + enforcement

### Separation

Move dev-internal records into a `dev/` tree, git-excluded from the public remote:

```
public:  assets/ docs/MANUAL.md README.md SKILL.md LICENSE SECURITY.md
         CONTRIBUTING.md stack.md templates/
dev/  :  ledger.md state.md state-archive.md duties.md composes.md
         docs/plans/ docs/specs/   (incl. this spec)
```

Each root `.md` is reviewed individually before moving — `SKILL.md`, `stack.md`, `README.md`,
`LICENSE`, `SECURITY.md`, `CONTRIBUTING.md` are the tool's public interface and stay. `.gitignore`
gains `dev/` plus the moved paths.

### Enforcement (defense in depth)

- **`pre-push` guard** extending AntCrate's existing secret-pattern guard: refuses any push to the
  public remote whose staged/pushed content includes `dev/`-class paths or matches secret
  patterns. Reason-required bypass routes through the existing `--hook-bypass` (dual audit-logged).
- **CI backstop:** a GitHub Actions workflow that fails a PR if forbidden content (dev paths,
  secret patterns) is present — catches anything that skipped local hooks.

## Testing

- `bats` suites for `paths.sh` resolution (XDG overrides, fallbacks) and the migration shim
  (idempotency, `mv -n` safety, breadcrumb).
- Clean-`HOME` install smoke test (sub-project 2).
- `gitleaks` clean exit on the public surface (sub-project 3/4).
- `pre-push` guard unit test: a staged `dev/` path is rejected; a clean push passes;
  `--hook-bypass` overrides with audit entry.
- Full existing `bats` regression run after the path refactor (requires `bats` + `shellcheck`
  installed — see sub-project 2 preflight).

## Sequencing & boundaries

1. **Layout** — `paths.sh`, per-file default rewrites, migration shim. Independently testable.
2. **Install** — depends on 1; preflight + README + clean-machine proof.
3. **Scan** — independent; informs 4.
4. **Boundary** — depends on 3's findings; `dev/` move, `.gitignore`, `pre-push` guard, CI.

Each sub-project is committed independently via the Gateway Law (`antcrate --commit`).

## Out of scope (YAGNI)

- macOS / Windows install paths (Linux-only for now).
- Packaging (deb/rpm/AUR) — source install only.
- Migrating away from the `:=`-per-file idiom wholesale (kept for test-sourcing).
