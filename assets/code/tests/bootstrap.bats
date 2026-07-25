#!/usr/bin/env bats
# tests for lib/bootstrap.sh

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    echo "Hello" > "$R/README.md"
    export R

    # git needs a committer identity for ac_commit_run to succeed.
    # Set per-invocation via env so we don't touch the user's global config.
    export GIT_AUTHOR_NAME="bats-test"
    export GIT_AUTHOR_EMAIL="bats@example.com"
    export GIT_COMMITTER_NAME="bats-test"
    export GIT_COMMITTER_EMAIL="bats@example.com"
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export GIT_AUTHOR_NAME="'"$GIT_AUTHOR_NAME"'"
        export GIT_AUTHOR_EMAIL="'"$GIT_AUTHOR_EMAIL"'"
        export GIT_COMMITTER_NAME="'"$GIT_COMMITTER_NAME"'"
        export GIT_COMMITTER_EMAIL="'"$GIT_COMMITTER_EMAIL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/address.sh"
        . "'"$LIB"'/devops.sh"
        . "'"$LIB"'/diagrams.sh"
        . "'"$LIB"'/commit.sh"
        . "'"$LIB"'/git_init.sh"
        . "'"$LIB"'/bootstrap.sh"
        '"$1"
}

@test "bootstrap: creates .git + writes .gitignore + commits initial" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_bootstrap proj"
    [ "$status" -eq 0 ]
    [ -d "$R/.git" ]
    [ -f "$R/.gitignore" ]
    grep -q '^\.env$' "$R/.gitignore"
    out=$(git -C "$R" log --oneline)
    [ -n "$out" ]
}

@test "bootstrap: idempotent on second call (clean tree)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_bootstrap proj"
    first_sha=$(git -C "$R" rev-parse HEAD)
    run src "ac_bootstrap proj"
    [ "$status" -eq 0 ]
    second_sha=$(git -C "$R" rev-parse HEAD)
    [ "$first_sha" = "$second_sha" ]
}

@test "bootstrap: leaves working tree clean after first commit (no tree.mmd loop)" {
    src "ac_registry_upsert proj '$R' scripts ''
         ac_bootstrap proj"
    out=$(git -C "$R" status --porcelain)
    [ -z "$out" ]   # nothing dirty after first bootstrap
}

@test "bootstrap: respects existing .gitignore (does not overwrite)" {
    echo "# my custom ignore" > "$R/.gitignore"
    echo "/private/" >> "$R/.gitignore"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_bootstrap proj"
    [ "$status" -eq 0 ]
    grep -q '^# my custom ignore$' "$R/.gitignore"
    grep -q '^/private/$' "$R/.gitignore"
    # The default-write would have added .env; verify it didn't
    ! grep -q '^\.env$' "$R/.gitignore"
}

@test "bootstrap: -m custom message used in commit" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_bootstrap proj 'feat(init): custom bootstrap message'"
    [ "$status" -eq 0 ]
    out=$(git -C "$R" log -1 --pretty=%s)
    [ "$out" = "feat(init): custom bootstrap message" ]
}

@test "bootstrap: auto-message used when -m omitted" {
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_bootstrap proj"
    [ "$status" -eq 0 ]
    out=$(git -C "$R" log -1 --pretty=%s)
    [ "$out" = "feat(init): bootstrap proj via antcrate" ]
}

@test "bootstrap: errors when project unregistered" {
    run src "ac_bootstrap nonexistent"
    [ "$status" -ne 0 ]
    [ ! -d "$R/.git" ]
}

@test "bootstrap: errors when project name missing" {
    run src "ac_bootstrap"
    [ "$status" -ne 0 ]
}

@test "bootstrap: secret-pattern guard catches .env not gitignored" {
    # Pre-create a custom .gitignore that does NOT exclude .env
    printf '*.log\n' > "$R/.gitignore"
    # Plant a .env file that would be staged
    printf 'SECRET=abc\n' > "$R/.env"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_bootstrap proj"
    [ "$status" -ne 0 ]
    # No commit should have landed
    run git -C "$R" log -1 --oneline
    [ "$status" -ne 0 ]
}

@test "bootstrap: works on a tree with only a single tracked file" {
    # Edge case: minimum viable tree
    rm -f "$R/README.md"
    echo "x" > "$R/only.txt"
    run src "ac_registry_upsert proj '$R' scripts ''
             ac_bootstrap proj"
    [ "$status" -eq 0 ]
    [ -d "$R/.git" ]
    out=$(git -C "$R" ls-files)
    grep -q '^only.txt$' <<< "$out"
}

# ---------- publication boundary (2026-07-24) ----------
#
# The boundary lives in .git/info/exclude, NOT .gitignore. Owner ruling: signs
# of AI/dev tooling belong in the private -dev companion, and a COMMITTED
# .gitignore line reading "/CLAUDE.md" announces exactly what it conceals.
# info/exclude protects identically and is never committed.

@test "bootstrap: publication boundary is provisioned into info/exclude" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_bootstrap proj 'initial'"
    [ "$status" -eq 0 ]
    for pat in '^/CLAUDE\.md$' '^/AGENTS\.md$' '^/\.claude/$' '^dev/$' '^X-POSTS\.md$'; do
        grep -qE "$pat" "$R/.git/info/exclude" || { echo "MISSING from info/exclude: $pat"; false; }
    done
}

@test "bootstrap: the committed .gitignore carries NO AI trace" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_bootstrap proj 'initial'"
    [ "$status" -eq 0 ]
    for trace in CLAUDE AGENTS '\.claude' '\.cursor' copilot; do
        run grep -qE "$trace" "$R/.gitignore"
        [ "$status" -ne 0 ] || { echo "AI TRACE in committed .gitignore: $trace"; false; }
    done
}

@test "bootstrap: agent-context ignores are anchored, not global" {
    src "ac_registry_upsert proj '$R' scripts ''"
    run src "ac_bootstrap proj 'initial'"
    [ "$status" -eq 0 ]
    # a project that legitimately ships docs/CLAUDE.md must keep it
    mkdir -p "$R/docs"
    echo "public doc" > "$R/docs/CLAUDE.md"
    run git -C "$R" check-ignore -q docs/CLAUDE.md
    [ "$status" -ne 0 ]
    # ...while the root copy stays ignored
    echo "private context" > "$R/CLAUDE.md"
    run git -C "$R" check-ignore -q CLAUDE.md
    [ "$status" -eq 0 ]
}

@test "bootstrap: first commit never carries dev context" {
    src "ac_registry_upsert proj '$R' scripts ''"
    echo "private context" > "$R/CLAUDE.md"
    mkdir -p "$R/.claude"; echo "agent" > "$R/.claude/a.md"
    run src "ac_bootstrap proj 'initial'"
    [ "$status" -eq 0 ]
    run git -C "$R" log --name-only --format= -5
    [[ "$output" != *"CLAUDE.md"* ]]
    [[ "$output" != *".claude"* ]]
}
