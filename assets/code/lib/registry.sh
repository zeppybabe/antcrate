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
