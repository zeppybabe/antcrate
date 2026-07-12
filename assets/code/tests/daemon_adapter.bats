#!/usr/bin/env bats
# Tests for bin/antcrated's fswatch → inotify-vocabulary adapter
# (ac_fswatch_stream). A fake fswatch on PATH prints canned event lines and
# exits, so the translation runs identically on Linux CI and macOS — no real
# watcher needed.

setup() {
  # extract just the adapter function from the daemon (sourcing the whole
  # binary would start it)
  FUNC="$BATS_TEST_TMPDIR/adapter.sh"
  sed -n '/^ac_fswatch_stream()/,/^}/p' "$BATS_TEST_DIRNAME/../bin/antcrated" > "$FUNC"
  grep -q 'ac_fswatch_stream()' "$FUNC"   # extraction sanity

  SHIM="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$SHIM"
  export FIXTURE="$BATS_TEST_TMPDIR/fixture"
}

# fake_fswatch <<'EOF' ... — install a fswatch that prints the fixture then exits
fake_fswatch() {
  cat > "$FIXTURE"
  cat > "$SHIM/fswatch" <<SH
#!/usr/bin/env bash
cat "$FIXTURE"
SH
  chmod +x "$SHIM/fswatch"
}

run_adapter() {
  PATH="$SHIM:$PATH" run bash -c ". '$FUNC'; ac_fswatch_stream /watched"
}

@test "adapter: splits full path into dir with trailing slash + basename" {
  fake_fswatch <<'EOF'
/watched/proj/file.txt|Created
EOF
  run_adapter
  [ "$status" -eq 0 ]
  [ "$output" = "/watched/proj/|CREATE,CLOSE_WRITE|file.txt" ]
}

@test "adapter: maps every direct flag to the inotify token" {
  fake_fswatch <<'EOF'
/watched/a|Created
/watched/b|Updated
/watched/c|Removed
/watched/d|MovedTo
/watched/e|MovedFrom
EOF
  run_adapter
  # bare Created on a file gains CLOSE_WRITE (inotify `touch` parity)
  [ "${lines[0]}" = "/watched/|CREATE,CLOSE_WRITE|a" ]
  [ "${lines[1]}" = "/watched/|CLOSE_WRITE|b" ]
  [ "${lines[2]}" = "/watched/|DELETE|c" ]
  [ "${lines[3]}" = "/watched/|MOVED_TO|d" ]
  [ "${lines[4]}" = "/watched/|MOVED_FROM|e" ]
}

@test "adapter: combined flags join comma-separated like inotify" {
  fake_fswatch <<'EOF'
/watched/newdir|Created,IsDir
EOF
  run_adapter
  [ "$output" = "/watched/|CREATE,ISDIR|newdir" ]
}

@test "adapter: Renamed disambiguates by existence — present means MOVED_TO" {
  mkdir -p "$BATS_TEST_TMPDIR/live"
  touch "$BATS_TEST_TMPDIR/live/dest"
  fake_fswatch <<EOF
$BATS_TEST_TMPDIR/live/dest|Renamed
$BATS_TEST_TMPDIR/live/gone|Renamed
EOF
  run_adapter
  [ "${lines[0]}" = "$BATS_TEST_TMPDIR/live/|MOVED_TO|dest" ]
  [ "${lines[1]}" = "$BATS_TEST_TMPDIR/live/|MOVED_FROM|gone" ]
}

@test "adapter: attribute-only events are dropped" {
  fake_fswatch <<'EOF'
/watched/noise|AttributeModified
/watched/noise2|OwnerModified,IsFile
/watched/real|Updated
EOF
  run_adapter
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "/watched/|CLOSE_WRITE|real" ]
}

@test "adapter: unknown flags are ignored inside a token list, known ones kept" {
  fake_fswatch <<'EOF'
/watched/mix|Created,IsFile,PlatformSpecific
EOF
  run_adapter
  [ "$output" = "/watched/|CREATE,CLOSE_WRITE|mix" ]
}

@test "adapter: bare Created on a DIRECTORY does not gain CLOSE_WRITE" {
  fake_fswatch <<'EOF'
/watched/newdir|Created,IsDir
EOF
  run_adapter
  [ "$output" = "/watched/|CREATE,ISDIR|newdir" ]
}
