#!/usr/bin/env bats
# ac_pp_panel — the bundled pre-push panel (Plan 2, audit 2026-07-10)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"

    R="$ANTCRATE_ROOT/proj"
    REMOTE="$BATS_TEST_TMPDIR/remote.git"
    git init -q --bare "$REMOTE"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email t@e.c; git config user.name t
        echo one > f.txt; git add f.txt; git commit -qm "first"
        git tag v0.1.0
        git remote add origin "$REMOTE"
        git push -q -u origin master 2>/dev/null
        echo two >> f.txt; git commit -qam "second"
        git tag v0.2.0-rc1
        echo dirty >> f.txt
    )
    mkdir -p "$R/dev"
    printf '# L\n\n## 2026-07-10 — current milestone head\n\nx\n\n## 2026-07-01 — previous milestone head\n' > "$R/dev/ledger.md"
    export R REMOTE
}

panel() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'" ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_LOG_LEVEL=error ANTCRATE_DUTIES_FILE="'"$ANTCRATE_DUTIES_FILE"'"
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/pp.sh"
        ac_pp_panel proj "'"$1"'"'
}

@test "panel: versions — last tag, stable filters prerelease, current dirty" {
    run panel "$R"
    [ "$status" -eq 0 ]
    [[ "$output" == *"last=v0.2.0-rc1"* ]]
    [[ "$output" == *"stable=v0.1.0"* ]]
    [[ "$output" == *"-dirty"* ]]
}

@test "panel: unpushed count and working changes" {
    run panel "$R"
    [[ "$output" == *"unpushed  : 1 commit(s)"* ]]
    # 2 = modified f.txt + untracked dev/ (the fixture ledger)
    [[ "$output" == *"working   : 2 change(s)"* ]]
}

@test "panel: milestone from dev/ledger.md heads" {
    run panel "$R"
    [[ "$output" == *"milestone : 2026-07-10 — current milestone head"* ]]
    [[ "$output" == *"previous  : 2026-07-01 — previous milestone head"* ]]
}

@test "panel: tagless repo degrades to (none)" {
    T="$ANTCRATE_ROOT/tagless"; mkdir -p "$T"
    ( cd "$T"; git init -q -b master; git config user.email t@e.c; git config user.name t
      echo x > f; git add f; git commit -qm i )
    run panel "$T"
    [ "$status" -eq 0 ]
    [[ "$output" == *"last=(none)"* ]]
}

@test "panel: non-git path degrades without error" {
    N="$ANTCRATE_ROOT/plain"; mkdir -p "$N"
    run panel "$N"
    [ "$status" -eq 0 ]
}
