#!/usr/bin/env bats
# tests for lib/devsync.sh — automatic dev/ provisioning + local-only context sync
#
# Problem this closes (found 2026-07-24 on a real push): the publication
# boundary git-ignores CLAUDE.md, AGENTS.md, .claude/ and the record files, but
# the mirror only carries dev/. A project that keeps its records at the repo
# ROOT therefore gets the boundary (files hidden from the public tree) WITHOUT
# the mirror (no backup anywhere) — the boundary silently becomes a delete.
#
# The fix cannot be "move them into dev/": Claude Code reads CLAUDE.md and
# .claude/ at the project root, so relocating them breaks agent discovery.
# Instead the local-only root surface is SYNCED into dev/context/.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

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
        . "'"$LIB"'/git.sh"
        . "'"$LIB"'/devsync.sh"
        '"$1"
}

# ---------- dev/ provisioning ----------

@test "devsync: creates dev/ when the project has none" {
    [ ! -d "$R/dev" ]
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ -d "$R/dev" ]
}

@test "devsync: is idempotent — a second run changes nothing" {
    src "ac_dev_ensure '$R'"
    echo "handwritten" > "$R/dev/notes.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ "$(cat "$R/dev/notes.md")" = "handwritten" ]
}

@test "devsync: writes the publication boundary into .git/info/exclude" {
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    grep -qE '^/CLAUDE\.md$' "$R/.git/info/exclude"
    grep -qE '^dev/$'         "$R/.git/info/exclude"
}

@test "devsync: does not duplicate the boundary block on re-run" {
    src "ac_dev_ensure '$R'"
    src "ac_dev_ensure '$R'"
    [ "$(grep -c '^/CLAUDE\.md$' "$R/.git/info/exclude")" -eq 1 ]
}

# ---------- AI-TRACE-FREE: nothing lands in the committed .gitignore ----------
#
# Owner ruling 2026-07-24: signs of AI are dev tooling and belong in the -dev
# companion, so a public repo must not advertise them. A .gitignore line saying
# '/CLAUDE.md' announces exactly what it was meant to conceal. info/exclude
# protects identically and is never committed.

@test "devsync: leaves NO AI trace in the committed .gitignore" {
    printf 'node_modules/\n' > "$R/.gitignore"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    for trace in CLAUDE AGENTS '\.claude' '\.cursor' copilot; do
        run grep -qE "$trace" "$R/.gitignore"
        [ "$status" -ne 0 ] || { echo "AI TRACE leaked into .gitignore: $trace"; false; }
    done
}

@test "devsync: does not modify .gitignore at all" {
    printf 'node_modules/\n' > "$R/.gitignore"
    local before; before=$(cat "$R/.gitignore")
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ "$(cat "$R/.gitignore")" = "$before" ]
}

@test "devsync: boundary still works with no .gitignore in the repo at all" {
    rm -f "$R/.gitignore"
    echo "context" > "$R/CLAUDE.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ ! -f "$R/.gitignore" ]
    run git -C "$R" check-ignore -q CLAUDE.md
    [ "$status" -eq 0 ]
}

# ---------- the actual gap: local-only root surface reaches the mirror ----------

@test "devsync: syncs local-only root records into dev/context/" {
    echo "project context" > "$R/CLAUDE.md"
    echo "agent rules"     > "$R/AGENTS.md"
    echo "log"             > "$R/ledger.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ "$(cat "$R/dev/context/CLAUDE.md")" = "project context" ]
    [ "$(cat "$R/dev/context/AGENTS.md")" = "agent rules" ]
    [ "$(cat "$R/dev/context/ledger.md")" = "log" ]
}

@test "devsync: leaves the originals at the project root (tooling reads them there)" {
    echo "project context" > "$R/CLAUDE.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    # Claude Code looks for CLAUDE.md at the root — a move would break it
    [ -f "$R/CLAUDE.md" ]
}

@test "devsync: syncs the .claude/ directory tree, not just top-level files" {
    mkdir -p "$R/.claude/agents"
    echo "agent def" > "$R/.claude/agents/cody.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ "$(cat "$R/dev/context/.claude/agents/cody.md")" = "agent def" ]
}

@test "devsync: refreshes context on re-run when a root record changes" {
    echo "v1" > "$R/CLAUDE.md"
    src "ac_dev_ensure '$R'"
    echo "v2" > "$R/CLAUDE.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ "$(cat "$R/dev/context/CLAUDE.md")" = "v2" ]
}

@test "devsync: never copies PUBLISHED files into context (only local-only ones)" {
    echo "public readme" > "$R/README.md"   # tracked, not ignored
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ ! -e "$R/dev/context/README.md" ]
}

@test "devsync: a secret at the root is NOT swept into the mirror" {
    # .env is ignored, but it is a credential — the mirror is a backup of dev
    # context, not a place to replicate secrets into a second remote.
    echo "API_KEY=live" > "$R/.env"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ ! -e "$R/dev/context/.env" ]
}

@test "devsync: prunes context entries whose root file was deleted" {
    echo "temp" > "$R/AGENTS.md"
    src "ac_dev_ensure '$R'"
    [ -f "$R/dev/context/AGENTS.md" ]
    rm "$R/AGENTS.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ ! -e "$R/dev/context/AGENTS.md" ]
}

@test "devsync: refuses a path that is not a git working tree" {
    mkdir -p "$BATS_TEST_TMPDIR/plain"
    run src "ac_dev_ensure '$BATS_TEST_TMPDIR/plain'"
    [ "$status" -ne 0 ]
}

# ---------- retrofit: a file already tracked must be untracked ----------
#
# Adding a path to .gitignore does NOT untrack it — git keeps honouring the
# index. rfm-music, antcrate-mcp and circular-pong were all in this state and
# had to be fixed by hand; that step is now automatic.

@test "devsync: untracks a root record that was already committed" {
    echo "context" > "$R/CLAUDE.md"
    git -C "$R" add CLAUDE.md
    git -C "$R" commit -qm "add claude md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    run git -C "$R" ls-files --error-unmatch CLAUDE.md
    [ "$status" -ne 0 ]
    # ...but the file itself survives on disk
    [ -f "$R/CLAUDE.md" ]
}

@test "devsync: untracking never touches a published file" {
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    git -C "$R" ls-files --error-unmatch README.md
}
