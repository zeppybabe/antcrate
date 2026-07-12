#!/usr/bin/env bash
# antcrate :: lib/watch_window.sh — detached terminal window for --watch
#
# Spawns one terminal window per project running `antcrate watch <project>`.
# Dedup: if the PID file at $ANTCRATE_HOME/watch/<project>.pid exists and the
# process is alive, a second invocation exits 0 without spawning. Stale PID
# files (process dead) are silently removed and a fresh window is spawned.
#
# Terminal backends: alacritty (Linux default; works on macOS if installed)
# and terminal (macOS Terminal.app via osascript, darwin default).
# kitty / wezterm / foot TODO.
#
# PID semantics per backend: alacritty tracks the terminal window PID;
# terminal (Terminal.app) tracks the inner `antcrate watch` process, because
# osascript cannot return the window's unix PID — dedup/alive behave the same.
#
# Public API (callable from the wrapper):
#   ac_watch_window_pid_path <project>   — print pid-file path
#   ac_watch_window_alive <project>      — exit 0 if window alive; 1 if dead
#   ac_watch_window <project> [--terminal NAME]
#                                        — spawn-or-warn; exit 0, 1, or 2
#
# Internal: spawn logic inside ac_watch_window; not split further because
# the PID-write and setsid are one atomic block.

# compat.sh self-source: AC_OS used below; guard makes re-sourcing free.
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

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
    [[ "${AC_OS:-linux}" == darwin ]] && terminal="terminal"
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
            if ! command -v alacritty >/dev/null 2>&1; then
                ac_error "watch-window: alacritty not found on PATH"
                return 1
            fi
            # setsid fully detaches from the controlling tty on Linux; macOS
            # has no setsid(1) — background + disown detaches well enough there.
            local -a detach=()
            if command -v setsid >/dev/null 2>&1; then
                detach=(setsid)
            elif [[ "${AC_OS:-linux}" != darwin ]]; then
                ac_error "setsid not found; install util-linux (or use --terminal terminal on macOS)"
                return 1
            fi
            "${detach[@]}" alacritty \
                --class "ac-watch-$project" \
                --title "antcrate watch: $project" \
                -e "$bin" watch "$project" \
                </dev/null >/dev/null 2>&1 &
            local pid=$!
            disown "$pid" 2>/dev/null || true
            printf '%s\n' "$pid" > "$pid_file"
            printf 'watching %s in alacritty window (pid %s)\n' "$project" "$pid"
            ;;
        terminal)
            if ! command -v osascript >/dev/null 2>&1; then
                ac_error "watch-window: osascript not found (terminal backend is macOS-only)"
                return 1
            fi
            # Launcher records the inner watch PID (see PID semantics above),
            # then becomes `antcrate watch`. Terminal.app runs it via do script.
            local launcher="$ANTCRATE_HOME/watch/$project.cmd"
            printf '#!/usr/bin/env bash\necho $$ > "%s"\nexec "%s" watch "%s"\n' \
                "$pid_file" "$bin" "$project" > "$launcher"
            chmod +x "$launcher"
            if ! osascript -e "tell application \"Terminal\" to do script \"exec ${launcher// /\\ }\"" >/dev/null 2>&1; then
                ac_error "watch-window: osascript failed to open Terminal.app"
                return 1
            fi
            printf 'watching %s in Terminal.app window\n' "$project"
            ;;
        *)
            ac_error "watch-window: unknown terminal: $terminal (supported: alacritty, terminal)"
            return 2
            ;;
    esac
}
