#!/usr/bin/env bats
# Tests for lib/scan.sh — leak scan (secrets + publication boundary).

setup() {
  source "$BATS_TEST_DIRNAME/../lib/scan.sh"
  REPO=$(mktemp -d)
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  echo hi > "$REPO/README.md"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm init
}
teardown() { rm -rf "$REPO"; }

@test "scan: devtree OK when dev/ is absent or untracked" {
  run ac_scan_devtree "$REPO"
  [ "$status" -eq 0 ]
}

@test "scan: devtree FAILS when a dev/ file is tracked" {
  mkdir -p "$REPO/dev"; echo secret-notes > "$REPO/dev/ledger.md"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "oops tracked dev"
  run ac_scan_devtree "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dev/ records are TRACKED"* ]]
}

@test "scan: devtree OK when dev/ exists but is git-ignored" {
  mkdir -p "$REPO/dev"; echo notes > "$REPO/dev/ledger.md"
  echo "dev/" > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore; git -C "$REPO" commit -qm gitignore
  run ac_scan_devtree "$REPO"
  [ "$status" -eq 0 ]
}

@test "scan: markers skipped when ANTCRATE_SCAN_DEV_MARKERS empty" {
  echo "/home/someone/x" > "$REPO/file.txt"
  ANTCRATE_SCAN_DEV_MARKERS="" run ac_scan_markers "$REPO"
  [ "$status" -eq 0 ]
}

@test "scan: markers catch a configured pattern in the public surface" {
  echo "path /home/somedev/proj" > "$REPO/file.txt"
  ANTCRATE_SCAN_DEV_MARKERS="/home/somedev" run ac_scan_markers "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"file.txt"* ]]
}

@test "scan: full run on a clean repo exits 0" {
  run ac_scan_run "$REPO"
  [ "$status" -eq 0 ]
}

# ---- findings must be readable from a CI log (2026-07-27) ----
#
# `antcrate scan` printed only "FINDINGS — run gitleaks detect for detail".
# On a GitHub runner nobody can run that, so the CI job failed with no way to
# tell WHAT it found. The repo's own CI sat red from 2026-07-20 to 2026-07-27
# for five false positives that would have been obvious from one line each.
#
# Values must stay out of the output — gitleaks is already invoked with
# --redact, and these assert rule + location only.

skip_without_gitleaks() {
  ac_scan_gitleaks_bin >/dev/null 2>&1 || skip "gitleaks not available"
}

@test "scan: a finding names its rule and file:line" {
  skip_without_gitleaks
  printf 'token = "%s"\n' "gh""p_0123456789abcdef0123456789abcdef0123" > "$REPO/creds.tf"
  run ac_scan_run "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"creds.tf"* ]]
  [[ "$output" == *"github-pat"* ]]
}

@test "scan: a finding does NOT print the secret value" {
  skip_without_gitleaks
  printf 'token = "%s"\n' "gh""p_0123456789abcdef0123456789abcdef0123" > "$REPO/creds.tf"
  run ac_scan_run "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" != *"0123456789abcdef0123456789abcdef0123"* ]]
}

@test "scan: a clean tree still reports secrets OK" {
  skip_without_gitleaks
  run ac_scan_run "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"secrets   OK"* ]]
}
