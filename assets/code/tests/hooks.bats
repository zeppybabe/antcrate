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
