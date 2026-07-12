#!/usr/bin/env bash
# antcrate :: lib/targets.sh — backup target registry + dispatch.
# Sourced after the individual lib/targets/<name>.sh files.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_CONFIG:=$ANTCRATE_HOME/config}"

# ac_targets_enabled -> enabled target names, one per line, priority order.
# Source: config 'backup_targets=a,b,c' (rule-#13 human-only). Default: local.
ac_targets_enabled() {
    local list=""
    # '|| true': a config with no backup_targets line makes grep exit 1, which
    # under the wrapper's `set -euo pipefail` would abort before we default.
    if [[ -f "$ANTCRATE_CONFIG" ]]; then
        list=$(grep -E '^backup_targets=' "$ANTCRATE_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi
    [[ -z "$list" ]] && list="local"
    printf '%s\n' "${list//,/$'\n'}" | sed '/^[[:space:]]*$/d'
}

# ac_target_call <name> <verb> [args...] -> invoke target_<name>_<verb>.
# Config names may carry hyphens (git-mirror); function names cannot.
ac_target_call() {
    local name="$1" verb="$2"; shift 2
    local fn="target_${name//-/_}_${verb}"
    if ! declare -F "$fn" >/dev/null 2>&1; then
        ac_error "target: unknown target/verb: ${name}/${verb}"
        return 2
    fi
    "$fn" "$@"
}
