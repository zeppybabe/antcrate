#!/usr/bin/env bash
# antcrate :: lib/subbranch.sh — atomic sub-branch (project nesting) sequence
#
# Protocol (from blueprint §6):
#   1. Pause the Pipe
#   2. Update Filesystem (mkdir parent, mv child)
#   3. Update Registry (path + parent)
#   4. Update Relational Links (.env.[project].secret symlinks)
#   5. Resume the Pipe

: "${ANTCRATE_ROOT:=$HOME/projects}"

# ac_subbranch_expand <new_parent> <child_project>
# Moves <child_project> under <new_parent>, creating <new_parent> if needed.
ac_subbranch_expand() {
    local new_parent="$1" child="$2"

    if ! ac_registry_has "$child"; then
        ac_error "subbranch: unknown project '$child'"
        return 1
    fi

    local old_path; old_path=$(ac_registry_get "$child" path)
    if [[ -z "$old_path" || ! -d "$old_path" ]]; then
        ac_error "subbranch: project path missing on disk: '$old_path'"
        return 1
    fi

    local parent_path="$ANTCRATE_ROOT/$new_parent"
    local new_path="$parent_path/$child"

    # safety: both old and new must be under allowed zones
    ac_safety_guard "subbranch source" "$old_path" || return 1
    ac_safety_guard "subbranch target" "$new_path" || return 1

    # mandatory backup-before-move (subbranch IS a destructive op on the source path)
    ac_safety_guard_destructive "$child" "subbranch mv" "$old_path" || return 1

    ac_info "subbranch: pause pipe (backup at $AC_LAST_BACKUP_PATH)"
    ac_pause_pipe
    # ensure pause is honored even on error
    trap 'ac_resume_pipe; trap - RETURN' RETURN

    ac_with_lock bash -c '
        set -e
        mkdir -p "'"$parent_path"'"
        if [[ -e "'"$new_path"'" ]]; then
            echo "subbranch: target exists: '"$new_path"'" >&2
            exit 1
        fi
        mv "'"$old_path"'" "'"$new_path"'"
    ' || { ac_error "subbranch: filesystem move failed"; return 1; }

    ac_info "subbranch: update registry path/parent"
    ac_registry_set_path "$child" "$new_path"
    ac_registry_set_parent "$child" "$new_parent"

    ac_info "subbranch: rewriting relational links"
    ac_subbranch_fix_links "$child" "$old_path" "$new_path"

    ac_info "subbranch: resume pipe"
    ac_resume_pipe
    trap - RETURN
    return 0
}

# ac_subbranch_fix_links <project> <old_path> <new_path>
ac_subbranch_fix_links() {
    local project="$1" old_path="$2" new_path="$3"
    : "$project"   # param kept for call-site symmetry; not consumed yet

    # find any symlinks across registered projects that point inside old_path
    local p target newtgt
    while IFS= read -r p; do
        local pdir; pdir=$(ac_registry_get "$p" path)
        [[ -d "$pdir" ]] || continue
        # iterate symlinks
        while IFS= read -r -d '' link; do
            target=$(readlink "$link")
            case "$target" in
                "$old_path"|"$old_path"/*)
                    newtgt="${target/#$old_path/$new_path}"
                    ln -sfn "$newtgt" "$link"
                    ac_info "relink $link → $newtgt"
                    ;;
            esac
        done < <(find "$pdir" -maxdepth 4 -type l -print0 2>/dev/null)
    done < <(ac_registry_list)
}
