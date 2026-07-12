#!/usr/bin/env bash
# antcrate :: lib/health.sh — the `st` doctor.
# There is deliberately NO separate health command (owner directive 2026-07-11:
# fewer commands, more information per command): cmd_status prints
# ac_health_status_line, and install.sh ends by running `antcrate st`, so the
# install itself delivers the first health report. Every check is local,
# read-only and fast; every miss row carries a copy-pasteable fix command.

: "${ANTCRATE_BIN_DIR:=$HOME/.local/bin}"
: "${ANTCRATE_TOOLS_BIN:=${ANTCRATE_DATA_HOME:-$HOME/.local/share/antcrate}/tools/bin}"

# _ac_health_row <level> <name> <status> <detail> <fix>
#   level: req|opt   status: ok|miss|skip (skip = not applicable on this host)
_ac_health_row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

ac_health_checks() {
    # ── required: without these, antcrate itself misbehaves ────────────────
    case ":$PATH:" in
        *":$ANTCRATE_BIN_DIR:"*)
            _ac_health_row req path ok "$ANTCRATE_BIN_DIR in PATH" - ;;
        *)
            _ac_health_row req path miss "$ANTCRATE_BIN_DIR not in PATH" \
                "export PATH=\"$ANTCRATE_BIN_DIR:\$PATH\" (add to ~/.bashrc)" ;;
    esac

    if [[ -x "$ANTCRATE_BIN_DIR/antcrate" ]]; then
        _ac_health_row req wrapper ok "installed" -
    else
        _ac_health_row req wrapper miss "no $ANTCRATE_BIN_DIR/antcrate" \
            "bash <repo>/assets/code/install.sh"
    fi

    local what present
    for what in config root registry; do
        present=0
        case "$what" in
            config)   [[ -f "$ANTCRATE_CONFIG" ]] && present=1 ;;
            root)     [[ -d "$ANTCRATE_ROOT" ]] && present=1 ;;
            registry) [[ -f "$ANTCRATE_REGISTRY" ]] && present=1 ;;
        esac
        if (( present )); then
            _ac_health_row req "$what" ok "present" -
        else
            _ac_health_row req "$what" miss "missing" "antcrate --init"
        fi
    done

    # ── optional: quality-of-life; misses degrade features, not safety ─────
    if command -v systemctl >/dev/null 2>&1; then
        local t
        for t in backup intel; do
            if systemctl --user is-enabled "antcrate-$t.timer" >/dev/null 2>&1; then
                _ac_health_row opt "timer-$t" ok "enabled" -
            else
                _ac_health_row opt "timer-$t" miss "disabled" \
                    "systemctl --user enable --now antcrate-$t.timer"
            fi
        done
    else
        _ac_health_row opt timer-backup skip "no systemd" -
        _ac_health_row opt timer-intel  skip "no systemd" -
    fi

    local missing="" tool
    for tool in bats shellcheck gitleaks; do
        [[ -x "$ANTCRATE_TOOLS_BIN/$tool" ]] || command -v "$tool" >/dev/null 2>&1 \
            || missing="$missing $tool"
    done
    if [[ -z "$missing" ]]; then
        _ac_health_row opt tools ok "bats shellcheck gitleaks" -
    else
        _ac_health_row opt tools miss "missing:$missing" \
            "antcrate tool install${missing}"
    fi

    if ! command -v gh >/dev/null 2>&1; then
        _ac_health_row opt gh miss "gh not installed" "sudo apt install gh"
    elif gh auth token >/dev/null 2>&1; then
        _ac_health_row opt gh ok "authenticated" -
    else
        _ac_health_row opt gh miss "not authenticated" "gh auth login"
    fi

    if ! command -v git >/dev/null 2>&1; then
        _ac_health_row req git miss "git not installed" "sudo apt install git"
    elif [[ -n "$(git config --get user.name 2>/dev/null)" \
         && -n "$(git config --get user.email 2>/dev/null)" ]]; then
        _ac_health_row opt git-id ok "identity set" -
    else
        _ac_health_row opt git-id miss "user.name/email unset" \
            "git config --global user.name \"You\" && git config --global user.email you@example.com"
    fi
}

# one-liner (or issue list) for cmd_status — mirrors ac_intel_status_line
ac_health_status_line() {
    local level name status detail fix total=0 issues=0 lines=""
    while IFS=$'\t' read -r level name status detail fix; do
        [[ -z "$name" || "$status" == "skip" ]] && continue
        total=$((total + 1))
        if [[ "$status" == "miss" ]]; then
            issues=$((issues + 1))
            local mark=""
            [[ "$level" == "opt" ]] && mark=" (opt)"
            lines="${lines}  ${name}${mark} : ${detail} — fix: ${fix}"$'\n'
        fi
    done < <(ac_health_checks)
    if (( issues == 0 )); then
        printf 'health: OK (%s checks)\n' "$total"
    else
        printf 'health: %s issue(s)\n' "$issues"
        printf '%s' "$lines"
    fi
}
