#!/usr/bin/env bash
# antcrate :: lib/migrate.sh — one-time, idempotent move of a legacy ~/.antcrate
# layout into the XDG dirs. Safe to call on every install/--init: it no-ops once
# the breadcrumb exists, and mv -n never clobbers an already-present target.
# Dependency-free (plain printf) so install.sh can call it without sourcing log.sh.
# Requires paths.sh to have been sourced first (for the ANTCRATE_* vars).

ac_migrate_xdg() {
    local legacy="$HOME/.antcrate"
    [[ -d "$legacy" ]] || return 0
    [[ -e "$legacy/MIGRATED" ]] && return 0

    mkdir -p "$ANTCRATE_CONFIG_HOME" "$ANTCRATE_DATA_HOME" "$ANTCRATE_STATE_HOME"

    # config base
    [[ -f "$legacy/config" ]] && mv -n "$legacy/config" "$ANTCRATE_CONFIG"
    # data base (guard dir targets so mv doesn't nest into an existing dir)
    [[ -f "$legacy/registry.json" ]] && mv -n "$legacy/registry.json" "$ANTCRATE_REGISTRY"
    [[ -f "$legacy/registry.mmd" ]]  && mv -n "$legacy/registry.mmd"  "$ANTCRATE_REGISTRY_MMD"
    [[ -d "$legacy/intel" && ! -e "$ANTCRATE_INTEL_DIR" ]] && mv -n "$legacy/intel" "$ANTCRATE_INTEL_DIR"

    # everything else (logs, backups, events, locks, quarantine, …) → state base
    local entry base
    shopt -s nullglob dotglob
    for entry in "$legacy"/*; do
        base=$(basename "$entry")
        [[ "$base" == "MIGRATED" ]] && continue
        [[ -e "$ANTCRATE_STATE_HOME/$base" ]] && continue
        mv -n "$entry" "$ANTCRATE_STATE_HOME/$base"
    done
    shopt -u nullglob dotglob

    date -u +%FT%TZ > "$legacy/MIGRATED" 2>/dev/null || true
    printf '[antcrate] migrated ~/.antcrate -> XDG dirs (config/data/state)\n'
}
