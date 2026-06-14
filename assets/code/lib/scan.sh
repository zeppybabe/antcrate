#!/usr/bin/env bash
# antcrate :: lib/scan.sh — repo leak scan (secrets + publication boundary).
#
# Three composable checks behind `antcrate --scan` and the pre-push guard:
#   secrets  — gitleaks over the working tree (skipped, not failed, if absent).
#   dev-tree — the dev/ records tree must be git-IGNORED, never tracked; a tracked
#              dev/ path means dev-internal content is about to reach the public repo.
#   markers  — OPTIONAL grep for extra dev-internal patterns (foreign home paths,
#              internal hosts). Default empty so this file embeds no private names;
#              set ANTCRATE_SCAN_DEV_MARKERS in your (git-ignored) config to enable.
#
# Exit: 0 clean, 1 any finding.

# Optional |-separated extended-regex; configured per-dev, never hardcoded here.
: "${ANTCRATE_SCAN_DEV_MARKERS:=}"

# ac_scan_gitleaks_bin — print a usable gitleaks path, or return 1.
ac_scan_gitleaks_bin() {
    if command -v gitleaks >/dev/null 2>&1; then command -v gitleaks; return 0; fi
    [[ -x "${ANTCRATE_TOOLS_BIN:-}/gitleaks" ]] && { printf '%s\n' "$ANTCRATE_TOOLS_BIN/gitleaks"; return 0; }
    return 1
}

# ac_scan_secrets <dir> — 0 clean, 1 leaks, 2 gitleaks unavailable.
ac_scan_secrets() {
    local dir="${1:-.}" gl
    gl=$(ac_scan_gitleaks_bin) || return 2
    "$gl" detect --source "$dir" --no-git --no-banner --redact >/dev/null 2>&1
}

# ac_scan_devtree <dir> — the dev/ records tree must be git-ignored. 0 clean, 1 tracked.
ac_scan_devtree() {
    local dir="${1:-.}" tracked
    [[ -d "$dir/.git" ]] || return 0   # not a git repo → nothing to check
    tracked=$(git -C "$dir" ls-files dev/ 2>/dev/null || true)
    [[ -z "$tracked" ]] && return 0
    printf 'scan: dev/ records are TRACKED by git (must be git-ignored):\n' >&2
    printf '%s\n' "$tracked" | sed 's/^/  /' >&2
    return 1
}

# ac_scan_markers <dir> — optional dev-marker grep over the public surface. 0 clean, 1 hits.
ac_scan_markers() {
    [[ -z "$ANTCRATE_SCAN_DEV_MARKERS" ]] && return 0
    local dir="${1:-.}" hits
    hits=$(grep -rIlE "$ANTCRATE_SCAN_DEV_MARKERS" "$dir" \
              --exclude-dir=.git --exclude-dir=dev 2>/dev/null || true)
    [[ -z "$hits" ]] && return 0
    printf 'scan: configured dev markers in public-surface files:\n' >&2
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
    return 1
}

# ac_scan_run <dir> — combined report. 0 clean, 1 any finding.
ac_scan_run() {
    local dir="${1:-.}" rc=0 s
    if ac_scan_secrets "$dir"; then
        printf 'scan: secrets   OK (no leaks)\n'
    else
        s=$?
        if (( s == 2 )); then
            printf 'scan: secrets   SKIPPED (gitleaks unavailable — antcrate --tool-install gitleaks)\n'
        else
            printf 'scan: secrets   FINDINGS — run gitleaks detect for detail\n' >&2; rc=1
        fi
    fi
    ac_scan_devtree  "$dir" && printf 'scan: dev-tree  OK (dev/ not tracked)\n'             || rc=1
    ac_scan_markers  "$dir" && printf 'scan: markers   OK\n'                                || rc=1
    return "$rc"
}
