#!/usr/bin/env bats
# tests/quarantine.bats — verify the quarantine pivot end-to-end.

load test_helper

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    BIN="$BATS_TEST_DIRNAME/../bin/antcrate"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/lock.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/quarantine.sh"
        '"$1"
}

# ---------------------------------------------------------------------------
# _ac_quarantine_capture
# ---------------------------------------------------------------------------

@test "capture: src is moved (gone from original), tarball + manifest created" {
    local src_dir="$BATS_TEST_TMPDIR/mydata"
    mkdir -p "$src_dir"
    echo "hello" > "$src_dir/file.txt"

    src '_ac_quarantine_capture _generic "'"$src_dir"'" test-op my-label'

    [ ! -e "$src_dir" ]
    local qbase="$ANTCRATE_HOME/quarantine/_generic"
    local tarball; tarball=$(find "$qbase" -name "payload.tar.gz" | head -n1)
    [ -n "$tarball" ]
    [ -f "$tarball" ]
    local manifest; manifest=$(find "$qbase" -name "manifest.json" | head -n1)
    [ -n "$manifest" ]
    [ -f "$manifest" ]
}

@test "capture: sha256 in manifest matches tarball" {
    local src_dir="$BATS_TEST_TMPDIR/mydata2"
    mkdir -p "$src_dir"
    echo "content" > "$src_dir/f.txt"

    src '_ac_quarantine_capture _generic "'"$src_dir"'" hash-op lbl'

    local manifest; manifest=$(find "$ANTCRATE_HOME/quarantine/_generic" -name "manifest.json" | head -n1)
    local tarball; tarball=$(dirname "$manifest")/payload.tar.gz

    local expected; expected=$(t_sha256 "$tarball" | awk '{print $1}')
    local recorded; recorded=$(jq -r '.sha256' "$manifest")
    [ "$expected" = "$recorded" ]
}

@test "capture: original_path recorded in manifest" {
    local src_dir="$BATS_TEST_TMPDIR/mydata3"
    mkdir -p "$src_dir"
    echo "x" > "$src_dir/g.txt"

    src '_ac_quarantine_capture _generic "'"$src_dir"'" path-op lbl'

    local manifest; manifest=$(find "$ANTCRATE_HOME/quarantine/_generic" -name "manifest.json" | head -n1)
    local orig; orig=$(jq -r '.original_path' "$manifest")
    [ "$orig" = "$src_dir" ]
}

@test "capture: project, op, label in manifest" {
    local src_dir="$BATS_TEST_TMPDIR/mydata4"
    mkdir -p "$src_dir"

    src '_ac_quarantine_capture myproject "'"$src_dir"'" test-op my-label'

    local manifest; manifest=$(find "$ANTCRATE_HOME/quarantine/myproject" -name "manifest.json" | head -n1)
    [ "$(jq -r '.project' "$manifest")" = "myproject" ]
    [ "$(jq -r '.op'      "$manifest")" = "test-op" ]
    [ "$(jq -r '.label'   "$manifest")" = "my-label" ]
    [ "$(jq -r '.captured_by' "$manifest")" = "quarantine-capture" ]
}

@test "capture: label is sanitized (special chars become dashes)" {
    local src_dir="$BATS_TEST_TMPDIR/mydata5"
    mkdir -p "$src_dir"

    src '_ac_quarantine_capture _generic "'"$src_dir"'" op "bad label/with:chars"'

    local qbase="$ANTCRATE_HOME/quarantine/_generic"
    local found; found=$(find "$qbase" -maxdepth 1 -type d | grep -v "^$qbase\$" | head -n1)
    local dirname; dirname=$(basename "$found")
    [[ "$dirname" =~ __op__bad-label ]]
}

@test "capture: refuses cleanly on missing src (no half-capture dir)" {
    run src '_ac_quarantine_capture _generic "'"$BATS_TEST_TMPDIR/nonexistent"'" op lbl'
    [ "$status" -ne 0 ]
    [ ! -d "$ANTCRATE_HOME/quarantine/_generic" ]
}

@test "capture: uncompressed payload removed after tar (only tarball remains)" {
    local src_dir="$BATS_TEST_TMPDIR/mydata6"
    mkdir -p "$src_dir"
    echo "data" > "$src_dir/d.txt"

    src '_ac_quarantine_capture _generic "'"$src_dir"'" op lbl'

    local qbase="$ANTCRATE_HOME/quarantine/_generic"
    local qdir; qdir=$(find "$qbase" -maxdepth 1 -type d | grep -v "^$qbase\$" | head -n1)
    [ ! -e "$qdir/payload" ]
    [ -f "$qdir/payload.tar.gz" ]
}

# ---------------------------------------------------------------------------
# _ac_unlink_internal
# ---------------------------------------------------------------------------

@test "unlink_internal: removes a path inside ANTCRATE_HOME" {
    local target="$ANTCRATE_HOME/somefile.txt"
    echo "data" > "$target"

    src '_ac_unlink_internal "'"$target"'"'
    [ ! -e "$target" ]
}

@test "unlink_internal: removes a dir inside ANTCRATE_HOME" {
    local target="$ANTCRATE_HOME/somedir"
    mkdir -p "$target/sub"

    src '_ac_unlink_internal "'"$target"'"'
    [ ! -e "$target" ]
}

@test "unlink_internal: REFUSES a path outside ANTCRATE_HOME" {
    local outside="$BATS_TEST_TMPDIR/outside.txt"
    echo "x" > "$outside"

    run src '_ac_unlink_internal "'"$outside"'"'
    [ "$status" -ne 0 ]
    [ -e "$outside" ]
}

@test "unlink_internal: refuses /tmp path" {
    local tmp_path; tmp_path=$(mktemp)

    run src '_ac_unlink_internal "'"$tmp_path"'"'
    [ "$status" -ne 0 ]
    [ -e "$tmp_path" ]
    rm -f "$tmp_path"
}

@test "unlink_internal: allows .git-resident antcrate artifact (pipe.paused)" {
    local target="$ANTCRATE_HOME/pipe.paused"
    touch "$target"

    src '_ac_unlink_internal "'"$target"'"'
    [ ! -e "$target" ]
}

@test "unlink_internal: REFUSES empty path" {
    run src '_ac_unlink_internal ""'
    [ "$status" -ne 0 ]
}

@test "unlink_internal: REFUSES dotdot traversal (ANTCRATE_HOME/../../etc/x)" {
    local outside="$ANTCRATE_HOME/../../tmp/ac_attack_$$"
    run src '_ac_unlink_internal "'"$outside"'"'
    [ "$status" -ne 0 ]
}

@test "unlink_internal: REFUSES string-prefix match (ANTCRATE_HOME_evil/x)" {
    local evil_dir="${ANTCRATE_HOME}_evil"
    mkdir -p "$evil_dir"
    echo "precious" > "$evil_dir/precious.txt"
    run src '_ac_unlink_internal "'"$evil_dir/precious.txt"'"'
    [ "$status" -ne 0 ]
    [ -f "$evil_dir/precious.txt" ]
    rm -rf "$evil_dir"
}

@test "unlink_internal: REFUSES symlink whose target is outside ANTCRATE_HOME" {
    local outside_dir; outside_dir=$(mktemp -d)
    echo "precious" > "$outside_dir/precious.txt"
    ln -s "$outside_dir" "$ANTCRATE_HOME/evil_link"
    run src '_ac_unlink_internal "'"$ANTCRATE_HOME/evil_link/precious.txt"'"'
    [ "$status" -ne 0 ]
    [ -f "$outside_dir/precious.txt" ]
    rm -rf "$outside_dir"
}

@test "unlink_internal: allows antcrate-hook-bypass inside a .git dir" {
    local gitdir; gitdir=$(mktemp -d)
    mkdir -p "$gitdir/.git"
    touch "$gitdir/.git/antcrate-hook-bypass"
    src '_ac_unlink_internal "'"$gitdir/.git/antcrate-hook-bypass"'"'
    [ ! -e "$gitdir/.git/antcrate-hook-bypass" ]
    rm -rf "$gitdir"
}

@test "unlink_internal: REFUSES antcrate-hook-bypass outside a .git dir" {
    local nodir; nodir=$(mktemp -d)
    echo "precious" > "$nodir/antcrate-hook-bypass"
    run src '_ac_unlink_internal "'"$nodir/antcrate-hook-bypass"'"'
    [ "$status" -ne 0 ]
    [ -f "$nodir/antcrate-hook-bypass" ]
    rm -rf "$nodir"
}

@test "unlink_internal: REFUSES pipe.paused outside ANTCRATE_HOME" {
    local nodir; nodir=$(mktemp -d)
    echo "precious" > "$nodir/pipe.paused"
    run src '_ac_unlink_internal "'"$nodir/pipe.paused"'"'
    [ "$status" -ne 0 ]
    [ -f "$nodir/pipe.paused" ]
    rm -rf "$nodir"
}

# ---------------------------------------------------------------------------
# --quarantine-restore
# ---------------------------------------------------------------------------

@test "restore: brings payload back to original_path" {
    local src_dir="$BATS_TEST_TMPDIR/restore_src"
    mkdir -p "$src_dir"
    echo "restore-me" > "$src_dir/r.txt"

    src '_ac_quarantine_capture _generic "'"$src_dir"'" restore-op lbl'

    local manifest; manifest=$(find "$ANTCRATE_HOME/quarantine/_generic" -name "manifest.json" | head -n1)
    local qdir; qdir=$(dirname "$manifest")
    local ts; ts=$(basename "$qdir" | cut -d_ -f1)

    run bash -c '
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        "'"$BATS_TEST_DIRNAME/../bin/antcrate"'" --quarantine-restore _generic --at "'"$ts"'"
    '
    [ "$status" -eq 0 ]
    [ -d "$src_dir" ]
    [ -f "$src_dir/r.txt" ]
}

@test "restore: REFUSES when original_path already exists" {
    local src_dir="$BATS_TEST_TMPDIR/restore_conflict"
    mkdir -p "$src_dir"
    echo "original" > "$src_dir/f.txt"

    src '_ac_quarantine_capture _generic "'"$src_dir"'" restore-op lbl'

    # recreate the path so it conflicts
    mkdir -p "$src_dir"

    local manifest; manifest=$(find "$ANTCRATE_HOME/quarantine/_generic" -name "manifest.json" | head -n1)
    local qdir; qdir=$(dirname "$manifest")
    local ts; ts=$(basename "$qdir" | cut -d_ -f1)

    run bash -c '
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        "'"$BATS_TEST_DIRNAME/../bin/antcrate"'" --quarantine-restore _generic --at "'"$ts"'"
    '
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# --quarantine-list
# ---------------------------------------------------------------------------

@test "quarantine-list: empty → friendly message" {
    run bash -c '
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        "'"$BATS_TEST_DIRNAME/../bin/antcrate"'" --quarantine-list _generic
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"No quarantine"* ]] || [[ "$output" == *"no entries"* ]] || [[ "$output" == *"empty"* ]]
}

@test "quarantine-list: with 2 entries shows both in DESC order" {
    local s1="$BATS_TEST_TMPDIR/q1" s2="$BATS_TEST_TMPDIR/q2"
    mkdir -p "$s1" "$s2"
    echo "a" > "$s1/a.txt"
    echo "b" > "$s2/b.txt"

    src '_ac_quarantine_capture listproj "'"$s1"'" op1 lbl1'
    sleep 1
    src '_ac_quarantine_capture listproj "'"$s2"'" op2 lbl2'

    run bash -c '
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        "'"$BATS_TEST_DIRNAME/../bin/antcrate"'" --quarantine-list listproj
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"op2"* ]]
    [[ "$output" == *"op1"* ]]
    # DESC: op2 line must appear before op1 line
    local pos_op2 pos_op1
    pos_op2=$(echo "$output" | grep -n "op2" | head -1 | cut -d: -f1)
    pos_op1=$(echo "$output" | grep -n "op1" | head -1 | cut -d: -f1)
    [ "$pos_op2" -lt "$pos_op1" ]
}

# ---------------------------------------------------------------------------
# Integration: ac_devops_remove quarantines instead of destroying
# ---------------------------------------------------------------------------

@test "integration: ac_devops_remove quarantines project (tarball exists, original gone)" {
    local proj_dir="$ANTCRATE_ROOT/demolish"
    mkdir -p "$proj_dir"
    echo "data" > "$proj_dir/file.txt"

    run bash -c '
        set -eo pipefail
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
            . "'"$LIB"'/log.sh"
        . "'"$LIB"'/lock.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/quarantine.sh"
        . "'"$LIB"'/scaffold.sh"
        . "'"$LIB"'/subbranch.sh"
        . "'"$LIB"'/devops.sh"
        ac_registry_init
        ac_registry_upsert demolish "'"$proj_dir"'" scripts ""
        ac_devops_remove demolish
    '
    [ "$status" -eq 0 ]
    [ ! -d "$proj_dir" ]
    local tarball; tarball=$(find "$ANTCRATE_HOME/quarantine/demolish" -name "payload.tar.gz" 2>/dev/null | head -n1)
    [ -n "$tarball" ]
    [ -f "$tarball" ]
}

@test "integration: ac_safety_safe_rm quarantines path inside allowed zone" {
    local target="$ANTCRATE_ROOT/safefiles"
    mkdir -p "$target"
    echo "safe" > "$target/safe.txt"

    run bash -c '
        set -eo pipefail
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/lock.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/quarantine.sh"
        ac_safety_safe_rm "'"$target"'"
    '
    [ "$status" -eq 0 ]
    [ ! -e "$target" ]
    local tarball; tarball=$(find "$ANTCRATE_HOME/quarantine/_generic" -name "payload.tar.gz" 2>/dev/null | head -n1)
    [ -n "$tarball" ]
}

# ---------------------------------------------------------------------------
# No --quarantine-purge flag
# ---------------------------------------------------------------------------

@test "no --quarantine-purge: unknown flag errors" {
    run bash -c '
        export ANTCRATE_CANARY_DISABLE=1
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        "'"$BATS_TEST_DIRNAME/../bin/antcrate"'" --quarantine-purge x
    '
    [ "$status" -ne 0 ]
}

@test "unlink_internal: still refuses non-hook .git internals" {
    local git_dir="$BATS_TEST_TMPDIR/repo/.git"
    mkdir -p "$git_dir"
    local target="$git_dir/config"
    echo "[core]" > "$target"

    run src '_ac_unlink_internal "'"$target"'"'
    [ "$status" -ne 0 ]
    [ -e "$target" ]
}

@test "unlink_internal: allows antcrate-* scratch dir under system tmp" {
    local scratch; scratch=$(mktemp -d -t antcrate-test.XXXXXX)
    touch "$scratch/junk"

    src '_ac_unlink_internal "'"$scratch"'"'
    [ ! -e "$scratch" ]
}

@test "unlink_internal: refuses non-antcrate-named tmp dir" {
    local scratch; scratch=$(mktemp -d -t other-test.XXXXXX)

    run src '_ac_unlink_internal "'"$scratch"'"'
    [ "$status" -ne 0 ]
    [ -e "$scratch" ]
    rmdir "$scratch"
}

# ---------------------------------------------------------------------------
# _ac_unlink_internal — the opt-in dev/context zone
# (duty 2026-07-25, audit finding E)
#
# devsync.sh mirrors a project's local-only root records into $p/dev/context/
# and must be able to replace or drop an entry. That path lives inside a USER
# PROJECT TREE, which none of the three standing allowances cover, so devsync
# was calling `rm -rf -- "$dst"` raw — an unaudited rm $VAR site against user
# data, against rule #16.
#
# The zone is OPT-IN: it only opens when the caller names the repo root it is
# operating on, and only for paths strictly BELOW <root>/dev/context. Passing a
# root must not widen anything else.
# ---------------------------------------------------------------------------

@test "unlink: refuses a dev/context path when no repo root is passed" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context"
    echo "records" > "$P/dev/context/CLAUDE.md"
    run src "_ac_unlink_internal '$P/dev/context/CLAUDE.md'"
    [ "$status" -ne 0 ]
    [ -f "$P/dev/context/CLAUDE.md" ]
}

@test "unlink: removes a dev/context path when its repo root is passed" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context"
    echo "records" > "$P/dev/context/CLAUDE.md"
    run src "_ac_unlink_internal '$P/dev/context/CLAUDE.md' '$P'"
    [ "$status" -eq 0 ]
    [ ! -e "$P/dev/context/CLAUDE.md" ]
}

@test "unlink: removes a nested dev/context subtree when the repo root is passed" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context/.claude/agents"
    echo "agent" > "$P/dev/context/.claude/agents/cody.md"
    run src "_ac_unlink_internal '$P/dev/context/.claude' '$P'"
    [ "$status" -eq 0 ]
    [ ! -e "$P/dev/context/.claude" ]
    [ -d "$P/dev/context" ]
}

@test "unlink: refuses the dev/context directory itself" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context"
    run src "_ac_unlink_internal '$P/dev/context' '$P'"
    [ "$status" -ne 0 ]
    [ -d "$P/dev/context" ]
}

@test "unlink: refuses a path inside the repo but outside dev/context" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/src" "$P/dev/context"
    echo "code" > "$P/src/main.sh"
    run src "_ac_unlink_internal '$P/src/main.sh' '$P'"
    [ "$status" -ne 0 ]
    [ -f "$P/src/main.sh" ]
}

@test "unlink: refuses a dev/context path belonging to a DIFFERENT repo" {
    A="$ANTCRATE_ROOT/alpha"; B="$ANTCRATE_ROOT/beta"
    mkdir -p "$A/dev/context" "$B/dev/context"
    echo "beta records" > "$B/dev/context/CLAUDE.md"
    run src "_ac_unlink_internal '$B/dev/context/CLAUDE.md' '$A'"
    [ "$status" -ne 0 ]
    [ -f "$B/dev/context/CLAUDE.md" ]
}

@test "unlink: refuses a .. escape out of the dev/context zone" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context" "$P/src"
    echo "code" > "$P/src/main.sh"
    run src "_ac_unlink_internal '$P/dev/context/../../src/main.sh' '$P'"
    [ "$status" -ne 0 ]
    [ -f "$P/src/main.sh" ]
}

@test "unlink: passing a repo root does not widen the other zones" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context"
    echo "elsewhere" > "$BATS_TEST_TMPDIR/loose.txt"
    run src "_ac_unlink_internal '$BATS_TEST_TMPDIR/loose.txt' '$P'"
    [ "$status" -ne 0 ]
    [ -f "$BATS_TEST_TMPDIR/loose.txt" ]
}

@test "unlink: refuses a repo root that is not an existing directory" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context"
    echo "records" > "$P/dev/context/CLAUDE.md"
    run src "_ac_unlink_internal '$P/dev/context/CLAUDE.md' '$ANTCRATE_ROOT/no-such-repo'"
    [ "$status" -ne 0 ]
    [ -f "$P/dev/context/CLAUDE.md" ]
}

@test "unlink: refuses / as a repo root" {
    P="$ANTCRATE_ROOT/proj"
    mkdir -p "$P/dev/context"
    echo "records" > "$P/dev/context/CLAUDE.md"
    run src "_ac_unlink_internal '$P/dev/context/CLAUDE.md' '/'"
    [ "$status" -ne 0 ]
    [ -f "$P/dev/context/CLAUDE.md" ]
}

@test "unlink: the ANTCRATE_HOME zone still works with no root argument" {
    mkdir -p "$ANTCRATE_HOME/scratch"
    run src "_ac_unlink_internal '$ANTCRATE_HOME/scratch'"
    [ "$status" -eq 0 ]
    [ ! -e "$ANTCRATE_HOME/scratch" ]
}
