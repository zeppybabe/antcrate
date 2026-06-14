#!/usr/bin/env bats
# Tests for lib/paths.sh — XDG base-dir resolution.

@test "paths: defaults to XDG dirs and ~/Projects" {
  run bash -c '
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME ANTCRATE_HOME ANTCRATE_ROOT \
          ANTCRATE_CONFIG ANTCRATE_REGISTRY ANTCRATE_REGISTRY_MMD ANTCRATE_INTEL_DIR \
          ANTCRATE_BACKUP_DIR
    HOME=/tmp/h
    source "'"$BATS_TEST_DIRNAME"'/../lib/paths.sh"
    echo "$ANTCRATE_CONFIG|$ANTCRATE_REGISTRY|$ANTCRATE_REGISTRY_MMD|$ANTCRATE_INTEL_DIR|$ANTCRATE_BACKUP_DIR|$ANTCRATE_ROOT"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/h/.config/antcrate/config|/tmp/h/.local/share/antcrate/registry.json|/tmp/h/.local/share/antcrate/registry.mmd|/tmp/h/.local/share/antcrate/intel|/tmp/h/.local/state/antcrate/backups|/tmp/h/Projects" ]
}

@test "paths: honors XDG_*_HOME overrides" {
  run bash -c '
    unset ANTCRATE_HOME ANTCRATE_CONFIG ANTCRATE_REGISTRY ANTCRATE_BACKUP_DIR
    export XDG_CONFIG_HOME=/x/cfg XDG_DATA_HOME=/x/data XDG_STATE_HOME=/x/state
    source "'"$BATS_TEST_DIRNAME"'/../lib/paths.sh"
    echo "$ANTCRATE_CONFIG|$ANTCRATE_REGISTRY|$ANTCRATE_BACKUP_DIR"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "/x/cfg/antcrate/config|/x/data/antcrate/registry.json|/x/state/antcrate/backups" ]
}

@test "paths: respects a pre-set ANTCRATE_ROOT" {
  run bash -c '
    export ANTCRATE_ROOT=/custom/root
    source "'"$BATS_TEST_DIRNAME"'/../lib/paths.sh"
    echo "$ANTCRATE_ROOT"
  '
  [ "$output" = "/custom/root" ]
}
