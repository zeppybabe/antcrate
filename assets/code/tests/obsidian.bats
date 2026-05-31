#!/usr/bin/env bats
# tests for lib/obsidian.sh — Obsidian vault mirroring

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_OBSIDIAN_VAULT="$BATS_TEST_TMPDIR/obsidian"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT" "$ANTCRATE_OBSIDIAN_VAULT"

    # Set up a fixture project
    P="$ANTCRATE_ROOT/fixture"
    mkdir -p "$P/docs/diagrams"
    : > "$P/docs/diagrams/tree.mmd"
    printf '%%mermaid\ngraph TD\n  A[Root] --> B[Child]\n' > "$P/docs/diagrams/tree.mmd"

    : > "$P/ledger.md"
    printf '## 2026-01-01\nInitial commit.\n## 2026-01-02\nSecond commit.\n' >> "$P/ledger.md"

    src 'ac_registry_init; ac_registry_upsert fixture '"$P"' testdomain "https://github.com/test/fixture.git"'
    export P
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_OBSIDIAN_VAULT="'"$ANTCRATE_OBSIDIAN_VAULT"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/obsidian.sh"
        '"$1"
}

@test "obsidian-mirror: unset vault var returns 2 with config hint" {
    unset ANTCRATE_OBSIDIAN_VAULT
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "ANTCRATE_OBSIDIAN_VAULT"
    echo "$output" | grep -q "config"
}

@test "obsidian-mirror: nonexistent vault dir returns 2" {
    export ANTCRATE_OBSIDIAN_VAULT="$BATS_TEST_TMPDIR/nonexistent"
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 2 ]
}

@test "obsidian-mirror: happy path creates Registry.md and project note" {
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ] || { echo "Status: $status, Output: $output"; false; }
    [ -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/Registry.md" ]
    [ -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md" ]
}

@test "obsidian-mirror: project note contains domain and path in frontmatter" {
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    grep -q "domain: testdomain" "$note"
    grep -q "path: $P" "$note"
    # Frontmatter must be the first line so Obsidian parses it as Properties,
    # not a horizontal rule (the callout goes below the frontmatter block).
    [ "$(head -1 "$note")" = "---" ]
}

@test "obsidian-mirror: linked nodes render as wikilinks" {
    # Link fixture to another project
    P2="$ANTCRATE_ROOT/linked"
    mkdir -p "$P2"
    run src 'ac_registry_upsert linked '"$P2"' testdomain ""'
    [ "$status" -eq 0 ]
    run src 'ac_registry_link fixture linked'
    [ "$status" -eq 0 ]

    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    grep -q "\[\[linked\]\]" "$note"
}

@test "obsidian-mirror: idempotent — second run leaves content unchanged" {
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    sha1=$(sha256sum "$note" | awk '{print $1}')

    # Second run
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]
    sha2=$(sha256sum "$note" | awk '{print $1}')

    [ "$sha1" = "$sha2" ]
}

@test "obsidian-mirror: tree.mmd embedded in project note" {
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    grep -q '```mermaid' "$note"
    grep -q 'graph TD' "$note"
}

@test "obsidian-mirror: specific project filters correctly" {
    P2="$ANTCRATE_ROOT/other"
    mkdir -p "$P2"
    run src 'ac_registry_upsert other '"$P2"' testdomain ""'
    [ "$status" -eq 0 ]

    run src 'ac_obsidian_mirror fixture'
    [ "$status" -eq 0 ]
    [ -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md" ]
    [ ! -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/other.md" ]
}

@test "obsidian-mirror: unknown project returns 2" {
    run src 'ac_obsidian_mirror unknown'
    [ "$status" -eq 2 ]
}

@test "obsidian-mirror: git_remote in frontmatter (or none)" {
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    grep -q "git_remote: https://github.com/test/fixture.git" "$note"
}

@test "obsidian-mirror: Registry.md includes project list as wikilinks" {
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]
    registry="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/Registry.md"
    grep -q "\[\[fixture\]\]" "$registry"
}

@test "obsidian-mirror: skips ghost entries (path no longer exists)" {
    # Register a project with a nonexistent path (ghost)
    run src 'ac_registry_upsert ghost /nonexistent/path testdomain ""'
    [ "$status" -eq 0 ]

    # Mirror all
    run src 'ac_obsidian_mirror'
    [ "$status" -eq 0 ]

    # Ghost note should NOT exist
    [ ! -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/ghost.md" ]

    # Registry.md should NOT link ghost
    registry="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/Registry.md"
    ! grep -q "\[\[ghost\]\]" "$registry"
}

@test "obsidian-mirror: specific ghost project returns 0 with warning" {
    # Register ghost
    run src 'ac_registry_upsert ghost /nonexistent/path testdomain ""'
    [ "$status" -eq 0 ]

    # Mirror specific ghost
    run src 'ac_obsidian_mirror ghost'
    [ "$status" -eq 0 ]

    # No note created
    [ ! -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/ghost.md" ]

    # Warning logged (since log level is error, no warning appears; we just confirm exit 0)
}

@test "obsidian-mirror --with-docs: copies project .md files as vault notes" {
    # Create a .md file in the project
    mkdir -p "$P/docs"
    printf 'Test content\n' > "$P/docs/README.md"

    run src 'ac_obsidian_mirror fixture --with-docs'
    [ "$status" -eq 0 ]

    # Project note should exist and include ## Documents section
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    [ -f "$note" ]
    grep -q '## Documents' "$note"

    # Mirrored doc should exist at correct path
    doc="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture/docs/README.md"
    [ -f "$doc" ]

    # Doc content should have the mirrored header
    grep -q "Mirrored by" "$doc"
    grep -q "Test content" "$doc"

    # Project note should link the doc
    grep -q '\[\[AntCrate/projects/fixture/docs/README|docs/README.md\]\]' "$note"
}

@test "obsidian-mirror without --with-docs: no ## Documents section" {
    # Create a .md file in the project
    mkdir -p "$P/docs"
    printf 'Test content\n' > "$P/docs/README.md"

    run src 'ac_obsidian_mirror fixture'
    [ "$status" -eq 0 ]

    # Project note should NOT include ## Documents section
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    [ -f "$note" ]
    ! grep -q '## Documents' "$note"
}

@test "obsidian-mirror: ac_obsidian_auto_regen returns 0 when ANTCRATE_OBSIDIAN_AUTO unset" {
    export ANTCRATE_OBSIDIAN_AUTO=0
    run src 'ac_obsidian_auto_regen fixture'
    [ "$status" -eq 0 ]
    # No note created
    [ ! -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md" ]
}

@test "obsidian-mirror: ac_obsidian_auto_regen writes metadata-only note when ANTCRATE_OBSIDIAN_AUTO=1" {
    export ANTCRATE_OBSIDIAN_AUTO=1
    mkdir -p "$P/docs"
    printf 'Test doc\n' > "$P/docs/README.md"

    run src 'ac_obsidian_auto_regen fixture'
    [ "$status" -eq 0 ]

    # Metadata note should exist
    note="$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture.md"
    [ -f "$note" ]

    # Should NOT include ## Documents section (metadata-only, no --with-docs)
    ! grep -q '## Documents' "$note"

    # .md file should NOT be copied
    [ ! -f "$ANTCRATE_OBSIDIAN_VAULT/AntCrate/projects/fixture/docs/README.md" ]
}
