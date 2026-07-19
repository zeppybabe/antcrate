#!/usr/bin/env bash
# antcrate :: lib/paths.sh — single source of truth for on-disk locations.
#
# Sourced FIRST by bin/antcrate and bin/antcrated, before every other lib, so
# the `: "${VAR:=…}"` fallbacks scattered through the libs become no-ops. Honors
# the XDG base-directory env vars; otherwise uses the XDG default home dirs.
#
#   config  ~/.config/antcrate        human-edited config
#   data    ~/.local/share/antcrate   registry, templates, intel, tools (portable data)
#   state   ~/.local/state/antcrate   logs, backups, events, locks (machine state)
#
# ANTCRATE_HOME is kept as an alias of the STATE base so the many `$ANTCRATE_HOME/<x>`
# *state* joins in the libs keep resolving; config/registry/intel get their own
# vars below because they live under config/data, not state.

: "${ANTCRATE_CONFIG_HOME:=${XDG_CONFIG_HOME:-$HOME/.config}/antcrate}"
: "${ANTCRATE_DATA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/antcrate}"
: "${ANTCRATE_STATE_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/antcrate}"

# back-compat alias: the state base (legacy installs used $HOME/.antcrate for all of it)
: "${ANTCRATE_HOME:=$ANTCRATE_STATE_HOME}"

# project tree root
: "${ANTCRATE_ROOT:=$HOME/Projects}"

# config base
: "${ANTCRATE_CONFIG:=$ANTCRATE_CONFIG_HOME/config}"

# data base
: "${ANTCRATE_REGISTRY:=$ANTCRATE_DATA_HOME/registry.json}"
: "${ANTCRATE_REGISTRY_MMD:=$ANTCRATE_DATA_HOME/registry.mmd}"
: "${ANTCRATE_INTEL_DIR:=$ANTCRATE_DATA_HOME/intel}"
: "${ANTCRATE_TEMPLATES:=$ANTCRATE_DATA_HOME/templates}"

# state base (explicit, even though the alias would cover them — single source of truth)
: "${ANTCRATE_LOG_DIR:=$ANTCRATE_STATE_HOME/log}"
: "${ANTCRATE_BACKUP_DIR:=$ANTCRATE_STATE_HOME/backups}"
: "${ANTCRATE_EVENTS_DIR:=$ANTCRATE_STATE_HOME/events}"
: "${ANTCRATE_LOCK:=$ANTCRATE_STATE_HOME/daemon.lock}"
: "${ANTCRATE_PROPOSALS_LOG:=$ANTCRATE_STATE_HOME/proposals.log}"
: "${ANTCRATE_CI_BASELINE:=$ANTCRATE_STATE_HOME/ci-baseline.json}"
: "${ANTCRATE_CLEANUP_DIR:=$ANTCRATE_STATE_HOME/cleanup}"
: "${ANTCRATE_FETCH_DIR:=$ANTCRATE_STATE_HOME/fetch}"
: "${ANTCRATE_POSTS_DIR:=$ANTCRATE_STATE_HOME/posts}"
