#!/usr/bin/env bats
# tests for plugin/hooks/session-digest.sh — SessionStart state digest

setup() {
    DIGEST="$BATS_TEST_DIRNAME/../../../plugin/hooks/session-digest.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export ANTCRATE_DATA_HOME="$HOME/.local/share/antcrate"
    export ANTCRATE_INTEL_DIR="$ANTCRATE_DATA_HOME/intel"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    mkdir -p "$ANTCRATE_INTEL_DIR" "$ANTCRATE_DATA_HOME"
    printf '{"projects":{}}\n' > "$ANTCRATE_DATA_HOME/registry.json"
    : > "$ANTCRATE_DUTIES_FILE"
    : > "$ANTCRATE_INTEL_DIR/new.jsonl"
    : > "$ANTCRATE_INTEL_DIR/acked.jsonl"
}

digest() { printf '{"session_id":"x"}' | "$DIGEST"; }

@test "silent when duties, intel and trees are all clean" {
    run digest
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "counts open duties and reports the oldest date" {
    cat > "$ANTCRATE_DUTIES_FILE" <<'EOF'
 1. - [ ] 2026-07-17 — [command] older thing
 2. - [x] 2026-07-01 — [policy] already done
 3. - [ ] 2026-07-25 — [policy] newer thing
EOF
    run digest
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 duties open"* ]]
    [[ "$output" == *"oldest 2026-07-17"* ]]
}

@test "counts unread intel as new minus acked on source+sha" {
    printf '%s\n' \
      '{"source":"a","sha256":"aaa"}' \
      '{"source":"b","sha256":"bbb"}' \
      '{"source":"c","sha256":"ccc"}' > "$ANTCRATE_INTEL_DIR/new.jsonl"
    printf '%s\n' '{"source":"b","sha256":"bbb"}' > "$ANTCRATE_INTEL_DIR/acked.jsonl"
    run digest
    [[ "$output" == *"2 intel unread"* ]]
}

@test "reports a dirty registered project by name" {
    P="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$P"
    ( cd "$P" && git init -q -b master \
        && git config user.email t@e.x && git config user.name t \
        && echo one > a.txt && git add a.txt && git commit -qm init \
        && echo two > a.txt )
    jq -n --arg p "$P" '{projects:{proj:{path:$p}}}' > "$ANTCRATE_DATA_HOME/registry.json"
    run digest
    [[ "$output" == *"1 dirty"* ]]
    [[ "$output" == *"proj"* ]]
}

@test "ANTCRATE_DIGEST_GIT=0 skips the git sweep entirely" {
    P="$BATS_TEST_TMPDIR/proj"
    mkdir -p "$P"
    ( cd "$P" && git init -q -b master \
        && git config user.email t@e.x && git config user.name t \
        && echo one > a.txt && git add a.txt && git commit -qm init \
        && echo two > a.txt )
    jq -n --arg p "$P" '{projects:{proj:{path:$p}}}' > "$ANTCRATE_DATA_HOME/registry.json"
    ANTCRATE_DIGEST_GIT=0 run digest
    [ -z "$output" ]
}

@test "ANTCRATE_DIGEST_DISABLE=1 silences the hook completely" {
    printf ' 1. - [ ] 2026-07-17 — [x] thing\n' > "$ANTCRATE_DUTIES_FILE"
    ANTCRATE_DIGEST_DISABLE=1 run digest
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fails open on a missing registry" {
    rm -f "$ANTCRATE_DATA_HOME/registry.json"
    run digest
    [ "$status" -eq 0 ]
}

@test "fails open on malformed intel jsonl" {
    printf 'not json at all\n' > "$ANTCRATE_INTEL_DIR/new.jsonl"
    run digest
    [ "$status" -eq 0 ]
}

@test "fails open on a missing duties file" {
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/nope.md"
    run digest
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
