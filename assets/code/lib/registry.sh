#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filter strings: $-vars are jq, not shell
# antcrate :: lib/registry.sh — atomic jq-backed registry CRUD
#
# Registry shape:
# {
#   "projects": {
#     "<name>": {
#       "path": "...",
#       "parent": "...",
#       "linked_nodes": ["..."],
#       "git_remote": "..."
#     }
#   }
# }

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_REGISTRY:=$ANTCRATE_HOME/registry.json}"

ac_registry_init() {
    mkdir -p "$ANTCRATE_HOME"
    if [[ ! -f "$ANTCRATE_REGISTRY" ]]; then
        printf '{"projects":{}}\n' > "$ANTCRATE_REGISTRY"
    fi
}

# atomic write helper: ac_registry_apply [jq-flags...] <jq-filter>
ac_registry_apply() {
    ac_registry_init
    local tmp; tmp=$(mktemp "${ANTCRATE_REGISTRY}.XXXXXX")
    if jq "$@" "$ANTCRATE_REGISTRY" > "$tmp"; then
        mv "$tmp" "$ANTCRATE_REGISTRY"
    else
        rm -f "$tmp"
        return 1
    fi
}

ac_registry_has() {
    # ac_registry_has <name> — exit 0 if registered, 1 otherwise
    ac_registry_init
    local name="$1"
    jq -e --arg n "$name" '.projects[$n]' "$ANTCRATE_REGISTRY" >/dev/null 2>&1
}

ac_registry_get() {
    # ac_registry_get <name> <field>  (path|parent|git_remote|linked_nodes)
    ac_registry_init
    local name="$1" field="$2"
    if [[ "$field" == "linked_nodes" ]]; then
        jq -r --arg n "$name" '.projects[$n].linked_nodes // [] | .[]' "$ANTCRATE_REGISTRY"
    else
        jq -r --arg n "$name" --arg f "$field" '.projects[$n][$f] // ""' "$ANTCRATE_REGISTRY"
    fi
}

ac_registry_upsert() {
    # ac_registry_upsert <name> <path> <parent> <git_remote>
    local name="$1" path="$2" parent="$3" remote="$4"
    ac_registry_apply \
        --arg n "$name" --arg p "$path" --arg par "$parent" --arg gr "$remote" \
        '.projects[$n] = (.projects[$n] // {linked_nodes:[]})
         | .projects[$n].path = $p
         | .projects[$n].parent = $par
         | .projects[$n].git_remote = $gr
         | .projects[$n].linked_nodes = (.projects[$n].linked_nodes // [])'
}

ac_registry_set_path() {
    # ac_registry_set_path <name> <new_path>
    local name="$1" path="$2"
    ac_registry_apply --arg n "$name" --arg p "$path" \
        '.projects[$n].path = $p'
}

ac_registry_set_parent() {
    local name="$1" parent="$2"
    ac_registry_apply --arg n "$name" --arg par "$parent" \
        '.projects[$n].parent = $par'
}

ac_registry_set_remote() {
    local name="$1" remote="$2"
    ac_registry_apply --arg n "$name" --arg gr "$remote" \
        '.projects[$n].git_remote = $gr'
}

ac_registry_link() {
    # ac_registry_link <a> <b>  — bidirectional linked_nodes
    local a="$1" b="$2"
    ac_registry_apply --arg a "$a" --arg b "$b" \
        '.projects[$a].linked_nodes = ((.projects[$a].linked_nodes // []) + [$b] | unique)
         | .projects[$b].linked_nodes = ((.projects[$b].linked_nodes // []) + [$a] | unique)'
}

ac_registry_unlink() {
    local a="$1" b="$2"
    ac_registry_apply --arg a "$a" --arg b "$b" \
        '.projects[$a].linked_nodes = ((.projects[$a].linked_nodes // []) - [$b])
         | .projects[$b].linked_nodes = ((.projects[$b].linked_nodes // []) - [$a])'
}

ac_registry_delete() {
    # NOTE: this only removes the registry entry, not the on-disk project.
    # Use lib/safety.sh helpers if you also need to delete files on disk.
    local name="$1"
    ac_registry_apply --arg n "$name" \
        'del(.projects[$n])
         | .projects |= with_entries(.value.linked_nodes |= ((. // []) - [$n]))'
}

ac_registry_list() {
    ac_registry_init
    jq -r '.projects | keys[]' "$ANTCRATE_REGISTRY"
}

ac_registry_dump() {
    ac_registry_init
    jq '.' "$ANTCRATE_REGISTRY"
}

# ac_registry_info <project> — formatted single-project record for human eyes.
# Replaces the `jq '.projects.<name>' ~/.antcrate/registry.json` muscle-memory
# pattern. Reads registry + project on-disk state + git status if .git present.
# Read-only; never mutates.
ac_registry_info() {
    local project="${1:-}"
    [[ -n "$project" ]] || { ac_error "info: missing project name"; return 1; }
    ac_registry_init
    if ! ac_registry_has "$project"; then
        ac_error "info: unknown project '$project'"
        return 1
    fi

    printf 'project    : %s\n' "$project"

    jq -r --arg n "$project" '
        .projects[$n] |
        "path       : " + .path,
        "domain     : " + (.parent // "(none)"),
        "git_remote : " + (if (.git_remote // "") == "" then "(none)" else .git_remote end),
        "linked     : " + ((.linked_nodes // []) | if length == 0 then "(none)" else join(", ") end),
        (if has("previous_parent") and .previous_parent != null
            then "previous_parent: " + .previous_parent
            else empty end),
        "removals   : " + (((.recent_removals // []) | length) | tostring) + " tracked"
    ' "$ANTCRATE_REGISTRY"

    local backup_dir="$ANTCRATE_HOME/backups/$project"
    local backup_count=0
    if [[ -d "$backup_dir" ]]; then
        backup_count=$(find "$backup_dir" -maxdepth 1 -name "*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf 'backups    : %d\n' "$backup_count"

    local proj_path
    proj_path=$(ac_registry_get "$project" path 2>/dev/null)
    if [[ -n "$proj_path" && -d "$proj_path/.git" ]]; then
        local last_commit
        last_commit=$(git -C "$proj_path" log -1 --pretty='%h %s' 2>/dev/null || echo '(no commits)')
        printf 'last_commit: %s\n' "$last_commit"
        local branch
        branch=$(git -C "$proj_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(detached)')
        printf 'branch     : %s\n' "$branch"
        local dirty_count
        dirty_count=$(git -C "$proj_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        if (( dirty_count > 0 )); then
            printf 'working    : dirty (%d entries)\n' "$dirty_count"
        else
            printf 'working    : clean\n'
        fi
    else
        printf 'git        : not a git repo (use --git-init or --bootstrap)\n'
    fi

    return 0
}
