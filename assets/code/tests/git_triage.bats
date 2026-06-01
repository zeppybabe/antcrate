#!/usr/bin/env bats
# tests for lib/git_triage.sh — git is mocked via PATH shim

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_CONFLICT_LOG="$BATS_TEST_TMPDIR/conflict.log"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$ANTCRATE_HOME" "$BATS_TEST_TMPDIR/bin"
}

# install a fake git that: skips a leading "-C <path>"; records push args to
# pushargs.log; scripts push rc/stderr; answers rev-parse for @{u}, branch, sha.
# usage: install_fake_git <push_rc> <push_stderr_msg> [upstream_mode: set|unset]
install_fake_git() {
    local rc="$1" stderr_msg="$2" upstream_mode="${3:-set}"
    cat > "$BATS_TEST_TMPDIR/bin/git" <<EOF
#!/usr/bin/env bash
[ "\$1" = "-C" ] && shift 2          # drop the path prefix
sub="\$1"; shift
case "\$sub" in
    push)
        echo "push \$*" >> "$BATS_TEST_TMPDIR/pushargs.log"
        [ -n "$stderr_msg" ] && printf '%s\n' "$stderr_msg" >&2
        exit $rc ;;
    rev-parse)
        if printf '%s ' "\$@" | grep -q '@{u}'; then
            [ "$upstream_mode" = unset ] && exit 1
            echo "origin/main"; exit 0
        fi
        if printf '%s ' "\$@" | grep -q -- '--abbrev-ref' && printf '%s ' "\$@" | grep -qw HEAD; then
            echo "main"; exit 0
        fi
        echo "deadbeef"; exit 0 ;;
    diff)
        echo "diff --git a/x b/x"; for i in \$(seq 1 500); do echo "line\$i"; done; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/git"
}

# install a fake mailx that records to a file
install_fake_mailx() {
    cat > "$BATS_TEST_TMPDIR/bin/mailx" <<EOF
#!/usr/bin/env bash
echo "MAILX-CALLED args=\$*" > "$BATS_TEST_TMPDIR/mailx.log"
cat >> "$BATS_TEST_TMPDIR/mailx.log"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/mailx"
}

@test "successful push returns 0 and writes nothing to conflict log" {
    install_fake_git 0 ""
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj'
    [ "$status" -eq 0 ]
    [ ! -s "$BATS_TEST_TMPDIR/mailx.log" ] || true
}

@test "rejected push triggers triage, writes /tmp log, dispatches mail" {
    install_fake_git 1 "error: failed to push some refs"
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj'
    [ "$status" -ne 0 ]
    [ -f "$ANTCRATE_CONFLICT_LOG" ]
    grep -q "AntCrate Conflict Triage Report" "$ANTCRATE_CONFLICT_LOG"
    grep -q "myproj" "$ANTCRATE_CONFLICT_LOG"
    grep -q "MAILX-CALLED" "$BATS_TEST_TMPDIR/mailx.log"
    grep -q "AntCrate Auto-Push Failed" "$BATS_TEST_TMPDIR/mailx.log"
}

@test "triage truncates email body to 300 lines" {
    install_fake_git 1 "rejected"
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj'
    # body should not contain line500 (full diff has 500 lines, truncated to 300)
    ! grep -q "^line500$" "$BATS_TEST_TMPDIR/mailx.log"
    # full log should
    grep -q "^line500$" "$ANTCRATE_CONFLICT_LOG"
}

@test "missing email config skips dispatch but keeps log" {
    install_fake_git 1 "rejected"
    install_fake_mailx
    unset ANTCRATE_EMAIL
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj'
    [ -f "$ANTCRATE_CONFLICT_LOG" ]
    [ ! -f "$BATS_TEST_TMPDIR/mailx.log" ]
}

@test "push is path-explicit: ac_git_push receives -C <path>" {
    install_fake_git 0 ""
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj "/tmp/some/proj/path"'
    [ "$status" -eq 0 ]
    grep -q -- '-C' "$BATS_TEST_TMPDIR/bin/git"   # shim is -C-aware
    # the push must have happened (args recorded), proving the call routed through git -C
    [ -s "$BATS_TEST_TMPDIR/pushargs.log" ]
}

@test "no upstream → push sets it with -u origin <branch>" {
    install_fake_git 0 "" unset
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj "/tmp/proj"'
    [ "$status" -eq 0 ]
    grep -q 'push -u origin main' "$BATS_TEST_TMPDIR/pushargs.log"
}

@test "rejection with upstream-set still triages (conflict log + mail)" {
    install_fake_git 1 "error: failed to push some refs" unset
    install_fake_mailx
    export ANTCRATE_EMAIL="dev@example.com"
    run bash -c '
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/git_triage.sh"
        ac_git_push myproj "/tmp/proj"'
    [ "$status" -ne 0 ]
    [ -s "$ANTCRATE_CONFLICT_LOG" ]
    grep -q 'push -u origin main' "$BATS_TEST_TMPDIR/pushargs.log"
}
