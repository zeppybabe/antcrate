#!/usr/bin/env bash
# antcrate :: install.sh — idempotent first-run installer

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/antcrate/lib"
TPL_DIR="$PREFIX/share/antcrate/templates"
SVC_DIR="$HOME/.config/systemd/user"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[antcrate] installing to $PREFIX"

mkdir -p "$BIN_DIR" "$LIB_DIR" "$TPL_DIR" "$HOME/.antcrate"

# binaries (rewrite LIB_DIR path on copy)
for b in antcrate antcrated; do
    sed "s|LIB_DIR=\"\$SCRIPT_DIR/../lib\"|LIB_DIR=\"$LIB_DIR\"|" \
        "$SRC/bin/$b" > "$BIN_DIR/$b"
    chmod +x "$BIN_DIR/$b"
done

# libs
cp -f "$SRC"/lib/*.sh "$LIB_DIR/"

# templates
if [[ -d "$SRC/templates" ]]; then
    cp -rf "$SRC/templates"/. "$TPL_DIR/"
fi

# hook templates (sibling to lib so lib/hooks.sh's ../hooks/templates path resolves)
HOOKS_DIR="$PREFIX/share/antcrate/hooks"
if [[ -d "$SRC/hooks" ]]; then
    mkdir -p "$HOOKS_DIR"
    cp -rf "$SRC/hooks"/. "$HOOKS_DIR/"
fi

# state dir
"$BIN_DIR/antcrate" --init >/dev/null

# remember the source root so --selfsrc / --selftest / --selfedit work
CONFIG="$HOME/.antcrate/config"
if [[ -f "$CONFIG" ]] && ! grep -q '^ANTCRATE_SELFSRC=' "$CONFIG"; then
    printf '\nANTCRATE_SELFSRC="%s"\n' "$SRC" >> "$CONFIG"
elif [[ -f "$CONFIG" ]]; then
    sed -i "s|^ANTCRATE_SELFSRC=.*|ANTCRATE_SELFSRC=\"$SRC\"|" "$CONFIG"
fi

# optional systemd user unit
if command -v systemctl >/dev/null 2>&1 && [[ -d "$SVC_DIR" || $(mkdir -p "$SVC_DIR") ]]; then
    sed "s|__BIN__|$BIN_DIR/antcrated|g" \
        "$SRC/systemd/antcrated.service" > "$SVC_DIR/antcrated.service"
    systemctl --user daemon-reload || true
    echo "[antcrate] systemd unit installed at $SVC_DIR/antcrated.service"
    echo "[antcrate] enable with: systemctl --user enable --now antcrated"
fi

echo "[antcrate] done. PATH should include $BIN_DIR"
