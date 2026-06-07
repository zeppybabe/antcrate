#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filter strings: $-vars are jq, not shell
# antcrate :: lib/relocate.sh — relocate a registered project out of the
# ~/.claude skill tree into $ANTCRATE_ROOT (~/projects), leaving a symlink at
# the old path so existing references and Claude Code skill-discovery resolve.
#
# Why: Claude Code carves ~/.claude out of background-subagent file writes, so a
# project living there cannot be edited by background agents. Relocating it under
# $ANTCRATE_ROOT removes that limitation. See
# docs/specs/2026-06-06-relocate-command-design.md.
#
# Sourced by bin/antcrate. Depends on log.sh, registry.sh, safety.sh, backup.sh.

: "${ANTCRATE_ROOT:=$HOME/projects}"
: "${ANTCRATE_HOME:=$HOME/.antcrate}"

# ac_relocate <project> [--no-watch]
ac_relocate() {
    local project="" no_watch=0 arg
    for arg in "$@"; do
        case "$arg" in
            --no-watch) no_watch=1 ;;
            --*) ac_error "relocate: unknown flag '$arg'"; return 2 ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$arg"
                else
                    ac_error "relocate: unexpected argument '$arg'"; return 2
                fi ;;
        esac
    done
    [[ -z "$project" ]] && { ac_error "relocate: requires <project>"; return 2; }

    ac_registry_has "$project" || { ac_error "relocate: unknown project '$project'"; return 1; }

    local src; src=$(ac_registry_get "$project" path)
    [[ -d "$src" ]] || { ac_error "relocate: project path missing: $src"; return 1; }

    local root_abs src_abs
    root_abs=$(realpath -m "$ANTCRATE_ROOT")
    src_abs=$(realpath -m "$src")
    case "$src_abs" in
        "$root_abs"|"$root_abs"/*)
            ac_error "relocate: '$project' is already in the projects tree ($src) — nothing to relocate"
            return 1 ;;
    esac

    local dst="$ANTCRATE_ROOT/$project"
    [[ -e "$dst" ]] && { ac_error "relocate: destination already exists: $dst"; return 1; }

    # Gateway-Law: canary gate + path-zone check + mandatory backup + approval.
    ac_safety_guard_destructive "$project" "relocate to '$dst'" "$src" || return 1

    mkdir -p "$ANTCRATE_ROOT" || { ac_error "relocate: cannot create $ANTCRATE_ROOT"; return 1; }

    # 1. move the tree (carries its own .git)
    mv -- "$src" "$dst" || { ac_error "relocate: mv failed"; return 1; }

    # 2. registry path BEFORE symlink, so symlink-failure rollback needs no rm
    if ! ac_registry_set_path "$project" "$dst"; then
        ac_error "relocate: registry path update failed — rolling back move"
        mv -- "$dst" "$src" 2>/dev/null
        return 1
    fi

    # 3. recreate the old path as a symlink -> new location
    if ! ln -s "$dst" "$src"; then
        ac_error "relocate: symlink creation failed — rolling back"
        ac_registry_set_path "$project" "$src"
        mv -- "$dst" "$src" 2>/dev/null
        return 1
    fi

    # 4. parent + optional daemon-ignore flag
    ac_registry_set_parent "$project" "projects"
    if (( no_watch == 1 )); then
        ac_registry_apply --arg n "$project" '.projects[$n].daemon_ignore = true'
    fi

    ac_info "relocate: '$project' moved to $dst (symlink at $src, backup=${AC_LAST_BACKUP_PATH:-none})"
    {
        printf '\n  relocate: NEXT STEPS\n'
        printf '  - If this project ships an antcrate wrapper, reinstall from the new path:\n'
        printf '      bash "%s/assets/code/install.sh"\n' "$dst"
        printf '  - If this project is a Claude Code skill, RESTART Claude Code, then confirm:\n'
        printf '      ls -l "%s"   (symlink -> %s) and the skill still loads.\n' "$src" "$dst"
        printf '    If it does NOT load, replace the symlink with a real dir containing a\n'
        printf '    SKILL.md shim (see docs/specs/2026-06-06-relocate-command-design.md).\n'
    } >&2
    return 0
}
