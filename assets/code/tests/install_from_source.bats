#!/usr/bin/env bats
# tests for ac_devops_install_from_source in lib/devops.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/devops.sh"
        '"$1"
}

register_antcrate() {
    local p="$1"
    mkdir -p "$p"
    src "ac_registry_init; ac_registry_upsert antcrate '$p' claude-skills \"\""
}

@test "install-from-source: refuses exit 1 when antcrate not registered" {
    src "ac_registry_init"
    run src "ac_devops_install_from_source"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not registered"* ]]
}

@test "install-from-source: refuses exit 1 when install.sh missing" {
    local p="$BATS_TEST_TMPDIR/ac_src"
    register_antcrate "$p"
    run src "ac_devops_install_from_source"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
}

@test "install-from-source: refuses exit 1 when install.sh not executable" {
    local p="$BATS_TEST_TMPDIR/ac_src"
    register_antcrate "$p"
    printf '#!/usr/bin/env bash\necho STUB-OK\n' > "$p/install.sh"
    chmod -x "$p/install.sh"
    run src "ac_devops_install_from_source"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not executable"* ]]
}

@test "install-from-source: success runs install.sh and exits 0" {
    local p="$BATS_TEST_TMPDIR/ac_src"
    register_antcrate "$p"
    printf '#!/usr/bin/env bash\necho STUB-OK\n' > "$p/install.sh"
    chmod +x "$p/install.sh"
    run src "ac_devops_install_from_source"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB-OK"* ]]
}

@test "install-from-source: idempotent — second call also succeeds" {
    local p="$BATS_TEST_TMPDIR/ac_src"
    register_antcrate "$p"
    printf '#!/usr/bin/env bash\necho STUB-OK\n' > "$p/install.sh"
    chmod +x "$p/install.sh"
    src "ac_devops_install_from_source"
    run src "ac_devops_install_from_source"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB-OK"* ]]
}

@test "install-from-source: probes nested assets/code/install.sh when root install.sh absent" {
    # Skill-style layout: install.sh lives at <root>/assets/code/install.sh, not at <root>/install.sh
    local p="$BATS_TEST_TMPDIR/ac_src"
    register_antcrate "$p"
    mkdir -p "$p/assets/code"
    printf '#!/usr/bin/env bash\necho NESTED-OK\n' > "$p/assets/code/install.sh"
    chmod +x "$p/assets/code/install.sh"
    run src "ac_devops_install_from_source"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NESTED-OK"* ]]
}

@test "install-from-source: ignores ANTCRATE_SELFSRC — uses registry path" {
    local p="$BATS_TEST_TMPDIR/ac_src"
    register_antcrate "$p"
    printf '#!/usr/bin/env bash\necho STUB-OK\n' > "$p/install.sh"
    chmod +x "$p/install.sh"
    run bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_SELFSRC=/nonexistent/path
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/devops.sh"
        ac_devops_install_from_source'
    [ "$status" -eq 0 ]
    [[ "$output" == *"STUB-OK"* ]]
}
