#!/usr/bin/env bash
# _zones.sh — shared zone definitions for the Claude Code gateway guard.
#
# Sourced by gateway-guard.sh. This file is the guard's AUDITABLE SECURITY
# SURFACE: the critical-path set and the dangerous-command catalogue live here
# in one reviewable place. See docs/specs/2026-05-31-harness-enforcement-layer.md.
#
# Env-aware so fixture tests can point ANTCRATE_HOME / ANTCRATE_REGISTRY at a
# tmpdir. In production the registry resolves under the XDG data home
# (~/.local/share/antcrate), with the pre-migration ~/.antcrate as fallback.

# XDG homes, resolved exactly as lib/paths.sh does. Kept as a private helper so
# the control plane and the registry cannot drift apart again.
_zones_data_home() {
    printf '%s\n' "${ANTCRATE_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/antcrate}"
}
_zones_state_home() {
    printf '%s\n' "${ANTCRATE_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/antcrate}"
}
_zones_config_home() {
    printf '%s\n' "${ANTCRATE_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/antcrate}"
}

# Control-plane roots — themselves critical (hard-blocked). One per line.
# Covers state (daemon lock, backups, policy), data (registry, intel,
# templates), config (rule #13 human-only file), and the legacy pre-XDG home
# which may still hold a stub or logs.
zones_control_plane() {
    _zones_state_home
    _zones_data_home
    _zones_config_home
    printf '%s\n' "${ANTCRATE_HOME:-$HOME/.antcrate}"
}

# Registry file path. Resolution order matches lib/paths.sh:30 —
# ANTCRATE_REGISTRY, then the data home, then legacy ~/.antcrate as a last
# resort. ANTCRATE_HOME means the STATE home and is never consulted for the
# registry: conflating the two is what made this guard read a stub.
#
# plugin/hooks/session-digest.sh carries a hand-written copy of this exact
# resolution order (it cannot source this file — hooks.json wires it as a
# standalone script). That copy must move together with this function, or
# _zones_registry and session-digest.sh will disagree on which registry.json
# is live.
#
# The legacy fallback only applies when the data home is the *default*
# ($HOME/.local/share/antcrate): if the caller explicitly set
# ANTCRATE_DATA_HOME or XDG_DATA_HOME, that override wins outright, even
# before anything has been written under it — an explicit relocation is not
# grounds to silently prefer the pre-migration stub.
_zones_registry() {
    if [ -n "${ANTCRATE_REGISTRY:-}" ]; then
        printf '%s\n' "$ANTCRATE_REGISTRY"; return 0
    fi
    local xdg legacy
    xdg="$(_zones_data_home)/registry.json"
    legacy="$HOME/.antcrate/registry.json"
    if [ -n "${ANTCRATE_DATA_HOME:-}" ] || [ -n "${XDG_DATA_HOME:-}" ] \
        || [ -r "$xdg" ] || [ ! -r "$legacy" ]; then
        printf '%s\n' "$xdg"
    else
        printf '%s\n' "$legacy"
    fi
}

# Policy file path — same resolution shape as _zones_registry above, but for
# lib/policy.sh's policy.json. That file resolves under ANTCRATE_HOME, which
# lib/paths.sh aliases to the STATE home; a standalone hook has no paths.sh,
# so it must reproduce the STATE-home math itself or its default silently
# points at a path nothing ever writes. Order: ANTCRATE_POLICY_FILE, then the
# XDG state home, then legacy ~/.antcrate/anycrate/policy.json as a last
# resort. An explicit ANTCRATE_STATE_HOME/XDG_STATE_HOME wins outright, same
# relocation rule as the registry.
_zones_policy_file() {
    if [ -n "${ANTCRATE_POLICY_FILE:-}" ]; then
        printf '%s\n' "$ANTCRATE_POLICY_FILE"; return 0
    fi
    local xdg legacy
    xdg="$(_zones_state_home)/anycrate/policy.json"
    legacy="$HOME/.antcrate/anycrate/policy.json"
    if [ -n "${ANTCRATE_STATE_HOME:-}" ] || [ -n "${XDG_STATE_HOME:-}" ] \
        || [ -r "$xdg" ] || [ ! -r "$legacy" ]; then
        printf '%s\n' "$xdg"
    else
        printf '%s\n' "$legacy"
    fi
}

# Registered project roots, one per line. Returns non-zero (and prints nothing)
# when the registry is unreadable — the guard treats that as the fail-open
# boundary for registry-dependent rules.
zones_registered_roots() {
    local reg
    reg="$(_zones_registry)"
    [ -r "$reg" ] || return 1
    jq -r '.projects[]?.path // empty' "$reg" 2>/dev/null
}

# Static critical-zone path prefixes: system dirs, identity/shell files, and the
# AntCrate control plane. A path that equals or sits under any of these is
# hard-blocked for destructive ops regardless of registry health.
zones_critical_paths() {
    local home="${HOME:-/root}"
    printf '%s\n' \
        / /etc /usr /bin /sbin /lib /lib64 /boot /sys /proc /dev /var \
        /System /Library /Applications \
        "$home/Library" \
        "$home/.bashrc" "$home/.zshrc" "$home/.profile" \
        "$home/.ssh" "$home/.gnupg" "$home/.config" \
        "$(zones_control_plane)"
}

# User-temp prefixes: destructive ops here are as sanctioned as Linux /tmp.
# macOS puts per-user temp dirs under /var/folders (physical /private/var/…),
# which would otherwise inherit /var criticality and block every agent temp-file
# cleanup. Control-plane zones keep their criticality even inside these
# prefixes (the guard checks them separately).
zones_safe_tmp_prefixes() {
    printf '%s\n' /tmp /private/tmp /var/folders /private/var/folders
    [ -n "${TMPDIR:-}" ] && printf '%s\n' "${TMPDIR%/}"
}

# Dangerous-command argv0 catalogue (matched by basename in the guard). These
# can damage the system/hardware and are blocked in ANY zone.
# shellcheck disable=SC2034  # consumed by gateway-guard.sh after sourcing
ZONES_DANGEROUS_ARGV0=(dd fdisk parted mkswap modprobe insmod rmmod)
