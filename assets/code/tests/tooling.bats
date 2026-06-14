#!/usr/bin/env bats
# Tests for lib/tooling.sh — local pinned-tool provisioning.

setup() {
  TMP=$(mktemp -d)
  export HOME="$TMP"
  export XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/cfg"
  source "$BATS_TEST_DIRNAME/../lib/paths.sh"
  source "$BATS_TEST_DIRNAME/../lib/tooling.sh"
}
teardown() { rm -rf "$TMP"; }

@test "tooling: ac_tool_path points into XDG data" {
  [ "$(ac_tool_path)" = "$XDG_DATA_HOME/antcrate/tools/bin" ]
}

@test "tooling: known tools are recognized, unknown rejected" {
  ac_tool_known shellcheck
  ac_tool_known bats
  run ac_tool_known nope
  [ "$status" -ne 0 ]
}

@test "tooling: ac_tool_list reports both tools with pinned versions" {
  run ac_tool_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"shellcheck"*"v0.11.0"* ]]
  [[ "$output" == *"bats"*"v1.13.0"* ]]
}

@test "tooling: install of an unknown tool exits 2" {
  run ac_tool_install definitely-not-a-tool
  [ "$status" -eq 2 ]
}

@test "tooling: install fetches, verifies, symlinks, and writes a manifest line (network)" {
  curl -fsS --proto '=https' --tlsv1.2 -o /dev/null https://github.com 2>/dev/null || skip "no network"
  ANTCRATE_TOOL_APPROVED_BY=test-suite run ac_tool_install shellcheck
  [ "$status" -eq 0 ]
  [ -x "$XDG_DATA_HOME/antcrate/tools/bin/shellcheck" ]
  run "$XDG_DATA_HOME/antcrate/tools/bin/shellcheck" --version
  [[ "$output" == *"0.11.0"* ]]
  grep -q '"tool":"shellcheck"' "$XDG_STATE_HOME/antcrate/tools/manifest.jsonl"
  grep -q '"attested_by":"test-suite"' "$XDG_STATE_HOME/antcrate/tools/manifest.jsonl"
}

@test "tooling: re-install is idempotent without --force" {
  curl -fsS --proto '=https' --tlsv1.2 -o /dev/null https://github.com 2>/dev/null || skip "no network"
  ac_tool_install shellcheck >/dev/null
  run ac_tool_install shellcheck
  [ "$status" -eq 0 ]
  [[ "$output" == *"already present"* ]]
}
