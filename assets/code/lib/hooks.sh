#!/usr/bin/env bash
# antcrate :: lib/hooks.sh — read-only inspection of git hooks for a project.
#
# Today's surface (small, read-only):
#   ac_hooks_list <project>      — list active hooks + which dir is in use
#   ac_hooks_log  <project> [N]  — tail .git/antcrate-hook.log (default 50)
#
# Larger queued surface (see assets/docs/HOOK_PLAN.md):
#   --hook-install / --hook-remove / --hook-bypass / hook templates
# These are NOT implemented yet — install/remove/bypass require AGENTS.md
# rule-#1 + rule-#12 integration which is best done as a focused next pass.
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
