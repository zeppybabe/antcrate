#!/usr/bin/env bats
# tests for bin/antcrate multi-step dispatch exit codes — proposal
# wrapper-exit-on-substep-fail. A REFUSED destructive primary step must
# propagate its non-zero exit; aftermath steps (diagram regen, lifecycle)
# must not mask it back to 0. Surfaced live 2026-05-26/27: a canary-gate
# rename refusal printed the framed gate UX but the wrapper exited 0.

setup() {
    WRAPPER="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_CANARY_DISABLE=1
    # unwritable backup dir -> mandatory backup fails -> every destructive op
    # refuses (rule #1), giving a deterministic refused-primary to test exit
    # propagation with. (Was the canary-missing gate pre fail-open, audit
    # 2026-07-10.) Duties file pinned to tmp so the guard never touches the
    # real dev/duties.md.
    touch "$BATS_TEST_TMPDIR/backup-blocker"
    export ANTCRATE_BACKUP_DIR="$BATS_TEST_TMPDIR/backup-blocker/backups"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT/myproj"
    jq -n --arg p "$ANTCRATE_ROOT/myproj" \
        '{projects:{myproj:{path:$p,parent:"scripts",linked_nodes:[],git_remote:""}}}' \
        > "$ANTCRATE_REGISTRY"
}

@test "dispatch: refused --rename exits non-zero (aftermath must not mask)" {
    run "$WRAPPER" --rename myproj newname
    [ "$status" -ne 0 ]
    [ -d "$ANTCRATE_ROOT/myproj" ]
    [ ! -d "$ANTCRATE_ROOT/newname" ]
}

@test "dispatch: refused --archive exits non-zero" {
    run "$WRAPPER" --archive myproj
    [ "$status" -ne 0 ]
    [ -d "$ANTCRATE_ROOT/myproj" ]
}

@test "dispatch: successful non-destructive action still exits 0" {
    run "$WRAPPER" list
    [ "$status" -eq 0 ]
}

# --- bak argument-order normalisation (e2e audit 2026-08-07) -----------------
# `help` has always printed the trailing form `bak <p> [ls|restore]` while only
# the leading form `bak ls <p>` dispatched, so the documented invocation died
# with "unknown arg: ls" (exit 2). Both orders must now reach --backups; these
# pin that, and pin that a bare `bak <p>` still means "take a backup" rather
# than being mistaken for a subcommand.

@test "dispatch: bak <p> ls (documented trailing form) reaches the backups list" {
    run "$WRAPPER" bak myproj ls
    [ "$status" -eq 0 ]
    [[ "$output" != *"unknown arg"* ]]
}

@test "dispatch: bak ls <p> (leading form) still reaches the backups list" {
    run "$WRAPPER" bak ls myproj
    [ "$status" -eq 0 ]
    [[ "$output" != *"unknown arg"* ]]
}

@test "dispatch: both bak orders produce identical output" {
    run "$WRAPPER" bak myproj ls
    local trailing="$output"
    run "$WRAPPER" bak ls myproj
    [ "$output" = "$trailing" ]
}

@test "dispatch: bare bak <p> is still a backup request, not a subcommand" {
    # backup dir is unwritable in setup(), so a real backup attempt refuses —
    # that non-zero is the proof it took the --backup path, not --backups.
    run "$WRAPPER" bak myproj
    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown arg"* ]]
}
