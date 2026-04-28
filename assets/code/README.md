# AntCrate

Pure-Bash deterministic project scaffolder. Filenames are arguments. The daemon translates filesystem events into project actions. State lives in one jq-managed JSON file. Git pushes are automated with a fail-safe that emails truncated diffs on rejection.

## Schema

Filenames decode positionally:

```
<Name>.<Domain>.<Action>.<Meta>
  $0      $1       $2      $3
```

`Action` ∈ `start | branch | link | rel`. `Meta` is `#csv,values#` or `key=value`.

### Triggers are equivalent

| Filesystem | CLI |
|---|---|
| `nano coolgif.webapps.start.#html,css,js#` | `antcrate --start coolgif --domain webapps --meta "html,css,js"` |
| `touch derived.proj.branch.from=base` | `antcrate --branch derived --domain proj --meta "from=base"` |

## Install

```bash
./install.sh                 # installs into ~/.local
antcrate --init              # creates ~/.antcrate state dir + config
systemctl --user enable --now antcrated   # optional daemon
```

Edit `~/.antcrate/config` to set `ANTCRATE_EMAIL` and `ANTCRATE_GIT_REMOTE_PREFIX`.

## Layout

```
bin/
  antcrate       Wrapper CLI
  antcrated      Pipe (inotifywait daemon)
lib/
  schema.sh      positional decoder
  registry.sh    atomic jq CRUD on ~/.antcrate/registry.json
  git_triage.sh  automated push + conflict triage
  subbranch.sh   atomic project nesting
  scaffold.sh    action dispatcher (start/branch/link/rel)
  log.sh         leveled logging
  lock.sh        flock + pause-flag helpers
templates/       per-domain scaffolding (webapps, projects, scripts, notes, _generic)
systemd/         antcrated.service
tests/           bats-core suite
install.sh
```

## Conflict triage

On `git push` rejection, AntCrate captures stderr, runs `git diff @{u}..HEAD`, writes the full diff to `/tmp/antcrate_conflict.log`, and emails the first 300 lines via `mailx` (or `sendmail` fallback) with header:

> `AntCrate Auto-Push Failed. Merge conflict detected in <project>. Displaying first 300 lines. Full log saved locally.`

## Sub-branching atomicity

`antcrate --resume <new_parent> --expand <child>` runs:

1. Pause daemon (touch `~/.antcrate/pipe.paused`)
2. `mkdir -p` parent → `mv` child under it (under `flock`)
3. Rewrite `path` and `parent` in registry
4. Rewrite any symlinks across registered projects pointing into old path
5. Resume daemon

Failure at any step still resumes the daemon (RETURN trap).

## Tests

```bash
bats tests/
```

Covers schema decode, registry CRUD, triage flow (mocked git+mailx), scaffold + subbranch atomicity. See `tests/README.md` for coverage gaps that need real hardware.

## Status

v0 — generated 2026-04-26. Awaiting GitHub upload + real-machine audit. Diagram automation (Mermaid/PlantUML/D2/SchemaSpy integration into `start` templates) is **Phase 2**, deferred until v0 is audit-clean.
