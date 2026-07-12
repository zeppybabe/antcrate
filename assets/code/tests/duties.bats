#!/usr/bin/env bats
# tests for lib/duties.sh — human-action checklist (user duties)
#
# Actions only the human can perform (control-plane seeds, systemd enables,
# rule-#13 config edits, key rotation) live in duties.md as a markdown
# checklist. Append/flip only — items are never removed (quarantine
# philosophy applied to prose).

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_DUTIES_FILE='$ANTCRATE_DUTIES_FILE'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/duties.sh'
        $1
    "
}

@test "duty: add creates file with header and checkbox line" {
    run src "ac_duty_add 'rotate gh token — why: owner-only credential'"
    [ "$status" -eq 0 ]
    grep -q '^# AntCrate — User Duties' "$ANTCRATE_DUTIES_FILE"
    grep -Eq '^- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2} — rotate gh token — why: owner-only credential$' "$ANTCRATE_DUTIES_FILE"
}

@test "duty: resolves to dev/duties.md when the project has a dev/ boundary" {
    root="$BATS_TEST_TMPDIR/repo"; mkdir -p "$root/assets/code" "$root/dev"; : > "$root/dev/duties.md"
    run bash -c "
        unset ANTCRATE_DUTIES_FILE; export ANTCRATE_LOG_LEVEL=error
        . '$LIB/log.sh'; . '$LIB/duties.sh'
        ac_devops_selfsrc() { printf '%s/assets/code\n' '$root'; }
        _ac_duties_file"
    [ "$status" -eq 0 ]
    [ "$output" = "$root/dev/duties.md" ]
}

@test "duty: resolves to root duties.md when no dev/ boundary" {
    root="$BATS_TEST_TMPDIR/repo2"; mkdir -p "$root/assets/code"
    run bash -c "
        unset ANTCRATE_DUTIES_FILE; export ANTCRATE_LOG_LEVEL=error
        . '$LIB/log.sh'; . '$LIB/duties.sh'
        ac_devops_selfsrc() { printf '%s/assets/code\n' '$root'; }
        _ac_duties_file"
    [ "$output" = "$root/duties.md" ]
}

@test "duty: add appends, order preserved" {
    src "ac_duty_add 'first'" >/dev/null
    src "ac_duty_add 'second'" >/dev/null
    [ "$(grep -c '^- \[ \]' "$ANTCRATE_DUTIES_FILE")" -eq 2 ]
    [ "$(grep -n 'first' "$ANTCRATE_DUTIES_FILE" | cut -d: -f1)" -lt "$(grep -n 'second' "$ANTCRATE_DUTIES_FILE" | cut -d: -f1)" ]
}

@test "duty: add with empty text exits 2" {
    run src "ac_duty_add ''"
    [ "$status" -eq 2 ]
}

@test "duty: add flattens embedded newlines" {
    run src "ac_duty_add 'line one
line two'"
    [ "$status" -eq 0 ]
    grep -q '^- \[ \] .* — line one line two$' "$ANTCRATE_DUTIES_FILE"
}

@test "duties: list numbers OPEN items only" {
    src "ac_duty_add 'open one'" >/dev/null
    src "ac_duty_add 'open two'" >/dev/null
    src "ac_duty_done 1" >/dev/null
    run src "ac_duty_list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1."*"open two"* ]]
    [[ "$output" != *"open one"* ]]
}

@test "duties: empty list exits 0 with 'No open duties'" {
    run src "ac_duty_list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open duties"* ]]
}

@test "duty-done: flips nth open item and stamps done-date" {
    src "ac_duty_add 'alpha'" >/dev/null
    src "ac_duty_add 'beta'" >/dev/null
    run src "ac_duty_done 2"
    [ "$status" -eq 0 ]
    grep -Eq '^- \[x\] .* — beta \(done [0-9]{4}-[0-9]{2}-[0-9]{2}\)$' "$ANTCRATE_DUTIES_FILE"
    grep -q '^- \[ \] .* — alpha$' "$ANTCRATE_DUTIES_FILE"
}

@test "duty-done: out-of-range index exits 1; non-numeric exits 2" {
    src "ac_duty_add 'only'" >/dev/null
    run src "ac_duty_done 5"
    [ "$status" -eq 1 ]
    run src "ac_duty_done abc"
    [ "$status" -eq 2 ]
}

@test "duties: file derives REPO ROOT when selfsrc is */assets/code" {
    run bash -c "
        export ANTCRATE_LOG_LEVEL='error'
        . '$LIB/log.sh'
        . '$LIB/duties.sh'
        unset ANTCRATE_DUTIES_FILE
        ac_devops_selfsrc() { printf '%s\n' '/tmp/repo/assets/code'; }
        _ac_duties_file
    "
    [ "$status" -eq 0 ]
    [ "$output" = "/tmp/repo/duties.md" ]
}

@test "duties-clear: flips ALL open items done and stamps each" {
    src "ac_duty_add 'alpha'" >/dev/null
    src "ac_duty_add 'beta'" >/dev/null
    src "ac_duty_add 'gamma'" >/dev/null
    run src "ac_duty_done_all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleared 3 open duties"* ]]
    [ "$(grep -c '^- \[ \]' "$ANTCRATE_DUTIES_FILE")" -eq 0 ]
    [ "$(grep -c '^- \[x\]' "$ANTCRATE_DUTIES_FILE")" -eq 3 ]
    grep -Eq '^- \[x\] .* — gamma \(done [0-9]{4}-[0-9]{2}-[0-9]{2}\)$' "$ANTCRATE_DUTIES_FILE"
}

@test "duties-clear: leaves already-done items untouched (no double-stamp)" {
    src "ac_duty_add 'one'" >/dev/null
    src "ac_duty_add 'two'" >/dev/null
    src "ac_duty_done 1" >/dev/null
    run src "ac_duty_done_all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleared 1 open duty"* ]]
    [ "$(grep -Ec '\(done [0-9]{4}-[0-9]{2}-[0-9]{2}\)' "$ANTCRATE_DUTIES_FILE")" -eq 2 ]
}

@test "duties-clear: empty/no-open exits 0 with 'No open duties to clear'" {
    src "ac_duty_add 'solo'" >/dev/null
    src "ac_duty_done_all" >/dev/null
    run src "ac_duty_done_all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open duties to clear"* ]]
}

@test "duties: status line counts open only and shows oldest date" {
    src "ac_duty_add 'a'" >/dev/null
    src "ac_duty_add 'b'" >/dev/null
    src "ac_duty_done 1" >/dev/null
    run src "ac_duties_status_line"
    [ "$status" -eq 0 ]
    [[ "$output" == "duties: 1 open (oldest 20"*")" ]]
}

@test "duties: status line with nothing open stays bare" {
    run src "ac_duties_status_line"
    [ "$status" -eq 0 ]
    [ "$output" = "duties: 0 open" ]
}
