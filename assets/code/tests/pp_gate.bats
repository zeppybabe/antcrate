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

# ── G2 (2026-07-12): dev/ mirror on pp ──────────────────────────────────────

mirror_setup() {   # ignore dev/ in the fixture repo (real projects always do)
    export ANTCRATE_CONFIG="$BATS_TEST_TMPDIR/config"
    printf 'mirror_dev=proj\n' > "$ANTCRATE_CONFIG"
    export ANTCRATE_MIRROR_PREFIX="$BATS_TEST_TMPDIR/hub/"
    # the nested dev repo commits with the GLOBAL git identity — pin one, or
    # these tests track the ambient machine state (green locally, red on a
    # bare CI runner: exactly how run 29178263554 failed)
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git config --file "$GIT_CONFIG_GLOBAL" user.name tester
    git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.com
    git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master
    mkdir -p "$BATS_TEST_TMPDIR/hub"
    ( cd "$R" && echo "dev/" > .gitignore && git add .gitignore && git commit -qm gitignore )
    mkdir -p "$R/dev"; echo "note" > "$R/dev/state.md"
}

@test "pp: mirror_dev project mirrors dev/ after a successful push" {
    mirror_setup
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"mirror"*"proj-dev"* ]]
    [ -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: --no-mirror suppresses the dev mirror for that push" {
    mirror_setup
    run "$BIN" pp proj --no-mirror
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: project not in mirror_dev list is never mirrored" {
    mirror_setup
    printf 'mirror_dev=otherproj\n' > "$ANTCRATE_CONFIG"
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: mirror failure warns but never fails the public push" {
    mirror_setup
    touch "$BATS_TEST_TMPDIR/blocked"
    export ANTCRATE_MIRROR_PREFIX="$BATS_TEST_TMPDIR/blocked/hub/"
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [[ "$output" != *"mirror    :"* ]]
}
