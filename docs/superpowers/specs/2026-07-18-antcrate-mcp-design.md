# Design: `antcrate-mcp` — read-only Python MCP server for AntCrate (v1)

**Date:** 2026-07-18
**Status:** Approved design, pending implementation plan
**Home:** new public sibling repo `zeppybabe/antcrate-mcp`, registered as its own
AntCrate project via the wrapper (`antcrate new` / `reg` + `gh-init` — Gateway Law:
no bare `git init`/`gh repo create`). This spec file moves into that repo's
`docs/` at scaffold time; this copy in antcrate-src is the pre-scaffold record.

## Problem

AI agents currently learn AntCrate state by running shell commands inside a
session. That works but hands them an execution surface for what is really a
read query. `antcrate-mcp` provides a strictly narrower channel: structured,
read-only answers over MCP, with **no execution path at all** — the server opens
files, never processes. It extends the Gateway's least-privilege philosophy to
the Model Context Protocol.

## Decision summary (2026-07-18)

| Fork | Decision |
|---|---|
| Repo home | **Separate sibling repo `antcrate-mcp`** — keeps antcrate pure-Bash; standalone Python repo with own CI (fellowship evidence). |
| Data access | **Direct file reads only** — no `subprocess`, no shell-out, ever. Read-only by construction. |
| v1 surface | **Core four:** registry, policy, duties, posts. Intel/backups deferred to v2. |
| Stack | Python 3.11+, official `mcp` SDK (FastMCP), stdio transport, `uv` packaging, `pytest`, `ruff`. |

## Architecture — three small modules (`src/antcrate_mcp/`)

- **`paths.py`** — resolves XDG locations exactly as antcrate's `lib/paths.sh`
  does, honoring the same `ANTCRATE_*` env overrides with the same defaults:
  data `~/.local/share/antcrate` (registry.json), state `~/.local/state/antcrate`
  (anycrate/policy.json, posts/), plus `ANTCRATE_DUTIES_FILE` for the duties
  checklist. It is the single source of truth for *what files may be touched*:
  `confined_read(path)` resolves symlinks and **refuses any path outside the
  allowed roots**, returning a structured error instead. Everything else asks it.
- **`readers.py`** — pure functions, one per surface: `read_registry(path)`,
  `read_policy(path)`, `read_duties(path)`, `read_posts(dir, project)`. Explicit
  paths in, plain dicts out. No MCP imports, no globals — unit-testable against
  fixture files.
- **`server.py`** — FastMCP wiring only: four tools mapping 1:1 onto readers,
  docstrings doubling as the tool descriptions agents see; `main()` runs stdio.

## The four tools

1. `antcrate_registry(project: str | None = None)` — all projects (name, domain,
   path, git_remote) or one project's full record. Unknown project → error
   listing known names.
2. `antcrate_policy()` — endpoints table (name, kind, url) + per-model budgets
   from `anycrate/policy.json`. Policy values only; a credential-shape redaction
   pass (ERE equivalent to antcrate's `AC_POST_SECRET_ERE`) runs over every
   string value as defense-in-depth before return.
3. `antcrate_duties()` — OPEN items parsed from the duties markdown checklist
   (unchecked `- [ ]` boxes, with any `[type]` tags and ISO dates present).
4. `antcrate_posts(project: str)` — X update-log history from
   `posts/<project>.log`: list of {timestamp, handle, range, status, text}.

## Security posture (binding requirements)

- **No execution surface:** the package imports no `subprocess`, `os.system`,
  `pty`, `multiprocessing`, or `ctypes`; a pytest walks the AST of every module
  and fails on any such import or call. File contents are data, never evaluated.
- **Path confinement:** every open goes through `paths.py`; resolved
  (symlink-followed) paths must sit under an allowed root or be refused. A test
  symlinks a fixture registry to `/etc/passwd` and asserts refusal.
- **Human-only files stay human-only:** `~/.config/antcrate/config` and
  `x-accounts.json` are deliberately NOT exposed by any tool (Rule #13 spirit —
  this channel doesn't even read them).
- **No secrets in output:** redaction pass on policy strings; posts/registry
  content is already secret-guarded upstream but passes through the same
  redactor anyway.
- **Failure shape:** missing file → `{"error": ..., "hint": ...}`; malformed
  JSON/markdown → same shape naming the file; never a raw traceback to the client.

## Packaging & CI

- `uv`-managed project: `pyproject.toml` (name `antcrate-mcp`, console script
  `antcrate-mcp = antcrate_mcp.server:main`), `uv.lock` committed, `ruff` config.
- README: what it is, the security posture, Claude Code registration snippet
  (`claude mcp add antcrate -- uv run antcrate-mcp` from the repo dir), and the
  explicit non-goals.
- GitHub Actions: uv sync → ruff check → pytest, matrix ubuntu-latest +
  macos-latest. MIT license, same as antcrate.

## Testing

Pytest with a fake XDG root under `tests/fixtures/` (real-shaped registry.json,
policy.json, duties.md, posts/*.log — shapes copied from live files, values
invented). Required suites: per-reader units (happy + missing + malformed);
path-confinement incl. symlink-escape refusal; the AST no-execution test; one
stdio integration test using the SDK's client to call all four tools end-to-end.

## Non-goals (v1)

Any write/mutate tool · shell-out of any kind · dev/ ledger/state exposure ·
intel/backups surfaces (v2) · HTTP/SSE transport · PyPI publication.

## Resume line this truthfully earns

"Built a Python MCP server exposing AntCrate's registry, policy, and duty state
to AI agents read-only — no subprocess surface, path-confined file access,
enforced by AST-level tests."
