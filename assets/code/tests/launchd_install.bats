#!/usr/bin/env bats
# Tests for install.sh's launchd rendering block (darwin branch): the three
# LaunchAgent plists must be rendered with every __PLACEHOLDER__ substituted.
# Runs the full installer in a sandboxed HOME, so it needs the real runtime
# deps (bash 4+, jq, git, a watcher) — skipped where those are absent.

setup() {
  SRC="$BATS_TEST_DIRNAME/.."
  export HOME="$BATS_TEST_TMPDIR/home"
  export ANTCRATE_LAUNCHD_DIR="$HOME/Library/LaunchAgents"
  mkdir -p "$HOME"
  # sandbox every antcrate location under the fake HOME
  unset ANTCRATE_HOME ANTCRATE_ROOT ANTCRATE_CONFIG ANTCRATE_REGISTRY \
        XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME 2>/dev/null || true
  export PREFIX="$HOME/.local"

  (( BASH_VERSINFO[0] >= 4 )) || skip "installer needs bash 4+ on PATH"
  command -v jq >/dev/null 2>&1 || skip "installer needs jq"
  command -v git >/dev/null 2>&1 || skip "installer needs git"
  command -v inotifywait >/dev/null 2>&1 || command -v fswatch >/dev/null 2>&1 \
    || skip "installer needs a filesystem watcher"
}

@test "launchd install: darwin branch renders 3 fully-substituted plists" {
  AC_OS=darwin run bash "$SRC/install.sh"
  [ "$status" -eq 0 ]
  local unit
  for unit in daemon backup intel; do
    local plist="$ANTCRATE_LAUNCHD_DIR/com.antcrate.$unit.plist"
    [ -f "$plist" ]
    run grep -c '__[A-Z]*__' "$plist"
    [ "$output" = "0" ]                       # no placeholder survived
    grep -q "<string>com.antcrate.$unit</string>" "$plist"
  done
  # daemon points at antcrated, timers at antcrate with their subcommands
  grep -q "$PREFIX/bin/antcrated" "$ANTCRATE_LAUNCHD_DIR/com.antcrate.daemon.plist"
  grep -q "<string>bak</string>" "$ANTCRATE_LAUNCHD_DIR/com.antcrate.backup.plist"
  grep -q "<string>intel</string>" "$ANTCRATE_LAUNCHD_DIR/com.antcrate.intel.plist"
}

@test "launchd install: rendered plists lint clean when plutil exists" {
  command -v plutil >/dev/null 2>&1 || skip "no plutil on this host"
  AC_OS=darwin run bash "$SRC/install.sh"
  [ "$status" -eq 0 ]
  local unit
  for unit in daemon backup intel; do
    plutil -lint "$ANTCRATE_LAUNCHD_DIR/com.antcrate.$unit.plist"
  done
}

@test "launchd install: linux branch renders no plists" {
  AC_OS=linux run bash "$SRC/install.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$ANTCRATE_LAUNCHD_DIR/com.antcrate.daemon.plist" ]
}

@test "launchd install: baked PATH contains the running bash's dir" {
  AC_OS=darwin run bash "$SRC/install.sh"
  [ "$status" -eq 0 ]
  local bash_dir; bash_dir="$(dirname "$(command -v bash)")"
  grep -q "$bash_dir" "$ANTCRATE_LAUNCHD_DIR/com.antcrate.daemon.plist"
}
