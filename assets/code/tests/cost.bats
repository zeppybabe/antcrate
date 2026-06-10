#!/usr/bin/env bats
# tests for lib/cost.sh — real-dollar cost engine over Claude Code session JSONL
#
# Price model (validated against USAGE ON CLAUDE.pdf, 2026-06-10):
#   cost = in*R.in + out*R.out + cache_read*R.in*0.1
#        + write_5m*R.in*1.25 + write_1h*R.in*2.0   (all per MTok)

setup() {
    export ANTCRATE_CANARY_DISABLE=1
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_LOG_LEVEL="error"
    export ANTCRATE_CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/claude-projects"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_CLAUDE_PROJECTS_DIR/projA"
    # shellcheck disable=SC1090
    . "$LIB/log.sh"
    # shellcheck disable=SC1090
    . "$LIB/cost.sh"
}

# msg <file> <ts> <id> <model> <in> <out> <read> <w5m> <w1h>
msg() {
    local f="$1" ts="$2" id="$3" model="$4" in="$5" out="$6" read="$7" w5m="$8" w1h="$9"
    printf '{"timestamp":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":%s}}}}\n' \
        "$ts" "$id" "$model" "$in" "$out" "$read" "$((w5m + w1h))" "$w5m" "$w1h" >> "$f"
}

F() { printf '%s\n' "$ANTCRATE_CLAUDE_PROJECTS_DIR/projA/sess1.jsonl"; }

@test "cost: haiku 1M in + 1M out = 6.00" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    run ac_cost_total
    [ "$status" -eq 0 ]
    [ "$output" = "6.0000" ]
}

@test "cost: duplicate message ids counted once" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    msg "$(F)" "2026-06-10T01:00:00.100Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    run ac_cost_total
    [ "$output" = "6.0000" ]
}

@test "cost: cache read priced at 0.1x input" {
    # opus: 2M cache read * 5.00 * 0.1 = 1.00
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-opus-4-8 0 0 2000000 0 0
    run ac_cost_total
    [ "$output" = "1.0000" ]
}

@test "cost: 5m cache write 1.25x and 1h write 2x" {
    # opus: 1M w5m * 5 * 1.25 = 6.25 ; 1M w1h * 5 * 2 = 10.00 → 16.25
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-opus-4-8 0 0 0 1000000 0
    msg "$(F)" "2026-06-10T01:00:01.000Z" m2 claude-opus-4-8 0 0 0 0 1000000
    run ac_cost_total
    [ "$output" = "16.2500" ]
}

@test "cost: legacy usage without cache_creation object falls back to total writes at 5m rate" {
    printf '{"timestamp":"2026-06-10T01:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000000}}}\n' >> "$(F)"
    run ac_cost_total
    [ "$output" = "6.2500" ]
}

@test "cost: --since excludes earlier messages" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 0 0 0 0
    msg "$(F)" "2026-06-10T03:00:00.000Z" m2 claude-haiku-4-5 0 1000000 0 0 0
    run ac_cost_total --since "2026-06-10T02:00:00Z"
    [ "$output" = "5.0000" ]
}

@test "cost: --since accepts epoch seconds" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 0 0 0 0
    msg "$(F)" "2026-06-10T03:00:00.000Z" m2 claude-haiku-4-5 0 1000000 0 0 0
    # 2026-06-10T02:00:00Z
    run ac_cost_total --since "$(date -u -d '2026-06-10T02:00:00Z' +%s)"
    [ "$output" = "5.0000" ]
}

@test "cost: unknown claude-* model priced conservatively at fable rates" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-zonnet-9 1000000 0 0 0 0
    run ac_cost_total
    [ "$output" = "10.0000" ]
}

@test "cost: non-claude model (synthetic) contributes zero" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 "<synthetic>" 1000000 1000000 0 0 0
    msg "$(F)" "2026-06-10T01:00:01.000Z" m2 claude-haiku-4-5 1000000 0 0 0 0
    run ac_cost_total
    [ "$output" = "1.0000" ]
}

@test "cost: date-suffixed model id prefix-matches its base rate" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5-20251001 1000000 0 0 0 0
    run ac_cost_total
    [ "$output" = "1.0000" ]
}

@test "cost: aggregates across multiple project dirs and files" {
    mkdir -p "$ANTCRATE_CLAUDE_PROJECTS_DIR/projB"
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 0 0 0 0
    msg "$ANTCRATE_CLAUDE_PROJECTS_DIR/projB/sess2.jsonl" "2026-06-10T01:00:01.000Z" m2 claude-haiku-4-5 0 1000000 0 0 0
    run ac_cost_total
    [ "$output" = "6.0000" ]
}

@test "cost: --session restricts to one file" {
    mkdir -p "$ANTCRATE_CLAUDE_PROJECTS_DIR/projB"
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 0 0 0 0
    msg "$ANTCRATE_CLAUDE_PROJECTS_DIR/projB/sess2.jsonl" "2026-06-10T01:00:01.000Z" m2 claude-haiku-4-5 0 1000000 0 0 0
    run ac_cost_total --session "$(F)"
    [ "$output" = "1.0000" ]
}

@test "cost: empty/no transcripts yields 0.0000, exit 0" {
    run ac_cost_total
    [ "$status" -eq 0 ]
    [ "$output" = "0.0000" ]
}

@test "cost report: per-model table plus total line" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    msg "$(F)" "2026-06-10T01:00:01.000Z" m2 claude-opus-4-8 0 0 2000000 0 0
    run ac_cost_report
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-haiku-4-5"* ]]
    [[ "$output" == *"claude-opus-4-8"* ]]
    [[ "$output" == *"total: \$7.0000"* ]]
}

@test "cost report: --porcelain prints bare total only" {
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    run ac_cost_report --porcelain
    [ "$output" = "6.0000" ]
}

# ---------- loop integration: dollar budgets ----------

loop_env() {
    export ANTCRATE_LOOP_ALLOW_UNSAFE=1
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$ANTCRATE_ROOT/demo"
    ac_registry_get() { [[ "$2" == path ]] && printf '%s\n' "$ANTCRATE_ROOT/$1"; }
    ac_registry_has() { [[ -d "$ANTCRATE_ROOT/$1" ]]; }
    # shellcheck disable=SC1090
    . "$LIB/loop.sh"
}

@test "loop: decimal budget initializes cost mode with dollar ceiling" {
    loop_env
    run ac_loop_init "obj" demo 25 "5.00"
    [ "$status" -eq 0 ]
    local id; id=$(ls "$ANTCRATE_HOME/loops" | head -1); id="${id%.json}"
    [ "$(jq -r '.budget_mode' "$ANTCRATE_HOME/loops/$id.json")" = "cost" ]
    [ "$(jq -r '.budget_ceiling' "$ANTCRATE_HOME/loops/$id.json")" = "5.00" ]
}

@test "loop: integer budget keeps legacy wall-clock mode" {
    loop_env
    run ac_loop_init "obj" demo 25 "300"
    [ "$status" -eq 0 ]
    local id; id=$(ls "$ANTCRATE_HOME/loops" | head -1); id="${id%.json}"
    [ "$(jq -r '.budget_mode' "$ANTCRATE_HOME/loops/$id.json")" = "wallclock" ]
}

@test "loop: cost budget trips when spend since start exceeds ceiling" {
    loop_env
    # spend after start: haiku 1M in + 1M out = $6.00 > $5 ceiling
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    local start; start=$(date -u -d '2026-06-01T00:00:00Z' +%s)
    echo "{\"id\":\"a\",\"status\":\"running\",\"tick\":1,\"max_iter\":25,\"stall_streak\":0,\"budget_ceiling\":\"5.00\",\"budget_mode\":\"cost\",\"budget_counter_start\":$start}" | _ac_loop_write "a"
    run _ac_loop_check_stops "a"
    [ "$output" = "budget" ]
}

@test "loop: cost budget does not trip under ceiling" {
    loop_env
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    local start; start=$(date -u -d '2026-06-01T00:00:00Z' +%s)
    echo "{\"id\":\"a\",\"status\":\"running\",\"tick\":1,\"max_iter\":25,\"stall_streak\":0,\"budget_ceiling\":\"100.00\",\"budget_mode\":\"cost\",\"budget_counter_start\":$start}" | _ac_loop_write "a"
    run _ac_loop_check_stops "a"
    [ "$output" = "" ]
}

@test "loop: spend before loop start does not count against cost budget" {
    loop_env
    msg "$(F)" "2026-06-10T01:00:00.000Z" m1 claude-haiku-4-5 1000000 1000000 0 0 0
    local start; start=$(date -u -d '2026-06-11T00:00:00Z' +%s)
    echo "{\"id\":\"a\",\"status\":\"running\",\"tick\":1,\"max_iter\":25,\"stall_streak\":0,\"budget_ceiling\":\"5.00\",\"budget_mode\":\"cost\",\"budget_counter_start\":$start}" | _ac_loop_write "a"
    run _ac_loop_check_stops "a"
    [ "$output" = "" ]
}
