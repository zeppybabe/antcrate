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
