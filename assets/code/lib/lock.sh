#!/usr/bin/env bash
# antcrate :: lib/lock.sh — flock-based wrapper/daemon coordination

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_LOCK:=$ANTCRATE_HOME/daemon.lock}"

# ac_with_lock <cmd...>  — run cmd while holding exclusive lock
ac_with_lock() {
    mkdir -p "$ANTCRATE_HOME"
    [[ -e "$ANTCRATE_LOCK" ]] || : > "$ANTCRATE_LOCK"
    (
        flock -x 200
        "$@"
    ) 200>"$ANTCRATE_LOCK"
}

# ac_pause_pipe — signal daemon to pause (touch a pause flag the daemon polls)
ac_pause_pipe() {
    : > "$ANTCRATE_HOME/pipe.paused"
}

# ac_resume_pipe — clear pause flag
ac_resume_pipe() {
    if declare -f _ac_unlink_internal >/dev/null 2>&1; then
        _ac_unlink_internal "$ANTCRATE_HOME/pipe.paused"
    else
        rm -f "$ANTCRATE_HOME/pipe.paused"
    fi
}

# ac_pipe_paused — exit 0 if paused, 1 otherwise
ac_pipe_paused() {
    [[ -f "$ANTCRATE_HOME/pipe.paused" ]]
}
