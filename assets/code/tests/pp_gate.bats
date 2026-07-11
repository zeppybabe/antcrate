#!/usr/bin/env bats
# --pp non-TTY: dirty tree auto-commits + pushes without -y (audit 2026-07-10)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"

    # project repo with a bare remote
    R="$ANTCRATE_ROOT/proj"
    REMOTE="$BATS_TEST_TMPDIR/remote.git"
    git init -q --bare "$REMOTE"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
        echo "initial" > README.md
        git add README.md
        git commit -qm "initial"
        git remote add origin "$REMOTE"
        git push -q origin master
    )
    export R REMOTE

    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'" ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL=error
        LIB="'"$BATS_TEST_DIRNAME"'/../lib"
        . "$LIB/log.sh"; . "$LIB/registry.sh"
        ac_registry_init
        ac_registry_upsert proj "'"$R"'" scripts ""'
}

@test "pp: non-TTY dirty tree auto-commits and pushes (no -y)" {
    echo "change" >> "$R/README.md"
    run "$BIN" pp proj </dev/null
    [ "$status" -eq 0 ]
    [ -z "$(git -C "$R" status --porcelain)" ]
    run git --git-dir="$REMOTE" log -1 --pretty=%s
    [[ "$output" == antcrate:\ auto-commit* ]]
}
