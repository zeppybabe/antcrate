#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filter strings: $-vars are jq, not shell
# antcrate :: lib/devops.sh — developer-side wrappers
#
# Bundled commands that AntCrate (and Claude) rely on every day:
#   - --map       : addressed tree walk with dynamic/static classification
#   - --rename    : safe project rename (backup + approval)
#   - --archive   : safe move to ~/projects/.archive/<project>
#   - --logs      : tail per-component logs + conflict log
#   - --diff      : git status + diff via `git -C` (no cd)
#   - --selfsrc   : echo the antcrate skill source root
#   - --selfinstall : run install.sh from that root
#   - --selftest  : run bats tests/[<pattern>] from that root
#   - --selfedit  : echo absolute path to a file under selfsrc (for $EDITOR)
#
# Sourced by wrapper. Depends on registry.sh, safety.sh, backup.sh, address.sh.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_ROOT:=$HOME/projects}"
: "${ANTCRATE_ARCHIVE_DIR:=$ANTCRATE_ROOT/.archive}"
: "${ANTCRATE_SELFSRC:=$HOME/.claude/skills/antcrate/assets/code}"

# ---------- classification ----------

# Files matched by these patterns are considered "static" (set-once, rarely change).
# Everything else inside a project tree is "dynamic" by default.
AC_DEVOPS_STATIC_PATTERNS=(
    '^[.]env(\.|$)'
    '^[.]env\.[a-zA-Z0-9_-]+$'
    '^Dockerfile(\.|$)'
    '^docker-compose\.yml$'
    '^[.]dockerignore$'
    '^[.]gitignore$'
    '^[.]gitattributes$'
    '^[.]editorconfig$'
    '^[.]nvmrc$'
    '^[.]node-version$'
    '^[.]python-version$'
    '^[.]tool-versions$'
    '^LICENSE(\.|$)'
    '^package-lock\.json$'
    '^yarn\.lock$'
    '^pnpm-lock\.yaml$'
    '^bun\.lockb?$'
    '^Cargo\.lock$'
    '^Gemfile\.lock$'
    '^poetry\.lock$'
    '^uv\.lock$'
    '^composer\.lock$'
)

ac_devops_classify() {
    # ac_devops_classify <basename> -> "static" or "dynamic"
    local name="$1" pat
    for pat in "${AC_DEVOPS_STATIC_PATTERNS[@]}"; do
        if [[ "$name" =~ $pat ]]; then printf 'static'; return 0; fi
    done
    printf 'dynamic'
}

# ---------- map ----------

ac_devops_map() {
    local project="$1"
    if ! ac_registry_has "$project"; then
        ac_error "map: unknown project '$project'"; return 1
    fi
    local root; root=$(ac_registry_get "$project" path)
    [[ -d "$root" ]] || { ac_error "map: project path missing: $root"; return 1; }
    local d_count=0 s_count=0 addr rel base tag
    printf '\n  %s  %s\n' "$project" "$root"
    printf '  %s\n' "$(printf '%.s-' {1..60})"
    while IFS=$'\t' read -r addr rel; do
        base=$(basename "$rel")
        if [[ -d "$root/$rel" ]]; then
            tag=" "
        else
            tag=$(ac_devops_classify "$base")
            if [[ "$tag" == "dynamic" ]]; then d_count=$((d_count + 1)); tag="d"
            else s_count=$((s_count + 1)); tag="s"; fi
        fi
        printf '  %-8s [%s]  %s\n' "$addr" "$tag" "$rel"
    done < <(ac_addr_render_tree "$root")
    printf '\n  total: %d dynamic, %d static (directories shown without tag)\n\n' \
        "$d_count" "$s_count"
}

# ---------- rename ----------

ac_devops_rename() {
    local old="$1" new="$2"
    [[ -z "$old" || -z "$new" ]] && { ac_error "rename: requires <old> <new>"; return 2; }
    if ! ac_registry_has "$old"; then ac_error "rename: unknown project '$old'"; return 1; fi
    if ac_registry_has "$new"; then ac_error "rename: target name already registered: '$new'"; return 1; fi
    [[ "$new" =~ ^[a-zA-Z0-9._-]+$ ]] || { ac_error "rename: invalid name '$new' (alnum/._- only)"; return 2; }

    local oldpath; oldpath=$(ac_registry_get "$old" path)
    [[ -d "$oldpath" ]] || { ac_error "rename: source path missing: $oldpath"; return 1; }
    local parentdir; parentdir=$(dirname "$oldpath")
    local newpath="$parentdir/$new"
    [[ -e "$newpath" ]] && { ac_error "rename: target path already exists: $newpath"; return 1; }

    ac_safety_guard_destructive "$old" "rename to '$new'" "$oldpath" || return 1

    mv -- "$oldpath" "$newpath" || { ac_error "rename: mv failed"; return 1; }

    ac_registry_apply --arg o "$old" --arg n "$new" --arg p "$newpath" '
        .projects[$n] = (.projects[$o] // {})
        | .projects[$n].path = $p
        | del(.projects[$o])
        | .projects |= with_entries(
            .value.linked_nodes = ((.value.linked_nodes // []) | map(if . == $o then $n else . end))
            | (if .value.parent == $o then .value.parent = $n else . end)
          )
    ' || { ac_error "rename: registry update failed (project moved on disk!)"; return 1; }

    ac_info "rename: '$old' -> '$new' (path=$newpath, backup=$AC_LAST_BACKUP_PATH)"
}

# ---------- archive / unarchive ----------

ac_devops_archive() {
    local project="$1"
    [[ -z "$project" ]] && { ac_error "archive: requires <project>"; return 2; }
    if ! ac_registry_has "$project"; then ac_error "archive: unknown project '$project'"; return 1; fi
    local src; src=$(ac_registry_get "$project" path)
    [[ -d "$src" ]] || { ac_error "archive: project path missing: $src"; return 1; }
    local prev_parent; prev_parent=$(ac_registry_get "$project" parent)

    local dst="$ANTCRATE_ARCHIVE_DIR/$project"
    mkdir -p "$ANTCRATE_ARCHIVE_DIR"
    [[ -e "$dst" ]] && { ac_error "archive: target already exists: $dst"; return 1; }

    ac_safety_guard_destructive "$project" "archive" "$src" || return 1
    mv -- "$src" "$dst" || { ac_error "archive: mv failed"; return 1; }
    ac_registry_set_path "$project" "$dst"
    ac_registry_set_parent "$project" "_archived"
    ac_registry_apply --arg n "$project" --arg pp "$prev_parent" \
        '.projects[$n].previous_parent = $pp'
    ac_info "archive: '$project' moved to $dst (was parent='$prev_parent', backup=$AC_LAST_BACKUP_PATH)"
}

ac_devops_unarchive() {
    local project="$1"
    [[ -z "$project" ]] && { ac_error "unarchive: requires <project>"; return 2; }
    if ! ac_registry_has "$project"; then ac_error "unarchive: unknown project '$project'"; return 1; fi
    local src; src=$(ac_registry_get "$project" path)
    [[ -d "$src" ]] || { ac_error "unarchive: archived path missing: $src"; return 1; }
    case "$src" in
        "$ANTCRATE_ARCHIVE_DIR"/*) ;;
        *) ac_error "unarchive: project '$project' is not currently archived (path=$src)"; return 1 ;;
    esac

    local prev_parent; prev_parent=$(jq -r --arg n "$project" \
        '.projects[$n].previous_parent // ""' "$ANTCRATE_REGISTRY")
    if [[ -z "$prev_parent" ]]; then
        ac_error "unarchive: no previous_parent recorded for '$project' — restore manually with --rename or --resume"
        return 1
    fi
    local dst="$ANTCRATE_ROOT/$prev_parent/$project"
    [[ -e "$dst" ]] && { ac_error "unarchive: destination already exists: $dst"; return 1; }
    mkdir -p "$ANTCRATE_ROOT/$prev_parent"

    ac_safety_guard_destructive "$project" "unarchive" "$src" || return 1
    mv -- "$src" "$dst" || { ac_error "unarchive: mv failed"; return 1; }
    ac_registry_set_path "$project" "$dst"
    ac_registry_set_parent "$project" "$prev_parent"
    ac_registry_apply --arg n "$project" 'del(.projects[$n].previous_parent)'
    ac_info "unarchive: '$project' restored to $dst (parent='$prev_parent', backup=$AC_LAST_BACKUP_PATH)"
}

# ---------- remove (hard delete) ----------

ac_devops_remove() {
    local project="$1"
    [[ -z "$project" ]] && { ac_error "remove: requires <project>"; return 2; }
    if ! ac_registry_has "$project"; then ac_error "remove: unknown project '$project'"; return 1; fi
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "remove: project path missing: $p"; return 1; }

    printf '\n' >&2
    printf '  ====================================================\n' >&2
    printf '  PERMANENT DELETE: %s\n' "$project" >&2
    printf '  path: %s\n' "$p" >&2
    printf '  ====================================================\n' >&2
    printf '  The project files and registry entry will be removed.\n' >&2
    printf '  Recovery is only possible via the backup tarball below.\n' >&2
    printf '  Consider --archive instead if uncertain.\n\n' >&2

    ac_safety_guard_destructive "$project" "PERMANENT remove" "$p" || return 1

    rm -rf -- "$p" || { ac_error "remove: rm failed (registry NOT modified)"; return 1; }
    ac_registry_delete "$project"
    ac_info "remove: '$project' deleted from disk and registry (backup=$AC_LAST_BACKUP_PATH)"
    printf '\n  Recovery: antcrate --restore %s --at <ts>  (tarball: %s)\n\n' \
        "$project" "$AC_LAST_BACKUP_PATH" >&2
}

# ---------- touch / mkdir (file/dir creation through the wrapper) ----------

# Validate a relative path argument: no absolute, no .. traversal, no leading /.
_ac_devops_check_relpath() {
    local rel="$1"
    [[ -z "$rel" ]] && { ac_error "path: empty"; return 2; }
    [[ "${rel:0:1}" == "/" ]] && { ac_error "path: must be relative (got '$rel')"; return 2; }
    case "/$rel/" in
        */../*) ac_error "path: '..' traversal forbidden in '$rel'"; return 2 ;;
    esac
    return 0
}

ac_devops_touch() {
    local project="$1" rel="$2"
    [[ -z "$project" ]] && { ac_error "touch: requires <project>"; return 2; }
    _ac_devops_check_relpath "$rel" || return 2
    if ! ac_registry_has "$project"; then ac_error "touch: unknown project '$project'"; return 1; fi
    local root; root=$(ac_registry_get "$project" path)
    [[ -d "$root" ]] || { ac_error "touch: project path missing: $root"; return 1; }
    local full="$root/$rel"
    if [[ -e "$full" ]]; then
        ac_error "touch: refusing to overwrite existing entry: $full"
        return 1
    fi
    mkdir -p -- "$(dirname "$full")" || { ac_error "touch: mkdir parents failed"; return 1; }
    : > "$full" || { ac_error "touch: file creation failed"; return 1; }
    ac_info "touch: created $full"
    printf '%s\n' "$full"
}

ac_devops_mkdir() {
    local project="$1" rel="$2"
    [[ -z "$project" ]] && { ac_error "mkdir: requires <project>"; return 2; }
    _ac_devops_check_relpath "$rel" || return 2
    if ! ac_registry_has "$project"; then ac_error "mkdir: unknown project '$project'"; return 1; fi
    local root; root=$(ac_registry_get "$project" path)
    [[ -d "$root" ]] || { ac_error "mkdir: project path missing: $root"; return 1; }
    local full="$root/$rel"
    if [[ -e "$full" && ! -d "$full" ]]; then
        ac_error "mkdir: path exists but is not a directory: $full"
        return 1
    fi
    mkdir -p -- "$full" || { ac_error "mkdir: failed"; return 1; }
    ac_info "mkdir: ensured $full"
    printf '%s\n' "$full"
}

# ---------- logs ----------

ac_devops_logs() {
    local project="${1:-}" lines="${2:-50}"
    printf '\n=== /tmp/antcrate_conflict.log (last %d) ===\n' "$lines"
    [[ -f /tmp/antcrate_conflict.log ]] && tail -n "$lines" /tmp/antcrate_conflict.log || printf '(absent)\n'
    printf '\n=== %s/log/wrapper.log ===\n' "$ANTCRATE_HOME"
    [[ -f "$ANTCRATE_HOME/log/wrapper.log" ]] && tail -n "$lines" "$ANTCRATE_HOME/log/wrapper.log" || printf '(absent)\n'
    printf '\n=== %s/log/daemon.log ===\n' "$ANTCRATE_HOME"
    [[ -f "$ANTCRATE_HOME/log/daemon.log" ]] && tail -n "$lines" "$ANTCRATE_HOME/log/daemon.log" || printf '(absent)\n'
    if [[ -n "$project" ]] && ac_registry_has "$project"; then
        local p; p=$(ac_registry_get "$project" path)
        printf '\n=== git -C %s log -n 5 ===\n' "$p"
        git -C "$p" log --oneline -n 5 2>/dev/null || printf '(no git history)\n'
    fi
    printf '\n'
}

# ---------- diff ----------

ac_devops_diff() {
    local project="$1"
    [[ -z "$project" ]] && { ac_error "diff: requires <project>"; return 2; }
    if ! ac_registry_has "$project"; then ac_error "diff: unknown project '$project'"; return 1; fi
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p/.git" ]] || { ac_error "diff: not a git repo: $p"; return 1; }
    printf '\n=== %s :: status ===\n' "$project"
    git -C "$p" status --short
    printf '\n=== %s :: diff (working tree) ===\n' "$project"
    git -C "$p" --no-pager diff
}

# ---------- self-dev ----------

ac_devops_selfsrc() {
    if [[ ! -d "$ANTCRATE_SELFSRC" ]]; then
        ac_error "selfsrc: skill source not found at $ANTCRATE_SELFSRC"
        ac_error "selfsrc: set ANTCRATE_SELFSRC in $ANTCRATE_HOME/config"
        return 1
    fi
    printf '%s\n' "$ANTCRATE_SELFSRC"
}

ac_devops_selfinstall() {
    local src; src=$(ac_devops_selfsrc) || return 1
    [[ -x "$src/install.sh" ]] || { ac_error "selfinstall: $src/install.sh missing or not executable"; return 1; }
    ac_info "selfinstall: running $src/install.sh"
    bash "$src/install.sh"
}

ac_devops_install_from_source() {
    # Auto-fire after --commit lands on antcrate is a follow-up flag
    # (--commit-self-install or post-commit hook); ANTCRATE_SKIP_SELFINSTALL=1
    # ships with that, not now.
    if ! ac_registry_has antcrate; then
        ac_error "install-from-source: project 'antcrate' not registered. Run: antcrate --register antcrate <path-to-skill-source>"
        return 1
    fi
    local path; path=$(ac_registry_get antcrate path)
    # install.sh can live at the project root OR nested at assets/code/install.sh
    # (the skill layout has source code under assets/code/). Probe both.
    local installer=""
    for candidate in "$path/install.sh" "$path/assets/code/install.sh"; do
        if [[ -f "$candidate" ]]; then installer="$candidate"; break; fi
    done
    if [[ -z "$installer" ]]; then
        ac_error "install-from-source: install.sh not found at $path/install.sh or $path/assets/code/install.sh"
        return 1
    fi
    if [[ ! -x "$installer" ]]; then
        ac_error "install-from-source: $installer is not executable"
        return 1
    fi
    bash "$installer"
}

ac_devops_selftest() {
    local pattern="${1:-}" src
    src=$(ac_devops_selfsrc) || return 1
    if ! command -v bats >/dev/null 2>&1; then
        ac_error "selftest: 'bats' not on PATH (install bats-core: apt install bats)"
        return 1
    fi
    if [[ -z "$pattern" ]]; then
        ac_info "selftest: running all bats tests under $src/tests/"
        bats "$src/tests/"
    else
        local target="$src/tests/$pattern"
        [[ "$target" == *.bats ]] || target="${target}.bats"
        [[ -f "$target" ]] || { ac_error "selftest: no such file: $target"; return 1; }
        ac_info "selftest: running $target"
        bats "$target"
    fi
}

ac_devops_selfedit() {
    local rel="$1" src
    [[ -z "$rel" ]] && { ac_error "selfedit: requires <relpath> (e.g. lib/registry.sh)"; return 2; }
    src=$(ac_devops_selfsrc) || return 1
    local full="$src/$rel"
    [[ -e "$full" ]] || { ac_error "selfedit: not found: $full"; return 1; }
    printf '%s\n' "$full"
}

# ---------- ci shim ----------

ac_devops_ci() {
    local src; src=$(ac_devops_selfsrc) || return 1
    local rc=0
    printf '\n=== shellcheck ===\n'
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck -x "$src"/lib/*.sh "$src/bin/antcrate" "$src/bin/antcrated" "$src/install.sh"; then
            printf 'shellcheck: clean\n'
        else
            printf 'shellcheck: FAILED\n'
            rc=1
        fi
    else
        ac_warn "ci: shellcheck not on PATH — skipping"
    fi
    printf '\n=== antcrate-core (cmake/ctest) ===\n'
    if ! command -v cmake >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
        ac_warn "core: skip (cmake/g++ not found)"
    else
        local core_src="$src/core"
        local core_build="$src/core/build"
        if cmake -B "$core_build" -S "$core_src" -Wno-dev >/dev/null 2>&1 \
            && cmake --build "$core_build" --parallel >/dev/null 2>&1 \
            && ctest --test-dir "$core_build" --output-on-failure; then
            printf 'core: clean\n'
        else
            printf 'core: FAILED\n'
            rc=1
        fi
    fi
    printf '\n=== bats selftest ===\n'
    if command -v bats >/dev/null 2>&1; then
        if bats "$src/tests/"; then
            printf 'bats: all green\n'
        else
            printf 'bats: FAILED\n'
            rc=1
        fi
    else
        ac_warn "ci: bats not on PATH — skipping"
    fi
    printf '\n=== ci result: '
    if (( rc == 0 )); then printf 'PASS ===\n'; else printf 'FAIL ===\n'; fi
    return $rc
}
