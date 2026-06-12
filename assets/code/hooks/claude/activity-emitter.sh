#!/usr/bin/env bash
# Hook: activity-emitter (Claude Code PostToolUse / Edit|Write|Read|NotebookEdit).
#
# Feeds the live watch view (`antcrate --watch [--follow]`): resolves the file
# a tool just touched to a registered project (longest path-prefix wins) and
# appends an activity event via `antcrate --emit-activity`. Edit/Write/
# NotebookEdit → modify (yellow); Read → read (cyan).
#
# Fail-open contract: this hook NEVER blocks a tool call — every exit path is
# exit 0, and the wrapper call is best-effort. A broken emitter must degrade
# to "the tree just doesn't light up", not to a stuck session.
#
# Env: ANTCRATE_REGISTRY (default ~/.antcrate/registry.json)
#      ANTCRATE_BIN (default: antcrate on PATH, else $ANTCRATE_SELFSRC/bin/antcrate)
set -uo pipefail

REGISTRY="${ANTCRATE_REGISTRY:-$HOME/.antcrate/registry.json}"
[ -f "$REGISTRY" ] || exit 0

payload="$(cat)"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
file="$(printf '%s' "$payload" \
    | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)" || exit 0
[ -z "$file" ] && exit 0

case "$tool" in
    Read)                    kind="read" ;;
    Edit|Write|NotebookEdit) kind="modify" ;;
    *)                       exit 0 ;;
esac

# longest path-prefix match over registry project roots
match="$(jq -r --arg f "$file" '
    .projects | to_entries[]
    | (.value.path | rtrimstr("/")) as $p
    | select(($f == $p) or ($f | startswith($p + "/")))
    | "\($p | length)\t\(.key)\t\($p)"' "$REGISTRY" 2>/dev/null \
    | sort -rn | head -n 1)"
[ -z "$match" ] && exit 0
proj="$(printf '%s' "$match" | cut -f2)"
root="$(printf '%s' "$match" | cut -f3)"
rel="${file#"$root"/}"
[ "$rel" = "$file" ] && rel="."

BIN="${ANTCRATE_BIN:-}"
if [ -z "$BIN" ]; then
    BIN="$(command -v antcrate 2>/dev/null)" || BIN="${ANTCRATE_SELFSRC:-}/bin/antcrate"
fi
[ -x "$BIN" ] || exit 0

"$BIN" --emit-activity "$proj" "$kind" "$rel" --agent claude --label hook >/dev/null 2>&1 || true
exit 0
