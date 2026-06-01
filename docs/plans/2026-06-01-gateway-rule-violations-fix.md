# Gateway Rule-Violations Fix — Implementation Plan

> **For agentic workers:** Implement task-by-task, TDD. Steps use checkbox (`- [ ]`) syntax.
> **COMMIT POLICY (overrides the usual per-task commit):** Do NOT run `git commit` or `git add` for commits, and do NOT run `antcrate --commit`/`--pp`. Committing is Clyde's gateway responsibility and will happen once, over the whole tree, after verification. Your job ends at "`bash bin/antcrate --ci` is green; surface a report to Clyde."

**Goal:** Resolve three AGENTS-rule violations (two bare `cd` #10, one bare `git push` #12) by making `ac_git_push` path-explicit (`git -C`) and upstream-aware, then routing the two callers through it without `cd`.

**Architecture:** Single root change in `lib/git_triage.sh` (path param + `git -C` + auto set-upstream), consumed by `cmd_pp` (`bin/antcrate`) and `ac_gh_init_repo` (`lib/gh.sh`). Git is mocked in bats via a PATH shim; the shim must be taught to skip a leading `-C <path>`.

**Tech Stack:** Bash 5, bats, shellcheck. Spec: `docs/specs/2026-06-01-gateway-rule-violations-fix-design.md`.

**Working dir for all commands:** `~/.claude/skills/antcrate/assets/code`

---

### Task 1: Teach the fake-git shim about `-C`, then add failing tests

**Files:**
- Modify: `tests/git_triage.bats` (the `install_fake_git` helper + 3 new `@test`s)

- [ ] **Step 1: Replace `install_fake_git` with a `-C`-aware, arg-recording, upstream-configurable version.**

Replace the existing `install_fake_git()` function body with:

```bash
# install a fake git that: skips a leading "-C <path>"; records push args to
# pushargs.log; scripts push rc/stderr; answers rev-parse for @{u}, branch, sha.
# usage: install_fake_git <push_rc> <push_stderr_msg> [upstream_mode: set|unset]
install_fake_git() {
    local rc="$1" stderr_msg="$2" upstream_mode="${3:-set}"
    cat > "$BATS_TEST_TMPDIR/bin/git" <<EOF
#!/usr/bin/env bash
[ "\$1" = "-C" ] && shift 2          # drop the path prefix
sub="\$1"; shift
case "\$sub" in
    push)
        echo "push \$*" >> "$BATS_TEST_TMPDIR/pushargs.log"
        [ -n "$stderr_msg" ] && printf '%s\n' "$stderr_msg" >&2
        exit $rc ;;
    rev-parse)
        if printf '%s ' "\$@" | grep -q '@{u}'; then
            [ "$upstream_mode" = unset ] && exit 1
            echo "origin/main"; exit 0
        fi
        if printf '%s ' "\$@" | grep -q -- '--abbrev-ref' && printf '%s ' "\$@" | grep -qw HEAD; then
            echo "main"; exit 0
        fi
        echo "deadbeef"; exit 0 ;;
    diff)
        echo "diff --git a/x b/x"; for i in \$(seq 1 500); do echo "line\$i"; done; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/git"
}
```

- [ ] **Step 2: Run the existing suite to confirm the shim change is backward-compatible.**

Run: `bats tests/git_triage.bats`
Expected: PASS (existing cases unchanged — the `-C` skip is a no-op when git is called without `-C`, and `ac_git_push` still calls plain `git push` at this point).

- [ ] **Step 3: Add three failing tests at the end of `tests/git_triage.bats`.**

```bash
@test "push is path-explicit: ac_git_push receives -C <path>" {
    install_fake_git 0 ""
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj "/tmp/some/proj/path"'
    [ "$status" -eq 0 ]
    grep -q -- '-C' "$BATS_TEST_TMPDIR/bin/git"   # shim is -C-aware
    # the push must have happened (args recorded), proving the call routed through git -C
    [ -s "$BATS_TEST_TMPDIR/pushargs.log" ]
}

@test "no upstream → push sets it with -u origin <branch>" {
    install_fake_git 0 "" unset
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj "/tmp/proj"'
    [ "$status" -eq 0 ]
    grep -q 'push -u origin main' "$BATS_TEST_TMPDIR/pushargs.log"
}

@test "rejection with upstream-set still triages (conflict log + mail)" {
    install_fake_git 1 "error: failed to push some refs" unset
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj "/tmp/proj"'
    [ "$status" -ne 0 ]
    [ -s "$ANTCRATE_CONFLICT_LOG" ]
    grep -q 'push -u origin main' "$BATS_TEST_TMPDIR/pushargs.log"
}
```

- [ ] **Step 4: Run the three new tests; confirm they FAIL for the right reason.**

Run: `bats tests/git_triage.bats -f 'path-explicit|upstream|rejection with upstream'`
Expected: FAIL — current `ac_git_push` ignores `$2`, calls plain `git push` (no `-C`, no `-u origin`), so `pushargs.log` shows `push ` not `push -u origin main`. (The path-explicit test may pass partially; the two `-u origin` asserts must fail.)

---

### Task 2: Refactor `ac_git_push` to be path-explicit + upstream-aware (GREEN)

**Files:**
- Modify: `lib/git_triage.sh:53-120` (the `ac_git_push` function)

- [ ] **Step 1: Rewrite the function header + comment + push block.**

Replace the comment and signature:

```bash
# ac_git_push <project> [path]  — wraps git push, engages triage on rejection.
# Operates on <path> (default $PWD) via `git -C`; no cwd mutation. If the current
# branch has no upstream, the push sets it (-u origin <branch>) so first-pushes
# route through the same triage instead of a bare hand-rolled push.
ac_git_push() {
    local project="$1" path="${2:-$PWD}"
    local stderr_file; stderr_file=$(mktemp)
    local rc=0

    # upstream-aware push (auto set-upstream on first push), stderr captured
    local up branch
    up=$(git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [[ -z "$up" ]]; then
        branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
        git -C "$path" push -u origin "$branch" 2> "$stderr_file"; rc=$?
    else
        git -C "$path" push 2> "$stderr_file"; rc=$?
    fi
```

- [ ] **Step 2: Convert every remaining `git ` in the function to `git -C "$path" `.**

In the success branch (verify block) and the triage branch, change:
- `git rev-parse HEAD` → `git -C "$path" rev-parse HEAD`
- `git rev-parse --abbrev-ref --symbolic-full-name '@{u}'` → `git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}'` (both occurrences)
- `git rev-parse "$upstream"` → `git -C "$path" rev-parse "$upstream"`
- `git rev-parse --abbrev-ref HEAD` → `git -C "$path" rev-parse --abbrev-ref HEAD`
- `git diff "${upstream}..HEAD"` → `git -C "$path" diff "${upstream}..HEAD"`

Leave all triage/email logic, `$ANTCRATE_CONFLICT_LOG`, `ac_triage_dispatch`, and return codes exactly as-is.

- [ ] **Step 3: Run the full file; confirm all green.**

Run: `bats tests/git_triage.bats`
Expected: PASS (existing + 3 new).

- [ ] **Step 4: shellcheck the changed lib.**

Run: `shellcheck -x lib/git_triage.sh`
Expected: clean (no output).

---

### Task 3: Update `cmd_pp` to drop `cd` and pass the path

**Files:**
- Modify: `bin/antcrate:293-311` (the `cmd_pp` function)

- [ ] **Step 1: Replace the cd + git block.**

Replace lines from `cd "$p"` through `ac_git_push "$project" || true` with:

```bash
    if [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]]; then
        if [[ "$auto_yes" != "-y" ]]; then
            read -r -p "Uncommitted changes in $project. Commit & push? [y/N] " ans
            [[ "${ans,,}" == "y" ]] || { ac_warn "pp: aborted by user"; exit 0; }
        fi
        git -C "$p" add -A
        git -C "$p" commit -qm "antcrate: auto-commit $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
    fi
    ac_git_push "$project" "$p" || true
```

- [ ] **Step 2: shellcheck + syntax check.**

Run: `shellcheck -x bin/antcrate && bash -n bin/antcrate`
Expected: clean, exit 0.

---

### Task 4: Update `ac_gh_init_repo` to drop `cd` and route the push through `ac_git_push`

**Files:**
- Modify: `lib/gh.sh:36-72` (inside `ac_gh_init_repo`)

- [ ] **Step 1: Remove `cd "$path" || return 1` (line 36) entirely.**

- [ ] **Step 2: Make the init/commit block path-explicit.** Replace the block:

```bash
    # ensure local repo has at least one commit
    if [[ ! -d "$path/.git" ]]; then
        git -C "$path" init -q
    fi
    if ! git -C "$path" rev-parse HEAD >/dev/null 2>&1; then
        git -C "$path" add -A
        git -C "$path" commit -qm "antcrate: initial commit ($project)" || true
    fi
```

- [ ] **Step 3: Make the gh create path-explicit** — change `--source=.` to `--source "$path"`:

```bash
        gh repo create "${user}/${project}" "--${visibility}" \
            --source "$path" --remote=origin --push 2>&1 | sed 's/^/  gh: /' || {
            ac_error "gh: repo create failed"; return 1; }
```

- [ ] **Step 4: Make the "repo existed" remote-wire path-explicit, and route the push through `ac_git_push`.** Replace from the `git remote get-url` block through the final push:

```bash
    # repo existed; just wire origin if missing and push through the gateway
    if ! git -C "$path" remote get-url origin >/dev/null 2>&1; then
        git -C "$path" remote add origin "$https_url"
    fi
    ac_registry_set_remote "$project" "$https_url"

    # route through ac_git_push: upstream-auto-set handles the first-push upstream,
    # and a rejection now engages the conflict triage instead of a bare warn.
    if ac_git_push "$project" "$path"; then
        ac_info "gh: $project pushed to $https_url"
    else
        ac_warn "gh: initial push triaged — see $ANTCRATE_CONFLICT_LOG"
        return 1
    fi
```

- [ ] **Step 5: shellcheck the lib.**

Run: `shellcheck -x lib/gh.sh`
Expected: clean.

---

### Task 5: Full CI + report to Clyde (NO commit)

- [ ] **Step 1: Run the whole suite.**

Run: `bash bin/antcrate --ci`
Expected: `=== ci result: PASS ===` — shellcheck clean, cmake/ctest green, all bats green.

- [ ] **Step 2: Surface a report to Clyde.** Lead with the headline: which files changed, `--ci` result, the new test count, and confirm NO commit was made. List any deviation from this plan. Do NOT commit, push, or run `antcrate --commit`/`--pp` — Clyde owns the gateway and will commit the whole tree in one pass.

---

## Self-review (author)

- **Spec coverage:** Unit 1 → Task 2; Unit 2 → Task 3; Unit 3 → Task 4; fixture-shim trap → Task 1 Step 1; the three required tests → Task 1 Step 3. Covered.
- **Placeholder scan:** none — every code step has complete code.
- **Type/signature consistency:** `ac_git_push <project> [path]` used identically in Tasks 2/3/4. Push-arg assertion string `push -u origin main` matches the fake-git `echo "push $*"` format (`$*` of `push -u origin main` → `-u origin main`, logged as `push -u origin main`). Consistent.
