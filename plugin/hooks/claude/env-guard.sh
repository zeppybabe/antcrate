#!/usr/bin/env bash
# env-guard.sh — Claude Code PreToolUse hook (Bash + Read).
#
# Secrets stay opaque to agents. An agent may ASSIGN or reference env vars
# by NAME (`export FOO="$API_KEY"`, `KEY=$TOKEN ./run`, `source .env`), but
# any display sink that would put secret VALUES into the transcript is
# BLOCKED (exit 2):
#   - environment dumps: bare `env`, `printenv`, bare `set`,
#     `declare -p` / `typeset -p` / `export -p`
#   - echo/printf of vars whose NAME looks secret (KEY/TOKEN/SECRET/...)
#   - read sinks (cat/grep/head/...) on secret files (.env, private keys,
#     .netrc, credentials, *.pem) — and the Read tool on the same files
#
# Single-quoted text never expands, so it is stripped before analysis.
# Rebuilt 2026-06-10 after the original was lost in the ephemeral-path
# incident (ledger 2026-06-09).
#
# NOTE: no `set -e` — the guard must always exit with its own computed code.
set -uo pipefail

[ "${ANTCRATE_ENV_GUARD_DISABLE:-0}" = "1" ] && exit 0

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
fpath="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"

block() {
    printf 'env-guard: BLOCKED — %s\nSecret values must never enter the transcript. Reference variables by NAME only (assignment, export, source); ask the user to inspect values themselves.\n' "$1" >&2
    exit 2
}

# Var NAMES that look secret. Segmented on underscores so BYPASS != PASS.
_is_secret_var() {
    local seg
    local IFS='_'
    # shellcheck disable=SC2086  # intentional word-split of the name into segments
    for seg in ${1^^}; do
        case "$seg" in
            KEY|KEYS|APIKEY|TOKEN|TOKENS|SECRET|SECRETS|PASS|PASSWD|PASSWORD|CRED|CREDS|CREDENTIAL|CREDENTIALS|AUTH) return 0 ;;
        esac
    done
    return 1
}

_is_secret_file() {
    local p="$1" b; b=$(basename "$p")
    case "$b" in
        .env.example|.env.sample|.env.template|*.pub) return 1 ;;
        .env|.env.*|.netrc|.npmrc|credentials|credentials.json|*.pem|id_rsa|id_ed25519|id_ecdsa|id_dsa) return 0 ;;
    esac
    case "$p" in
        *.pub) return 1 ;;
        */.ssh/*|*/.aws/credentials|*/.gnupg/*) return 0 ;;
    esac
    return 1
}

# --- Read tool ---------------------------------------------------------------

if [ -n "$fpath" ]; then
    _is_secret_file "$fpath" && block "reading secret file: $fpath"
    exit 0
fi

[ -z "$cmd" ] && exit 0

# --- Bash tool ---------------------------------------------------------------

# Single-quoted spans never expand — drop them before analysis.
stripped="$(printf '%s' "$cmd" | sed "s/'[^']*'//g")"

# Walk pipeline/list segments.
while IFS= read -r seg; do
    # tokenize, shedding surrounding double quotes per token
    read -r -a toks <<< "$seg" || continue
    (( ${#toks[@]} == 0 )) && continue
    argv0="${toks[0]##*/}"

    case "$argv0" in
        env)
            # bare dump blocks; `env [-i] VAR=x cmd` (a launcher) is fine
            (( ${#toks[@]} == 1 )) && block "environment dump: env" ;;
        printenv)
            block "environment dump: printenv" ;;
        set)
            (( ${#toks[@]} == 1 )) && block "environment dump: bare set" ;;
        declare|typeset|export)
            [ "${toks[1]:-}" = "-p" ] && block "environment dump: $argv0 -p" ;;
        echo|printf)
            # any expanded var with a secret-looking name in this segment
            while IFS= read -r name; do
                [ -z "$name" ] && continue
                _is_secret_var "$name" && block "printing secret variable \$$name"
            done < <(printf '%s' "$seg" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\${\?//; s/^\$//')
            ;;
        cat|less|more|head|tail|grep|egrep|fgrep|rg|awk|sed|strings|xxd|od|nl|bat|cut|sort|uniq|tee|wc)
            local_i=1
            while (( local_i < ${#toks[@]} )); do
                t="${toks[$local_i]}"; t="${t%\"}"; t="${t#\"}"
                case "$t" in -*) local_i=$((local_i + 1)); continue ;; esac
                _is_secret_file "$t" && block "reading secret file: $t"
                local_i=$((local_i + 1))
            done
            ;;
    esac
done < <(printf '%s\n' "$stripped" | tr '|;&' '\n')

exit 0
