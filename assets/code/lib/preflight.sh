#!/usr/bin/env bash
# antcrate :: lib/preflight.sh — dependency checks for install.sh.
#
# Required runtime tools (jq, git, a filesystem watcher) must be present or the
# install aborts with a per-platform install hint — never a cryptic mid-script
# failure. On Linux the hint is per-distro (apt/dnf/pacman/zypper via
# /etc/os-release); on macOS it is Homebrew. The watcher requirement is the
# virtual token "fswatcher", satisfied by inotifywait (Linux) OR fswatch
# (macOS/FSEvents) — bin/antcrated picks whichever is present at runtime.
# Optional dev tools (bats, shellcheck) are merely advised, pointing at the
# local, no-root `antcrate --tool-install` path (the system package manager is
# gated by the local-install guard hook).

# compat.sh self-source: AC_OS used below; guard makes re-sourcing free
# (bats tests source libs directly, without the wrapper preamble).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

# ac_preflight_pkg_hint <pkg> — print the per-platform install command for <pkg>.
ac_preflight_pkg_hint() {
    local pkg="$1" id
    if [[ "${AC_OS:-linux}" == darwin ]]; then
        if command -v brew >/dev/null 2>&1; then
            printf 'brew install %s\n' "$pkg"
        else
            printf 'brew install %s   (install Homebrew first: https://brew.sh)\n' "$pkg"
        fi
        return 0
    fi
    # shellcheck disable=SC1091  # /etc/os-release is a runtime distro file, not a project source
    id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-${ID:-}}")"
    case "$id" in
        *debian*|*ubuntu*)        printf 'sudo apt-get install -y %s\n' "$pkg" ;;
        *fedora*|*rhel*|*centos*) printf 'sudo dnf install -y %s\n' "$pkg" ;;
        *arch*|*manjaro*)         printf 'sudo pacman -S --noconfirm %s\n' "$pkg" ;;
        *suse*)                   printf 'sudo zypper install -y %s\n' "$pkg" ;;
        *)                        printf "(install '%s' with your system package manager)\n" "$pkg" ;;
    esac
}

# _ac_preflight_pkg_for <tool> — map a missing tool to its package name for
# the hint. The "fswatcher" virtual token maps to the platform's watcher.
_ac_preflight_pkg_for() {
    local t="$1"
    case "$t" in
        inotifywait) echo "inotify-tools" ;;
        fswatcher)
            if [[ "${AC_OS:-linux}" == darwin ]]; then echo "fswatch"; else echo "inotify-tools"; fi ;;
        *) echo "$t" ;;
    esac
}

# _ac_preflight_have <tool> — command -v, with "fswatcher" satisfied by
# either concrete watcher.
_ac_preflight_have() {
    local t="$1"
    if [[ "$t" == fswatcher ]]; then
        command -v inotifywait >/dev/null 2>&1 || command -v fswatch >/dev/null 2>&1
        return $?
    fi
    command -v "$t" >/dev/null 2>&1
}

# ac_preflight_bash_version — the codebase needs Bash 4+ (associative arrays,
# mapfile, ${var,,}); macOS's stock /bin/bash is 3.2. Fails below 4 with a
# fix hint; warns below 5 (EPOCHREALTIME fast paths degrade gracefully).
ac_preflight_bash_version() {
    if (( BASH_VERSINFO[0] < 4 )); then
        printf '[antcrate] bash %s is too old — antcrate needs bash 4+ (associative arrays)\n' "${BASH_VERSION}" >&2
        printf '  %s\n' "$(ac_preflight_pkg_hint bash)" >&2
        if [[ "${AC_OS:-linux}" == darwin ]]; then
            printf '  then make sure the brew bin dir precedes /bin in PATH (scripts use env bash)\n' >&2
        fi
        return 1
    fi
    if (( BASH_VERSINFO[0] < 5 )); then
        printf '[antcrate] note: bash %s works, but 5+ is faster (EPOCHREALTIME)\n' "${BASH_VERSION}"
    fi
    return 0
}

# ac_preflight_deps [required...] — verify required tools are on PATH; on any
# miss, print the per-platform hint(s) to stderr and return 1. Default required
# set is jq, git, fswatcher. Advises (does not require) bats + shellcheck.
ac_preflight_deps() {
    local required=("$@")
    (( ${#required[@]} )) || required=(jq git fswatcher)

    local t
    local missing=()
    for t in "${required[@]}"; do
        _ac_preflight_have "$t" || missing+=("$t")
    done

    if (( ${#missing[@]} )); then
        printf '[antcrate] missing required tools: %s\n' "${missing[*]}" >&2
        for t in "${missing[@]}"; do
            printf '  %s\n' "$(ac_preflight_pkg_hint "$(_ac_preflight_pkg_for "$t")")" >&2
        done
        return 1
    fi

    for t in bats shellcheck; do
        command -v "$t" >/dev/null 2>&1 \
            || printf "[antcrate] optional dev tool '%s' not found — local install: antcrate --tool-install %s\n" "$t" "$t"
    done
    return 0
}
