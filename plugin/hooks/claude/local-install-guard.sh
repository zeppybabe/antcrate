#!/usr/bin/env bash
# local-install-guard.sh — Claude Code PreToolUse hook (Bash).
#
# AntCrate prefers local, no-root, pinned, checksum-verified tools over reflexive
# system-wide or opaque installs. This guard BLOCKS (exit 2):
#   - system package installs: sudo apt/apt-get/dnf/yum/pacman/zypper/apk + install,
#     brew install, npm/pnpm/yarn global, gem install, cargo install, go install,
#     sudo pip install
#   - opaque download-and-run: `curl|wget … | sh/bash/python/...`, `sh -c "$(curl …)"`
#   - two-step download-then-execute: saving a remote installer to a file and
#     running it, either joined by an operator or as two separate tool calls
#     (fetched paths are recorded in XDG state for 24h)
#   - unsafe fetches: curl missing a fail-fast/transparency flag (-f/--fail)
#
# Escape hatch (audited): ANTCRATE_ALLOW_SYSTEM_INSTALL=1 must be in the
# PROCESS ENV of the session — export it before starting, or set it in the tool
# config. An inline `ANTCRATE_ALLOW_SYSTEM_INSTALL=1 <cmd>` prefix does NOT
# work: this hook runs before the command and reads its own environment, so the
# prefix has not taken effect yet. The block message says so when it sees one.
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
    # The hook reads its OWN environment; a VAR=1 prefix inside the command
    # string sets a variable for the command, never for the guard that runs
    # before it. Say so, or the next attempt is the identical one.
    if [[ "$cmd" == *ANTCRATE_ALLOW_SYSTEM_INSTALL=* ]]; then
        printf '  NOTE: an inline ANTCRATE_ALLOW_SYSTEM_INSTALL= prefix does not work —\n' >&2
        printf '  the guard runs before your command, so the variable must already be in\n' >&2
        printf '  the process env of the session (export it, or set it in the tool config).\n' >&2
    fi
    exit 2
}

_abs() {  # token -> absolute path, one quote layer stripped, . and .. collapsed
    local p="$1" part out=() joined=""
    p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
    case "$p" in
        '~'/*) p="$HOME/${p#\~/}" ;;
        /*)    ;;
        *)     p="$PWD/$p" ;;
    esac
    while IFS= read -r part; do
        case "$part" in
            ''|.) ;;
            ..)   (( ${#out[@]} > 0 )) && out=("${out[@]:0:${#out[@]}-1}") ;;
            *)    out+=("$part") ;;
        esac
    done < <(printf '%s\n' "${p//\//$'\n'}")
    for part in "${out[@]+"${out[@]}"}"; do joined+="/$part"; done
    printf '%s' "${joined:-/}"
}

# peel sudo / VAR=val and return the index of the real argv0
_argv0_index() {
    local -n _t="$1"
    local i=0
    while [ "${_t[$i]:-}" = "sudo" ] || [[ "${_t[$i]:-}" == *=* && "${_t[$i]:-}" != -* ]]; do
        i=$((i + 1))
    done
    printf '%s' "$i"
}

_fetch_targets() {  # <segment> -> local paths this segment saves a REMOTE fetch to
    local seg="$1" i j t argv0 url="" out="" bare_o=0 want=0
    local -a toks
    read -r -a toks <<< "$seg" || return 0
    (( ${#toks[@]} == 0 )) && return 0
    i="$(_argv0_index toks)"
    argv0="${toks[$i]##*/}"
    case "$argv0" in curl|wget) ;; *) return 0 ;; esac
    for (( j = i + 1; j < ${#toks[@]}; j++ )); do
        t="${toks[$j]}"
        if [ "$want" = 1 ]; then want=0; out="$t"; continue; fi
        case "$t" in
            -o|--output|--output-document) want=1 ;;
            -O) if [ "$argv0" = "curl" ]; then bare_o=1; else want=1; fi ;;
            '>'|'>>') want=1 ;;
            '>'*) out="${t#>}"; out="${out#>}" ;;
            -*) ;;
            *) [ -z "$url" ] && url="$t" ;;
        esac
    done
    # only a genuinely remote source counts — local file copies are not installs
    case "$url" in http://*|https://*|ftp://*) ;; *) return 0 ;; esac
    if [ -n "$out" ]; then
        _abs "$out"; printf '\n'
    elif [ "$bare_o" = 1 ] || [ "$argv0" = "wget" ]; then
        local bn="${url##*/}"; bn="${bn%%\?*}"
        [ -n "$bn" ] && { _abs "$bn"; printf '\n'; }
    fi
    return 0
}

_exec_targets() {  # <segment> -> local script paths this segment would execute
    local seg="$1" i j argv0 base
    local -a toks
    read -r -a toks <<< "$seg" || return 0
    (( ${#toks[@]} == 0 )) && return 0
    i="$(_argv0_index toks)"
    argv0="${toks[$i]:-}"
    base="${argv0##*/}"; base="${base#\\}"
    case "$base" in
        bash|sh|zsh|dash|ksh|python|python3|perl|ruby|node)
            for (( j = i + 1; j < ${#toks[@]}; j++ )); do
                case "${toks[$j]}" in -*) continue ;; esac
                _abs "${toks[$j]}"; printf '\n'; break
            done ;;
        *)
            case "$argv0" in */*|./*) _abs "$argv0"; printf '\n' ;; esac ;;
    esac
    return 0
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

# --- two-step download-then-execute ------------------------------------------
# `fetch | sh` is caught above. Saving the installer first and running it after
# reaches the same place, whether the steps are joined by && in one command or
# issued as two separate tool calls. The second shape needs a short-lived record
# of what was fetched, kept in XDG state.
_fetched_db="$_state/install-guard-fetched.tsv"
_fetch_window=$(( 24 * 60 * 60 ))

fetched=()
executed=()
while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    while IFS= read -r p; do [ -n "$p" ] && fetched+=("$p"); done < <(_fetch_targets "$seg")
    while IFS= read -r p; do [ -n "$p" ] && executed+=("$p"); done < <(_exec_targets "$seg")
done < <(printf '%s\n' "$cmd" | tr '|;&' '\n')

for x in "${executed[@]+"${executed[@]}"}"; do
    for f in "${fetched[@]+"${fetched[@]}"}"; do
        [ "$x" = "$f" ] && block "downloading a remote script and executing it in the same command"
    done
done

if [ -n "${executed[*]+x}" ] && [ -f "$_fetched_db" ]; then
    now="$(date +%s)"
    while IFS=$'\t' read -r ts path; do
        [ -z "${path:-}" ] && continue
        [ -z "${ts//[0-9]/}" ] || continue
        (( now - ts > _fetch_window )) && continue
        for x in "${executed[@]+"${executed[@]}"}"; do
            [ "$x" = "$path" ] && block "executing a script this session downloaded earlier ($path)"
        done
    done < "$_fetched_db"
fi

# nothing blocked — remember what was fetched so a later call is still seen
if [ -n "${fetched[*]+x}" ]; then
    if mkdir -p "$(dirname "$_fetched_db")" 2>/dev/null; then
        now="$(date +%s)"
        for f in "${fetched[@]}"; do
            printf '%s\t%s\n' "$now" "$f" >> "$_fetched_db" 2>/dev/null || true
        done
        # bound the file: keep the newest 200 records
        if [ "$(wc -l < "$_fetched_db" 2>/dev/null || echo 0)" -gt 200 ]; then
            tail -n 200 "$_fetched_db" > "$_fetched_db.tmp" 2>/dev/null \
                && mv "$_fetched_db.tmp" "$_fetched_db" 2>/dev/null || true
        fi
    fi
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
