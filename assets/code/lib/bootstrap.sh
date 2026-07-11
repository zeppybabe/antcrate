#!/usr/bin/env bash
# antcrate :: lib/bootstrap.sh — one-liner: git-init + .gitignore + first commit
#
# The "post-register first-commit" sequence as a single flag. Replaces the
# manual dance of: git init → write .gitignore → git add -A → commit. Each
# step is idempotent so re-runs converge instead of erroring.
#
# Composes existing pieces:
#   - ac_git_init           (lib/git_init.sh)        — idempotent git init
#   - default .gitignore    (this file, _writer)     — rule #13 secret denylist
#                                                      + common build/cache giants
#   - ac_commit_run         (lib/commit.sh)          — secret-pattern guard,
#                                                      stages with mode "all"
#   - ac_gh_init_repo       (lib/gh.sh)              — optional --with-remote
#                                                      (private default per #79)
#
# Public API:
#   ac_bootstrap <project> [<msg>] [<with_remote>] [<visibility>]
#
# Internal:
#   _ac_bootstrap_default_gitignore <out_path>
#       # Reason: writes a curated denylist matching the --commit secret-pattern
#       # guard (.env, *.pem, *.key, id_*, *.netrc, credentials.json, secrets.y*ml)
#       # plus common build/cache giants. Bypasses no invariant; documented as
#       # internal because direct callers other than ac_bootstrap should not
#       # exist — clobber-protection lives here.
#
# Sourced by wrapper. Depends on git_init.sh, commit.sh, gh.sh, registry.sh, log.sh.

# _ac_bootstrap_default_gitignore <out_path>
# Writes a default .gitignore. NEVER overwrites — silently no-ops if the file
# already exists. The patterns mirror lib/commit.sh's ac_commit_secret_match
# secret-pattern guard, plus common build/cache giants the cleanup classifier
# already prunes (so the gitignore and cleanup logic agree by construction).
_ac_bootstrap_default_gitignore() {
    local out="$1"
    [[ -f "$out" ]] && return 0
    cat > "$out" <<'GITIGNORE'
# OS / editor junk
.DS_Store
Thumbs.db
*~
*.swp
*.swo

# Logs
*.log

# Local environment (rule #13 — credentials never tracked)
# Patterns mirror lib/commit.sh ac_commit_secret_match.
.env
.env.*
*.pem
*.key
id_rsa
id_dsa
id_ed25519
id_ecdsa
*.p12
*.pfx
secrets.yml
secrets.yaml
*.credentials
credentials.json
.netrc

# Common build / cache giants (mirrors lib/cleanup.sh skip-prune list)
node_modules/
__pycache__/
.venv/
venv/
.tox/
.pytest_cache/
.mypy_cache/
.cache/
.turbo/
.nyc_output/
coverage/
dist/
build/
.next/
target/
GITIGNORE
}

# ac_bootstrap <project> [<msg>] [<with_remote>] [<visibility>]
# One-liner: idempotent git init + default .gitignore + first commit
# (+ optional --with-remote → gh repo create, private default).
#
# Behavior:
#   1. ac_git_init <project> — idempotent (no-op if .git exists)
#   2. Write default .gitignore if absent (never overwrites)
#   3. ac_diagrams_auto_regen — pre-stage refresh so the staged tree.mmd
#      reflects post-bootstrap state (#81 makes the post-commit regen a no-op)
#   4. If working tree has changes, ac_commit_run with mode="all";
#      auto-message "feat(init): bootstrap <project> via antcrate" if msg empty
#   5. If with_remote=1, ac_gh_init_repo with given visibility (default private)
#
# All steps are idempotent. Re-running on a clean tree commits nothing and
# returns 0 without error.
ac_bootstrap() {
    local project="${1:-}"
    local msg="${2:-}"
    local with_remote="${3:-}"
    local visibility="${4:-private}"

    [[ -n "$project" ]] || { ac_error "bootstrap: missing project name"; return 1; }

    if ! ac_registry_has "$project"; then
        ac_error "bootstrap: unknown project '$project' (use --register or --start first)"
        return 1
    fi

    local proj_path
    proj_path=$(ac_registry_get "$project" path) || {
        ac_error "bootstrap: failed to resolve path for '$project'"
        return 1
    }
    [[ -d "$proj_path" ]] || { ac_error "bootstrap: project path missing on disk: $proj_path"; return 1; }

    # Step 1: git init (idempotent)
    ac_git_init "$project" || return 1

    # Step 2: default .gitignore (no-op if present)
    local gitignore="$proj_path/.gitignore"
    if [[ ! -f "$gitignore" ]]; then
        _ac_bootstrap_default_gitignore "$gitignore"
        ac_info "bootstrap: wrote default .gitignore"
    else
        ac_info "bootstrap: .gitignore already exists, leaving unchanged"
    fi

    # Step 3: regen diagrams BEFORE staging so the committed tree.mmd reflects
    # post-bootstrap state (.gitignore visible, etc.). Without this, the staged
    # tree.mmd is stale and the post-commit regen leaves the working tree dirty
    # with a "+.gitignore" diff, breaking idempotency. Bug #81's fix makes the
    # post-commit regen a no-op when nothing semantic changed; this pre-stage
    # regen ensures nothing semantic changes post-commit.
    #
    # Double-call by design: the first regen creates docs/diagrams/tree.mmd
    # itself, which the renderer would then see as a new node on subsequent
    # scans — without the second regen, the scan-shape grows by one node
    # between calls and triggers another commit. Two calls converges. This is
    # the same shape the diagrams.bats "auto_regen stability" test guards.
    ac_diagrams_auto_regen "$project" >/dev/null 2>&1 || true
    ac_diagrams_auto_regen "$project" >/dev/null 2>&1 || true

    # Step 4: commit if there's anything to commit
    if [[ -z "$(git -C "$proj_path" status --porcelain 2>/dev/null)" ]]; then
        ac_info "bootstrap: working tree clean, nothing to commit"
    else
        local commit_msg="${msg:-feat(init): bootstrap $project via antcrate}"
        # Internal approval: the user approved this commit by running the
        # parent command (`antcrate new`) — _AC_APPROVED skips the inner gate.
        if ! _AC_APPROVED=1 ac_commit_run "$project" "$commit_msg" "all"; then
            ac_error "bootstrap: commit failed"
            return 1
        fi
    fi

    # Step 4: optional remote
    if [[ -n "$with_remote" ]]; then
        ac_info "bootstrap: chaining --gh-init (visibility=$visibility)"
        if ! ac_gh_init_repo "$project" "$visibility"; then
            ac_error "bootstrap: --with-remote ac_gh_init_repo failed"
            return 1
        fi
    fi

    return 0
}
