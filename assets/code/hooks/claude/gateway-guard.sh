#!/usr/bin/env bash
# gateway-guard.sh — Claude Code PreToolUse / Bash hook.
#
# Tiered whole-system perimeter (the colony perimeter). Reads the hook payload
# on stdin, classifies the Bash command across protection zones, and:
#   - BLOCK  (exit 2) — critical zone, dangerous commands, registered-root or
#            recursive deletes in a sanctioned tree. stderr names the violation
#            and the sanctioned AntCrate channel; Claude Code feeds it back.
#   - WARN   (exit 0 + stderr) — neutral-zone destructive ops, bare git push.
#   - ALLOW  (exit 0, silent) — reads, single-file edits in a project tree, etc.
#
# Fail-open boundary: if the registry is unreadable, registry-dependent rules
# fall open, but the static critical-zone + dangerous-command rules STILL fire.
#
# NOTE: no `set -e` — the guard must always exit with its own computed code.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/_zones.sh"

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# --- resolve zone data -------------------------------------------------------

registry_ok=1
roots=()
if reg_out="$(zones_registered_roots)"; then
    while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done <<< "$reg_out"
else
    registry_ok=0
fi

CRIT=()
while IFS= read -r c; do [ -n "$c" ] && CRIT+=("$c"); done < <(zones_critical_paths)

CP=()
while IFS= read -r c; do [ -n "$c" ] && CP+=("$c"); done < <(zones_control_plane)

SAFE_TMP=()
while IFS= read -r c; do [ -n "$c" ] && SAFE_TMP+=("$c"); done < <(zones_safe_tmp_prefixes)

# --- helpers -----------------------------------------------------------------

_neutralize_quoted() {  # blank out shell operators sitting INSIDE quotes so
                        # destructive-looking text in string args isn't read as ops
    local s="$1" out="" ch q="" i n
    n="${#s}"
    for (( i = 0; i < n; i++ )); do
        ch="${s:i:1}"
        if [ -n "$q" ]; then
            if [ "$ch" = "$q" ]; then
                q=""
            else
                case "$ch" in '|'|'&'|';'|'<'|'>') ch=' ' ;; esac
            fi
        else
            case "$ch" in "'"|'"') q="$ch" ;; esac
        fi
        out+="$ch"
    done
    printf '%s' "$out"
}

_neutralize_heredocs() {  # blank heredoc BODIES — text between <<MARKER and the
                          # closing MARKER line is data, not commands. Exception:
                          # a shell/script interpreter receiving the heredoc
                          # EXECUTES its body (bash <<EOF) — leave those visible.
    local s="$1" out="" line probe marker="" in_doc=0 detect
    while IFS= read -r line; do
        if [ "$in_doc" = 1 ]; then
            probe="${line#"${line%%[!$'\t']*}"}"   # tolerate <<- tab indent
            if [ "$probe" = "$marker" ]; then
                in_doc=0
                out+="$line"$'\n'
            else
                out+=$'\n'
            fi
            continue
        fi
        out+="$line"$'\n'
        detect="${line//<<</ }"                    # herestrings are not heredocs
        if [[ "$detect" == *"<<"* ]]; then
            # interpreters that execute their stdin: keep the body scannable
            if [[ "$line" =~ (^|[[:space:];|&])(bash|sh|zsh|dash|ksh|eval|python[0-9.]*|perl|ruby|node)([[:space:]]|$) ]]; then
                continue
            fi
            if [[ "$detect" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_][A-Za-z0-9_]*) ]]; then
                marker="${BASH_REMATCH[1]}"
                in_doc=1
            fi
        fi
    done <<< "$s"
    printf '%s' "$out"
}

_resolve() {  # normalize a token into an absolute-ish path for matching
    local p="$1" tilde='~'
    p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"   # strip one layer of quotes
    if [ "${p:0:1}" = "$tilde" ]; then
        p="$HOME${p:1}"            # ~ -> $HOME, ~/x -> $HOME/x
    elif [ "${p:0:1}" != "/" ]; then
        p="$PWD/$p"
    fi
    printf '%s' "$p"
}

_under() {  # _under <path> <prefix>: true if path == prefix or under prefix/
    local path="$1" pre="$2"
    [ "$path" = "$pre" ] && return 0
    case "$path" in "$pre"/*) return 0 ;; esac
    return 1
}

_is_safe_dev() {  # ubiquitous harmless pseudo-devices — safe as redirect/op targets
    case "$1" in
        /dev/null|/dev/zero|/dev/full|/dev/tty|/dev/stdin|/dev/stdout|/dev/stderr|/dev/random|/dev/urandom) return 0 ;;
        /dev/fd/*) return 0 ;;
    esac
    return 1
}

_is_critical() {
    local path="$1" c
    _is_safe_dev "$path" && return 1
    # user-temp carve-out: only the control plane stays critical there
    for c in "${SAFE_TMP[@]+"${SAFE_TMP[@]}"}"; do
        if _under "$path" "$c"; then
            for c in "${CP[@]+"${CP[@]}"}"; do _under "$path" "$c" && return 0; done
            return 1
        fi
    done
    for c in "${CRIT[@]}"; do _under "$path" "$c" && return 0; done
    return 1
}

_under_root() {  # echoes the matching root, rc 0, if path is under one
    local path="$1" r
    for r in "${roots[@]+"${roots[@]}"}"; do
        _under "$path" "$r" && { printf '%s' "$r"; return 0; }
    done
    return 1
}

_is_root_exact() {
    local path="$1" r
    for r in "${roots[@]+"${roots[@]}"}"; do [ "$path" = "$r" ] && return 0; done
    return 1
}

# verdict: 0 allow, 1 warn, 2 block. Strongest wins; keep its message.
verdict=0
msg=""
bump() {
    local lvl="$1"; shift
    if [ "$lvl" -gt "$verdict" ]; then verdict="$lvl"; msg="$*"; fi
}

# --- whole-command dangerous signatures --------------------------------------

if printf '%s' "$cmd" | grep -qE ':\(\)\s*\{[^}]*:\|:[^}]*\}\s*;\s*:'; then
    bump 2 "dangerous fork-bomb signature"
fi

# --- per-segment analysis ----------------------------------------------------

# Neutralize operators inside quotes first, then split on ; && || | &
# (single & = background). Redirects (>) stay in-segment.
scan="$(_neutralize_quoted "$cmd")"
scan="$(_neutralize_heredocs "$scan")"
segments="$(printf '%s' "$scan" | sed -E 's/(\|\||&&|[;&|])/\n/g')"

while IFS= read -r seg; do
    # trim
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg="${seg%"${seg##*[![:space:]]}"}"
    [ -z "$seg" ] && continue

    read -r -a toks <<< "$seg"
    [ "${#toks[@]}" -eq 0 ] && continue

    # strip a leading privilege/wrapper prefix
    while [ "${#toks[@]}" -gt 1 ]; do
        case "${toks[0]##*/}" in
            sudo|doas|env|nohup|nice) toks=("${toks[@]:1}") ;;
            *) break ;;
        esac
    done

    base="${toks[0]##*/}"

    # redirects landing in the critical zone (covers > /dev/..., > registry)
    expect_target=0
    for t in "${toks[@]}"; do
        if [ "$expect_target" -eq 1 ]; then
            expect_target=0
            _is_critical "$(_resolve "$t")" && bump 2 "critical-zone redirect into $t"
            continue
        fi
        case "$t" in
            *'>'*)
                tgt="${t##*>}"
                if [ -z "$tgt" ]; then expect_target=1; else
                    _is_critical "$(_resolve "$tgt")" && bump 2 "critical-zone redirect into $tgt"
                fi
                ;;
        esac
    done

    # dangerous argv0 catalogue (any zone)
    for d in "${ZONES_DANGEROUS_ARGV0[@]}"; do
        [ "$base" = "$d" ] && bump 2 "dangerous command: $base"
    done
    case "$base" in
        mkfs|mkfs.*) bump 2 "dangerous command: $base" ;;
        systemctl)
            for t in "${toks[@]:1}"; do
                case "$t" in enable|start|disable) bump 2 "dangerous: systemctl $t" ;; esac
            done ;;
        launchctl)
            for t in "${toks[@]:1}"; do
                case "$t" in bootstrap|bootout|enable|disable|kickstart|load|unload)
                    bump 2 "dangerous: launchctl $t" ;; esac
            done ;;
        service)
            for t in "${toks[@]:1}"; do [ "$t" = start ] && bump 2 "dangerous: service start"; done ;;
        crontab)
            install=1
            for t in "${toks[@]:1}"; do [ "$t" = "-l" ] && install=0; done
            for t in "${toks[@]:1}"; do case "$t" in -e|-r) install=1 ;; esac; done
            [ "$install" -eq 1 ] && bump 2 "dangerous: crontab install" ;;
        chmod|chown)
            recursive=0
            for t in "${toks[@]:1}"; do
                case "$t" in -R|--recursive|-*R*|-*r*) recursive=1 ;; esac
            done
            if [ "$recursive" -eq 1 ]; then
                for t in "${toks[@]:1}"; do
                    case "$t" in -*) continue ;; esac
                    case "$t" in */*|~*|.|..) ;; *) continue ;; esac
                    rp="$(_resolve "$t")"
                    if _is_critical "$rp"; then bump 2 "dangerous: recursive $base on $rp"
                    elif [ "$registry_ok" -eq 1 ] && ! _under_root "$rp" >/dev/null; then
                        bump 2 "dangerous: recursive $base on non-project path $rp"
                    fi
                done
            fi ;;
    esac

    # rm — zone-classified deletion
    if [ "$base" = "rm" ]; then
        recursive=0
        targets=()
        for t in "${toks[@]:1}"; do
            case "$t" in
                --) continue ;;
                --recursive) recursive=1 ;;
                -*) case "$t" in *[rR]*) recursive=1 ;; esac ;;
                *) targets+=("$t") ;;
            esac
        done
        for t in "${targets[@]+"${targets[@]}"}"; do
            rp="$(_resolve "$t")"
            if _is_critical "$rp"; then
                bump 2 "critical-zone delete: $rp"
            elif [ "$registry_ok" -eq 1 ] && _under_root "$rp" >/dev/null; then
                if _is_root_exact "$rp"; then
                    bump 2 "delete of a registered project root: $rp"
                elif [ "$recursive" -eq 1 ]; then
                    bump 2 "recursive delete inside a project tree: $rp"
                fi
                # single-file rm inside a tree → allow (silent)
            elif [ "$registry_ok" -eq 1 ]; then
                bump 1 "neutral-zone delete: $rp"
            fi
            # registry_ok==0 + non-critical → fail open (no verdict)
        done
    fi

    # mv — moving a critical path or a whole registered root
    if [ "$base" = "mv" ]; then
        nf=()
        for t in "${toks[@]:1}"; do
            case "$t" in -*) continue ;; *) nf+=("$t") ;; esac
        done
        n="${#nf[@]}"
        i=0
        for t in "${nf[@]+"${nf[@]}"}"; do
            i=$((i + 1))
            rp="$(_resolve "$t")"
            if _is_critical "$rp"; then
                bump 2 "critical-zone move: $rp"
            elif [ "$i" -lt "$n" ] && [ "$registry_ok" -eq 1 ] && _is_root_exact "$rp"; then
                bump 2 "move of a registered project root: $rp"
            fi
        done
    fi

    # bare git push
    if [ "$base" = "git" ]; then
        for t in "${toks[@]:1}"; do
            [ "$t" = "push" ] && bump 1 "bare git push — use antcrate --pp <project>"
        done
    fi
done <<< "$segments"

# --- emit --------------------------------------------------------------------

case "$verdict" in
    2)
        printf 'gateway-guard: BLOCKED — %s\n' "$msg" >&2
        printf 'Sanctioned removal channels: antcrate --remove / --rename (whole roots), --ghosts (deghost), --quarantine-* ; mutate the registry only via lib/registry.sh. System / identity / control-plane ops are outside the colony perimeter and not permitted.\n' >&2
        exit 2 ;;
    1)
        printf 'gateway-guard: WARN — %s\n' "$msg" >&2
        exit 0 ;;
    *)
        exit 0 ;;
esac
