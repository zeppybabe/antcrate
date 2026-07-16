#!/usr/bin/env bash
# _zones.sh — shared zone definitions for the Claude Code gateway guard.
#
# Sourced by gateway-guard.sh. This file is the guard's AUDITABLE SECURITY
# SURFACE: the critical-path set and the dangerous-command catalogue live here
# in one reviewable place. See docs/specs/2026-05-31-harness-enforcement-layer.md.
#
# Env-aware so fixture tests can point ANTCRATE_HOME / ANTCRATE_REGISTRY at a
# tmpdir. In production both default to ~/.antcrate.

# Control-plane root — itself critical (hard-blocked).
zones_control_plane() {
    printf '%s\n' "${ANTCRATE_HOME:-$HOME/.antcrate}"
}

# Registry file path.
_zones_registry() {
    printf '%s\n' "${ANTCRATE_REGISTRY:-${ANTCRATE_HOME:-$HOME/.antcrate}/registry.json}"
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
