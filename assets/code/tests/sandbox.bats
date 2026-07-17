#!/usr/bin/env bats
# tests for lib/sandbox.sh — sandboxed local-inference launcher (spec 2026-07-16)
#
# Arg-construction is tested via a PATH-shimmed fake systemd-run that records
# its argv and execs the payload after `--`, so these tests run on ANY host
# (no systemd needed).

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    # warn, not error: several tests assert ac_warn text, which log.sh
    # suppresses at error level. HOME sandboxed so log writes stay in tmp.
    export ANTCRATE_LOG_LEVEL="warn"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    FAKE_BIN="$BATS_TEST_TMPDIR/fakebin"
    export FAKE_LOG="$BATS_TEST_TMPDIR/systemd-run.argv"
    mkdir -p "$FAKE_BIN"
    # FAKE_PROBE_MODE=pass (default): when the payload after `--` mentions
    # /sys/class/net (the capability probe's in-unit check), exit 0 WITHOUT
    # running it — simulates a host where the hardening properties genuinely
    # apply. FAKE_PROBE_MODE=real: exec the payload for real, so on THIS test
    # host (which has more than just `lo`) the probe's own check fails,
    # simulating a degraded (apparmor_restrict_unprivileged_userns) host.
    # Any other launch (no /sys/class/net in the payload) always execs, same
    # as before.
    cat > "$FAKE_BIN/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
payload=()
saw_dd=0
for a in "$@"; do
    if [[ $saw_dd -eq 1 ]]; then
        payload+=("$a")
    elif [[ "$a" == "--" ]]; then
        saw_dd=1
    fi
done
[[ $saw_dd -eq 1 ]] || exit 0   # no `--`: legacy no-op probe form, succeed silently
if [[ "${FAKE_PROBE_MODE:-pass}" == "pass" ]] && [[ "${payload[*]}" == *"/sys/class/net"* ]]; then
    exit 0
fi
exec "${payload[@]}"
EOF
    chmod +x "$FAKE_BIN/systemd-run"
}

# run a snippet with the fake systemd-run first on PATH and AC_OS forced
src() {
    AC_OS="${FORCE_OS:-linux}" PATH="$FAKE_BIN:$PATH" FAKE_LOG="$FAKE_LOG" \
    ANTCRATE_SANDBOX_DISABLE="${FORCE_DISABLE:-0}" \
    FAKE_PROBE_MODE="${FORCE_PROBE_MODE:-pass}" \
    ANTCRATE_HOME="$ANTCRATE_HOME" \
    bash -c "
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/sandbox.sh'
        $1
    "
}

@test "sandbox: capable on linux with working systemd-run" {
    run src "ac_sandbox_capable && echo CAPABLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *CAPABLE* ]]
    # the probe itself must launch WITH the hardening properties, not a
    # no-op — first FAKE_LOG line is the probe call.
    argv="$(head -1 "$FAKE_LOG")"
    [[ "$argv" == *"PrivateNetwork=yes"* ]]
    [[ "$argv" == *"ProtectHome=read-only"* ]]
}

@test "sandbox: NOT capable when AC_OS=darwin (even with systemd-run on PATH)" {
    FORCE_OS=darwin run src "ac_sandbox_capable || echo NOT-CAPABLE"
    [[ "$output" == *NOT-CAPABLE* ]]
}

@test "sandbox: NOT capable on degraded linux host (hardening props silently dropped)" {
    # FAKE_PROBE_MODE=real makes the shim exec the probe's in-unit check for
    # real; on this test host /sys/class/net has more than just "lo", so the
    # check fails — reproducing the apparmor_restrict_unprivileged_userns
    # degrade where systemd-run "succeeds" but confinement never applied.
    FORCE_PROBE_MODE=real run src "ac_sandbox_capable"
    [ "$status" -eq 1 ]
}

@test "sandbox: run on degraded linux host warns 'not enforceable' and still runs unsandboxed" {
    FORCE_PROBE_MODE=real run src "ac_sandbox_run '$BATS_TEST_TMPDIR' -- echo ran-degraded"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not enforceable"* ]]
    [[ "$output" == *ran-degraded* ]]
    # the probe unit runs (it has --pipe too now), but the real hardened
    # launch (identifiable by ReadWritePaths=, only set on a launch) must not.
    ! grep -q -- 'ReadWritePaths=' "$FAKE_LOG" 2>/dev/null
}

@test "sandbox: run wraps with the full hardening property set" {
    run src "ac_sandbox_run '$BATS_TEST_TMPDIR/crate' -- echo payload-ran"
    [ "$status" -eq 0 ]
    [[ "$output" == *payload-ran* ]]
    argv="$(tail -1 "$FAKE_LOG")"   # last call = the launch (first = the probe)
    [[ "$argv" == *"--user"* ]]
    [[ "$argv" == *"--pipe"* ]]
    [[ "$argv" == *"PrivateNetwork=yes"* ]]
    [[ "$argv" == *"ProtectHome=read-only"* ]]
    [[ "$argv" == *"ReadWritePaths=$BATS_TEST_TMPDIR/crate"* ]]
    [[ "$argv" == *"PrivateTmp=yes"* ]]
    [[ "$argv" == *"NoNewPrivileges=yes"* ]]
}

@test "sandbox: run passes stdin through to the payload" {
    run bash -c "echo hello-in | AC_OS=linux PATH='$FAKE_BIN:$PATH' FAKE_LOG='$FAKE_LOG' \
        ANTCRATE_LOG_LEVEL=error bash -c '. \"$LIB/log.sh\"; . \"$LIB/sandbox.sh\"; \
        ac_sandbox_run \"$BATS_TEST_TMPDIR\" -- cat'"
    [ "$status" -eq 0 ]
    [[ "$output" == *hello-in* ]]
}

@test "sandbox: macOS warns and runs unsandboxed" {
    FORCE_OS=darwin run src "ac_sandbox_run '$BATS_TEST_TMPDIR' -- echo ran-anyway"
    [ "$status" -eq 0 ]
    [[ "$output" == *"unavailable"* ]]
    [[ "$output" == *ran-anyway* ]]
    # and systemd-run was never invoked for a launch
    ! grep -q -- '--pipe' "$FAKE_LOG" 2>/dev/null
}

@test "sandbox: ANTCRATE_SANDBOX_DISABLE=1 warns and bypasses" {
    FORCE_DISABLE=1 run src "ac_sandbox_run '$BATS_TEST_TMPDIR' -- echo bypassed"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DISABLED"* ]]
    [[ "$output" == *bypassed* ]]
}

@test "sandbox: usage errors — missing -- and missing command" {
    run src "ac_sandbox_run '$BATS_TEST_TMPDIR' echo x"
    [ "$status" -eq 2 ]
    run src "ac_sandbox_run '$BATS_TEST_TMPDIR' --"
    [ "$status" -eq 2 ]
}

@test "sandbox: write_path containing whitespace is refused (ReadWritePaths is space-separated)" {
    run src "ac_sandbox_run '$BATS_TEST_TMPDIR/has space' -- touch '$BATS_TEST_TMPDIR/marker-space'"
    [ "$status" -eq 2 ]
    [ ! -e "$BATS_TEST_TMPDIR/marker-space" ]
}

@test "sandbox: relative write_path is refused (meaningless as a mount boundary)" {
    run src "ac_sandbox_run 'relative/path' -- touch '$BATS_TEST_TMPDIR/marker-relative'"
    [ "$status" -eq 2 ]
    [ ! -e "$BATS_TEST_TMPDIR/marker-relative" ]
}

@test "sandbox: payload exit code propagates" {
    run src "ac_sandbox_run '$BATS_TEST_TMPDIR' -- bash -c 'exit 7'"
    [ "$status" -eq 7 ]
}
