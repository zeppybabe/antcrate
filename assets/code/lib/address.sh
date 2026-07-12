#!/usr/bin/env bash
# antcrate :: lib/address.sh — layered positional address scheme
#
# An address is a string like `1a3` that uniquely identifies a file or directory
# inside a project tree. Depth alternates between numeric and alphabetic segments:
#
#   depth 1 = digits   (1-indexed integer)
#   depth 2 = letters  (bijective base-26: a=1, z=26, aa=27, ab=28, ba=53)
#   depth 3 = digits
#   depth 4 = letters
#   ...
#
# At each depth, directory entries are listed in lexicographic order (LC_ALL=C)
# and the segment selects the Nth entry (1-indexed) regardless of file/dir.
#
# Hidden entries (starting with .) and noisy build dirs are filtered (see
# AC_ADDR_SKIP_PATTERN). Override with ANTCRATE_ADDR_INCLUDE_HIDDEN=1.
#
# Sourced by anchor.sh, devops.sh. No side effects on source.

# compat.sh self-source: shims used below; guard makes re-sourcing free
# (bats tests source libs directly, without the wrapper preamble).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

: "${ANTCRATE_ADDR_INCLUDE_HIDDEN:=0}"
AC_ADDR_SKIP_PATTERN='^([.]git|node_modules|[.]svelte-kit|target|dist|build|__pycache__|[.]next|[.]cache)$'

# ac_addr_letters_to_int <letters> — bijective base-26 ("a"->1, "aa"->27)
ac_addr_letters_to_int() {
    local s="$1" n=0 i ch code
    for (( i=0; i<${#s}; i++ )); do
        ch="${s:i:1}"
        case "$ch" in
            [a-z]) ;;
            *) return 2 ;;
        esac
        printf -v code '%d' "'$ch"
        n=$(( n * 26 + (code - 96) ))
    done
    printf '%d' "$n"
}

# ac_addr_int_to_letters <int> — inverse of above
ac_addr_int_to_letters() {
    local n="$1" s="" rem ch
    if (( n < 1 )); then return 2; fi
    local letters=abcdefghijklmnopqrstuvwxyz
    while (( n > 0 )); do
        n=$(( n - 1 ))
        rem=$(( n % 26 ))
        ch="${letters:rem:1}"
        s="${ch}${s}"
        n=$(( n / 26 ))
    done
    printf '%s' "$s"
}

# ac_addr_decode <address> — emit one index per line; expected-type alternates
# starting with "num" at depth 1. Errors on malformed input.
ac_addr_decode() {
    local addr="$1"
    [[ -z "$addr" ]] && { ac_error "address: empty"; return 2; }
    local i=0 expect="num" buf="" ch
    while (( i < ${#addr} )); do
        ch="${addr:i:1}"
        case "$ch" in
            [0-9])
                if [[ "$expect" != "num" ]]; then
                    [[ -n "$buf" ]] && { _ac_addr_emit "$expect" "$buf"; }
                    expect="num"; buf="$ch"
                else
                    buf+="$ch"
                fi ;;
            [a-z])
                if [[ "$expect" != "alpha" ]]; then
                    [[ -n "$buf" ]] && { _ac_addr_emit "$expect" "$buf"; }
                    expect="alpha"; buf="$ch"
                else
                    buf+="$ch"
                fi ;;
            *)
                ac_error "address: invalid char '$ch' in '$addr'"; return 2 ;;
        esac
        i=$((i + 1))
    done
    [[ -n "$buf" ]] && _ac_addr_emit "$expect" "$buf"
}

_ac_addr_emit() {
    local kind="$1" raw="$2"
    if [[ "$kind" == "num" ]]; then
        # strip leading zeros but keep at least one digit
        raw="${raw##+(0)}"
        [[ -z "$raw" ]] && raw=0
        if (( raw < 1 )); then ac_error "address: zero/negative segment"; return 2; fi
        printf '%d\n' "$raw"
    else
        ac_addr_letters_to_int "$raw" || return 2
        printf '\n'
    fi
}

# ac_addr_list_dir <dir> — print sorted, filtered entries (one per line)
ac_addr_list_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || { ac_error "address: not a directory: $dir"; return 1; }
    local include_hidden="$ANTCRATE_ADDR_INCLUDE_HIDDEN"
    # shellcheck disable=SC2012  # `ls -1A` here is fed through awk; project-tree filenames are trusted
    LC_ALL=C ls -1A "$dir" 2>/dev/null | awk -v inc="$include_hidden" -v skip="$AC_ADDR_SKIP_PATTERN" '
        {
            if (inc != "1" && substr($0, 1, 1) == ".") next
            if ($0 ~ skip) next
            print
        }
    '
}

# ac_addr_resolve <root> <address> — print absolute path of resolved entry
ac_addr_resolve() {
    local root="$1" addr="$2"
    root=$(ac_realpath_m "$root")
    [[ -d "$root" ]] || { ac_error "address: project root missing: $root"; return 1; }

    # depth-aware decode (we need both expected-type and value per segment)
    local cur="$root" depth=0 idx entry count picked
    local indices=()
    while IFS= read -r idx; do
        indices+=( "$idx" )
    done < <(ac_addr_decode "$addr")
    (( ${#indices[@]} )) || return 2

    for idx in "${indices[@]}"; do
        depth=$(( depth + 1 ))
        if [[ ! -d "$cur" ]]; then
            ac_error "address: cannot descend; '$cur' is a file (segment $depth of '$addr')"
            return 1
        fi
        count=0; picked=""
        while IFS= read -r entry; do
            count=$((count + 1))
            if (( count == idx )); then
                picked="$entry"
                break
            fi
        done < <(ac_addr_list_dir "$cur")
        if [[ -z "$picked" ]]; then
            ac_error "address: index $idx out of range at depth $depth in '$cur' (only $count entries)"
            return 1
        fi
        cur="$cur/$picked"
    done
    printf '%s\n' "$cur"
}

# ac_addr_render_tree <root> [depth] — print every entry with its address.
# Stdout columns: <address>  <relpath>
ac_addr_render_tree() {
    local root="$1"
    root=$(ac_realpath_m "$root")
    _ac_addr_walk "$root" "$root" "" 1
}

_ac_addr_walk() {
    local root="$1" cur="$2" prefix="$3" depth="$4"
    local i=0 entry seg
    while IFS= read -r entry; do
        i=$((i + 1))
        if (( depth % 2 == 1 )); then
            seg="$i"
        else
            seg=$(ac_addr_int_to_letters "$i")
        fi
        local addr="${prefix}${seg}"
        local full="$cur/$entry"
        local rel="${full#"$root"/}"
        printf '%s\t%s\n' "$addr" "$rel"
        if [[ -d "$full" ]]; then
            _ac_addr_walk "$root" "$full" "$addr" $((depth + 1))
        fi
    done < <(ac_addr_list_dir "$cur")
}
