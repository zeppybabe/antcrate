# `antcrate --relocate` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `antcrate --relocate <project> [--no-watch]` to move a registered project out of the `~/.claude` skill tree into `$ANTCRATE_ROOT` (`~/projects`), leaving a symlink and rewiring registry/config/hooks — then dogfood it on antcrate itself so background agents can edit antcrate's code.

**Architecture:** New `lib/relocate.sh::ac_relocate` reuses `ac_safety_guard_destructive` (canary + path-zone + mandatory backup + approval), `mv`, `ln -s`, and `lib/registry.sh` mutators. Wired as `--relocate` in `bin/antcrate`. `bin/antcrated` learns to skip registry entries flagged `daemon_ignore: true`. Rollback is ordered so no `rm $VAR` is ever needed (honors AGENTS.md rule #16).

**Tech Stack:** Bash 5 (POSIX-ish), jq, bats, shellcheck. All paths absolute. cwd for commands: `~/.claude/skills/antcrate/assets/code` (until the dogfood move; the repo root is `~/.claude/skills/antcrate`).

**Reference:** spec at `docs/specs/2026-06-06-relocate-command-design.md`.

---

## Task 1: `lib/relocate.sh` + `tests/relocate.bats` (TDD)

**Files:**
- Create: `assets/code/lib/relocate.sh`
- Create: `assets/code/tests/relocate.bats`

- [ ] **Step 1: Write the failing test file**

Create `assets/code/tests/relocate.bats`:

```bash
#!/usr/bin/env bats
# tests for lib/relocate.sh — relocate a project out of the skill tree into $ANTCRATE_ROOT

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    export ANTCRATE_REMOVAL_PREAPPROVED=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT'
        export ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        export ANTCRATE_CANARY_DISABLE='1'
        export ANTCRATE_REMOVAL_PREAPPROVED='1'
        . '$LIB/log.sh'
        . '$LIB/registry.sh'
        . '$LIB/backup.sh'
        . '$LIB/canary.sh'
        . '$LIB/safety.sh'
        . '$LIB/relocate.sh'
        $1
    "
}

# helper: make a fake project OUTSIDE \$ANTCRATE_ROOT but inside an allowed zone
# (\$ANTCRATE_HOME is an allowed safety zone), and register it.
mk_outside_project() {
    local name="$1"
    local dir="$ANTCRATE_HOME/skilltree/$name"
    mkdir -p "$dir"
    printf 'hello\n' > "$dir/file.txt"
    src "ac_registry_upsert '$name' '$dir' 'claude-skills' ''"
    printf '%s' "$dir"
}

@test "relocate: missing project arg returns 2" {
    run src 'ac_relocate'
    [ "$status" -eq 2 ]
    [[ "$output" == *"requires <project>"* ]]
}

@test "relocate: unknown project returns 1" {
    run src 'ac_relocate nope'
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown project"* ]]
}

@test "relocate: project already under ANTCRATE_ROOT is refused" {
    mkdir -p "$ANTCRATE_ROOT/already"
    src "ac_registry_upsert 'already' '$ANTCRATE_ROOT/already' 'projects' ''"
    run src 'ac_relocate already'
    [ "$status" -eq 1 ]
    [[ "$output" == *"already in the projects tree"* ]]
}

@test "relocate: refuses when destination already exists" {
    mk_outside_project clash >/dev/null
    mkdir -p "$ANTCRATE_ROOT/clash"
    run src 'ac_relocate clash'
    [ "$status" -eq 1 ]
    [[ "$output" == *"destination already exists"* ]]
}

@test "relocate: happy path moves tree, creates symlink, updates registry path" {
    local oldpath; oldpath=$(mk_outside_project demo)
    run src 'ac_relocate demo'
    [ "$status" -eq 0 ]
    # tree moved
    [ -d "$ANTCRATE_ROOT/demo" ]
    [ -f "$ANTCRATE_ROOT/demo/file.txt" ]
    # old path is now a symlink -> new path
    [ -L "$oldpath" ]
    [ "$(readlink "$oldpath")" = "$ANTCRATE_ROOT/demo" ]
    # registry path updated
    run src 'ac_registry_get demo path'
    [ "$output" = "$ANTCRATE_ROOT/demo" ]
}

@test "relocate --no-watch sets daemon_ignore true" {
    mk_outside_project quiet >/dev/null
    run src 'ac_relocate quiet --no-watch'
    [ "$status" -eq 0 ]
    run bash -c "jq -r '.projects.quiet.daemon_ignore' '$ANTCRATE_REGISTRY'"
    [ "$output" = "true" ]
}

@test "relocate without --no-watch leaves daemon_ignore unset" {
    mk_outside_project loud >/dev/null
    run src 'ac_relocate loud'
    [ "$status" -eq 0 ]
    run bash -c "jq -r '.projects.loud.daemon_ignore // \"null\"' '$ANTCRATE_REGISTRY'"
    [ "$output" = "null" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/.claude/skills/antcrate/assets/code && bats tests/relocate.bats`
Expected: FAIL — `lib/relocate.sh` does not exist / `ac_relocate: command not found`.

- [ ] **Step 3: Write `lib/relocate.sh`**

Create `assets/code/lib/relocate.sh`:

```bash
#!/usr/bin/env bash
# antcrate :: lib/relocate.sh — relocate a registered project out of the
# ~/.claude skill tree into $ANTCRATE_ROOT (~/projects), leaving a symlink at
# the old path so existing references and Claude Code skill-discovery resolve.
#
# Why: Claude Code carves ~/.claude out of background-subagent file writes, so a
# project living there cannot be edited by background agents. Relocating it under
# $ANTCRATE_ROOT removes that limitation. See
# docs/specs/2026-06-06-relocate-command-design.md.
#
# Sourced by bin/antcrate. Depends on log.sh, registry.sh, safety.sh, backup.sh.

: "${ANTCRATE_ROOT:=$HOME/projects}"
: "${ANTCRATE_HOME:=$HOME/.antcrate}"

# ac_relocate <project> [--no-watch]
ac_relocate() {
    local project="" no_watch=0 arg
    for arg in "$@"; do
        case "$arg" in
            --no-watch) no_watch=1 ;;
            --*) ac_error "relocate: unknown flag '$arg'"; return 2 ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$arg"
                else
                    ac_error "relocate: unexpected argument '$arg'"; return 2
                fi ;;
        esac
    done
    [[ -z "$project" ]] && { ac_error "relocate: requires <project>"; return 2; }

    ac_registry_has "$project" || { ac_error "relocate: unknown project '$project'"; return 1; }

    local src; src=$(ac_registry_get "$project" path)
    [[ -d "$src" ]] || { ac_error "relocate: project path missing: $src"; return 1; }

    local root_abs src_abs
    root_abs=$(realpath -m "$ANTCRATE_ROOT")
    src_abs=$(realpath -m "$src")
    case "$src_abs" in
        "$root_abs"|"$root_abs"/*)
            ac_error "relocate: '$project' is already in the projects tree ($src) — nothing to relocate"
            return 1 ;;
    esac

    local dst="$ANTCRATE_ROOT/$project"
    [[ -e "$dst" ]] && { ac_error "relocate: destination already exists: $dst"; return 1; }

    # Gateway-Law: canary gate + path-zone check + mandatory backup + approval.
    ac_safety_guard_destructive "$project" "relocate to '$dst'" "$src" || return 1

    mkdir -p "$ANTCRATE_ROOT" || { ac_error "relocate: cannot create $ANTCRATE_ROOT"; return 1; }

    # 1. move the tree (carries its own .git)
    mv -- "$src" "$dst" || { ac_error "relocate: mv failed"; return 1; }

    # 2. registry path BEFORE symlink, so symlink-failure rollback needs no rm
    if ! ac_registry_set_path "$project" "$dst"; then
        ac_error "relocate: registry path update failed — rolling back move"
        mv -- "$dst" "$src" 2>/dev/null
        return 1
    fi

    # 3. recreate the old path as a symlink -> new location
    if ! ln -s "$dst" "$src"; then
        ac_error "relocate: symlink creation failed — rolling back"
        ac_registry_set_path "$project" "$src"
        mv -- "$dst" "$src" 2>/dev/null
        return 1
    fi

    # 4. parent + optional daemon-ignore flag
    ac_registry_set_parent "$project" "projects"
    if (( no_watch == 1 )); then
        ac_registry_apply --arg n "$project" '.projects[$n].daemon_ignore = true'
    fi

    ac_info "relocate: '$project' moved to $dst (symlink at $src, backup=${AC_LAST_BACKUP_PATH:-none})"
    {
        printf '\n  relocate: NEXT STEPS\n'
        printf '  - If this project ships an antcrate wrapper, reinstall from the new path:\n'
        printf '      bash "%s/assets/code/install.sh"\n' "$dst"
        printf '  - If this project is a Claude Code skill, RESTART Claude Code, then confirm:\n'
        printf '      ls -l "%s"   (symlink -> %s) and the skill still loads.\n' "$src" "$dst"
        printf '    If it does NOT load, replace the symlink with a real dir containing a\n'
        printf '    SKILL.md shim (see docs/specs/2026-06-06-relocate-command-design.md).\n'
    } >&2
    return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/.claude/skills/antcrate/assets/code && bats tests/relocate.bats`
Expected: PASS — 7/7.

- [ ] **Step 5: Shellcheck the new lib**

Run: `cd ~/.claude/skills/antcrate/assets/code && shellcheck -x lib/relocate.sh`
Expected: no output (clean). The shellcheck-on-save PostToolUse hook also enforces this on write.

---

## Task 2: Wire `--relocate` into `bin/antcrate`

**Files:**
- Modify: `assets/code/bin/antcrate` (source list ~line 38; flag parse ~line 555; dispatch ~line 851; help text ~line 184)

- [ ] **Step 1: Source the new lib**

After the `. "$LIB_DIR/safety.sh"` line (≈ line 38), add:

```bash
. "$LIB_DIR/relocate.sh"
```

(Place it adjacent to the other devops-family sources; order only matters in that registry.sh, safety.sh, backup.sh, log.sh load before it — they do.)

- [ ] **Step 2: Add the arg-parse case**

Immediately after the `--remove)` case (≈ line 555), add:

```bash
        --relocate)
            ACTION="relocate"; NAME="${2:-}"; shift 2
            RELOCATE_NO_WATCH=0
            while [[ "${1:-}" == "--no-watch" ]]; do RELOCATE_NO_WATCH=1; shift; done ;;
```

Also ensure `RELOCATE_NO_WATCH=0` is initialized with the other global defaults near the top of the arg-parse section (search for where `RENAME_NEW=` or similar defaults are set; add `RELOCATE_NO_WATCH=0` there). If no such block exists, the `--relocate` case sets it before use, which is sufficient.

- [ ] **Step 3: Add the dispatch case**

In the `case "$ACTION" in` block, after the `remove)` dispatch entry (search near line 851 / the `backup)` entry), add:

```bash
    relocate)
        [[ -z "$NAME" ]] && { ac_error "--relocate requires <project>"; exit 2; }
        relocate_args=( "$NAME" )
        (( ${RELOCATE_NO_WATCH:-0} == 1 )) && relocate_args+=( --no-watch )
        ac_with_lock ac_relocate "${relocate_args[@]}" ;;
```

- [ ] **Step 4: Add the help line**

In the help text, after the `--remove` line (≈ line 184), add:

```
  --relocate <project> [--no-watch]   move a project out of ~/.claude into ~/projects
                                      (symlink left behind; --no-watch keeps the daemon off it)
```

- [ ] **Step 5: Smoke the wiring (no move performed)**

Run: `cd ~/.claude/skills/antcrate/assets/code && bash bin/antcrate --relocate 2>&1; echo "rc=$?"`
Expected: `--relocate requires <project>` and `rc=2`.

Run: `bash bin/antcrate --relocate antcrate` — expected refusal **only if** antcrate is already under `~/projects`; at this point antcrate is still in `~/.claude`, so do NOT run the real move yet (that's Task 4). Instead verify the unknown-project guard:
Run: `bash bin/antcrate --relocate __nope__ 2>&1; echo "rc=$?"`
Expected: `unknown project '__nope__'`, `rc=1`.

---

## Task 3: Honor `daemon_ignore` in `bin/antcrated`

**Files:**
- Modify: `assets/code/bin/antcrated` (registry read loop, ≈ line 98)

- [ ] **Step 1: Filter the watch list**

Change the jq filter on ≈ line 98 from:

```bash
    done < <(jq -r '.projects | to_entries[] | "\(.key)\t\(.value.path)"' "$rfile" 2>/dev/null)
```

to:

```bash
    done < <(jq -r '.projects | to_entries[] | select(.value.daemon_ignore != true) | "\(.key)\t\(.value.path)"' "$rfile" 2>/dev/null)
```

- [ ] **Step 2: Verify the filter excludes flagged entries**

Run:
```bash
printf '%s' '{"projects":{"a":{"path":"/pa"},"b":{"path":"/pb","daemon_ignore":true}}}' \
 | jq -r '.projects | to_entries[] | select(.value.daemon_ignore != true) | "\(.key)\t\(.value.path)"'
```
Expected: exactly one line — `a	/pa` (b excluded).

- [ ] **Step 3: Shellcheck the daemon**

Run: `cd ~/.claude/skills/antcrate/assets/code && shellcheck -x bin/antcrated`
Expected: clean (or unchanged from baseline; no NEW findings).

---

## Task 4: Green the suite, commit, then dogfood the relocation

**Files:** none new — operational.

- [ ] **Step 1: Full CI**

Run: `cd ~/.claude/skills/antcrate/assets/code && bash bin/antcrate --ci`
Expected: `=== ci result: PASS ===` — shellcheck clean, cmake/ctest green, bats all green (previous count + 7 new = relocate.bats).

- [ ] **Step 2: Commit the feature (local only; push gated on user ask)**

Run:
```bash
cd ~/.claude/skills/antcrate
antcrate --commit antcrate -m "feat(relocate): --relocate moves a project out of ~/.claude into ~/projects" -- \
  assets/code/lib/relocate.sh assets/code/tests/relocate.bats assets/code/bin/antcrate assets/code/bin/antcrated \
  docs/specs/2026-06-06-relocate-command-design.md docs/plans/2026-06-06-relocate-command.md
```
Expected: one commit created. (Do NOT `--pp` / push unless the user asks.)

- [ ] **Step 3: Refresh the system wrapper so `antcrate` on PATH has `--relocate`**

Run: `antcrate --install-from-source`
Expected: installs from `~/.claude/skills/antcrate/assets/code`; `command -v antcrate` resolves to `~/.local/bin/antcrate`.
Verify: `antcrate --relocate __nope__ 2>&1; echo rc=$?` → `unknown project`, `rc=1`.

- [ ] **Step 4: Dogfood — relocate antcrate itself**

Run: `antcrate --backup antcrate` (explicit pre-move tarball; `--relocate` also backs up, but this is the belt-and-suspenders Gateway-Law step).
Then: `antcrate --relocate antcrate --no-watch`
Expected: `relocate: 'antcrate' moved to /home/twntydotsix/projects/antcrate (symlink at /home/twntydotsix/.claude/skills/antcrate, ...)` plus the NEXT STEPS notice.

- [ ] **Step 5: Verify the move on disk + registry**

Run:
```bash
ls -ld /home/twntydotsix/.claude/skills/antcrate            # symlink -> ~/projects/antcrate
ls -d  /home/twntydotsix/projects/antcrate/.git             # real repo now here
jq '.projects.antcrate' ~/.antcrate/registry.json           # path=~/projects/antcrate, parent=projects, daemon_ignore=true
```
Expected: symlink resolves; `.git` present at new path; registry updated.

- [ ] **Step 6: Reinstall from the new location + CI from new path**

Run:
```bash
bash /home/twntydotsix/projects/antcrate/assets/code/install.sh
grep ANTCRATE_SELFSRC ~/.antcrate/config        # now points at ~/projects/antcrate/assets/code
cd /home/twntydotsix/projects/antcrate/assets/code && bash bin/antcrate --ci
```
Expected: `ANTCRATE_SELFSRC="/home/twntydotsix/projects/antcrate/assets/code"`; CI PASS.

- [ ] **Step 7: Repoint the Claude Code hook paths in settings.json**

Edit `~/.claude/settings.json`: change both hook command paths from
`/home/twntydotsix/.claude/skills/antcrate/assets/code/hooks/claude/...` to
`/home/twntydotsix/projects/antcrate/assets/code/hooks/claude/...`.
(They would still execute through the symlink, but repointing avoids any `~/.claude` path confusion and survives later symlink changes.)
Verify: `jq -r '.hooks.PreToolUse[].hooks[].command, .hooks.PostToolUse[].hooks[].command' ~/.claude/settings.json` — both under `~/projects/antcrate`.

- [ ] **Step 8: Restart checklist (HANDOFF to user)**

The skill-discovery confirmation requires a Claude Code restart (skills load at startup). After restart, confirm:
- the `antcrate` skill still appears / loads;
- `ls -l ~/.claude/skills/antcrate` is a symlink → `~/projects/antcrate`.
If the skill does NOT load: replace the symlink with a real `~/.claude/skills/antcrate/` dir containing a `SKILL.md` shim pointing at `~/projects/antcrate` (documented fallback in the spec). Otherwise: background agents can now edit antcrate via the `~/projects/antcrate` path. Update `state.md` + `ledger.md` + memory accordingly.

---

## Self-review notes

- **Spec coverage:** refusals (Task 1 tests 1–4), move+symlink+registry (Task 1 test 5), `--no-watch`/daemon_ignore (Task 1 tests 6–7 + Task 3), rewire config/hooks (Task 4 steps 6–7), restart caveat (Task 4 step 8), reusable command (Tasks 1–2). All spec sections map to a task.
- **No `rm $VAR`:** rollback uses only `mv` (ordering: registry-before-symlink) — AGENTS.md rule #16 satisfied.
- **Type/name consistency:** `ac_relocate`, `RELOCATE_NO_WATCH`, `daemon_ignore`, `relocate_args` used identically across tasks.
- **Out of scope:** obsidian re-focus — next cycle, its own spec.
