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
#   ac_watch_smoke <project> [kind] [relpath] [--ttl-ms N] [--depth N] [--no-color]
#   ac_watch_render_once <project> [--no-color] [--depth N]
#   ac_watch_loop [<project>] [--follow] [--interval-ms N] [--no-color] [--depth N]
#   ac_watch_hot_project
#
# Internal (do not call from outside this file):
#   ac_watch_severity_for, ac_watch_color_for,
#   ac_watch_build_overlay, ac_watch_fold_overlay, ac_watch_walk_tree,
#   ac_watch_latest_event, ac_watch_term_rows, ac_watch_clamp_frame
# Reason: severity / color / fold helpers depend on a stable input shape
# from ac_watch_build_overlay; calling them out of order would render a
# partial or inconsistent overlay. Recursion (ac_watch_walk_tree) holds
# an associative array via nameref and must be invoked via render_once.
# ac_watch_latest_event reads the same active-event stream that the
# overlay does, so it is consistent with what the tree colors show.

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

# ac_watch_latest_event <project>
# Outputs "<ts_ms>\t<kind>\t<path>" for the most-recent active event, or
# nothing if there are no active events. Tie-break: lexicographic path
# (deterministic, doesn't matter much in practice since ts_ms is ms-resolved).
# Used to paint the anchor header above the tree so the eye lands on the
# hot path even when the rest of the tree is scrolling.
ac_watch_latest_event() {
    local project="$1"
    local active; active=$(ac_events_active "$project")
    [[ -z "$active" ]] && return 0
    jq -r 'select(.kind != null and .path != null and .path != "__root__")
           | [.ts_ms, .kind, .path] | @tsv' <<< "$active" \
        | sort -k1,1nr -k3,3 \
        | head -n 1
}

# ac_watch_walk_tree <root> <rel_prefix> <line_prefix> <depth_remaining> <use_color> <overlay_assoc_name> [latest_path]
# Recursive tree walker. The overlay is passed by name (associative array
# in the caller's scope) so we don't reparse for every entry. latest_path
# (optional, project-relative) marks one entry with a "   ●" suffix so the
# eye can find the most-recently-active node even in a large tree.
ac_watch_walk_tree() {
    local root="$1" rel_prefix="$2" line_prefix="$3" depth="$4" use_color="$5" overlay_name="$6" latest_path="${7:-}"
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
        local marker=""
        [[ -n "$latest_path" && "$rel" == "$latest_path" ]] && marker="   ●"
        # printf wants escapes interpreted via %b
        printf '%s%s' "$line_prefix" "$connector"
        printf '%b%s%b%s\n' "$color" "$label" "$reset" "$marker"
        if [[ -d "$root/$e" ]] && (( depth > 1 )); then
            ac_watch_walk_tree "$root/$e" "$rel" "$child_pfx" $((depth - 1)) "$use_color" "$overlay_name" "$latest_path"
        fi
    done
}

# ac_watch_smoke <project> [kind] [relpath] [--ttl-ms N] [--depth N] [--no-color]
# Convenience: emit one event then call ac_watch_render_once in one shot.
# Defaults: kind=modify, relpath=".", ttl=60000ms.
# Hard-coded --label smoke so downstream filters identify smoke events.
# Exit: 0 success; 1 unknown project; 2 invalid kind / bad ttl (from ac_events_emit).
ac_watch_smoke() {
    local project="$1"; shift
    local kind="modify" relpath="." ttl="60000"
    local render_args=()
    if [[ $# -gt 0 && "${1:0:2}" != "--" ]]; then kind="$1"; shift; fi
    if [[ $# -gt 0 && "${1:0:2}" != "--" ]]; then relpath="$1"; shift; fi
    while (( $# > 0 )); do
        case "$1" in
            --ttl-ms)   ttl="$2"; shift 2 ;;
            --depth)    render_args+=(--depth "$2"); shift 2 ;;
            --no-color) render_args+=(--no-color); shift ;;
            *) shift ;;
        esac
    done
    ac_registry_has "$project" || { ac_error "watch-smoke: unknown project '$project'"; return 1; }
    ac_events_emit "$project" "$kind" "$relpath" --ttl-ms "$ttl" --label smoke || return $?
    ac_watch_render_once "$project" "${render_args[@]}"
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
    # Non-tty stdout (pipes, command substitution): FORCE_COLOR may re-enable
    # color, but an explicit --no-color is authoritative and never overridden.
    if [[ ! -t 1 ]] && (( use_color )); then
        use_color=${ANTCRATE_WATCH_FORCE_COLOR:-0}
    fi

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

    # Anchor: most-recent active event, pinned above the tree so the eye
    # lands on the hot path even when the project tree scrolls past the
    # viewport. Emitted whether or not colors are on (color-off mode is
    # for scripts/tests; the anchor is information either way).
    local latest_path="" latest_kind=""
    local latest; latest=$(ac_watch_latest_event "$project" 2>/dev/null || true)
    if [[ -n "$latest" ]]; then
        latest_kind=$(awk -F'\t' '{print $2}' <<< "$latest")
        latest_path=$(awk -F'\t' '{print $3}' <<< "$latest")
    fi
    if [[ -n "$latest_path" ]]; then
        if (( use_color )); then
            local c; c=$(ac_watch_color_for "$latest_kind")
            printf '%b\xe2\x96\xb6 %s%b   \xe2\x86\x90 latest %s\n' \
                "$c" "$latest_path" '\033[0m' "$latest_kind"
        else
            printf '\xe2\x96\xb6 %s   \xe2\x86\x90 latest %s\n' "$latest_path" "$latest_kind"
        fi
        printf '\n'
    fi

    # Header — paint if any event landed at any descendant (the most
    # common case for a "project is busy" indicator). The "__root__" key
    # holds the highest-severity kind seen anywhere in the tree.
    local hdr="$project/"
    local hdr_kind="${overlay[__root__]:-}"
    if (( use_color )) && [[ -n "$hdr_kind" ]]; then
        printf '%b%s%b\n' "$(ac_watch_color_for "$hdr_kind")" "$hdr" '\033[0m'
    else
        printf '%s\n' "$hdr"
    fi

    ac_watch_walk_tree "$root" "" "" "$depth" "$use_color" overlay "$latest_path"
}

# ac_watch_term_rows — terminal height; tput → $LINES → 24. Re-queried every
# frame so window resizes take effect on the next redraw.
ac_watch_term_rows() {
    local r
    r=$(tput lines 2>/dev/null) || r=""
    [[ "$r" =~ ^[1-9][0-9]*$ ]] || r="${LINES:-24}"
    [[ "$r" =~ ^[1-9][0-9]*$ ]] || r=24
    printf '%s\n' "$r"
}

# ac_watch_clamp_frame <max_rows> — pure stdin→stdout filter. Frames taller
# than max_rows are cut to max_rows-1 lines plus a "… (+N more …)" marker, so
# a redraw never exceeds the viewport (overflow is what made the old loop
# scroll-spam the terminal instead of repainting in place).
ac_watch_clamp_frame() {
    local max="$1"
    awk -v max="$max" '
        { buf[NR] = $0 }
        END {
            if (NR <= max) { for (i = 1; i <= NR; i++) print buf[i]; exit }
            for (i = 1; i < max; i++) print buf[i]
            printf "\xe2\x80\xa6 (+%d more lines \xe2\x80\x94 lower --depth or resize)\n", NR - (max - 1)
        }'
}

# ac_watch_hot_project — print the registered project with the newest ACTIVE
# (TTL-unexpired) event across $ANTCRATE_EVENTS_DIR; exit 1 if none. Powers
# --follow: the view tracks whatever project the agent is touching right now.
ac_watch_hot_project() {
    local now best_ts=0 best="" f proj ts
    now=$(date +%s%3N)
    for f in "$ANTCRATE_EVENTS_DIR"/*.jsonl; do
        [[ -f "$f" ]] || continue
        proj="${f##*/}"; proj="${proj%.jsonl}"
        ac_registry_has "$proj" 2>/dev/null || continue
        ts=$(tail -n "${ANTCRATE_EVENTS_TAIL:-200}" "$f" 2>/dev/null \
            | jq -s --argjson now "$now" \
                '[ .[] | select((.ts_ms + .ttl_ms) > $now) | .ts_ms ] | max // 0' \
                2>/dev/null) || ts=0
        [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
        if (( ts > best_ts )); then best_ts=$ts; best="$proj"; fi
    done
    [[ -n "$best" ]] || return 1
    printf '%s\n' "$best"
}

# ac_watch_loop [<project>] [--follow] [--interval-ms N] [--no-color] [--depth N]
# Full-screen live view. Renders into the alternate screen buffer (the user's
# scrollback is untouched and restored on exit), cursor hidden, terminal
# autowrap off (long lines truncate instead of wrapping and pushing the frame
# off-screen). Each frame is drawn with home + per-line erase + erase-below —
# no full clear, so no flicker; the frame is clamped to the terminal height,
# so no scrolling. With --follow (project optional) the view auto-switches to
# the project with the newest active event.
ac_watch_loop() {
    local project="" follow=0 interval="$ANTCRATE_WATCH_INTERVAL_MS"
    local extra=()
    while (( $# > 0 )); do
        case "$1" in
            --follow)      follow=1; shift ;;
            --interval-ms) interval="$2"; shift 2 ;;
            --depth)       extra+=(--depth "$2"); shift 2 ;;
            --no-color)    extra+=(--no-color); shift ;;
            --*)           shift ;;
            *)             project="$1"; shift ;;
        esac
    done
    if (( ! follow )) && [[ -z "$project" ]]; then
        ac_error "watch: project required (or --follow)"
        return 2
    fi
    # convert ms to seconds for sleep (bash sleep accepts decimals)
    local secs
    secs=$(awk -v ms="$interval" 'BEGIN{printf "%.3f", ms/1000}')
    # Frames are built via command substitution (not a tty), so when the real
    # stdout IS a tty, carry color through the capture. --no-color still wins
    # (render_once treats it as authoritative).
    if [[ -t 1 && -z "${ANTCRATE_WATCH_FORCE_COLOR:-}" ]]; then
        export ANTCRATE_WATCH_FORCE_COLOR=1
    fi
    # alt screen + hide cursor + autowrap off; restore on EVERY exit path
    printf '\033[?1049h\033[?25l\033[?7l'
    trap 'printf "\033[?7h\033[?25h\033[?1049l"' EXIT
    trap 'exit 0' INT TERM
    local cur="$project" rows frame hot
    while :; do
        if (( follow )); then
            if hot=$(ac_watch_hot_project 2>/dev/null) && [[ -n "$hot" ]]; then
                cur="$hot"
            fi
        fi
        rows=$(ac_watch_term_rows)
        if [[ -z "$cur" ]]; then
            frame="antcrate watch --follow: waiting for activity…"
        else
            frame=$(ac_watch_render_once "$cur" "${extra[@]}" 2>&1 \
                | ac_watch_clamp_frame $(( rows > 1 ? rows - 1 : 1 ))) || true
        fi
        # per-line erase-to-EOL kills residue from previous (longer) frames
        frame=${frame//$'\n'/$'\033[K\n'}
        printf '\033[H%s\033[K\n\033[J' "$frame"
        # shellcheck disable=SC2086  # $secs is an awk-formatted decimal with no whitespace; unquoted on purpose
        sleep $secs
    done
}
