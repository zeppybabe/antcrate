#!/usr/bin/env bats
# tests for lib/plugin.sh — plugin tree generator and drift check

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_LOG_LEVEL="error"
    SRC="$BATS_TEST_TMPDIR/src/hooks/claude"
    DST="$BATS_TEST_TMPDIR/plugin/hooks/claude"
    mkdir -p "$SRC" "$DST"
    printf '#!/usr/bin/env bash\necho a\n' > "$SRC/a.sh"; chmod +x "$SRC/a.sh"
    printf '#!/usr/bin/env bash\necho b\n' > "$SRC/b.sh"; chmod +x "$SRC/b.sh"
    export ANTCRATE_PLUGIN_SRC="$SRC"
    export ANTCRATE_PLUGIN_DST="$DST"
}

build() {
    bash -c '
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_PLUGIN_SRC="'"$SRC"'"
        export ANTCRATE_PLUGIN_DST="'"$DST"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/plugin.sh"
        ac_plugin_build '"$1"
}

@test "build: copies every source hook into the plugin tree" {
    run build ""
    [ "$status" -eq 0 ]
    [ -f "$DST/a.sh" ]
    [ -f "$DST/b.sh" ]
}

@test "build: preserves the executable bit" {
    build "" >/dev/null
    [ -x "$DST/a.sh" ]
}

@test "build: removes a stale copy with no source counterpart" {
    printf 'stale\n' > "$DST/gone.sh"
    build "" >/dev/null
    [ ! -f "$DST/gone.sh" ]
}

@test "check: clean tree exits 0" {
    build "" >/dev/null
    run build "--check"
    [ "$status" -eq 0 ]
}

@test "check: modified copy exits 1 and names the file" {
    build "" >/dev/null
    printf 'tampered\n' >> "$DST/a.sh"
    run build "--check"
    [ "$status" -eq 1 ]
    [[ "$output" == *"a.sh"* ]]
}

@test "check: missing copy exits 1" {
    build "" >/dev/null
    rm -f "$DST/b.sh"
    run build "--check"
    [ "$status" -eq 1 ]
}

@test "check: extra copy exits 1" {
    build "" >/dev/null
    printf 'extra\n' > "$DST/extra.sh"
    run build "--check"
    [ "$status" -eq 1 ]
}

@test "check: never writes — drift survives a check run" {
    build "" >/dev/null
    printf 'tampered\n' >> "$DST/a.sh"
    build "--check" || true
    grep -q tampered "$DST/a.sh"
}
