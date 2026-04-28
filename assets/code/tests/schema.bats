#!/usr/bin/env bats
# tests for lib/schema.sh

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    # shellcheck disable=SC1091
    . "$LIB/log.sh"
    # shellcheck disable=SC1091
    . "$LIB/schema.sh"
}

@test "decode: full csv-meta filename" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode "coolgifwebapp.webapps.start.#html,css,js#" \
        && printf "%s|%s|%s|%s\n" "$AC_NAME" "$AC_DOMAIN" "$AC_ACTION" "$AC_META_TYPE"'
    [ "$status" -eq 0 ]
    [ "$output" = "coolgifwebapp|webapps|start|csv" ]
}

@test "decode: kv-meta" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode "alpha.proj.branch.from=beta" \
        && printf "%s|%s|%s|%s|%s\n" "$AC_NAME" "$AC_DOMAIN" "$AC_ACTION" "$AC_META_KEY" "$AC_META_VAL"'
    [ "$status" -eq 0 ]
    [ "$output" = "alpha|proj|branch|from|beta" ]
}

@test "decode: no-meta is ok" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode "thing.notes.start" \
        && printf "%s|%s|%s\n" "$AC_NAME" "$AC_DOMAIN" "$AC_ACTION"'
    [ "$status" -eq 0 ]
    [ "$output" = "thing|notes|start" ]
}

@test "decode: hidden file rejected" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode ".alpha.proj.start"'
    [ "$status" -eq 1 ]
}

@test "decode: backup file rejected" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode "alpha.proj.start~"'
    [ "$status" -eq 1 ]
}

@test "decode: swap file rejected" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode ".alpha.proj.start.swp"'
    [ "$status" -eq 1 ]
}

@test "decode: too few segments rejected" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode "thing.proj"'
    [ "$status" -eq 1 ]
}

@test "decode: unknown action returns 2" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode "thing.proj.nuke"'
    [ "$status" -eq 2 ]
}

@test "decode: meta with embedded period preserved" {
    run bash -c '. "'"$LIB"'/log.sh"; . "'"$LIB"'/schema.sh"; \
        ac_schema_decode "v.proj.start.ver=1.2.3" \
        && printf "%s\n" "$AC_META"'
    [ "$status" -eq 0 ]
    [ "$output" = "ver=1.2.3" ]
}
