# AntCrate — Architecture Blueprint

Source: official spec PDF (v0). Restructured for engineering reference.

## 1. Core Objectives

- **Deterministic Scaffolding** — Translate positional filename extensions directly into directory creation, template generation, and Git initialization commands.
- **Statefulness** — Maintain a lightweight JSON registry that tracks relational links across the file system without requiring a heavy SQL database.
- **Automated Version Control with Fail-Safes** — Handle background Git pushes while guaranteeing zero data loss via an automated email/notification triage system for merge conflicts.
- **Editor Agnosticism** — Allow the system to be triggered identically whether a user invokes the `antcrate` CLI wrapper directly or simply uses standard editors (like nano or helix) via the background file-watcher.

## 2. Terminology & Glossary

| Term | Definition |
|---|---|
| The Wrapper (`antcrate`) | The primary CLI tool executing the logic. |
| The Pipe (Daemon, `antcrated`) | The background `inotifywait` process that monitors the filesystem for specific Positional Extensions and feeds them to the Wrapper. |
| Positional Indexing | Using dot-notation in filenames to map directly to array indices (`Index0.Index1.Index2.Index3`). |
| The State Registry | A hidden mapping file (`~/.antcrate/registry.json`) tracking where projects live and how they are branched. |
| Conflict Triage | The fail-safe protocol that fires when a remote Git push is rejected. |

## 3. The Positional Extension Schema

Every piped file follows a strict, predictable index structure: `[Name].[Domain].[Action].[Meta]`

| Index | Component | Description | Example |
|---|---|---|---|
| 0 | Name | Literal title of the file/project | `testProject`, `coolgifwebapp` |
| 1 | Domain | Target routing directory or category | `projects`, `coolwebapps` |
| 2 | Action | Core command to execute | `start`, `branch`, `link`, `rel` |
| 3 | Meta | Optional modifiers in `#hash#` or `key=value` | `#html,css,js#`, `rel=coolapps` |

### Translation examples

| Trigger | CLI equivalent |
|---|---|
| `nano coolgifwebapp.webapps.start.#html,css#` | `antcrate --start coolgifwebapp --domain webapps --meta "html,css"` |

### Bash array mapping

```
$0 = coolgifwebapp
$1 = webapps
$2 = start
$3 = #html,css#
```

## 4. The State Registry (`registry.json`)

Lightweight JSON map updated upon every successful `--start` or `--branch`. Read/written via `jq` with atomic temp-file replacement.

```json
{
  "projects": {
    "coolphotowebapp": {
      "path": "/home/twntydotsix/projects/coolwebapps/coolphotowebapp",
      "parent": "coolwebapps",
      "linked_nodes": ["coolgifwebapp"],
      "git_remote": "git@github.com:user/coolphoto.git"
    },
    "coolgifwebapp": {
      "path": "/home/twntydotsix/projects/coolwebapps/coolgifwebapp",
      "parent": "coolwebapps",
      "linked_nodes": ["coolphotowebapp"],
      "git_remote": "git@github.com:user/coolgif.git"
    }
  }
}
```

## 5. Git Fail-Safe & Triage Protocol

When `antcrate --pp <project> -y` runs, stderr from `git push` is captured. On rejection (diverged branches, conflicts), the fail-safe engages.

### Logic flow

1. **Halt Execution** — Abort the automated `git push` immediately to prevent overwriting.
2. **Generate Diff** — Run `git diff` against the remote branch to capture exactly what is conflicting.
3. **Truncate & Notify**:
   - Store full diff at `/tmp/antcrate_conflict.log`.
   - Capture first 300 lines of the diff.
   - Prepend header: `"AntCrate Auto-Push Failed. Merge conflict detected in [Project]. Displaying first 300 lines. Full log saved locally."`
4. **Dispatch** — Send truncated log via `mailx` (or `sendmail` fallback) to the developer's configured email address.

## 6. Sub-Branching / Refactoring Logic

Command: `antcrate --resume coolwebapps --expand coolphotowebapp`

Atomic execution sequence:

1. **Pause the Pipe** — Temporarily halt `inotifywait` daemon so it doesn't try to sort directories while they're moving.
2. **Update Filesystem** — `mkdir -p ~/projects/coolwebapps` → `mv ~/projects/coolphotowebapp ~/projects/coolwebapps/`
3. **Update Registry** — Rewrite `path` and `parent` keys for the project in `registry.json`.
4. **Update Relational Links** — If any `.env.[project].secret` files exist, update their symlinks or paths based on the new registry coordinates.
5. **Resume the Pipe** — Restart the `inotifywait` daemon.

## 7. Implementation invariants (engineering additions)

These are not in the original PDF but are required for the v0 implementation to be safe:

- **Wrapper/daemon coordination via `flock`** — both processes hold an advisory lock on `~/.antcrate/daemon.lock` during state-mutating sections to prevent registry races.
- **Editor swap-file ignore rules** — daemon ignores filenames matching: starts with `.`, ends with `~`, contains `.swp` / `.swo` / `.swx`, ends with `.tmp`.
- **Debounce** — daemon waits for `close_write` after `create` before acting; if a `create` is followed by another `create` on the same basename within 200ms, the first is dropped (editor temp-file pattern).
- **Atomic registry writes** — never edit `registry.json` in place. Always: `jq … registry.json > registry.json.tmp && mv registry.json.tmp registry.json`.
- **Idempotent `--start`** — re-running `--start foo --domain bar` on an existing project is a no-op + log warning, not a destructive overwrite.
