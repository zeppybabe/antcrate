#!/usr/bin/env bash
# lib/quarantine.sh — user-data destruction surface. All user-data rm sites
# route through _ac_quarantine_capture; the captured tree is archived + moved
# to ~/.antcrate/quarantine/<project>/<UTC-ts>__<op>__<sanitized-label>/.
# Only the user deletes the quarantine root. See AGENTS.md rule #16.

: "${ANTCRATE_HOME:=$HOME/.antcrate}"
_AC_UNLINK_ABS_HOME=""

# _ac_quarantine_sanitize_label <label>  — replace non-alnum/._- with -
_ac_quarantine_sanitize_label() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

# _ac_quarantine_capture <project> <src> <op> <label>
# Relocates user data to quarantine instead of deleting it.
# Returns non-zero + leaves no partial dir if src missing or mv/tar fails.
_ac_quarantine_capture() {
    local project="$1" src="$2" op="$3" label="$4"

    if [[ ! -e "$src" ]]; then
        ac_error "quarantine: source does not exist: $src"
        return 1
    fi

    local sane_label; sane_label=$(_ac_quarantine_sanitize_label "$label")
    local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
    local qdir="$ANTCRATE_HOME/quarantine/$project/${ts}__${op}__${sane_label}"

    mkdir -p "$qdir"

    if ! mv "$src" "$qdir/payload"; then
        ac_error "quarantine: mv failed for $src"
        rm -rf -- "$qdir"
        return 1
    fi

    if ! tar czf "$qdir/payload.tar.gz" -C "$qdir" payload; then
        ac_error "quarantine: tar failed for $src"
        if ! mv "$qdir/payload" "$src"; then
            ac_error "quarantine: rollback mv also failed — data stranded at $qdir/payload"
        fi
        rm -rf -- "$qdir"
        return 1
    fi

    _ac_unlink_internal "$qdir/payload"

    local sha; sha=$(sha256sum "$qdir/payload.tar.gz" | awk '{print $1}')

    jq -n \
        --arg ts "$ts" \
        --arg project "$project" \
        --arg op "$op" \
        --arg label "$label" \
        --arg original_path "$src" \
        --arg sha256 "$sha" \
        --arg captured_by "quarantine-capture" \
        '{ts:$ts, project:$project, op:$op, label:$label,
          original_path:$original_path, sha256:$sha256,
          captured_by:$captured_by}' > "$qdir/manifest.json"

    return 0
}

# _ac_unlink_internal <path>
# THE ONLY audited rm $VAR site post-pivot.
# Allowed zones: under $ANTCRATE_HOME, or .git-resident AntCrate artifacts
# (antcrate-hook-bypass inside a *.git/ directory).
_ac_unlink_internal() {
    local path="$1"
    [[ -z "$path" ]] && { ac_error "unlink_internal: empty path refused"; return 1; }
    if [[ -z "$_AC_UNLINK_ABS_HOME" ]]; then
        _AC_UNLINK_ABS_HOME=$(realpath -m "$ANTCRATE_HOME") \
            || { ac_error "unlink_internal: cannot resolve ANTCRATE_HOME"; return 1; }
    fi
    local abs_path; abs_path=$(realpath -m "$path") \
        || { ac_error "unlink_internal: cannot resolve path: $path"; return 1; }

    case "$abs_path" in
        "$_AC_UNLINK_ABS_HOME"|"$_AC_UNLINK_ABS_HOME"/*) rm -rf -- "$path"; return 0 ;;
    esac

    case "${abs_path##*/}" in
        antcrate-hook-bypass)
            [[ "$abs_path" == */.git/* ]] && { rm -rf -- "$path"; return 0; } ;;
    esac

    ac_error "unlink_internal: refusing to remove path outside ANTCRATE_HOME: $path"
    return 1
}

# ac_quarantine_list <project>
# List quarantine entries for a project, sorted DESC by timestamp.
ac_quarantine_list() {
    local project="$1"
    local qbase="$ANTCRATE_HOME/quarantine/$project"

    local header_printed=0
    local dir
    while IFS= read -r dir; do
        [[ -f "$dir/manifest.json" ]] || continue
        if [[ "$header_printed" -eq 0 ]]; then
            printf '%-22s  %-20s  %-20s  %s\n' "TIMESTAMP" "OP" "LABEL" "ORIGINAL_PATH"
            printf '%-22s  %-20s  %-20s  %s\n' "----------------------" "--------------------" "--------------------" "----"
            header_printed=1
        fi
        local ts op label orig
        IFS=$'\t' read -r ts op label orig < <(
            jq -r '[.ts, .op, .label, .original_path] | @tsv' "$dir/manifest.json"
        )
        printf '%-22s  %-20s  %-20s  %s\n' "$ts" "$op" "$label" "$orig"
    done < <(find "$qbase" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r)

    if [[ "$header_printed" -eq 0 ]]; then
        printf 'No quarantine entries for project: %s\n' "$project"
    fi
}

# ac_quarantine_restore <project> <ts>
# Find the quarantine entry whose dir starts with <ts>, read original_path
# from manifest, extract tarball and mv payload back to original_path.
# Refuses (exit 1) if original_path already exists.
ac_quarantine_restore() {
    local project="$1" ts="$2"
    local qbase="$ANTCRATE_HOME/quarantine/$project"

    local qdir
    qdir=$(find "$qbase" -maxdepth 1 -mindepth 1 -type d -name "${ts}*" 2>/dev/null | head -n1)

    if [[ -z "$qdir" ]]; then
        ac_error "quarantine: no entry found for project='$project' ts='$ts'"
        return 1
    fi

    local manifest="$qdir/manifest.json"
    [[ -f "$manifest" ]] || { ac_error "quarantine: manifest missing in $qdir"; return 1; }

    local orig; orig=$(jq -r '.original_path' "$manifest")

    if [[ -e "$orig" ]]; then
        ac_error "quarantine: restore refused — original_path already exists: $orig"
        return 1
    fi

    local tarball="$qdir/payload.tar.gz"
    [[ -f "$tarball" ]] || { ac_error "quarantine: tarball missing: $tarball"; return 1; }

    tar xzf "$tarball" -C "$qdir"
    mv "$qdir/payload" "$orig"

    ac_info "quarantine: restored '$orig' from $qdir"
}
