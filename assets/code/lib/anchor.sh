#!/usr/bin/env bash
# antcrate :: lib/anchor.sh — directory anchor + --in runner
#
# Eliminates `cd <project> && do-thing && cd <other>` patterns. The anchor is a
# resolved absolute path (project root, or a sub-path via the address scheme).
# Two ways to consume it:
#
#   eval "$(antcrate --anchor randomize)"
#       → exports ANTCRATE_ANCHOR + ANTCRATE_ANCHOR_NAME [+ ANTCRATE_ANCHOR_ADDR]
#         in the calling shell.
#
#   antcrate --in randomize -- bun test
#       → runs the command with cwd = anchor, no shell-state pollution.
#
# Sourced by wrapper. Depends on registry.sh + address.sh + log.sh.

# ac_anchor_path <project> [addr] — print absolute path of anchor
ac_anchor_path() {
    local project="$1" addr="${2:-}"
    if ! ac_registry_has "$project"; then
        ac_error "anchor: unknown project '$project'"
        return 1
    fi
    local root; root=$(ac_registry_get "$project" path)
    [[ -d "$root" ]] || { ac_error "anchor: project path missing: $root"; return 1; }
    if [[ -z "$addr" ]]; then
        printf '%s\n' "$root"
    else
        ac_addr_resolve "$root" "$addr" || return 1
    fi
}

# ac_anchor_export <project> [addr] — emit eval-able export lines on stdout.
# Adds ANTCRATE_ANCHOR_FILE when the resolved target is a file (parent becomes
# the anchor; basename goes into ANTCRATE_ANCHOR_FILE).
ac_anchor_export() {
    local project="$1" addr="${2:-}"
    local p; p=$(ac_anchor_path "$project" "$addr") || return 1
    local anchor_dir anchor_file=""
    if [[ -d "$p" ]]; then
        anchor_dir="$p"
    else
        anchor_dir=$(dirname "$p")
        anchor_file=$(basename "$p")
    fi
    printf 'export ANTCRATE_ANCHOR=%q\n' "$anchor_dir"
    printf 'export ANTCRATE_ANCHOR_NAME=%q\n' "$project"
    [[ -n "$addr" ]] && printf 'export ANTCRATE_ANCHOR_ADDR=%q\n' "$addr"
    if [[ -n "$anchor_file" ]]; then
        printf 'export ANTCRATE_ANCHOR_FILE=%q\n' "$anchor_file"
    else
        printf 'unset ANTCRATE_ANCHOR_FILE\n'
    fi
    # shellcheck disable=SC2016  # the $( ... ) in this comment is meant to be literal
    printf '# consume: eval "$(antcrate --anchor %s%s)"\n' \
        "$project" "${addr:+ --addr $addr}"
}

# ac_anchor_run <project> <addr-or-empty> -- <cmd...> — exec cmd inside anchor
ac_anchor_run() {
    local project="$1" addr="$2"; shift 2
    if [[ "${1:-}" == "--" ]]; then shift; fi
    if (( $# == 0 )); then
        ac_error "anchor: --in requires a command after --"
        return 2
    fi
    local p; p=$(ac_anchor_path "$project" "$addr") || return 1
    local cwd="$p" file=""
    if [[ ! -d "$p" ]]; then
        cwd=$(dirname "$p")
        file=$(basename "$p")
    fi
    ac_info "anchor: cd=$cwd${file:+ file=$file} cmd=$*"
    (
        cd "$cwd" || exit 1
        export ANTCRATE_ANCHOR="$cwd"
        export ANTCRATE_ANCHOR_NAME="$project"
        [[ -n "$addr" ]] && export ANTCRATE_ANCHOR_ADDR="$addr"
        [[ -n "$file" ]] && export ANTCRATE_ANCHOR_FILE="$file"
        exec "$@"
    )
}
