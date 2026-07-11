#!/usr/bin/env bats
# end-to-end: scaffold + subbranch atomicity (no git push, no daemon)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_TEMPLATES="$BATS_TEST_DIRNAME/../templates"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
}

src() {
    bash -c '
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_TEMPLATES="'"$ANTCRATE_TEMPLATES"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/lock.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/scaffold.sh"
        . "'"$LIB"'/subbranch.sh"
        '"$1"
}

@test "start creates project dir and registry entry" {
    run src 'ac_action_start coolgif webapps html css js
             ls "$ANTCRATE_ROOT/webapps/coolgif"
             ac_registry_get coolgif path'
    [ "$status" -eq 0 ]
    [[ "$output" == *"coolgif"* ]]
    [[ "$output" == *"$ANTCRATE_ROOT/webapps/coolgif"* ]]
}

@test "start with html,css,js meta stubs the three files" {
    run src 'ac_action_start coolgif webapps html css js
             test -f "$ANTCRATE_ROOT/webapps/coolgif/index.html" && echo HTML
             test -f "$ANTCRATE_ROOT/webapps/coolgif/style.css"  && echo CSS
             test -f "$ANTCRATE_ROOT/webapps/coolgif/app.js"     && echo JS'
    [[ "$output" == *"HTML"* ]]
    [[ "$output" == *"CSS"* ]]
    [[ "$output" == *"JS"* ]]
}

@test "start is idempotent (no overwrite)" {
    run src 'ac_action_start coolgif webapps html
             ac_action_start coolgif webapps html
             ac_registry_list | wc -l'
    [[ "$output" == *"1"* ]]
}

@test "subbranch moves dir, updates path and parent" {
    run src '
        ac_action_start photoapp webapps html
        ac_subbranch_expand coolwebapps photoapp
        ac_registry_get photoapp path
        ac_registry_get photoapp parent
        test -d "$ANTCRATE_ROOT/coolwebapps/photoapp" && echo MOVED
        test ! -d "$ANTCRATE_ROOT/webapps/photoapp" && echo OLD_GONE'
    [[ "$output" == *"coolwebapps/photoapp"* ]]
    [[ "$output" == *"coolwebapps"* ]]
    [[ "$output" == *"MOVED"* ]]
    [[ "$output" == *"OLD_GONE"* ]]
}

@test "subbranch resumes pipe even on failure" {
    run src '
        ac_action_start photoapp webapps html
        # pre-create destination to force failure
        mkdir -p "$ANTCRATE_ROOT/coolwebapps/photoapp"
        ac_subbranch_expand coolwebapps photoapp || true
        ac_pipe_paused && echo STILL_PAUSED || echo RESUMED'
    [[ "$output" == *"RESUMED"* ]]
}

@test "branch with from=<base> copies and links" {
    run src '
        ac_action_start base webapps html
        ac_action_branch derived webapps from=base
        ac_registry_get derived linked_nodes
        test -d "$ANTCRATE_ROOT/webapps/derived" && echo OK'
    [[ "$output" == *"base"* ]]
    [[ "$output" == *"OK"* ]]
}
