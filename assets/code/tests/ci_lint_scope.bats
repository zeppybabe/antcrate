#!/usr/bin/env bats
# tests for what `self ci` actually hands to shellcheck (audit 2026-07-25,
# finding C).
#
# ci linted lib/, both bins and install.sh — and nothing else. That left the
# entire Claude Code hook tree unlinted: hooks/claude/ is the source of truth
# for the plugin's security guards, and plugin/hooks/session-digest.sh sits
# outside the code tree altogether. Real shellcheck warnings were sitting in
# both when this was found. The generated copies under plugin/hooks/claude are
# covered by `self plugin --check`, so linting the source of truth covers both.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"

    TOOLS_BIN="$BATS_TEST_TMPDIR/tools/bin"
    FAKE_PATH="$BATS_TEST_TMPDIR/fakepath"
    ARGS_LOG="$BATS_TEST_TMPDIR/shellcheck-args.log"
    mkdir -p "$TOOLS_BIN" "$FAKE_PATH"
    mk_fake_path
    # full repo shape: <repo>/assets/code plus <repo>/plugin/hooks
    REPO="$BATS_TEST_TMPDIR/repo"
    SRC="$REPO/assets/code"
    mk_repo
    mk_arg_shim "$TOOLS_BIN" shellcheck
    mk_arg_shim "$TOOLS_BIN" bats
}

mk_fake_path() {
    local n p
    for n in jq git date sed grep cut head sort cat mkdir rm printf env bash uname stat; do
        p=$(command -v "$n" 2>/dev/null) && ln -sf "$p" "$FAKE_PATH/$n"
    done
}

mk_repo() {
    mkdir -p "$SRC/lib" "$SRC/tests" "$SRC/bin" "$SRC/hooks/claude" "$REPO/plugin/hooks"
    printf '#!/usr/bin/env bash\n:\n' > "$SRC/lib/stub.sh"
    printf '#!/usr/bin/env bash\n:\n' > "$SRC/bin/antcrate"
    printf '#!/usr/bin/env bash\n:\n' > "$SRC/bin/antcrated"
    printf '#!/usr/bin/env bash\n:\n' > "$SRC/install.sh"
    printf '#!/usr/bin/env bash\n:\n' > "$SRC/hooks/claude/some-guard.sh"
    printf '#!/usr/bin/env bash\n:\n' > "$REPO/plugin/hooks/session-digest.sh"
}

# shim that records the arguments it was called with
mk_arg_shim() {
    local dir="$1" name="$2"
    cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$ARGS_LOG"
[ "\${1:-}" = "--count" ] && echo 7
exit 0
EOF
    chmod +x "$dir/$name"
}

run_ci() {
    PATH="$FAKE_PATH" \
    ANTCRATE_TOOLS_BIN="$TOOLS_BIN" \
    ANTCRATE_HOME="$ANTCRATE_HOME" \
    ANTCRATE_REGISTRY="$ANTCRATE_REGISTRY" \
    ANTCRATE_ROOT="$ANTCRATE_ROOT" \
    ANTCRATE_LOG_LEVEL="$ANTCRATE_LOG_LEVEL" \
    ANTCRATE_CANARY_DISABLE=1 \
    "$BASH" -c "
        . '$LIB/log.sh'
        . '$LIB/registry.sh'
        . '$LIB/devops.sh'
        ac_devops_ci --source '$SRC'
    "
}

@test "ci lint scope: the source-of-truth hook tree is linted" {
    run run_ci
    [ "$status" -eq 0 ]
    grep -qF "$SRC/hooks/claude/some-guard.sh" "$ARGS_LOG"
}

@test "ci lint scope: hand-written plugin hooks outside the code tree are linted" {
    run run_ci
    grep -qF "$REPO/plugin/hooks/session-digest.sh" "$ARGS_LOG"
}

@test "ci lint scope: libs and both binaries are still linted" {
    run run_ci
    grep -qF "$SRC/lib/stub.sh" "$ARGS_LOG"
    grep -qF "$SRC/bin/antcrate" "$ARGS_LOG"
    grep -qF "$SRC/bin/antcrated" "$ARGS_LOG"
    grep -qF "$SRC/install.sh" "$ARGS_LOG"
}

# A findings-free lint of a tree WITHOUT hooks must not break: the extra paths
# are added only when they exist, never as unexpanded globs.
@test "ci lint scope: a tree with no hook dirs passes no phantom paths" {
    rm -rf "$SRC/hooks" "$REPO/plugin"
    run run_ci
    [ "$status" -eq 0 ]
    ! grep -q '\*' "$ARGS_LOG"
}
