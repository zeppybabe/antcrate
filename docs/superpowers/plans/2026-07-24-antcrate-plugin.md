# AntCrate Claude Code Plugin (enforcement core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Claude Code plugin that loads AntCrate's five perimeter hooks as one versioned, testable unit, and fix the stub-registry defect that currently makes those hooks guard nothing.

**Architecture:** `assets/code/hooks/claude/` stays the source of truth for hook scripts. A new `antcrate self plugin` build step copies them into a committed `plugin/` tree alongside a hand-written `hooks/hooks.json` wiring file and a new `session-digest.sh`. `self ci` gains a drift test that fails when copy and source diverge. Nothing about the hooks' exit-code contract changes.

**Tech Stack:** Bash 5 (`set -uo pipefail`, no `set -e` in guards), `jq` for all JSON, `bats` for tests, `shellcheck` clean. No new dependencies.

## Global Constraints

- **Repo:** `~/antcrate-src` (symlinked as `~/.claude/skills/antcrate`), branch `master`.
- **Gateway Law:** never `git commit`/`git push`/`mv`/`rm` directly on a registered project. Commit with `antcrate commit antcrate -m "<msg>" -- <files...>` (the wrapper refuses a commit with no `--all-tracked` or explicit file list). Push only with `antcrate pp antcrate`, and only when the owner asks.
- **Hook contract, unchanged:** exit `2` blocks the tool call and feeds stderr back to the model; exit `0` allows. Guards never use `set -e` — each must exit with its own computed code.
- **Fail-open rule:** every hook degrades to "that check is skipped", never to an error or a hung session. Unreadable state file, missing `jq`, absent `git` → exit 0.
- **`plugin/hooks/claude/` is generated output.** Never hand-edit a file there. Edit `assets/code/hooks/claude/` and re-run the generator.
- **Registry path, canonical order** (copied verbatim from the spec, used identically in Task 1 and Task 2):
  `ANTCRATE_REGISTRY` → `${ANTCRATE_DATA_HOME}/registry.json` → `${XDG_DATA_HOME:-$HOME/.local/share}/antcrate/registry.json` → `$HOME/.antcrate/registry.json` (legacy, last).
- **Test invocation:** `cd ~/antcrate-src/assets/code && bats tests/<file>.bats` for one file; `antcrate self ci` for the full suite plus shellcheck. Current baseline is 905 passing tests — the suite must only grow.
- **Records:** `dev/ledger.md` and `dev/state-archive.md` are append-only, newest first. `dev/state.md` is rewritten freely but rolling — keep current + prior session block only.

---

### Task 1: Fix registry and control-plane path resolution in the hooks

The guards resolve the registry as `${ANTCRATE_HOME:-$HOME/.antcrate}/registry.json`. That file is a post-migration stub containing `{"projects":{}}`, so every registry-dependent rule in `gateway-guard.sh` currently falls open. `zones_control_plane` has the same legacy assumption, so the control plane's own critical-zone protection points at a directory that no longer holds anything.

**Files:**
- Modify: `assets/code/hooks/claude/_zones.sh:11-19` (`zones_control_plane`, `_zones_registry`)
- Modify: `assets/code/hooks/claude/activity-emitter.sh:16` (duplicate legacy default)
- Test: `assets/code/tests/zones_paths.bats` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `_zones_registry()` → prints one absolute path to stdout, always exits 0. `zones_control_plane()` → prints one or more absolute directory paths, one per line (it becomes multi-line in this task; `gateway-guard.sh` already consumes it in a `while read` loop, so no caller change is needed — verify this in Step 5).

- [ ] **Step 1: Write the failing test**

Create `assets/code/tests/zones_paths.bats`:

```bash
#!/usr/bin/env bats
# tests for hooks/claude/_zones.sh path resolution (XDG vs legacy ~/.antcrate)

setup() {
    ZONES="$BATS_TEST_DIRNAME/../hooks/claude/_zones.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.antcrate" "$HOME/.local/share/antcrate" "$HOME/.local/state/antcrate"
    # legacy stub — exactly what the real machine has post-migration
    printf '{"projects":{}}\n' > "$HOME/.antcrate/registry.json"
    # live registry with one project
    jq -n '{projects:{live:{path:"/tmp/live",parent:"x",linked_nodes:[],git_remote:""}}}' \
        > "$HOME/.local/share/antcrate/registry.json"
    unset ANTCRATE_REGISTRY ANTCRATE_HOME ANTCRATE_DATA_HOME XDG_DATA_HOME
}

zsrc() { bash -c '. "'"$ZONES"'"; '"$1"; }

@test "registry: XDG data path wins over the legacy stub" {
    run zsrc '_zones_registry'
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.local/share/antcrate/registry.json" ]
}

@test "registry: registered roots come from the XDG registry, not the stub" {
    run zsrc 'zones_registered_roots'
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/live" ]
}

@test "registry: ANTCRATE_REGISTRY overrides everything" {
    export ANTCRATE_REGISTRY="$BATS_TEST_TMPDIR/custom.json"
    run zsrc '_zones_registry'
    [ "$output" = "$BATS_TEST_TMPDIR/custom.json" ]
}

@test "registry: ANTCRATE_DATA_HOME is honored ahead of XDG_DATA_HOME" {
    export ANTCRATE_DATA_HOME="$BATS_TEST_TMPDIR/dh"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg"
    run zsrc '_zones_registry'
    [ "$output" = "$BATS_TEST_TMPDIR/dh/registry.json" ]
}

@test "registry: XDG_DATA_HOME is honored when ANTCRATE_DATA_HOME is unset" {
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg"
    mkdir -p "$BATS_TEST_TMPDIR/xdg/antcrate"
    printf '{"projects":{}}\n' > "$BATS_TEST_TMPDIR/xdg/antcrate/registry.json"
    run zsrc '_zones_registry'
    [ "$output" = "$BATS_TEST_TMPDIR/xdg/antcrate/registry.json" ]
}

@test "registry: falls back to legacy when no XDG registry exists" {
    rm -f "$HOME/.local/share/antcrate/registry.json"
    run zsrc '_zones_registry'
    [ "$output" = "$HOME/.antcrate/registry.json" ]
}

@test "control plane: covers state, data and config homes" {
    run zsrc 'zones_control_plane'
    [[ "$output" == *"$HOME/.local/state/antcrate"* ]]
    [[ "$output" == *"$HOME/.local/share/antcrate"* ]]
    [[ "$output" == *"$HOME/.config/antcrate"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/antcrate-src/assets/code && bats tests/zones_paths.bats`
Expected: FAIL. The first test reports the legacy `$HOME/.antcrate/registry.json`; `zones_registered_roots` prints nothing (the stub has no projects); the control-plane test finds only `.antcrate`.

- [ ] **Step 3: Write the implementation**

In `assets/code/hooks/claude/_zones.sh`, replace the two functions at lines 11-19:

```bash
# XDG homes, resolved exactly as lib/paths.sh does. Kept as a private helper so
# the control plane and the registry cannot drift apart again.
_zones_data_home() {
    printf '%s\n' "${ANTCRATE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/antcrate}"
}
_zones_state_home() {
    printf '%s\n' "${ANTCRATE_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/antcrate}"
}
_zones_config_home() {
    printf '%s\n' "${ANTCRATE_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/antcrate}"
}

# Control-plane roots — themselves critical (hard-blocked). One per line.
# Covers state (daemon lock, backups, policy), data (registry, intel,
# templates), config (rule #13 human-only file), and the legacy pre-XDG home
# which may still hold a stub or logs.
zones_control_plane() {
    _zones_state_home
    _zones_data_home
    _zones_config_home
    printf '%s\n' "${ANTCRATE_HOME:-$HOME/.antcrate}"
}

# Registry file path. Resolution order matches lib/paths.sh:30 —
# ANTCRATE_REGISTRY, then the data home, then legacy ~/.antcrate as a last
# resort. ANTCRATE_HOME means the STATE home and is never consulted for the
# registry: conflating the two is what made this guard read a stub.
_zones_registry() {
    if [ -n "${ANTCRATE_REGISTRY:-}" ]; then
        printf '%s\n' "$ANTCRATE_REGISTRY"; return 0
    fi
    local xdg legacy
    xdg="$(_zones_data_home)/registry.json"
    legacy="$HOME/.antcrate/registry.json"
    if [ -r "$xdg" ] || [ ! -r "$legacy" ]; then
        printf '%s\n' "$xdg"
    else
        printf '%s\n' "$legacy"
    fi
}
```

Also update the header comment on line 8-9 — it currently claims "In production both default to `~/.antcrate`", which is now false:

```bash
# Env-aware so fixture tests can point ANTCRATE_HOME / ANTCRATE_REGISTRY at a
# tmpdir. In production the registry resolves under the XDG data home
# (~/.local/share/antcrate), with the pre-migration ~/.antcrate as fallback.
```

In `assets/code/hooks/claude/activity-emitter.sh`, replace line 16:

```bash
REGISTRY="${ANTCRATE_REGISTRY:-$HOME/.antcrate/registry.json}"
```

with a source of the shared resolver, so there is exactly one:

```bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/_zones.sh"
REGISTRY="$(_zones_registry)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/antcrate-src/assets/code && bats tests/zones_paths.bats`
Expected: PASS, 7 tests.

- [ ] **Step 5: Verify no caller regressed, and that the fix is non-vacuous**

Run: `cd ~/antcrate-src/assets/code && bats tests/gateway_guard.bats tests/activity_emitter.bats`
Expected: PASS. These set `ANTCRATE_REGISTRY` explicitly, so the override branch keeps them green — which also proves the override still wins.

Confirm `gateway-guard.sh` consumes `zones_control_plane` line-by-line and not as a single value:

Run: `grep -n 'zones_control_plane' ~/antcrate-src/assets/code/hooks/claude/gateway-guard.sh`
Expected: a `while IFS= read -r` loop or a `$(...)` used inside a loop. If it assigns to a scalar and compares with `=`, fix that call site to loop over the lines before continuing — a multi-line value silently compared as a scalar would make the critical zone stop matching.

Prove the fix does real work on this machine:

Run: `cd ~/antcrate-src/assets/code && jq -n '{tool_input:{command:"rm -rf /home/alexk/Projects/rfm-music/src"}}' | hooks/claude/gateway-guard.sh; echo "rc=$?"`
Expected: `rc=2` with a message naming the sanctioned channel. Before this task the same command exits 0, because the stub registry lists no projects.

- [ ] **Step 6: Run shellcheck**

Run: `shellcheck ~/antcrate-src/assets/code/hooks/claude/_zones.sh ~/antcrate-src/assets/code/hooks/claude/activity-emitter.sh`
Expected: clean, no output.

- [ ] **Step 7: Commit**

```bash
cd ~/antcrate-src && antcrate commit antcrate \
  -m "fix(hooks): resolve registry under XDG data home, not the ~/.antcrate stub" \
  -- assets/code/hooks/claude/_zones.sh \
     assets/code/hooks/claude/activity-emitter.sh \
     assets/code/tests/zones_paths.bats
```

---

### Task 2: The SessionStart digest hook

A new hook that injects open duties, unread intel, and dirty/unpushed project counts at session start — and prints nothing when all three are clean, so a quiet session costs zero tokens.

**Files:**
- Create: `plugin/hooks/session-digest.sh`
- Test: `assets/code/tests/session_digest.bats` (create)

**Interfaces:**
- Consumes: the registry resolution order from Task 1, reimplemented locally (this script is bundled outside `hooks/claude/` and must not depend on the generated tree's layout).
- Produces: a script that reads the hook payload on stdin (and ignores it), writes at most one line to stdout, and always exits 0.

Note the file lives at `plugin/hooks/session-digest.sh`, **not** under `plugin/hooks/claude/`. Task 3's generator owns `plugin/hooks/claude/` completely and deletes anything there without a source counterpart.

- [ ] **Step 1: Write the failing test**

Create `assets/code/tests/session_digest.bats`:

```bash
#!/usr/bin/env bats
# tests for plugin/hooks/session-digest.sh — SessionStart state digest

setup() {
    DIGEST="$BATS_TEST_DIRNAME/../../../plugin/hooks/session-digest.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export ANTCRATE_DATA_HOME="$HOME/.local/share/antcrate"
    export ANTCRATE_INTEL_DIR="$ANTCRATE_DATA_HOME/intel"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_INTEL_DIR" "$ANTCRATE_DATA_HOME"
    printf '{"projects":{}}\n' > "$ANTCRATE_DATA_HOME/registry.json"
    : > "$ANTCRATE_DUTIES_FILE"
    : > "$ANTCRATE_INTEL_DIR/new.jsonl"
    : > "$ANTCRATE_INTEL_DIR/acked.jsonl"
}

digest() { printf '{"session_id":"x"}' | "$DIGEST"; }

@test "silent when duties, intel and trees are all clean" {
    run digest
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "counts open duties and reports the oldest date" {
    cat > "$ANTCRATE_DUTIES_FILE" <<'EOF'
 1. - [ ] 2026-07-17 — [command] older thing
 2. - [x] 2026-07-01 — [policy] already done
 3. - [ ] 2026-07-25 — [policy] newer thing
EOF
    run digest
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 duties open"* ]]
    [[ "$output" == *"oldest 2026-07-17"* ]]
}

@test "counts unread intel as new minus acked on source+sha" {
    printf '%s\n' \
      '{"source":"a","sha256":"aaa"}' \
      '{"source":"b","sha256":"bbb"}' \
      '{"source":"c","sha256":"ccc"}' > "$ANTCRATE_INTEL_DIR/new.jsonl"
    printf '%s\n' '{"source":"b","sha256":"bbb"}' > "$ANTCRATE_INTEL_DIR/acked.jsonl"
    run digest
    [[ "$output" == *"2 intel unread"* ]]
}

@test "reports a dirty registered project by name" {
    P="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$P"
    ( cd "$P" && git init -q -b master \
        && git config user.email t@e.x && git config user.name t \
        && echo one > a.txt && git add a.txt && git commit -qm init \
        && echo two > a.txt )
    jq -n --arg p "$P" '{projects:{proj:{path:$p}}}' > "$ANTCRATE_DATA_HOME/registry.json"
    run digest
    [[ "$output" == *"1 dirty"* ]]
    [[ "$output" == *"proj"* ]]
}

@test "ANTCRATE_DIGEST_GIT=0 skips the git sweep entirely" {
    P="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$P"
    ( cd "$P" && git init -q -b master \
        && git config user.email t@e.x && git config user.name t \
        && echo one > a.txt && git add a.txt && git commit -qm init \
        && echo two > a.txt )
    jq -n --arg p "$P" '{projects:{proj:{path:$p}}}' > "$ANTCRATE_DATA_HOME/registry.json"
    ANTCRATE_DIGEST_GIT=0 run digest
    [ -z "$output" ]
}

@test "ANTCRATE_DIGEST_DISABLE=1 silences the hook completely" {
    printf ' 1. - [ ] 2026-07-17 — [x] thing\n' > "$ANTCRATE_DUTIES_FILE"
    ANTCRATE_DIGEST_DISABLE=1 run digest
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fails open on a missing registry" {
    rm -f "$ANTCRATE_DATA_HOME/registry.json"
    run digest
    [ "$status" -eq 0 ]
}

@test "fails open on malformed intel jsonl" {
    printf 'not json at all\n' > "$ANTCRATE_INTEL_DIR/new.jsonl"
    run digest
    [ "$status" -eq 0 ]
}

@test "fails open on a missing duties file" {
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/nope.md"
    run digest
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/antcrate-src/assets/code && bats tests/session_digest.bats`
Expected: FAIL on every test — the script does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `plugin/hooks/session-digest.sh` (mark it executable: `chmod +x`):

```bash
#!/usr/bin/env bash
# session-digest.sh — Claude Code SessionStart hook.
#
# Injects the three state deltas an agent would otherwise spend tokens asking
# for: open duties, unread intel, and dirty/unpushed registered projects.
# Prints NOTHING when all three are clean, so a quiet session costs zero
# tokens. Read-only by construction: it opens files and runs read-only git
# queries, and writes nowhere.
#
# Fail-open contract: any missing file, absent tool, or malformed JSON drops
# that one signal. Every exit path is exit 0 — a SessionStart hook must never
# be able to stop a session from starting.
#
# Env: ANTCRATE_DIGEST_DISABLE=1  skip the hook entirely
#      ANTCRATE_DIGEST_GIT=0      skip the git sweep (the only slow part)
#      ANTCRATE_DIGEST_BUDGET     git sweep wall-clock budget, seconds (default 2)
#      ANTCRATE_REGISTRY / ANTCRATE_DATA_HOME / XDG_DATA_HOME  registry location
#      ANTCRATE_INTEL_DIR         intel dir (default <data home>/intel)
#      ANTCRATE_DUTIES_FILE       duties checklist (default <selfsrc>/dev/duties.md)
#
# NOTE: no `set -e` — a failed sub-check must skip its signal, not abort.
set -uo pipefail

[ "${ANTCRATE_DIGEST_DISABLE:-0}" = "1" ] && exit 0
cat >/dev/null 2>&1 || true          # drain the payload; we do not need it
command -v jq >/dev/null 2>&1 || exit 0

# ---- path resolution (mirrors lib/paths.sh and hooks/claude/_zones.sh) ------
data_home="${ANTCRATE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/antcrate}"
registry="${ANTCRATE_REGISTRY:-}"
if [ -z "$registry" ]; then
    if [ -r "$data_home/registry.json" ] || [ ! -r "$HOME/.antcrate/registry.json" ]; then
        registry="$data_home/registry.json"
    else
        registry="$HOME/.antcrate/registry.json"
    fi
fi
intel_dir="${ANTCRATE_INTEL_DIR:-$data_home/intel}"

duties_file="${ANTCRATE_DUTIES_FILE:-}"
if [ -z "$duties_file" ]; then
    selfsrc="${ANTCRATE_SELFSRC:-$HOME/.claude/skills/antcrate}"
    if   [ -f "$selfsrc/dev/duties.md" ]; then duties_file="$selfsrc/dev/duties.md"
    else duties_file="$selfsrc/duties.md"
    fi
fi

parts=()

# ---- duties: unchecked boxes, plus the oldest ISO date among them -----------
if [ -r "$duties_file" ]; then
    open_lines="$(grep -c -- '- \[ \]' "$duties_file" 2>/dev/null || true)"
    open_lines="${open_lines:-0}"
    if [ "$open_lines" -gt 0 ] 2>/dev/null; then
        oldest="$(grep -- '- \[ \]' "$duties_file" 2>/dev/null \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort | head -n 1)"
        if [ -n "$oldest" ]; then
            parts+=("$open_lines duties open (oldest $oldest)")
        else
            parts+=("$open_lines duties open")
        fi
    fi
fi

# ---- intel: rows in new.jsonl absent from acked.jsonl, matched source+sha ---
if [ -r "$intel_dir/new.jsonl" ]; then
    acked='[]'
    [ -r "$intel_dir/acked.jsonl" ] && \
        acked="$(jq -cs '[.[] | {source, sha256}]' "$intel_dir/acked.jsonl" 2>/dev/null || echo '[]')"
    unread="$(jq -r --argjson acked "$acked" \
        'select(. as $r | $acked | map(.source == $r.source and .sha256 == $r.sha256) | any | not) | 1' \
        "$intel_dir/new.jsonl" 2>/dev/null | grep -c 1 || true)"
    unread="${unread:-0}"
    [ "$unread" -gt 0 ] 2>/dev/null && parts+=("$unread intel unread")
fi

# ---- working trees: dirty and unpushed counts, bounded by a time budget -----
if [ "${ANTCRATE_DIGEST_GIT:-1}" != "0" ] && [ -r "$registry" ] && command -v git >/dev/null 2>&1; then
    budget="${ANTCRATE_DIGEST_BUDGET:-2}"
    started=$SECONDS
    dirty=0; unpushed=0; skipped=0
    dirty_names=()
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ $(( SECONDS - started )) -ge "$budget" ]; then
            skipped=$(( skipped + 1 )); continue
        fi
        [ -e "$p/.git" ] || continue        # .git is a FILE in a worktree
        if [ -n "$(git -C "$p" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            dirty=$(( dirty + 1 ))
            [ "${#dirty_names[@]}" -lt 3 ] && dirty_names+=("$(basename "$p")")
        fi
        ahead="$(git -C "$p" rev-list --count '@{u}..HEAD' 2>/dev/null || true)"
        [ "${ahead:-0}" -gt 0 ] 2>/dev/null && unpushed=$(( unpushed + 1 ))
    done < <(jq -r '.projects[]?.path // empty' "$registry" 2>/dev/null)

    if [ "$dirty" -gt 0 ]; then
        names="$(IFS=', '; printf '%s' "${dirty_names[*]}")"
        parts+=("$dirty dirty ($names)")
    fi
    [ "$unpushed" -gt 0 ] && parts+=("$unpushed unpushed")
    # Never present a partial sweep as a total.
    [ "$skipped" -gt 0 ] && parts+=("$skipped project(s) not checked — time budget")
fi

# ---- emit, or stay silent --------------------------------------------------
[ "${#parts[@]}" -eq 0 ] && exit 0
printf 'antcrate: %s\n' "$(IFS=' · '; printf '%s' "${parts[*]}")"
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/antcrate-src/assets/code && chmod +x ../../plugin/hooks/session-digest.sh && bats tests/session_digest.bats`
Expected: PASS, 9 tests.

- [ ] **Step 5: Check it against real state on this machine**

Run: `printf '{}' | ~/antcrate-src/plugin/hooks/session-digest.sh`
Expected: one line reporting roughly `7 duties open (oldest 2026-07-17) · 26 intel unread` plus whatever trees are dirty. If it prints nothing, the duties or intel path resolution is wrong — debug before continuing, because silence is indistinguishable from "clean" by design.

- [ ] **Step 6: Run shellcheck**

Run: `shellcheck ~/antcrate-src/plugin/hooks/session-digest.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
cd ~/antcrate-src && antcrate commit antcrate \
  -m "feat(plugin): SessionStart digest — duties, intel, dirty trees; silent when clean" \
  -- plugin/hooks/session-digest.sh assets/code/tests/session_digest.bats
```

---

### Task 3: The `antcrate self plugin` generator

Copies the hook scripts from source into the plugin tree, and provides the `--check` mode that CI uses to fail on drift.

**Files:**
- Create: `assets/code/lib/plugin.sh`
- Modify: `assets/code/bin/antcrate` (source the lib near line 117; add the `self` sub near line 625; add the flag parse near line 938; add the dispatch near line 1325; add two usage lines near 154 and 177)
- Test: `assets/code/tests/plugin_build.bats` (create)

**Interfaces:**
- Consumes: `ac_error` / `ac_info` from `lib/log.sh`, already sourced by the wrapper.
- Produces: `ac_plugin_build [--check]` → exit 0 when the tree matches source (or was successfully rebuilt); exit 1 when `--check` finds drift; exit 2 on a usage error. Prints one line per file added, updated, or removed.

- [ ] **Step 1: Write the failing test**

Create `assets/code/tests/plugin_build.bats`:

```bash
#!/usr/bin/env bats
# tests for lib/plugin.sh — plugin tree generator and drift check

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_LOG_LEVEL="error"
    SRC="$BATS_TEST_TMPDIR/src/hooks/claude"
    DST="$BATS_TEST_TMPDIR/plugin/hooks/claude"
    mkdir -p "$SRC" "$DST"
    printf '#!/usr/bin/env bash\necho a\n' > "$SRC/a.sh"; chmod +x "$SRC/a.sh"
    printf '#!/usr/bin/env bash\necho b\n' > "$SRC/b.sh"; chmod +x "$SRC/b.sh"
    export ANTCRATE_PLUGIN_SRC="$SRC"
    export ANTCRATE_PLUGIN_DST="$DST"
}

build() {
    bash -c '
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_PLUGIN_SRC="'"$SRC"'"
        export ANTCRATE_PLUGIN_DST="'"$DST"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/plugin.sh"
        ac_plugin_build '"$1"
}

@test "build: copies every source hook into the plugin tree" {
    run build ""
    [ "$status" -eq 0 ]
    [ -f "$DST/a.sh" ]
    [ -f "$DST/b.sh" ]
}

@test "build: preserves the executable bit" {
    build "" >/dev/null
    [ -x "$DST/a.sh" ]
}

@test "build: removes a stale copy with no source counterpart" {
    printf 'stale\n' > "$DST/gone.sh"
    build "" >/dev/null
    [ ! -f "$DST/gone.sh" ]
}

@test "check: clean tree exits 0" {
    build "" >/dev/null
    run build "--check"
    [ "$status" -eq 0 ]
}

@test "check: modified copy exits 1 and names the file" {
    build "" >/dev/null
    printf 'tampered\n' >> "$DST/a.sh"
    run build "--check"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a.sh"* ]]
}

@test "check: missing copy exits 1" {
    build "" >/dev/null
    rm -f "$DST/b.sh"
    run build "--check"
    [ "$status" -eq 1 ]
}

@test "check: extra copy exits 1" {
    build "" >/dev/null
    printf 'extra\n' > "$DST/extra.sh"
    run build "--check"
    [ "$status" -eq 1 ]
}

@test "check: never writes — drift survives a check run" {
    build "" >/dev/null
    printf 'tampered\n' >> "$DST/a.sh"
    build "--check" || true
    grep -q tampered "$DST/a.sh"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/antcrate-src/assets/code && bats tests/plugin_build.bats`
Expected: FAIL — `lib/plugin.sh` does not exist, so sourcing it aborts every test.

- [ ] **Step 3: Write the implementation**

Create `assets/code/lib/plugin.sh`:

```bash
#!/usr/bin/env bash
# antcrate :: lib/plugin.sh — generate the Claude Code plugin tree.
#
# assets/code/hooks/claude/ is the SOURCE OF TRUTH for hook scripts. The
# plugin ships committed copies so it installs standalone, with no build step
# on the consumer's machine. This generator produces those copies; a drift
# test in self ci fails when they diverge.
#
# plugin/hooks/claude/ is WHOLLY OWNED by this function: anything there with
# no source counterpart is deleted. Hand-written plugin files (hooks.json,
# session-digest.sh) live one level up, in plugin/hooks/, and are never touched.
#
# Public API:
#   ac_plugin_build [--check]
#
# Env (test seams): ANTCRATE_PLUGIN_SRC, ANTCRATE_PLUGIN_DST
#
# Sourced by wrapper. Depends on log.sh.

# ac_plugin_build [--check]
#   default : sync src -> dst, print what changed, exit 0
#   --check : report drift, change nothing, exit 1 if any drift
ac_plugin_build() {
    local check=0
    while (( $# > 0 )); do
        case "$1" in
            --check) check=1; shift ;;
            *) ac_error "self plugin: unknown arg '$1' (--check)"; return 2 ;;
        esac
    done

    local selfsrc src dst
    selfsrc="${ANTCRATE_SELFSRC:-$HOME/.claude/skills/antcrate}"
    src="${ANTCRATE_PLUGIN_SRC:-$selfsrc/assets/code/hooks/claude}"
    dst="${ANTCRATE_PLUGIN_DST:-$selfsrc/plugin/hooks/claude}"

    [ -d "$src" ] || { ac_error "self plugin: source dir missing: $src"; return 2; }
    (( check )) || mkdir -p "$dst"
    [ -d "$dst" ] || { ac_error "self plugin: dest dir missing: $dst"; return 2; }

    local drift=0 f base
    # forward pass: every source file must exist in dst, byte-identical
    for f in "$src"/*.sh; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        if [ -f "$dst/$base" ] && cmp -s "$f" "$dst/$base"; then
            continue
        fi
        drift=1
        if (( check )); then
            printf 'plugin: DRIFT %s\n' "$base"
        else
            cp -p "$f" "$dst/$base"
            chmod +x "$dst/$base"
            printf 'plugin: synced %s\n' "$base"
        fi
    done

    # reverse pass: nothing may exist in dst without a source counterpart
    for f in "$dst"/*.sh; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ -f "$src/$base" ] && continue
        drift=1
        if (( check )); then
            printf 'plugin: DRIFT extra %s\n' "$base"
        else
            rm -f "$f"
            printf 'plugin: removed %s\n' "$base"
        fi
    done

    if (( check )); then
        (( drift )) && { ac_error "self plugin: tree is stale — run 'antcrate self plugin'"; return 1; }
        printf 'plugin: tree matches source\n'
    fi
    return 0
}
```

Wire it into `assets/code/bin/antcrate` — four edits:

1. Near line 117, beside the other `. "$LIB_DIR/..."` lines:

```bash
. "$LIB_DIR/plugin.sh"
```

2. In the `self)` dispatch block (line 625-633), add a sub before the `*)` arm:

```bash
                    plugin)  shift; set -- --plugin-build "$@" ;;
```

and extend that block's error text to `(check|test|ci|plugin|src|edit|install)`.

3. In the flag-parsing `case`, beside `--ci)` at line 938:

```bash
        --plugin-build)
            ACTION="plugin-build"; shift
            if [[ "${1:-}" == "--check" ]]; then PLUGIN_CHECK="--check"; shift; fi ;;
```

Declare `PLUGIN_CHECK=""` beside the other option defaults at the top of the parser.

4. In the `case "$ACTION"` dispatch, beside `ci)` at line 1325:

```bash
    plugin-build) ac_plugin_build ${PLUGIN_CHECK:+"$PLUGIN_CHECK"} ;;
```

Update the two usage lines (near 154 and 177) to read
`self <check|test|ci|plugin|src|edit|install>`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/antcrate-src/assets/code && bats tests/plugin_build.bats`
Expected: PASS, 8 tests.

- [ ] **Step 5: Generate the real tree**

Run: `cd ~/antcrate-src && ANTCRATE_SELFSRC=~/antcrate-src bash assets/code/bin/antcrate self plugin`
Expected: eight `plugin: synced <name>.sh` lines — `_zones.sh`, `gateway-guard.sh`, `env-guard.sh`, `local-install-guard.sh`, `activity-emitter.sh`, `shellcheck-on-save.sh`, `cost-anticipator.sh`, `session-budget-guard.sh`.

Run: `ANTCRATE_SELFSRC=~/antcrate-src bash ~/antcrate-src/assets/code/bin/antcrate self plugin --check`
Expected: `plugin: tree matches source`, exit 0.

- [ ] **Step 6: Run shellcheck and the full suite**

Run: `shellcheck ~/antcrate-src/assets/code/lib/plugin.sh ~/antcrate-src/assets/code/bin/antcrate`
Expected: clean.

Run: `cd ~/antcrate-src && antcrate self ci 2>&1 | tail -5`
Expected: all tests pass, count above the 905 baseline. The new `.bats` files are picked up automatically by the suite glob.

- [ ] **Step 7: Commit**

```bash
cd ~/antcrate-src && antcrate commit antcrate \
  -m "feat(self): 'antcrate self plugin' generates the plugin hook tree, --check detects drift" \
  -- assets/code/lib/plugin.sh assets/code/bin/antcrate \
     assets/code/tests/plugin_build.bats plugin/hooks/claude
```

---

### Task 4: Manifests, wiring, and the plugin validation test

The hand-written half of the plugin: what Claude Code reads to find and load it.

**Files:**
- Create: `.claude-plugin/marketplace.json`
- Create: `plugin/.claude-plugin/plugin.json`
- Create: `plugin/hooks/hooks.json`
- Create: `plugin/README.md`
- Test: `assets/code/tests/plugin_manifest.bats` (create)

**Interfaces:**
- Consumes: `plugin/hooks/claude/*.sh` from Task 3; `plugin/hooks/session-digest.sh` from Task 2.
- Produces: an installable plugin. Nothing later in this plan consumes it programmatically.

**Deviation from the spec, deliberate:** the spec called for "a commented block in `hooks.json`" documenting how to enable the two budget hooks. JSON has no comments, and an unknown key risks failing manifest validation. The commented block moves to `plugin/README.md`, and `plugin_manifest.bats` asserts the two hooks are present in the tree but absent from the wiring — the decision is pinned by test either way.

- [ ] **Step 1: Write the failing test**

Create `assets/code/tests/plugin_manifest.bats`:

```bash
#!/usr/bin/env bats
# tests for the plugin manifests and hook wiring

setup() {
    ROOT="$BATS_TEST_DIRNAME/../../.."          # antcrate-src
    PLUGIN="$ROOT/plugin"
    HOOKS_JSON="$PLUGIN/hooks/hooks.json"
    MKT="$ROOT/.claude-plugin/marketplace.json"
    PJ="$PLUGIN/.claude-plugin/plugin.json"
}

# every command string in hooks.json, with the plugin root substituted
wired_commands() {
    jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$HOOKS_JSON" \
        | sed "s|\${CLAUDE_PLUGIN_ROOT}|$PLUGIN|g"
}

@test "marketplace.json parses and names the plugin" {
    run jq -e '.plugins | map(.name) | index("antcrate")' "$MKT"
    [ "$status" -eq 0 ]
}

@test "plugin.json parses and carries name plus version" {
    run jq -e '.name == "antcrate" and (.version | type == "string")' "$PJ"
    [ "$status" -eq 0 ]
}

@test "hooks.json parses" {
    run jq -e '.hooks | type == "object"' "$HOOKS_JSON"
    [ "$status" -eq 0 ]
}

@test "every wired command resolves to an executable file" {
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [ -f "$c" ] || { echo "missing: $c"; false; }
        [ -x "$c" ] || { echo "not executable: $c"; false; }
    done < <(wired_commands)
}

@test "every wired command uses \${CLAUDE_PLUGIN_ROOT}, never \$HOME or an absolute path" {
    run jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$HOOKS_JSON"
    [[ "$output" != *"\$HOME"* ]]
    [[ "$output" != *"/home/"* ]]
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        [[ "$c" == "\${CLAUDE_PLUGIN_ROOT}/"* ]] || { echo "bad prefix: $c"; false; }
    done <<< "$output"
}

@test "the five v1 guards are wired" {
    out="$(wired_commands)"
    for h in gateway-guard.sh env-guard.sh local-install-guard.sh \
             activity-emitter.sh shellcheck-on-save.sh session-digest.sh; do
        [[ "$out" == *"$h"* ]] || { echo "not wired: $h"; false; }
    done
}

@test "the budget pair ships in the tree but stays UNWIRED" {
    [ -f "$PLUGIN/hooks/claude/cost-anticipator.sh" ]
    [ -f "$PLUGIN/hooks/claude/session-budget-guard.sh" ]
    out="$(wired_commands)"
    [[ "$out" != *"cost-anticipator.sh"* ]]
    [[ "$out" != *"session-budget-guard.sh"* ]]
}

@test "gateway-guard and env-guard are wired on PreToolUse Bash" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command' "$HOOKS_JSON"
    [[ "$output" == *"gateway-guard.sh"* ]]
    [[ "$output" == *"env-guard.sh"* ]]
}

@test "session-digest is wired on SessionStart" {
    run jq -r '.hooks.SessionStart[].hooks[].command' "$HOOKS_JSON"
    [[ "$output" == *"session-digest.sh"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/antcrate-src/assets/code && bats tests/plugin_manifest.bats`
Expected: FAIL — none of the three JSON files exist.

- [ ] **Step 3: Write the manifests**

Create `.claude-plugin/marketplace.json` at the repo root:

```json
{
  "name": "antcrate",
  "owner": { "name": "zeppybabe" },
  "plugins": [
    {
      "name": "antcrate",
      "source": "./plugin",
      "description": "AntCrate's Gateway Law perimeter for Claude Code: blocks destructive Bash outside the sanctioned channels, keeps secret values out of the transcript, and injects open duties and unread intel at session start."
    }
  ]
}
```

Create `plugin/.claude-plugin/plugin.json`:

```json
{
  "name": "antcrate",
  "version": "0.1.0",
  "description": "AntCrate's Gateway Law perimeter for Claude Code: blocks destructive Bash outside the sanctioned channels, keeps secret values out of the transcript, and injects open duties and unread intel at session start.",
  "author": { "name": "zeppybabe" },
  "homepage": "https://github.com/zeppybabe/antcrate",
  "license": "MIT",
  "keywords": ["antcrate", "safety", "hooks", "gateway"]
}
```

Create `plugin/hooks/hooks.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/gateway-guard.sh" },
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/env-guard.sh" },
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/local-install-guard.sh" }
        ]
      },
      {
        "matcher": "Read",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/env-guard.sh" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write|Read|NotebookEdit",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/activity-emitter.sh" }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/shellcheck-on-save.sh" }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-digest.sh" }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: Write the README**

Create `plugin/README.md`:

```markdown
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

## Not wired by default

`cost-anticipator.sh` and `session-budget-guard.sh` ship in `hooks/claude/` but
are deliberately unwired. Both parse the session transcript and can block
`Skill`, `Agent` and `Read` calls; a misfire stalls the session's own work. To
enable, add to the `PreToolUse` array in `hooks/hooks.json`:

```json
{
  "matcher": "Skill|Agent|Read",
  "hooks": [
    { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/claude/cost-anticipator.sh" },
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/antcrate-src/assets/code && bats tests/plugin_manifest.bats`
Expected: PASS, 9 tests.

- [ ] **Step 6: Run the full suite**

Run: `cd ~/antcrate-src && antcrate self ci 2>&1 | tail -5`
Expected: all green, count above baseline.

- [ ] **Step 7: Commit**

```bash
cd ~/antcrate-src && antcrate commit antcrate \
  -m "feat(plugin): manifests, hook wiring and README for the antcrate Claude Code plugin" \
  -- .claude-plugin plugin/.claude-plugin plugin/hooks/hooks.json plugin/README.md \
     assets/code/tests/plugin_manifest.bats
```

---

### Task 5: Live install, non-vacuous verification, and records

Fixture tests prove the wiring is well-formed. They cannot prove Claude Code actually loads it. This task is the live check plus the record-keeping the maintenance protocol requires.

**Files:**
- Modify: `dev/duties.md` (via `antcrate duty add`, never by hand)
- Modify: `dev/ledger.md` (append, newest first)
- Modify: `dev/state.md` (rewrite "Top of mind", roll the oldest block into `dev/state-archive.md`)

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Install the plugin**

In a Claude Code session:

```
/plugin marketplace add ~/antcrate-src
/plugin install antcrate@antcrate
```

Then restart the session. Expected: the session-start digest line appears — that is the first proof the plugin loaded at all.

- [ ] **Step 2: File the settings.json duty**

Run:

```bash
antcrate duty add --type policy "Delete the local-install-guard.sh PreToolUse entry from ~/.claude/settings.json — the antcrate plugin now supplies it. Leaving both double-fires the guard and means uninstalling the plugin silently leaves one hook behind. Owner-only: agents do not edit that file."
```

Expected: the duty appears in `antcrate duty ls`.

- [ ] **Step 3: Verify the block fires from the plugin — the positive half**

With the plugin installed and the `settings.json` entry removed, ask the session to run a recursive delete inside a registered project that does not exist, e.g. `rm -rf ~/Projects/rfm-music/no-such-dir`.

Expected: the call is **blocked** with the guard's message naming the sanctioned `antcrate` channel. Nothing is deleted.

- [ ] **Step 4: Verify the same block is attributable, not incidental — the negative half**

A block proves nothing if the wrapper or a leftover settings entry produced it. Confirm attribution:

Run: `jq -r '.hooks.PreToolUse[]?.hooks[]?.command' ~/.claude/settings.json`
Expected: no `gateway-guard.sh`, no `local-install-guard.sh` — the block in Step 3 could only have come from the plugin.

Then prove the Task 1 fix is what makes registry rules fire, by reverting it temporarily:

```bash
cd ~/antcrate-src
cp plugin/hooks/claude/_zones.sh /tmp/_zones.sh.bak
# temporarily force the stub-registry behaviour
ANTCRATE_REGISTRY="$HOME/.antcrate/registry.json" \
  jq -n '{tool_input:{command:"rm -rf /home/alexk/Projects/rfm-music/src"}}' \
  | plugin/hooks/claude/gateway-guard.sh; echo "rc=$?"
```

Expected: `rc=0` — the stub registry lists no projects, so the sanctioned-zone rule cannot fire. Compare against the same command without the env override, which must give `rc=2`. That difference is the proof the fix does real work.

- [ ] **Step 5: Verify the activity emitter end to end**

Run: `antcrate watch` in one terminal, then edit any file inside a registered project from the Claude Code session.

Expected: the tree lights up for that project. This path has never worked before — the emitter was reading the stub registry and exiting 0 on every call.

- [ ] **Step 6: Append the ledger entry**

Add to the top of `dev/ledger.md` (newest first, below the header):

```markdown
## 2026-07-24 — CLAUDE CODE PLUGIN v1 (enforcement core) + registry-path fix

The perimeter was written but not loaded. Seven hook scripts existed in
`assets/code/hooks/claude/` and were installed by `self install`; exactly one —
`local-install-guard.sh` — was wired in `~/.claude/settings.json`.
`gateway-guard.sh` had never fired.

**The worse half: it would not have worked if it had been wired.** `_zones.sh`
resolved the registry as `${ANTCRATE_HOME:-$HOME/.antcrate}/registry.json`. That
file survives the XDG migration as a stub containing `{"projects":{}}`, so every
registry-dependent rule in the guard saw zero registered projects and fell open.
`activity-emitter.sh` carried the same legacy default, which is why the watch
view never lit up. Fixed at source: registry now resolves under the data home
exactly as `lib/paths.sh:30` does, `ANTCRATE_HOME` is never consulted for it,
and `zones_control_plane` covers state, data and config homes instead of only
the legacy directory.

**Why a plugin rather than more settings.json entries.** Hand-edited settings
are exactly the un-versioned, un-testable, un-removable configuration the
Gateway abolishes everywhere else. The plugin makes the perimeter versioned,
atomic to install and remove, portable, and inherited by subagents — which is
where an unenforced Law bites hardest.

`assets/code/hooks/claude/` stays the source of truth. `plugin/hooks/claude/`
holds committed copies so the plugin installs standalone with no consumer-side
build; `antcrate self plugin --check` fails CI on drift. Five hooks wired;
`cost-anticipator` and `session-budget-guard` ship unwired — both parse the
transcript and can block Skill/Agent/Read, and neither has run in a real
session. A test pins them as unwired so enabling them stays a deliberate change.

New `session-digest.sh` (SessionStart) reports open duties, unread intel and
dirty/unpushed trees, and prints **nothing** when all three are clean — the
property that makes an always-on hook acceptable. Read-only, no `antcrate`
shellout, git sweep bounded by a wall-clock budget with two kill switches.

**Owner action:** delete the `local-install-guard.sh` entry from
`~/.claude/settings.json` (duty filed). Left in place it double-fires and
survives a plugin uninstall.
```

- [ ] **Step 7: Update state.md**

Rewrite the "Top of mind" section of `dev/state.md` with a new dated block for this work, and move the oldest block verbatim into `dev/state-archive.md` (append-only, newest first) to keep `state.md` rolling at current + prior.

- [ ] **Step 8: Commit and report**

```bash
cd ~/antcrate-src && antcrate commit antcrate \
  -m "docs: ledger + state for the Claude Code plugin v1" \
  -- dev/ledger.md dev/state.md dev/state-archive.md dev/duties.md
```

Do **not** push. `antcrate pp antcrate` is the owner's call — report the commit range and the `st` output instead.

---

## Self-Review

**Spec coverage.** Problem statement → Task 1 (path defect) and Task 5 Step 2 (settings.json overlap). Component 1 wiring → Task 4. Component 2 path fix → Task 1. Component 3 digest → Task 2. Component 4 build and drift test → Task 3, with the manifest half of the spec's `plugin.bats` split into `plugin_manifest.bats` in Task 4 (a reviewer can accept the generator while rejecting the wiring, so they are separate tasks; the test file split follows). Component 5 install → Task 5 Steps 1-2. Verification section, all four items → Task 5 Steps 3-5, plus Task 1 Step 5. Out-of-scope list → untouched.

**Deviations from the spec, both deliberate and noted inline.** (1) The spec's single `plugin.bats` became `plugin_build.bats` + `plugin_manifest.bats`, following the task split. (2) The spec's "commented block in `hooks.json`" for the budget pair moved to `README.md`, because JSON has no comments; the decision stays pinned by a test asserting they are unwired. (3) `zones_control_plane` widening to three XDG homes was not in the spec — it is the same defect in the same function and fixing only half would leave the control plane guarding an empty legacy directory.

**Type consistency.** `ac_plugin_build [--check]` is named identically in `lib/plugin.sh`, the wrapper dispatch, and `plugin_build.bats`. `_zones_registry` / `zones_control_plane` / `zones_registered_roots` keep their existing names, so no caller outside `_zones.sh` changes. `ANTCRATE_PLUGIN_SRC` / `ANTCRATE_PLUGIN_DST` are used only as test seams and appear in both `plugin.sh` and `plugin_build.bats`. The env switches `ANTCRATE_DIGEST_DISABLE`, `ANTCRATE_DIGEST_GIT`, `ANTCRATE_DIGEST_BUDGET` appear identically in `session-digest.sh`, its tests, and the README.
