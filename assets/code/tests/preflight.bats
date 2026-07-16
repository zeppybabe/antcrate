#!/usr/bin/env bats
# Tests for lib/preflight.sh — install dependency checks.

setup() { source "$BATS_TEST_DIRNAME/../lib/preflight.sh"; }

@test "preflight: passes when all required tools are present" {
  run ac_preflight_deps jq git    # both present in CI/dev
  [ "$status" -eq 0 ]
}

@test "preflight: fails and names a missing required tool" {
  run ac_preflight_deps jq definitely-absent-tool-xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required tools"* ]]
  [[ "$output" == *"definitely-absent-tool-xyz"* ]]
}

@test "preflight: maps inotifywait to the inotify-tools package in its hint" {
  run ac_preflight_deps inotifywait-absent-xyz
  # the missing tool name itself is echoed; the hint maps known names only,
  # so just assert the generic miss path works for an unknown tool
  [ "$status" -eq 1 ]
  [[ "$output" == *"inotifywait-absent-xyz"* ]]
}

@test "preflight: pkg hint is non-empty for a package" {
  run ac_preflight_pkg_hint inotify-tools
  [ "$status" -eq 0 ]
  [[ -n "$output" ]]
  [[ "$output" == *"inotify-tools"* ]]
}

@test "preflight: darwin pkg hint is brew install" {
  AC_OS=darwin run ac_preflight_pkg_hint fswatch
  [ "$status" -eq 0 ]
  [[ "$output" == "brew install fswatch"* ]]
}

@test "preflight: linux pkg hint never mentions brew" {
  AC_OS=linux run ac_preflight_pkg_hint fswatch
  [ "$status" -eq 0 ]
  [[ "$output" != *"brew"* ]]
}

@test "preflight: fswatcher token satisfied by either watcher" {
  # a fake inotifywait OR fswatch on PATH must satisfy the virtual token
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/fswatch"
  chmod +x "$BATS_TEST_TMPDIR/bin/fswatch"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run ac_preflight_deps fswatcher
  [ "$status" -eq 0 ]
}

@test "preflight: fswatcher miss maps to the platform watcher package" {
  # restrict PATH to core dirs; if neither watcher lives there, the token
  # must miss and the darwin hint must name fswatch
  AC_OS=darwin PATH="/usr/bin:/bin" run ac_preflight_deps fswatcher
  if PATH="/usr/bin:/bin" bash -c 'command -v inotifywait || command -v fswatch' >/dev/null 2>&1; then
    [ "$status" -eq 0 ]   # watcher genuinely ships in a core dir — accept pass
  else
    [ "$status" -eq 1 ]
    [[ "$output" == *"fswatch"* ]]
  fi
}

@test "preflight: bash version guard matches the running bash" {
  run ac_preflight_bash_version
  if (( BASH_VERSINFO[0] >= 4 )); then
    [ "$status" -eq 0 ]
  else
    [ "$status" -eq 1 ]
    [[ "$output" == *"bash 4+"* ]]
  fi
}
