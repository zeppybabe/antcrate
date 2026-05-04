#!/usr/bin/env bats
# tests for lib/ingest.sh — bundle consumer per BUNDLE_SPEC v1.0

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    export ANTCRATE_BACKUP_DIR="$ANTCRATE_HOME/backups"
    export ANTCRATE_SKILLS_DIR="$BATS_TEST_TMPDIR/skills"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_INGEST_OFFLINE=1
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT" "$ANTCRATE_SKILLS_DIR"
    BUNDLE="$BATS_TEST_TMPDIR/bundle"
    mkdir -p "$BUNDLE"
    export BUNDLE
}

src() {
    bash -c '
        set -eo pipefail
        export ANTCRATE_HOME="'"$ANTCRATE_HOME"'"
        export ANTCRATE_REGISTRY="'"$ANTCRATE_REGISTRY"'"
        export ANTCRATE_ROOT="'"$ANTCRATE_ROOT"'"
        export ANTCRATE_BACKUP_DIR="'"$ANTCRATE_BACKUP_DIR"'"
        export ANTCRATE_SKILLS_DIR="'"$ANTCRATE_SKILLS_DIR"'"
        export ANTCRATE_LOG_LEVEL="'"$ANTCRATE_LOG_LEVEL"'"
        export ANTCRATE_INGEST_OFFLINE="'"$ANTCRATE_INGEST_OFFLINE"'"
        export ANTCRATE_INGEST_SKIP_FETCH="'"${ANTCRATE_INGEST_SKIP_FETCH:-0}"'"
        export ANTCRATE_REMOVAL_PREAPPROVED="'"${ANTCRATE_REMOVAL_PREAPPROVED:-0}"'"
        . "'"$LIB"'/log.sh"
        . "'"$LIB"'/registry.sh"
        . "'"$LIB"'/backup.sh"
        . "'"$LIB"'/safety.sh"
        . "'"$LIB"'/ingest.sh"
        '"$1"
}

write_manifest() {
    # write_manifest <name> <domain> <objective> <source-type> [extra-jq]
    local name="$1" domain="$2" obj="$3" stype="$4" extra="${5:-.}"
    local src_obj
    case "$stype" in
        none)    src_obj='{"type":"none"}' ;;
        git)     src_obj='{"type":"git","url":"file:///tmp/fake.git"}' ;;
        archive) src_obj='{"type":"archive","url":"file:///tmp/fake.tar.gz"}' ;;
        *)       src_obj="$stype" ;;
    esac
    jq -n \
        --arg n "$name" --arg d "$domain" --arg o "$obj" \
        --argjson src "$src_obj" \
        '{spec_version:"1.0", name:$n, domain:$d, objective:$o,
          generated_at:"2026-04-28T15:00:00Z", source:$src}' \
        | jq "$extra" > "$BUNDLE/manifest.json"
}

# ----- validation pass -------------------------------------------------------

@test "validate: theoretical bundle (source=none) passes" {
    write_manifest mybun projects "test" none
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -eq 0 ]
}

@test "validate: refuses missing manifest" {
    rm -f "$BUNDLE/manifest.json"
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses bad JSON" {
    echo "not json {" > "$BUNDLE/manifest.json"
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses missing required field" {
    write_manifest mybun projects "test" none 'del(.objective)'
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses unknown spec major" {
    write_manifest mybun projects "test" none '.spec_version = "2.0"'
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: accepts forward-compat minor (1.99)" {
    write_manifest mybun projects "test" none '.spec_version = "1.99"'
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -eq 0 ]
}

@test "validate: refuses name with whitespace" {
    write_manifest "bad name" projects "test" none
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses name with slash" {
    write_manifest "bad/name" projects "test" none
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses unknown source.type" {
    write_manifest mybun projects "t" '{"type":"floppy"}'
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses git source missing url" {
    write_manifest mybun projects "t" '{"type":"git"}'
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses composite with empty sources[]" {
    write_manifest mybun projects "t" '{"type":"composite","sources":[]}'
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: refuses collision without supersedes/extends" {
    src 'ac_registry_init; ac_registry_upsert mybun /tmp/x projects ""'
    write_manifest mybun projects "t" none
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -ne 0 ]
}

@test "validate: accepts collision with supersedes relationship" {
    src 'ac_registry_init; ac_registry_upsert mybun /tmp/x projects ""'
    write_manifest mybun projects "t" none \
        '.relationships = [{"kind":"supersedes","bundle":"mybun"}]'
    run src "ac_ingest_validate '$BUNDLE'"
    [ "$status" -eq 0 ]
}

# ----- ingest: source=none ---------------------------------------------------

@test "ingest: source=none creates empty tree + registers" {
    write_manifest mybun projects "obj" none
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -eq 0 ]
    [ -d "$ANTCRATE_ROOT/projects/mybun" ]
    has=$(src 'ac_registry_has mybun && echo YES')
    [ "$has" = "YES" ]
}

@test "ingest: registry stores objective" {
    write_manifest mybun projects "track ants" none
    src "ac_ingest '$BUNDLE'"
    obj=$(jq -r '.projects.mybun.objective' "$ANTCRATE_REGISTRY")
    [ "$obj" = "track ants" ]
}

@test "ingest: STATUS transitions to ingested" {
    echo "ready" > "$BUNDLE/STATUS"
    write_manifest mybun projects "obj" none
    src "ac_ingest '$BUNDLE'"
    [ "$(head -n1 "$BUNDLE/STATUS")" = "ingested" ]
}

@test "ingest: failure sets STATUS=failed: <reason>" {
    write_manifest mybun projects "obj" '{"type":"floppy"}'
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -ne 0 ]
    grep -q '^failed' "$BUNDLE/STATUS"
}

# ----- ingest: opaque files --------------------------------------------------

@test "ingest: copies research.md, claude.md, skill, diagrams, attachments" {
    write_manifest mybun projects "obj" none
    echo "# research" > "$BUNDLE/research.md"
    echo "# claude" > "$BUNDLE/claude.md"
    mkdir -p "$BUNDLE/skill" "$BUNDLE/diagrams" "$BUNDLE/attachments"
    echo "# skill" > "$BUNDLE/skill/SKILL.md"
    echo "graph TD" > "$BUNDLE/diagrams/architecture.mmd"
    echo "paper" > "$BUNDLE/attachments/paper.bib"
    src "ac_ingest '$BUNDLE'"
    P="$ANTCRATE_ROOT/projects/mybun"
    [ -f "$P/docs/research.md" ]
    [ -f "$P/CLAUDE.md" ]
    [ -f "$ANTCRATE_SKILLS_DIR/mybun/SKILL.md" ]
    [ -f "$P/docs/diagrams/architecture.mmd" ]
    [ -f "$P/docs/attachments/paper.bib" ]
}

@test "ingest: claude.skill_name override is honored" {
    write_manifest mybun projects "obj" none '.claude = {"skill_name":"custom-skill"}'
    mkdir -p "$BUNDLE/skill"
    echo "x" > "$BUNDLE/skill/SKILL.md"
    src "ac_ingest '$BUNDLE'"
    [ -f "$ANTCRATE_SKILLS_DIR/custom-skill/SKILL.md" ]
}

# ----- ingest: source=git from local bare repo -------------------------------

@test "ingest: source=git from file:// bare repo materializes" {
    # use a non-bare repo as source — avoids HEAD/default-branch setup quirks
    UP="$BATS_TEST_TMPDIR/upstream"
    git -c init.defaultBranch=main init -q "$UP"
    ( cd "$UP"
      git config user.email t@t; git config user.name t
      echo "hello" > README.md
      git add . && git commit -qm init )
    write_manifest mybun projects "obj" \
        "{\"type\":\"git\",\"url\":\"$UP\"}"
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -eq 0 ]
    [ -f "$ANTCRATE_ROOT/projects/mybun/README.md" ]
}

# ----- ingest: source=archive from local tarball -----------------------------

@test "ingest: source=archive from local tarball materializes" {
    SRC="$BATS_TEST_TMPDIR/src"
    mkdir -p "$SRC"
    echo "hello" > "$SRC/README.md"
    TAR="$BATS_TEST_TMPDIR/payload.tar.gz"
    tar -C "$BATS_TEST_TMPDIR" -czf "$TAR" "src"
    write_manifest mybun projects "obj" \
        "{\"type\":\"archive\",\"url\":\"$TAR\"}"
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -eq 0 ]
    [ -d "$ANTCRATE_ROOT/projects/mybun" ]
}

@test "ingest: archive sha256 mismatch fails cleanly" {
    SRC="$BATS_TEST_TMPDIR/src"
    mkdir -p "$SRC"; echo "hello" > "$SRC/README.md"
    TAR="$BATS_TEST_TMPDIR/payload.tar.gz"
    tar -C "$BATS_TEST_TMPDIR" -czf "$TAR" "src"
    write_manifest mybun projects "obj" \
        "{\"type\":\"archive\",\"url\":\"$TAR\",\"sha256\":\"deadbeef\"}"
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -ne 0 ]
    grep -q '^failed' "$BUNDLE/STATUS"
}

# ----- ingest: supersedes (rule #1) ------------------------------------------

@test "ingest: supersedes backs up + replaces existing" {
    # set up an existing project tree
    EXIST="$ANTCRATE_ROOT/projects/mybun"
    mkdir -p "$EXIST"
    echo "old" > "$EXIST/old.txt"
    src 'ac_registry_init; ac_registry_upsert mybun '"$EXIST"' projects ""'
    write_manifest mybun projects "obj" none \
        '.relationships = [{"kind":"supersedes","bundle":"mybun"}]'
    ANTCRATE_REMOVAL_PREAPPROVED=1 run src "ac_ingest '$BUNDLE'"
    [ "$status" -eq 0 ]
    [ ! -f "$EXIST/old.txt" ]
    # backup tarball was written
    [ -d "$ANTCRATE_BACKUP_DIR/mybun" ]
    n=$(find "$ANTCRATE_BACKUP_DIR/mybun" -name '*.tar.gz' | wc -l)
    [ "$n" -ge 1 ]
}

# ----- ingest: extends -------------------------------------------------------

@test "ingest: extends merges into existing without overwriting" {
    EXIST="$ANTCRATE_ROOT/projects/base"
    mkdir -p "$EXIST/docs"
    echo "kept" > "$EXIST/keep.txt"
    src 'ac_registry_init; ac_registry_upsert base /tmp/wrong projects ""
         ac_registry_apply --arg n base --arg p '"'$EXIST'"' ".projects[\$n].path = \$p"'
    # Bundle name is "base" (matches existing), declares extends:
    write_manifest base projects "addendum" none \
        '.relationships = [{"kind":"extends","bundle":"base"}]'
    echo "# more" > "$BUNDLE/research.md"
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -eq 0 ]
    [ -f "$EXIST/keep.txt" ]
    [ -f "$EXIST/docs/research.md" ]
}

# ----- composite -------------------------------------------------------------

@test "ingest: composite merges in order, first wins on conflicts" {
    A="$BATS_TEST_TMPDIR/a"; B="$BATS_TEST_TMPDIR/b"
    mkdir -p "$A" "$B"
    echo "from-A" > "$A/shared.txt"
    echo "only-A"  > "$A/onlya.txt"
    echo "from-B" > "$B/shared.txt"
    echo "only-B"  > "$B/onlyb.txt"
    TA="$BATS_TEST_TMPDIR/a.tar.gz"; TB="$BATS_TEST_TMPDIR/b.tar.gz"
    tar -C "$BATS_TEST_TMPDIR" -czf "$TA" "a"
    tar -C "$BATS_TEST_TMPDIR" -czf "$TB" "b"
    SRC_JSON=$(jq -nc \
        --arg ta "$TA" --arg tb "$TB" \
        '{type:"composite", sources:[
            {type:"archive", url:$ta},
            {type:"archive", url:$tb}
        ]}')
    write_manifest mybun projects "obj" "$SRC_JSON"
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -eq 0 ]
    P="$ANTCRATE_ROOT/projects/mybun"
    # archive extracted with strip-components=1, so contents land directly
    [ -f "$P/shared.txt" ]
    [ -f "$P/onlya.txt" ]
    [ -f "$P/onlyb.txt" ]
    grep -q "from-A" "$P/shared.txt"
}

# ----- depends_on (informational) --------------------------------------------

@test "ingest: depends_on missing dep warns but proceeds" {
    write_manifest mybun projects "obj" none \
        '.relationships = [{"kind":"depends_on","bundle":"nonexistent"}]'
    run src "ac_ingest '$BUNDLE'"
    [ "$status" -eq 0 ]
}
