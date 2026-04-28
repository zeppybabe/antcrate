#!/usr/bin/env bash
# antcrate :: lib/gh.sh — GitHub HTTPS integration via gh CLI
#
# Uses the user's existing `gh auth` credentials (stored by gh in the system keychain
# or ~/.config/gh/hosts.yml). Never reads or writes PATs in plaintext.

ac_gh_check() {
    if ! command -v gh >/dev/null 2>&1; then
        ac_error "gh: GitHub CLI not installed. Install: https://cli.github.com/"
        return 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        ac_error "gh: not authenticated. Run: gh auth login -h github.com -p https"
        return 1
    fi
    return 0
}

# ac_gh_init_repo <project> [private|public]
# Creates remote repo via gh, sets HTTPS origin on local clone, pushes initial commit.
ac_gh_init_repo() {
    local project="$1" visibility="${2:-private}"
    ac_gh_check || return 1

    if ! ac_registry_has "$project"; then
        ac_error "gh: unknown project '$project'"; return 1
    fi
    local path; path=$(ac_registry_get "$project" path)
    [[ -d "$path" ]] || { ac_error "gh: path missing: $path"; return 1; }

    # gh user
    local user; user=$(gh api user -q .login 2>/dev/null) || {
        ac_error "gh: failed to fetch authenticated user"; return 1; }
    local https_url="https://github.com/${user}/${project}.git"

    cd "$path" || return 1

    # ensure local repo has at least one commit
    if [[ ! -d .git ]]; then
        git init -q
    fi
    if ! git rev-parse HEAD >/dev/null 2>&1; then
        git add -A
        git commit -qm "antcrate: initial commit ($project)" || true
    fi

    # create remote (idempotent — if it exists, gh exits non-zero; we tolerate)
    ac_info "gh: creating ${visibility} repo ${user}/${project}"
    if gh repo view "${user}/${project}" >/dev/null 2>&1; then
        ac_warn "gh: repo ${user}/${project} already exists — skipping create"
    else
        gh repo create "${user}/${project}" "--${visibility}" \
            --source=. --remote=origin --push 2>&1 | sed 's/^/  gh: /' || {
            ac_error "gh: repo create failed"; return 1; }
        # gh repo create with --source already wires the origin; no further work needed
        ac_registry_set_remote "$project" "$https_url"
        ac_info "gh: $project → $https_url"
        return 0
    fi

    # repo existed; just wire origin if missing and push
    if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "$https_url"
    fi
    ac_registry_set_remote "$project" "$https_url"

    # push current branch tracking
    local branch; branch=$(git rev-parse --abbrev-ref HEAD)
    git push -u origin "$branch" 2>&1 | sed 's/^/  git: /' || {
        ac_warn "gh: initial push failed (the triage flow will engage on next --pp)"
        return 1; }
    ac_info "gh: $project pushed to $https_url"
}

# ac_gh_login_hint — print onboarding instructions
ac_gh_login_hint() {
    cat <<'EOF'
GitHub HTTPS setup for AntCrate:

  1. Install gh CLI:        https://cli.github.com/
  2. Authenticate (HTTPS):  gh auth login -h github.com -p https
                            (choose: Login with a web browser)
  3. Verify:                gh auth status
  4. Then:                  antcrate --gh-init <project> [--public|--private]

Credentials are stored by gh in your system keychain. AntCrate never sees the token.
EOF
}
