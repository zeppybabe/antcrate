#!/usr/bin/env bash
# antcrate :: lib/plugin.sh — generate the Claude Code plugin tree.
#
# assets/code/hooks/claude/ is the SOURCE OF TRUTH for hook scripts. The
# plugin ships committed copies so it installs standalone, with no build step
# on the consumer's machine. This generator produces those copies; a drift
# test in self ci fails when they diverge.
#
# plugin/hooks/claude/ is WHOLLY OWNED by this function: anything there with
# no source counterpart is deleted. Hand-written plugin files (hooks.json,
# session-digest.sh) live one level up, in plugin/hooks/, and are never touched.
#
# Public API:
#   ac_plugin_build [--check]
#
# Env (test seams): ANTCRATE_PLUGIN_SRC, ANTCRATE_PLUGIN_DST
#
# Sourced by wrapper. Depends on log.sh.

# ac_plugin_build [--check]
#   default : sync src -> dst, print what changed, exit 0
#   --check : report drift, change nothing, exit 1 if any drift
ac_plugin_build() {
    local check=0
    while (( $# > 0 )); do
        case "$1" in
            --check) check=1; shift ;;
            *) ac_error "self plugin: unknown arg '$1' (--check)"; return 2 ;;
        esac
    done

    # ANTCRATE_SELFSRC conventionally names the assets/code dir itself (see
    # devops.sh's default and safety.sh's zone derivation), not the repo
    # root — mirror safety.sh's dirname-twice unwrap so plugin src/dst land
    # next to each other under the repo root regardless of which form the
    # caller's config uses.
    local selfsrc skill_root src dst
    selfsrc="${ANTCRATE_SELFSRC:-$HOME/.claude/skills/antcrate/assets/code}"
    case "$selfsrc" in
        */assets/code) skill_root=$(dirname "$(dirname "$selfsrc")") ;;
        *)             skill_root="$selfsrc" ;;
    esac
    src="${ANTCRATE_PLUGIN_SRC:-$selfsrc/hooks/claude}"
    dst="${ANTCRATE_PLUGIN_DST:-$skill_root/plugin/hooks/claude}"

    [ -d "$src" ] || { ac_error "self plugin: source dir missing: $src"; return 2; }
    (( check )) || mkdir -p "$dst"
    [ -d "$dst" ] || { ac_error "self plugin: dest dir missing: $dst"; return 2; }

    local drift=0 f base
    # forward pass: every source file must exist in dst, byte-identical
    for f in "$src"/*.sh; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        if [ -f "$dst/$base" ] && cmp -s "$f" "$dst/$base"; then
            continue
        fi
        drift=1
        if (( check )); then
            printf 'plugin: DRIFT %s\n' "$base"
        else
            cp -p "$f" "$dst/$base"
            chmod +x "$dst/$base"
            printf 'plugin: synced %s\n' "$base"
        fi
    done

    # reverse pass: nothing may exist in dst without a source counterpart
    for f in "$dst"/*.sh; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ -f "$src/$base" ] && continue
        drift=1
        if (( check )); then
            printf 'plugin: DRIFT extra %s\n' "$base"
        else
            rm -f "$f"
            printf 'plugin: removed %s\n' "$base"
        fi
    done

    if (( check )); then
        (( drift )) && { ac_error "self plugin: tree is stale — run 'antcrate self plugin'"; return 1; }
        printf 'plugin: tree matches source\n'
    fi
    return 0
}
