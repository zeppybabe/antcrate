#!/usr/bin/env bash
# antcrate :: lib/post.sh — project update drafting for X (drafts-folder delivery, v1.1).
#
# Design: docs/superpowers/specs/2026-07-17-x-post-design.md (+ 2026-07-18 pivot note)
#  - material mode emits secret-guarded git material; an AI (or human) words the
#    post; --draft prepends it to the project's git-ignored X-POSTS.md. The HUMAN
#    copies it into X — the paste is the publish gate; this lib never touches X.
#  - The web-intent browser delivery (--open + x-accounts.json) was retired
#    2026-07-18 by owner decision; see the ledger entry of that date.

# Local defaults for standalone sourcing (house convention: libs redeclare paths.sh vars)
: "${ANTCRATE_POSTS_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/antcrate/posts}"

# ac_post_log_file <project>
ac_post_log_file() { printf '%s/%s.log\n' "$ANTCRATE_POSTS_DIR" "$1"; }

# ac_post_last_sha <project> — range end of the newest record; rc 1 if no log.
ac_post_last_sha() {
    local f rec range
    f=$(ac_post_log_file "$1")
    [[ -s "$f" ]] || return 1
    rec=$(tail -n 1 "$f")
    range=$(printf '%s' "$rec" | awk -F'\t' '{print $3}')
    [[ -n "$range" ]] || return 1
    printf '%s\n' "${range##*..}"
}

# ac_post_log_append <project> <handle> <range> <text> [status] — append-only record.
# Field order is a stable contract (antcrate-mcp's antcrate_posts tool parses it).
ac_post_log_append() {
    local project="$1" handle="$2" range="$3" text="$4" status="${5:-drafted}" f
    f=$(ac_post_log_file "$project")
    mkdir -p "$ANTCRATE_POSTS_DIR"
    text="${text//$'\t'/ }"        # tabs are the field separator
    text="${text//$'\n'/\\n}"      # one record per line
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$handle" "$range" "$status" "$text" >> "$f"
}

# ac_post_log_show <project> — newest first; rc 1 if no log yet.
ac_post_log_show() {
    local f
    f=$(ac_post_log_file "$1")
    if [[ ! -s "$f" ]]; then ac_error "post: no posts logged for '$1' yet"; return 1; fi
    tac "$f" | awk -F'\t' '{ printf "%s  %s  %s  [%s]  %s\n", $1, $2, $3, $4, $5 }'
}

# Content secret guard — credential SHAPES, deliberately conservative: a post is
# ~280 chars of prose; a false positive costs a rewrite, a false negative leaks.
#
# JWT alternative uses `+` (not `{20,}`): under the system mawk, an open-ended
# `{20,}` bound followed by more pattern (here `\.eyJ`) silently fails to
# match, so a JWT-shaped secret would pass ac_post_redact unredacted while
# grep -E (ac_post_guard_text) still refuses it — same ERE, disagreeing
# engines. `+` is unbounded-but-not-interval and mawk handles it correctly.
# Assignment alternatives are duplicated in lower/Title/ALL-CAPS ([Pp]assword,
# PASSWORD, etc.) rather than using a case-insensitive flag, since ERE has no
# inline (?i) and grep/awk here don't share a portable case-fold option.
AC_POST_SECRET_ERE='AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]+\.eyJ|-----BEGIN [A-Z ]*PRIVATE KEY-----|[Pp]assword[[:space:]]*[=:][[:space:]]*[^[:space:]]+|PASSWORD[[:space:]]*[=:][[:space:]]*[^[:space:]]+|[Aa]pi[_-]?[Kk]ey[[:space:]]*[=:][[:space:]]*[^[:space:]]+|API[_-]?KEY[[:space:]]*[=:][[:space:]]*[^[:space:]]+|[Ss]ecret[[:space:]]*[=:][[:space:]]*[^[:space:]]+|SECRET[[:space:]]*[=:][[:space:]]*[^[:space:]]+|[Tt]oken[[:space:]]*[=:][[:space:]]*[^[:space:]]+|TOKEN[[:space:]]*[=:][[:space:]]*[^[:space:]]+'

# ac_post_guard_text <text> — refuse on any credential shape. Never echoes the hit.
ac_post_guard_text() {
    if printf '%s\n' "$1" | grep -Eq "$AC_POST_SECRET_ERE"; then
        ac_error "post: text matches a secret-pattern — refusing (rewrite without the credential-shaped token)"
        return 1
    fi
    return 0
}

# ac_post_redact — stdin filter for material mode; whole matching line replaced.
# Pattern passed via ENVIRON, not `awk -v` (house convention, see
# lib/hooks.sh:_ac_hook_render): `-v` interprets escape sequences in the
# value, which would mangle the `\.` inside the JWT alternative. ENVIRON
# passes the ERE byte-for-byte, keeping this in lockstep with the grep -E
# used by ac_post_guard_text.
ac_post_redact() {
    AC_POST_SECRET_ERE="$AC_POST_SECRET_ERE" awk '{ if ($0 ~ ENVIRON["AC_POST_SECRET_ERE"]) print "[redacted: secret-pattern]"; else print }'
}

# ac_post_x_len <text> — X counting: every URL is 23 chars (t.co wrapping).
ac_post_x_len() {
    printf '%s' "$1" \
      | sed -E 's#https?://[^[:space:]]+#XXXXXXXXXXXXXXXXXXXXXXX#g' \
      | wc -m | tr -d ' '
}

# ac_post_repo_url <project> <path> — public https URL for the draft, or "".
ac_post_repo_url() {
    local url suffix
    url=$(ac_registry_get "$1" git_remote); [[ -z "$url" ]] \
        && url=$(git -C "$2" remote get-url origin 2>/dev/null || true)
    [[ -z "$url" ]] && return 0
    url="${url%.git}"
    case "$url" in
        git@*) suffix="${url#git@}"; suffix="${suffix/:/\/}"; url="https://$suffix" ;;
    esac
    printf '%s\n' "$url"
}

# ac_post_material <project> — rc 0 material, rc 2 unknown project, rc 3 empty range.
ac_post_material() {
    local project="$1" path last range log url subjects draft s
    path=$(ac_registry_get "$project" path)
    if [[ -z "$path" || ! -d "$path/.git" ]]; then
        ac_error "post: unknown project or not a git repo: '$project'"
        return 2
    fi
    if last=$(ac_post_last_sha "$project"); then
        range="$last..HEAD"
    else
        range="HEAD~10..HEAD"
        # fewer than 11 commits and no prior post: take everything
        git -C "$path" rev-parse -q --verify HEAD~10 >/dev/null 2>&1 || range="HEAD"
    fi
    log=$(git -C "$path" log --format='%h %s%n%b' "$range" 2>/dev/null || true)
    if [[ -z "${log//[[:space:]]/}" ]]; then
        ac_error "post: nothing to post for '$project' since ${last:-the beginning}"
        return 3
    fi
    url=$(ac_post_repo_url "$project" "$path")
    printf '=== MATERIAL (%s, %s) ===\n' "$project" "$range"
    printf '%s\n' "$log" | ac_post_redact
    [[ -n "$url" ]] && printf 'repo: %s\n' "$url"
    printf '=== DRAFT ===\n'
    subjects=$(git -C "$path" log --format='%s' "$range" 2>/dev/null || true)
    draft="$project update:"
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        if [[ $(ac_post_x_len "$draft; $s ${url:+$url}") -le 280 ]]; then
            if [[ "$draft" == "$project update:" ]]; then draft="$draft $s"
            else draft="$draft; $s"; fi
        fi
    done <<< "$subjects"
    [[ -n "$url" ]] && draft="$draft $url"
    printf '%s\n' "$draft" | ac_post_redact
}

# ac_post_draft <project> <text> — the delivery step. Prepends a copy-ready
# entry to the project's git-ignored X-POSTS.md; the human pastes it into X.
# The paste is the publish gate — this lib never touches X at all.
ac_post_draft() {
    local project="$1" text="$2" path len last end range f tmp today
    path=$(ac_registry_get "$project" path)
    if [[ -z "$path" || ! -d "$path/.git" ]]; then
        ac_error "post: unknown project or not a git repo: '$project'"
        return 2
    fi
    ac_post_guard_text "$text" || return 1
    len=$(ac_post_x_len "$text")
    if (( len > 280 )); then
        ac_error "post: text is $len chars (X limit 280, URLs count as 23)"
        return 1
    fi
    end=$(git -C "$path" rev-parse --short HEAD 2>/dev/null) || { ac_error "post: '$project' has no commits yet — nothing to announce"; return 2; }
    last=$(ac_post_last_sha "$project" || true)
    range="${last:-start}..$end"
    # drafts stay out of the public repo: ensure the file is git-ignored
    if ! git -C "$path" check-ignore -q X-POSTS.md 2>/dev/null; then
        printf 'X-POSTS.md\n' >> "$path/.gitignore"
    fi
    f="$path/X-POSTS.md"
    today=$(date -u +%Y-%m-%d)
    tmp=$(mktemp)
    {
        printf '## %s — %s — drafted\n\n%s\n\n' "$today" "$range" "$text"
        [[ -f "$f" ]] && cat "$f"
    } > "$tmp"
    mv "$tmp" "$f"
    ac_post_log_append "$project" "-" "$range" "$text" "drafted"
    ac_info "post: drafted $range → $f (copy the top block into X)"
}
