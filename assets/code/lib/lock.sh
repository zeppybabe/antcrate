#!/usr/bin/env bash
# antcrate :: lib/lock.sh — wrapper/daemon coordination lock
#
# flock(1) (util-linux) is the fast path everywhere it exists — all Linux,
# macOS with `brew install flock`. Where it doesn't (stock macOS), a mkdir
# spinlock provides the same contract: exclusive, blocking-until-acquired,
# released on command exit (even a failing one), stealable when the holder
# pid is dead (crash recovery, same idiom as the daemon.pid check).

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_LOCK:=$ANTCRATE_HOME/daemon.lock}"

# ac_with_lock <cmd...>  — run cmd while holding exclusive lock
ac_with_lock() {
    mkdir -p "$ANTCRATE_HOME"
    if command -v flock >/dev/null 2>&1; then
        [[ -e "$ANTCRATE_LOCK" ]] || : > "$ANTCRATE_LOCK"
        (
            flock -x 200
            "$@"
        ) 200>"$ANTCRATE_LOCK"
    else
        _ac_with_lock_mkdir "$@"
    fi
}

# Internal: mkdir-spinlock fallback for ac_with_lock. Do not call directly —
# callers must go through ac_with_lock so the flock fast path is preferred.
# Reason: two processes mixing flock and mkdir locking would not exclude
# each other.
_ac_with_lock_mkdir() {
    local lockdir="$ANTCRATE_LOCK.d" holder rc=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        holder=$(cat "$lockdir/pid" 2>/dev/null || true)
        if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$lockdir"       # holder died without cleanup — steal
            continue
        fi
        sleep 0.05
    done
    echo $$ > "$lockdir/pid"
    "$@" || rc=$?
    rm -rf "$lockdir"
    return "$rc"
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
