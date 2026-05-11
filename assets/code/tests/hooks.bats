#!/usr/bin/env bats
# tests for lib/hooks.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
    )
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/hooks.sh"
        '"$1"
}

# ---------- ac_hooks_dir ----------

@test "hooks_dir: default points at .git/hooks when core.hooksPath unset" {
    out=$(src "ac_hooks_dir '$R'")
    [ "$out" = "$R/.git/hooks" ]
}

@test "hooks_dir: honors a relative core.hooksPath" {
    (cd "$R" && git config core.hooksPath .githooks)
    out=$(src "ac_hooks_dir '$R'")
    [ "$out" = "$R/.githooks" ]
}

@test "hooks_dir: honors an absolute core.hooksPath" {
    (cd "$R" && git config core.hooksPath "/tmp/somewhere")
    out=$(src "ac_hooks_dir '$R'")
    [ "$out" = "/tmp/somewhere" ]
}

@test "hooks_dir: returns nonzero for a non-git path" {
    NOT="$BATS_TEST_TMPDIR/notgit"; mkdir -p "$NOT"
    run src "ac_hooks_dir '$NOT'"
    [ "$status" -ne 0 ]
}

# ---------- ac_hooks_list ----------

@test "hooks_list: registers project, lists default dir + filters .sample" {
    src "ac_registry_upsert proj '$R' scripts ''"
    # default dir already has bundled .sample files; create one real hook
    cat > "$R/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$R/.git/hooks/pre-commit"

    run src "ac_hooks_list proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hooks-dir:"* ]]
    [[ "$output" == *"pre-commit"$'\t'"active"* ]]
    [[ "$output" != *".sample"* ]]
}

@test "hooks_list: surfaces 'disabled' for non-executable hook files" {
    src "ac_registry_upsert proj '$R' scripts ''"
    : > "$R/.git/hooks/post-commit"   # exists but not exec
    run src "ac_hooks_list proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"post-commit"$'\t'"disabled"* ]]
}

@test "hooks_list: indicates antcrate opt-in when core.hooksPath=.githooks" {
    mkdir -p "$R/.githooks"
    cat > "$R/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$R/.githooks/pre-commit"
    (cd "$R" && git config core.hooksPath .githooks)

    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hooks_list proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"antcrate opt-in: ENABLED"* ]]
    [[ "$output" == *"pre-commit"$'\t'"active"* ]]
}

@test "hooks_list: refuses unknown project" {
    run src "ac_hooks_list ghost"
    [ "$status" -ne 0 ]
}

@test "hooks_list: handles missing hooks dir gracefully (exits 0)" {
    rm -rf "$R/.git/hooks"
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hooks_list proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"does not exist"* ]]
}

# ---------- ac_hooks_log ----------

@test "hook-log: friendly notice when no log exists yet" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hooks_log proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no hook log yet"* ]]
}

@test "hook-log: tails the log when present" {
    src "ac_registry_upsert proj '$R' scripts ''"
    LF="$R/.git/antcrate-hook.log"
    for i in 1 2 3 4 5; do printf 'line-%s\n' "$i" >> "$LF"; done
    run src "ac_hooks_log proj 3"
    [ "$status" -eq 0 ]
    [[ "$output" == *"line-3"* ]]
    [[ "$output" == *"line-4"* ]]
    [[ "$output" == *"line-5"* ]]
    [[ "$output" != *"line-1"* ]]
    [[ "$output" != *"line-2"* ]]
}

@test "hook-log: refuses unknown project" {
    run src "ac_hooks_log ghost"
    [ "$status" -ne 0 ]
}

# ---------- ac_hook_install ----------

@test "hook_install: writes pre-commit-secrets and chmods +x" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_install proj pre-commit-secrets"
    [ "$status" -eq 0 ]
    [ -x "$R/.git/hooks/pre-commit" ]
    grep -q "antcrate-template: pre-commit-secrets" "$R/.git/hooks/pre-commit"
    grep -q "Project: proj" "$R/.git/hooks/pre-commit"
}

@test "hook_install: token substitution replaces __PROJECT_NAME__" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    ! grep -q "__PROJECT_NAME__" "$R/.git/hooks/pre-commit"
}

@test "hook_install: idempotent (no-op when content matches)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    cs1=$(sha256sum "$R/.git/hooks/pre-commit" | cut -d' ' -f1)
    run src "ac_hook_install proj pre-commit-secrets"
    [ "$status" -eq 0 ]
    cs2=$(sha256sum "$R/.git/hooks/pre-commit" | cut -d' ' -f1)
    [ "$cs1" = "$cs2" ]
}

@test "hook_install: refuses overwrite when content differs (no --force)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    printf '#!/usr/bin/env bash\n# user edit\nexit 0\n' > "$R/.git/hooks/pre-commit"
    chmod +x "$R/.git/hooks/pre-commit"
    run src "ac_hook_install proj pre-commit-secrets"
    [ "$status" -ne 0 ]
    grep -q "user edit" "$R/.git/hooks/pre-commit"
}

@test "hook_install: --force backs up then overwrites" {
    src "ac_registry_upsert proj '$R' scripts ''"
    printf '#!/usr/bin/env bash\n# user edit\nexit 0\n' > "$R/.git/hooks/pre-commit"
    chmod +x "$R/.git/hooks/pre-commit"
    run src "ac_hook_install proj pre-commit-secrets --force"
    [ "$status" -eq 0 ]
    grep -q "antcrate-template: pre-commit-secrets" "$R/.git/hooks/pre-commit"
    # Backup file with timestamp suffix should exist.
    ls "$R/.git/hooks/" | grep -q "pre-commit.bak."
}

@test "hook_install: pre-push-tests installs as pre-push" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_install proj pre-push-tests"
    [ "$status" -eq 0 ]
    [ -x "$R/.git/hooks/pre-push" ]
    grep -q "antcrate-template: pre-push-tests" "$R/.git/hooks/pre-push"
}

@test "hook_install: explicit hook-name override works" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_install proj pre-commit-secrets pre-commit-extra"
    [ "$status" -eq 0 ]
    [ -x "$R/.git/hooks/pre-commit-extra" ]
    [ ! -f "$R/.git/hooks/pre-commit" ]
}

@test "hook_install: refuses unknown template" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_install proj nonexistent-template"
    [ "$status" -ne 0 ]
}

@test "hook_install: refuses unknown project" {
    run src "ac_hook_install ghost pre-commit-secrets"
    [ "$status" -ne 0 ]
}

@test "hook_install: refuses non-git path" {
    NOT="$BATS_TEST_TMPDIR/notgit"
    mkdir -p "$NOT"
    src "ac_registry_upsert nogit '$NOT' scripts ''"
    run src "ac_hook_install nogit pre-commit-secrets"
    [ "$status" -ne 0 ]
}

@test "hook_install: respects core.hooksPath" {
    src "ac_registry_upsert proj '$R' scripts ''"
    mkdir -p "$R/.githooks"
    (cd "$R" && git config core.hooksPath .githooks)
    run src "ac_hook_install proj pre-commit-secrets"
    [ "$status" -eq 0 ]
    [ -x "$R/.githooks/pre-commit" ]
    [ ! -f "$R/.git/hooks/pre-commit" ]
}

# ---------- ac_hook_remove ----------

@test "hook_remove: removes installed hook, creates .bak, audit logs append" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    [ -x "$R/.git/hooks/pre-commit" ]

    run src "ac_hook_remove proj pre-commit"
    [ "$status" -eq 0 ]
    [ ! -f "$R/.git/hooks/pre-commit" ]
    # Backup with timestamp suffix lives next to the original.
    ls "$R/.git/hooks/" | grep -q "pre-commit.bak."
    # Both audit sinks got an entry.
    [ -f "$ANTCRATE_HOME/hooks.log" ]
    grep -q '"action":"hook-remove"' "$ANTCRATE_HOME/hooks.log"
    grep -q '"project":"proj"'       "$ANTCRATE_HOME/hooks.log"
    [ -f "$R/.git/antcrate-hook-audit.log" ]
    grep -q "hook-remove project=proj hook=pre-commit" "$R/.git/antcrate-hook-audit.log"
}

@test "hook_remove: JSONL audit entry is well-formed (jq-parseable)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    run src "ac_hook_remove proj pre-commit"
    [ "$status" -eq 0 ]
    # Every line must parse and carry required fields.
    while IFS= read -r line; do
        echo "$line" | jq -e '.ts and .action and .project and .hook and .sha256 and .backup' >/dev/null
    done < "$ANTCRATE_HOME/hooks.log"
}

@test "hook_remove: captures sha256 of pre-removal file" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    pre_sha=$(sha256sum "$R/.git/hooks/pre-commit" | cut -d' ' -f1)
    run src "ac_hook_remove proj pre-commit"
    [ "$status" -eq 0 ]
    logged_sha=$(jq -r 'select(.action=="hook-remove") | .sha256' "$ANTCRATE_HOME/hooks.log" | tail -1)
    [ "$pre_sha" = "$logged_sha" ]
}

@test "hook_remove: missing hook returns 0 with friendly notice (no-op)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_remove proj pre-commit"
    [ "$status" -eq 0 ]
    # No audit entry should be appended when nothing was removed.
    [ ! -f "$ANTCRATE_HOME/hooks.log" ] || ! grep -q '"hook":"pre-commit"' "$ANTCRATE_HOME/hooks.log"
}

@test "hook_remove: refuses unknown project" {
    run src "ac_hook_remove ghost pre-commit"
    [ "$status" -ne 0 ]
}

@test "hook_remove: requires a hook name" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_remove proj"
    [ "$status" -ne 0 ]
}

@test "hook_remove: refuses non-git path" {
    NOT="$BATS_TEST_TMPDIR/notgit"
    mkdir -p "$NOT"
    src "ac_registry_upsert nogit '$NOT' scripts ''"
    run src "ac_hook_remove nogit pre-commit"
    [ "$status" -ne 0 ]
}

@test "hook_remove: respects core.hooksPath" {
    src "ac_registry_upsert proj '$R' scripts ''"
    mkdir -p "$R/.githooks"
    (cd "$R" && git config core.hooksPath .githooks)
    src "ac_hook_install proj pre-commit-secrets"
    [ -x "$R/.githooks/pre-commit" ]
    run src "ac_hook_remove proj pre-commit"
    [ "$status" -eq 0 ]
    [ ! -f "$R/.githooks/pre-commit" ]
    ls "$R/.githooks/" | grep -q "pre-commit.bak."
}

@test "hook_remove: backup file is restorable to working hook" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    src "ac_hook_remove proj pre-commit"
    # Find the backup, restore it, confirm content matches what install would write.
    bak=$(ls "$R/.git/hooks/"pre-commit.bak.* | head -1)
    [ -n "$bak" ]
    cp -p "$bak" "$R/.git/hooks/pre-commit"
    grep -q "antcrate-template: pre-commit-secrets" "$R/.git/hooks/pre-commit"
}

# ---------- ac_hook_debug ----------

# Helper: write an executable pre-commit hook with arbitrary body.
write_hook() {
    local body="$1"
    cat > "$R/.git/hooks/pre-commit" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$R/.git/hooks/pre-commit"
}

@test "hook_debug: passing hook returns 0, prints header + STDOUT, audits" {
    src "ac_registry_upsert proj '$R' scripts ''"
    write_hook 'echo hello-from-hook; exit 0'

    run src "ac_hook_debug proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== antcrate hook-debug ==="* ]]
    [[ "$output" == *"project   : proj"* ]]
    [[ "$output" == *"hook      : pre-commit"* ]]
    [[ "$output" == *"mode      : xtrace"* ]]
    [[ "$output" == *"=== STDOUT ==="* ]]
    [[ "$output" == *"[out] hello-from-hook"* ]]
    [[ "$output" == *"=== exit 0 ==="* ]]

    # audit sinks populated with action=hook-debug
    grep -q '"action":"hook-debug"' "$ANTCRATE_HOME/hooks.log"
    grep -q "hook-debug project=proj hook=pre-commit" "$R/.git/antcrate-hook-audit.log"
}

@test "hook_debug: failing hook surfaces stderr + nonzero exit" {
    src "ac_registry_upsert proj '$R' scripts ''"
    write_hook 'echo boom 1>&2; exit 7'

    run src "ac_hook_debug proj"
    [ "$status" -eq 7 ]
    [[ "$output" == *"=== STDERR ==="* ]]
    [[ "$output" == *"[err] boom"* ]]
    [[ "$output" == *"=== exit 7 ==="* ]]
}

@test "hook_debug: emits TRACE section by default (xtrace)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    write_hook 'X=42; echo "value=$X"'

    run src "ac_hook_debug proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== TRACE ==="* ]]
    # PS4 carries file:line, so trace lines must contain source coords.
    [[ "$output" == *"[trace] + pre-commit:"* ]]
}

@test "hook_debug: --no-trace suppresses xtrace output" {
    src "ac_registry_upsert proj '$R' scripts ''"
    write_hook 'echo plain'

    run src "ac_hook_debug proj --no-trace"
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode      : plain (no xtrace)"* ]]
    [[ "$output" != *"=== TRACE ==="* ]]
    [[ "$output" == *"[out] plain"* ]]
}

@test "hook_debug: appends a labeled block to .git/antcrate-hook.log" {
    src "ac_registry_upsert proj '$R' scripts ''"
    write_hook 'echo aaa; exit 0'

    run src "ac_hook_debug proj"
    [ "$status" -eq 0 ]
    [ -f "$R/.git/antcrate-hook.log" ]
    grep -q "antcrate hook-debug" "$R/.git/antcrate-hook.log"
    grep -q "exit=0" "$R/.git/antcrate-hook.log"
}

@test "hook_debug: missing hook returns nonzero with friendly notice" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_debug proj"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing to debug"* ]] || [[ "$output" == *"not present"* ]]
    # No audit entry should be appended for a no-such-hook case.
    [ ! -f "$ANTCRATE_HOME/hooks.log" ] || ! grep -q '"action":"hook-debug"' "$ANTCRATE_HOME/hooks.log"
}

@test "hook_debug: refuses unknown project" {
    run src "ac_hook_debug ghost"
    [ "$status" -ne 0 ]
}

@test "hook_debug: refuses non-git path" {
    NOT="$BATS_TEST_TMPDIR/notgit"
    mkdir -p "$NOT"
    src "ac_registry_upsert nogit '$NOT' scripts ''"
    run src "ac_hook_debug nogit"
    [ "$status" -ne 0 ]
}

@test "hook_debug: respects core.hooksPath" {
    src "ac_registry_upsert proj '$R' scripts ''"
    mkdir -p "$R/.githooks"
    (cd "$R" && git config core.hooksPath .githooks)
    cat > "$R/.githooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo from-custom-hooksdir
EOF
    chmod +x "$R/.githooks/pre-commit"

    run src "ac_hook_debug proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[out] from-custom-hooksdir"* ]]
    [[ "$output" == *".githooks/pre-commit"* ]]
}

@test "hook_debug: --with-stash creates+pops a stash; hook sees staged set only" {
    src "ac_registry_upsert proj '$R' scripts ''"
    # Establish a baseline commit so stash has a parent.
    (
        cd "$R"
        echo "v1" > tracked.txt
        git add tracked.txt
        git -c user.email=t@e -c user.name=t commit -q -m init
    )
    # Hook prints both files so we can assert what state the worktree had.
    write_hook 'echo "staged: $(cat staged-only.txt 2>/dev/null || echo MISSING)"; echo "unstaged: $(cat unstaged-only.txt 2>/dev/null || echo MISSING)"'

    # One new staged file + one new unstaged file in separate paths so a
    # `git stash pop` can replay cleanly without merge conflict.
    (
        cd "$R"
        echo "STAGED-CONTENT" > staged-only.txt
        git add staged-only.txt
        echo "UNSTAGED-CONTENT" > unstaged-only.txt
    )
    # Sanity: unstaged file present pre-debug.
    [ -f "$R/unstaged-only.txt" ]

    pre_count=$(git -C "$R" stash list | wc -l)
    run src "ac_hook_debug proj --with-stash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stash     : pushed"* ]]
    # Hook should have seen staged file but NOT the unstaged file.
    [[ "$output" == *"[out] staged: STAGED-CONTENT"* ]]
    [[ "$output" == *"[out] unstaged: MISSING"* ]]

    # After the run, stash should have been popped (count back to baseline)
    # and the unstaged file restored to the working tree.
    post_count=$(git -C "$R" stash list | wc -l)
    [ "$pre_count" = "$post_count" ]
    [ -f "$R/unstaged-only.txt" ]
    grep -q "UNSTAGED-CONTENT" "$R/unstaged-only.txt"

    # Audit entry carries the stash refspec in the backup field.
    grep -q '"action":"hook-debug"' "$ANTCRATE_HOME/hooks.log"
    grep -q '"backup":"stash:antcrate-hook-debug-' "$ANTCRATE_HOME/hooks.log"
}

@test "hook_debug: --with-stash overlapping edits — pop conflict warned, stash preserved" {
    src "ac_registry_upsert proj '$R' scripts ''"
    # Baseline commit.
    (
        cd "$R"
        echo "v1" > tracked.txt
        git add tracked.txt
        git -c user.email=t@e -c user.name=t commit -q -m init
    )
    write_hook 'echo "snapshot: $(cat tracked.txt | tr "\n" " ")"'

    # Staged change + overlapping unstaged change on the same file — this is
    # the case git stash pop cannot reapply cleanly after --keep-index.
    (
        cd "$R"
        echo "v2-staged" >> tracked.txt
        git add tracked.txt
        echo "v3-unstaged" >> tracked.txt
    )

    run src "ac_hook_debug proj --with-stash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stash     : pushed"* ]]
    # During the run, hook saw the staged state only (no v3-unstaged).
    [[ "$output" == *"v2-staged"* ]]
    [[ "$output" != *"v3-unstaged"* ]]
    # Warning surfaces about pop failure; the stash is preserved so the user
    # can resolve manually.
    [[ "$output" == *"stash pop failed"* ]]
    [ "$(git -C "$R" stash list | wc -l)" -ge 1 ]
}

@test "hook_debug: --with-stash is a no-op when there are no local changes" {
    src "ac_registry_upsert proj '$R' scripts ''"
    write_hook 'exit 0'

    run src "ac_hook_debug proj --with-stash"
    [ "$status" -eq 0 ]
    [[ "$output" == *"stash     : requested, no local changes to save"* ]]
}

@test "hook_debug: explicit hook name targets the named file" {
    src "ac_registry_upsert proj '$R' scripts ''"
    cat > "$R/.git/hooks/post-commit" <<'EOF'
#!/usr/bin/env bash
echo from-post-commit
EOF
    chmod +x "$R/.git/hooks/post-commit"

    run src "ac_hook_debug proj post-commit"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hook      : post-commit"* ]]
    [[ "$output" == *"[out] from-post-commit"* ]]
}

@test "hook_debug: JSONL audit entry is well-formed (jq-parseable)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    write_hook 'exit 0'

    run src "ac_hook_debug proj"
    [ "$status" -eq 0 ]
    while IFS= read -r line; do
        echo "$line" | jq -e '.ts and .action and .project and .hook and .sha256' >/dev/null
    done < "$ANTCRATE_HOME/hooks.log"
}

# ---------- ac_hook_bypass ----------

@test "hook_bypass: writes flag with structured JSON + audits with reason" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_bypass proj --reason 'hook broken for unrelated cause'"
    [ "$status" -eq 0 ]
    [ -f "$R/.git/antcrate-hook-bypass" ]
    # Flag is well-formed JSON with the expected fields.
    jq -e '.ts and .reason and .project' "$R/.git/antcrate-hook-bypass" >/dev/null
    [ "$(jq -r '.reason' "$R/.git/antcrate-hook-bypass")" = "hook broken for unrelated cause" ]
    [ "$(jq -r '.project' "$R/.git/antcrate-hook-bypass")" = "proj" ]
    # Audit row with action=hook-bypass + reason payload in `backup` field.
    grep -q '"action":"hook-bypass"' "$ANTCRATE_HOME/hooks.log"
    grep -q '"backup":"reason:hook broken for unrelated cause"' "$ANTCRATE_HOME/hooks.log"
}

@test "hook_bypass: refuses without --reason (audit invariant)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_hook_bypass proj"
    [ "$status" -ne 0 ]
    [ ! -f "$R/.git/antcrate-hook-bypass" ]
    # No audit row written when validation refuses.
    [ ! -f "$ANTCRATE_HOME/hooks.log" ] || ! grep -q '"action":"hook-bypass"' "$ANTCRATE_HOME/hooks.log"
}

@test "hook_bypass: refuses unknown project" {
    run src "ac_hook_bypass ghost --reason 'x'"
    [ "$status" -ne 0 ]
}

@test "hook_bypass: refuses non-git path" {
    NOT="$BATS_TEST_TMPDIR/notgit"
    mkdir -p "$NOT"
    src "ac_registry_upsert nogit '$NOT' scripts ''"
    run src "ac_hook_bypass nogit --reason 'x'"
    [ "$status" -ne 0 ]
}

@test "hook_bypass: refuses when flag already present (no silent overwrite)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_bypass proj --reason 'first'"
    [ -f "$R/.git/antcrate-hook-bypass" ]
    run src "ac_hook_bypass proj --reason 'second'"
    [ "$status" -ne 0 ]
    # First bypass's payload preserved — second call did not overwrite.
    [ "$(jq -r '.reason' "$R/.git/antcrate-hook-bypass")" = "first" ]
}

# Helper: run an installed hook the way git would — from repo root cwd so
# `git diff --cached` and `git rev-parse --git-dir` resolve correctly.
run_hook_from_repo() {
    local hook="$1"
    ( cd "$R" && bash ".git/hooks/$hook" )
}

@test "hook_bypass: rendered hook consumes the flag, logs to both sinks, exits 0" {
    src "ac_registry_upsert proj '$R' scripts ''"
    # Install a hook that WOULD fail (exit 1) if it ran past the bypass-check.
    src "ac_hook_install proj pre-commit-secrets"
    # Cause the underlying check to fail by staging a secret-pattern file.
    (
        cd "$R"
        echo "AWS_KEY=fake" > .env
        git add -f .env
    )
    # Without bypass: hook should refuse (run from repo root, like git does).
    run run_hook_from_repo pre-commit
    [ "$status" -ne 0 ]

    # Issue bypass, then re-run the hook.
    src "ac_hook_bypass proj --reason 'underlying check intentionally tripped for test'"
    [ -f "$R/.git/antcrate-hook-bypass" ]

    run run_hook_from_repo pre-commit
    [ "$status" -eq 0 ]
    # Flag was consumed.
    [ ! -f "$R/.git/antcrate-hook-bypass" ]
    # Per-project hook.log line names the reason.
    grep -q "BYPASSED via antcrate --hook-bypass" "$R/.git/antcrate-hook.log"
    grep -q "reason=underlying check intentionally tripped for test" "$R/.git/antcrate-hook.log"
    # Per-project audit log line names the project + hook + reason.
    grep -q "hook-bypass-consumed project=proj hook=pre-commit reason=underlying check intentionally tripped for test" \
        "$R/.git/antcrate-hook-audit.log"
}

@test "hook_bypass: flag is single-shot, second hook run executes normally" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    (
        cd "$R"
        echo "x" > .env
        git add -f .env
    )
    src "ac_hook_bypass proj --reason 'one-shot test'"
    # First run consumes the flag.
    run run_hook_from_repo pre-commit
    [ "$status" -eq 0 ]
    [ ! -f "$R/.git/antcrate-hook-bypass" ]
    # Second run has no flag — the underlying check fires and fails.
    run run_hook_from_repo pre-commit
    [ "$status" -ne 0 ]
}

@test "hook_bypass: rendered hook handles a flag with no JSON reason field gracefully" {
    src "ac_registry_upsert proj '$R' scripts ''"
    src "ac_hook_install proj pre-commit-secrets"
    # Write a bare flag with no JSON. The consume snippet falls back to tr.
    echo "manual-touch" > "$R/.git/antcrate-hook-bypass"
    run run_hook_from_repo pre-commit
    [ "$status" -eq 0 ]
    [ ! -f "$R/.git/antcrate-hook-bypass" ]
    grep -q "BYPASSED via antcrate --hook-bypass" "$R/.git/antcrate-hook.log"
}

# ---------- ac_hook_debug (continued) ----------

# ---------- ac_hook_render ----------

@test "hook_render: emits rendered pre-commit-secrets template to stdout" {
    run src "ac_hook_render pre-commit-secrets testproj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"#!/"* ]]
    [[ "$output" == *"testproj"* ]]
}

@test "hook_render: substitutes __PROJECT_NAME__" {
    run src "ac_hook_render pre-commit-secrets myproj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproj"* ]]
    [[ "$output" != *"__PROJECT_NAME__"* ]]
}

@test "hook_render: injects bypass-check block at the marker" {
    run src "ac_hook_render pre-commit-secrets myproj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"antcrate-hook-bypass"* ]]
    [[ "$output" != *"# __ANTCRATE_BYPASS_CHECK__"* ]]
}

@test "hook_render: substitutes __ANTCRATE_BIN__" {
    run src "ac_hook_render pre-commit-secrets myproj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"antcrate"* ]]
    [[ "$output" != *"__ANTCRATE_BIN__"* ]]
}

@test "hook_render: refuses unknown template" {
    run src "ac_hook_render no-such-template myproj"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown template"* ]]
}

@test "hook_render: project arg is optional (defaults to EXAMPLE_PROJECT)" {
    run src "ac_hook_render pre-commit-secrets"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXAMPLE_PROJECT"* ]]
}

# ---------- ac_hook_audit ----------

@test "hook_audit: prints all three section headers when sinks exist" {
    src "ac_registry_upsert proj '$R' scripts ''"

    # Populate global JSONL sink with one entry for this project.
    mkdir -p "$ANTCRATE_HOME"
    printf '{"ts":"2026-01-01T00:00:00Z","ts_ms":0,"action":"hook-remove","project":"proj","hook":"pre-commit","hooks_dir":"%s/.git/hooks","sha256":"abc","backup":"bak"}\n' \
        "$R" >> "$ANTCRATE_HOME/hooks.log"

    # Populate per-project plain audit log.
    mkdir -p "$R/.git"
    printf '2026-01-01T00:00:00Z hook-remove project=proj hook=pre-commit sha256=abc backup=bak\n' \
        >> "$R/.git/antcrate-hook-audit.log"

    # Populate human-readable hook log.
    printf '%s\n' '--- antcrate hook-debug 2026-01-01T00:00:00Z ---' \
        >> "$R/.git/antcrate-hook.log"

    run src "ac_hook_audit proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== antcrate hook-audit: proj ==="* ]]
    [[ "$output" == *"--- [1/3] global JSONL"* ]]
    [[ "$output" == *"--- [2/3] per-project audit"* ]]
    [[ "$output" == *"--- [3/3] human-readable hook log"* ]]
    [[ "$output" == *'"action":"hook-remove"'* ]]
    [[ "$output" == *"hook-remove project=proj"* ]]
    [[ "$output" == *"antcrate hook-debug"* ]]
}

@test "hook_audit: friendly notice when sinks absent (no error)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    # No hooks.log, no audit log, no hook.log — all three sinks absent.
    run src "ac_hook_audit proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no entries (global hooks.log not yet present)"* ]]
    [[ "$output" == *"no entries"* ]]
    [[ "$output" == *"no log yet"* ]]
}

@test "hook_audit: caps lines per sink via N argument" {
    src "ac_registry_upsert proj '$R' scripts ''"
    mkdir -p "$R/.git"
    # Write 6 lines to the per-project audit log.
    for i in 1 2 3 4 5 6; do
        printf '2026-01-01T00:0%s:00Z hook-debug project=proj hook=pre-commit sha256=x%s backup=\n' \
            "$i" "$i" >> "$R/.git/antcrate-hook-audit.log"
    done

    run src "ac_hook_audit proj 3"
    [ "$status" -eq 0 ]
    # Count lines in the per-project section that contain "hook-debug project=proj".
    local count
    count=$(printf '%s\n' "$output" | grep -c "hook-debug project=proj")
    [ "$count" -eq 3 ]
}

@test "hook_audit: filters global JSONL to the named project" {
    src "ac_registry_upsert proj '$R' scripts ''"
    mkdir -p "$ANTCRATE_HOME"
    # Write one entry for this project and one for a different project.
    printf '{"ts":"2026-01-01T00:00:00Z","ts_ms":0,"action":"hook-remove","project":"proj","hook":"pre-commit","hooks_dir":"/x","sha256":"a","backup":"b"}\n' \
        >> "$ANTCRATE_HOME/hooks.log"
    printf '{"ts":"2026-01-01T00:00:01Z","ts_ms":1,"action":"hook-remove","project":"other","hook":"pre-commit","hooks_dir":"/y","sha256":"c","backup":"d"}\n' \
        >> "$ANTCRATE_HOME/hooks.log"

    run src "ac_hook_audit proj"
    [ "$status" -eq 0 ]
    # The proj entry appears.
    [[ "$output" == *'"project":"proj"'* ]]
    # The other-project entry must NOT appear anywhere in the JSONL section.
    [[ "$output" != *'"project":"other"'* ]]
}

@test "hook_audit: refuses unknown project" {
    run src "ac_hook_audit ghost"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown project"* ]]
}

@test "hook_debug: --with-stash pops even when downstream pipe closes early (SIGPIPE)" {
    # Regression for an outage where the smoke test piped --hook-debug output
    # through `head -14`, the closed pipe SIGPIPE'd a mid-trace printf, set -e
    # aborted the function BEFORE `git stash pop`, and the user's WIP was
    # stranded in stash@{0}. Fix: cleanup (pop + audit + hook.log append) runs
    # in a file-only section before any pipe-sensitive print; subsequent
    # prints live in `( ... ) || true` subshells.
    src "ac_registry_upsert proj '$R' scripts ''"
    (
        cd "$R"
        echo v1 > tracked.txt
        git add tracked.txt
        git -c user.email=t@e -c user.name=t commit -q -m init
    )
    # Emit lots of trace lines so the pipe closes deep into the output.
    write_hook 'for i in 1 2 3 4 5 6 7 8 9 10; do echo "line-$i"; done'

    # Untracked file so stash captures something with a clean pop path.
    echo "untracked-payload" > "$R/untracked-only.txt"

    pre_count=$(git -C "$R" stash list | wc -l)
    # Drive the function under the same constraints the wrapper imposes
    # (set -euo pipefail) and pipe to `head -2` so the pipe closes very early.
    run bash -c '
        set -euo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL=error
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/hooks.sh"
        ac_hook_debug proj --with-stash | head -2
    '
    [ "$status" -eq 0 ]

    # Critical invariant: stash count back to baseline (pop ran despite SIGPIPE).
    post_count=$(git -C "$R" stash list | wc -l)
    [ "$pre_count" = "$post_count" ]
    # Untracked file restored to working tree.
    [ -f "$R/untracked-only.txt" ]
    grep -q "untracked-payload" "$R/untracked-only.txt"
    # Audit log entry still written (audit runs in the file-only section).
    grep -q '"action":"hook-debug"' "$ANTCRATE_HOME/hooks.log"
}
