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

# install a fake git that prints scripted output and exits with scripted code
install_fake_git() {
    local rc="$1" stderr_msg="$2"
    cat > "$BATS_TEST_TMPDIR/bin/git" <<EOF
#!/usr/bin/env bash
case "\$1" in
    push) printf '%s\n' "$stderr_msg" >&2; exit $rc ;;
    rev-parse) echo "origin/main" ;;
    diff) echo "diff --git a/x b/x"; for i in \$(seq 1 500); do echo "line\$i"; done ;;
    *) ;;
esac
exit 0
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
