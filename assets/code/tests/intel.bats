#!/usr/bin/env bats
# tests for lib/intel.sh — Anthropic intel tracker (deterministic retrieval layer)
#
# Bash owns retrieval, Claude owns judgment: pull fetches pinned Anthropic-only
# sources, normalizes, hashes; a changed hash stores a snapshot + appends a
# new.jsonl row. Nothing here is ever deleted (append-only quarantine philosophy).
# curl is mocked via PATH shim, same pattern as the fake-git shim.

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_INTEL_DIR="$ANTCRATE_HOME/intel"
    export ANTCRATE_LOG_LEVEL="error"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$ANTCRATE_HOME" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/serve"
    install_fake_curl
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_INTEL_DIR='$ANTCRATE_INTEL_DIR'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        export PATH='$PATH'
        . '$LIB/log.sh'
        . '$LIB/intel.sh'
        $1
    "
}

# fake curl: last arg is the URL; serves $BATS_TEST_TMPDIR/serve/<sanitized-url>,
# logs every call, exits 6 (couldn't resolve) when no fixture exists.
install_fake_curl() {
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
url="\${*: -1}"
printf '%s\n' "\$url" >> "$BATS_TEST_TMPDIR/curl.log"
f="$BATS_TEST_TMPDIR/serve/\$(printf '%s' "\$url" | tr -c 'A-Za-z0-9._-' '_')"
[ -f "\$f" ] || exit 6
cat "\$f"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

# serve <url> <body...> — register fixture content for the fake curl
serve() {
    local url="$1"; shift
    printf '%s\n' "$*" > "$BATS_TEST_TMPDIR/serve/$(printf '%s' "$url" | tr -c 'A-Za-z0-9._-' '_')"
}

# mk_sources <jq-array-of-{id,url}> — write a custom sources.json
mk_sources() {
    mkdir -p "$ANTCRATE_INTEL_DIR"
    jq -n --argjson s "$1" '{sources: $s}' > "$ANTCRATE_INTEL_DIR/sources.json"
}

ONE_SOURCE='[{"id":"news","url":"https://www.anthropic.com/news"}]'
TWO_SOURCES='[{"id":"news","url":"https://www.anthropic.com/news"},
              {"id":"eng","url":"https://www.anthropic.com/engineering"}]'

@test "pull: seeds default sources.json with 7 Anthropic-only sources when missing" {
    run src 'ANTCRATE_INTEL_OFFLINE=1 ac_intel_pull'
    [ "$status" -eq 0 ]
    [ -f "$ANTCRATE_INTEL_DIR/sources.json" ]
    [ "$(jq '.sources | length' "$ANTCRATE_INTEL_DIR/sources.json")" -eq 7 ]
    # every seeded url passes the Anthropic-origin allowlist
    run src 'jq -r ".sources[].url" "$ANTCRATE_INTEL_DIR/sources.json" | while read -r u; do
                 _ac_intel_host_allowed "$u" || exit 9; done'
    [ "$status" -eq 0 ]
}

@test "pull: first pull stores normalized snapshot + latest.sha256 + new.jsonl row" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html><body>Claude 5 released</body></html>"
    run src 'ac_intel_pull'
    [ "$status" -eq 0 ]
    [ -f "$ANTCRATE_INTEL_DIR/snapshots/news/latest.sha256" ]
    [ "$(find "$ANTCRATE_INTEL_DIR/snapshots/news" -name '*.body' | wc -l)" -eq 1 ]
    grep -q "Claude 5 released" "$ANTCRATE_INTEL_DIR/snapshots/news/"*.body
    [ "$(wc -l < "$ANTCRATE_INTEL_DIR/new.jsonl")" -eq 1 ]
    run jq -r '.source' "$ANTCRATE_INTEL_DIR/new.jsonl"
    [ "$output" = "news" ]
}

@test "pull: unchanged body adds no new row and no second snapshot" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html><body>stable</body></html>"
    src 'ac_intel_pull'
    run src 'ac_intel_pull'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$ANTCRATE_INTEL_DIR/new.jsonl")" -eq 1 ]
    [ "$(find "$ANTCRATE_INTEL_DIR/snapshots/news" -name '*.body' | wc -l)" -eq 1 ]
}

@test "pull: changed body stores second snapshot + appends row + updates latest.sha256" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html><body>v1</body></html>"
    src 'ac_intel_pull'
    old_sha=$(cat "$ANTCRATE_INTEL_DIR/snapshots/news/latest.sha256")
    serve "https://www.anthropic.com/news" "<html><body>v2 big change</body></html>"
    run src 'ac_intel_pull'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$ANTCRATE_INTEL_DIR/new.jsonl")" -eq 2 ]
    [ "$(find "$ANTCRATE_INTEL_DIR/snapshots/news" -name '*.body' | wc -l)" -eq 2 ]
    new_sha=$(cat "$ANTCRATE_INTEL_DIR/snapshots/news/latest.sha256")
    [ "$old_sha" != "$new_sha" ]
}

@test "pull: script/style-only changes do not produce a new row (normalization)" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html><script>var a=1;</script><style>.x{}</style><body>same text</body></html>"
    src 'ac_intel_pull'
    serve "https://www.anthropic.com/news" "<html><script>var a=999;</script><style>.y{color:red}</style><body>same text</body></html>"
    run src 'ac_intel_pull'
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$ANTCRATE_INTEL_DIR/new.jsonl")" -eq 1 ]
}

@test "pull: refuses non-Anthropic host with exit 2 and fetches nothing" {
    mk_sources '[{"id":"evil","url":"https://evil.example.com/feed"},
                 {"id":"news","url":"https://www.anthropic.com/news"}]'
    serve "https://www.anthropic.com/news" "<html>ok</html>"
    run src 'ac_intel_pull'
    [ "$status" -eq 2 ]
    [[ "$output" == *"evil.example.com"* ]]
    # fail-closed: validation precedes ALL fetching — not even the good source was hit
    [ ! -f "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "pull: unreachable source warns, continues to next source, exits 0" {
    mk_sources "$TWO_SOURCES"
    # only eng is served; news will exit 6 in the shim
    serve "https://www.anthropic.com/engineering" "<html>best practices</html>"
    # suite default is error-level (quiet logs); the warn must surface at warn level
    run src 'ANTCRATE_LOG_LEVEL=warn ac_intel_pull'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unreachable"* ]]
    [ -f "$ANTCRATE_INTEL_DIR/snapshots/eng/latest.sha256" ]
}

@test "pull: source id argument limits the pull to that source" {
    mk_sources "$TWO_SOURCES"
    serve "https://www.anthropic.com/news" "<html>news</html>"
    serve "https://www.anthropic.com/engineering" "<html>eng</html>"
    run src 'ac_intel_pull news'
    [ "$status" -eq 0 ]
    [ -f "$ANTCRATE_INTEL_DIR/snapshots/news/latest.sha256" ]
    [ ! -d "$ANTCRATE_INTEL_DIR/snapshots/eng" ]
}

@test "pull: unknown source id errors with exit 2" {
    mk_sources "$ONE_SOURCE"
    run src 'ac_intel_pull nosuch'
    [ "$status" -eq 2 ]
    [[ "$output" == *"nosuch"* ]]
}

@test "pull: ANTCRATE_INTEL_OFFLINE=1 performs no network call, exit 0" {
    mk_sources "$ONE_SOURCE"
    run src 'ANTCRATE_INTEL_OFFLINE=1 ac_intel_pull'
    [ "$status" -eq 0 ]
    [ ! -f "$BATS_TEST_TMPDIR/curl.log" ]
}

@test "new: lists unacked rows, empty output when nothing new" {
    mk_sources "$ONE_SOURCE"
    run src 'ac_intel_new'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    serve "https://www.anthropic.com/news" "<html>item</html>"
    src 'ac_intel_pull'
    run src 'ac_intel_new'
    [ "$status" -eq 0 ]
    [[ "$output" == *"news"* ]]
}

@test "new: --json emits one valid JSON object per row with ts/source/sha256 keys" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html>item</html>"
    src 'ac_intel_pull'
    run src 'ac_intel_new --json'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.ts and .source and .sha256' >/dev/null
}

@test "ack: acked row disappears from the new listing" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html>item</html>"
    src 'ac_intel_pull'
    sha=$(jq -r '.sha256' "$ANTCRATE_INTEL_DIR/new.jsonl")
    run src "ac_intel_ack news $sha"
    [ "$status" -eq 0 ]
    run src 'ac_intel_new'
    [ -z "$output" ]
}

@test "ack: appends to acked.jsonl and never deletes from new.jsonl" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html>item</html>"
    src 'ac_intel_pull'
    sha=$(jq -r '.sha256' "$ANTCRATE_INTEL_DIR/new.jsonl")
    src "ac_intel_ack news $sha"
    [ "$(wc -l < "$ANTCRATE_INTEL_DIR/new.jsonl")" -eq 1 ]
    [ "$(wc -l < "$ANTCRATE_INTEL_DIR/acked.jsonl")" -eq 1 ]
    run jq -r '.by' "$ANTCRATE_INTEL_DIR/acked.jsonl"
    [ -n "$output" ]
}

@test "status: per-source lines include unread counts" {
    mk_sources "$TWO_SOURCES"
    serve "https://www.anthropic.com/news" "<html>n</html>"
    serve "https://www.anthropic.com/engineering" "<html>e</html>"
    src 'ac_intel_pull'
    run src 'ac_intel_status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"news"* ]]
    [[ "$output" == *"eng"* ]]
    [[ "$output" == *"unread"* ]]
}

@test "status line: ac_intel_status_line prints 'intel: N unread'" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html>n</html>"
    src 'ac_intel_pull'
    run src 'ac_intel_status_line'
    [ "$status" -eq 0 ]
    [ "$output" = "intel: 1 unread" ]
}

@test "pull: --quiet suppresses per-source progress output" {
    mk_sources "$ONE_SOURCE"
    serve "https://www.anthropic.com/news" "<html>n</html>"
    run src 'ac_intel_pull --quiet'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "systemd: antcrate-intel.service + .timer pass systemd-analyze verify" {
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not available"
    UNITDIR="$BATS_TEST_DIRNAME/../systemd"
    [ -f "$UNITDIR/antcrate-intel.service" ]
    [ -f "$UNITDIR/antcrate-intel.timer" ]
    # __BIN__ placeholder is substituted at install time; use a resolvable stub
    tmp="$BATS_TEST_TMPDIR/units"
    mkdir -p "$tmp"
    sed "s|__BIN__|/usr/bin/env|" "$UNITDIR/antcrate-intel.service" > "$tmp/antcrate-intel.service"
    cp "$UNITDIR/antcrate-intel.timer" "$tmp/antcrate-intel.timer"
    run systemd-analyze verify --user "$tmp/antcrate-intel.timer" "$tmp/antcrate-intel.service"
    [ "$status" -eq 0 ]
}

@test "ack all: bulk-acks every unread item (bundled review close-out)" {
    mk_sources "$TWO_SOURCES"
    serve "https://www.anthropic.com/news" "news body one"
    serve "https://www.anthropic.com/engineering" "eng body one"
    src "ac_intel_pull --quiet"
    run src "ac_intel_ack_all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"acked 2"* ]]
    run src "ac_intel_new"
    [ -z "$output" ]
}

@test "ack all <source>: only acks that source's unread items" {
    mk_sources "$TWO_SOURCES"
    serve "https://www.anthropic.com/news" "news body one"
    serve "https://www.anthropic.com/engineering" "eng body one"
    src "ac_intel_pull --quiet"
    run src "ac_intel_ack_all news"
    [ "$status" -eq 0 ]
    run src "ac_intel_new"
    [[ "$output" == *"eng"* ]]
    [[ "$output" != *"news"* ]]
}

@test "ack all: nothing unread is a clean no-op" {
    mk_sources "$ONE_SOURCE"
    run src "ac_intel_ack_all"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing unread"* ]]
}
