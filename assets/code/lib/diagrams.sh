#!/usr/bin/env bash
# shellcheck disable=SC2016  # Mermaid/PlantUML/D2 strings are not shell expansions
# antcrate :: lib/diagrams.sh — diagram emission + optional rendering
#
# Per assets/docs/DIAGRAM_AUTOMATION_GUIDE.md: text is the source of truth.
# We emit `.mmd` / `.puml` / `.d2` files that live next to the code and render
# inline on GitHub (Mermaid). SVG rendering is optional — if `mmdc`/`plantuml`/
# `d2` are absent, we skip with a one-line note instead of failing.
#
# Sourced by wrapper. Depends on registry.sh, address.sh, log.sh.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_DIAGRAMS_DIR:=docs/diagrams}"      # relative to project root

# ---------- scaffolding ----------

# ac_diagrams_scaffold <project_path> <project_name>
# Creates docs/diagrams/architecture.mmd if absent. Idempotent.
ac_diagrams_scaffold() {
    local proj_path="$1" name="$2"
    local dir="$proj_path/$ANTCRATE_DIAGRAMS_DIR"
    mkdir -p "$dir"
    local f="$dir/architecture.mmd"
    if [[ ! -f "$f" ]]; then
        cat > "$f" <<MERMAID
%% $name — architecture sketch (regenerate with: antcrate --tree-diagram $name)
%% Edit this file as the project grows; it renders inline on GitHub.
graph TD
    user[User] --> entry[$name entrypoint]
    entry --> core[Core logic]
    core --> data[(State / data)]
MERMAID
        ac_info "diagrams: scaffolded $f"
    fi
}

# ---------- registry-as-graph ----------

# ac_diagrams_registry_to_mermaid — emits a Mermaid graph of the registry.
# Each project is a node; parent is shown as label; linked_nodes drawn as
# bidirectional edges. Archived projects render dimmed.
ac_diagrams_registry_to_mermaid() {
    ac_registry_init
    printf '%%%% AntCrate registry — generated %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'graph LR\n'
    # nodes
    jq -r '
        .projects | to_entries[]
        | "  \(.key)[\"" + .key + "\\n(" + (.value.parent // "?") + ")\"]"
    ' "$ANTCRATE_REGISTRY"
    # archived class
    printf '  classDef archived fill:#eee,stroke:#999,color:#999\n'
    jq -r '
        .projects | to_entries[]
        | select(.value.parent == "_archived")
        | "  class \(.key) archived"
    ' "$ANTCRATE_REGISTRY"
    # link edges (one-way each direction; dedup by sorting names)
    jq -r '
        [ .projects | to_entries[]
          | .key as $a
          | (.value.linked_nodes // [])[]
          | [$a, .] | sort | join(",") ] | unique[]
        | split(",") | "  " + .[0] + " <--> " + .[1]
    ' "$ANTCRATE_REGISTRY" 2>/dev/null
}

# ac_diagrams_registry_emit [out_path] — write the registry diagram to disk
ac_diagrams_registry_emit() {
    local out="${1:-$ANTCRATE_HOME/registry.mmd}"
    mkdir -p "$(dirname "$out")"
    ac_diagrams_registry_to_mermaid > "$out"
    ac_info "diagrams: registry → $out"
    printf '%s\n' "$out"
}

# ---------- project tree as graph ----------

# ac_diagrams_tree_to_mermaid <project> — Mermaid graph of the project tree
# using the address scheme. Node ids are the addresses; labels are the
# basenames; static files get a different shape.
ac_diagrams_tree_to_mermaid() {
    local project="$1"
    local root; root=$(ac_registry_get "$project" path)
    [[ -d "$root" ]] || { ac_error "tree-diagram: missing path: $root"; return 1; }
    printf '%%%% %s tree — generated %s\n' "$project" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'graph TD\n'
    printf '  root(["%s"])\n' "$project"
    local addr rel base parent_addr label shape
    while IFS=$'\t' read -r addr rel; do
        base=$(basename "$rel")
        if [[ -d "$root/$rel" ]]; then
            shape='[/'"$base"'/]'    # parallelogram = directory
        elif [[ "$(ac_devops_classify "$base" 2>/dev/null)" == "static" ]]; then
            shape='[('"$base"')]'    # stadium = static
        else
            shape='["'"$base"'"]'    # box = dynamic
        fi
        printf '  %s%s\n' "$addr" "$shape"
        # parent: strip the last segment of the address
        parent_addr=$(_ac_diagrams_parent_addr "$addr")
        if [[ -z "$parent_addr" ]]; then
            label="root"
        else
            label="$parent_addr"
        fi
        printf '  %s --> %s\n' "$label" "$addr"
    done < <(ac_addr_render_tree "$root")
}

# Strip the trailing segment from an address (e.g., 4d2 -> 4d, 4d -> 4, 4 -> "")
_ac_diagrams_parent_addr() {
    local addr="$1" out="" i=0 ch buf="" cur_kind=""
    # walk left-to-right collecting consecutive same-kind chars; emit all but
    # the final group
    local chars=()
    while (( i < ${#addr} )); do
        ch="${addr:i:1}"
        case "$ch" in
            [0-9]) chars+=("d:$ch") ;;
            [a-z]) chars+=("a:$ch") ;;
        esac
        i=$((i + 1))
    done
    # group consecutive same-kind
    local groups=() c kind val
    for c in "${chars[@]}"; do
        kind="${c%%:*}"; val="${c#*:}"
        if [[ "$kind" == "$cur_kind" ]]; then
            buf+="$val"
        else
            [[ -n "$buf" ]] && groups+=("$buf")
            buf="$val"; cur_kind="$kind"
        fi
    done
    [[ -n "$buf" ]] && groups+=("$buf")
    # rejoin all but last
    if (( ${#groups[@]} <= 1 )); then
        printf ''
        return 0
    fi
    local last_idx=$((${#groups[@]} - 1))
    for (( i=0; i<last_idx; i++ )); do out+="${groups[i]}"; done
    printf '%s' "$out"
}

# ac_diagrams_tree_emit <project> [out_path]
ac_diagrams_tree_emit() {
    local project="$1" out="${2:-}"
    [[ -z "$out" ]] && {
        local root; root=$(ac_registry_get "$project" path)
        out="$root/$ANTCRATE_DIAGRAMS_DIR/tree.mmd"
    }
    mkdir -p "$(dirname "$out")"
    ac_diagrams_tree_to_mermaid "$project" > "$out" || return 1
    ac_info "diagrams: tree($project) → $out"
    printf '%s\n' "$out"
}

# ---------- path → project resolver ----------
#
# ac_diagrams_resolve_project_for_path <abs_path>
# Echoes the project name whose registered `path` is the longest prefix of
# <abs_path>. Returns 1 (and emits nothing) if no project matches.
#
# Used by the daemon's live-tree auto-regen path: an inotify event fires on
# some directory under the watched root; we need to map that directory back to
# whichever registered project (possibly nested) it belongs to. Longest-prefix
# match handles sub-branches correctly — a file under
# ~/projects/parent/child/x.sh resolves to `child`, not `parent`.
ac_diagrams_resolve_project_for_path() {
    local target="${1:-}"
    [[ -z "$target" ]] && return 1
    target="${target%/}"
    local best_name="" best_path="" name path
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        path=$(ac_registry_get "$name" path 2>/dev/null || true)
        [[ -z "$path" ]] && continue
        path="${path%/}"
        if [[ "$target" == "$path" || "$target" == "$path"/* ]]; then
            if (( ${#path} > ${#best_path} )); then
                best_path="$path"
                best_name="$name"
            fi
        fi
    done < <(ac_registry_list 2>/dev/null)
    if [[ -n "$best_name" ]]; then
        printf '%s\n' "$best_name"
        return 0
    fi
    return 1
}

# ---------- auto-regeneration ----------
#
# Called by mutating wrapper actions so a human/AI never has to remember to
# refresh diagrams. Always silent (no stdout), failures are swallowed: a
# diagram refresh must never block the action that triggered it.
#
# Opt out for scripted pipelines: export ANTCRATE_AUTO_DIAGRAMS=0
#
# Always regenerates the registry-level diagram (cheap, single jq pass).
# If <project> is given AND it's still registered AND its path still exists,
# also regenerates the project's tree diagram at <path>/docs/diagrams/tree.mmd.
ac_diagrams_auto_regen() {
    [[ "${ANTCRATE_AUTO_DIAGRAMS:-1}" == "1" ]] || return 0
    local project="${1:-}"

    # registry-level — always
    {
        local out="$ANTCRATE_HOME/registry.mmd"
        mkdir -p "$(dirname "$out")" 2>/dev/null || true
        ac_diagrams_registry_to_mermaid > "$out" 2>/dev/null
    } >/dev/null 2>&1 || true

    # project-level — only if project still resolvable on disk
    if [[ -n "$project" ]] && ac_registry_has "$project" 2>/dev/null; then
        local proj_path
        proj_path=$(ac_registry_get "$project" path 2>/dev/null || true)
        if [[ -n "$proj_path" && -d "$proj_path" ]]; then
            local tree_out="$proj_path/$ANTCRATE_DIAGRAMS_DIR/tree.mmd"
            mkdir -p "$(dirname "$tree_out")" 2>/dev/null || true
            ac_diagrams_tree_to_mermaid "$project" > "$tree_out" 2>/dev/null || true
        fi
    fi
    return 0
}

# ---------- bulk render ----------

# ac_diagrams_render <project>
# Walks $project/docs/diagrams/, renders each .mmd/.puml/.d2 to .svg if the
# right tool is available. Logs (info) about each file. Missing tools yield
# a single one-line warn per ext, not a failure.
ac_diagrams_render() {
    local project="$1"
    local root; root=$(ac_registry_get "$project" path)
    local dir="$root/$ANTCRATE_DIAGRAMS_DIR"
    [[ -d "$dir" ]] || { ac_warn "diagrams: no $dir directory"; return 0; }

    local have_mmdc=0 have_puml=0 have_d2=0
    command -v mmdc >/dev/null 2>&1 && have_mmdc=1
    command -v plantuml >/dev/null 2>&1 && have_puml=1
    command -v d2 >/dev/null 2>&1 && have_d2=1

    local f rendered=0 skipped=0
    while IFS= read -r -d '' f; do
        case "$f" in
            *.mmd)
                if (( have_mmdc )); then
                    mmdc -i "$f" -o "${f%.mmd}.svg" >/dev/null 2>&1 \
                        && ac_info "diagrams: rendered $f → ${f%.mmd}.svg" \
                        && rendered=$((rendered + 1))
                else
                    skipped=$((skipped + 1))
                fi ;;
            *.puml)
                if (( have_puml )); then
                    plantuml -tsvg "$f" >/dev/null 2>&1 \
                        && ac_info "diagrams: rendered $f → ${f%.puml}.svg" \
                        && rendered=$((rendered + 1))
                else
                    skipped=$((skipped + 1))
                fi ;;
            *.d2)
                if (( have_d2 )); then
                    d2 "$f" "${f%.d2}.svg" >/dev/null 2>&1 \
                        && ac_info "diagrams: rendered $f → ${f%.d2}.svg" \
                        && rendered=$((rendered + 1))
                else
                    skipped=$((skipped + 1))
                fi ;;
        esac
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.mmd' -o -name '*.puml' -o -name '*.d2' \) -print0)

    (( have_mmdc )) || ac_warn "diagrams: 'mmdc' not on PATH (npm install -g @mermaid-js/mermaid-cli to render .mmd)"
    (( have_puml )) || ac_warn "diagrams: 'plantuml' not on PATH (apt install plantuml to render .puml)"
    (( have_d2 ))   || ac_warn "diagrams: 'd2' not on PATH (curl -fsSL https://d2lang.com/install.sh | sh -s -- to render .d2)"
    ac_info "diagrams: rendered=$rendered skipped=$skipped (sources are still text-of-truth and render inline on GitHub)"
}
