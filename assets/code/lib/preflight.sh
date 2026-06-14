#!/usr/bin/env bash
# antcrate :: lib/preflight.sh — dependency checks for install.sh.
#
# Required runtime tools (jq, git, inotifywait) must be present or the install
# aborts with a per-distro install hint — never a cryptic mid-script failure.
# Optional dev tools (bats, shellcheck) are merely advised, pointing at the
# local, no-root `antcrate --tool-install` path (the system package manager is
# gated by the local-install guard hook).

# ac_preflight_pkg_hint <pkg> — print the per-distro install command for <pkg>.
ac_preflight_pkg_hint() {
    local pkg="$1" id
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

# ac_preflight_deps [required...] — verify required tools are on PATH; on any
# miss, print the per-distro hint(s) to stderr and return 1. Default required
# set is jq, git, inotifywait. Advises (does not require) bats + shellcheck.
ac_preflight_deps() {
    local required=("$@")
    (( ${#required[@]} )) || required=(jq git inotifywait)

    local t pkg
    local missing=()
    for t in "${required[@]}"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done

    if (( ${#missing[@]} )); then
        printf '[antcrate] missing required tools: %s\n' "${missing[*]}" >&2
        for t in "${missing[@]}"; do
            pkg="$t"; [ "$t" = "inotifywait" ] && pkg="inotify-tools"
            printf '  %s\n' "$(ac_preflight_pkg_hint "$pkg")" >&2
        done
        return 1
    fi

    for t in bats shellcheck; do
        command -v "$t" >/dev/null 2>&1 \
            || printf "[antcrate] optional dev tool '%s' not found — local install: antcrate --tool-install %s\n" "$t" "$t"
    done
    return 0
}
