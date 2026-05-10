#!/usr/bin/env bash
# antcrate :: lib/hooks.sh — git-hook inspection + template install for a project.
#
# Public API:
#   ac_hooks_list   <project>                            — list active hooks + which dir is in use
#   ac_hooks_log    <project> [N]                        — tail .git/antcrate-hook.log (default 50)
#   ac_hook_install <project> <template> [hook] [--force] — install a template hook (idempotent;
#                                                          backup-then-overwrite on --force)
#
# Internal:
#   ac_hooks_dir            — resolve effective hooks dir (honors core.hooksPath)
#   _ac_hook_template_path  — resolve absolute path to a template by name
#   _ac_hook_render         — token-substitute a template into a target file
#
# Templates live at assets/code/hooks/templates/. Each is a stand-alone
# shell script with a header line `# antcrate-template-version: <ver>`
# so installed hooks can be audited for staleness later. Tokens
# substituted at install time: __PROJECT_NAME__, __ANTCRATE_BIN__.
#
# Larger queued surface (see assets/docs/HOOK_PLAN.md):
#   --hook-remove / --hook-bypass / commit-msg-format template
#
# Sourced by wrapper. Depends on registry.sh, log.sh.

# ac_hooks_dir <project_path>
# Echo the absolute path of the directory git will read hooks from for this
# project (honors core.hooksPath; falls back to .git/hooks).
ac_hooks_dir() {
    local proj_path="$1"
    [[ -d "$proj_path" ]] || return 1
    [[ -d "$proj_path/.git" ]] || return 1   # not a git repo

    local hp
    hp=$(git -C "$proj_path" config --get core.hooksPath 2>/dev/null || true)
    if [[ -n "$hp" ]]; then
        if [[ "$hp" = /* ]]; then
            printf '%s\n' "$hp"
        else
            printf '%s/%s\n' "$proj_path" "$hp"
        fi
    else
        printf '%s/.git/hooks\n' "$proj_path"
    fi
}

# ac_hooks_list <project>
# Tab-separated lines: <hook-name>\t<status>\t<path>
# Status: "active" (executable, non-sample), "disabled" (file present, not
# executable), or absent entries are simply not listed.
# Header line printed first describes the effective hooks dir.
ac_hooks_list() {
    local project="$1"
    ac_registry_has "$project" || { ac_error "hooks-list: unknown project: $project"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "hooks-list: missing path: $p"; return 1; }

    local dir
    dir=$(ac_hooks_dir "$p") || { ac_error "hooks-list: $p is not a git repo"; return 1; }

    if [[ ! -d "$dir" ]]; then
        printf 'hooks-dir: %s (does not exist)\n' "$dir"
        return 0
    fi

    # Indicate whether antcrate's shipped opt-in dir (.githooks) is active.
    local hp_set
    hp_set=$(git -C "$p" config --get core.hooksPath 2>/dev/null || true)
    if [[ "$hp_set" == ".githooks" ]]; then
        printf 'hooks-dir: %s (antcrate opt-in: ENABLED via core.hooksPath=.githooks)\n' "$dir"
    elif [[ -n "$hp_set" ]]; then
        printf 'hooks-dir: %s (custom: core.hooksPath=%s)\n' "$dir" "$hp_set"
    else
        printf 'hooks-dir: %s (default)\n' "$dir"
    fi

    local f base status
    while IFS= read -r -d '' f; do
        base=$(basename "$f")
        # skip git's bundled samples (only meaningful in default .git/hooks)
        case "$base" in *.sample) continue ;; esac
        if [[ -x "$f" ]]; then status="active"; else status="disabled"; fi
        printf '%s\t%s\t%s\n' "$base" "$status" "$f"
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
}

# ac_hooks_log <project> [lines]
# Tail $project/.git/antcrate-hook.log (the file the shipped pre-commit hook
# tees output to). Useful when a commit got blocked and the terminal output
# is gone (or the commit was attempted from an automation context).
ac_hooks_log() {
    local project="$1" lines="${2:-50}"
    ac_registry_has "$project" || { ac_error "hook-log: unknown project: $project"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "hook-log: missing path: $p"; return 1; }

    local logfile="$p/.git/antcrate-hook.log"
    if [[ ! -f "$logfile" ]]; then
        printf 'no hook log yet at %s\n' "$logfile"
        printf '(the shipped .githooks/pre-commit writes here on every run)\n'
        return 0
    fi

    printf '=== %s (last %s lines) ===\n' "$logfile" "$lines"
    tail -n "$lines" "$logfile"
}

# _ac_hook_template_path <name>
# Resolve absolute path to a hook template. Templates live next to this
# library at ../hooks/templates/<name>. Returns nonzero if not found.
_ac_hook_template_path() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    local lib_dir; lib_dir=$(dirname "${BASH_SOURCE[0]}")
    local tmpl="$lib_dir/../hooks/templates/$name"
    [[ -f "$tmpl" ]] || return 1
    printf '%s\n' "$(cd "$(dirname "$tmpl")" && pwd)/$(basename "$tmpl")"
}

# _ac_hook_render <template-path> <project-name> > stdout
# Token-substitute a template. Prints the rendered hook on stdout.
_ac_hook_render() {
    local tmpl="$1" project="$2"
    local antcrate_bin
    antcrate_bin=$(command -v antcrate 2>/dev/null || echo "antcrate")
    sed -e "s|__PROJECT_NAME__|$project|g" \
        -e "s|__ANTCRATE_BIN__|$antcrate_bin|g" \
        "$tmpl"
}

# ac_hook_install <project> <template> [hook-name] [--force]
# Install a template into the project's effective hooks dir. The hook
# filename defaults to the part of the template name before the first
# dash (e.g. pre-commit-secrets → pre-commit). Pass an explicit
# hook-name to override.
#
# Conflict behavior:
#   - hook absent              → write template, chmod +x
#   - hook present, identical  → no-op (idempotent)
#   - hook present, different  → refuse (default) OR backup-then-overwrite (--force)
# The backup goes to <hooks_dir>/<hook>.bak.<UTC-timestamp>.
ac_hook_install() {
    local project="" template="" hook_name="" force=0
    while (( $# > 0 )); do
        case "$1" in
            --force) force=1; shift ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                elif [[ -z "$template" ]]; then template="$1"
                elif [[ -z "$hook_name" ]]; then hook_name="$1"
                else ac_error "hook-install: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project"  ]] || { ac_error "hook-install: missing project name"; return 1; }
    [[ -n "$template" ]] || { ac_error "hook-install: missing template name"; return 1; }

    ac_registry_has "$project" || { ac_error "hook-install: unknown project '$project'"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p"      ]] || { ac_error "hook-install: missing path: $p"; return 1; }
    [[ -d "$p/.git" ]] || { ac_error "hook-install: not a git repo: $p (use --git-init first)"; return 1; }

    local tmpl
    tmpl=$(_ac_hook_template_path "$template") || {
        ac_error "hook-install: unknown template '$template'"
        local tdir; tdir=$(dirname "${BASH_SOURCE[0]}")/../hooks/templates
        if [[ -d "$tdir" ]]; then
            ac_error "available: $(find "$tdir" -mindepth 1 -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
        fi
        return 1
    }

    # Default hook name = template prefix before the first dash-after-prefix.
    # pre-commit-secrets → pre-commit; pre-push-tests → pre-push;
    # commit-msg-format → commit-msg. Falls back to template name if no match.
    if [[ -z "$hook_name" ]]; then
        case "$template" in
            pre-commit-*) hook_name="pre-commit" ;;
            pre-push-*)   hook_name="pre-push" ;;
            commit-msg-*) hook_name="commit-msg" ;;
            post-commit-*) hook_name="post-commit" ;;
            *)            hook_name="$template" ;;
        esac
    fi

    local dir
    dir=$(ac_hooks_dir "$p") || return 1
    mkdir -p "$dir"
    local target="$dir/$hook_name"

    local rendered; rendered=$(_ac_hook_render "$tmpl" "$project")

    if [[ -f "$target" ]]; then
        local existing; existing=$(cat "$target")
        if [[ "$existing" == "$rendered" ]]; then
            ac_info "hook-install: $hook_name already matches '$template' — no-op"
            return 0
        fi
        if (( force == 0 )); then
            ac_error "hook-install: $hook_name exists and differs from template '$template'"
            ac_error "    pass --force to backup-then-overwrite (creates $target.bak.<ts>)"
            return 1
        fi
        local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
        cp -p "$target" "$target.bak.$ts"
        ac_info "hook-install: backed up existing $hook_name to $target.bak.$ts"
    fi

    printf '%s' "$rendered" > "$target"
    chmod +x "$target"
    ac_info "hook-install: installed '$template' as $hook_name in $dir"
    return 0
}
