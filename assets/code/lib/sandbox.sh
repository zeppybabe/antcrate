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
# Degraded-Linux case: on hosts with kernel.apparmor_restrict_unprivileged_
# userns=1 (DEFAULT on Ubuntu 23.10+/24.04), `systemd-run --user` SUCCEEDS
# but the kernel silently DROPS PrivateNetwork=yes and ProtectHome=read-only
# — logged only to the journal ("proceeding without ..."), nothing on the
# forwarded stdout/stderr. A probe that merely checks "did systemd-run exit
# 0" cannot see this and reports capable when the payload would actually run
# with full network + a writable home. So the probe below launches a real
# hardened unit and checks confinement FROM INSIDE it (loopback-only
# networking, non-writable $HOME); only that verifies the properties
# actually took effect on this kernel.
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
# unit launched WITH the hardening properties, verified from inside the unit
# (not merely "did systemd-run exit 0" — see header comment on the
# apparmor_restrict_unprivileged_userns degrade, where properties are
# silently dropped and a no-op probe would false-positive). Only the
# loopback interface visible AND $HOME not writable proves the properties
# actually applied. Result cached for the process lifetime.
ac_sandbox_capable() {
    if [[ -z "$_AC_SANDBOX_PROBED" ]]; then
        _AC_SANDBOX_PROBED=1
        # shellcheck disable=SC2016  # single-quoted: expands inside the probe unit, not here
        if [[ "${AC_OS:-linux}" == linux ]] \
           && command -v systemd-run >/dev/null 2>&1 \
           && systemd-run --user --quiet --collect --wait --pipe \
                  -p PrivateNetwork=yes \
                  -p ProtectHome=read-only \
                  -p PrivateTmp=yes \
                  -p NoNewPrivileges=yes \
                  -- bash -c '[ "$(ls /sys/class/net)" = "lo" ] && [ ! -w "$HOME" ]' \
                  >/dev/null 2>&1; then
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
    # ReadWritePaths= is space-separated; whitespace in wpath would silently
    # widen the writable set to multiple paths. A relative path is also
    # meaningless as a mount boundary.
    if [[ "$wpath" =~ [[:space:]] ]]; then
        ac_error "sandbox: write_path must not contain whitespace: $wpath"
        return 2
    fi
    if [[ "$wpath" != /* ]]; then
        ac_error "sandbox: write_path must be an absolute path: $wpath"
        return 2
    fi
    if [[ "${ANTCRATE_SANDBOX_DISABLE:-0}" == "1" ]]; then
        ac_warn "sandbox: DISABLED via ANTCRATE_SANDBOX_DISABLE — running unsandboxed"
        "$@"
        return
    fi
    if ! ac_sandbox_capable; then
        if [[ "${AC_OS:-linux}" == darwin ]]; then
            ac_warn "sandbox: unavailable on this OS — running unsandboxed"
        else
            ac_warn "sandbox: hardening not enforceable on this host (kernel/AppArmor restriction?) — running unsandboxed"
        fi
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

# ac_endpoint_run <name> [extra-args...]
# Launch a kind:local endpoint from policy.json — prompt on stdin, completion
# on stdout. Sandboxed by default (endpoint "sandbox": false opts out —
# HUMAN-set, like all endpoint fields). vllm/api endpoints are remote and are
# REFUSED here, not downgraded (bizcrate fail-closed stance).
# MOCK_LLM_MODE passes through when set: systemd-run units do not inherit the
# caller's environment, so it is carried explicitly via env(1).
ac_endpoint_run() {
    local name="${1:-}"
    [[ -n "$name" ]] || { ac_error "endpoint: usage: ac_endpoint_run <name> [args...]"; return 2; }
    shift
    local kind
    kind=$(ac_policy_get ".endpoints[\"$name\"].kind") \
        || { ac_error "endpoint: no policy file — run: antcrate policy seed"; return 1; }
    [[ -n "$kind" ]] || { ac_error "endpoint: unknown endpoint '$name'"; return 1; }
    [[ "$kind" == "local" ]] \
        || { ac_error "endpoint: '$name' is kind $kind — only local endpoints are launched"; return 1; }
    local exec_bin model_file sandboxed
    exec_bin=$(ac_policy_get ".endpoints[\"$name\"].exec")
    [[ -n "$exec_bin" ]] || { ac_error "endpoint: '$name' has no exec"; return 1; }
    model_file=$(ac_policy_get ".endpoints[\"$name\"].model_file")
    sandboxed=$(ac_policy_get ".endpoints[\"$name\"].sandbox")
    local -a cmd=()
    [[ -n "${MOCK_LLM_MODE:-}" ]] && cmd+=( env "MOCK_LLM_MODE=$MOCK_LLM_MODE" )
    cmd+=( "$exec_bin" )
    [[ -n "$model_file" ]] && cmd+=( -m "${model_file/#\~/$HOME}" )
    cmd+=( "$@" )
    if [[ "$sandboxed" == "false" ]]; then
        "${cmd[@]}"
    else
        ac_sandbox_run "${ANTCRATE_HOME:-$HOME/.antcrate}" -- "${cmd[@]}"
    fi
}
