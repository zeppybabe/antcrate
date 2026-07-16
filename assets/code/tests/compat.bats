#!/usr/bin/env bats
# Tests for lib/compat.sh — GNU/BSD portability shims.
# Every shim is tested on whatever userland is running the suite, plus the
# fallback branches are forced explicitly so both paths stay covered on
# either platform.

setup() {
  COMPAT="$BATS_TEST_DIRNAME/../lib/compat.sh"
  T="$BATS_TEST_TMPDIR"
}

@test "compat: AC_OS resolves to darwin or linux and is pre-settable" {
  run bash -c ". '$COMPAT'; echo \$AC_OS"
  [ "$status" -eq 0 ]
  [[ "$output" == "darwin" || "$output" == "linux" ]]
  run bash -c "AC_OS=testos; . '$COMPAT'; echo \$AC_OS"
  [ "$output" = "testos" ]
}

@test "compat: idempotent re-source" {
  run bash -c "set -euo pipefail; . '$COMPAT'; . '$COMPAT'; echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "compat: ac_stat_mtime/size/inode agree with the filesystem" {
  echo hello > "$T/f"
  run bash -c ". '$COMPAT'
    m=\$(ac_stat_mtime '$T/f'); s=\$(ac_stat_size '$T/f'); i=\$(ac_stat_inode '$T/f')
    [[ \$m =~ ^[0-9]+\$ && \$s -eq 6 && \$i =~ ^[0-9]+\$ ]] && echo ok"
  [ "$output" = "ok" ]
}

@test "compat: ac_now_ms is 13-digit and monotonic" {
  run bash -c ". '$COMPAT'
    a=\$(ac_now_ms); sleep 0.05; b=\$(ac_now_ms)
    [[ \$a =~ ^[0-9]{13}\$ && \$b -ge \$a ]] && echo ok"
  [ "$output" = "ok" ]
}

@test "compat: ac_now_iso_ms shape" {
  run bash -c ". '$COMPAT'; ac_now_iso_ms"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
}

@test "compat: ac_date_from_epoch epoch 0 and custom format" {
  run bash -c ". '$COMPAT'; ac_date_from_epoch 0"
  [ "$output" = "1970-01-01T00:00:00Z" ]
  run bash -c ". '$COMPAT'; ac_date_from_epoch 86400 +%Y-%m-%d"
  [ "$output" = "1970-01-02" ]
}

@test "compat: ac_sed_i edits in place, supports -E, keeps no backup file" {
  printf 'aaa\nbbb\n' > "$T/s"
  run bash -c ". '$COMPAT'; ac_sed_i 's/aaa/zzz/' '$T/s' && ac_sed_i -E 's/^(b+)\$/X\\1/' '$T/s'"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/s")" = "$(printf 'zzz\nXbbb')" ]
  [ ! -e "$T/s''" ]
  [ -z "$(find "$T" -name '*.bak' -o -name "s?*" 2>/dev/null)" ]
}

@test "compat: ac_sha256 file and stdin match and parse like sha256sum" {
  printf 'hi\n' > "$T/h"
  run bash -c ". '$COMPAT'
    f=\$(ac_sha256 '$T/h' | awk '{print \$1}')
    s=\$(ac_sha256 <<< 'hi' | cut -d' ' -f1)
    [[ \$f == \$s && \${#f} -eq 64 ]] && echo ok"
  [ "$output" = "ok" ]
}

@test "compat: ac_realpath_m resolves existing paths" {
  mkdir -p "$T/real/dir"
  run bash -c ". '$COMPAT'; ac_realpath_m '$T/real/dir'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd "$T/real/dir" && pwd -P)" ]
}

@test "compat: ac_realpath_m fallback — nonexistent leaf and middle" {
  mkdir -p "$T/base"
  base="$(cd "$T/base" && pwd -P)"
  run bash -c ". '$COMPAT'; _ac_realpath_m_fallback '$T/base/x/y/z'"
  [ "$output" = "$base/x/y/z" ]
}

@test "compat: ac_realpath_m fallback — dotdot squashing in nonexistent tail" {
  mkdir -p "$T/base"
  base="$(cd "$T/base" && pwd -P)"
  run bash -c ". '$COMPAT'; _ac_realpath_m_fallback '$T/base/x/../y/./z'"
  [ "$output" = "$base/y/z" ]
}

@test "compat: ac_realpath_m fallback — dotdot escaping above existing dir" {
  mkdir -p "$T/base/sub"
  parent="$(cd "$T/base" && pwd -P)"
  run bash -c ". '$COMPAT'; _ac_realpath_m_fallback '$T/base/sub/../../base/ok'"
  [ "$output" = "$parent/ok" ]
}

@test "compat: ac_realpath_m fallback — relative input absolutized" {
  mkdir -p "$T/rel"
  reldir="$(cd "$T/rel" && pwd -P)"
  run bash -c "cd '$T/rel'; . '$COMPAT'; _ac_realpath_m_fallback 'a/b'"
  [ "$output" = "$reldir/a/b" ]
}

@test "compat: ac_realpath_m fallback — symlinked ancestor resolved physically" {
  mkdir -p "$T/target"
  ln -s "$T/target" "$T/link"
  tgt="$(cd "$T/target" && pwd -P)"
  run bash -c ". '$COMPAT'; _ac_realpath_m_fallback '$T/link/new/file'"
  [ "$output" = "$tgt/new/file" ]
}

@test "compat: ac_realpath_m matches realpath -m when available" {
  command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1 || skip "no realpath -m here"
  mkdir -p "$T/cmp"
  run bash -c ". '$COMPAT'
    a=\$(realpath -m '$T/cmp/no/such/../thing')
    b=\$(_ac_realpath_m_fallback '$T/cmp/no/such/../thing')
    [[ \$a == \$b ]] && echo ok"
  [ "$output" = "ok" ]
}

@test "compat: ac_files_by_mtime newest first with epoch column" {
  mkdir -p "$T/mt"
  touch -t 202001010000 "$T/mt/old"
  touch "$T/mt/new"
  run bash -c ". '$COMPAT'; ac_files_by_mtime '$T/mt' -type f"
  [ "$status" -eq 0 ]
  first_line="${lines[0]}"
  [[ "$first_line" == *$'\t'*"/new" ]]
  [[ "${lines[1]}" == *$'\t'*"/old" ]]
  [[ "${first_line%%$'\t'*}" =~ ^[0-9] ]]
}

@test "compat: ac_basenames strips directories" {
  mkdir -p "$T/bn/sub"
  touch "$T/bn/one" "$T/bn/sub/two"
  run bash -c ". '$COMPAT'; ac_basenames '$T/bn' -type f | sort | paste -sd, -"
  [ "$output" = "one,two" ]
}

@test "compat: ac_copy_into copies contents including dotfiles into dst" {
  mkdir -p "$T/src/deep"
  echo v > "$T/src/f"
  echo h > "$T/src/.hidden"
  echo d > "$T/src/deep/g"
  run bash -c ". '$COMPAT'; ac_copy_into '$T/src' '$T/dst'"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/dst/f")" = "v" ]
  [ "$(cat "$T/dst/.hidden")" = "h" ]
  [ "$(cat "$T/dst/deep/g")" = "d" ]
}

@test "compat: ac_copy_into into an existing dst merges" {
  mkdir -p "$T/m-src" "$T/m-dst"
  echo new > "$T/m-src/added"
  echo keep > "$T/m-dst/existing"
  run bash -c ". '$COMPAT'; ac_copy_into '$T/m-src' '$T/m-dst'"
  [ "$(cat "$T/m-dst/added")" = "new" ]
  [ "$(cat "$T/m-dst/existing")" = "keep" ]
}

@test "compat: ac_du_bytes returns a positive integer" {
  mkdir -p "$T/du"
  head -c 5000 /dev/zero > "$T/du/blob"
  run bash -c ". '$COMPAT'; ac_du_bytes '$T/du'"
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -ge 4096 ]
}

@test "compat: ac_mktemp_d honors prefix and creates a dir" {
  run bash -c ". '$COMPAT'; d=\$(ac_mktemp_d antcrate-bats); [[ -d \$d && \$d == *antcrate-bats.* ]] && echo \"\$d\" && rmdir \"\$d\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"antcrate-bats."* ]]
}

@test "compat: forced BSD stat flavor errors cleanly on GNU-only systems or works on BSD" {
  # The flavor probes are plain vars — force each branch to prove both code
  # paths are syntactically live. On a GNU-only box the bsd branch fails at
  # runtime (stat -f unsupported); that non-zero exit is the assertion there.
  echo x > "$T/probe"
  if stat -f %m "$T/probe" >/dev/null 2>&1; then
    run bash -c ". '$COMPAT'; _AC_STAT_FLAVOR=bsd; ac_stat_mtime '$T/probe'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
  else
    run bash -c ". '$COMPAT'; _AC_STAT_FLAVOR=bsd; ac_stat_mtime '$T/probe'"
    [ "$status" -ne 0 ]
  fi
}
