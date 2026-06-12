#!/usr/bin/env bats
# tests for hooks/templates/pre-commit-docsguard + pre-push-docsguard —
# documentation-as-secrets guards (markdown + docs/ never committed/pushed).

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    TPL="$BATS_TEST_DIRNAME/../hooks/templates"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R/src"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
    )
    # render = strip the placeholder lines the installer substitutes
    for t in pre-commit-docsguard pre-push-docsguard; do
        sed 's/__PROJECT_NAME__/proj/; s/^# __ANTCRATE_BYPASS_CHECK__$//' \
            "$TPL/$t" > "$BATS_TEST_TMPDIR/$t"
        chmod +x "$BATS_TEST_TMPDIR/$t"
    done
    export R
}

# ---------- pre-commit-docsguard ----------

@test "pre-commit: staged .md file is refused" {
    cd "$R"
    echo "secret spec" > design.md
    git add design.md
    run "$BATS_TEST_TMPDIR/pre-commit-docsguard"
    [ "$status" -eq 1 ]
    [[ "$output" == *"design.md"* ]]
}

@test "pre-commit: staged docs/ file is refused (any extension)" {
    cd "$R"
    mkdir -p docs
    echo "notes" > docs/notes.txt
    git add -f docs/notes.txt
    run "$BATS_TEST_TMPDIR/pre-commit-docsguard"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docs/notes.txt"* ]]
}

@test "pre-commit: nested docs/ path is refused" {
    cd "$R"
    mkdir -p src/docs
    echo "x" > src/docs/inner.txt
    git add -f src/docs/inner.txt
    run "$BATS_TEST_TMPDIR/pre-commit-docsguard"
    [ "$status" -eq 1 ]
}

@test "pre-commit: code-only staging passes" {
    cd "$R"
    echo "int main(){}" > src/main.cpp
    git add src/main.cpp
    run "$BATS_TEST_TMPDIR/pre-commit-docsguard"
    [ "$status" -eq 0 ]
}

@test "pre-commit: empty index passes" {
    cd "$R"
    run "$BATS_TEST_TMPDIR/pre-commit-docsguard"
    [ "$status" -eq 0 ]
}

# ---------- pre-push-docsguard ----------

push_line() {
    # push_line <local_sha> <remote_sha>
    printf 'refs/heads/master %s refs/heads/master %s\n' "$1" "$2"
}

@test "pre-push: new-branch push with .md in history is refused" {
    cd "$R"
    echo "spec" > leak.md
    git add -f leak.md && git commit -qm "oops"
    sha=$(git rev-parse HEAD)
    run bash -c "$(printf '%q' "$BATS_TEST_TMPDIR/pre-push-docsguard")" \
        < <(push_line "$sha" "0000000000000000000000000000000000000000")
    [ "$status" -eq 1 ]
    [[ "$output" == *"leak.md"* ]]
}

@test "pre-push: clean history passes" {
    cd "$R"
    echo "int main(){}" > src/main.cpp
    git add src/main.cpp && git commit -qm "code"
    sha=$(git rev-parse HEAD)
    run bash -c "$(printf '%q' "$BATS_TEST_TMPDIR/pre-push-docsguard")" \
        < <(push_line "$sha" "0000000000000000000000000000000000000000")
    [ "$status" -eq 0 ]
}

@test "pre-push: only outgoing range is scanned on ref update" {
    cd "$R"
    # base commit contains a doc — but it is BEHIND the remote sha, so a
    # subsequent clean push must pass (the doc never leaves again)
    echo "old" > old.md
    git add -f old.md && git commit -qm "old doc"
    base=$(git rev-parse HEAD)
    echo "int main(){}" > src/main.cpp
    git add src/main.cpp && git commit -qm "code"
    tip=$(git rev-parse HEAD)
    run bash -c "$(printf '%q' "$BATS_TEST_TMPDIR/pre-push-docsguard")" \
        < <(push_line "$tip" "$base")
    [ "$status" -eq 0 ]
}

@test "pre-push: doc inside outgoing range is refused" {
    cd "$R"
    echo "int main(){}" > src/main.cpp
    git add src/main.cpp && git commit -qm "code"
    base=$(git rev-parse HEAD)
    mkdir -p docs && echo "spec" > docs/spec.txt
    git add -f docs/spec.txt && git commit -qm "doc"
    tip=$(git rev-parse HEAD)
    run bash -c "$(printf '%q' "$BATS_TEST_TMPDIR/pre-push-docsguard")" \
        < <(push_line "$tip" "$base")
    [ "$status" -eq 1 ]
    [[ "$output" == *"docs/spec.txt"* ]]
}

@test "pre-push: ref deletion passes (nothing leaves)" {
    cd "$R"
    run bash -c "$(printf '%q' "$BATS_TEST_TMPDIR/pre-push-docsguard")" \
        < <(push_line "0000000000000000000000000000000000000000" "deadbeef")
    [ "$status" -eq 0 ]
}

@test "pre-push: empty stdin passes" {
    cd "$R"
    run bash -c "$(printf '%q' "$BATS_TEST_TMPDIR/pre-push-docsguard")" < /dev/null
    [ "$status" -eq 0 ]
}
