#!/usr/bin/env bash
# antcrate :: lib/hygiene.sh — registry hygiene (ghosts + deregister)
#
# Ghosts: registry entries whose on-disk path no longer exists.
# --ghosts    lists all ghosts (read-only)
# --deregister removes a ghost entry (capture-first safety invariant)
#
# Sourced by wrapper. No side effects on source.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_REGISTRY:=$ANTCRATE_HOME/registry.json}"

ac_hygiene_ghosts() {
    # List every registry entry whose path no longer exists
    # Output: one line per ghost: name<TAB>path
    # If zero ghosts, print friendly message.
    # Exit: 0 always

    local ghosts=()

    while IFS= read -r name; do
        local path; path=$(ac_registry_get "$name" path)
        if [[ -n "$path" && ! -e "$path" ]]; then
            ghosts+=("$name	$path")
        fi
    done < <(ac_registry_list)

    if (( ${#ghosts[@]} == 0 )); then
        printf 'no ghost entries (registry clean)\n'
        return 0
    fi

    printf 'Ghost entries (path no longer exists):\n'
    printf '%s\n' "${ghosts[@]}"
    return 0
}

ac_hygiene_deregister() {
    # Drops a stale registry entry whose files are already gone.
    # CAPTURE-FIRST safety: saves entry + registry + manifest to a dedicated dir.
    # REFUSES if path still exists (prevents deregister from becoming a backdoor
    # around --archive/--remove safety guards).
    #
    # Exit codes:
    #   0  - success (ghost entry removed, capture created)
    #   1  - path still exists (refuse to deregister; point user to --archive)
    #   2  - unknown project or missing arg

    local project="${1:-}"

    if [[ -z "$project" ]]; then
        ac_error "deregister: missing <project>"
        return 2
    fi

    if ! ac_registry_has "$project"; then
        ac_error "deregister: unknown project '$project'"
        return 2
    fi

    local path; path=$(ac_registry_get "$project" path)

    if [[ -e "$path" ]]; then
        ac_error "deregister: path still exists: $path"
        ac_error "Use --archive instead of deregister for a project with files on disk."
        return 1
    fi

    local cap_ts; cap_ts=$(date -u +%Y%m%dT%H%M%SZ)
    local cap_dir="$ANTCRATE_HOME/deregistered/$project/$cap_ts"
    mkdir -p "$cap_dir"

    jq --arg n "$project" '.projects[$n]' "$ANTCRATE_REGISTRY" > "$cap_dir/entry.json"

    cp "$ANTCRATE_REGISTRY" "$cap_dir/registry.json"

    jq --arg ts "$cap_ts" \
       --arg proj "$project" \
       --arg pth "$path" \
       '{ts: $ts, project: $proj, path: $pth, reason: "ghost deregister",
         linked_nodes: (.linked_nodes // [])}' \
       "$cap_dir/entry.json" > "$cap_dir/manifest.json"

    ac_registry_delete "$project"

    ac_info "deregister: dropped '$project' (was: $path)"
    printf 'Deregistered: %s\nPath was: %s\nCapture dir: %s\n' "$project" "$path" "$cap_dir"

    return 0
}
