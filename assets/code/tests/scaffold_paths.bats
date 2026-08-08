#!/usr/bin/env bats
# tests for lib/scaffold.sh path resolution (e2e path-rot audit 2026-08-07).
#
# scaffold.sh predated the 2026-06-13 XDG migration and kept three legacy
# assumptions that the migration never swept:
#   1. ANTCRATE_ROOT defaulted to $HOME/projects (lowercase — a DIFFERENT
#      directory from $HOME/Projects on any case-sensitive filesystem);
#   2. the template search tried $HOME/.antcrate/templates BEFORE the XDG data
#      home, so a leftover legacy tree beat freshly installed templates;
#   3. ac_scaffold_remote_for sourced ONLY $HOME/.antcrate/config, so the
#      documented ANTCRATE_GIT_REMOTE_PREFIX key — shipped in
#      templates/config.example — was silently dead on every XDG install.

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

src() {
    bash -c '
        export HOME="'"$HOME"'"
        '"${2:-}"'
        . "'"$LIB"'/log.sh" 2>/dev/null
        . "'"$LIB"'/scaffold.sh"
        '"$1"
}

@test "scaffold: ANTCRATE_ROOT defaults to capital-P ~/Projects" {
    run src 'printf "%s\n" "$ANTCRATE_ROOT"'
    [ "$output" = "$HOME/Projects" ]
}

@test "scaffold: the default root is not the lowercase legacy directory" {
    run src 'printf "%s\n" "$ANTCRATE_ROOT"'
    [ "$output" != "$HOME/projects" ]
}

@test "scaffold: XDG data templates win over a leftover legacy tree" {
    mkdir -p "$HOME/.antcrate/templates/_generic"
    mkdir -p "$HOME/.local/share/antcrate/templates/_generic"
    run src 'ac_scaffold_resolve_templates; printf "%s\n" "$ANTCRATE_TEMPLATES"'
    [ "$output" = "$HOME/.local/share/antcrate/templates" ]
}

@test "scaffold: legacy templates never win over a real tree" {
    # Running from a source checkout, the second candidate (the repo's own
    # assets/code/templates) always exists, so legacy is unreachable here by
    # construction. That IS the contract: legacy is the last resort, and the
    # only thing worth pinning is that it never beats a populated tree.
    mkdir -p "$HOME/.antcrate/templates/_generic"
    run src 'ac_scaffold_resolve_templates; printf "%s\n" "$ANTCRATE_TEMPLATES"'
    [ "$output" != "$HOME/.antcrate/templates" ]
}

@test "scaffold: an explicit ANTCRATE_TEMPLATES is honoured over every candidate" {
    mkdir -p "$HOME/explicit/_generic" "$HOME/.local/share/antcrate/templates/_generic"
    run src 'ac_scaffold_resolve_templates; printf "%s\n" "$ANTCRATE_TEMPLATES"' \
            'export ANTCRATE_TEMPLATES="'"$HOME"'/explicit"'
    [ "$output" = "$HOME/explicit" ]
}

@test "scaffold: ANTCRATE_GIT_REMOTE_PREFIX is read from the XDG config" {
    mkdir -p "$HOME/.config/antcrate"
    echo 'ANTCRATE_GIT_REMOTE_PREFIX="https://example.test/me/"' > "$HOME/.config/antcrate/config"
    run src 'ac_scaffold_remote_for proj'
    [ "$output" = "https://example.test/me/proj.git" ]
}

@test "scaffold: ANTCRATE_GIT_REMOTE_PREFIX still honoured from the legacy config" {
    mkdir -p "$HOME/.antcrate"
    echo 'ANTCRATE_GIT_REMOTE_PREFIX="https://legacy.test/me/"' > "$HOME/.antcrate/config"
    run src 'ac_scaffold_remote_for proj'
    [ "$output" = "https://legacy.test/me/proj.git" ]
}

@test "scaffold: no prefix configured yields an empty remote, not a broken URL" {
    run src 'ac_scaffold_remote_for proj'
    [ "$output" = "" ]
}
