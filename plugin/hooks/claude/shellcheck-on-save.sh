#!/usr/bin/env bash
# Hook: shellcheck-on-save (Claude Code PostToolUse / Edit|Write).
#
# Enforces the "shellcheck must pass" convention at edit time, scoped to .sh
# files under the AntCrate code tree. Block-style: findings surface to the model
# (exit 2) so they must be addressed; clean edits are silent.
# See docs/specs/2026-05-31-harness-enforcement-layer.md.
#
# Env: ANTCRATE_CODE_ROOT (default ~/.claude/skills/antcrate/assets/code)
#      ANTCRATE_PLUGIN_ROOT (default ~/.claude/skills/antcrate/plugin)
#      ANTCRATE_SHELLCHECK (default shellcheck) — binary name, overridable for tests.
#      ANTCRATE_TOOLS_BIN — pinned toolchain, searched when the binary name is
#      not on PATH.
set -uo pipefail

CODE_ROOT="${ANTCRATE_CODE_ROOT:-$HOME/.claude/skills/antcrate/assets/code}"
# plugin/hooks/session-digest.sh is hand-written shell that lives OUTSIDE the
# code tree, so it fell through this scope test entirely (audit 2026-07-25,
# finding C).
PLUGIN_ROOT="${ANTCRATE_PLUGIN_ROOT:-$HOME/.claude/skills/antcrate/plugin}"
SHELLCHECK_BIN="${ANTCRATE_SHELLCHECK:-shellcheck}"
TOOLS_BIN="${ANTCRATE_TOOLS_BIN:-${ANTCRATE_DATA_HOME:-$HOME/.local/share/antcrate}/tools/bin}"

payload="$(cat)"
file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$file" ] && exit 0

# Scope: only .sh files, only inside the AntCrate code tree.
case "$file" in
    *.sh) ;;
    *) exit 0 ;;
esac
case "$file" in
    "$CODE_ROOT"/*|"$PLUGIN_ROOT"/*) ;;
    *) exit 0 ;;
esac

# `antcrate tool install` puts the pinned shellcheck somewhere deliberately NOT
# on the default PATH, so a bare `command -v` made this hook skip on the very
# machine that has the tool (audit 2026-07-25, finding D — same fail-open shape
# ci carried until 9ff7641). Fall back to the pinned copy before giving up.
if ! command -v "$SHELLCHECK_BIN" >/dev/null 2>&1 && [ -x "$TOOLS_BIN/$SHELLCHECK_BIN" ]; then
    SHELLCHECK_BIN="$TOOLS_BIN/$SHELLCHECK_BIN"
fi

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
