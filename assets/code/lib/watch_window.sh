#!/usr/bin/env bash
# antcrate :: lib/watch_window.sh — detached terminal window for --watch
#
# Spawns one Alacritty window per project running `antcrate watch <project>`.
# PID file at $ANTCRATE_HOME/watch/<project>.pid tracks the terminal PID (the
# user-meaningful entity), not the inner antcrate process. Dedup: if the PID
# file exists and the process is alive, a second invocation exits 0 without
# spawning. Stale PID files (process dead) are silently removed and a fresh
# window is spawned.
#
# Terminal backends: alacritty only. kitty / wezterm / foot TODO.
#
# Public API (callable from the wrapper):
#   ac_watch_window_pid_path <project>   — print pid-file path
#   ac_watch_window_alive <project>      — exit 0 if window alive; 1 if dead
#   ac_watch_window <project> [--terminal NAME]
#                                        — spawn-or-warn; exit 0, 1, or 2
#
# Internal: spawn logic inside ac_watch_window; not split further because
# the PID-write and setsid are one atomic block.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"

ac_watch_window_pid_path() {
    local project="$1"
    printf '%s/watch/%s.pid\n' "$ANTCRATE_HOME" "$project"
}

ac_watch_window_alive() {
    local project="$1"
    local pid_file; pid_file=$(ac_watch_window_pid_path "$project")
    [[ -f "$pid_file" ]] || return 1
    local pid; pid=$(< "$pid_file")
    [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$pid_file"; return 1; }
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    else
        rm -f "$pid_file"
        return 1
    fi
}

ac_watch_window() {
    local project="$1"; shift
    local terminal="alacritty"
    while (( $# > 0 )); do
        case "$1" in
            --terminal) terminal="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if ! ac_registry_has "$project"; then
        ac_error "watch-window: unknown project '$project'"
        return 1
    fi

    if ac_watch_window_alive "$project"; then
        local pid_file; pid_file=$(ac_watch_window_pid_path "$project")
        local pid; pid=$(< "$pid_file")
        printf 'already watching %s (pid %s)\n' "$project" "$pid"
        return 0
    fi

    local pid_file; pid_file=$(ac_watch_window_pid_path "$project")
    mkdir -p "$ANTCRATE_HOME/watch"

    local bin
    bin="$(command -v antcrate 2>/dev/null)" || bin="${ANTCRATE_SELFSRC:-}/bin/antcrate"
    if [[ ! -x "$bin" ]]; then
        ac_error "watch-window: cannot resolve antcrate binary (not on PATH, ANTCRATE_SELFSRC empty or invalid)"
        return 1
    fi

    case "$terminal" in
        alacritty)
            if ! command -v setsid >/dev/null 2>&1; then
                ac_error "setsid not found; --watch-window is Linux-only currently."
                return 1
            fi
            if ! command -v alacritty >/dev/null 2>&1; then
                ac_error "watch-window: alacritty not found on PATH"
                return 1
            fi
            setsid alacritty \
                --class "ac-watch-$project" \
                --title "antcrate watch: $project" \
                -e "$bin" watch "$project" \
                </dev/null >/dev/null 2>&1 &
            local pid=$!
            disown "$pid" 2>/dev/null || true
            printf '%s\n' "$pid" > "$pid_file"
            printf 'watching %s in alacritty window (pid %s)\n' "$project" "$pid"
            ;;
        *)
            ac_error "watch-window: unknown terminal: $terminal (supported: alacritty)"
            return 2
            ;;
    esac
}
