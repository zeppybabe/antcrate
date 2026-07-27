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

# ---------- prune goes through quarantine, not through rm ----------
#
# Duty 2026-07-25 (audit finding E). The prune arm fires when a root record is
# gone from the working tree — which is exactly when the context copy is the
# LAST copy. `rm -rf -- "$dst"` there destroyed the backup unattended, from
# every pp, with no capture. The refresh arm is different: the original still
# exists, so a plain audited unlink is correct and quarantining every push
# would fill the quarantine with duplicates of live files.

qdirs() {
    find "$ANTCRATE_HOME/quarantine" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort
}

@test "devsync: prune captures the stale context copy into quarantine" {
    echo "temp" > "$R/AGENTS.md"
    src "ac_dev_ensure '$R'"
    rm "$R/AGENTS.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ ! -e "$R/dev/context/AGENTS.md" ]
    [ "$(qdirs | wc -l)" -eq 1 ]
    [[ "$(qdirs)" == *"__devsync-prune__AGENTS.md" ]]
}

@test "devsync: the quarantined prune payload still holds the deleted content" {
    echo "irreplaceable" > "$R/AGENTS.md"
    src "ac_dev_ensure '$R'"
    rm "$R/AGENTS.md"
    src "ac_dev_ensure '$R'"
    local q; q=$(qdirs)
    [ -f "$q/payload.tar.gz" ]
    tar xzf "$q/payload.tar.gz" -C "$BATS_TEST_TMPDIR"
    [ "$(cat "$BATS_TEST_TMPDIR/payload")" = "irreplaceable" ]
}

@test "devsync: the prune manifest records where the copy came from" {
    echo "temp" > "$R/AGENTS.md"
    src "ac_dev_ensure '$R'"
    rm "$R/AGENTS.md"
    src "ac_dev_ensure '$R'"
    local q; q=$(qdirs)
    [ "$(jq -r .op          "$q/manifest.json")" = "devsync-prune" ]
    [ "$(jq -r .project     "$q/manifest.json")" = "proj" ]
    [ "$(jq -r .original_path "$q/manifest.json")" = "$R/dev/context/AGENTS.md" ]
}

@test "devsync: prune captures a directory tree, not just files" {
    mkdir -p "$R/.claude/agents"
    echo "agent def" > "$R/.claude/agents/cody.md"
    src "ac_dev_ensure '$R'"
    [ -f "$R/dev/context/.claude/agents/cody.md" ]
    rm -rf "$R/.claude"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ ! -e "$R/dev/context/.claude" ]
    local q; q=$(qdirs)
    tar xzf "$q/payload.tar.gz" -C "$BATS_TEST_TMPDIR"
    [ "$(cat "$BATS_TEST_TMPDIR/payload/agents/cody.md")" = "agent def" ]
}

@test "devsync: a refresh does NOT quarantine — the original still exists" {
    echo "v1" > "$R/CLAUDE.md"
    src "ac_dev_ensure '$R'"
    echo "v2" > "$R/CLAUDE.md"
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ "$(cat "$R/dev/context/CLAUDE.md")" = "v2" ]
    [ -z "$(qdirs)" ]
}

@test "devsync: a prune with nothing mirrored creates no quarantine entry" {
    run src "ac_dev_ensure '$R'"
    [ "$status" -eq 0 ]
    [ -z "$(qdirs)" ]
}

# The fail-safe direction matters more than the happy path: if the capture
# cannot be written, the copy must SURVIVE. Deleting it anyway would be the
# original bug with an extra step.
@test "devsync: a failed capture keeps the context copy instead of destroying it" {
    echo "irreplaceable" > "$R/AGENTS.md"
    src "ac_dev_ensure '$R'"
    rm "$R/AGENTS.md"

    # a regular file where the quarantine root's parent must be — mkdir fails
    : > "$BATS_TEST_TMPDIR/blocker"
    ANTCRATE_HOME="$BATS_TEST_TMPDIR/blocker/home" \
    ANTCRATE_LOG_LEVEL=warn \
        run src "ac_dev_ensure '$R'"

    [ "$status" -eq 0 ]
    [ "$(cat "$R/dev/context/AGENTS.md")" = "irreplaceable" ]
    [[ "$output" == *"keeping the context copy"* ]]
}

# The refresh arm's refusal branch. Without a case that reaches it, the
# _ac_unlink_internal guard on that path is untested code.
@test "devsync: a context entry symlinked out of the mirror is not written through" {
    echo "v1" > "$R/CLAUDE.md"
    src "ac_dev_ensure '$R'"
    echo "outside" > "$BATS_TEST_TMPDIR/outside.md"
    rm "$R/dev/context/CLAUDE.md"
    ln -s "$BATS_TEST_TMPDIR/outside.md" "$R/dev/context/CLAUDE.md"
    echo "v2" > "$R/CLAUDE.md"

    ANTCRATE_LOG_LEVEL=warn run src "ac_dev_ensure '$R'"

    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/outside.md")" = "outside" ]
    [[ "$output" == *"leaving it as is"* ]]
}
