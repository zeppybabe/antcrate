#!/usr/bin/env bats
# tests for install.sh's retired-lib prune.
#
# Found 2026-07-27 on a live box: `antcrate st` reported
#   wrapper : installed copy is BEHIND source (5 retired lib still installed)
#             — fix: antcrate self install
# and running that fix changed nothing, because install.sh only ever COPIES
# libs forward. canary.sh, cost.sh, delegate.sh, loop.sh and obsidian.sh had
# left the source months earlier and were still sitting in the install, still
# loadable. The doctor named a command that structurally could not work — the
# same defect class as `rm <ghost>` dead-ending instead of naming `deregister`.
#
# Dead code that still loads is drift in the dangerous direction: a stale lib
# can shadow nothing today and shadow something after the next rename.

setup() {
    SRC="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    export PREFIX="$HOME/.local"
    export ANTCRATE_DATA_HOME="$HOME/.local/share/antcrate"
    export ANTCRATE_STATE_HOME="$HOME/.local/state/antcrate"
    export ANTCRATE_CONFIG_HOME="$HOME/.config/antcrate"
    mkdir -p "$HOME"
    LIB_DIR="$ANTCRATE_DATA_HOME/lib"
}

install_now() {
    run env HOME="$HOME" PREFIX="$PREFIX" \
        ANTCRATE_DATA_HOME="$ANTCRATE_DATA_HOME" \
        ANTCRATE_STATE_HOME="$ANTCRATE_STATE_HOME" \
        ANTCRATE_CONFIG_HOME="$ANTCRATE_CONFIG_HOME" \
        bash "$SRC/install.sh"
}

@test "install: copies the source libs in" {
    install_now
    [ "$status" -eq 0 ]
    [ -f "$LIB_DIR/registry.sh" ]
    [ -f "$LIB_DIR/scan.sh" ]
}

@test "install: removes an installed lib that no longer exists in the source" {
    install_now
    [ "$status" -eq 0 ]
    echo '# retired months ago' > "$LIB_DIR/obsolete_thing.sh"
    [ -f "$LIB_DIR/obsolete_thing.sh" ]

    install_now
    [ "$status" -eq 0 ]
    [ ! -e "$LIB_DIR/obsolete_thing.sh" ]
}

@test "install: the prune reports what it removed" {
    install_now
    echo '# retired' > "$LIB_DIR/obsolete_thing.sh"
    install_now
    [[ "$output" == *"obsolete_thing.sh"* ]]
}

@test "install: the prune leaves current libs alone" {
    install_now
    echo '# retired' > "$LIB_DIR/obsolete_thing.sh"
    install_now
    [ -f "$LIB_DIR/registry.sh" ]
    [ -f "$LIB_DIR/devsync.sh" ]
    [ -f "$LIB_DIR/quarantine.sh" ]
}

# The prune must not reach outside the install lib dir, and must not eat
# non-.sh payload that lives there on purpose.
@test "install: the prune ignores subdirectories" {
    install_now
    [ -d "$LIB_DIR/targets" ]
    install_now
    [ -d "$LIB_DIR/targets" ]
}

@test "install: the prune ignores non-.sh files in the lib dir" {
    install_now
    echo 'data' > "$LIB_DIR/notes.txt"
    install_now
    [ -f "$LIB_DIR/notes.txt" ]
}

@test "install: a symlinked lib pointing outside is removed as a link, not followed" {
    install_now
    echo 'precious' > "$BATS_TEST_TMPDIR/outside.sh"
    ln -s "$BATS_TEST_TMPDIR/outside.sh" "$LIB_DIR/obsolete_link.sh"

    install_now
    [ "$status" -eq 0 ]
    [ ! -e "$LIB_DIR/obsolete_link.sh" ]
    [ "$(cat "$BATS_TEST_TMPDIR/outside.sh")" = "precious" ]
}

@test "install: a second run with nothing retired prunes nothing" {
    install_now
    install_now
    [ "$status" -eq 0 ]
    [[ "$output" != *"retired lib"* ]]
}
