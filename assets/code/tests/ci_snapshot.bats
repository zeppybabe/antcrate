#!/usr/bin/env bats
# tests for the --ci baseline/audit-cadence helpers in lib/devops.sh
# (proposals ci-snapshot + ci-source-override, 2026-06-10).
#
# ~/.antcrate/ci-baseline.json shape:
#   .last     {ts, bats, sha, branch}  — updated on EVERY --ci PASS
#   .baseline {ts, bats, sha, branch}  — set only by --ci --snapshot (audit time)
# The +100 audit cadence = baseline.bats + 100, surfaced via the status line.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    BASEFILE="$ANTCRATE_HOME/ci-baseline.json"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_REGISTRY='$ANTCRATE_REGISTRY'
        export ANTCRATE_ROOT='$ANTCRATE_ROOT'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/registry.sh'
        . '$LIB/devops.sh'
        $1
    "
}

# minimal antcrate-shaped tree for resolve tests
mk_tree() {
    local d="$1"
    mkdir -p "$d/lib" "$d/tests" "$d/bin"
    touch "$d/bin/antcrate"
}

@test "record: first PASS creates baseline file with .last and no .baseline" {
    run src 'ac_devops_ci_record 560 "'"$BATS_TEST_TMPDIR"'"'
    [ "$status" -eq 0 ]
    [ -f "$BASEFILE" ]
    [ "$(jq -r '.last.bats' "$BASEFILE")" = "560" ]
    [ "$(jq -r '.baseline' "$BASEFILE")" = "null" ]
}

@test "record: --snapshot sets .baseline equal to .last" {
    run src 'ac_devops_ci_record 560 "'"$BATS_TEST_TMPDIR"'" --snapshot'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.baseline.bats' "$BASEFILE")" = "560" ]
    [ "$(jq -r '.last.bats' "$BASEFILE")" = "560" ]
}

@test "record: later runs update .last and PRESERVE .baseline" {
    src 'ac_devops_ci_record 560 "'"$BATS_TEST_TMPDIR"'" --snapshot'
    run src 'ac_devops_ci_record 575 "'"$BATS_TEST_TMPDIR"'"'
    [ "$status" -eq 0 ]
    [ "$(jq -r '.last.bats' "$BASEFILE")" = "575" ]
    [ "$(jq -r '.baseline.bats' "$BASEFILE")" = "560" ]
}

@test "resolve: explicit --source path that looks like an antcrate tree is accepted" {
    mk_tree "$BATS_TEST_TMPDIR/alt"
    run src 'ac_devops_ci_resolve_src "'"$BATS_TEST_TMPDIR"'/alt"'
    [ "$status" -eq 0 ]
    [ "$output" = "$BATS_TEST_TMPDIR/alt" ]
}

@test "resolve: --source path missing tests/ is refused exit 2" {
    mkdir -p "$BATS_TEST_TMPDIR/notree/lib"
    run src 'ac_devops_ci_resolve_src "'"$BATS_TEST_TMPDIR"'/notree"'
    [ "$status" -eq 2 ]
}

@test "audit status line: shows last count against baseline+100 due point" {
    src 'ac_devops_ci_record 498 "'"$BATS_TEST_TMPDIR"'" --snapshot'
    src 'ac_devops_ci_record 560 "'"$BATS_TEST_TMPDIR"'"'
    run src 'ac_devops_audit_status_line'
    [ "$status" -eq 0 ]
    [[ "$output" == *"560"* ]]
    [[ "$output" == *"598"* ]]
}

@test "audit status line: overdue baseline says AUDIT DUE" {
    src 'ac_devops_ci_record 498 "'"$BATS_TEST_TMPDIR"'" --snapshot'
    src 'ac_devops_ci_record 601 "'"$BATS_TEST_TMPDIR"'"'
    run src 'ac_devops_audit_status_line'
    [ "$status" -eq 0 ]
    [[ "$output" == *"AUDIT DUE"* ]]
}

@test "audit status line: no baseline file -> hint to snapshot" {
    run src 'ac_devops_audit_status_line'
    [ "$status" -eq 0 ]
    [[ "$output" == *"antcrate self ci --snapshot"* ]]
}
