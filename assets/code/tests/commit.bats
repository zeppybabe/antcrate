#!/usr/bin/env bats
# tests for lib/commit.sh

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
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
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/safety.sh"
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

@test "commit: non-TTY proceeds without PREAPPROVED (audit 2026-07-10)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "x" >> "$R/README.md"
    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        unset ANTCRATE_COMMIT_PREAPPROVED
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/registry.sh"; . "'"$LIB"'/safety.sh"; . "'"$LIB"'/commit.sh"
        ac_commit_run proj "feat: x" all < /dev/null
    '
    [ "$status" -eq 0 ]
    [ "$(git -C "$R" log --oneline | wc -l)" -eq 2 ]
    [ "$(git -C "$R" log -1 --pretty=%s)" = "feat: x" ]
}

@test "commit: ASSUME_TTY decline aborts, staged set preserved" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "y" >> "$R/README.md"
    run bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        unset ANTCRATE_COMMIT_PREAPPROVED
        export ANTCRATE_ASSUME_TTY=1
        . "'"$LIB"'/log.sh"; . "'"$LIB"'/registry.sh"; . "'"$LIB"'/safety.sh"; . "'"$LIB"'/commit.sh"
        ac_commit_run proj "declined" all <<< "n"
    '
    [ "$status" -eq 0 ]
    # ac_warn is level-suppressed in tests; the behavioral contract is: no commit
    [ "$(git -C "$R" log --oneline | wc -l)" -eq 1 ]
}

@test "commit: nothing-staged is a soft-warn, not an error" {
    src "ac_registry_upsert proj '$R' scripts ''"
    # working tree clean; --all-tracked produces nothing
    run src "ac_commit_run proj 'noop' all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing staged"* ]]
}

@test "commit: explicit mode stages a pre-staged deletion (git rm'd path)" {
    src "ac_registry_upsert proj '$R' scripts ''"
    git -C "$R" rm -q README.md
    run src "ac_commit_run proj 'chore: drop readme' explicit README.md"
    [ "$status" -eq 0 ]
    [ ! -f "$R/README.md" ]
    git -C "$R" show --name-only --pretty=format: HEAD | grep -q "README.md"
}

# ---------- finding D: an abort must not destroy pre-existing staging ----------
#
# Both abort paths used to run `git reset HEAD`, which unstages EVERYTHING —
# including work the user staged (often via `git add -p`) before ever invoking
# antcrate. The wrapper may only undo what the wrapper itself staged.

@test "commit: secret-guard abort preserves the user's pre-existing staged work" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "hand-staged work" > "$R/notes.txt"
    git -C "$R" add notes.txt
    echo "KEY=abc" > "$R/.env"

    run src "ac_commit_run proj 'msg' explicit .env"
    [ "$status" -eq 2 ]
    # the .env must be gone from the index, the user's notes.txt must survive
    run git -C "$R" diff --cached --name-only
    [[ "$output" == *"notes.txt"* ]]
    [[ "$output" != *".env"* ]]
}

@test "commit: abort preserves partial (add -p style) staged CONTENT, not just filenames" {
    src "ac_registry_upsert proj '$R' scripts ''"
    printf 'staged-version\n' > "$R/work.txt"
    git -C "$R" add work.txt
    printf 'worktree-version\n' > "$R/work.txt"   # index now differs from worktree
    echo "KEY=abc" > "$R/.env"

    run src "ac_commit_run proj 'msg' explicit .env"
    [ "$status" -eq 2 ]
    # the exact staged blob must come back, not merely the path
    run git -C "$R" show :work.txt
    [ "$status" -eq 0 ]
    [[ "$output" == "staged-version" ]]
}

@test "commit: failed explicit stage preserves pre-existing staged work" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "hand-staged work" > "$R/notes.txt"
    git -C "$R" add notes.txt

    run src "ac_commit_run proj 'msg' explicit does-not-exist.txt"
    [ "$status" -eq 1 ]
    run git -C "$R" diff --cached --name-only
    [[ "$output" == *"notes.txt"* ]]
}

# ---------- finding E: secrets in file CONTENT, not just in file NAMES ----------
#
# The basename guard only ever saw names. A key pasted into config.py committed
# clean. The literals below are assembled at runtime on purpose: a contiguous
# key in this file would be caught by the very guard it tests, blocking our own
# commits of this test file.

@test "commit: refuses a secret pasted INTO an innocently-named source file" {
    command -v gitleaks >/dev/null 2>&1 || skip "gitleaks unavailable"
    src "ac_registry_upsert proj '$R' scripts ''"
    { printf 'AWS_KEY = "%s%s"\n' 'AKIA' 'Z3MHW7QK2NRDPLXV'
      printf 'TOKEN = "%s%s"\n'   'ghp_' '9fK2mQ7xR4tZ1wY8vB3nC6jH0sL5dG2aE7pU'
    } > "$R/config.py"

    run src "ac_commit_run proj 'feat: config' explicit config.py"
    [ "$status" -eq 2 ]
    [[ "$output" == *"secret"* ]]
    # nothing may be committed, and the index must be clean of it
    run git -C "$R" diff --cached --name-only
    [[ "$output" != *"config.py"* ]]
}

@test "commit: ordinary source content still commits (content guard is not trigger-happy)" {
    command -v gitleaks >/dev/null 2>&1 || skip "gitleaks unavailable"
    src "ac_registry_upsert proj '$R' scripts ''"
    printf 'def main():\n    return "hello"\n' > "$R/app.py"

    run src "ac_commit_run proj 'feat: app' explicit app.py"
    [ "$status" -eq 0 ]
    git -C "$R" show --name-only --pretty=format: HEAD | grep -q "app.py"
}
