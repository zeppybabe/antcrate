#!/usr/bin/env bats
# tests for the --ci pinned-toolchain contract in lib/devops.sh (duty 2026-07-18).
#
# Two properties, both about NOT reporting a hollow PASS:
#   1. `self ci` prepends $ANTCRATE_TOOLS_BIN, so the pinned shellcheck/bats
#      installed by `antcrate tool install` are found on a bare PATH.
#   2. A tool that is still missing after that is a hard FAIL, never a warn-and-skip.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"

    TOOLS_BIN="$BATS_TEST_TMPDIR/tools/bin"
    SRC="$BATS_TEST_TMPDIR/src"
    FAKE_PATH="$BATS_TEST_TMPDIR/fakepath"
    mkdir -p "$TOOLS_BIN" "$FAKE_PATH"
    mk_src "$SRC"
    mk_fake_path
}

# A PATH with the utilities lib/devops.sh needs, but deliberately WITHOUT
# shellcheck or bats — that is the bare-PATH condition being tested.
mk_fake_path() {
    local n p
    for n in jq git date sed grep cut head sort cat mkdir rm printf env bash uname stat; do
        p=$(command -v "$n" 2>/dev/null) && ln -sf "$p" "$FAKE_PATH/$n"
    done
}

# minimal tree that passes ac_devops_ci_resolve_src
mk_src() {
    local d="$1"
    mkdir -p "$d/lib" "$d/tests" "$d/bin"
    printf '#!/usr/bin/env bash\n:\n' > "$d/lib/stub.sh"
    printf '#!/usr/bin/env bash\n:\n' > "$d/bin/antcrate"
    printf '#!/usr/bin/env bash\n:\n' > "$d/bin/antcrated"
    printf '#!/usr/bin/env bash\n:\n' > "$d/install.sh"
}

# a shim that always succeeds and records that it ran
mk_shim() {
    local dir="$1" name="$2"
    cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
echo "$name" >> "$BATS_TEST_TMPDIR/ran.log"
[ "\${1:-}" = "--count" ] && echo 7
exit 0
EOF
    chmod +x "$dir/$name"
}

# run ac_devops_ci against the fixture tree on the bare fake PATH
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

@test "ci: missing shellcheck and bats is a hard FAIL, not a skip" {
    run run_ci
    [ "$status" -ne 0 ]
    [[ "$output" == *"ci result: FAIL"* ]]
    [[ "$output" != *"ci result: PASS"* ]]
}

@test "ci: missing tool is named in the output with an install hint" {
    run run_ci
    [[ "$output" == *"shellcheck"* ]]
    [[ "$output" == *"bats"* ]]
    [[ "$output" == *"tool install"* ]]
}

@test "ci: finds shellcheck and bats in ANTCRATE_TOOLS_BIN on a bare PATH" {
    mk_shim "$TOOLS_BIN" shellcheck
    mk_shim "$TOOLS_BIN" bats
    run run_ci
    [ "$status" -eq 0 ]
    [[ "$output" == *"ci result: PASS"* ]]
    # non-vacuous: the shims in the tools bin are what actually ran
    [[ "$(cat "$BATS_TEST_TMPDIR/ran.log")" == *"shellcheck"* ]]
    [[ "$(cat "$BATS_TEST_TMPDIR/ran.log")" == *"bats"* ]]
}

@test "ci: one tool present and one missing still FAILs" {
    mk_shim "$TOOLS_BIN" bats
    run run_ci
    [ "$status" -ne 0 ]
    [[ "$output" == *"ci result: FAIL"* ]]
    [[ "$output" == *"shellcheck"* ]]
}

@test "ci: PATH prepend does not leak out of the function" {
    mk_shim "$TOOLS_BIN" shellcheck
    mk_shim "$TOOLS_BIN" bats
    run env PATH="$FAKE_PATH" \
        ANTCRATE_TOOLS_BIN="$TOOLS_BIN" \
        ANTCRATE_HOME="$ANTCRATE_HOME" \
        ANTCRATE_REGISTRY="$ANTCRATE_REGISTRY" \
        ANTCRATE_ROOT="$ANTCRATE_ROOT" \
        ANTCRATE_LOG_LEVEL=error \
        ANTCRATE_CANARY_DISABLE=1 \
        "$BASH" -c "
            . '$LIB/log.sh'
            . '$LIB/registry.sh'
            . '$LIB/devops.sh'
            ac_devops_ci --source '$SRC' >/dev/null 2>&1
            command -v shellcheck >/dev/null 2>&1 && echo LEAKED || echo CLEAN
        "
    [[ "$output" == *"CLEAN"* ]]
}
