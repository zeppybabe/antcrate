#!/usr/bin/env bash
# antcrate :: lib/backup.sh — mandatory backup before destructive ops
#
# Contract: NO removal, no overwrite-mv, no force-recreate happens
# until a successful backup tarball is written and verified.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_BACKUP_DIR:=$ANTCRATE_HOME/backups}"
: "${ANTCRATE_BACKUP_RETENTION:=20}"   # keep last N backups per project

# ac_backup_create <project> <path>  — tar.gz of <path>; prints backup file path on stdout
# Accepts either a directory or a single file. Both wrap as tar.gz so the
# backup format stays uniform for ac_safety_guard_destructive callers.
ac_backup_create() {
    local project="$1" path="$2"
    [[ -e "$path" ]] || { ac_error "backup: source missing: $path"; return 1; }

    local proj_dir="$ANTCRATE_BACKUP_DIR/$project"
    mkdir -p "$proj_dir"
    local ts; ts=$(date -u +"%Y%m%dT%H%M%SZ")
    local tarball="$proj_dir/${project}-${ts}.tar.gz"
    # collision suffix when two backups land in the same second
    local n=0
    while [[ -f "$tarball" ]]; do
        n=$((n + 1))
        tarball="$proj_dir/${project}-${ts}_${n}.tar.gz"
    done

    # tar from parent so the archive contains the project as a top-level dir
    local parent base
    parent=$(dirname "$path")
    base=$(basename "$path")
    if ! tar -C "$parent" -czf "$tarball" "$base" 2>/dev/null; then
        ac_error "backup: tar failed for $path"
        rm -f "$tarball"
        return 1
    fi

    # verify
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        ac_error "backup: verification failed for $tarball"
        rm -f "$tarball"
        return 1
    fi

    # write a sidecar manifest
    {
        printf 'project   : %s\n' "$project"
        printf 'source    : %s\n' "$path"
        printf 'timestamp : %s\n' "$ts"
        printf 'size      : %s bytes\n' "$(stat -c %s "$tarball" 2>/dev/null || stat -f %z "$tarball")"
        printf 'sha256    : %s\n' "$(sha256sum "$tarball" 2>/dev/null | awk '{print $1}')"
    } > "${tarball}.manifest"

    ac_info "backup: $tarball"
    ac_backup_prune "$project"
    printf '%s\n' "$tarball"
}

# ac_backup_prune <project> — keep only the N most recent
ac_backup_prune() {
    local project="$1"
    local proj_dir="$ANTCRATE_BACKUP_DIR/$project"
    [[ -d "$proj_dir" ]] || return 0
    local count; count=$(find "$proj_dir" -maxdepth 1 -name '*.tar.gz' -printf '.' | wc -c)
    (( count <= ANTCRATE_BACKUP_RETENTION )) && return 0
    local excess=$(( count - ANTCRATE_BACKUP_RETENTION ))
    find "$proj_dir" -maxdepth 1 -name '*.tar.gz' -printf '%T@ %p\n' \
        | sort -n | head -n "$excess" \
        | while read -r _ f; do
            rm -f "$f" "${f}.manifest"
            ac_debug "backup: pruned $f"
          done
}

# ac_backup_list <project>
ac_backup_list() {
    local project="$1"
    local proj_dir="$ANTCRATE_BACKUP_DIR/$project"
    [[ -d "$proj_dir" ]] || { ac_warn "no backups for $project"; return 0; }
    find "$proj_dir" -maxdepth 1 -name '*.tar.gz' | sort
}

# ac_backup_latest <project>  — prints path of most recent backup tarball
ac_backup_latest() {
    local project="$1"
    ac_backup_list "$project" | tail -n 1
}

# ac_backup_restore <project> [<tarball>]
# Restores the project tree from <tarball> (defaults to latest). Refuses to clobber
# a non-empty target unless ANTCRATE_RESTORE_OVERWRITE=1.
ac_backup_restore() {
    local project="$1" tarball="${2:-}"
    [[ -z "$tarball" ]] && tarball=$(ac_backup_latest "$project")
    [[ -z "$tarball" || ! -f "$tarball" ]] && { ac_error "restore: no backup found"; return 1; }

    if ! ac_registry_has "$project"; then
        ac_error "restore: unknown project '$project'"; return 1
    fi
    local target; target=$(ac_registry_get "$project" path)
    local parent; parent=$(dirname "$target")

    if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
        if [[ "${ANTCRATE_RESTORE_OVERWRITE:-0}" != "1" ]]; then
            ac_error "restore: target $target is non-empty. Set ANTCRATE_RESTORE_OVERWRITE=1 to clobber."
            return 1
        fi
        # safety-protected pre-restore backup of current state, then remove
        local pre; pre=$(ac_backup_create "$project" "$target") || return 1
        ac_warn "restore: existing tree backed up to $pre before restore"
        ac_safety_safe_rm "$target" || return 1
    fi

    mkdir -p "$parent"
    if ! tar -C "$parent" -xzf "$tarball"; then
        ac_error "restore: tar extract failed"
        return 1
    fi
    ac_info "restore: $project ← $tarball"
}

# ac_backup_run <project> <source-path> — fan 'project'-scope push to every
# enabled+available target; report per-target result. Non-zero only if EVERY
# scope-eligible target failed. Requires lib/targets.sh sourced.
ac_backup_run() {
    local project="$1" src="$2"
    local any=0 ok=0 name scopes
    while read -r name; do
        [[ -z "$name" ]] && continue
        scopes=$(ac_target_call "$name" scopes 2>/dev/null) || { ac_warn "backup: skip $name (no contract)"; continue; }
        [[ "$scopes" == *project* ]] || continue
        any=1
        if ! ac_target_call "$name" available 2>/dev/null; then
            printf '  %s : skip (unavailable)\n' "$name"; continue
        fi
        if ac_target_call "$name" push "$project" "$src" >/dev/null 2>&1; then
            printf '  %s : OK\n' "$name"; ok=1
        else
            printf '  %s : FAIL\n' "$name"
        fi
    done < <(ac_targets_enabled)
    (( any == 0 )) && { ac_error "backup: no project-scope target enabled"; return 1; }
    (( ok == 1 )) || { ac_error "backup: all targets failed"; return 1; }
    return 0
}

# ac_backup_restore_best <project> <dest-parent> — restore newest VERIFIED
# 'project'-scope snapshot across enabled targets, walked in priority order.
# (Wired into the CLI restore path in Phase 2, when a second target exists;
# Phase 1 keeps the safety-guarded ac_backup_restore for the local path.)
ac_backup_restore_best() {
    local project="$1" dest="$2" name id best_id="" best_name="" best_t=0 t
    while read -r name; do
        [[ -z "$name" ]] && continue
        ac_target_call "$name" available 2>/dev/null || continue
        while read -r id; do
            [[ -z "$id" ]] && continue
            ac_target_call "$name" verify "$project" "$id" 2>/dev/null || continue
            t=$(stat -c %Y "$id" 2>/dev/null || stat -f %m "$id" 2>/dev/null || echo 0)
            if (( t >= best_t )); then best_t=$t; best_id=$id; best_name=$name; fi
        done < <(ac_target_call "$name" list "$project" 2>/dev/null)
    done < <(ac_targets_enabled)
    [[ -z "$best_id" ]] && { ac_error "restore: no verified snapshot found"; return 1; }
    ac_target_call "$best_name" pull "$project" "$best_id" "$dest"
}
