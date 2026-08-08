#!/usr/bin/env bats
# Doc-accuracy guard (e2e audit 2026-08-07).
#
# Leading --flags were retired as input on 2026-07-10: typing one exits 2.
# The agent-facing docs kept prescribing them anyway — PATTERNS.md's
# "Quick index by verb" alone listed ~35 retired flags, every one a dead
# end for the agent that file exists to instruct. Fixing that by hand is a
# one-time repair; this test is what stops it coming back.
#
# The allowlist is PARSED FROM bin/antcrate rather than duplicated here, so
# retiring or adding a flag-only surface updates the guard automatically. A
# hardcoded copy would rot exactly the way the docs did.

setup() {
    REPO="$BATS_TEST_DIRNAME/../../.."
    WRAPPER="$BATS_TEST_DIRNAME/../bin/antcrate"
}

# every flag the dispatcher still accepts as a LEADING argument
flag_only_allowlist() {
    sed -n '/^\s*--help|-h|--init/,/flag-only surfaces/p' "$WRAPPER" \
        | grep -oE '\-\-[a-z-]+' | sort -u
}

# every `antcrate --flag` a doc tells the reader to run
doc_flags() {
    grep -ohE 'antcrate \-\-[a-z-]+' "$@" 2>/dev/null \
        | sed 's/antcrate //' | sort -u
}

# Flags a doc may name while NOT prescribing them: retirement examples and
# prose about the retirement itself. Kept deliberately tiny — anything added
# here is a promise that the surrounding text says "this is retired".
is_documented_example() {
    case "$1" in
        --status) return 0 ;;   # PATTERNS: "`antcrate --status` -> `antcrate st`"
    esac
    return 1
}

check_doc() {
    local doc="$1" allow flag bad=()
    allow=$(flag_only_allowlist)
    while read -r flag; do
        [[ -z "$flag" ]] && continue
        grep -qx -- "$flag" <<< "$allow" && continue
        is_documented_example "$flag" && continue
        bad+=("$flag")
    done < <(doc_flags "$doc")
    if (( ${#bad[@]} )); then
        printf 'retired flags prescribed in %s: %s\n' "$doc" "${bad[*]}" >&2
        return 1
    fi
    return 0
}

@test "docs guard: the allowlist actually parses out of bin/antcrate" {
    run flag_only_allowlist
    [ "$status" -eq 0 ]
    # a silent parse failure would make every check below vacuously pass
    [ "${#lines[@]}" -gt 10 ]
    printf '%s\n' "${lines[@]}" | grep -qx -- '--gh-init'
    printf '%s\n' "${lines[@]}" | grep -qx -- '--quarantine-restore'
}

@test "docs guard: PATTERNS.md prescribes no retired flags" {
    check_doc "$BATS_TEST_DIRNAME/../../docs/PATTERNS.md"
}

@test "docs guard: the agent-facing and public docs prescribe no retired flags" {
    local root="$BATS_TEST_DIRNAME/../../.."
    for d in "$root/README.md" \
             "$root/SKILL.md" \
             "$root/CONTRIBUTING.md" \
             "$BATS_TEST_DIRNAME/../AGENTS.md" \
             "$BATS_TEST_DIRNAME/../CLAUDE_CODE.md" \
             "$BATS_TEST_DIRNAME/../../docs/LIB_MAP.md"; do
        [[ -f "$d" ]] || continue
        run check_doc "$d"
        [ "$status" -eq 0 ] || {
            printf 'FAILED: %s\n%s\n' "$d" "$output" >&2
            return 1
        }
    done
}

# docs/MANUAL.md is deliberately NOT guarded. It documents the --flag forms
# as the internal canonical action map and says so in its own synopsis; ~45
# of its entries are flag-headed by design. Converting it to word forms is
# the same job as rewriting `help --all` and is tracked as its own duty.
# Adding it here would either fail permanently or force the allowlist so wide
# that the guard stopped catching anything.

@test "docs guard: the guard would actually catch a regression" {
    tmp="$BATS_TEST_TMPDIR/rotten.md"
    printf 'Run `antcrate --tool-install bats` to fix it.\n' > "$tmp"
    run check_doc "$tmp"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--tool-install"* ]]
}

@test "docs guard: a flag-only surface does not trip the guard" {
    tmp="$BATS_TEST_TMPDIR/fine.md"
    printf 'Run `antcrate --gh-init myproj --public` once.\n' > "$tmp"
    run check_doc "$tmp"
    [ "$status" -eq 0 ]
}
