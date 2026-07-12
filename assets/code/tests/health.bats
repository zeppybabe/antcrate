#!/usr/bin/env bats
# tests for lib/health.sh — the `st` doctor (no separate command by design:
# owner directive 2026-07-11, "fewer commands, more information per command")

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_CONFIG="$ANTCRATE_HOME/config"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/Projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_BIN_DIR="$BATS_TEST_TMPDIR/bin"
    export ANTCRATE_TOOLS_BIN="$BATS_TEST_TMPDIR/tools/bin"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT" "$ANTCRATE_BIN_DIR" "$ANTCRATE_TOOLS_BIN"
    : > "$ANTCRATE_CONFIG"
    echo '{}' > "$ANTCRATE_REGISTRY"
    printf '#!/usr/bin/env bash\n' > "$ANTCRATE_BIN_DIR/antcrate"
    chmod +x "$ANTCRATE_BIN_DIR/antcrate"
    # stub PATH: our fake bin first, plus coreutils; NO systemctl/gh/git stubs yet
    STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
    export HEALTH_PATH="$ANTCRATE_BIN_DIR:$STUBS:/usr/bin:/bin"
}

run_health() {
    bash -c "
        export PATH='$HEALTH_PATH'
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_CONFIG='$ANTCRATE_CONFIG'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT' ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_BIN_DIR='$ANTCRATE_BIN_DIR' ANTCRATE_TOOLS_BIN='$ANTCRATE_TOOLS_BIN'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'; . '$LIB/health.sh'
        $1
    "
}

@test "checks: emits req rows for path/wrapper/config/root/registry" {
    run run_health "ac_health_checks"
    [ "$status" -eq 0 ]
    for name in path wrapper config root registry; do
        [[ "$output" == *"req	$name	"* ]]
    done
}

@test "checks: all-good env has zero miss rows in req set" {
    run run_health "ac_health_checks | awk -F'\t' '\$1==\"req\" && \$3==\"miss\"'"
    [ -z "$output" ]
}

@test "checks: missing root is a miss with a fix command" {
    rmdir "$ANTCRATE_ROOT"
    run run_health "ac_health_checks | awk -F'\t' '\$2==\"root\"'"
    [[ "$output" == *"miss"* ]]
    [[ "$output" == *"antcrate --init"* ]]
}

@test "checks: BIN_DIR absent from PATH is a miss naming the export fix" {
    HEALTH_PATH="/usr/bin:/bin"
    run run_health "ac_health_checks | awk -F'\t' '\$2==\"path\"'"
    [[ "$output" == *"miss"* ]]
    [[ "$output" == *"export PATH="* ]]
}

@test "checks: no systemctl on PATH -> timer rows are skip, not miss" {
    HEALTH_PATH="$ANTCRATE_BIN_DIR:$BATS_TEST_TMPDIR/stubs"   # no coreutils either
    run run_health "ac_health_checks"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\t'"timer-backup"$'\t'"skip"* ]]
    [[ "$output" != *$'\t'"timer-backup"$'\t'"miss"* ]]
}

@test "checks: disabled timer (stubbed systemctl) is an opt miss with enable fix" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/stubs/systemctl"
    chmod +x "$BATS_TEST_TMPDIR/stubs/systemctl"
    run run_health "ac_health_checks | awk -F'\t' '\$2==\"timer-backup\"'"
    [[ "$output" == *"opt	timer-backup	miss"* ]]
    [[ "$output" == *"systemctl --user enable --now antcrate-backup.timer"* ]]
}

@test "checks: missing dev tool is an opt miss pointing at tool install" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/stubs/systemctl"
    chmod +x "$BATS_TEST_TMPDIR/stubs/systemctl"
    run run_health "ac_health_checks | awk -F'\t' '\$2==\"tools\"'"
    [[ "$output" == *"antcrate tool install"* ]]
}

@test "status line: clean env says OK with check count" {
    # make everything pass: stub systemctl ok, gh with token, git identity, tools
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/stubs/systemctl"
    printf '#!/usr/bin/env bash\n[ "$1" = auth ] && { echo tok; exit 0; }\nexit 0\n' \
        > "$BATS_TEST_TMPDIR/stubs/gh"
    printf '#!/usr/bin/env bash\necho someone\nexit 0\n' > "$BATS_TEST_TMPDIR/stubs/git"
    chmod +x "$BATS_TEST_TMPDIR/stubs/"*
    for t in bats shellcheck gitleaks; do
        printf '#!/usr/bin/env bash\n' > "$ANTCRATE_TOOLS_BIN/$t"
        chmod +x "$ANTCRATE_TOOLS_BIN/$t"
    done
    run run_health "ac_health_status_line"
    [ "$status" -eq 0 ]
    [[ "$output" == "health: OK ("*" checks)" ]]
}

@test "status line: misses are listed with name, detail and fix" {
    rmdir "$ANTCRATE_ROOT"
    run run_health "ac_health_status_line"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "health: "*"issue"* ]]
    [[ "$output" == *"root"*"fix: "* ]]
}

@test "status line: optional misses are marked (opt)" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/stubs/systemctl"
    chmod +x "$BATS_TEST_TMPDIR/stubs/systemctl"
    run run_health "ac_health_status_line"
    [[ "$output" == *"(opt)"* ]]
}

# ---- darwin (launchd) branch — forced via AC_OS, launchctl PATH stub ----

run_health_darwin() {
    bash -c "
        export PATH='$HEALTH_PATH'
        export AC_OS=darwin
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_CONFIG='$ANTCRATE_CONFIG'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT' ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_BIN_DIR='$ANTCRATE_BIN_DIR' ANTCRATE_TOOLS_BIN='$ANTCRATE_TOOLS_BIN'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'; . '$LIB/health.sh'
        $1
    "
}

@test "checks darwin: unloaded launchd timer is an opt miss with bootstrap fix" {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS_TEST_TMPDIR/stubs/launchctl"
    chmod +x "$BATS_TEST_TMPDIR/stubs/launchctl"
    run run_health_darwin "ac_health_checks | awk -F'\t' '\$2==\"timer-backup\"'"
    [[ "$output" == *"opt	timer-backup	miss"* ]]
    [[ "$output" == *"launchctl bootstrap"* ]]
    [[ "$output" == *"com.antcrate.backup.plist"* ]]
}

@test "checks darwin: loaded launchd timer is ok" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/stubs/launchctl"
    chmod +x "$BATS_TEST_TMPDIR/stubs/launchctl"
    run run_health_darwin "ac_health_checks | awk -F'\t' '\$2==\"timer-intel\"'"
    [[ "$output" == *"opt	timer-intel	ok"* ]]
}

@test "checks darwin: missing gh hint is brew, not apt" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/stubs/launchctl"
    chmod +x "$BATS_TEST_TMPDIR/stubs/launchctl"
    run run_health_darwin "ac_health_checks | awk -F'\t' '\$2==\"gh\"'"
    if [[ "$output" == *"miss"* ]]; then
        [[ "$output" == *"brew install gh"* ]]
        [[ "$output" != *"apt"* ]]
    else
        [[ "$output" == *"ok"* ]]   # gh genuinely on the restricted PATH
    fi
}
