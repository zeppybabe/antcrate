#!/usr/bin/env bash
# shellcheck disable=SC2034  # AC_META_* are consumed by scaffold.sh after decode
# antcrate :: lib/schema.sh — positional filename decoder
#
# Schema: <Name>.<Domain>.<Action>.<Meta>
#   Index 0 = Name   (literal project/file title)
#   Index 1 = Domain (target routing directory / category)
#   Index 2 = Action (start | branch | link | rel)
#   Index 3 = Meta   (optional: #csv,values# or key=value)
#
# Exports on success:
#   AC_NAME AC_DOMAIN AC_ACTION AC_META AC_META_TYPE AC_META_VALUES[@]
#
# Exit codes:
#   0 = decoded successfully
#   1 = filename does not match schema (skip silently)
#   2 = decoded but action is not recognized (warn)

ac_schema_reset() {
    AC_NAME=""; AC_DOMAIN=""; AC_ACTION=""; AC_META=""
    AC_META_TYPE=""           # "csv" | "kv" | ""
    AC_META_VALUES=()
    AC_META_KEY=""; AC_META_VAL=""
}

ac_schema_decode() {
    # ac_schema_decode <basename>
    ac_schema_reset
    local fname="$1"

    # ignore swap/backup/hidden files
    case "$fname" in
        .*|*~|*.swp|*.swo|*.swx|*.tmp) return 1 ;;
    esac

    # split on '.'
    IFS='.' read -r -a parts <<< "$fname"
    local n=${#parts[@]}
    (( n < 3 )) && return 1

    AC_NAME="${parts[0]}"
    AC_DOMAIN="${parts[1]}"
    AC_ACTION="${parts[2]}"
    if (( n >= 4 )); then
        # rejoin remaining segments in case meta itself contained a '.'
        local meta="${parts[3]}"
        local i
        for (( i=4; i<n; i++ )); do meta="${meta}.${parts[i]}"; done
        AC_META="$meta"
    fi

    # guard against empty fields
    [[ -z "$AC_NAME" || -z "$AC_DOMAIN" || -z "$AC_ACTION" ]] && return 1

    # validate action
    case "$AC_ACTION" in
        start|branch|link|rel) ;;
        *) return 2 ;;
    esac

    # parse meta
    if [[ -n "$AC_META" ]]; then
        if [[ "$AC_META" =~ ^#(.*)#$ ]]; then
            AC_META_TYPE="csv"
            local csv="${BASH_REMATCH[1]}"
            IFS=',' read -r -a AC_META_VALUES <<< "$csv"
        elif [[ "$AC_META" == *=* ]]; then
            AC_META_TYPE="kv"
            AC_META_KEY="${AC_META%%=*}"
            AC_META_VAL="${AC_META#*=}"
        else
            # bare meta — treat as single-value csv
            AC_META_TYPE="csv"
            AC_META_VALUES=("$AC_META")
        fi
    fi
    return 0
}

# stable cli encoding for logging / dry-run
ac_schema_describe() {
    printf 'name=%s domain=%s action=%s meta=%s meta_type=%s\n' \
        "$AC_NAME" "$AC_DOMAIN" "$AC_ACTION" "$AC_META" "$AC_META_TYPE"
}
