#!/usr/bin/env bash
# antcrate :: lib/delegate.sh — Clyde-side wrapper for handing focused
# code work to project-scoped Cody under a per-key attempt budget.
#
# Closes proposal #93 (the last piece of the agent layer). Each project
# has <project>/.antcrate/cody-attempts.json — a flat object keyed by
# whatever string identifies the unit-under-edit (e.g. "src/foo.sh:42",
# "validateInput", "README.md"). On every delegation Clyde calls this
# library to:
#   1. Verify the key has not exceeded the threshold (default 3).
#   2. Increment the counter (atomic temp+mv).
#   3. Emit a `delegate` activity event so --watch paints the file green.
#   4. Print a copy-pasteable delegation block Clyde feeds to
#      <project>-cody (the project-scoped Cody pointer dropped by
#      lib/agent_init.sh).
#
# Threshold semantics (matches cody.md's three-attempt rule):
#   counter at 0..(threshold-1) — delegation succeeds, increments first
#   counter at >= threshold     — REFUSED (exit code 3); Cody is being
#                                  re-delegated without progress; escalate
#                                  to the user instead of guessing again.
# Override threshold via ANTCRATE_DELEGATE_THRESHOLD.
#
# Public API:
#   ac_delegate_run     <project> <key> <task> [file]
#   ac_delegate_reset   <project> [key]
#   ac_delegate_status  <project>
#
# Internal (do not call from outside this file):
#   _ac_delegate_attempts_path  — resolve cody-attempts.json
#   _ac_delegate_attempts_get   — read count for a key (0 if absent)
#   _ac_delegate_attempts_inc   — atomic +1, prints new count
#   _ac_delegate_attempts_write — atomic JSON replacement
#   _ac_delegate_threshold      — env override or default 3
#   _ac_delegate_print_block    — handoff block to stdout
# Reason: callers should go through ac_delegate_run so threshold check,
# event emission, and output format stay coupled.
#
# Sourced by wrapper. Depends on registry.sh, events.sh, log.sh.

: "${ANTCRATE_DELEGATE_THRESHOLD:=3}"

_ac_delegate_threshold() {
    local t="${ANTCRATE_DELEGATE_THRESHOLD:-3}"
    [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=3
    printf '%s\n' "$t"
}

_ac_delegate_attempts_path() {
    local project="$1"
    local p
    p=$(ac_registry_get "$project" path 2>/dev/null) || return 1
    [[ -n "$p" ]] || return 1
    printf '%s/.antcrate/cody-attempts.json\n' "$p"
}

_ac_delegate_attempts_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { printf '0\n'; return 0; }
    jq -r --arg k "$key" '(.[$k] // 0)' "$file" 2>/dev/null \
        || printf '0\n'
}

_ac_delegate_attempts_write() {
    # Atomic replacement: write to .tmp then mv. Caller passes new JSON
    # on stdin.
    local file="$1"
    local dir
    dir=$(dirname "$file")
    mkdir -p "$dir"
    local tmp="$file.tmp.$$"
    if cat > "$tmp"; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

_ac_delegate_attempts_inc() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || printf '%s\n' '{}' > "$file"
    local new
    new=$(jq --arg k "$key" '. + {($k): ((.[$k] // 0) + 1)}' "$file") || return 1
    printf '%s\n' "$new" | _ac_delegate_attempts_write "$file" || return 1
    jq -r --arg k "$key" '.[$k]' "$file"
}

_ac_delegate_print_block() {
    local project="$1" key="$2" task="$3" file="$4" attempt="$5" threshold="$6"
    local display_file="$file"
    [[ -z "$display_file" ]] && display_file="$key"
    cat <<EOF
─── Delegate to ${project}-cody ───
project : ${project}
key     : ${key}
attempt : ${attempt} of ${threshold}
file    : ${display_file}
task    : ${task}
──────────────────────────────────
Hand the block above to ${project}-cody. Cody must:
- Read CLAUDE.md and the relevant section of state.md / ledger.md first.
- Make the edit, then run the project's test command.
- Self-review with the \`simplify\` skill before reporting back.
- After ${threshold} failed attempts on this key, surface back to Clyde
  with a short failure report. Don't keep guessing past the threshold.
EOF
}

# ac_delegate_run <project> <key> <task> [file]
# Pre-increment threshold check; on success increments counter, emits a
# delegate event, prints the handoff block. Refusal exits 3.
ac_delegate_run() {
    local project="${1:-}" key="${2:-}" task="${3:-}" file="${4:-}"
    [[ -n "$project" ]] || { ac_error "delegate: missing <project>"; return 2; }
    [[ -n "$key" ]]     || { ac_error "delegate: missing --key <key>"; return 2; }
    [[ -n "$task" ]]    || { ac_error "delegate: missing --task <description>"; return 2; }

    if ! ac_registry_has "$project"; then
        ac_error "delegate: unknown project '$project' (use --register or --start first)"
        return 1
    fi

    local file_path
    file_path=$(_ac_delegate_attempts_path "$project") || {
        ac_error "delegate: failed to resolve attempts file for '$project'"
        return 1
    }

    # Lifecycle treatment usually creates the attempts file at register/
    # start time. If a project predates lifecycle wiring or the file was
    # deleted, recreate it lazily.
    if [[ ! -f "$file_path" ]]; then
        mkdir -p "$(dirname "$file_path")"
        printf '%s\n' '{}' > "$file_path"
    fi

    local threshold current
    threshold=$(_ac_delegate_threshold)
    current=$(_ac_delegate_attempts_get "$file_path" "$key")

    if (( current >= threshold )); then
        cat <<EOF
─── REFUSED: --delegate threshold reached ───
project   : ${project}
key       : ${key}
attempts  : ${current} (>= threshold of ${threshold})
─────────────────────────────────────────────
${project}-cody has been delegated to ${current} times on this key
without success. Per cody.md's three-attempt rule, escalate to the
user instead of delegating again — four shallow attempts cost more
than one deeper investigation.

To deliberately reset and continue (e.g. after the user reframed the
problem):
  antcrate --delegate-reset ${project} --key '${key}'
EOF
        return 3
    fi

    local new_count
    new_count=$(_ac_delegate_attempts_inc "$file_path" "$key") || {
        ac_error "delegate: failed to increment attempts for '$key'"
        return 1
    }

    local event_path="$file"
    [[ -z "$event_path" ]] && event_path="$key"
    ac_events_emit "$project" delegate "$event_path" \
        --label "key=${key} attempt=${new_count}/${threshold}" \
        --agent "clyde" >/dev/null 2>&1 || true

    _ac_delegate_print_block "$project" "$key" "$task" "$file" "$new_count" "$threshold"
    return 0
}

# ac_delegate_reset <project> [key]
# With a key: zero that one entry. Without: replace the file with {}.
ac_delegate_reset() {
    local project="${1:-}" key="${2:-}"
    [[ -n "$project" ]] || { ac_error "delegate-reset: missing <project>"; return 2; }
    if ! ac_registry_has "$project"; then
        ac_error "delegate-reset: unknown project '$project'"
        return 1
    fi

    local file_path
    file_path=$(_ac_delegate_attempts_path "$project") || return 1

    if [[ ! -f "$file_path" ]]; then
        mkdir -p "$(dirname "$file_path")"
        printf '%s\n' '{}' > "$file_path"
        ac_info "delegate-reset: counter file created (was missing)"
        return 0
    fi

    if [[ -z "$key" ]]; then
        printf '%s\n' '{}' > "$file_path"
        ac_info "delegate-reset: cleared all attempts for '$project'"
        return 0
    fi

    local new
    new=$(jq --arg k "$key" 'del(.[$k])' "$file_path") || return 1
    printf '%s\n' "$new" | _ac_delegate_attempts_write "$file_path" || return 1
    ac_info "delegate-reset: cleared '$key' for '$project'"
    return 0
}

# ac_delegate_status <project>
# Lists non-zero attempt counters, sorted by count descending.
ac_delegate_status() {
    local project="${1:-}"
    [[ -n "$project" ]] || { ac_error "delegate-status: missing <project>"; return 2; }
    if ! ac_registry_has "$project"; then
        ac_error "delegate-status: unknown project '$project'"
        return 1
    fi

    local file_path
    file_path=$(_ac_delegate_attempts_path "$project") || return 1

    local threshold
    threshold=$(_ac_delegate_threshold)

    printf 'project   : %s\n' "$project"
    printf 'threshold : %s\n' "$threshold"
    if [[ ! -f "$file_path" ]]; then
        printf 'attempts  : (counter file missing)\n'
        return 0
    fi

    local count
    count=$(jq -r 'to_entries | map(select(.value > 0)) | length' "$file_path" 2>/dev/null || echo 0)
    if [[ "$count" == "0" ]]; then
        printf 'attempts  : (none)\n'
        return 0
    fi

    printf 'attempts  :\n'
    jq -r 'to_entries
           | map(select(.value > 0))
           | sort_by(-.value)
           | .[]
           | "  \(.value)  \(.key)"' "$file_path" 2>/dev/null
}
