#!/usr/bin/env bats
# tests for lib/fetch.sh — generic no-LLM web fetcher (spec 2026-06-11 TH tier)
# Network is stubbed with a curl PATH shim.

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_FETCH_DIR="$BATS_TEST_TMPDIR/fetch"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME" "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_CURL_FAIL:-0}" = "1" ] && exit 22
printf '<html><script>x</script><body>Hello <b>fetch</b> world</body></html>\n'
SH
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

src() { bash -c "export PATH='$PATH' ANTCRATE_HOME='$ANTCRATE_HOME' ANTCRATE_FETCH_DIR='$ANTCRATE_FETCH_DIR' ANTCRATE_LOG_LEVEL=error; . '$LIB/log.sh'; . '$LIB/intel.sh'; . '$LIB/fetch.sh'; $1"; }

@test "fetch: snapshots normalized body and prints path" {
    run src "ac_fetch https://example.com/docs/page --name expage"
    [ "$status" -eq 0 ]
    snap=$(ls "$ANTCRATE_FETCH_DIR/expage/"*.body)
    grep -q 'Hello fetch world' "$snap"
    ! grep -q '<script>' "$snap"
    [[ "$output" == *"$snap"* ]]
}

@test "fetch: default slug derived from url" {
    src "ac_fetch https://example.com/a/b" >/dev/null
    ls "$ANTCRATE_FETCH_DIR"/example.com-a-b/*.body
}

@test "fetch: unchanged content -> no duplicate snapshot (append-only, hash-keyed)" {
    src "ac_fetch https://example.com/x --name x" >/dev/null
    src "ac_fetch https://example.com/x --name x" >/dev/null
    [ "$(ls "$ANTCRATE_FETCH_DIR/x/"*.body | wc -l)" -eq 1 ]
}

@test "fetch: curl failure -> rc 1, nothing written" {
    FAKE_CURL_FAIL=1 run src "FAKE_CURL_FAIL=1 ac_fetch https://example.com/x --name x"
    [ "$status" -eq 1 ]
    [ ! -d "$ANTCRATE_FETCH_DIR/x" ]
}

@test "fetch: missing url rc2; non-http scheme refused rc2" {
    run src "ac_fetch"; [ "$status" -eq 2 ]
    run src "ac_fetch file:///etc/passwd"; [ "$status" -eq 2 ]
}
