#!/usr/bin/env bats
# three-tier skill cut (spec 2026-06-11 Unit 1 / plan Task 6)
# Guards the builder skill's flag table against wrapper drift and pins the
# orchestrator SKILL.md trim.

setup() { ROOT="$BATS_TEST_DIRNAME/../../.."; }

@test "builder skill: exists with generated-section markers" {
    f="$ROOT/assets/skills/builder/SKILL.md"
    [ -f "$f" ]
    grep -q 'ac:builder:flags:start' "$f"
    grep -q 'ac:builder:flags:end' "$f"
}

@test "builder skill: every flag in the marker section exists in bin/antcrate (drift check)" {
    f="$ROOT/assets/skills/builder/SKILL.md"
    flags=$(sed -n '/ac:builder:flags:start/,/ac:builder:flags:end/p' "$f" | grep -oE '\-\-[a-z][a-z-]*' | sort -u)
    [ -n "$flags" ]
    for fl in $flags; do
        grep -q -- "$fl" "$ROOT/assets/code/bin/antcrate" || { echo "DRIFT: $fl not in wrapper"; return 1; }
    done
}

@test "orchestrator SKILL.md: trimmed under 8000 bytes and points at LIB_MAP/MANUAL/PATTERNS" {
    f="$ROOT/SKILL.md"
    [ "$(wc -c < "$f")" -lt 8000 ]
    grep -q 'LIB_MAP.md' "$f"; grep -q 'MANUAL.md' "$f"; grep -q 'PATTERNS.md' "$f"
}

@test "LIB_MAP.md: carries the relocated lib catalog (registry.sh present)" {
    grep -q 'registry.sh' "$ROOT/assets/docs/LIB_MAP.md"
}
