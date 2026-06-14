#!/usr/bin/env bash
# antcrate :: lib/md_scaffold.sh — internal-md skeletons for registered projects.
#
# Drops CLAUDE.md, AGENTS.md, state.md, and ledger.md at the project root
# from templates at assets/code/templates/md/. Refresh-only by default —
# existing files are kept as-is. Pass --force to backup-then-overwrite.
#
# dev/-aware: when the project has a dev/ directory (i.e. it has adopted the
# publication boundary), the dev-internal records (state.md, state-archive.md,
# ledger.md) are written under dev/ instead of the root — so this never recreates
# a root stub of a record that legitimately lives git-ignored under dev/.
#
# Tokens substituted at write time: __NAME__, __DOMAIN__, __DATE__ (matches
# the convention in lib/scaffold.sh).
#
# Public API:
#   ac_md_scaffold <project> [--force]
#
# Internal:
#   _ac_md_templates_dir   — resolve the templates/md directory (in-tree or installed)
#
# Sourced by wrapper. Depends on registry.sh, log.sh.

# _ac_md_templates_dir
# Echo the absolute path of the md/ template directory. Tries sibling
# location first (in-tree dev), then $PREFIX/share/antcrate/templates/md
# style installed location.
_ac_md_templates_dir() {
    local lib_dir; lib_dir=$(dirname "${BASH_SOURCE[0]}")
    local d
    for d in "$lib_dir/../templates/md" "$lib_dir/../share/antcrate/templates/md"; do
        if [[ -d "$d" ]]; then
            (cd "$d" && pwd)
            return 0
        fi
    done
    return 1
}

# ac_md_scaffold <project> [--force]
ac_md_scaffold() {
    local project="" force=0
    while (( $# > 0 )); do
        case "$1" in
            --force) force=1; shift ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                else ac_error "md_scaffold: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project" ]] || { ac_error "md_scaffold: missing project name"; return 1; }
    ac_registry_has "$project" || { ac_error "md_scaffold: unknown project '$project'"; return 1; }

    local proj_path
    proj_path=$(ac_registry_get "$project" path)
    [[ -d "$proj_path" ]] || { ac_error "md_scaffold: missing path: $proj_path"; return 1; }

    local domain
    domain=$(ac_registry_get "$project" parent 2>/dev/null || true)
    [[ -z "$domain" ]] && domain="_generic"

    local today; today=$(date +%Y-%m-%d)

    local tdir
    tdir=$(_ac_md_templates_dir) || {
        ac_error "md_scaffold: templates/md directory not found"
        return 1
    }

    local f base target target_dir rendered ts
    while IFS= read -r -d '' f; do
        base=$(basename "$f")
        # dev/-aware: route the dev-internal records into dev/ when the project
        # has adopted a dev/ boundary, so md_scaffold never recreates a root stub
        # of a record that legitimately lives (git-ignored) under dev/.
        target_dir="$proj_path"
        case "$base" in
            state.md|state-archive.md|ledger.md)
                [[ -d "$proj_path/dev" ]] && target_dir="$proj_path/dev" ;;
        esac
        target="$target_dir/$base"
        rendered=$(sed \
            -e "s|__NAME__|$project|g" \
            -e "s|__DOMAIN__|$domain|g" \
            -e "s|__DATE__|$today|g" \
            "$f")

        if [[ -f "$target" ]]; then
            if (( force == 0 )); then
                ac_info "md_scaffold: $base exists — skipping (use --force to backup-then-overwrite)"
                continue
            fi
            ts=$(date -u +%Y%m%dT%H%M%SZ)
            cp -p "$target" "$target.bak.$ts"
            ac_info "md_scaffold: backed up existing $base to $base.bak.$ts"
        fi

        printf '%s' "$rendered" > "$target"
        ac_info "md_scaffold: wrote $base"
    done < <(find "$tdir" -mindepth 1 -maxdepth 1 -type f -print0)

    return 0
}
