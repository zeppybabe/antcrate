#!/usr/bin/env bash
# antcrate :: lib/env_scan.sh — env-var detector + .gitignore guard.
#
# Read-only by default: lists .env files at the project root + counts
# env-var references in source (process.env, os.environ, getenv, etc.).
# Pass --apply to idempotently add standard .env patterns to .gitignore
# so secrets stay untracked.
#
# Refuses to touch the .env files themselves — that's #85 territory
# (--env-setup is the human-driven setup wizard).
#
# Public API:
#   ac_env_scan <project> [--apply]
#
# Internal: (none)
#
# Sourced by wrapper. Depends on registry.sh, log.sh.

# Patterns to add to .gitignore on --apply. Conservative set — only
# files that should NEVER be committed. .env.development / .env.production
# are intentionally excluded because some frameworks (Next.js) commit them.
_AC_ENV_GITIGNORE_PATTERNS=( '.env' '.env.local' '.env.*.local' )

# ac_env_scan <project> [--apply]
ac_env_scan() {
    local project="" apply=0
    while (( $# > 0 )); do
        case "$1" in
            --apply) apply=1; shift ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                else ac_error "env-scan: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project" ]] || { ac_error "env-scan: missing project name"; return 1; }
    ac_registry_has "$project" || { ac_error "env-scan: unknown project '$project'"; return 1; }
    local p
    p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "env-scan: missing path: $p"; return 1; }

    # Discover .env / .env.* files (excluding .env.example, which is fine to track).
    local env_files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$(basename "$f")" in .env.example|.env.sample) continue ;; esac
        env_files+=("$f")
    done < <(find "$p" -maxdepth 2 \
        -path '*/.git'         -prune -o \
        -path '*/node_modules' -prune -o \
        -path '*/.venv'        -prune -o \
        \( -name '.env' -o -name '.env.*' \) -type f -print 2>/dev/null)

    # Count env-var references in source. One regex covers the common
    # cases across JS/TS/Py/Rb/Java/PHP. Heavy directories are excluded.
    local ref_count
    ref_count=$(grep -rE \
        'process\.env\.|import\.meta\.env\.|os\.environ|os\.getenv|System\.getenv|ENV\[' \
        --include='*.js' --include='*.ts' --include='*.jsx' --include='*.tsx' \
        --include='*.svelte' --include='*.py' --include='*.rb' --include='*.java' \
        --include='*.php' \
        "$p" 2>/dev/null \
        | grep -cv -E '/\.git/|/node_modules/|/\.venv/|/venv/|/dist/|/build/|/target/' || true)
    ref_count="${ref_count:-0}"

    # Human-readable summary.
    printf 'env-scan: %s\n' "$project"
    printf '  .env files found (%d):\n' "${#env_files[@]}"
    if (( ${#env_files[@]} > 0 )); then
        local f
        for f in "${env_files[@]}"; do
            printf '    %s\n' "$f"
        done
    else
        printf '    (none)\n'
    fi
    printf '  env-var references in source: %d\n' "$ref_count"
    if [[ -f "$p/.env.example" ]]; then
        printf '  .env.example: present\n'
    else
        printf '  .env.example: missing (consider creating one)\n'
    fi

    # Apply mode: patch .gitignore.
    if (( apply == 1 )); then
        local gi="$p/.gitignore"
        local added=()
        local pat
        for pat in "${_AC_ENV_GITIGNORE_PATTERNS[@]}"; do
            if [[ -f "$gi" ]] && grep -qFx "$pat" "$gi"; then
                continue
            fi
            printf '%s\n' "$pat" >> "$gi"
            added+=("$pat")
        done
        if (( ${#added[@]} > 0 )); then
            ac_info "env-scan: appended to $gi: ${added[*]}"
            printf '  patched .gitignore (added: %s)\n' "${added[*]}"
        else
            printf '  .gitignore already covers .env patterns — no changes\n'
        fi
    fi

    return 0
}
