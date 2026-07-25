#!/usr/bin/env bash
# _lex.sh — shared lexical normalisation for the Claude Code Bash guards.
#
# Sourced by gateway-guard.sh, env-guard.sh and local-install-guard.sh. Every
# one of those guards analyses a command by splitting it into lines and then
# into segments. A backslash-newline continuation breaks that model: bash joins
# the two lines into ONE command, but a line-oriented scanner sees two, and the
# operands land in a "command" whose argv0 is a path fragment no rule matches.
#
# Audit 2026-07-25 (finding A) — this was a live fail-open in BOTH PreToolUse
# guards, reproduced from a neutral cwd:
#     rm -rf \        ->  WARN "neutral-zone delete: /home/alexk/\"
#     /etc                 (bash executes `rm -rf /etc`; the guard let it pass)
#     cat \           ->  allowed silently, rc 0
#     .env
# It is not an evasion trick: it is how anyone formats a long command, so the
# guards were blind on ordinary input, not just adversarial input.

[ -n "${_AC_LEX_LOADED:-}" ] && return 0
_AC_LEX_LOADED=1

# ac_lex_join_continuations <text> — fold `\<newline>` into one logical line.
#
# A trailing backslash only continues the line when it is NOT itself escaped,
# so the trailing backslash RUN is counted and an odd count continues. The
# backslash is replaced by a space rather than deleted, so `rm -rf \` + `/etc`
# becomes `rm -rf  /etc` and never fuses two tokens into one.
#
# Deliberately not quote-aware: a backslash-newline inside a single-quoted
# string is literal text, and folding it anyway can only merge more text into
# one line — i.e. it can over-match a rule, never under-match one. For a
# security guard that is the safe direction, and the alternative (a second
# quote-state parser) would be a larger surface than the bug it fixes.
#
# Heredoc bodies must be neutralised BEFORE calling this: folding a body line
# that ends in a backslash onto the closing marker line would hide the marker,
# leaving the rest of the command swallowed as heredoc data.
ac_lex_join_continuations() {
    local s="$1" out="" line run
    while IFS= read -r line; do
        run="${line##*[!\\]}"                 # trailing run of backslashes
        if (( ${#run} % 2 == 1 )); then
            out+="${line%\\} "
        else
            out+="$line"$'\n'
        fi
    done <<< "$s"
    printf '%s' "$out"
}
