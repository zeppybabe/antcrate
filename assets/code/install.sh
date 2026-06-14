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
. "$SRC/lib/migrate.sh"

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

# templates
if [[ -d "$SRC/templates" ]]; then
    cp -rf "$SRC/templates"/. "$TPL_DIR/"
fi

# hook templates (sibling to lib so lib/hooks.sh's ../hooks/templates path resolves)
if [[ -d "$SRC/hooks" ]]; then
    mkdir -p "$HOOKS_DIR"
    cp -rf "$SRC/hooks"/. "$HOOKS_DIR/"
fi

# initialize state (idempotent; XDG dirs already created + migrated above)
"$BIN_DIR/antcrate" --init >/dev/null

# remember the source root so --selfsrc / --selftest / --selfedit work
CONFIG="$ANTCRATE_CONFIG"
if [[ -f "$CONFIG" ]] && ! grep -q '^ANTCRATE_SELFSRC=' "$CONFIG"; then
    printf '\nANTCRATE_SELFSRC="%s"\n' "$SRC" >> "$CONFIG"
elif [[ -f "$CONFIG" ]]; then
    sed -i "s|^ANTCRATE_SELFSRC=.*|ANTCRATE_SELFSRC=\"$SRC\"|" "$CONFIG"
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
    # idempotent: --register refuses (exit 1) if 'antcrate' already exists
    "$BIN_DIR/antcrate" --register antcrate "$REPO_ROOT" --domain antcrate >/dev/null 2>&1 || true

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
    echo "[antcrate] enable with: systemctl --user enable --now antcrated"
    echo "[antcrate] enable daily backup: systemctl --user enable --now antcrate-backup.timer"
    echo "[antcrate] enable daily intel pull: systemctl --user enable --now antcrate-intel.timer"
fi

echo "[antcrate] done. PATH should include $BIN_DIR"
