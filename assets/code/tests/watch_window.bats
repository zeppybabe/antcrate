#!/usr/bin/env bats
# tests for ac_watch_window in lib/watch_window.sh — spawn mocked via PATH shim

load test_helper

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT" "$BATS_TEST_TMPDIR/bin"
    P="$ANTCRATE_ROOT/mybun"
    mkdir -p "$P"
    src "ac_registry_init; ac_registry_upsert mybun '$P' projects \"\""
    export P
}

src() {
    bash -c '
        set -eo pipefail
        export AC_OS="'"${TEST_AC_OS:-linux}"'"
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export PATH="'"$BATS_TEST_TMPDIR"'/bin:'"$PATH"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/watch_window.sh"
        '"$1"
}

install_mock_alacritty() {
    # Mock alacritty: records args, then sleeps so it appears alive via kill -0.
    cat > "$BATS_TEST_TMPDIR/bin/alacritty" <<'ALACRITTY'
#!/usr/bin/env bash
echo "$@" > "$BATS_TEST_TMPDIR/alacritty.args"
exec sleep 30
ALACRITTY
    # setsid must also be available; use the real one if present, else stub
    if ! command -v setsid >/dev/null 2>&1; then
        cat > "$BATS_TEST_TMPDIR/bin/setsid" <<'SETSID'
#!/usr/bin/env bash
exec "$@"   # setsid's args ARE the command; exec them as-is
SETSID
        chmod +x "$BATS_TEST_TMPDIR/bin/setsid"
    fi
    # Replace BATS_TEST_TMPDIR placeholder in the alacritty script
    t_sed_i "s|\$BATS_TEST_TMPDIR|$BATS_TEST_TMPDIR|g" "$BATS_TEST_TMPDIR/bin/alacritty"
    chmod +x "$BATS_TEST_TMPDIR/bin/alacritty"
    # Stub antcrate binary so -e arg resolves
    cat > "$BATS_TEST_TMPDIR/bin/antcrate" <<'ANTCRATE'
#!/usr/bin/env bash
exec sleep 30
ANTCRATE
    chmod +x "$BATS_TEST_TMPDIR/bin/antcrate"
}

kill_mock_alacritty() {
    local pid_file="$ANTCRATE_HOME/watch/mybun.pid"
    [[ -f "$pid_file" ]] || return 0
    local pid; pid=$(< "$pid_file")
    kill "$pid" 2>/dev/null || true
}

@test "watch-window: refuses unknown project with exit 1" {
    install_mock_alacritty
    run src "ac_watch_window ghost_project"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown"* ]] || [[ "$output" == *"ghost_project"* ]]
}

@test "watch-window: unknown terminal exits 2 with clear error" {
    install_mock_alacritty
    run src "ac_watch_window mybun --terminal xterm_fake"
    [ "$status" -eq 2 ]
    [[ "$output" == *"xterm_fake"* ]]
}

@test "watch-window: creates PID file with numeric PID after spawn" {
    install_mock_alacritty
    run src "ac_watch_window mybun"
    [ "$status" -eq 0 ]
    pid_file="$ANTCRATE_HOME/watch/mybun.pid"
    [ -f "$pid_file" ]
    pid=$(< "$pid_file")
    [[ "$pid" =~ ^[0-9]+$ ]]
    kill_mock_alacritty
}

@test "watch-window: spawn args contain --class, --title, -e with the watch word" {
    install_mock_alacritty
    src "ac_watch_window mybun"
    args_file="$BATS_TEST_TMPDIR/alacritty.args"
    # The mock writes args then exec-sleeps; wait up to 2s for the write
    local i=0
    until [[ -f "$args_file" ]] || (( i >= 20 )); do sleep 0.1; (( i++ )) || true; done
    [ -f "$args_file" ]
    content=$(< "$args_file")
    [[ "$content" == *"--class"* ]]
    [[ "$content" == *"ac-watch-mybun"* ]]
    [[ "$content" == *"--title"* ]]
    [[ "$content" == *"antcrate watch: mybun"* ]]
    [[ "$content" == *" watch mybun"* ]] || [[ "$content" == *" watch"*"mybun"* ]]
    kill_mock_alacritty
}

@test "watch-window: dedup — second call while alive prints 'already watching'" {
    install_mock_alacritty
    src "ac_watch_window mybun"
    run src "ac_watch_window mybun"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already watching mybun"* ]]
    kill_mock_alacritty
}

@test "watch-window: stale PID file is cleaned up and window re-spawned" {
    install_mock_alacritty
    pid_file="$ANTCRATE_HOME/watch/mybun.pid"
    mkdir -p "$ANTCRATE_HOME/watch"
    printf '99999999\n' > "$pid_file"
    run src "ac_watch_window mybun"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already watching"* ]]
    new_pid=$(< "$pid_file")
    [ "$new_pid" != "99999999" ]
    [[ "$new_pid" =~ ^[0-9]+$ ]]
    kill_mock_alacritty
}

@test "watch-window: PID file directory created on first invocation" {
    install_mock_alacritty
    rm -rf "$ANTCRATE_HOME/watch"
    run src "ac_watch_window mybun"
    [ "$status" -eq 0 ]
    [ -d "$ANTCRATE_HOME/watch" ]
    kill_mock_alacritty
}

@test "watch-window: after killing mock, next call re-spawns" {
    install_mock_alacritty
    src "ac_watch_window mybun"
    kill_mock_alacritty
    # Give the kernel a moment to mark the process dead
    sleep 0.1
    run src "ac_watch_window mybun"
    [ "$status" -eq 0 ]
    [[ "$output" != *"already watching"* ]]
    kill_mock_alacritty
}

@test "watch-window: --terminal alacritty explicit succeeds" {
    install_mock_alacritty
    run src "ac_watch_window mybun --terminal alacritty"
    [ "$status" -eq 0 ]
    kill_mock_alacritty
}

@test "watch-window: refuses when antcrate not on PATH and SELFSRC empty" {
    install_mock_alacritty
    rm -f "$BATS_TEST_TMPDIR/bin/antcrate"
    # Use a clean PATH containing only the mock dir + minimal coreutils,
    # so the system-installed antcrate (~/.local/bin/antcrate) is unreachable.
    run bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        unset ANTCRATE_SELFSRC
        export PATH="'"$BATS_TEST_TMPDIR"'/bin:/usr/bin:/bin"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/watch_window.sh"
        ac_watch_window mybun
    '
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot resolve antcrate"* ]]
}

# ---- terminal (macOS Terminal.app) backend — osascript mocked via PATH shim ----

install_mock_osascript() {
    cat > "$BATS_TEST_TMPDIR/bin/osascript" <<OSA
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$BATS_TEST_TMPDIR/osascript.args"
exit 0
OSA
    chmod +x "$BATS_TEST_TMPDIR/bin/osascript"
    cat > "$BATS_TEST_TMPDIR/bin/antcrate" <<'ANTCRATE'
#!/usr/bin/env bash
exec sleep 30
ANTCRATE
    chmod +x "$BATS_TEST_TMPDIR/bin/antcrate"
}

@test "watch-window darwin: terminal backend is the default and calls osascript" {
    install_mock_osascript
    TEST_AC_OS=darwin run src "ac_watch_window mybun"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Terminal.app"* ]]
    grep -q 'tell application "Terminal"' "$BATS_TEST_TMPDIR/osascript.args"
}

@test "watch-window darwin: launcher script records pid file and execs watch" {
    install_mock_osascript
    TEST_AC_OS=darwin run src "ac_watch_window mybun"
    [ "$status" -eq 0 ]
    local launcher="$ANTCRATE_HOME/watch/mybun.cmd"
    [ -x "$launcher" ]
    grep -q "watch/mybun.pid" "$launcher"
    grep -q 'watch "mybun"' "$launcher"
}

@test "watch-window darwin: alacritty still selectable explicitly" {
    install_mock_alacritty
    TEST_AC_OS=darwin run src "ac_watch_window mybun --terminal alacritty"
    [ "$status" -eq 0 ]
    [[ "$output" == *"alacritty"* ]]
    kill_mock_alacritty
}

@test "watch-window darwin: missing osascript is a clean error" {
    # osascript lives in /usr/bin, so hide /usr/bin — but keep jq (registry)
    # and the antcrate stub reachable via the shim dir
    install_mock_osascript
    rm "$BATS_TEST_TMPDIR/bin/osascript"
    ln -sf "$(command -v jq)" "$BATS_TEST_TMPDIR/bin/jq"
    TEST_AC_OS=darwin run src "PATH='$BATS_TEST_TMPDIR/bin:/bin'; ac_watch_window mybun"
    [ "$status" -eq 1 ]
    [[ "$output" == *"osascript"* ]]
}
