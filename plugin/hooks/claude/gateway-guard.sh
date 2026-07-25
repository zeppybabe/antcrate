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
# shellcheck source=/dev/null
. "$HERE/_lex.sh"

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

_normalize() {  # collapse . and .. LEXICALLY, plus duplicate/trailing slashes.
                # Deliberately no filesystem access and no symlink resolution:
                # registry roots are stored unresolved, so resolving here would
                # make the prefix match disagree with them. Without this,
                # a/../a defeats _under and the whole zone check falls open.
    local p="$1" part out=() joined=""
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

_resolve() {  # normalize a token into an absolute path for matching
    local p="$1" tilde='~'
    p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"   # strip one layer of quotes
    if [ "${p:0:1}" = "$tilde" ]; then
        p="$HOME${p:1}"            # ~ -> $HOME, ~/x -> $HOME/x
    elif [ "${p:0:1}" != "/" ]; then
        p="$PWD/$p"
    fi
    _normalize "$p"
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
    local path="$1" c cp
    _is_safe_dev "$path" && return 1
    # user-temp carve-out: only the control plane stays critical there
    for c in "${SAFE_TMP[@]+"${SAFE_TMP[@]}"}"; do
        if _under "$path" "$c"; then
            for cp in "${CP[@]+"${CP[@]}"}"; do _under "$path" "$cp" && return 0; done
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

_is_wrapper() {  # privilege / no-op prefixes that hide the real argv0, plus the
                 # builtin escapes (\rm, command rm, exec rm) and VAR=val prefixes
    local w="${1##*/}"; w="${w#\\}"
    case "$w" in
        sudo|doas|env|nohup|nice|time|stdbuf|command|builtin|exec) return 0 ;;
        -*) return 1 ;;
        *=*) return 0 ;;
    esac
    return 1
}

_qtokens() {  # quote-aware tokenizer: one token per line, one layer of quotes
              # stripped, and unquoted ; | & && || emitted as their own tokens.
              # Needed because the segment scanner below runs on a string whose
              # quoted operators have already been blanked — an inner command
              # must be recovered from the RAW text to stay segmentable.
    local s="$1" i n ch q="" tok="" started=0
    n="${#s}"
    for (( i = 0; i < n; i++ )); do
        ch="${s:i:1}"
        if [ -n "$q" ]; then
            if [ "$ch" = "$q" ]; then q=""; else tok+="$ch"; fi
            continue
        fi
        case "$ch" in
            "'"|'"') q="$ch"; started=1 ;;
            ' '|$'\t'|$'\n')
                [ "$started" = 1 ] && { printf '%s\n' "$tok"; tok=""; started=0; } ;;
            ';'|'|'|'&')
                [ "$started" = 1 ] && { printf '%s\n' "$tok"; tok=""; started=0; }
                if [ "${s:i+1:1}" = "$ch" ]; then
                    i=$((i + 1)); printf '%s%s\n' "$ch" "$ch"
                else
                    printf '%s\n' "$ch"
                fi ;;
            *) tok+="$ch"; started=1 ;;   # backslash kept: \rm must stay visible
        esac
    done
    [ "$started" = 1 ] && printf '%s\n' "$tok"
    return 0
}

_inner_cmds() {  # emit every command string hidden inside a shell -c or an eval
    local raw="$1" t w at_start=1 argv0="" want_c=0 in_eval=0 evalbuf=""
    while IFS= read -r t; do
        case "$t" in
            ';'|'&'|'|'|'&&'|'||')
                [ "$in_eval" = 1 ] && [ -n "$evalbuf" ] && printf '%s\n' "$evalbuf"
                evalbuf=""; in_eval=0; want_c=0; at_start=1; argv0=""
                continue ;;
        esac
        if [ "$at_start" = 1 ]; then
            _is_wrapper "$t" && continue
            w="${t##*/}"; w="${w#\\}"
            at_start=0; argv0="$w"
            [ "$w" = "eval" ] && in_eval=1
            continue
        fi
        if [ "$in_eval" = 1 ]; then
            evalbuf="${evalbuf:+$evalbuf }$t"
            continue
        fi
        if [ "$want_c" = 1 ]; then
            printf '%s\n' "$t"; want_c=0; continue
        fi
        case "$argv0" in
            bash|sh|zsh|dash|ksh) [ "$t" = "-c" ] && want_c=1 ;;
        esac
    done < <(_qtokens "$raw")
    [ "$in_eval" = 1 ] && [ -n "$evalbuf" ] && printf '%s\n' "$evalbuf"
    return 0
}

# verdict: 0 allow, 1 warn, 2 block. Strongest wins; keep its message.
verdict=0
msg=""
bump() {
    local lvl="$1"; shift
    if [ "$lvl" -gt "$verdict" ]; then verdict="$lvl"; msg="$*"; fi
}

# --- command analysis --------------------------------------------------------

# _scan_command <raw> [depth] — analyse one command string, recursing first into
# any command hidden inside a shell -c / eval so indirection cannot launder a
# blocked operation. Verdict accumulates in the globals via bump().
_scan_command() {
    local raw="$1" depth="${2:-0}" inner scan segments seg
    (( depth > 4 )) && return 0

    # Inner-command extraction runs on the RAW text (it must see quoting), so it
    # needs its own fold: `bash -c \` + `'rm -rf /etc'` otherwise hands the
    # tokenizer a lone backslash as the -c argument and loses the payload.
    while IFS= read -r inner; do
        [ -n "$inner" ] && _scan_command "$inner" $(( depth + 1 ))
    done < <(_inner_cmds "$(ac_lex_join_continuations "$raw")")

    if printf '%s' "$raw" | grep -qE ':\(\)\s*\{[^}]*:\|:[^}]*\}\s*;\s*:'; then
        bump 2 "dangerous fork-bomb signature"
    fi

# Neutralize operators inside quotes first, then split on ; && || | &
# (single & = background). Redirects (>) stay in-segment.
scan="$(_neutralize_quoted "$raw")"
scan="$(_neutralize_heredocs "$scan")"
# AFTER the heredoc pass, never before: folding a body line onto its closing
# marker would hide the marker and swallow the rest of the command as data.
scan="$(ac_lex_join_continuations "$scan")"
segments="$(printf '%s' "$scan" | sed -E 's/(\|\||&&|[;&|])/\n/g')"

while IFS= read -r seg; do
    # trim
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg="${seg%"${seg##*[![:space:]]}"}"
    [ -z "$seg" ] && continue

    read -r -a toks <<< "$seg"
    [ "${#toks[@]}" -eq 0 ] && continue

    # strip leading privilege/no-op wrappers, builtin escapes and VAR=val prefixes
    while [ "${#toks[@]}" -gt 1 ]; do
        _is_wrapper "${toks[0]}" || break
        toks=("${toks[@]:1}")
    done

    base="${toks[0]##*/}"; base="${base#\\}"

    # xargs — the real command sits after xargs' own options. Without this the
    # single most common deletion shape in a pipeline, `… | xargs rm -rf`, was
    # classified as an invocation of "xargs" and drew no verdict at all, while
    # find -delete, rsync --delete, git clean -f, truncate and shred were all
    # covered (audit 2026-07-25, finding B). Expose the inner argv so every rule
    # below judges the deletion, not the launcher.
    via_xargs=0
    if [ "$base" = "xargs" ]; then
        via_xargs=1
        k=1
        while (( k < ${#toks[@]} )); do
            case "${toks[$k]}" in
                --) k=$((k + 1)); break ;;
                # options that take a separate value
                -n|-P|-I|-i|-s|-L|-a|-d|-E|--max-args|--max-procs|--replace|--arg-file|--delimiter|--max-lines|--eof)
                    k=$((k + 2)) ;;
                -*) k=$((k + 1)) ;;
                *)  break ;;
            esac
        done
        toks=("${toks[@]:$k}")
        [ "${#toks[@]}" -eq 0 ] && continue
        while [ "${#toks[@]}" -gt 1 ]; do
            _is_wrapper "${toks[0]}" || break
            toks=("${toks[@]:1}")
        done
        base="${toks[0]##*/}"; base="${base#\\}"
    fi

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

    # find with a destructive action — same effect as a recursive rm, different argv0
    if [ "$base" = "find" ]; then
        destructive=0
        want_exec=0
        paths=()
        seen_flag=0
        for t in "${toks[@]:1}"; do
            if [ "$want_exec" -eq 1 ]; then
                want_exec=0
                case "${t##*/}" in rm|unlink|shred|truncate|dd|mv) destructive=1 ;; esac
            fi
            case "$t" in
                -delete) destructive=1 ;;
                -exec|-execdir|-ok|-okdir) want_exec=1; seen_flag=1 ;;
                -*) seen_flag=1 ;;
                *) [ "$seen_flag" -eq 0 ] && paths+=("$t") ;;
            esac
        done
        if [ "$destructive" -eq 1 ]; then
            [ "${#paths[@]}" -eq 0 ] && paths=(".")
            for t in "${paths[@]}"; do
                rp="$(_resolve "$t")"
                if _is_critical "$rp"; then
                    bump 2 "critical-zone delete via find: $rp"
                elif [ "$registry_ok" -eq 1 ] && _under_root "$rp" >/dev/null; then
                    bump 2 "recursive delete inside a project tree via find: $rp"
                elif [ "$registry_ok" -eq 1 ]; then
                    bump 1 "neutral-zone delete via find: $rp"
                fi
            done
        fi
    fi

    # git clean -f — untracked-file wipe; as destructive as rm -r inside a tree
    if [ "$base" = "git" ]; then
        is_clean=0; forced=0; dry=0
        paths=()
        expect_dir=0
        gitdir=""
        for t in "${toks[@]:1}"; do
            if [ "$expect_dir" -eq 1 ]; then expect_dir=0; gitdir="$t"; continue; fi
            case "$t" in
                -C) expect_dir=1 ;;
                clean) is_clean=1 ;;
                -n|--dry-run) dry=1 ;;
                --force) forced=1 ;;
                -*) [ "$is_clean" -eq 1 ] && case "$t" in *f*) forced=1 ;; esac
                    case "$t" in *n*) [[ "$t" != --* ]] && dry=1 ;; esac ;;
                *) [ "$is_clean" -eq 1 ] && paths+=("$t") ;;
            esac
        done
        if [ "$is_clean" -eq 1 ] && [ "$forced" -eq 1 ] && [ "$dry" -eq 0 ]; then
            [ "${#paths[@]}" -eq 0 ] && paths=("${gitdir:-.}")
            for t in "${paths[@]}"; do
                rp="$(_resolve "$t")"
                if _is_critical "$rp"; then
                    bump 2 "critical-zone wipe: git clean on $rp"
                elif [ "$registry_ok" -eq 1 ] && _under_root "$rp" >/dev/null; then
                    bump 2 "untracked-file wipe inside a project tree: git clean on $rp"
                fi
            done
        fi
    fi

    # rsync --delete — deletes in the DESTINATION (last non-flag operand)
    if [ "$base" = "rsync" ]; then
        deleting=0
        nf=()
        for t in "${toks[@]:1}"; do
            case "$t" in
                --delete|--delete-*|--del) deleting=1 ;;
                -*) ;;
                *) nf+=("$t") ;;
            esac
        done
        if [ "$deleting" -eq 1 ] && [ "${#nf[@]}" -gt 0 ]; then
            rp="$(_resolve "${nf[$(( ${#nf[@]} - 1 ))]}")"
            if _is_critical "$rp"; then
                bump 2 "critical-zone delete via rsync --delete: $rp"
            elif [ "$registry_ok" -eq 1 ] && _under_root "$rp" >/dev/null; then
                bump 2 "recursive delete inside a project tree via rsync --delete: $rp"
            fi
        fi
    fi

    # truncate — destroys file contents in place without ever calling rm
    if [ "$base" = "truncate" ]; then
        for t in "${toks[@]:1}"; do
            case "$t" in -*) continue ;; esac
            rp="$(_resolve "$t")"
            _is_critical "$rp" && bump 2 "critical-zone truncate: $rp"
        done
    fi

    # rm and its single-purpose equivalents — zone-classified deletion
    if [ "$base" = "rm" ] || [ "$base" = "unlink" ] || [ "$base" = "shred" ]; then
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
        # `… | xargs rm -rf` with no literal operand: the paths arrive on stdin,
        # so nothing here can classify them. Unknown targets are exactly the
        # case the zone rules exist for, so this cannot be silent — but it also
        # cannot be proven to touch a protected path, so it warns rather than
        # blocks, matching the neutral-zone destructive tier.
        if [ "$via_xargs" -eq 1 ] && [ "${#targets[@]}" -eq 0 ]; then
            bump 1 "$base via xargs — targets read from stdin, not classifiable"
        fi
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
}

_scan_command "$cmd" 0

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
