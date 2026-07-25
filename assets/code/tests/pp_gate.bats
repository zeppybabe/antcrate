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
    run git --git-dir="$REMOTE" log -1 --pretty=%s master
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

# ── mirror is DEFAULT-ON (2026-07-24, owner directive) ─────────────────────
#
# Was an opt-in allowlist. The publication boundary now keeps CLAUDE.md, dev/
# and friends out of every public tree by default — and without a mirror that
# material has no home at all, so the boundary quietly became a delete.
# Default-on gives every project its private <project>-dev companion.
# The test below formerly asserted the opposite ("not in the list is never
# mirrored"); it is inverted on purpose, not broken.

@test "pp: a project absent from mirror_dev STILL mirrors (default-on)" {
    mirror_setup
    printf 'mirror_dev=otherproj\n' > "$ANTCRATE_CONFIG"
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: mirrors dev/ with no mirror config present at all" {
    mirror_setup
    : > "$ANTCRATE_CONFIG"          # no mirror_dev key of any kind
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: mirror_dev_exclude opts a single project out" {
    mirror_setup
    printf 'mirror_dev_exclude=proj\n' > "$ANTCRATE_CONFIG"
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: mirror_dev_all=0 restores the legacy opt-in allowlist" {
    mirror_setup
    printf 'mirror_dev_all=0\nmirror_dev=otherproj\n' > "$ANTCRATE_CONFIG"
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [ ! -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: mirror_dev_all=0 still mirrors a project named in the allowlist" {
    mirror_setup
    printf 'mirror_dev_all=0\nmirror_dev=proj\n' > "$ANTCRATE_CONFIG"
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
}

@test "pp: mirror failure warns but never fails the public push" {
    mirror_setup
    touch "$BATS_TEST_TMPDIR/blocked"
    export ANTCRATE_MIRROR_PREFIX="$BATS_TEST_TMPDIR/blocked/hub/"
    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [[ "$output" != *"mirror    :"* ]]
}

# ── auto-provisioning (2026-07-24): the boundary must never outrun the mirror ──
#
# Regression guard for a failure found on a LIVE push, not in review: rfm-music
# and antcrate-mcp pushed clean, printed no mirror line, and created no -dev
# repo, because they keep their records at the repo root and had no dev/ tree.
# The boundary hid those files from the public remote while nothing backed them
# up. pp now provisions dev/ and syncs dev/context/ before mirroring.

@test "pp: a project with NO dev/ still gets a mirror (auto-provisioned)" {
    export ANTCRATE_CONFIG="$BATS_TEST_TMPDIR/config"
    : > "$ANTCRATE_CONFIG"
    export ANTCRATE_MIRROR_PREFIX="$BATS_TEST_TMPDIR/hub/"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git config --file "$GIT_CONFIG_GLOBAL" user.name tester
    git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.com
    git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master
    mkdir -p "$BATS_TEST_TMPDIR/hub"
    # records at the ROOT, no dev/ anywhere — the exact broken shape
    echo "project context" > "$R/CLAUDE.md"
    [ ! -d "$R/dev" ]

    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"mirror"*"proj-dev"* ]]
    [ -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
    # and the root context actually reached the companion
    [ -f "$R/dev/context/CLAUDE.md" ]
}

@test "pp: auto-provisioning keeps the root CLAUDE.md out of the PUBLIC remote" {
    export ANTCRATE_CONFIG="$BATS_TEST_TMPDIR/config"
    : > "$ANTCRATE_CONFIG"
    export ANTCRATE_MIRROR_PREFIX="$BATS_TEST_TMPDIR/hub/"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git config --file "$GIT_CONFIG_GLOBAL" user.name tester
    git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.com
    git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master
    mkdir -p "$BATS_TEST_TMPDIR/hub"
    echo "project context" > "$R/CLAUDE.md"

    run "$BIN" pp proj
    [ "$status" -eq 0 ]
    run git --git-dir="$REMOTE" log --name-only --format= -20
    [[ "$output" != *"CLAUDE.md"* ]]
}
