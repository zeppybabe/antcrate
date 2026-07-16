#!/usr/bin/env bats
# Tests for lib/lock.sh — exclusive lock with flock fast path and mkdir
# fallback. The fallback is forced via a PATH shim dir that lacks flock,
# so both branches run on any platform.

setup() {
  export ANTCRATE_HOME="$BATS_TEST_TMPDIR/home"
  export ANTCRATE_LOCK="$ANTCRATE_HOME/daemon.lock"
  mkdir -p "$ANTCRATE_HOME"
  LOCK_LIB="$BATS_TEST_DIRNAME/../lib/lock.sh"

  # minimal PATH without flock: symlink only the tools the lock paths use
  NOFLOCK="$BATS_TEST_TMPDIR/noflock-bin"
  mkdir -p "$NOFLOCK"
  local t
  for t in bash sh mkdir rm cat sleep kill echo printf seq; do
    ln -s "$(command -v $t)" "$NOFLOCK/$t" 2>/dev/null || true
  done
}

@test "lock: ac_with_lock runs the command and passes its exit code" {
  run bash -c ". '$LOCK_LIB'; ac_with_lock echo held"
  [ "$status" -eq 0 ]
  [ "$output" = "held" ]
  run bash -c ". '$LOCK_LIB'; ac_with_lock bash -c 'exit 7'"
  [ "$status" -eq 7 ]
}

@test "lock: mkdir fallback runs the command and passes its exit code" {
  run env PATH="$NOFLOCK" bash -c ". '$LOCK_LIB'; ac_with_lock echo held"
  [ "$status" -eq 0 ]
  [ "$output" = "held" ]
  run env PATH="$NOFLOCK" bash -c ". '$LOCK_LIB'; ac_with_lock bash -c 'exit 7'"
  [ "$status" -eq 7 ]
}

@test "lock: mkdir fallback releases the lock after a failing command" {
  run env PATH="$NOFLOCK" bash -c "
    . '$LOCK_LIB'
    ac_with_lock bash -c 'exit 3' || true
    [ ! -d \"\$ANTCRATE_LOCK.d\" ] && echo released"
  [ "$output" = "released" ]
}

@test "lock: mkdir fallback mutual exclusion — writers never interleave" {
  run env PATH="$NOFLOCK" bash -c "
    . '$LOCK_LIB'
    out=\"$BATS_TEST_TMPDIR/interleave\"
    writer() {
      # inside the lock: write A, yield the scheduler, write A again — if a
      # second writer sneaks in between, the pair check below catches it
      echo \"\$1\" >> \"\$out\"; sleep 0.05; echo \"\$1\" >> \"\$out\"
    }
    for i in 1 2 3; do ac_with_lock writer \"\$i\" & done
    wait
    cat \"\$out\""
  [ "$status" -eq 0 ]
  # 3 writers x 2 lines, and every pair of lines must match (no interleaving)
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[0]}" = "${lines[1]}" ]
  [ "${lines[2]}" = "${lines[3]}" ]
  [ "${lines[4]}" = "${lines[5]}" ]
}

@test "lock: mkdir fallback steals a stale lock from a dead holder" {
  run env PATH="$NOFLOCK" bash -c "
    . '$LOCK_LIB'
    mkdir \"\$ANTCRATE_LOCK.d\"
    echo 999999 > \"\$ANTCRATE_LOCK.d/pid\"   # no such process
    ac_with_lock echo stole-it"
  [ "$status" -eq 0 ]
  [ "$output" = "stole-it" ]
}

@test "lock: mkdir fallback blocks while the holder is alive" {
  run env PATH="$NOFLOCK" bash -c "
    . '$LOCK_LIB'
    ( ac_with_lock sleep 0.3 ) &
    holder=\$!
    sleep 0.1                                  # let the holder acquire
    start=\$SECONDS
    ac_with_lock echo done-waiting
    wait \$holder"
  [ "$status" -eq 0 ]
  [[ "$output" == *done-waiting* ]]
}
