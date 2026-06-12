#!/usr/bin/env bats
# typed duties + duty_involvement knob (spec 2026-06-11 TH tier / plan Task 4)
#
# Line format: `- [ ] 2026-06-11 — [research] text`; untyped legacy lines read
# as `policy`. --duties keeps FILE-ORDER numbering (indices stay valid for
# --duty-done) and tags untyped items [policy] in display only.

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

@test "duty: --type research records typed line" {
    run src "ac_duty_add --type research 'look up bats parallel flags'"
    [ "$status" -eq 0 ]
    grep -Eq '^- \[ \] [0-9-]{10} — \[research\] look up bats parallel flags$' "$ANTCRATE_DUTIES_FILE"
}

@test "duty: invalid type rejected rc2" {
    run src "ac_duty_add --type banana 'x'"
    [ "$status" -eq 2 ]
}

@test "duty: untyped add stays format-identical to legacy (backcompat)" {
    run src "ac_duty_add 'plain item'"
    grep -Eq '^- \[ \] [0-9-]{10} — plain item$' "$ANTCRATE_DUTIES_FILE"
}

@test "duties: list shows type tags, flat indices match duty-done" {
    src "ac_duty_add 'legacy one'" >/dev/null
    src "ac_duty_add --type command 'run antcrate --ci'" >/dev/null
    run src "ac_duty_list"
    [[ "$output" == *"[policy]"* && "$output" == *"[command]"* ]]
    src "ac_duty_done 2" >/dev/null
    grep -q '^- \[x\].*run antcrate --ci' "$ANTCRATE_DUTIES_FILE"
    grep -q '^- \[ \].*legacy one' "$ANTCRATE_DUTIES_FILE"
}

@test "involvement: env override > config > default lean" {
    run src "ac_duty_involvement"; [ "$output" = "lean" ]
    printf 'duty_involvement=hands-on\n' >> "$ANTCRATE_HOME/config"
    run src "ac_duty_involvement"; [ "$output" = "hands-on" ]
    run bash -c "export ANTCRATE_DUTY_INVOLVEMENT=standard ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_DUTIES_FILE='$ANTCRATE_DUTIES_FILE' ANTCRATE_LOG_LEVEL=error; . '$LIB/log.sh'; . '$LIB/duties.sh'; ac_duty_involvement"
    [ "$output" = "standard" ]
}

@test "involvement: garbage config value falls back to lean" {
    printf 'duty_involvement=chaotic\n' >> "$ANTCRATE_HOME/config"
    run src "ac_duty_involvement"; [ "$output" = "lean" ]
}
