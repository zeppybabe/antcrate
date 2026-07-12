#!/usr/bin/env bash
# antcrate :: lib/targets/git_mirror.sh — private dev/ companion mirror target.
# Scope: dev. Pushes a project's git-ignored dev/ tree as REAL git history to a
# private companion repo <owner>/<project>-dev (created on first push). dev/
# becomes a nested git repo — the parent ignores dev/ wholly, so the two
# histories never interfere. The companion is ALWAYS private: it carries
# exactly the content the publication boundary keeps out of the public repo.
#
# ANTCRATE_MIRROR_PREFIX (default https://github.com/<mirror_owner>/): when it
# is a local directory path, "create the repo" means `git init --bare` and no
# gh or network is involved — which is also how the bats suite drives this
# target. mirror_owner comes from config (rule-#13 human-only); default is the
# gh-authenticated login.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_CONFIG:=$ANTCRATE_HOME/config}"

_ac_mirror_owner() {
    local o=""
    if [[ -f "$ANTCRATE_CONFIG" ]]; then
        o=$(grep -E '^mirror_owner=' "$ANTCRATE_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi
    [[ -z "$o" ]] && o=$(gh api user --jq .login 2>/dev/null) || true
    printf '%s\n' "$o"
}

_ac_mirror_prefix() {
    if [[ -n "${ANTCRATE_MIRROR_PREFIX:-}" ]]; then
        printf '%s\n' "$ANTCRATE_MIRROR_PREFIX"
    else
        printf 'https://github.com/%s/\n' "$(_ac_mirror_owner)"
    fi
}

# <project> -> remote url of the companion repo
_ac_mirror_url() { printf '%s%s-dev.git\n' "$(_ac_mirror_prefix)" "$1"; }

# 0 when the prefix is a local directory (file mode — tests, air-gapped hubs)
_ac_mirror_local() { [[ "$(_ac_mirror_prefix)" != http* ]]; }

target_git_mirror_scopes() { printf 'dev\n'; }

target_git_mirror_available() {
    _ac_mirror_local && return 0
    command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1
}

# ensure <owner>/<project>-dev exists; PRIVATE always on the gh path
_ac_mirror_ensure_repo() {
    local project="$1" url
    url=$(_ac_mirror_url "$project")
    if _ac_mirror_local; then
        [[ -d "$url" ]] || git init --bare -q "$url"
        return 0
    fi
    local owner
    owner=$(_ac_mirror_owner)
    if [[ -z "$owner" ]]; then
        ac_error "git-mirror: no owner — set mirror_owner in config or gh auth login"
        return 1
    fi
    gh repo view "$owner/$project-dev" >/dev/null 2>&1 && return 0
    if ! gh repo create "$owner/$project-dev" --private >/dev/null; then
        ac_error "git-mirror: could not create private repo $owner/$project-dev"
        return 1
    fi
}

# push <project> <dev-path> -> echoes the pushed head sha
target_git_mirror_push() {
    local project="$1" dev="$2" url
    if [[ ! -d "$dev" ]]; then
        ac_error "git-mirror: no dev dir: $dev"
        return 1
    fi
    _ac_mirror_ensure_repo "$project" || return 1
    url=$(_ac_mirror_url "$project")
    [[ -d "$dev/.git" ]] || git -C "$dev" init -q
    git -C "$dev" add -A
    # commit only when the tree changed (or there is no history yet);
    # an unchanged dev/ re-pushes the existing head — clean no-op
    if ! git -C "$dev" diff --cached --quiet 2>/dev/null \
       || ! git -C "$dev" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        git -C "$dev" commit -qm "antcrate dev mirror $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
    fi
    if ! git -C "$dev" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        ac_error "git-mirror: nothing to mirror in $dev"
        return 1
    fi
    if ! git -C "$dev" push -q "$url" HEAD:master; then
        ac_error "git-mirror: push to $url failed"
        return 1
    fi
    git -C "$dev" rev-parse HEAD
}

# list <project> -> remote master head sha
target_git_mirror_list() {
    git ls-remote "$(_ac_mirror_url "$1")" refs/heads/master 2>/dev/null | awk '{print $1}'
}

# pull <project> <id> <dest> -> clone companion under <dest>/<project>-dev
target_git_mirror_pull() {
    local project="$1" id="${2:-}" dest="$3"
    mkdir -p "$dest"
    git clone -q "$(_ac_mirror_url "$project")" "$dest/$project-dev" || return 1
    [[ -n "$id" ]] && { git -C "$dest/$project-dev" checkout -q "$id" || return 1; }
    return 0
}

# verify <project> [<id>] -> remote head reachable (and equals <id> when given)
target_git_mirror_verify() {
    local project="$1" id="${2:-}" head
    head=$(target_git_mirror_list "$project")
    [[ -n "$head" ]] || return 1
    [[ -z "$id" || "$head" == "$id" ]]
}
