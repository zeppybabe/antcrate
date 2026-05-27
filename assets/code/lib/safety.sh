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
    # The skill source tree (parent of $ANTCRATE_SELFSRC, e.g.
    # ~/.claude/skills/antcrate/) is also AntCrate's domain — needed so the
    # antcrate codebase itself can be registered as a project and pushed.
    if [[ -n "${ANTCRATE_SELFSRC:-}" && -d "$ANTCRATE_SELFSRC" ]]; then
        local skill_root; skill_root=$(dirname "$ANTCRATE_SELFSRC")
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

    # 0. compaction-canary gate (Wave 1) — runs before path/backup/approval
    # so stale safety-context aborts cost zero disk I/O.
    if [[ "${ANTCRATE_CANARY_DISABLE:-0}" != "1" ]]; then
        if ! ac_canary_gate_check; then
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

    # 3. approval gate
    if [[ "${ANTCRATE_REMOVAL_PREAPPROVED:-0}" == "1" ]]; then
        ac_warn "safety: removal pre-approved by config — proceeding ($op on $target)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        # non-interactive (daemon, agent without -y) — refuse
        ac_error "safety: $op requires human approval (run interactively or set ANTCRATE_REMOVAL_PREAPPROVED=1)"
        ac_error "safety: backup retained at $backup"
        return 1
    fi
    printf '\n'
    printf 'AntCrate destructive-op approval required:\n' >&2
    printf '  project : %s\n' "$project" >&2
    printf '  op      : %s\n' "$op" >&2
    printf '  target  : %s\n' "$target" >&2
    printf '  backup  : %s\n' "$backup" >&2
    printf '\nProceed? [y/N] ' >&2
    local ans; read -r ans
    case "${ans,,}" in
        y|yes) ac_info "safety: approved ($op on $target)"; return 0 ;;
        *)     ac_warn "safety: aborted by user (backup retained at $backup)"; return 1 ;;
    esac
}

# ac_safety_safe_rm <path>  — only removes inside allowed zones
ac_safety_safe_rm() {
    local target="$1"
    ac_safety_guard "rm" "$target" || return 1
    rm -rf -- "$target"
}

# ac_safety_safe_mv <src> <dst>  — both src and dst must be inside allowed zones
ac_safety_safe_mv() {
    local src="$1" dst="$2"
    ac_safety_guard "mv (source)" "$src" || return 1
    ac_safety_guard "mv (target)" "$dst" || return 1
    mv -- "$src" "$dst"
}
