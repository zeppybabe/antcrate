#!/usr/bin/env bash
# antcrate :: lib/git_init.sh — local git bootstrap for a registered project
#
# The local-only counterpart to lib/gh.sh's --gh-init. Initializes a git
# repository inside a registered project's working directory; idempotent if
# .git already exists. Wires core.hooksPath when the project ships a
# .githooks/ directory (common for opt-in pre-commit hooks per HOOK_PLAN).
#
# Useful when a project enters AntCrate management before it's git-tracked
# (e.g., scaffolded with --start, or registered via --register over an
# existing tree that wasn't yet a repo). Composes into --bootstrap (#80).
#
# Public API:
#   ac_git_init <project>         # idempotent: git init + optional hooksPath wire
#
# Internal: (none)
#
# Sourced by wrapper. Depends on registry.sh, log.sh.

# ac_git_init <project>
# Initialize a git repo inside the registered project's path. Idempotent —
# if .git already exists, logs the fact and returns 0 without touching the
# repo. If the project ships a .githooks/ directory, sets core.hooksPath to
# enable the opt-in hook layer per HOOK_PLAN.
ac_git_init() {
    local project="${1:-}"
    [[ -n "$project" ]] || { ac_error "git_init: missing project name"; return 1; }

    if ! ac_registry_has "$project"; then
        ac_error "git_init: unknown project '$project' (use --register or --start first)"
        return 1
    fi

    local proj_path
    proj_path=$(ac_registry_get "$project" path) || {
        ac_error "git_init: failed to resolve path for '$project'"
        return 1
    }
    [[ -d "$proj_path" ]] || { ac_error "git_init: project path missing on disk: $proj_path"; return 1; }

    if [[ -d "$proj_path/.git" ]]; then
        ac_info "git_init: already a git repo: $proj_path"
        return 0
    fi

    if ! git -C "$proj_path" init -q; then
        ac_error "git_init: 'git init' failed in $proj_path"
        return 1
    fi
    ac_info "git_init: initialized git repo at $proj_path"

    if [[ -d "$proj_path/.githooks" ]]; then
        if git -C "$proj_path" config core.hooksPath .githooks 2>/dev/null; then
            ac_info "git_init: configured core.hooksPath .githooks"
        else
            ac_warn "git_init: failed to set core.hooksPath (continuing)"
        fi
    fi

    return 0
}
