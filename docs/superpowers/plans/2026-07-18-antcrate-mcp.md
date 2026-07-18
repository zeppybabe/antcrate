# `antcrate-mcp` — Read-Only Python MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Python MCP server (`antcrate-mcp`, new private sibling repo) exposing AntCrate's registry, policy, duties, and X-post state to AI agents strictly read-only — no subprocess surface, path-confined file access, enforced by AST-level tests.

**Architecture:** Three modules under `src/antcrate_mcp/`: `paths.py` (XDG resolution mirroring antcrate's `lib/paths.sh`; the only place files are opened, via `confined_read`), `readers.py` (pure functions: paths in, dicts out, credential-shape redaction on every string), `server.py` (FastMCP wiring of four tools + uniform error boundary). Fixture-driven pytest; stdio transport.

**Tech Stack:** Python ≥3.11 (host has 3.12.3), official `mcp` SDK (FastMCP), `uv` packaging, `pytest` + `pytest-asyncio`, `ruff`. Spec: `docs/superpowers/specs/2026-07-18-antcrate-mcp-design.md` (in antcrate-src).

## Global Constraints

- **Gateway Law:** repo creation and pushes go through the wrapper — `antcrate new`, `antcrate commit antcrate-mcp`, `antcrate --gh-init antcrate-mcp` (visibility defaults to **private** — owner chose private), `antcrate pp antcrate-mcp`. Never bare `git init`/`gh repo create`/`git push`.
- **No execution surface:** the package must never import `subprocess`, `pty`, `ctypes`, `multiprocessing`, or `socket`, nor call `eval`/`exec`/`compile`/`os.system`-family. A test enforces this by AST walk.
- **Path confinement:** every file open goes through `paths.confined_read`; symlink-resolved paths must sit under `data_home()`/`state_home()` (or exactly equal the duties file). Human-only files (`~/.config/antcrate/config`, `x-accounts.json`) are never exposed — `config_home` is not an allowed root.
- **Failure shape:** every tool failure returns `{"error": ..., "hint": ...}` — never a traceback. Internal signal is the `ReadRefused` exception.
- **Redaction:** every returned string passes the credential-shape regex (same shapes as antcrate's `AC_POST_SECRET_ERE`) replacing hits with `[redacted: secret-pattern]`.
- **Env overrides honored, same names as `lib/paths.sh`:** `ANTCRATE_DATA_HOME`, `ANTCRATE_STATE_HOME`, `ANTCRATE_HOME` (state alias, wins over `ANTCRATE_STATE_HOME`? — no: paths.sh sets `ANTCRATE_HOME:=$ANTCRATE_STATE_HOME`, so honor `ANTCRATE_HOME` only as the state base when set), `ANTCRATE_REGISTRY`, `ANTCRATE_POSTS_DIR`, `ANTCRATE_DUTIES_FILE`, plus XDG fallbacks.
- **Project-name inputs validated** against `^[A-Za-z0-9._-]+$` before forming any filename (the jq-injection lesson).
- Run all Python commands via `uv run …` from the repo root `/home/alexk/Projects/tools/antcrate-mcp`. Line length 100 (ruff). Commit messages: `feat:`/`test:`/`docs:`/`ci:` prefixes.

---

### Task 1: Scaffold repo via wrapper + Python packaging skeleton

**Files:**
- Create (via wrapper): repo at `/home/alexk/Projects/tools/antcrate-mcp`
- Create: `pyproject.toml`, `src/antcrate_mcp/__init__.py`, `.gitignore`, `docs/2026-07-18-antcrate-mcp-design.md` (copy of spec), `LICENSE` (MIT, copy from `/home/alexk/antcrate-src/LICENSE` with year/name kept)

**Interfaces:**
- Produces: importable empty package `antcrate_mcp`; `uv sync` working; the repo registered in the AntCrate registry as `antcrate-mcp`.

- [ ] **Step 1: Scaffold through the wrapper**

```bash
antcrate new antcrate-mcp --domain tools
antcrate info antcrate-mcp   # confirm registered, path /home/alexk/Projects/tools/antcrate-mcp
```
If `new` errors on the domain form, run `antcrate help --all` and use the documented `new` invocation; do NOT fall back to bare `git init`.

- [ ] **Step 2: Install uv if absent** (owner-approved stack; official installer)

```bash
command -v uv || (curl -LsSf https://astral.sh/uv/install.sh | sh && export PATH="$HOME/.local/bin:$PATH")
uv --version
```

- [ ] **Step 3: Write `pyproject.toml`** at the repo root:

```toml
[project]
name = "antcrate-mcp"
version = "0.1.0"
description = "Read-only MCP server exposing AntCrate registry, policy, duty, and post state to AI agents"
readme = "README.md"
license = { text = "MIT" }
requires-python = ">=3.11"
dependencies = ["mcp>=1.2"]

[project.scripts]
antcrate-mcp = "antcrate_mcp.server:main"

[dependency-groups]
dev = ["pytest>=8", "pytest-asyncio>=0.24", "ruff>=0.6"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/antcrate_mcp"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]

[tool.ruff]
line-length = 100
```

- [ ] **Step 4: Package skeleton + housekeeping**

```bash
mkdir -p src/antcrate_mcp tests docs
printf '"""antcrate-mcp — read-only MCP server for AntCrate state."""\n__version__ = "0.1.0"\n' > src/antcrate_mcp/__init__.py
printf '.venv/\n__pycache__/\n*.egg-info/\n.pytest_cache/\n.ruff_cache/\n' >> .gitignore
cp /home/alexk/antcrate-src/docs/superpowers/specs/2026-07-18-antcrate-mcp-design.md docs/
cp /home/alexk/antcrate-src/LICENSE LICENSE 2>/dev/null || true   # skip if scaffold already made one
printf '# antcrate-mcp\n\nRead-only MCP server for AntCrate state. Full README lands in the final task.\n' > README.md
```

- [ ] **Step 5: Verify the toolchain**

Run: `cd /home/alexk/Projects/tools/antcrate-mcp && uv sync && uv run python -c "import antcrate_mcp; print(antcrate_mcp.__version__)"`
Expected: dependency resolution succeeds, prints `0.1.0`.

- [ ] **Step 6: Commit via wrapper**

```bash
antcrate commit antcrate-mcp -m "feat: scaffold antcrate-mcp package (uv, src layout, spec copy)" --all-tracked
```

---

### Task 2: `paths.py` — XDG resolution + confined reads

**Files:**
- Create: `src/antcrate_mcp/paths.py`
- Test: `tests/test_paths.py`

**Interfaces:**
- Produces (Tasks 3–4 rely on these exact names):
  `ReadRefused(Exception)` with `.error: str`, `.hint: str` ·
  `data_home() -> Path` · `state_home() -> Path` · `registry_file() -> Path` ·
  `policy_file() -> Path` · `posts_dir() -> Path` · `duties_file() -> Path` ·
  `allowed_roots() -> tuple[Path, ...]` ·
  `confined_read(path: Path, extra_allowed: tuple[Path, ...] = ()) -> str`

- [ ] **Step 1: Write the failing tests** — `tests/test_paths.py`:

```python
"""paths.py: XDG resolution parity with lib/paths.sh + read confinement."""
import json
from pathlib import Path

import pytest

from antcrate_mcp import paths
from antcrate_mcp.paths import ReadRefused


@pytest.fixture
def xdg(tmp_path, monkeypatch):
    data = tmp_path / "data" / "antcrate"
    state = tmp_path / "state" / "antcrate"
    data.mkdir(parents=True)
    state.mkdir(parents=True)
    for var in ("ANTCRATE_HOME", "ANTCRATE_REGISTRY", "ANTCRATE_POSTS_DIR",
                "ANTCRATE_DUTIES_FILE", "XDG_DATA_HOME", "XDG_STATE_HOME"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("ANTCRATE_DATA_HOME", str(data))
    monkeypatch.setenv("ANTCRATE_STATE_HOME", str(state))
    return tmp_path


def test_defaults_under_fake_xdg(xdg):
    assert paths.registry_file() == xdg / "data" / "antcrate" / "registry.json"
    assert paths.policy_file() == xdg / "state" / "antcrate" / "anycrate" / "policy.json"
    assert paths.posts_dir() == xdg / "state" / "antcrate" / "posts"


def test_antcrate_home_alias_wins_for_state(xdg, monkeypatch):
    alt = xdg / "legacy-home"
    monkeypatch.setenv("ANTCRATE_HOME", str(alt))
    assert paths.state_home() == alt
    assert paths.policy_file() == alt / "anycrate" / "policy.json"


def test_registry_env_override(xdg, monkeypatch):
    alt = xdg / "data" / "antcrate" / "alt-registry.json"
    monkeypatch.setenv("ANTCRATE_REGISTRY", str(alt))
    assert paths.registry_file() == alt


def test_duties_file_from_registry(xdg):
    repo = xdg / "repos" / "antcrate"
    (repo / "dev").mkdir(parents=True)
    (repo / "dev" / "duties.md").write_text("# d\n")
    reg = {"projects": {"antcrate": {"path": str(repo / "assets" / "code")}}}
    paths.registry_file().write_text(json.dumps(reg))
    assert paths.duties_file() == repo / "dev" / "duties.md"


def test_duties_file_env_override(xdg, monkeypatch):
    monkeypatch.setenv("ANTCRATE_DUTIES_FILE", str(xdg / "elsewhere.md"))
    assert paths.duties_file() == xdg / "elsewhere.md"


def test_duties_file_unresolvable_raises_readrefused(xdg):
    with pytest.raises(ReadRefused) as e:
        paths.duties_file()
    assert "ANTCRATE_DUTIES_FILE" in e.value.hint


def test_confined_read_inside_root(xdg):
    f = paths.data_home() / "registry.json"
    f.write_text("{}")
    assert paths.confined_read(f) == "{}"


def test_confined_read_refuses_outside(xdg, tmp_path):
    outside = tmp_path / "outside.txt"
    outside.write_text("nope")
    with pytest.raises(ReadRefused) as e:
        paths.confined_read(outside)
    assert "refusing" in e.value.error


def test_confined_read_refuses_symlink_escape(xdg, tmp_path):
    target = tmp_path / "victim.txt"
    target.write_text("secret")
    link = paths.data_home() / "registry.json"
    link.symlink_to(target)
    with pytest.raises(ReadRefused):
        paths.confined_read(link)


def test_confined_read_missing_file_readrefused(xdg):
    with pytest.raises(ReadRefused) as e:
        paths.confined_read(paths.data_home() / "absent.json")
    assert "not found" in e.value.error


def test_extra_allowed_exact_file(xdg, tmp_path):
    extra = tmp_path / "duties.md"
    extra.write_text("- [ ] x\n")
    assert paths.confined_read(extra, extra_allowed=(extra,)) == "- [ ] x\n"


def test_config_home_is_not_an_allowed_root(xdg):
    roots = paths.allowed_roots()
    assert all(".config" not in str(r) for r in roots)
```

- [ ] **Step 2: Run to verify failure**

Run: `uv run pytest tests/test_paths.py -q`
Expected: FAIL/ERROR — `paths` has no attributes.

- [ ] **Step 3: Implement `src/antcrate_mcp/paths.py`**

```python
"""XDG path resolution mirroring antcrate's lib/paths.sh.

Single source of truth for which files this server may touch: everything
else calls confined_read(); nothing opens a file directly. config_home is
deliberately NOT an allowed root — human-only files stay human-only.
"""
from __future__ import annotations

import json
import os
from pathlib import Path


class ReadRefused(Exception):
    """A read was refused: confinement violation, missing file, or bad content."""

    def __init__(self, error: str, hint: str = ""):
        super().__init__(error)
        self.error = error
        self.hint = hint


def _xdg(env_specific: str, xdg_var: str, fallback: str) -> Path:
    specific = os.environ.get(env_specific)
    if specific:
        return Path(specific)
    base = os.environ.get(xdg_var)
    if base:
        return Path(base) / "antcrate"
    return Path.home() / fallback / "antcrate"


def data_home() -> Path:
    return _xdg("ANTCRATE_DATA_HOME", "XDG_DATA_HOME", ".local/share")


def state_home() -> Path:
    # lib/paths.sh: ANTCRATE_HOME is the back-compat alias for the state base.
    home = os.environ.get("ANTCRATE_HOME")
    if home:
        return Path(home)
    return _xdg("ANTCRATE_STATE_HOME", "XDG_STATE_HOME", ".local/state")


def registry_file() -> Path:
    override = os.environ.get("ANTCRATE_REGISTRY")
    return Path(override) if override else data_home() / "registry.json"


def policy_file() -> Path:
    # lib/policy.sh: $ANTCRATE_HOME/anycrate/policy.json
    return state_home() / "anycrate" / "policy.json"


def posts_dir() -> Path:
    override = os.environ.get("ANTCRATE_POSTS_DIR")
    return Path(override) if override else state_home() / "posts"


def duties_file() -> Path:
    # lib/duties.sh _ac_duties_file: env override wins; else the antcrate repo
    # root from the registry (strip /assets/code), preferring dev/duties.md.
    override = os.environ.get("ANTCRATE_DUTIES_FILE")
    if override:
        return Path(override)
    reg = registry_file()
    try:
        root = json.loads(reg.read_text(encoding="utf-8"))["projects"]["antcrate"]["path"]
    except Exception as exc:  # noqa: BLE001 - any failure means "cannot resolve"
        raise ReadRefused(
            error="cannot resolve duties file: antcrate project not readable from registry",
            hint=f"set ANTCRATE_DUTIES_FILE, or check {reg}",
        ) from exc
    rootp = Path(root)
    if rootp.name == "code" and rootp.parent.name == "assets":
        rootp = rootp.parent.parent
    dev = rootp / "dev" / "duties.md"
    return dev if dev.exists() else rootp / "duties.md"


def allowed_roots() -> tuple[Path, ...]:
    return (data_home().resolve(), state_home().resolve())


def confined_read(path: Path, extra_allowed: tuple[Path, ...] = ()) -> str:
    """Read text iff the symlink-resolved path sits under an allowed root or
    exactly equals an extra_allowed file (the duties record). Refuse otherwise."""
    resolved = Path(path).resolve()
    ok = any(resolved.is_relative_to(root) for root in allowed_roots()) or any(
        resolved == Path(e).resolve() for e in extra_allowed
    )
    if not ok:
        raise ReadRefused(
            error=f"refusing to read outside AntCrate roots: {resolved}",
            hint="only AntCrate data/state files (plus the duties record) are exposed",
        )
    if not resolved.is_file():
        raise ReadRefused(
            error=f"not found: {path}",
            hint="the corresponding antcrate feature may not have run on this machine yet",
        )
    return resolved.read_text(encoding="utf-8")
```

Symlink-escape note: `Path.resolve()` follows the symlink, so the resolved target lands outside the roots and is refused — that's the mechanism under test.

- [ ] **Step 4: Run tests** — `uv run pytest tests/test_paths.py -q` → 12 passed. Then `uv run ruff check .` → clean.

- [ ] **Step 5: Commit**

```bash
antcrate commit antcrate-mcp -m "feat: XDG path resolution + confined reads (ReadRefused boundary)" --all-tracked
```

---

### Task 3: `readers.py` — pure readers with redaction

**Files:**
- Create: `src/antcrate_mcp/readers.py`, `tests/conftest.py`
- Test: `tests/test_readers.py`

**Interfaces:**
- Consumes: `confined_read`, `ReadRefused` from Task 2.
- Produces (Task 4 relies on): `read_registry(path: Path, project: str | None = None) -> dict` · `read_policy(path: Path) -> dict` · `read_duties(path: Path) -> dict` · `read_posts(posts_dir: Path, project: str) -> dict` · `redact(value)` · `SECRET_RE` · `REDACTED = "[redacted: secret-pattern]"`

- [ ] **Step 1: Write `tests/conftest.py`** (the shared fake XDG world):

```python
"""Fixture: a fake XDG tree with real-shaped AntCrate files, invented values."""
import json

import pytest


@pytest.fixture
def fake_xdg(tmp_path, monkeypatch):
    data = tmp_path / "data" / "antcrate"
    state = tmp_path / "state" / "antcrate"
    (state / "anycrate").mkdir(parents=True)
    (state / "posts").mkdir()
    data.mkdir(parents=True)

    ant = tmp_path / "repos" / "antcrate"
    (ant / "dev").mkdir(parents=True)
    proj = tmp_path / "repos" / "projA"
    proj.mkdir(parents=True)

    (data / "registry.json").write_text(json.dumps({
        "projects": {
            "projA": {"path": str(proj), "domain": "webapps",
                      "git_remote": "git@github.com:owner/projA.git"},
            "antcrate": {"path": str(ant / "assets" / "code"),
                         "domain": "antcrate", "git_remote": ""},
        }
    }))
    (state / "anycrate" / "policy.json").write_text(json.dumps({
        "endpoints": {"local-llama": {"kind": "local", "url": "http://127.0.0.1:8080"}},
        "budgets": {"fable": {"session": 3}},
    }))
    (state / "posts" / "projA.log").write_text(
        "2026-07-17T21:00:00Z\t@antcrate\tstart..abc1234\topened\tfirst post\\nsecond line\n"
        "2026-07-18T09:00:00Z\t@antcrate\tabc1234..def5678\topened\tnewer post\n"
    )
    (ant / "dev" / "duties.md").write_text(
        "# AntCrate — User Duties\n\n"
        "- [x] 2026-07-01 — [command] finished thing (done 2026-07-02)\n"
        "- [ ] 2026-07-12 — [debug] fix the flaky probe\n"
        "- [ ] 2026-07-17 — untyped legacy item\n"
    )

    for var in ("ANTCRATE_HOME", "ANTCRATE_REGISTRY", "ANTCRATE_POSTS_DIR",
                "ANTCRATE_DUTIES_FILE", "XDG_DATA_HOME", "XDG_STATE_HOME"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setenv("ANTCRATE_DATA_HOME", str(data))
    monkeypatch.setenv("ANTCRATE_STATE_HOME", str(state))
    return tmp_path
```

- [ ] **Step 2: Write the failing tests** — `tests/test_readers.py`:

```python
"""readers.py: pure readers, redaction, structured failures."""
import json

import pytest

from antcrate_mcp import paths, readers
from antcrate_mcp.paths import ReadRefused
from antcrate_mcp.readers import REDACTED


def test_registry_list(fake_xdg):
    out = readers.read_registry(paths.registry_file())
    names = [p["name"] for p in out["projects"]]
    assert names == ["antcrate", "projA"]
    proj = next(p for p in out["projects"] if p["name"] == "projA")
    assert proj["domain"] == "webapps"


def test_registry_detail_and_unknown(fake_xdg):
    out = readers.read_registry(paths.registry_file(), "projA")
    assert out["git_remote"].endswith("projA.git")
    with pytest.raises(ReadRefused) as e:
        readers.read_registry(paths.registry_file(), "ghost")
    assert "projA" in e.value.hint


def test_registry_malformed_json(fake_xdg):
    paths.registry_file().write_text("{ not json")
    with pytest.raises(ReadRefused) as e:
        readers.read_registry(paths.registry_file())
    assert "malformed JSON" in e.value.error


def test_policy_endpoints_and_budgets(fake_xdg):
    out = readers.read_policy(paths.policy_file())
    assert out["endpoints"] == [
        {"name": "local-llama", "kind": "local", "url": "http://127.0.0.1:8080"}
    ]
    assert out["budgets"]["fable"]["session"] == 3


def test_policy_redacts_credential_shapes(fake_xdg):
    paths.policy_file().write_text(json.dumps({
        "endpoints": {"bad": {"kind": "api", "url": "https://x.test?api_key=sk-abcdefghij1234567890abcd"}},
        "budgets": {},
    }))
    out = readers.read_policy(paths.policy_file())
    assert "sk-abcdefghij" not in json.dumps(out)
    assert REDACTED in out["endpoints"][0]["url"]


def test_duties_open_items_only(fake_xdg):
    out = readers.read_duties(paths.duties_file())
    assert out["count"] == 2
    assert out["open"][0] == {"date": "2026-07-12", "type": "debug",
                              "text": "fix the flaky probe"}
    assert out["open"][1]["type"] == "policy"  # untyped legacy defaults to policy


def test_posts_newest_first_and_newline_unescape(fake_xdg):
    out = readers.read_posts(paths.posts_dir(), "projA")
    assert out["count"] == 2
    assert out["posts"][0]["text"] == "newer post"
    assert out["posts"][1]["text"] == "first post\nsecond line"
    assert out["posts"][0]["range"] == "abc1234..def5678"


def test_posts_unknown_project_missing_file(fake_xdg):
    with pytest.raises(ReadRefused) as e:
        readers.read_posts(paths.posts_dir(), "nope")
    assert "not found" in e.value.error


def test_posts_rejects_pathy_project_name(fake_xdg):
    with pytest.raises(ReadRefused) as e:
        readers.read_posts(paths.posts_dir(), "../escape")
    assert "invalid project name" in e.value.error
```

- [ ] **Step 3: Run to verify failure** — `uv run pytest tests/test_readers.py -q` → FAIL (no module `readers`).

- [ ] **Step 4: Implement `src/antcrate_mcp/readers.py`**

```python
"""Pure readers: explicit paths in, plain dicts out. No MCP imports, no globals.

Every string returned passes redact() — the same credential shapes as
antcrate's AC_POST_SECRET_ERE (lib/post.sh) — as defense-in-depth.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from .paths import ReadRefused, confined_read

SECRET_RE = re.compile(
    r"AKIA[0-9A-Z]{16}"
    r"|ghp_[A-Za-z0-9]{36}"
    r"|github_pat_[A-Za-z0-9_]{22,}"
    r"|sk-[A-Za-z0-9_-]{20,}"
    r"|xox[baprs]-[A-Za-z0-9-]{10,}"
    r"|AIza[0-9A-Za-z_-]{35}"
    r"|eyJ[A-Za-z0-9_-]+\.eyJ"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|(?i:password)\s*[=:]\s*\S+"
    r"|(?i:api[_-]?key)\s*[=:]\s*\S+"
    r"|(?i:secret)\s*[=:]\s*\S+"
    r"|(?i:token)\s*[=:]\s*\S+"
)
REDACTED = "[redacted: secret-pattern]"

_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

_DUTY_RE = re.compile(
    r"^- \[(?P<done>[ xX])\] (?P<date>\d{4}-\d{2}-\d{2}) — (?:\[(?P<type>\w+)\] )?(?P<text>.+)$"
)


def redact(value):
    """Recursively replace credential-shaped substrings in all string values."""
    if isinstance(value, str):
        return SECRET_RE.sub(REDACTED, value)
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, dict):
        return {k: redact(v) for k, v in value.items()}
    return value


def _check_name(project: str) -> None:
    if not _NAME_RE.match(project):
        raise ReadRefused(
            error=f"invalid project name: {project!r}",
            hint="allowed characters: A-Z a-z 0-9 . _ -",
        )


def _load_json(path: Path) -> dict:
    text = confined_read(path)
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise ReadRefused(
            error=f"malformed JSON in {path}",
            hint=f"line {exc.lineno}: {exc.msg}",
        ) from exc


def read_registry(path: Path, project: str | None = None) -> dict:
    data = _load_json(path).get("projects", {})
    if project is None:
        return redact({
            "projects": [
                {"name": name, "domain": rec.get("domain"),
                 "path": rec.get("path"), "git_remote": rec.get("git_remote")}
                for name, rec in sorted(data.items())
            ]
        })
    if project not in data:
        raise ReadRefused(
            error=f"unknown project: {project}",
            hint="known: " + ", ".join(sorted(data)),
        )
    return redact({"name": project, **data[project]})


def read_policy(path: Path) -> dict:
    data = _load_json(path)
    endpoints = data.get("endpoints") or {}
    return redact({
        "endpoints": [
            {"name": name, "kind": ep.get("kind"), "url": ep.get("url")}
            for name, ep in sorted(endpoints.items())
            if isinstance(ep, dict)
        ],
        "budgets": data.get("budgets") or {},
    })


def read_duties(path: Path) -> dict:
    text = confined_read(path, extra_allowed=(path,))
    open_items = []
    for line in text.splitlines():
        m = _DUTY_RE.match(line.strip())
        if m and m.group("done") == " ":
            open_items.append({
                "date": m.group("date"),
                "type": m.group("type") or "policy",
                "text": m.group("text"),
            })
    return redact({"open": open_items, "count": len(open_items)})


def read_posts(posts_dir: Path, project: str) -> dict:
    _check_name(project)
    text = confined_read(posts_dir / f"{project}.log")
    entries = []
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) == 5:
            ts, handle, commit_range, status, body = fields
            entries.append({
                "timestamp": ts, "handle": handle, "range": commit_range,
                "status": status, "text": body.replace("\\n", "\n"),
            })
    entries.reverse()  # newest first, matching `antcrate post x log`
    return redact({"project": project, "posts": entries, "count": len(entries)})
```

Note on `read_duties`'s `extra_allowed=(path,)`: the duties record legitimately lives outside the XDG roots (in the antcrate repo). The security boundary holds because no MCP tool ever accepts a file path from the client — Task 4 tests that tool signatures contain no path-like parameters.

- [ ] **Step 5: Run tests** — `uv run pytest tests/test_readers.py tests/test_paths.py -q` → 21 passed. `uv run ruff check .` → clean.

- [ ] **Step 6: Commit**

```bash
antcrate commit antcrate-mcp -m "feat: registry/policy/duties/posts readers with credential redaction" --all-tracked
```

---

### Task 4: `server.py` — FastMCP wiring + security tests

**Files:**
- Create: `src/antcrate_mcp/server.py`
- Test: `tests/test_no_execution.py`, `tests/test_server.py`

**Interfaces:**
- Consumes: all Task 2/3 functions by exact name.
- Produces: module-level `mcp` (FastMCP instance named "antcrate"), tools `antcrate_registry`, `antcrate_policy`, `antcrate_duties`, `antcrate_posts`, and `main()` (console entry, stdio).

- [ ] **Step 1: Write the failing security tests** — `tests/test_no_execution.py`:

```python
"""The package must have NO execution surface — enforced at the AST level."""
import ast
import inspect
from pathlib import Path

PKG = Path(__file__).resolve().parent.parent / "src" / "antcrate_mcp"

FORBIDDEN_IMPORTS = {"subprocess", "pty", "ctypes", "multiprocessing", "socket"}
FORBIDDEN_OS_ATTRS = {"system", "popen", "spawnl", "spawnv", "execv", "execve",
                      "execl", "fork", "posix_spawn"}
FORBIDDEN_BUILTINS = {"eval", "exec", "compile"}


def test_no_forbidden_imports_or_calls():
    assert PKG.is_dir()
    for py in sorted(PKG.rglob("*.py")):
        tree = ast.parse(py.read_text(encoding="utf-8"), filename=str(py))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                hit = {a.name.split(".")[0] for a in node.names} & FORBIDDEN_IMPORTS
                assert not hit, f"{py.name}: imports {hit}"
            elif isinstance(node, ast.ImportFrom):
                root = (node.module or "").split(".")[0]
                assert root not in FORBIDDEN_IMPORTS, f"{py.name}: from {node.module}"
            elif isinstance(node, ast.Attribute):
                if isinstance(node.value, ast.Name) and node.value.id == "os":
                    assert node.attr not in FORBIDDEN_OS_ATTRS, f"{py.name}: os.{node.attr}"
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                assert node.func.id not in FORBIDDEN_BUILTINS, f"{py.name}: {node.func.id}()"


def test_tools_expose_no_path_parameters():
    from antcrate_mcp import server
    for tool in (server.antcrate_registry, server.antcrate_policy,
                 server.antcrate_duties, server.antcrate_posts):
        for name in inspect.signature(tool).parameters:
            assert not any(w in name.lower() for w in ("path", "file", "dir")), (
                f"{tool.__name__} exposes path-like parameter {name!r}"
            )
```

- [ ] **Step 2: Write the failing integration test** — `tests/test_server.py`:

```python
"""End-to-end over an in-memory MCP transport: all four tools."""
import json

from mcp.shared.memory import create_connected_server_and_client_session

from antcrate_mcp import server


def _payload(result):
    assert not result.isError, result.content
    return json.loads(result.content[0].text)


async def test_all_four_tools_end_to_end(fake_xdg):
    async with create_connected_server_and_client_session(server.mcp._mcp_server) as s:
        listed = await s.list_tools()
        names = {t.name for t in listed.tools}
        assert names == {"antcrate_registry", "antcrate_policy",
                         "antcrate_duties", "antcrate_posts"}

        reg = _payload(await s.call_tool("antcrate_registry", {}))
        assert [p["name"] for p in reg["projects"]] == ["antcrate", "projA"]

        pol = _payload(await s.call_tool("antcrate_policy", {}))
        assert pol["endpoints"][0]["name"] == "local-llama"

        dut = _payload(await s.call_tool("antcrate_duties", {}))
        assert dut["count"] == 2

        posts = _payload(await s.call_tool("antcrate_posts", {"project": "projA"}))
        assert posts["posts"][0]["text"] == "newer post"


async def test_error_shape_not_traceback(fake_xdg):
    async with create_connected_server_and_client_session(server.mcp._mcp_server) as s:
        out = _payload(await s.call_tool("antcrate_registry", {"project": "ghost"}))
        assert set(out) == {"error", "hint"}
        assert "Traceback" not in json.dumps(out)
```

- [ ] **Step 3: Run to verify failure** — `uv run pytest tests/test_no_execution.py tests/test_server.py -q` → FAIL (no `server` module).

- [ ] **Step 4: Implement `src/antcrate_mcp/server.py`**

```python
"""FastMCP wiring: four read-only tools over the readers. No execution surface."""
from __future__ import annotations

import functools

from mcp.server.fastmcp import FastMCP

from . import paths, readers
from .paths import ReadRefused

mcp = FastMCP(
    "antcrate",
    instructions=(
        "Read-only view of AntCrate project-ops state (registry, policy, duties, "
        "X post log). Nothing here can modify anything; write operations go "
        "through the antcrate CLI's gateway instead."
    ),
)


def guarded(fn):
    """Uniform failure shape {'error', 'hint'} — never a traceback to the client."""

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except ReadRefused as exc:
            return {"error": exc.error, "hint": exc.hint}
        except Exception as exc:  # noqa: BLE001 - tool boundary
            return {"error": f"internal: {exc.__class__.__name__}", "hint": str(exc)}

    return wrapper


@mcp.tool()
@guarded
def antcrate_registry(project: str | None = None) -> dict:
    """List AntCrate projects (name, domain, path, git remote) or one project's record."""
    return readers.read_registry(paths.registry_file(), project)


@mcp.tool()
@guarded
def antcrate_policy() -> dict:
    """AntCrate endpoint policy: inference endpoints (name/kind/url) + model budgets."""
    return readers.read_policy(paths.policy_file())


@mcp.tool()
@guarded
def antcrate_duties() -> dict:
    """Open human-action duties from AntCrate's checklist (date, type, text)."""
    return readers.read_duties(paths.duties_file())


@mcp.tool()
@guarded
def antcrate_posts(project: str) -> dict:
    """X update-post history for a project (newest first) from the append-only log."""
    return readers.read_posts(paths.posts_dir(), project)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
```

If `create_connected_server_and_client_session` or `mcp._mcp_server` isn't found, check the installed SDK version's test helpers (`python -c "import mcp.shared.memory, inspect; print(inspect.getsource(mcp.shared.memory))"`) and adapt the session setup only — the assertions stay identical.

- [ ] **Step 5: Run the full suite** — `uv run pytest -q` → all tests pass (≈25). `uv run ruff check .` → clean. Also smoke the console script starts and exits: `timeout 2 uv run antcrate-mcp < /dev/null; test $? -eq 124 -o $? -eq 0 && echo OK` (a stdio server with closed stdin should exit promptly or idle till timeout — either is fine, no traceback output expected).

- [ ] **Step 6: Commit**

```bash
antcrate commit antcrate-mcp -m "feat: FastMCP server with four read-only tools + AST no-execution tests" --all-tracked
```

---

### Task 5: CI, README, private GitHub repo, push

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md` (full version)

**Interfaces:** none new — closes out v1.

- [ ] **Step 1: CI workflow** — `.github/workflows/ci.yml`:

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v5
      - uses: astral-sh/setup-uv@v5
      - run: uv sync --dev
      - run: uv run ruff check .
      - run: uv run pytest -q
```

- [ ] **Step 2: Full README.md** — sections, written out (not stubs): what it is (one paragraph: read-only MCP channel for AntCrate state, extends the Gateway's least-privilege to MCP); Security posture (no subprocess imports enforced by AST test, path confinement with symlink resolution, human-only configs excluded, credential-shape redaction, uniform error shape); The four tools (table: name, args, returns); Install & register with Claude Code:

````markdown
```bash
git clone <repo> && cd antcrate-mcp && uv sync
claude mcp add antcrate -- uv --directory /path/to/antcrate-mcp run antcrate-mcp
```
````

plus Non-goals (verbatim from the spec) and MIT license line.

- [ ] **Step 3: Verify** — `uv run pytest -q` green, `uv run ruff check .` clean, README renders (no broken fences: `grep -c '```' README.md` is even).

- [ ] **Step 4: Commit, create the private repo, push — all via wrapper**

```bash
antcrate commit antcrate-mcp -m "ci: uv+ruff+pytest matrix; docs: full README" --all-tracked
antcrate --gh-init antcrate-mcp        # default visibility: private (owner's choice)
antcrate pp antcrate-mcp               # push through the panel
```

Confirm afterward: `gh repo view zeppybabe/antcrate-mcp --json visibility -q .visibility` → `PRIVATE`, and CI runs green on the push.

- [ ] **Step 5: Session close-out (orchestrator, not subagent):** ledger + state updates in antcrate-src, memory update, resume-slot reminder to the owner.

---

## Self-Review (done at write time)

- **Spec coverage:** repo home + wrapper scaffold (T1), paths/env parity + confinement + symlink test + config-home exclusion (T2), four readers + redaction + malformed/missing/unknown failure shapes + duties markdown parse + posts parse (T3), FastMCP tools + docstrings + stdio + AST no-execution + no-path-params + in-memory integration + error-shape test (T4), uv/ruff/pytest CI matrix + README with registration snippet + private gh-init + pp (T5). Non-goals untouched. ✓
- **Placeholders:** none — all code and commands are written out; the two conditional instructions (scaffold form, SDK helper location) each name the exact probe command and the invariant to preserve. ✓
- **Type consistency:** `ReadRefused(error, hint)` shape used identically in T2/T3/T4; tool names and reader signatures match across T3/T4; `REDACTED` constant shared. Fixture `fake_xdg` defined once in conftest (T3) and consumed by T4's integration tests. ✓
