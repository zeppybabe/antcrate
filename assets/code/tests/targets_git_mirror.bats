#!/usr/bin/env bats
# tests for lib/targets/git_mirror.sh — private <project>-dev companion mirror.
# ANTCRATE_MIRROR_PREFIX points at a local dir, so "GitHub" is a tmpdir of bare
# repos and no gh/network is involved (the gh path only runs on https prefixes).

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_CONFIG="$ANTCRATE_HOME/config"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_MIRROR_PREFIX="$BATS_TEST_TMPDIR/hub/"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    git config --file "$GIT_CONFIG_GLOBAL" user.name tester
    git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.com
    git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master
    mkdir -p "$ANTCRATE_HOME" "$BATS_TEST_TMPDIR/hub"
    DEV="$BATS_TEST_TMPDIR/proj/dev"
    mkdir -p "$DEV"
    echo "note one" > "$DEV/state.md"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_CONFIG='$ANTCRATE_CONFIG'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        export ANTCRATE_MIRROR_PREFIX='$ANTCRATE_MIRROR_PREFIX'
        export GIT_CONFIG_GLOBAL='$GIT_CONFIG_GLOBAL'
        . '$LIB/log.sh'; . '$LIB/targets/git_mirror.sh'
        $1
    "
}

@test "git-mirror: scope is dev only" {
    run src "target_git_mirror_scopes"
    [ "$status" -eq 0 ]
    [ "$output" = "dev" ]
}

@test "git-mirror: available succeeds with a local prefix (no gh needed)" {
    run src "target_git_mirror_available"
    [ "$status" -eq 0 ]
}

@test "git-mirror: first push creates the private companion repo and echoes a sha" {
    run src "target_git_mirror_push proj '$DEV'"
    [ "$status" -eq 0 ]
    [ -d "$BATS_TEST_TMPDIR/hub/proj-dev.git" ]
    [[ "$output" =~ ^[0-9a-f]{40}$ ]]
}

@test "git-mirror: dev/ becomes a nested git repo; parent tree untouched" {
    src "target_git_mirror_push proj '$DEV'" >/dev/null
    [ -d "$DEV/.git" ]
    [ ! -d "$BATS_TEST_TMPDIR/proj/.git" ]
}

@test "git-mirror: second push is incremental (two commits on the remote)" {
    src "target_git_mirror_push proj '$DEV'" >/dev/null
    echo "note two" >> "$DEV/state.md"
    run src "target_git_mirror_push proj '$DEV'"
    [ "$status" -eq 0 ]
    [ "$(git -C "$BATS_TEST_TMPDIR/hub/proj-dev.git" rev-list --count master)" -eq 2 ]
}

@test "git-mirror: unchanged dev/ push is a clean no-op echoing the same sha" {
    sha1=$(src "target_git_mirror_push proj '$DEV'")
    run src "target_git_mirror_push proj '$DEV'"
    [ "$status" -eq 0 ]
    [ "$output" = "$sha1" ]
}

@test "git-mirror: list shows the remote head" {
    sha=$(src "target_git_mirror_push proj '$DEV'")
    run src "target_git_mirror_list proj"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$sha"* ]]
}

@test "git-mirror: pull round-trips dev content into dest" {
    src "target_git_mirror_push proj '$DEV'" >/dev/null
    dest="$BATS_TEST_TMPDIR/out"
    run src "target_git_mirror_pull proj '' '$dest'"
    [ "$status" -eq 0 ]
    [ "$(cat "$dest/proj-dev/state.md")" = "note one" ]
}

@test "git-mirror: verify passes on the pushed sha, fails on a bogus one" {
    sha=$(src "target_git_mirror_push proj '$DEV'")
    run src "target_git_mirror_verify proj '$sha'"
    [ "$status" -eq 0 ]
    run src "target_git_mirror_verify proj 0000000000000000000000000000000000000000"
    [ "$status" -ne 0 ]
}

@test "git-mirror: push on a missing dev dir fails cleanly" {
    run src "target_git_mirror_push proj '$BATS_TEST_TMPDIR/proj/nodev'"
    [ "$status" -ne 0 ]
}
