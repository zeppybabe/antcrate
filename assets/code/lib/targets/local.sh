#!/usr/bin/env bash
# antcrate :: lib/targets/local.sh — local filesystem backup target.
# The original ~/.antcrate/backups store, now behind the target contract.
# Snapshot id == tarball path (as ac_backup_create/ac_backup_list emit).
# Requires lib/backup.sh to be sourced first.

target_local_scopes()    { printf 'project\n'; }
target_local_available() { return 0; }

# push <project> <source-path> -> echoes snapshot id (tarball path)
target_local_push() { ac_backup_create "$1" "$2"; }

# list <project> -> snapshot ids, oldest-first (ac_backup_list sorts ascending)
target_local_list() { ac_backup_list "$1"; }

# pull <project> <id> <dest-parent> -> extract tarball under <dest-parent>
target_local_pull() {
    local id="$2" dest="$3"
    [[ -f "$id" ]] || { ac_error "local: snapshot not found: $id"; return 1; }
    mkdir -p "$dest"
    tar -C "$dest" -xzf "$id"
}

# verify <project> <id> -> 0 if the tarball is intact
target_local_verify() {
    local id="$2"
    [[ -f "$id" ]] && tar -tzf "$id" >/dev/null 2>&1
}
