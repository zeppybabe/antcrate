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

# ---------------------------------------------------------------------------
# Default-resolution tests: ANTCRATE_SELFSRC is accepted in two forms seen in
# this codebase — naming assets/code itself (devops.sh's default, safety.sh's
# zone derivation, this machine's real ~/.config/antcrate/config) or naming
# the repo root directly. These exercise the real resolution logic in
# ac_plugin_build (ANTCRATE_PLUGIN_SRC/DST unset), not the test seams the
# tests above use — the seams bypass default resolution entirely, so a bug
# in resolving ANTCRATE_SELFSRC would ship with all-green tests otherwise.

# resolves defaults from a caller-supplied ANTCRATE_SELFSRC; seams unset
build_from_selfsrc() {
    local _selfsrc="$1"; shift
    bash -c '
        unset ANTCRATE_PLUGIN_SRC ANTCRATE_PLUGIN_DST
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_SELFSRC="'"$_selfsrc"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/plugin.sh"
        ac_plugin_build '"$*"
}

# resolves defaults with ANTCRATE_SELFSRC unset and HOME overridden — proves
# the built-in fallback ($HOME/.claude/skills/antcrate/assets/code) is used
build_selfsrc_unset() {
    local _home="$1"; shift
    bash -c '
        unset ANTCRATE_PLUGIN_SRC ANTCRATE_PLUGIN_DST ANTCRATE_SELFSRC
        export ANTCRATE_LOG_LEVEL="error"
        export HOME="'"$_home"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/plugin.sh"
        ac_plugin_build '"$*"
}

@test "resolve: ANTCRATE_SELFSRC naming the assets/code dir places src/dst under the repo root" {
    ROOT="$BATS_TEST_TMPDIR/repo_ac"
    mkdir -p "$ROOT/assets/code/hooks/claude"
    printf '#!/usr/bin/env bash\necho r\n' > "$ROOT/assets/code/hooks/claude/r.sh"
    chmod +x "$ROOT/assets/code/hooks/claude/r.sh"
    run build_from_selfsrc "$ROOT/assets/code"
    [ "$status" -eq 0 ]
    [ -f "$ROOT/plugin/hooks/claude/r.sh" ]
}

@test "resolve: ANTCRATE_SELFSRC naming the bare repo root also places src/dst correctly" {
    ROOT="$BATS_TEST_TMPDIR/repo_root"
    mkdir -p "$ROOT/assets/code/hooks/claude"
    printf '#!/usr/bin/env bash\necho r\n' > "$ROOT/assets/code/hooks/claude/r.sh"
    chmod +x "$ROOT/assets/code/hooks/claude/r.sh"
    run build_from_selfsrc "$ROOT"
    [ "$status" -eq 0 ]
    [ -f "$ROOT/plugin/hooks/claude/r.sh" ]
}

@test "resolve: ANTCRATE_SELFSRC unset falls back to \$HOME/.claude/skills/antcrate/assets/code, not doubled" {
    FAKEHOME="$BATS_TEST_TMPDIR/fakehome"
    mkdir -p "$FAKEHOME"
    run build_selfsrc_unset "$FAKEHOME"
    [ "$status" -eq 2 ]
    [[ "$output" == *"$FAKEHOME/.claude/skills/antcrate/assets/code/hooks/claude"* ]]
    [[ "$output" != *"assets/code/assets/code"* ]]
}

# ---------------------------------------------------------------------------
# Real-repo drift check: the whole point of `self plugin --check` is to catch
# a committed plugin/hooks/claude/ copy that has diverged from its
# assets/code/hooks/claude source. Every test above uses tmpdir fixtures, so
# this one runs the check against the actual repo tree instead — a real
# divergence there must fail `self ci`, which globs in every *.bats file.

@test "check: real repo tree — plugin/hooks/claude has no drift from assets/code/hooks/claude" {
    SRC_REAL="$BATS_TEST_DIRNAME/../hooks/claude"
    DST_REAL="$BATS_TEST_DIRNAME/../../../plugin/hooks/claude"
    run bash -c '
        export ANTCRATE_LOG_LEVEL="error"
        export ANTCRATE_PLUGIN_SRC="'"$SRC_REAL"'"
        export ANTCRATE_PLUGIN_DST="'"$DST_REAL"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/plugin.sh"
        ac_plugin_build --check
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"tree matches source"* ]]
}
