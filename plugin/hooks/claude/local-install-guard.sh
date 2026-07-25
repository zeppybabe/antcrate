#!/usr/bin/env bash
# local-install-guard.sh — Claude Code PreToolUse hook (Bash).
#
# AntCrate prefers local, no-root, pinned, checksum-verified tools over reflexive
# system-wide or opaque installs. This guard BLOCKS (exit 2):
#   - system package installs: sudo apt/apt-get/dnf/yum/pacman/zypper/apk + install,
#     brew install, npm/pnpm/yarn global, gem install, cargo install, go install,
#     sudo pip install
#   - opaque download-and-run: `curl|wget … | sh/bash/python/...`, `sh -c "$(curl …)"`
#   - unsafe fetches: curl missing a fail-fast/transparency flag (-f/--fail)
#
# Escape hatch (audited): re-run with ANTCRATE_ALLOW_SYSTEM_INSTALL=1.
# Global off-switch: ANTCRATE_INSTALL_GUARD_DISABLE=1.
#
# NOTE: no `set -e` — the guard must always exit with its own computed code.
set -uo pipefail

[ "${ANTCRATE_INSTALL_GUARD_DISABLE:-0}" = "1" ] && exit 0

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# XDG state log for audited bypasses (resolve without sourcing paths.sh).
_state="${ANTCRATE_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/antcrate}"
_audit="$_state/log/install-guard.log"

_log() {  # <verdict> <reason>
    mkdir -p "$(dirname "$_audit")" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" >> "$_audit" 2>/dev/null || true
}

block() {
    local reason="$1"
    if [ "${ANTCRATE_ALLOW_SYSTEM_INSTALL:-0}" = "1" ]; then
        _log "BYPASS" "$reason :: $cmd"
        exit 0
    fi
    _log "BLOCK" "$reason :: $cmd"
    printf 'local-install-guard: BLOCKED — %s\n' "$reason" >&2
    printf '  AntCrate gates system-wide and opaque installs. Prefer local + pinned:\n' >&2
    printf '    antcrate --tool-install <tool>     # no root, sha256-verified\n' >&2
    printf '    antcrate --tool-list               # what is available/installed\n' >&2
    printf '  If a system package is genuinely required, re-run (audited):\n' >&2
    printf '    ANTCRATE_ALLOW_SYSTEM_INSTALL=1 <your command>\n' >&2
    exit 2
}

# Single-quoted spans never expand — strip them, but keep a copy of the raw
# command for the opaque-pipe regexes (which must see the quoted curl|bash).
stripped="$(printf '%s' "$cmd" | sed "s/'[^']*'//g")"

# --- opaque download-and-run (whole-command regexes) -------------------------
# curl/wget output piped into an interpreter
if printf '%s' "$cmd" | grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|dash|ksh|python3?|perl|ruby|node)\b'; then
    block "piping a remote download straight into a shell/interpreter"
fi
# sh -c / bash -c wrapping a curl|wget fetch
if printf '%s' "$cmd" | grep -Eq '\b(bash|sh|zsh|dash|ksh)[[:space:]]+-c\b.*(curl|wget)\b'; then
    block "executing a shell -c that fetches code with curl/wget"
fi

# --- per-segment analysis: package managers + unsafe curl --------------------
while IFS= read -r seg; do
    # tokenize
    # shellcheck disable=SC2206
    read -r -a toks <<< "$seg" || continue
    (( ${#toks[@]} == 0 )) && continue

    # peel a leading sudo/env so we see the real argv0
    i=0
    while [ "${toks[$i]:-}" = "sudo" ] || [[ "${toks[$i]:-}" == *=* && "${toks[$i]:-}" != -* ]]; do
        i=$((i+1))
    done
    argv0="${toks[$i]##*/}"
    rest=("${toks[@]:$((i+1))}")

    case "$argv0" in
        apt|apt-get|dnf|yum|zypper)
            for t in "${rest[@]}"; do [ "$t" = "install" ] && block "system package install: $argv0 install"; done ;;
        apk)
            for t in "${rest[@]}"; do [ "$t" = "add" ] && block "system package install: apk add"; done ;;
        pacman)
            for t in "${rest[@]}"; do case "$t" in -S|-S[yu]*|--sync) block "system package install: pacman $t" ;; esac; done ;;
        brew)
            for t in "${rest[@]}"; do [ "$t" = "install" ] && block "system package install: brew install"; done ;;
        npm|pnpm)
            for t in "${rest[@]}"; do case "$t" in -g|--global) block "global package install: $argv0 -g" ;; esac; done ;;
        yarn)
            [ "${rest[0]:-}" = "global" ] && block "global package install: yarn global" ;;
        gem)
            for t in "${rest[@]}"; do [ "$t" = "install" ] && block "system gem install: gem install"; done ;;
        cargo)
            [ "${rest[0]:-}" = "install" ] && block "global cargo install: cargo install" ;;
        go)
            [ "${rest[0]:-}" = "install" ] && block "system go install: go install" ;;
        pip|pip3)
            # only block clearly-system pip (sudo peeled above means a leading sudo set i>0)
            if (( i > 0 )); then
                for t in "${rest[@]}"; do [ "$t" = "install" ] && block "system pip install (sudo): use a venv or antcrate --tool-install"; done
            fi
            for t in "${rest[@]}"; do [ "$t" = "--break-system-packages" ] && block "pip --break-system-packages"; done ;;
        curl)
            # require a fail-fast/transparency flag (-f / --fail)
            has_fail=0
            for t in "${rest[@]}"; do
                case "$t" in --fail) has_fail=1 ;; -*f*) [[ "$t" != --* ]] && has_fail=1 ;; esac
            done
            (( has_fail == 0 )) && block "unsafe curl (no -f/--fail; add e.g. -fsSL --proto '=https' --tlsv1.2)"
            ;;
    esac
done < <(printf '%s\n' "$stripped" | tr '|;&' '\n')

exit 0
