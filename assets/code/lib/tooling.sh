#!/usr/bin/env bash
# antcrate :: lib/tooling.sh — local, no-root provisioning of pinned dev tools.
#
# The counterpart to the local-install guard hook: instead of `sudo apt install`,
# AntCrate fetches version-pinned, SHA256-verified release artifacts into
# $ANTCRATE_DATA_HOME/tools (opt/ payloads, bin/ symlinks). Every install appends
# an auditable manifest line (url, sha256, placed path, attester, timestamp) to
# $ANTCRATE_STATE_HOME/tools/manifest.jsonl — the integrity record that you and/or
# a model sign off on. No sudo, no system package manager, nothing opaque.
#
# Requires paths.sh sourced first (ANTCRATE_DATA_HOME, ANTCRATE_STATE_HOME).

# compat.sh self-source: shims used below; guard makes re-sourcing free
# (bats tests source libs directly, without the wrapper preamble).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"

: "${ANTCRATE_TOOLS_DIR:=$ANTCRATE_DATA_HOME/tools}"
: "${ANTCRATE_TOOLS_BIN:=$ANTCRATE_TOOLS_DIR/bin}"
: "${ANTCRATE_TOOLS_OPT:=$ANTCRATE_TOOLS_DIR/opt}"
: "${ANTCRATE_TOOLS_MANIFEST:=$ANTCRATE_STATE_HOME/tools/manifest.jsonl}"

# Pinned registry — name → "version|url|sha256|kind", keyed per platform for
# native binaries (bats is a source tree and runs anywhere bash does).
#   kind binxz : .tar.xz whose top dir holds a single <name> binary (shellcheck)
#   kind srcgz : .tar.gz source tree run in place via bin/<name>          (bats)
#   kind bingz : .tar.gz holding a single <name> binary               (gitleaks)
_ac_tool_platform() { printf '%s.%s\n' "$(uname -s)" "$(uname -m)"; }

_ac_tool_pin() {
    local plat; plat=$(_ac_tool_platform)
    case "$1" in
        shellcheck)
            case "$plat" in
                Darwin.arm64) printf '%s\n' \
"v0.11.0|https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz|56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79|binxz" ;;
                Darwin.x86_64) printf '%s\n' \
"v0.11.0|https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.x86_64.tar.xz|3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6|binxz" ;;
                *) printf '%s\n' \
"v0.11.0|https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz|8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198|binxz" ;;
            esac ;;
        bats) printf '%s\n' \
"v1.13.0|https://github.com/bats-core/bats-core/archive/refs/tags/v1.13.0.tar.gz|a85e12b8828271a152b338ca8109aa23493b57950987c8e6dff97ba492772ff3|srcgz" ;;
        gitleaks)
            case "$plat" in
                Darwin.arm64) printf '%s\n' \
"v8.30.1|https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz|b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5|bingz" ;;
                Darwin.x86_64) printf '%s\n' \
"v8.30.1|https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_x64.tar.gz|dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709|bingz" ;;
                *) printf '%s\n' \
"v8.30.1|https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz|551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb|bingz" ;;
            esac ;;
        *) return 1 ;;
    esac
}

ac_tool_known() { _ac_tool_pin "$1" >/dev/null 2>&1; }
ac_tool_path()  { printf '%s\n' "$ANTCRATE_TOOLS_BIN"; }

ac_tool_list() {
    local n pin ver
    for n in shellcheck bats gitleaks; do
        pin=$(_ac_tool_pin "$n"); ver=${pin%%|*}
        if [[ -x "$ANTCRATE_TOOLS_BIN/$n" ]]; then
            printf '  %-12s %-9s [installed]\n' "$n" "$ver"
        else
            printf '  %-12s %-9s [available]\n' "$n" "$ver"
        fi
    done
}

# ac_tool_install <name> [--force]
ac_tool_install() {
    local name="${1:-}" force="${2:-}"
    [[ -n "$name" ]] || { printf 'tool-install: name required\n' >&2; return 2; }
    local pin; pin=$(_ac_tool_pin "$name") || { printf 'tool-install: unknown tool: %s\n' "$name" >&2; return 2; }
    local ver url sha kind
    IFS='|' read -r ver url sha kind <<<"$pin"

    if [[ -x "$ANTCRATE_TOOLS_BIN/$name" && "$force" != "--force" ]]; then
        printf 'tool-install: %s already present (%s) — use --force to reinstall\n' "$name" "$ver"
        return 0
    fi

    mkdir -p "$ANTCRATE_TOOLS_BIN" "$ANTCRATE_TOOLS_OPT" "$(dirname "$ANTCRATE_TOOLS_MANIFEST")"
    local work; work=$(mktemp -d)
    # FUNCNAME guard: under `set -o functrace` (bats), RETURN traps fire on
    # every inner function's return too — without the guard, the first shell
    # function called below (e.g. ac_sha256) would delete $work mid-install.
    # shellcheck disable=SC2064
    trap "if [[ \${FUNCNAME[0]:-} == ac_tool_install ]]; then rm -rf '$work'; fi" RETURN

    local art="$work/artifact"
    # Safe, transparent fetch: fail on HTTP error (-f), HTTPS-only, modern TLS.
    if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$art" "$url"; then
        printf 'tool-install: download failed: %s\n' "$url" >&2; return 1
    fi

    # Integrity gate — abort hard on mismatch.
    local got; got=$(ac_sha256 "$art" | cut -d' ' -f1)
    if [[ "$got" != "$sha" ]]; then
        printf 'tool-install: SHA256 MISMATCH for %s\n  expected %s\n  got      %s\n' "$name" "$sha" "$got" >&2
        return 1
    fi

    local placed="" top
    case "$kind" in
        binxz)
            tar -xJf "$art" -C "$work"
            top=$(tar -tJf "$art" | sed -n '1p'); top=${top%%/*}   # sed (not head) = no SIGPIPE under pipefail
            local found="$work/$top/$name"
            [[ -f "$found" ]] || { printf 'tool-install: %s binary not found in archive\n' "$name" >&2; return 1; }
            local dest="$ANTCRATE_TOOLS_OPT/$name-$ver"
            mkdir -p "$dest"; cp "$found" "$dest/$name"; chmod +x "$dest/$name"
            ln -sfn "$dest/$name" "$ANTCRATE_TOOLS_BIN/$name"
            placed="$dest/$name"
            ;;
        bingz)
            tar -xzf "$art" -C "$work"            # single binary at archive root (no top dir)
            local found="$work/$name"
            [[ -f "$found" ]] || { printf 'tool-install: %s binary not found in archive\n' "$name" >&2; return 1; }
            local dest="$ANTCRATE_TOOLS_OPT/$name-$ver"
            mkdir -p "$dest"; cp "$found" "$dest/$name"; chmod +x "$dest/$name"
            ln -sfn "$dest/$name" "$ANTCRATE_TOOLS_BIN/$name"
            placed="$dest/$name"
            ;;
        srcgz)
            top=$(tar -tzf "$art" | sed -n '1p'); top=${top%%/*}
            rm -rf "${ANTCRATE_TOOLS_OPT:?}/$top"
            tar -xzf "$art" -C "$ANTCRATE_TOOLS_OPT"
            local srcdir="$ANTCRATE_TOOLS_OPT/$top"
            [[ -x "$srcdir/bin/$name" ]] || { printf 'tool-install: %s entrypoint missing\n' "$name" >&2; return 1; }
            ln -sfn "$srcdir/bin/$name" "$ANTCRATE_TOOLS_BIN/$name"
            placed="$srcdir/bin/$name"
            ;;
        *) printf 'tool-install: unknown kind: %s\n' "$kind" >&2; return 1 ;;
    esac

    # Auditable integrity record. attested_by = the approver (you or a model).
    local approver="${ANTCRATE_TOOL_APPROVED_BY:-unattested}"
    local ts; ts=$(date -u +%FT%TZ)
    printf '{"tool":"%s","version":"%s","url":"%s","sha256":"%s","path":"%s","attested_by":"%s","ts":"%s"}\n' \
        "$name" "$ver" "$url" "$sha" "$placed" "$approver" "$ts" >> "$ANTCRATE_TOOLS_MANIFEST"

    printf 'tool-install: %s %s OK\n  sha256 verified : %s\n  bin             : %s\n  attested_by     : %s\n  manifest        : %s\n' \
        "$name" "$ver" "$sha" "$ANTCRATE_TOOLS_BIN/$name" "$approver" "$ANTCRATE_TOOLS_MANIFEST"
}
