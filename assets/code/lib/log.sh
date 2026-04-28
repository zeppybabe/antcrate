#!/usr/bin/env bash
# antcrate :: lib/log.sh — leveled logging
# Sourced by wrapper and daemon. No side effects on source.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_LOG_DIR:=$ANTCRATE_HOME/log}"
: "${ANTCRATE_LOG_LEVEL:=info}"  # debug | info | warn | error

ac_log() {
    # ac_log <level> <component> <message...>
    local level="$1" component="$2"; shift 2
    local msg="$*"
    local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local logfile="$ANTCRATE_LOG_DIR/${component}.log"

    # filter by configured level
    case "$ANTCRATE_LOG_LEVEL" in
        debug) ;;
        info)  [[ "$level" == "debug" ]] && return 0 ;;
        warn)  [[ "$level" == "debug" || "$level" == "info" ]] && return 0 ;;
        error) [[ "$level" != "error" ]] && return 0 ;;
    esac

    mkdir -p "$ANTCRATE_LOG_DIR"
    printf '%s [%s] %s: %s\n' "$ts" "$level" "$component" "$msg" >> "$logfile"

    # also stderr for warn/error
    if [[ "$level" == "warn" || "$level" == "error" ]]; then
        printf '%s [%s] %s\n' "$level" "$component" "$msg" >&2
    fi
}

ac_debug() { ac_log debug "${AC_COMPONENT:-antcrate}" "$@"; }
ac_info()  { ac_log info  "${AC_COMPONENT:-antcrate}" "$@"; }
ac_warn()  { ac_log warn  "${AC_COMPONENT:-antcrate}" "$@"; }
ac_error() { ac_log error "${AC_COMPONENT:-antcrate}" "$@"; }
