#!/usr/bin/env bash
# antcrate :: lib/duties.sh — human-action checklist (user duties)
#
# Actions only the human can perform (control-plane jq seeds, systemd enables,
# rule-#13 config edits, key rotation, policy approvals) get a first-class
# checklist instead of living as prose inside state.md bullets.
#
#   antcrate --duty "<text>"     append an open item (agents may call freely)
#   antcrate --duties            numbered list of OPEN items
#   antcrate --duty-done <n>     flip nth OPEN item to done (user, or agent on
#                                explicit user instruction)
#
# File: <selfsrc>/duties.md (override: ANTCRATE_DUTIES_FILE). Markdown checklist:
#   - [ ] 2026-06-10 — enable antcrate-intel.timer — why: agents cannot run systemd
#   - [x] 2026-06-10 — seed audit baseline (done 2026-06-10)
# Append/flip ONLY — items are never removed (quarantine philosophy for prose).
#
# Sourced by wrapper. No side effects on source.

_ac_duties_file() {
    if [[ -n "${ANTCRATE_DUTIES_FILE:-}" ]]; then
        printf '%s\n' "$ANTCRATE_DUTIES_FILE"
        return 0
    fi
    local src
    src=$(ac_devops_selfsrc 2>/dev/null) || return 1
    printf '%s/duties.md\n' "$src"
}

ac_duty_add() {
    local text="${1:-}"
    if [[ -z "$text" ]]; then
        ac_error "duty: missing <text>"
        return 2
    fi
    local f
    f=$(_ac_duties_file) || { ac_error "duty: cannot resolve duties.md (set ANTCRATE_DUTIES_FILE or selfsrc)"; return 1; }
    local clean="${text//$'\n'/ }"
    if [[ ! -f "$f" ]]; then
        cat > "$f" <<'EOF'
# AntCrate — User Duties

Actions only the human can perform. Agents append via `antcrate --duty`;
items flip to done via `antcrate --duty-done <n>` — never deleted.

EOF
    fi
    printf -- '- [ ] %s — %s\n' "$(date -u +%F)" "$clean" >> "$f"
    ac_info "duty: appended to $f"
    printf 'Duty recorded. Review with: antcrate --duties\n'
}

ac_duty_list() {
    local f
    f=$(_ac_duties_file) || { ac_error "duties: cannot resolve duties.md"; return 1; }
    if [[ ! -f "$f" ]] || ! grep -q '^- \[ \]' "$f"; then
        printf 'No open duties (%s).\n' "$f"
        return 0
    fi
    printf 'Open duties — %s:\n' "$f"
    grep '^- \[ \]' "$f" | nl -w2 -s'. '
}

ac_duty_done() {
    local n="${1:-}"
    if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
        ac_error "duty-done: need a positive index from --duties (got: '${n:-<missing>}')"
        return 2
    fi
    local f
    f=$(_ac_duties_file) || { ac_error "duty-done: cannot resolve duties.md"; return 1; }
    [[ -f "$f" ]] || { ac_error "duty-done: no duties file at $f"; return 1; }
    local line
    line=$(grep -n '^- \[ \]' "$f" | sed -n "${n}p" | cut -d: -f1)
    if [[ -z "$line" ]]; then
        ac_error "duty-done: no open duty #$n"
        return 1
    fi
    local today; today=$(date -u +%F)
    sed -i "${line}s/^- \[ \]/- [x]/" "$f"
    sed -i "${line}s/\$/ (done ${today})/" "$f"
    ac_info "duty: #$n marked done in $f"
    printf 'Duty #%s marked done.\n' "$n"
}

# one-liner for cmd_status (mirrors ac_intel_status_line)
ac_duties_status_line() {
    local f n=0
    f=$(_ac_duties_file 2>/dev/null) || { printf 'duties: 0 open\n'; return 0; }
    if [[ -f "$f" ]]; then
        n=$(grep -c '^- \[ \]' "$f") || n=0
    fi
    printf 'duties: %s open\n' "$n"
}
