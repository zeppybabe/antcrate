#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq filter strings: $-vars are jq, not shell
# antcrate :: lib/cleanup.sh — per-project cleanup classifier + apply
#
# Lists candidates for removal (test caches, build temp dirs, empty dirs)
# without touching disk; --apply runs each removal through the AGENTS.md
# rule #1 backup + approval gate (`ac_safety_guard_destructive`) and emits
# a `delete` event so lib/watch.sh can paint a 1s tombstone.
#
# Categories detected (v1):
#   test-tmp   — known test/cache/coverage directories + temp file patterns
#   empty-dir  — directories with zero entries (excluding .git, .github, .githooks)
#
# Build-output and gitignored-on-disk are intentionally omitted from v1.
# .gitignore can include sensitive files (.env, secrets) that must NEVER
# be auto-suggested for deletion. A separate, explicit pattern set lands
# only when the producer-side flow needs it.
#
# Public API (callable from the wrapper):
#   ac_cleanup_classify <project>            — refresh list, print table
#   ac_cleanup_apply <project> <id> [<id>...] — gated removal per ID
#   ac_cleanup_list_path <project>            — abs path to persisted list
#
# Internal (do not call from outside this file):
#   ac_cleanup_scan_test_tmp, ac_cleanup_scan_empty_dirs,
#   ac_cleanup_resolve_id, ac_cleanup_record_removal,
#   ac_cleanup_human_size
# Reason: scanners produce raw rows that ac_cleanup_classify dedupes,
# numbers, and persists; calling them directly bypasses that contract.
# ac_cleanup_record_removal mutates registry.recent_removals and must be
# called only after a successful guarded removal.

# compat.sh self-source: shims used below; guard makes re-sourcing free
# (bats tests source libs directly, without the wrapper preamble).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
: "${ANTCRATE_CLEANUP_DIR:=$ANTCRATE_HOME/cleanup}"
: "${ANTCRATE_CLEANUP_MAX_DEPTH:=6}"
: "${ANTCRATE_CLEANUP_RECENT_CAP:=50}"

# Test-tmp directory names (exact basename match)
AC_CLEANUP_TEST_DIRS=(
    __pycache__ .pytest_cache .mypy_cache .tox .cache
    .turbo .nyc_output coverage .next/cache
)
# Test-tmp file patterns (glob, leaf basename)
AC_CLEANUP_TEST_FILES=(
    "*.test.tmp" "*.pyc" "*.bats.log"
)
# Directories never traversed (cleanup leaves them alone)
AC_CLEANUP_SKIP_DIRS=( .git .github .githooks node_modules )

ac_cleanup_list_path() {
    local project="$1"
    printf '%s/%s.list\n' "$ANTCRATE_CLEANUP_DIR" "$project"
}

ac_cleanup_human_size() {
    # Convert bytes (stdin) to human-readable. POSIX-portable: numfmt isn't
    # universal so we open-code it.
    local n="$1" units=(B K M G T) i=0
    while (( n >= 1024 && i < 4 )); do n=$(( n / 1024 )); i=$(( i + 1 )); done
    printf '%d%s' "$n" "${units[$i]}"
}

ac_cleanup_scan_test_tmp() {
    # ac_cleanup_scan_test_tmp <root>
    # Emits: <category>\t<size_bytes>\t<mtime_iso>\t<abs_path>
    local root="$1"
    # prune by basename so .git / node_modules etc. are skipped at any depth
    local skip_args=()
    local d
    for d in "${AC_CLEANUP_SKIP_DIRS[@]}"; do
        skip_args+=( -name "$d" -prune -o )
    done
    # directory matches by exact basename
    local dpat=()
    local pat
    for pat in "${AC_CLEANUP_TEST_DIRS[@]}"; do
        dpat+=( -name "$pat" -o )
    done
    if (( ${#dpat[@]} > 0 )); then
        unset 'dpat[${#dpat[@]}-1]'   # drop trailing -o
    fi
    # find dirs
    if (( ${#dpat[@]} > 0 )); then
        find "$root" -maxdepth "$ANTCRATE_CLEANUP_MAX_DEPTH" \
            "${skip_args[@]}" \( -type d \( "${dpat[@]}" \) \) -print 2>/dev/null \
            | while IFS= read -r p; do
                [[ -d "$p" ]] || continue
                local size mtime
                size=$(ac_du_bytes "$p")
                mtime=$(ac_stat_mtime "$p" 2>/dev/null)
                printf 'test-tmp\t%s\t%s\t%s\n' "${size:-0}" "${mtime:-0}" "$p"
            done
    fi
    # find files matching file patterns
    local fpat=()
    for pat in "${AC_CLEANUP_TEST_FILES[@]}"; do
        fpat+=( -name "$pat" -o )
    done
    if (( ${#fpat[@]} > 0 )); then
        unset 'fpat[${#fpat[@]}-1]'
        find "$root" -maxdepth "$ANTCRATE_CLEANUP_MAX_DEPTH" \
            "${skip_args[@]}" \( -type f \( "${fpat[@]}" \) \) -print 2>/dev/null \
            | while IFS= read -r p; do
                [[ -f "$p" ]] || continue
                local size mtime
                size=$(ac_stat_size "$p" 2>/dev/null)
                mtime=$(ac_stat_mtime "$p" 2>/dev/null)
                printf 'test-tmp\t%s\t%s\t%s\n' "${size:-0}" "${mtime:-0}" "$p"
            done
    fi
}

ac_cleanup_scan_empty_dirs() {
    local root="$1"
    local skip_args=()
    local d
    for d in "${AC_CLEANUP_SKIP_DIRS[@]}"; do
        skip_args+=( -name "$d" -prune -o )
    done
    find "$root" -mindepth 1 -maxdepth "$ANTCRATE_CLEANUP_MAX_DEPTH" \
        "${skip_args[@]}" \( -type d -empty \) -print 2>/dev/null \
        | while IFS= read -r p; do
            [[ -d "$p" ]] || continue
            local mtime; mtime=$(ac_stat_mtime "$p" 2>/dev/null)
            printf 'empty-dir\t0\t%s\t%s\n' "${mtime:-0}" "$p"
        done
}

ac_cleanup_classify() {
    # ac_cleanup_classify <project>
    # Persists numbered list at $ANTCRATE_CLEANUP_DIR/<project>.list and
    # prints a human-readable table. ID numbers are stable until the next
    # classify call.
    local project="$1"
    if ! ac_registry_has "$project"; then
        ac_error "cleanup: unknown project '$project'"
        return 1
    fi
    local root; root=$(ac_registry_get "$project" path)
    [[ -d "$root" ]] || { ac_error "cleanup: project path missing: $root"; return 1; }

    mkdir -p "$ANTCRATE_CLEANUP_DIR"
    local out; out=$(ac_cleanup_list_path "$project")
    local tmp; tmp=$(mktemp "${out}.XXXXXX")

    {
        ac_cleanup_scan_test_tmp "$root"
        ac_cleanup_scan_empty_dirs "$root"
    } | sort -u | awk -v OFS='\t' '
        { printf "%d\t%s\t%s\t%s\t%s\n", NR, $1, $2, $3, $4 }
    ' > "$tmp"
    mv "$tmp" "$out"

    # Render
    if [[ ! -s "$out" ]]; then
        printf 'No cleanup candidates for %s.\n' "$project"
        return 0
    fi
    printf '%-4s  %-12s  %-8s  %-20s  %s\n' "ID" "CATEGORY" "SIZE" "MTIME" "PATH"
    printf '%-4s  %-12s  %-8s  %-20s  %s\n' "----" "------------" "--------" "--------------------" "----"
    while IFS=$'\t' read -r id category size mtime path; do
        local hsize iso
        hsize=$(ac_cleanup_human_size "${size:-0}")
        iso=$(ac_date_from_epoch "${mtime:-0}" 2>/dev/null || echo "?")
        local rel="${path#"$root"/}"
        printf '%-4s  %-12s  %-8s  %-20s  %s\n' "$id" "$category" "$hsize" "$iso" "$rel"
    done < "$out"
}

ac_cleanup_resolve_id() {
    # ac_cleanup_resolve_id <project> <id>  — emits "<category>\t<abs_path>"
    local project="$1" id="$2"
    local list; list=$(ac_cleanup_list_path "$project")
    [[ -f "$list" ]] || { ac_error "cleanup: no list found; run --cleanup $project first"; return 1; }
    awk -v id="$id" -F'\t' '$1 == id { print $2"\t"$5; found=1 } END{ if(!found) exit 1 }' "$list"
}

ac_cleanup_record_removal() {
    # ac_cleanup_record_removal <project> <category> <relpath> <agent>
    # Appends to projects.<name>.recent_removals (capped at the cap).
    local project="$1" category="$2" relpath="$3" agent="$4"
    local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    ac_registry_apply \
        --arg n "$project" --arg ts "$ts" --arg cat "$category" \
        --arg path "$relpath" --arg agent "$agent" \
        --argjson cap "$ANTCRATE_CLEANUP_RECENT_CAP" \
        '.projects[$n].recent_removals =
            (((.projects[$n].recent_removals // []) +
              [{ts:$ts, label:$cat, path:$path, by:$agent}])
             | (if length > $cap then .[length-$cap:] else . end))'
}

ac_cleanup_apply() {
    # ac_cleanup_apply <project> <id> [<id>...]
    # Each ID is gated through ac_safety_guard_destructive (rule #1).
    # On success, removes the path, emits a delete event with the category
    # as the label, and records the removal in registry.recent_removals.
    local project="$1"; shift
    if ! ac_registry_has "$project"; then
        ac_error "cleanup: unknown project '$project'"
        return 1
    fi
    local root; root=$(ac_registry_get "$project" path)

    local id_arg
    for id_arg in "$@"; do
        # parse "1,3,5" too
        local ids; IFS=',' read -r -a ids <<< "$id_arg"
        local id
        for id in "${ids[@]}"; do
            [[ -z "$id" ]] && continue
            local row
            if ! row=$(ac_cleanup_resolve_id "$project" "$id"); then
                ac_error "cleanup: id '$id' not in current list"
                return 1
            fi
            local category path
            category=$(printf '%s' "$row" | cut -f1)
            path=$(printf '%s' "$row" | cut -f2)
            local rel="${path#"$root"/}"

            if ! ac_safety_guard_destructive "$project" "cleanup-$category" "$path"; then
                ac_error "cleanup: id $id refused (rule #1 gate)"
                return 1
            fi
            _ac_quarantine_capture "$project" "$path" "cleanup-$category" "$rel"
            ac_info "cleanup: quarantined id=$id $category $rel (backup at $AC_LAST_BACKUP_PATH)"

            # tombstone event
            if declare -f ac_events_emit >/dev/null 2>&1; then
                ac_events_emit "$project" delete "$rel" --label "$category" \
                    --agent "${ANTCRATE_AGENT:-clyde}" || true
            fi
            ac_cleanup_record_removal "$project" "$category" "$rel" "${ANTCRATE_AGENT:-clyde}"
        done
    done
}
