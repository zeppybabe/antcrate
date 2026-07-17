#!/usr/bin/env bash
# antcrate :: install.sh — idempotent first-run installer

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
SVC_DIR="$HOME/.config/systemd/user"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# XDG locations are the single source of truth (paths.sh); migrate.sh moves any
# legacy ~/.antcrate layout into them once. Data (lib/templates/hooks) installs
# under the XDG data home so the wrapper resolves it consistently.
# shellcheck disable=SC1091
. "$SRC/lib/paths.sh"
# shellcheck disable=SC1091
. "$SRC/lib/compat.sh"
# shellcheck disable=SC1091
. "$SRC/lib/migrate.sh"
# shellcheck disable=SC1091
. "$SRC/lib/preflight.sh"

# fail fast (with per-platform hints) if the shell or a required tool is too old/missing
ac_preflight_bash_version
ac_preflight_deps jq git fswatcher

LIB_DIR="$ANTCRATE_DATA_HOME/lib"
TPL_DIR="$ANTCRATE_TEMPLATES"
HOOKS_DIR="$ANTCRATE_DATA_HOME/hooks"

echo "[antcrate] installing to $PREFIX (data: $ANTCRATE_DATA_HOME)"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$TPL_DIR" "$HOOKS_DIR" \
         "$ANTCRATE_CONFIG_HOME" "$ANTCRATE_DATA_HOME" "$ANTCRATE_STATE_HOME"

# migrate a legacy ~/.antcrate before --init touches the new dirs
ac_migrate_xdg

# binaries (rewrite LIB_DIR path on copy; temp+rename so a RUNNING wrapper that
# invoked --install-from-source is never truncated in place mid-execution — the
# old process keeps its inode, new invocations get the new file)
for b in antcrate antcrated; do
    sed "s|LIB_DIR=\"\$SCRIPT_DIR/../lib\"|LIB_DIR=\"$LIB_DIR\"|" \
        "$SRC/bin/$b" > "$BIN_DIR/.$b.tmp.$$"
    chmod +x "$BIN_DIR/.$b.tmp.$$"
    mv -f "$BIN_DIR/.$b.tmp.$$" "$BIN_DIR/$b"
done

# libs (same temp+rename discipline — a wrapper starting mid-install must never
# source a half-written lib)
for f in "$SRC"/lib/*.sh; do
    cp -f "$f" "$LIB_DIR/.$(basename "$f").tmp.$$"
    mv -f "$LIB_DIR/.$(basename "$f").tmp.$$" "$LIB_DIR/$(basename "$f")"
done

# lib subdirs (e.g. targets/) — same temp+rename discipline, generic for any depth-1 dir
for d in "$SRC"/lib/*/; do
    [[ -d "$d" ]] || continue
    sub="$LIB_DIR/$(basename "$d")"
    mkdir -p "$sub"
    for f in "$d"*.sh; do
        [[ -e "$f" ]] || continue
        cp -f "$f" "$sub/.$(basename "$f").tmp.$$"
        mv -f "$sub/.$(basename "$f").tmp.$$" "$sub/$(basename "$f")"
    done
done

# templates
if [[ -d "$SRC/templates" ]]; then
    cp -rf "$SRC/templates"/. "$TPL_DIR/"
fi

# hook templates (sibling to lib so lib/hooks.sh's ../hooks/templates path resolves)
if [[ -d "$SRC/hooks" ]]; then
    mkdir -p "$HOOKS_DIR"
    cp -rf "$SRC/hooks"/. "$HOOKS_DIR/"
fi

# initialize state (idempotent; XDG dirs already created + migrated above).
# --init creates $ANTCRATE_ROOT (default ~/Projects) — note whether this run
# is the one that created it, so first-time users get oriented below.
ROOT_DIR="${ANTCRATE_ROOT:-$HOME/Projects}"
ROOT_WAS_MISSING=0
[[ -d "$ROOT_DIR" ]] || ROOT_WAS_MISSING=1
"$BIN_DIR/antcrate" --init >/dev/null

# remember the source root so --selfsrc / --selftest / --selfedit work
CONFIG="$ANTCRATE_CONFIG"
if [[ -f "$CONFIG" ]] && ! grep -q '^ANTCRATE_SELFSRC=' "$CONFIG"; then
    printf '\nANTCRATE_SELFSRC="%s"\n' "$SRC" >> "$CONFIG"
elif [[ -f "$CONFIG" ]]; then
    ac_sed_i "s|^ANTCRATE_SELFSRC=.*|ANTCRATE_SELFSRC=\"$SRC\"|" "$CONFIG"
fi

# self-register + skill link — both are required for `antcrate --selfcheck` to
# pass, and neither used to be created by the installer (the #1 "it didn't
# install properly" report). REPO_ROOT is the git checkout root, found by
# walking up from SRC so it works no matter how deep assets/code sits.
REPO_ROOT="$SRC"
while [[ "$REPO_ROOT" != "/" && ! -d "$REPO_ROOT/.git" ]]; do
    REPO_ROOT="$(dirname "$REPO_ROOT")"
done

if [[ -d "$REPO_ROOT/.git" ]]; then
    # idempotent: reg refuses (exit 1) if 'antcrate' already exists
    # (word form — the leading --register flag was retired 2026-07-10)
    "$BIN_DIR/antcrate" reg antcrate "$REPO_ROOT" --domain antcrate >/dev/null 2>&1 || true

    SKILL_LINK="${ANTCRATE_SKILL_LINK:-$HOME/.claude/skills/antcrate}"
    mkdir -p "$(dirname "$SKILL_LINK")"
    if [[ -L "$SKILL_LINK" || ! -e "$SKILL_LINK" ]]; then
        ln -sfn "$REPO_ROOT" "$SKILL_LINK"          # -f replaces a stale/dangling link only
        echo "[antcrate] skill link: $SKILL_LINK -> $REPO_ROOT"
    else
        echo "[antcrate] skill link skipped: $SKILL_LINK exists and is not a symlink"
    fi
else
    echo "[antcrate] note: no .git found above $SRC — skipping self-register + skill-link"
    echo "[antcrate]       (tarball install? run: antcrate --register antcrate <repo-root>)"
fi

# optional systemd user units
if command -v systemctl >/dev/null 2>&1 && [[ -d "$SVC_DIR" || $(mkdir -p "$SVC_DIR") ]]; then
    sed "s|__BIN__|$BIN_DIR/antcrated|g" \
        "$SRC/systemd/antcrated.service" > "$SVC_DIR/antcrated.service"
    sed "s|__BIN__|$BIN_DIR/antcrate|g" \
        "$SRC/systemd/antcrate-backup.service" > "$SVC_DIR/antcrate-backup.service"
    cp -f "$SRC/systemd/antcrate-backup.timer" "$SVC_DIR/antcrate-backup.timer"
    sed "s|__BIN__|$BIN_DIR/antcrate|g" \
        "$SRC/systemd/antcrate-intel.service" > "$SVC_DIR/antcrate-intel.service"
    cp -f "$SRC/systemd/antcrate-intel.timer" "$SVC_DIR/antcrate-intel.timer"
    systemctl --user daemon-reload || true
    echo "[antcrate] systemd units installed at $SVC_DIR (antcrated, antcrate-backup, antcrate-intel)"
fi

# launchd user agents (macOS sibling of the systemd block: rendered but never
# bootstrapped — enabling stays a human duty, printed by the st health panel)
if [[ "${AC_OS:-linux}" == darwin ]]; then
    LA_DIR="${ANTCRATE_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"
    mkdir -p "$LA_DIR" "$ANTCRATE_LOG_DIR"
    # launchd agents don't inherit shell PATH: bake in the dir of the bash that
    # runs this install (the brew bin dir when installed per the README) plus
    # BIN_DIR and the system dirs, so env-bash/jq/fswatch resolve for agents.
    LAUNCHD_PATH="$(dirname "$(command -v bash)"):$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
    for unit in daemon backup intel; do
        case "$unit" in
            daemon) UNIT_BIN="$BIN_DIR/antcrated" ;;
            *)      UNIT_BIN="$BIN_DIR/antcrate" ;;
        esac
        sed -e "s|__BIN__|$UNIT_BIN|g" \
            -e "s|__PATH__|$LAUNCHD_PATH|g" \
            -e "s|__LOG__|$ANTCRATE_LOG_DIR|g" \
            -e "s|__MIN__|$((RANDOM % 60))|g" \
            "$SRC/launchd/com.antcrate.$unit.plist" > "$LA_DIR/com.antcrate.$unit.plist"
    done
    echo "[antcrate] launchd agents installed at $LA_DIR (not loaded — enable with:"
    echo "[antcrate]   launchctl bootstrap gui/$(id -u) $LA_DIR/com.antcrate.<daemon|backup|intel>.plist )"
fi

# first-run orientation (owner directive: init is bundled here, not a command)
if [[ "$ROOT_WAS_MISSING" -eq 1 ]]; then
    cat <<EOF
[antcrate] created your workspace root: $ROOT_DIR
[antcrate]   Work from there — projects registered under it get the safety
[antcrate]   rails (gated commits, backups, duties), and coding agents like
[antcrate]   Claude Code inherit the right scope. Working elsewhere is fine
[antcrate]   but unmanaged. Quickstart:
[antcrate]     cd $ROOT_DIR
[antcrate]     antcrate reg <name> <path>   # register a project
[antcrate]     antcrate st                  # status + health, with fixes
[antcrate]     antcrate duty ls             # what needs a human
EOF
fi

echo "[antcrate] done. PATH should include $BIN_DIR"

# seed the model/budget/endpoint policy if absent (idempotent — a present
# file is user territory). Without it the budget hooks fail open; the
# 2026-06-13 XDG migration dropped it on at least one device.
"$BIN_DIR/antcrate" policy seed || true

# the status panel doubles as the doctor: anything left to do (enable timers,
# missing tools, auth) shows up here with its fix command — no extra step
echo ""
"$BIN_DIR/antcrate" st || true
