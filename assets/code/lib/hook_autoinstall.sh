#!/usr/bin/env bash
# antcrate :: lib/hook_autoinstall.sh — orchestrate profile + install + env-guard.
#
# The user-facing "make it automatic" surface. Reads the project's
# profile (lib/profile.sh) and:
#   1. Picks one hook per git-hook slot (pre-commit, pre-push, etc.)
#      from the recommendations. Priority order is the order signals
#      appear in the profile output.
#   2. Calls ac_hook_install for each picked template.
#   3. Calls ac_env_scan --apply to patch .gitignore with .env safety.
#   4. Prints a structured summary of what was added, skipped, refused.
#
# Phase-1 limitation: only ONE template installs per git-hook slot
# because git itself runs only one file per event. Additional checks
# can be installed manually with ac_hook_install <project> <template>
# <explicit-hook-name>. A composite template that chains multiple
# checks is queued for HOOK_PLAN follow-up.
#
# Public API:
#   ac_hook_autoinstall <project> [--dry-run]
#
# Internal: (none)
#
# Sourced by wrapper. Depends on profile.sh, hooks.sh, env_scan.sh, registry.sh, log.sh.

# ac_hook_autoinstall <project> [--dry-run]
ac_hook_autoinstall() {
    local project="" dry=0
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) dry=1; shift ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                else ac_error "hook-autoinstall: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project" ]] || { ac_error "hook-autoinstall: missing project name"; return 1; }
    ac_registry_has "$project" || { ac_error "hook-autoinstall: unknown project '$project'"; return 1; }
    local p
    p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "hook-autoinstall: missing path: $p"; return 1; }
    [[ -d "$p/.git" ]] || { ac_error "hook-autoinstall: not a git repo: $p (run --git-init first)"; return 1; }

    # Pull profile signals.
    local stream
    stream=$(ac_profile_raw "$project") || return 1

    # Pick one template per git-hook slot. First seen wins (profile order
    # is meaningful — universal checks like pre-commit-secrets come first).
    local picked_pre_commit="" picked_pre_push=""
    local cat key val
    while IFS=$'\t' read -r cat key val; do
        [[ "$cat" == "recommend" && "$key" == "hook" ]] || continue
        case "$val" in
            pre-commit-*) [[ -z "$picked_pre_commit" ]] && picked_pre_commit="$val" ;;
            pre-push-*)   [[ -z "$picked_pre_push"   ]] && picked_pre_push="$val" ;;
        esac
    done <<< "$stream"

    # All recommendations (for the skipped-summary).
    local all_recommended=()
    while IFS=$'\t' read -r cat key val; do
        [[ "$cat" == "recommend" && "$key" == "hook" ]] && all_recommended+=("$val")
    done <<< "$stream"

    printf 'hook-autoinstall: %s\n' "$project"
    printf '  recommendations: %s\n' "${all_recommended[*]:-(none)}"
    if [[ -n "$picked_pre_commit" ]]; then
        printf '  picked pre-commit: %s\n' "$picked_pre_commit"
    fi
    if [[ -n "$picked_pre_push" ]]; then
        printf '  picked pre-push: %s\n'   "$picked_pre_push"
    fi

    # Surface skipped pre-commit-* templates (Phase-1 single-slot constraint).
    local h skipped=()
    for h in "${all_recommended[@]}"; do
        case "$h" in
            pre-commit-*) [[ "$h" != "$picked_pre_commit" ]] && skipped+=("$h") ;;
            pre-push-*)   [[ "$h" != "$picked_pre_push"   ]] && skipped+=("$h") ;;
        esac
    done
    if (( ${#skipped[@]} > 0 )); then
        printf '  skipped (single-slot): %s\n' "${skipped[*]}"
        printf '    install manually with: antcrate --hook-install %s <template> <hook-name>\n' "$project"
    fi

    if (( dry == 1 )); then
        printf '  (dry-run: no changes)\n'
        return 0
    fi

    # Install picked templates (skip-on-error so we still get the env step).
    local install_log=()
    if [[ -n "$picked_pre_commit" ]]; then
        if ac_hook_install "$project" "$picked_pre_commit" 2>/dev/null; then
            install_log+=("installed: $picked_pre_commit -> pre-commit")
        else
            install_log+=("refused: $picked_pre_commit -> pre-commit (existing differs; use --hook-install --force)")
        fi
    fi
    if [[ -n "$picked_pre_push" ]]; then
        if ac_hook_install "$project" "$picked_pre_push" 2>/dev/null; then
            install_log+=("installed: $picked_pre_push -> pre-push")
        else
            install_log+=("refused: $picked_pre_push -> pre-push (existing differs; use --hook-install --force)")
        fi
    fi

    # Always patch .gitignore for env safety (idempotent).
    ac_env_scan "$project" --apply >/dev/null

    printf '  hooks:\n'
    if (( ${#install_log[@]} == 0 )); then
        printf '    (none picked)\n'
    else
        local entry
        for entry in "${install_log[@]}"; do
            printf '    %s\n' "$entry"
        done
    fi
    printf '  .gitignore: patched (idempotent)\n'
    printf '  done.\n'
    return 0
}
