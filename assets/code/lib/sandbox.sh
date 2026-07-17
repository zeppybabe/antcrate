#!/usr/bin/env bash
# antcrate :: lib/sandbox.sh — sandboxed local-inference launcher (spec 2026-07-16)
#
# Isolation for locally-launched model runtimes (kind: local endpoints — the
# only kind AntCrate ever launches; vllm/api are remote). V1 launches are
# ONE-SHOT inference calls: PrivateNetwork=yes is safe because nothing needs
# to reach the unit from outside — a persistent SERVER inside a private
# network namespace would be unreachable, so serving mode is out of scope.
#
# macOS: no non-deprecated user-space isolation primitive (sandbox-exec is
# deprecated; a security feature must not sit on a dying API) → warn + run
# unsandboxed (owner decision 2026-07-16: enforced-on-Linux, warn-on-macOS).
#
# Escape hatch: ANTCRATE_SANDBOX_DISABLE=1 (warned). Agents MUST NOT set it
# (AGENTS.md — same class as ANTCRATE_COST_GUARD_DISABLE).

# compat.sh self-source: AC_OS used below; guard makes re-sourcing free
# (bats tests source libs directly, without the wrapper preamble).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

_AC_SANDBOX_PROBED=""
_AC_SANDBOX_RC=1

# rc 0 iff this host can actually confine: Linux AND a systemd-run --user
# that verifiably works (probed with a real no-op unit, not assumed —
# compat.sh philosophy). Result cached for the process lifetime.
ac_sandbox_capable() {
    if [[ -z "$_AC_SANDBOX_PROBED" ]]; then
        _AC_SANDBOX_PROBED=1
        if [[ "${AC_OS:-linux}" == linux ]] \
           && command -v systemd-run >/dev/null 2>&1 \
           && systemd-run --user --quiet --collect --wait true >/dev/null 2>&1; then
            _AC_SANDBOX_RC=0
        fi
    fi
    return "$_AC_SANDBOX_RC"
}

# ac_sandbox_run <write_path> -- <cmd...>
# Run cmd confined: no network, read-only home except <write_path>, private
# /tmp, no privilege escalation. stdin/stdout pass through (--pipe). Runs
# UNSANDBOXED (with a loud warning) only on non-capable hosts or under the
# explicit ANTCRATE_SANDBOX_DISABLE=1 escape hatch. Payload rc propagates.
ac_sandbox_run() {
    local wpath="${1:-}"
    [[ -n "$wpath" ]] || { ac_error "sandbox: usage: ac_sandbox_run <write_path> -- <cmd...>"; return 2; }
    shift
    [[ "${1:-}" == "--" ]] || { ac_error "sandbox: usage: ac_sandbox_run <write_path> -- <cmd...>"; return 2; }
    shift
    (( $# > 0 )) || { ac_error "sandbox: no command given"; return 2; }
    if [[ "${ANTCRATE_SANDBOX_DISABLE:-0}" == "1" ]]; then
        ac_warn "sandbox: DISABLED via ANTCRATE_SANDBOX_DISABLE — running unsandboxed"
        "$@"
        return
    fi
    if ! ac_sandbox_capable; then
        ac_warn "sandbox: unavailable on this OS — running unsandboxed"
        "$@"
        return
    fi
    systemd-run --user --quiet --collect --wait --pipe \
        -p PrivateNetwork=yes \
        -p ProtectHome=read-only \
        -p ReadWritePaths="$wpath" \
        -p PrivateTmp=yes \
        -p NoNewPrivileges=yes \
        -- "$@"
}
