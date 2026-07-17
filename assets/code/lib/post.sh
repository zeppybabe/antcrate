#!/usr/bin/env bash
# antcrate :: lib/post.sh — project update publishing on X (web-intent handoff, v1).
#
# Design: docs/superpowers/specs/2026-07-17-x-post-design.md
#  - material mode emits secret-guarded git material; an AI (or human) words the
#    post; --open launches Firefox at x.com/intent/post pre-filled. The HUMAN
#    click on Post is the publish gate — this lib never scripts the X page.
#  - ~/.config/antcrate/x-accounts.json is HUMAN-ONLY (Rule #13): read, never write.

# ac_post_accounts_sample — print a copyable sample config to stderr.
ac_post_accounts_sample() {
    cat >&2 <<'SAMPLE'
post: create ~/.config/antcrate/x-accounts.json yourself (human-only file), e.g.:
{
  "accounts": { "@antcrate": { "profile": "x-antcrate" } },
  "projects": { "antcrate": "@antcrate" }
}
SAMPLE
}

# ac_post_account_resolve <project> [handle] — stdout "handle<TAB>profile".
# rc 2 on missing config / unmapped project / unknown handle.
ac_post_account_resolve() {
    local project="$1" handle="${2:-}" profile
    if [[ ! -f "$ANTCRATE_X_ACCOUNTS" ]]; then
        ac_error "post: missing $ANTCRATE_X_ACCOUNTS"
        ac_post_accounts_sample
        return 2
    fi
    if [[ -z "$handle" ]]; then
        handle=$(jq -r --arg p "$project" '.projects[$p] // empty' "$ANTCRATE_X_ACCOUNTS") || handle=""
        if [[ -z "$handle" ]]; then
            ac_error "post: no default account for '$project' in x-accounts.json (use --as @handle or add a projects entry)"
            return 2
        fi
    fi
    profile=$(jq -r --arg h "$handle" '.accounts[$h].profile // empty' "$ANTCRATE_X_ACCOUNTS") || profile=""
    if [[ -z "$profile" ]]; then
        ac_error "post: account '$handle' has no profile in x-accounts.json"
        return 2
    fi
    printf '%s\t%s\n' "$handle" "$profile"
}

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

# ac_post_log_append <project> <handle> <range> <text> — append-only record.
ac_post_log_append() {
    local project="$1" handle="$2" range="$3" text="$4" f
    f=$(ac_post_log_file "$project")
    mkdir -p "$ANTCRATE_POSTS_DIR"
    text="${text//$'\t'/ }"        # tabs are the field separator
    text="${text//$'\n'/\\n}"      # one record per line
    printf '%s\t%s\t%s\topened\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$handle" "$range" "$text" >> "$f"
}

# ac_post_log_show <project> — newest first; rc 1 if no log yet.
ac_post_log_show() {
    local f
    f=$(ac_post_log_file "$1")
    if [[ ! -s "$f" ]]; then ac_error "post: no posts logged for '$1' yet"; return 1; fi
    tac "$f" | awk -F'\t' '{ printf "%s  %s  %s  [%s]  %s\n", $1, $2, $3, $4, $5 }'
}
