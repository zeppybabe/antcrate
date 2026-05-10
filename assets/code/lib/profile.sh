#!/usr/bin/env bash
# antcrate :: lib/profile.sh — read-only project profiler.
#
# Inspects a registered project and emits a structured stream of signals:
# domain (from registry), stack signals (file presence: package.json,
# Cargo.toml, *.sh, *.sql, etc.), tooling configs, env-var presence,
# and a list of recommended hook templates / .gitignore entries.
#
# Used by --hook-autoinstall (#111) to decide what to install.
#
# Public API:
#   ac_profile     <project>          — human-readable summary
#   ac_profile_raw <project>          — tab-separated stream (category\tkey\tvalue)
#
# Internal:
#   _ac_profile_count_files <path> <name-pattern>
#
# Output stream format (one record per line, three TAB-separated fields):
#   <category>  <key>  <value>
# Categories: domain | stack | tooling | env | recommend
#
# Sourced by wrapper. Depends on registry.sh, log.sh.

# _ac_profile_count_files <path> <find-args...>
# Internal helper. Counts files matching find args at the given path,
# skipping common heavy/irrelevant trees (.git, node_modules, .venv, etc.).
_ac_profile_count_files() {
    local p="$1"; shift
    find "$p" -maxdepth 4 \
        -path '*/.git'         -prune -o \
        -path '*/node_modules' -prune -o \
        -path '*/.venv'        -prune -o \
        -path '*/venv'         -prune -o \
        -path '*/target'       -prune -o \
        -path '*/dist'         -prune -o \
        -path '*/build'        -prune -o \
        -type f "$@" -print 2>/dev/null | wc -l
}

# ac_profile_raw <project>
# Print the tab-separated signal stream. Other flags consume this.
ac_profile_raw() {
    local project="${1:-}"
    [[ -n "$project" ]] || { ac_error "profile: missing project name"; return 1; }
    ac_registry_has "$project" || { ac_error "profile: unknown project '$project'"; return 1; }

    local p
    p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "profile: missing path: $p"; return 1; }

    local domain
    domain=$(ac_registry_get "$project" parent 2>/dev/null || true)
    [[ -z "$domain" ]] && domain="_generic"

    printf 'domain\tregistry\t%s\n' "$domain"

    # Stack signals — file-presence indicators.
    [[ -f "$p/package.json"     ]] && printf 'stack\tnode\ttrue\n'
    [[ -f "$p/pnpm-lock.yaml"   ]] && printf 'stack\tpnpm\ttrue\n'
    [[ -f "$p/yarn.lock"        ]] && printf 'stack\tyarn\ttrue\n'
    [[ -f "$p/bun.lockb"        ]] && printf 'stack\tbun\ttrue\n'
    [[ -f "$p/svelte.config.js" || -f "$p/svelte.config.ts" ]] && printf 'stack\tsvelte\ttrue\n'
    [[ -f "$p/Cargo.toml"       ]] && printf 'stack\trust\ttrue\n'
    [[ -f "$p/go.mod"           ]] && printf 'stack\tgo\ttrue\n'
    [[ -f "$p/pyproject.toml" || -f "$p/setup.py" || -f "$p/requirements.txt" ]] && printf 'stack\tpython\ttrue\n'
    [[ -f "$p/composer.json"    ]] && printf 'stack\tphp\ttrue\n'
    [[ -f "$p/Gemfile"          ]] && printf 'stack\truby\ttrue\n'

    # Count-based stack signals.
    local sh_count sql_count
    sh_count=$(_ac_profile_count_files "$p" -name '*.sh')
    sql_count=$(_ac_profile_count_files "$p" -name '*.sql')
    (( sh_count  > 0 )) && printf 'stack\tbash\t%s\n' "$sh_count"
    (( sql_count > 0 )) && printf 'stack\tsql\t%s\n'  "$sql_count"

    # Tooling configs.
    compgen -G "$p/.eslintrc*"    >/dev/null && printf 'tooling\teslint\ttrue\n'
    [[ -f "$p/tsconfig.json"      ]] && printf 'tooling\ttypescript\ttrue\n'
    compgen -G "$p/.prettierrc*"  >/dev/null && printf 'tooling\tprettier\ttrue\n'
    [[ -f "$p/.pre-commit-config.yaml" ]] && printf 'tooling\tpre-commit-framework\ttrue\n'
    [[ -f "$p/shellcheckrc" || -f "$p/.shellcheckrc" ]] && printf 'tooling\tshellcheck-config\ttrue\n'
    [[ -d "$p/tests" || -d "$p/test" ]] && printf 'tooling\ttests-dir\ttrue\n'
    compgen -G "$p/tests/*.bats"  >/dev/null 2>&1 && printf 'tooling\tbats\ttrue\n'

    # Env-var presence.
    local env_files
    env_files=$(find "$p" -maxdepth 2 \
        -path '*/.git' -prune -o \
        -path '*/node_modules' -prune -o \
        \( -name '.env' -o -name '.env.*' \) -type f -print 2>/dev/null | wc -l)
    (( env_files > 0 )) && printf 'env\tenv-files\t%s\n' "$env_files"
    [[ -f "$p/.env.example" ]] && printf 'env\tenv-example\ttrue\n'

    # Recommendations.
    printf 'recommend\thook\tpre-commit-secrets\n'
    (( sh_count > 0 )) && printf 'recommend\thook\tpre-commit-stack-bash\n'
    [[ "$project" == "antcrate" || -f "$p/assets/code/install.sh" ]] && printf 'recommend\thook\tpre-commit-ci\n'
    if (( env_files > 0 )); then
        printf 'recommend\tgitignore\t.env\n'
        printf 'recommend\tgitignore\t.env.local\n'
        printf 'recommend\tgitignore\t.env.*.local\n'
    fi

    return 0
}

# ac_profile <project>
# Human-readable rendering of the signal stream.
ac_profile() {
    local project="${1:-}"
    [[ -n "$project" ]] || { ac_error "profile: missing project name"; return 1; }

    local stream
    stream=$(ac_profile_raw "$project") || return 1

    printf 'profile: %s\n' "$project"
    printf '  %-12s  %-24s  %s\n' "category" "key" "value"
    printf '  %-12s  %-24s  %s\n' "------------" "------------------------" "-----"
    while IFS=$'\t' read -r cat key val; do
        printf '  %-12s  %-24s  %s\n' "$cat" "$key" "$val"
    done <<< "$stream"
}
