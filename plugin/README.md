# antcrate — Claude Code plugin

The harness layer of [AntCrate](https://github.com/zeppybabe/antcrate). AntCrate
already owns the CLI layer (the wrapper), the repo layer (git hooks) and the
read layer (`antcrate-mcp`). This plugin is the fourth: it enforces the Gateway
Law inside Claude Code itself, where the rules previously held only by agent
goodwill.

## Install

```
/plugin marketplace add ~/antcrate-src
/plugin install antcrate@antcrate
```

Public install (once published): `/plugin marketplace add zeppybabe/antcrate`.

**After installing, remove the `local-install-guard.sh` entry from
`~/.claude/settings.json`** — the plugin now supplies it, and leaving both means
an uninstall silently leaves one guard behind.

## What it wires

| Event | Matcher | Hook | Effect |
|---|---|---|---|
| PreToolUse | Bash | `gateway-guard.sh` | Blocks destructive commands in the critical zone and recursive deletes or whole-root moves inside registered projects. Names the sanctioned `antcrate` channel in the block message. |
| PreToolUse | Bash | `env-guard.sh` | Blocks environment dumps and reads of `.env`, private keys, `.netrc`. Assignment and `source` stay allowed — only display sinks are blocked. |
| PreToolUse | Bash | `local-install-guard.sh` | Blocks pipe-to-shell installers. |
| PreToolUse | Read | `env-guard.sh` | Same secret-file rules for the Read tool. |
| PostToolUse | Edit\|Write\|Read\|NotebookEdit | `activity-emitter.sh` | Feeds the live `antcrate watch` view. Never blocks. |
| PostToolUse | Edit\|Write | `shellcheck-on-save.sh` | Lints shell files on save. Never blocks. |
| SessionStart | — | `session-digest.sh` | One line: open duties, unread intel, dirty and unpushed projects. Silent when all three are clean. |

Blocking hooks communicate by exit code: `2` blocks the call and returns stderr
to the model, `0` allows. Every hook fails open — a missing state file or absent
tool skips that check, never stalls the session.

## Known limits

`gateway-guard.sh` is a **token-level classifier**, not a command-semantics
analyzer. It matches argv0 and flag patterns; it does not evaluate what a
command actually does. Known bypass classes (verified live against this
branch — not a regression, the guard is byte-identical to its pre-plugin
state, but worth knowing before you rely on it):

- Indirection: `bash -c 'rm -rf <project>/src'`, `\rm -rf /etc`,
  `command rm -rf …`.
- Equivalent tools the guard doesn't pattern-match: `find … -delete`,
  `find … -exec rm -f {} +`, `git -C … clean -xfd`, `rsync -a --delete`,
  `truncate -s 0`.
- Path normalization: `rm -rf /home/alexk/.local/share/../share/antcrate`
  (no `..` collapsing before the critical-zone check).

Treat the guard as a speed bump against direct, literal destructive
commands — not a sandbox. It does not substitute for backups, review, or the
`antcrate` wrapper's own gates. Hardening these classes is tracked as future
work; see the duty log.

## Not wired by default

`cost-anticipator.sh` and `session-budget-guard.sh` ship in `hooks/claude/` but
are deliberately unwired. Both parse the session transcript and can block tool
calls; a misfire stalls the session's own work. Their matchers differ and must
not be merged into one entry:

- `cost-anticipator.sh` is the *predictive* half — it estimates the cost of an
  expensive call before it runs, so it only needs to see `Skill`, `Agent` and
  `Read` (its own header pins `matcher: Skill|Agent|Read`).
- `session-budget-guard.sh` is the *reactive* half — it gates the whole session
  on context-window health and, once past the hard limit, blocks everything
  except a wrap-up whitelist. Its header pins `matcher: *`, and its body
  `case`-dispatches on `tool_name` across `Read|Grep|Glob`, `Edit|Write|MultiEdit`,
  `Bash`, and a default `*)` branch. Wiring it under `Skill|Agent|Read` instead
  of `*` would mean it never sees `Bash`/`Edit`/`Write` calls — the hard-limit
  gate, the entire point of the hook, would never engage.

To enable, add **two** entries to the `PreToolUse` array in `hooks/hooks.json`:

```json
{
  "matcher": "Skill|Agent|Read",
  "hooks": [
    { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/cost-anticipator.sh" }
  ]
},
{
  "matcher": "*",
  "hooks": [
    { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/session-budget-guard.sh" }
  ]
}
```

A test in `assets/code/tests/plugin_manifest.bats` asserts they are unwired, so
enabling them is a deliberate, reviewable change — update that test too.

## Turning things off

- `ANTCRATE_DIGEST_DISABLE=1` — no session digest.
- `ANTCRATE_DIGEST_GIT=0` — digest skips the git sweep (its only slow part).
- `ANTCRATE_ENV_GUARD_DISABLE=1` — disables the secret guard. Agents must not
  set this; see `AGENTS.md`.

## Hacking

`hooks/claude/` is **generated**. The source of truth is
`assets/code/hooks/claude/` in this same repo. Edit there, then:

```
antcrate self plugin          # regenerate
antcrate self plugin --check  # what CI runs; non-zero on drift
```

`hooks/hooks.json` and `hooks/session-digest.sh` are hand-written and are never
touched by the generator.
