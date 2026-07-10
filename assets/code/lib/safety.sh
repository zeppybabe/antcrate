#!/usr/bin/env bash
# shellcheck disable=SC2034  # AC_LAST_BACKUP_PATH is read by callers after the guard returns
# antcrate :: lib/safety.sh — runtime path-safety guard
#
# Refuses destructive ops outside $ANTCRATE_ROOT unless explicitly overridden.

: "${ANTCRATE_ROOT:=$HOME/projects}"
: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_ALLOW_OUTSIDE_ROOT:=0}"

# allowed write zones (canonical absolute paths)
ac_safety_allowed_zones() {
    printf '%s\n' \
        "$(realpath -m "$ANTCRATE_ROOT")" \
        "$(realpath -m "$ANTCRATE_HOME")"
    # The skill source PROJECT ROOT is also AntCrate's domain — needed so the
    # antcrate codebase itself can be registered, relocated, and pushed.
    # Derivation order (proposal safety-skill-zone-fix, 2026-06-10):
    #   1. registry path for the self project, IF it is an ancestor of
    #      $ANTCRATE_SELFSRC (a non-ancestor entry must not widen the zone);
    #   2. else: <root>/assets/code layout -> two levels up;
    #   3. else: $ANTCRATE_SELFSRC itself (flat layout — never the parent,
    #      which would put unrelated sibling trees in-zone).
    if [[ -n "${ANTCRATE_SELFSRC:-}" && -d "$ANTCRATE_SELFSRC" ]]; then
        local skill_root=""
        if declare -F ac_registry_get >/dev/null 2>&1; then
            skill_root=$(ac_registry_get "${ANTCRATE_SELF_NAME:-antcrate}" path 2>/dev/null) || skill_root=""
            case "$ANTCRATE_SELFSRC" in
                "$skill_root"|"$skill_root"/*) : ;;
                *) skill_root="" ;;
            esac
        fi
        if [[ -z "$skill_root" ]]; then
            case "$ANTCRATE_SELFSRC" in
                */assets/code) skill_root=$(dirname "$(dirname "$ANTCRATE_SELFSRC")") ;;
                *)             skill_root="$ANTCRATE_SELFSRC" ;;
            esac
        fi
        printf '%s\n' "$(realpath -m "$skill_root")"
    fi
}

# ac_safety_check_path <path>  — returns 0 if path is inside an allowed zone
ac_safety_check_path() {
    local target="$1"
    [[ -z "$target" ]] && return 1
    local abs; abs=$(realpath -m "$target")
    local zone
    while IFS= read -r zone; do
        case "$abs" in
            "$zone"|"$zone"/*) return 0 ;;
        esac
    done < <(ac_safety_allowed_zones)
    return 1
}

# ac_gate_confirm <prompt> — TTY-optional confirmation (audit 2026-07-10).
# Non-interactive callers proceed: Claude Code's permission layer is the
# outer gate; the inner y/N only fires when a human is actually present.
# Test hook: ANTCRATE_ASSUME_TTY=1 forces the prompt path under bats.
ac_gate_confirm() {
    local prompt="$1"
    if [[ ! -t 0 && "${ANTCRATE_ASSUME_TTY:-0}" != "1" ]]; then
        ac_info "gate: non-interactive — proceeding ($prompt)"
        return 0
    fi
    local ans=""
    read -r -p "$prompt [y/N] " ans || true
    case "${ans,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

# ac_safety_guard <op-description> <path>  — abort if path is outside zones
# Override: ANTCRATE_ALLOW_OUTSIDE_ROOT=1 ac_safety_guard ...
ac_safety_guard() {
    local op="$1" target="$2"
    if (( ANTCRATE_ALLOW_OUTSIDE_ROOT == 1 )); then
        ac_warn "safety: override active — $op on $target"
        return 0
    fi
    if ! ac_safety_check_path "$target"; then
        ac_error "safety: refusing $op on path outside allowed zones: $target"
        ac_error "safety: allowed zones: $(ac_safety_allowed_zones | tr '\n' ' ')"
        ac_error "safety: to override, re-run with ANTCRATE_ALLOW_OUTSIDE_ROOT=1"
        return 1
    fi
    return 0
}

# ac_safety_guard_destructive <project> <op-description> <path>
# Enforces: backup-before-removal + human approval (unless ANTCRATE_REMOVAL_PREAPPROVED=1).
# Returns 0 only if a successful backup exists AND approval is granted.
# Sets AC_LAST_BACKUP_PATH on success so callers can reference the tarball in logs.
ac_safety_guard_destructive() {
    local project="$1" op="$2" target="$3"
    AC_LAST_BACKUP_PATH=""

    # 0. compaction-canary gate — fail-OPEN when the core binary is absent
    # (rc 2): an unbuilt optional C helper must never block recovery-backed
    # ops (audit 2026-07-10). Stale context (rc 4) still blocks.
    if [[ "${ANTCRATE_CANARY_DISABLE:-0}" != "1" ]]; then
        local _canary_rc=0
        ac_canary_gate_check || _canary_rc=$?
        if (( _canary_rc == 2 )); then
            ac_warn "safety: canary core missing — gate skipped (fail-open)"
        elif (( _canary_rc != 0 )); then
            ac_error "safety: refusing $op — compaction canary gate failed (see above)"
            return 1
        fi
    fi

    # 1. path must be inside allowed zones
    ac_safety_guard "$op" "$target" || return 1

    # 2. mandatory backup
    local backup
    if ! backup=$(ac_backup_create "$project" "$target"); then
        ac_error "safety: refusing $op — backup failed (no backup, no removal)"
        return 1
    fi
    AC_LAST_BACKUP_PATH="$backup"

    # 3. approval gate — non-interactive proceeds (backup verified above,
    # quarantine catches the artifact); approval moves out-of-band to the
    # duty ledger (audit 2026-07-10). PREAPPROVED kept one release for compat.
    if [[ "${ANTCRATE_REMOVAL_PREAPPROVED:-0}" == "1" ]]; then
        ac_warn "safety: removal pre-approved by config — proceeding ($op on $target)"
        return 0
    fi
    if [[ ! -t 0 && "${ANTCRATE_ASSUME_TTY:-0}" != "1" ]]; then
        if declare -F ac_duty_add >/dev/null 2>&1; then
            ac_duty_add --type command \
                "review: $op on $project — backup at $backup" >/dev/null 2>&1 || true
        fi
        ac_warn "safety: non-interactive $op proceeding (backup + review duty recorded)"
        return 0
    fi
    printf '\n'
    printf 'AntCrate destructive-op approval required:\n' >&2
    printf '  project : %s\n' "$project" >&2
    printf '  op      : %s\n' "$op" >&2
    printf '  target  : %s\n' "$target" >&2
    printf '  backup  : %s\n' "$backup" >&2
    if ac_gate_confirm "Proceed?"; then
        ac_info "safety: approved ($op on $target)"
        return 0
    fi
    ac_warn "safety: aborted by user (backup retained at $backup)"
    return 1
}

# ac_safety_safe_rm <path>  — only removes inside allowed zones
ac_safety_safe_rm() {
    local target="$1"
    ac_safety_guard "rm" "$target" || return 1
    _ac_quarantine_capture _generic "$target" safe-rm "$(basename "$target")"
}

# ac_safety_safe_mv <src> <dst>  — both src and dst must be inside allowed zones
ac_safety_safe_mv() {
    local src="$1" dst="$2"
    ac_safety_guard "mv (source)" "$src" || return 1
    ac_safety_guard "mv (target)" "$dst" || return 1
    mv -- "$src" "$dst"
}
