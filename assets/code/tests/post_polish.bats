#!/usr/bin/env bats
# tests for the post-x v1 polish backlog (duty 2026-07-18) — the non-blocking
# findings deferred from the final review:
#   ssh:// remote arm · >=11-commit range · extra guard shapes ·
#   log-text backslash escaping · git-failure vs empty-range rc

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_POSTS_DIR="$ANTCRATE_HOME/posts"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"

    R="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$R"
    (
        cd "$R"
        git init -q -b master
        git config user.email "test@example.com"
        git config user.name  "test"
        echo initial > README.md
        git add README.md
        git commit -qm "initial"
    )
    export R
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_POSTS_DIR="'"$ANTCRATE_POSTS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/post.sh"
        '"$1"
}

reg() {  # reg <name> <path> [remote]
    jq -n --arg n "$1" --arg p "$2" --arg u "${3:-}" \
        '{projects:{($n):{path:$p,parent:"webapps",linked_nodes:[],git_remote:$u}}}' \
        > "$ANTCRATE_REGISTRY"
}

commits() {  # commits <n> — add n commits to $R
    local i
    for (( i = 0; i < $1; i++ )); do
        (cd "$R" && echo "c$i" >> log.txt && git add log.txt && git commit -qm "commit $i")
    done
}

# ---- ssh:// remote arm ----

@test "repo-url: ssh://git@host/user/repo.git becomes an https URL" {
    reg proj "$R" "ssh://git@github.com/zeppybabe/antcrate.git"
    run src 'ac_post_repo_url proj "'"$R"'"'
    [ "$status" -eq 0 ]
    [ "$output" = "https://github.com/zeppybabe/antcrate" ]
}

@test "repo-url: ssh:// with an explicit port drops the port" {
    reg proj "$R" "ssh://git@github.com:22/zeppybabe/antcrate.git"
    run src 'ac_post_repo_url proj "'"$R"'"'
    [ "$output" = "https://github.com/zeppybabe/antcrate" ]
}

@test "repo-url: ssh:// without a user is still converted" {
    reg proj "$R" "ssh://github.com/zeppybabe/antcrate.git"
    run src 'ac_post_repo_url proj "'"$R"'"'
    [ "$output" = "https://github.com/zeppybabe/antcrate" ]
}

@test "repo-url: scp-style git@ form still works" {
    reg proj "$R" "git@github.com:zeppybabe/antcrate.git"
    run src 'ac_post_repo_url proj "'"$R"'"'
    [ "$output" = "https://github.com/zeppybabe/antcrate" ]
}

@test "repo-url: an https remote passes through unchanged" {
    reg proj "$R" "https://github.com/zeppybabe/antcrate.git"
    run src 'ac_post_repo_url proj "'"$R"'"'
    [ "$output" = "https://github.com/zeppybabe/antcrate" ]
}

# ---- >=11-commit range ----

@test "material: a branch with 11+ commits and no prior post uses HEAD~10..HEAD" {
    commits 12
    reg proj "$R"
    run src 'ac_post_material proj'
    [ "$status" -eq 0 ]
    [[ "$output" == *"HEAD~10..HEAD"* ]]
}

@test "material: a branch with 11+ commits reports exactly 10 commits of material" {
    commits 12
    reg proj "$R"
    run src 'ac_post_material proj'
    # commit 11 is the newest; commit 1 is the 10th back. commit 0 must be excluded.
    [[ "$output" == *"commit 11"* ]]
    [[ "$output" != *"commit 0 "* ]]
}

@test "material: a short branch still takes everything" {
    commits 2
    reg proj "$R"
    run src 'ac_post_material proj'
    [ "$status" -eq 0 ]
    [[ "$output" == *"initial"* ]]
}

# ---- extra guard shapes ----
#
# Token fixtures are assembled at runtime from halves. Written out literally
# they are real credential SHAPES, so `antcrate commit`'s gitleaks pass refuses
# the file — correct behavior, and the reason this indirection exists.
GLPAT='gl''pat-ABCDEFGHIJKLMNOPQRST'
NPMTOK='np''m_abcdefghijklmnopqrstuvwxyz0123456789'

@test "guard: refuses a GitLab pat token" {
    run src 'ac_post_guard_text "shipped it '"$GLPAT"'"'
    [ "$status" -eq 1 ]
}

@test "guard: refuses an npm token" {
    run src 'ac_post_guard_text "shipped it '"$NPMTOK"'"'
    [ "$status" -eq 1 ]
}

@test "guard: refuses an AWS secret access key shape" {
    run src 'ac_post_guard_text "aws_secret_access_key = wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY"'
    [ "$status" -eq 1 ]
}

@test "guard: redact filter agrees with the guard on the new shapes" {
    run src 'printf "%s\n" "leak '"$GLPAT"'" | ac_post_redact'
    [[ "$output" == *"[redacted: secret-pattern]"* ]]
}

@test "guard: ordinary prose about a pat is not refused" {
    run src 'ac_post_guard_text "rewrote the glpat handling docs"'
    [ "$status" -eq 0 ]
}

# ---- log-text backslash escaping ----

@test "log: a literal backslash-n is stored distinguishably from a real newline" {
    reg proj "$R"
    # text containing the two characters \ and n, written with single quotes
    # so the shell hands them through untouched
    src "ac_post_log_append proj - a..b 'path C:\\temp\\new' drafted"
    line=$(tail -n 1 "$ANTCRATE_POSTS_DIR/proj.log")
    # the literal backslash is doubled on the way in; a real newline would be
    # a SINGLE backslash + n, so the two cases can be told apart on read-back
    [[ "$line" == *'C:\\temp\\new'* ]]
    [ "$(wc -l < "$ANTCRATE_POSTS_DIR/proj.log")" -eq 1 ]
}

@test "log: a real newline still collapses to one record as a single-backslash n" {
    reg proj "$R"
    src 'ac_post_log_append proj - a..b "line one
line two" drafted'
    line=$(tail -n 1 "$ANTCRATE_POSTS_DIR/proj.log")
    [[ "$line" == *'line one\nline two'* ]]
    [[ "$line" != *'line one\\nline two'* ]]
    [ "$(wc -l < "$ANTCRATE_POSTS_DIR/proj.log")" -eq 1 ]
}

# ---- git failure vs empty range ----

@test "material: an empty range returns rc 3" {
    reg proj "$R"
    # log a post whose range end is HEAD, so there is nothing newer
    src 'ac_post_log_append proj - "start..'"$(cd "$R" && git rev-parse --short HEAD)"'" "x" drafted'
    run src 'ac_post_material proj'
    [ "$status" -eq 3 ]
}

@test "material: a git failure is rc 2, not the empty-range rc 3" {
    reg proj "$R"
    # a recorded range end that does not exist makes git log fail outright
    src 'ac_post_log_append proj - "start..deadbeefdeadbeef" "x" drafted'
    run src 'ac_post_material proj'
    [ "$status" -eq 2 ]
}

@test "material: the git-failure message does not claim there is nothing to post" {
    reg proj "$R"
    src 'ac_post_log_append proj - "start..deadbeefdeadbeef" "x" drafted'
    run src 'ac_post_material proj'
    [[ "$output" != *"nothing to post"* ]]
}
