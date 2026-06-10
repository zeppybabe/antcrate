#!/usr/bin/env bats
# tests for lib/selfcheck.sh — self-source persistence health check
#
# ac_selfcheck verifies the antcrate dev tree survived: registry path on disk,
# skill link resolving, git repo present, unpushed/uncommitted work, backup age.
# Exit: 0 = all ok, 1 = critical FAIL, 2 = warnings only.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_SELF_NAME="selfproj"
    export ANTCRATE_SKILL_LINK="$BATS_TEST_TMPDIR/skill-link"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT'
        export ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        export ANTCRATE_SELF_NAME='$ANTCRATE_SELF_NAME'
        export ANTCRATE_SKILL_LINK='$ANTCRATE_SKILL_LINK'
        export ANTCRATE_BACKUP_DIR='$ANTCRATE_BACKUP_DIR'
        . '$LIB/log.sh'
        . '$LIB/registry.sh'
        . '$LIB/selfcheck.sh'
        $1
    "
}

# healthy fixture: registered project with git repo + upstream, skill link, fresh backup
mk_healthy() {
    local p="$ANTCRATE_ROOT/selfproj"
    mkdir -p "$p"
    git init -q "$p"
    git -C "$p" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git init -q --bare "$BATS_TEST_TMPDIR/selfproj.remote"
    git -C "$p" remote add origin "$BATS_TEST_TMPDIR/selfproj.remote"
    git -C "$p" push -q -u origin HEAD
    src 'ac_registry_upsert "selfproj" "'"$p"'" "scripts" ""'
    ln -s "$p" "$ANTCRATE_SKILL_LINK"
    mkdir -p "$ANTCRATE_BACKUP_DIR/selfproj"
    touch "$ANTCRATE_BACKUP_DIR/selfproj/selfproj-20990101T000000Z.tar.gz"
}

@test "selfcheck: healthy tree passes all checks, exit 0" {
    mk_healthy
    run src 'ac_selfcheck'
    [ "$status" -eq 0 ]
    [[ "$output" == *"source path"* ]]
    [[ "$output" == *"result: OK"* ]]
}

@test "selfcheck: missing source path is critical FAIL, exit 1" {
    src 'ac_registry_upsert "selfproj" "/nonexistent/selfproj" "scripts" ""'
    ln -s "/nonexistent/selfproj" "$ANTCRATE_SKILL_LINK"
    run src 'ac_selfcheck'
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"/nonexistent/selfproj"* ]]
}

@test "selfcheck: unregistered self project is critical FAIL, exit 1" {
    run src 'ac_selfcheck'
    [ "$status" -eq 1 ]
    [[ "$output" == *"not registered"* ]]
}

@test "selfcheck: dangling skill link is critical FAIL, exit 1" {
    mk_healthy
    rm "$ANTCRATE_SKILL_LINK"
    ln -s "/nonexistent/target" "$ANTCRATE_SKILL_LINK"
    run src 'ac_selfcheck'
    [ "$status" -eq 1 ]
    [[ "$output" == *"skill link"* ]]
    [[ "$output" == *"FAIL"* ]]
}

@test "selfcheck: missing skill link is critical FAIL, exit 1" {
    mk_healthy
    rm "$ANTCRATE_SKILL_LINK"
    run src 'ac_selfcheck'
    [ "$status" -eq 1 ]
    [[ "$output" == *"skill link"* ]]
}

@test "selfcheck: skill entry as real directory (no symlink) is ok" {
    mk_healthy
    rm "$ANTCRATE_SKILL_LINK"
    mkdir -p "$ANTCRATE_SKILL_LINK"
    run src 'ac_selfcheck'
    [ "$status" -eq 0 ]
}

@test "selfcheck: missing .git is critical FAIL, exit 1" {
    mk_healthy
    rm -rf "$ANTCRATE_ROOT/selfproj/.git"
    run src 'ac_selfcheck'
    [ "$status" -eq 1 ]
    [[ "$output" == *"git repo"* ]]
    [[ "$output" == *"FAIL"* ]]
}

@test "selfcheck: unpushed commits warn, exit 2" {
    mk_healthy
    git -C "$ANTCRATE_ROOT/selfproj" -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m "local only"
    run src 'ac_selfcheck'
    [ "$status" -eq 2 ]
    [[ "$output" == *"unpushed"* ]]
    [[ "$output" == *"WARN"* ]]
}

@test "selfcheck: uncommitted changes warn, exit 2" {
    mk_healthy
    echo dirty > "$ANTCRATE_ROOT/selfproj/dirty.txt"
    run src 'ac_selfcheck'
    [ "$status" -eq 2 ]
    [[ "$output" == *"uncommitted"* ]]
    [[ "$output" == *"WARN"* ]]
}

@test "selfcheck: no backup found warns, exit 2" {
    mk_healthy
    rm -rf "$ANTCRATE_BACKUP_DIR/selfproj"
    run src 'ac_selfcheck'
    [ "$status" -eq 2 ]
    [[ "$output" == *"backup"* ]]
    [[ "$output" == *"WARN"* ]]
}

@test "selfcheck: stale backup warns, exit 2" {
    mk_healthy
    touch -d "3 days ago" "$ANTCRATE_BACKUP_DIR/selfproj/selfproj-20990101T000000Z.tar.gz"
    run src 'ac_selfcheck'
    [ "$status" -eq 2 ]
    [[ "$output" == *"stale"* ]]
}

@test "selfcheck: stale-backup threshold honors env override" {
    mk_healthy
    touch -d "3 days ago" "$ANTCRATE_BACKUP_DIR/selfproj/selfproj-20990101T000000Z.tar.gz"
    run src 'ANTCRATE_SELFCHECK_BACKUP_MAX_AGE_HOURS=100 ac_selfcheck'
    [ "$status" -eq 0 ]
}

@test "selfcheck: warnings do not mask a critical FAIL (exit 1 wins)" {
    mk_healthy
    rm -rf "$ANTCRATE_ROOT/selfproj/.git"
    rm -rf "$ANTCRATE_BACKUP_DIR/selfproj"
    run src 'ac_selfcheck'
    [ "$status" -eq 1 ]
}

@test "selfcheck: --quiet prints single summary line only" {
    mk_healthy
    run src 'ac_selfcheck --quiet'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"OK"* ]]
}

@test "selfcheck: --quiet still exits 1 on critical FAIL" {
    src 'ac_registry_upsert "selfproj" "/nonexistent/selfproj" "scripts" ""'
    ln -s "/nonexistent/selfproj" "$ANTCRATE_SKILL_LINK"
    run src 'ac_selfcheck --quiet'
    [ "$status" -eq 1 ]
}
