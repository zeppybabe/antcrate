#!/usr/bin/env bats
# tests for lib/commit.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_COMMIT_PREAPPROVED=1   # bypass interactive prompt for tests
    mkdir -p "$ANTCRATE_HOME"

    # set up a real git repo for the project
    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
        echo "initial" > README.md
        git add README.md
        git commit -qm "initial"
    )
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_COMMIT_PREAPPROVED="'"$ANTCRATE_COMMIT_PREAPPROVED"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/commit.sh"
        '"$1"
}

# ---------- secret-pattern guard (unit) ----------

@test "secret_match: .env" {
    src "ac_commit_secret_match .env"
}

@test "secret_match: .env.production" {
    src "ac_commit_secret_match .env.production"
}

@test "secret_match: server.pem" {
    src "ac_commit_secret_match server.pem"
}

@test "secret_match: id_ed25519" {
    src "ac_commit_secret_match id_ed25519"
}

@test "secret_match: secrets.yaml" {
    src "ac_commit_secret_match secrets.yaml"
}

@test "secret_match: credentials.json" {
    src "ac_commit_secret_match credentials.json"
}

@test "secret_match: .netrc" {
    src "ac_commit_secret_match .netrc"
}

@test "secret_match: README.md is NOT a match" {
    run src "ac_commit_secret_match README.md"
    [ "$status" -ne 0 ]
}

@test "secret_match: main.sh is NOT a match" {
    run src "ac_commit_secret_match main.sh"
    [ "$status" -ne 0 ]
}

# ---------- ac_commit_run (integration) ----------

@test "commit: rejects unknown project" {
    run src "ac_commit_run nonexistent 'msg' all"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown project"* ]]
}

@test "commit: rejects missing -m" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_commit_run proj '' all"
    [ "$status" -ne 0 ]
    [[ "$output" == *"-m <message> required"* ]]
}

@test "commit: rejects missing mode" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_commit_run proj 'msg' ''"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--all-tracked or -- <files...>"* ]]
}

@test "commit: rejects when project path is not a git repo" {
    mkdir -p "$BATS_TEST_TMPDIR/no-git"
    src "ac_registry_upsert nogit '$BATS_TEST_TMPDIR/no-git' scripts ''"
    run src "ac_commit_run nogit 'msg' all"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a git repo"* ]]
}

@test "commit: --all-tracked stages and commits all modifications" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "feature line" >> "$R/README.md"
    echo "new file" > "$R/new.sh"
    run src "ac_commit_run proj 'feat: x' all"
    [ "$status" -eq 0 ]
    # new commit on HEAD
    [ "$(git -C "$R" log --oneline | wc -l)" -eq 2 ]
    [[ "$(git -C "$R" log -1 --pretty=%s)" == "feat: x" ]]
    # both files were committed
    git -C "$R" show --name-only --pretty=format: HEAD | grep -q "new.sh"
    git -C "$R" show --name-only --pretty=format: HEAD | grep -q "README.md"
}

@test "commit: explicit files stages only the listed files" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "modified" >> "$R/README.md"
    echo "untracked" > "$R/extra.sh"
    run src "ac_commit_run proj 'fix: only readme' explicit README.md"
    [ "$status" -eq 0 ]
    # README.md committed; extra.sh remained untracked
    git -C "$R" show --name-only --pretty=format: HEAD | grep -q "README.md"
    ! git -C "$R" show --name-only --pretty=format: HEAD | grep -q "extra.sh"
    [ -f "$R/extra.sh" ]
}

@test "commit: refuses on .env in --all-tracked staged set" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "SECRET=hunter2" > "$R/.env"
    echo "code" > "$R/main.sh"
    run src "ac_commit_run proj 'feat: x' all"
    [ "$status" -ne 0 ]
    [[ "$output" == *"secret-pattern files"* ]]
    [[ "$output" == *".env"* ]]
    # nothing committed; staged set rolled back
    [ "$(git -C "$R" log --oneline | wc -l)" -eq 1 ]
    [ -z "$(git -C "$R" diff --cached --name-only)" ]
}

@test "commit: refuses on server.pem in explicit staged set" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "----- BEGIN PRIVATE KEY -----" > "$R/server.pem"
    run src "ac_commit_run proj 'add cert' explicit server.pem"
    [ "$status" -ne 0 ]
    [[ "$output" == *"server.pem"* ]]
    [ "$(git -C "$R" log --oneline | wc -l)" -eq 1 ]
}

@test "commit: refuses without TTY when not preapproved" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "x" >> "$R/README.md"
    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        unset ANTCRATE_COMMIT_PREAPPROVED
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/registry.sh"; . "'"$LIB"'/commit.sh"
        ac_commit_run proj "feat: x" all < /dev/null
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a TTY"* ]]
    [ "$(git -C "$R" log --oneline | wc -l)" -eq 1 ]
}

@test "commit: nothing-staged is a soft-warn, not an error" {
    src "ac_registry_upsert proj '$R' scripts ''"
    # working tree clean; --all-tracked produces nothing
    run src "ac_commit_run proj 'noop' all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing staged"* ]]
}
