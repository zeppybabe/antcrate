#!/usr/bin/env bash
# antcrate :: lib/compat.sh — GNU/BSD userland portability shims
#
# Single home for every place the GNU (Linux) and BSD (macOS) userlands
# diverge: stat formats, sed -i, sha256, epoch date math, find -printf,
# realpath -m, cp -rT, du -b, mktemp templates. Each shim capability-probes
# once at source time (never per call) and takes the GNU fast path when
# available, so behavior on Linux is bit-identical to the pre-compat code.
# Probing by capability rather than by OS keeps macOS-with-coreutils and
# other BSDs working for free; AC_OS exists for the few places that need
# a platform decision (package hints, launchd vs systemd).
#
# Sourced by bin/antcrate and bin/antcrated right after paths.sh, and
# self-sourced (idempotent) by any lib that calls a shim, because bats
# tests source individual libs directly.
#
# Public API (callable from the wrapper, daemon, installer, or other libs):
#   AC_OS                               — "darwin" | "linux" (pre-settable for tests)
#   ac_stat_mtime <path>                — mtime, epoch seconds
#   ac_stat_size <path>                 — size in bytes
#   ac_stat_inode <path>                — inode number
#   ac_now_ms                           — epoch milliseconds
#   ac_now_iso_ms                       — UTC ISO-8601 with milliseconds
#   ac_date_from_epoch <epoch> [fmt]    — format an epoch (default ISO-8601 UTC)
#   ac_sed_i <sed-args...>              — in-place sed, GNU/BSD safe
#   ac_sha256 [file...]                 — sha256 "HASH  NAME" lines (stdin when no args)
#   ac_realpath_m <path>                — realpath -m semantics (path may not exist)
#   ac_files_by_mtime <dir> [find-primaries...] — "EPOCH\tPATH" lines, newest first
#   ac_basenames <dir> [find-primaries...]      — basename per line
#   ac_copy_into <src_dir> <dst_dir>    — cp -rT semantics (contents into dst)
#   ac_du_bytes <path>                  — recursive size in bytes
#   ac_mktemp_d <prefix>                — temp dir with a name prefix
#
# Internal (do not call from outside this file):
#   _ac_realpath_m_fallback
# Reason: bypasses the realpath(1) fast path; callers must go through
# ac_realpath_m so existing GNU behavior is preserved where available.

[[ -n "${_AC_COMPAT_LOADED:-}" ]] && return 0
_AC_COMPAT_LOADED=1

if [[ -z "${AC_OS:-}" ]]; then
    case "$(uname -s)" in
        Darwin) AC_OS=darwin ;;
        *)      AC_OS=linux ;;
    esac
fi

# ---- one-time capability probes (cheap; cached for the process lifetime) ----
if stat -c %Y / >/dev/null 2>&1; then _AC_STAT_FLAVOR=gnu; else _AC_STAT_FLAVOR=bsd; fi
if date -u -d @0 +%Y >/dev/null 2>&1; then _AC_DATE_FLAVOR=gnu; else _AC_DATE_FLAVOR=bsd; fi
if [[ "$(date +%3N)" == [0-9][0-9][0-9] ]]; then _AC_DATE_MS=1; else _AC_DATE_MS=0; fi
if sed --version >/dev/null 2>&1; then _AC_SED_FLAVOR=gnu; else _AC_SED_FLAVOR=bsd; fi
if command -v sha256sum >/dev/null 2>&1; then _AC_SHA256=sha256sum; else _AC_SHA256=shasum; fi
if realpath -m / >/dev/null 2>&1; then _AC_REALPATH_M=1; else _AC_REALPATH_M=0; fi
if du -sb "${BASH_SOURCE[0]:-/dev/null}" >/dev/null 2>&1; then _AC_DU_BYTES=1; else _AC_DU_BYTES=0; fi

ac_stat_mtime() {
    if [[ "$_AC_STAT_FLAVOR" == gnu ]]; then stat -c %Y "$1"; else stat -f %m "$1"; fi
}

ac_stat_size() {
    if [[ "$_AC_STAT_FLAVOR" == gnu ]]; then stat -c %s "$1"; else stat -f %z "$1"; fi
}

ac_stat_inode() {
    if [[ "$_AC_STAT_FLAVOR" == gnu ]]; then stat -c %i "$1"; else stat -f %i "$1"; fi
}

ac_now_ms() {
    # One read, no fork, no s/ms race when EPOCHREALTIME exists (bash 5).
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="$EPOCHREALTIME" frac
        frac="${t#*.}"
        echo $(( ${t%.*} * 1000 + 10#${frac:0:3} ))
    elif [[ "$_AC_DATE_MS" == 1 ]]; then
        date -u +%s%3N
    else
        echo $(( $(date -u +%s) * 1000 ))
    fi
}

ac_now_iso_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="$EPOCHREALTIME" frac
        frac="${t#*.}"
        TZ=UTC printf '%(%Y-%m-%dT%H:%M:%S)T.%sZ\n' "${t%.*}" "${frac:0:3}"
    elif [[ "$_AC_DATE_MS" == 1 ]]; then
        date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"
    else
        date -u +"%Y-%m-%dT%H:%M:%S.000Z"
    fi
}

ac_date_from_epoch() {
    local epoch="$1" fmt="${2:-+%Y-%m-%dT%H:%M:%SZ}"
    if [[ "$_AC_DATE_FLAVOR" == gnu ]]; then
        date -u -d "@$epoch" "$fmt"
    else
        date -u -r "$epoch" "$fmt"
    fi
}

ac_sed_i() {
    if [[ "$_AC_SED_FLAVOR" == gnu ]]; then sed -i "$@"; else sed -i '' "$@"; fi
}

ac_sha256() {
    if [[ "$_AC_SHA256" == sha256sum ]]; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

ac_realpath_m() {
    if [[ "$_AC_REALPATH_M" == 1 ]]; then
        realpath -m "$1"
    else
        _ac_realpath_m_fallback "$1"
    fi
}

# realpath -m semantics without realpath(1): physically resolve the longest
# existing ancestor (cd -P follows symlinks), then squash . / .. / // in the
# nonexistent remainder lexically — same contract GNU realpath -m applies.
_ac_realpath_m_fallback() {
    local p="$1" existing suffix="" out seg
    [[ "$p" == /* ]] || p="$PWD/$p"
    existing="$p"
    while [[ ! -d "$existing" && "$existing" != "/" ]]; do
        suffix="/${existing##*/}${suffix}"
        existing="${existing%/*}"
        [[ -z "$existing" ]] && existing="/"
    done
    existing="$(cd -P "$existing" 2>/dev/null && pwd)" || existing="/"
    out="$existing"
    local IFS='/'
    for seg in $suffix; do
        case "$seg" in
            ''|'.') ;;
            '..')
                out="${out%/*}"
                [[ -z "$out" ]] && out="/"
                ;;
            *)
                if [[ "$out" == "/" ]]; then out="/$seg"; else out="$out/$seg"; fi
                ;;
        esac
    done
    printf '%s\n' "$out"
}

ac_files_by_mtime() {
    # ac_files_by_mtime <dir> [find-primaries...] — "EPOCH\tPATH", newest first.
    local dir="$1"; shift
    if [[ "$_AC_STAT_FLAVOR" == gnu ]]; then
        find "$dir" "$@" -printf '%T@\t%p\n' 2>/dev/null | sort -rn
    else
        local f
        find "$dir" "$@" -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            printf '%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || echo 0)" "$f"
        done | sort -rn
    fi
}

ac_basenames() {
    # ac_basenames <dir> [find-primaries...] — basename per line (find -printf '%f\n').
    local dir="$1"; shift
    find "$dir" "$@" 2>/dev/null | sed 's|.*/||'
}

ac_copy_into() {
    # cp -rT semantics: copy CONTENTS of src into dst (dst created if missing).
    local src="$1" dst="$2"
    mkdir -p "$dst"
    cp -R "$src/." "$dst/"
}

ac_du_bytes() {
    if [[ "$_AC_DU_BYTES" == 1 ]]; then
        du -sb "$1" 2>/dev/null | cut -f1
    else
        du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'
    fi
}

ac_mktemp_d() {
    # Full-template form sidesteps the GNU/BSD -t semantic split.
    local base="${TMPDIR:-/tmp}"
    mktemp -d "${base%/}/${1}.XXXXXX"
}
