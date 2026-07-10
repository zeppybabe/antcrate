#!/usr/bin/env bats
# `antcrate new` — bundled start + git-init + md-scaffold + agent-init (Plan 2)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_TEMPLATES="$BATS_TEST_DIRNAME/../templates"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    git config --global user.email >/dev/null 2>&1 || {
        export GIT_AUTHOR_EMAIL=t@e.c GIT_AUTHOR_NAME=t
        export GIT_COMMITTER_EMAIL=t@e.c GIT_COMMITTER_NAME=t
    }
}

@test "new: bundles scaffold + git-init + md-scaffold + agent-init" {
    run "$BIN" new bundleproj --domain scripts
    [ "$status" -eq 0 ]
    P=$(jq -r '.projects.bundleproj.path' "$ANTCRATE_REGISTRY")
    [ -d "$P" ]
    [ -d "$P/.git" ]
    [ -f "$P/CLAUDE.md" ]
    [ -f "$P/AGENTS.md" ]
    [ -f "$P/.claude/agents/bundleproj-cody.md" ]
    [ -f "$P/.antcrate/cody-attempts.json" ]
}

# NOTE (Plan 2 finding): --start was ALREADY the full bundle — scaffold.sh does
# git init, and ac_lifecycle_treatment chains agent-init + md-scaffold + hook
# autoinstall. `new` is the compact alias; this file pins the bundle contract.

@test "new: registry entry carries the domain as parent" {
    run "$BIN" new domproj --domain scripts
    [ "$status" -eq 0 ]
    [ "$(jq -r '.projects.domproj.parent' "$ANTCRATE_REGISTRY")" = "scripts" ]
}
