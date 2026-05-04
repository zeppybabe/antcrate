#!/usr/bin/env bash
# antcrate :: lib/watch.sh — colored tree renderer over the activity stream
#
# Pure bash + ANSI. No TUI library, no curses. Renders one frame from the
# project tree, painting each path according to active events from
# lib/events.sh. Intermediate directories propagate the highest-severity
# kind found in their descendants.
#
# Color map (kind → severity, ANSI):
#   delete   sev 5   bright red + strikethrough
#   modify   sev 4   yellow
#   delegate sev 3   green
#   think    sev 2   magenta
#   read     sev 1   cyan
#
# Public API (callable from the wrapper):
#   ac_watch_render_once <project> [--no-color] [--depth N]
#   ac_watch_loop <project> [--interval-ms N] [--no-color] [--depth N]
#
# Internal (do not call from outside this file):
#   ac_watch_severity_for, ac_watch_color_for,
#   ac_watch_build_overlay, ac_watch_fold_overlay, ac_watch_walk_tree
# Reason: severity / color / fold helpers depend on a stable input shape
# from ac_watch_build_overlay; calling them out of order would render a
# partial or inconsistent overlay. Recursion (ac_watch_walk_tree) holds
# an associative array via nameref and must be invoked via render_once.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_WATCH_INTERVAL_MS:=200}"

ac_watch_severity_for() {
    case "$1" in
        delete)   echo 5 ;;
        modify)   echo 4 ;;
        delegate) echo 3 ;;
        think)    echo 2 ;;
        read)     echo 1 ;;
        *)        echo 0 ;;
    esac
}

ac_watch_color_for() {
    # ac_watch_color_for <kind>  — outputs ANSI escape (no reset)
    case "$1" in
        delete)   printf '\033[91;9m' ;;     # bright red + strikethrough
        modify)   printf '\033[33m' ;;       # yellow
        delegate) printf '\033[32m' ;;       # green
        think)    printf '\033[35m' ;;       # magenta
        read)     printf '\033[36m' ;;       # cyan
        *)        printf '' ;;
    esac
}

# ac_watch_build_overlay <project>
# Reads active events, emits "<severity>\t<kind>\t<relpath>" for each path
# AND each ancestor directory of that path, plus a __root__ row carrying
# the highest-severity kind anywhere in the tree (for the header).
# Caller folds duplicates by taking max severity.
ac_watch_build_overlay() {
    local project="$1"
    local active; active=$(ac_events_active "$project")
    [[ -z "$active" ]] && return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local p k sev
        p=$(jq -r '.path' <<< "$line")
        k=$(jq -r '.kind' <<< "$line")
        sev=$(ac_watch_severity_for "$k")
        printf '%s\t%s\t%s\n' "$sev" "$k" "$p"
        printf '%s\t%s\t%s\n' "$sev" "$k" "__root__"
        # propagate to ancestor dirs
        local cur="$p"
        while [[ "$cur" == */* ]]; do
            cur="${cur%/*}"
            [[ -z "$cur" ]] && break
            printf '%s\t%s\t%s\n' "$sev" "$k" "$cur"
        done
    done <<< "$active"
}

# ac_watch_fold_overlay  — stdin: severity-tab-kind-tab-path lines
# Outputs one line per path with the highest-severity kind (deterministic
# tie-break by lexicographic kind).
ac_watch_fold_overlay() {
    sort -k3 -k1,1nr | awk -F'\t' '
        { if ($3 != lastp) { print; lastp = $3 } }
    '
}

# ac_watch_walk_tree <root> <rel_prefix> <line_prefix> <depth_remaining> <use_color> <overlay_assoc_name>
# Recursive tree walker. The overlay is passed by name (associative array
# in the caller's scope) so we don't reparse for every entry.
ac_watch_walk_tree() {
    local root="$1" rel_prefix="$2" line_prefix="$3" depth="$4" use_color="$5" overlay_name="$6"
    (( depth <= 0 )) && return 0
    # gather entries (directories first then files, both sorted)
    local entries=()
    local e
    while IFS= read -r e; do entries+=("$e"); done < <(
        find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
    )
    local n=${#entries[@]}
    local i=0
    for e in "${entries[@]}"; do
        i=$((i+1))
        local last=0; ((i == n)) && last=1
        local connector="├── " child_pfx="${line_prefix}│   "
        if (( last )); then
            connector="└── "; child_pfx="${line_prefix}    "
        fi
        local rel
        if [[ -z "$rel_prefix" ]]; then rel="$e"; else rel="$rel_prefix/$e"; fi
        # lookup overlay for this rel path
        local kind=""
        if [[ "$use_color" == "1" ]]; then
            local -n _ov="$overlay_name"
            kind="${_ov[$rel]:-}"
        fi
        local color="" reset=""
        if [[ -n "$kind" && "$use_color" == "1" ]]; then
            color=$(ac_watch_color_for "$kind")
            reset='\033[0m'
        fi
        local label="$e"
        [[ -d "$root/$e" ]] && label="$e/"
        # printf wants escapes interpreted via %b
        printf '%s%s' "$line_prefix" "$connector"
        printf '%b%s%b\n' "$color" "$label" "$reset"
        if [[ -d "$root/$e" ]] && (( depth > 1 )); then
            ac_watch_walk_tree "$root/$e" "$rel" "$child_pfx" $((depth - 1)) "$use_color" "$overlay_name"
        fi
    done
}

# ac_watch_render_once <project> [--no-color] [--depth N]
ac_watch_render_once() {
    local project="$1"; shift
    local use_color=1 depth=8
    while (( $# > 0 )); do
        case "$1" in
            --no-color) use_color=0; shift ;;
            --depth)    depth="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ -t 1 ]] || use_color=${ANTCRATE_WATCH_FORCE_COLOR:-0}

    if ! ac_registry_has "$project"; then
        ac_error "watch: unknown project '$project'"
        return 1
    fi
    local root; root=$(ac_registry_get "$project" path)
    [[ -d "$root" ]] || { ac_error "watch: project path missing: $root"; return 1; }

    # Build the overlay map (path → kind, max-severity wins)
    declare -A overlay
    if (( use_color )); then
        local line
        while IFS=$'\t' read -r _sev kind path; do
            [[ -z "$path" ]] && continue
            overlay["$path"]="$kind"
        done < <(ac_watch_build_overlay "$project" | ac_watch_fold_overlay)
    fi

    # Header — paint if any event landed at any descendant (the most
    # common case for a "project is busy" indicator). The "" key holds
    # the highest-severity kind seen anywhere in the tree.
    local hdr="$project/"
    local hdr_kind="${overlay[__root__]:-}"
    if (( use_color )) && [[ -n "$hdr_kind" ]]; then
        printf '%b%s%b\n' "$(ac_watch_color_for "$hdr_kind")" "$hdr" '\033[0m'
    else
        printf '%s\n' "$hdr"
    fi

    ac_watch_walk_tree "$root" "" "" "$depth" "$use_color" overlay
}

# ac_watch_loop <project> [--interval-ms N] [--no-color] [--depth N]
ac_watch_loop() {
    local project="$1"; shift
    local interval="$ANTCRATE_WATCH_INTERVAL_MS"
    local extra=()
    while (( $# > 0 )); do
        case "$1" in
            --interval-ms) interval="$2"; shift 2 ;;
            *) extra+=("$1"); shift ;;
        esac
    done
    # convert ms to seconds for sleep (bash sleep accepts decimals)
    local secs
    secs=$(awk -v ms="$interval" 'BEGIN{printf "%.3f", ms/1000}')
    # clean exit on Ctrl+C
    trap 'printf "\n"; exit 0' INT TERM
    while :; do
        printf '\033[2J\033[H'   # clear + home
        ac_watch_render_once "$project" "${extra[@]}"
        # shellcheck disable=SC2086
        sleep $secs
    done
}
