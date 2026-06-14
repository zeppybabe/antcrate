#!/usr/bin/env bats
# Tests for lib/migrate.sh — legacy ~/.antcrate -> XDG migration.

setup() {
  TMP=$(mktemp -d)
  export HOME="$TMP"
  export XDG_CONFIG_HOME="$TMP/cfg" XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state"
  mkdir -p "$HOME/.antcrate/log"
  echo "cfg" > "$HOME/.antcrate/config"
  echo "{}"  > "$HOME/.antcrate/registry.json"
  echo "x"   > "$HOME/.antcrate/log/wrapper.log"
  source "$BATS_TEST_DIRNAME/../lib/paths.sh"
  source "$BATS_TEST_DIRNAME/../lib/migrate.sh"
}
teardown() { rm -rf "$TMP"; }

@test "migrate: moves config->config-home, registry->data, log->state, drops breadcrumb" {
  ac_migrate_xdg
  [ "$(cat "$XDG_CONFIG_HOME/antcrate/config")" = "cfg" ]
  [ "$(cat "$XDG_DATA_HOME/antcrate/registry.json")" = "{}" ]
  [ -f "$XDG_STATE_HOME/antcrate/log/wrapper.log" ]
  [ -f "$HOME/.antcrate/MIGRATED" ]
}

@test "migrate: is idempotent and never clobbers a post-migration edit" {
  ac_migrate_xdg
  echo "newer" > "$XDG_CONFIG_HOME/antcrate/config"
  ac_migrate_xdg
  [ "$(cat "$XDG_CONFIG_HOME/antcrate/config")" = "newer" ]
}

@test "migrate: no-ops cleanly when no legacy dir exists" {
  rm -rf "$HOME/.antcrate"
  run ac_migrate_xdg
  [ "$status" -eq 0 ]
}
