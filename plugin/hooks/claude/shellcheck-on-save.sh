#!/usr/bin/env bash
# Hook: shellcheck-on-save (Claude Code PostToolUse / Edit|Write).
#
# Enforces the "shellcheck must pass" convention at edit time, scoped to .sh
# files under the AntCrate code tree. Block-style: findings surface to the model
# (exit 2) so they must be addressed; clean edits are silent.
# See docs/specs/2026-05-31-harness-enforcement-layer.md.
#
# Env: ANTCRATE_CODE_ROOT (default ~/.claude/skills/antcrate/assets/code)
#      ANTCRATE_SHELLCHECK (default shellcheck) — binary name, overridable for tests.
set -uo pipefail

CODE_ROOT="${ANTCRATE_CODE_ROOT:-$HOME/.claude/skills/antcrate/assets/code}"
SHELLCHECK_BIN="${ANTCRATE_SHELLCHECK:-shellcheck}"

payload="$(cat)"
file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$file" ] && exit 0

# Scope: only .sh files, only inside the AntCrate code tree.
case "$file" in
    *.sh) ;;
    *) exit 0 ;;
esac
case "$file" in
    "$CODE_ROOT"/*) ;;
    *) exit 0 ;;
esac

# Token-efficient skip when shellcheck is unavailable.
if ! command -v "$SHELLCHECK_BIN" >/dev/null 2>&1; then
    printf 'shellcheck-on-save: %s not found — skipping lint of %s\n' "$SHELLCHECK_BIN" "$file" >&2
    exit 0
fi

# Edited file may have been deleted/renamed by the time we run; nothing to lint.
[ -f "$file" ] || exit 0

if report="$("$SHELLCHECK_BIN" -x "$file" 2>&1)"; then
    exit 0
fi

printf 'shellcheck-on-save: findings in %s — address before continuing:\n%s\n' "$file" "$report" >&2
exit 2
