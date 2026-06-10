#!/usr/bin/env bash
# antcrate :: lib/loop.sh — durable, objective-driven orchestration loop.
#
# Owns run-state in $ANTCRATE_HOME/loops/<id>.json. --loop-tick is a Bash
# state-machine: checks the three hard stops (max-iter, no-progress, budget),
# runs the project CI gate, updates state, and emits an instruction block for
# Clyde. Cadence is delegated to Claude Code's /loop + ScheduleWakeup.
#
# Public API:
#   ac_loop_init    <objective> <project> [max_iter] [budget]
#   ac_loop_tick    <id>
#   ac_loop_signoff <id> <pass|fail> [note]
#   ac_loop_status  <id>
#   ac_loop_list
#   ac_loop_resume  <id>
#   ac_loop_halt    <id> [reason]
#
# Internal (do not call from outside this file): _ac_loop_*
# Sourced by bin/antcrate. Depends on log.sh, registry.sh, canary.sh,
# quarantine.sh, and git/jq at runtime.

: "${ANTCRATE_LOOP_MAX_ITER:=25}"

_ac_loop_dir() {
    printf '%s\n' "${ANTCRATE_HOME:-$HOME/.antcrate}/loops"
}

_ac_loop_gen_id() {
    local project="$1" slug ts
    slug=$(printf '%s' "$project" | tr -c 'a-zA-Z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')
    ts=$(date -u +%Y%m%dT%H%M%S)
    printf '%s-%s\n' "$slug" "$ts"
}

_ac_loop_state_path() {
    printf '%s/loops/%s.json\n' "${ANTCRATE_HOME:-$HOME/.antcrate}" "$1"
}

# Atomic replacement: candidate JSON on stdin -> temp -> mv. (delegate.sh idiom)
_ac_loop_write() {
    local file; file=$(_ac_loop_state_path "$1")
    mkdir -p "$(dirname "$file")"
    local tmp="$file.tmp.$$"
    if cat > "$tmp"; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"; return 1
    fi
}

_ac_loop_get() {
    local file; file=$(_ac_loop_state_path "$1")
    [[ -f "$file" ]] || { ac_error "loop: unknown loop '$1'"; return 1; }
    # Use -r (raw output) so strings print without quotes; numbers print as-is.
    jq -er --arg k "$2" '.[$k]' "$file" 2>/dev/null
}

# Set a top-level scalar field, atomically; rejects writes that don't parse.
_ac_loop_set() {
    local id="$1" key="$2" val="$3"
    local file; file=$(_ac_loop_state_path "$id")
    [[ -f "$file" ]] || { ac_error "loop: unknown loop '$id'"; return 1; }
    local next
    next=$(jq --arg k "$key" --arg v "$val" \
        '.[$k] = $v | .updated = (now | todateiso8601)' "$file") || return 1
    printf '%s\n' "$next" | _ac_loop_write "$id"
}

# The keystone: no autonomous loop unless the safety floor is armed.
# Armed = canary gate fresh (rc 0) AND gateway-guard hook present.
# ANTCRATE_LOOP_ALLOW_UNSAFE=1 bypasses (tests / explicit opt-out only).
_ac_loop_safety_floor_armed() {
    [[ "${ANTCRATE_LOOP_ALLOW_UNSAFE:-}" == "1" ]] && return 0
    if ! ac_canary_gate_check; then
        ac_error "loop: safety floor not armed — canary gate not fresh (run: antcrate --canary-init)"
        return 1
    fi
    local guard="${ANTCRATE_SELFSRC:-$HOME/.claude/skills/antcrate/assets/code}/hooks/claude/gateway-guard.sh"
    if [[ ! -f "$guard" ]]; then
        ac_error "loop: safety floor not armed — gateway-guard hook missing"
        return 1
    fi
    return 0
}

# Echoes the tripped stop name (max-iter|no-progress|budget) or "" if none.
# Order matters: max-iter, then no-progress, then budget.
_ac_loop_check_stops() {
    local id="$1" file; file=$(_ac_loop_state_path "$id")
    local tick max_iter stall ceiling start
    tick=$(jq -r '.tick' "$file");          max_iter=$(jq -r '.max_iter' "$file")
    stall=$(jq -r '.stall_streak' "$file"); ceiling=$(jq -r '.budget_ceiling' "$file")
    start=$(jq -r '.budget_counter_start' "$file")
    if (( tick >= max_iter )); then printf 'max-iter\n'; return 0; fi
    if (( stall >= 3 ));      then printf 'no-progress\n'; return 0; fi
    if [[ "$ceiling" != "null" ]]; then
        local elapsed=$(( $(date -u +%s) - start ))
        if (( elapsed >= ceiling )); then printf 'budget\n'; return 0; fi
    fi
    printf '\n'
}

# Compare the new tree-sha + error-signature against stored; update the
# stall streak. Stalls when the tree did NOT change OR the same error
# recurs. Resets only when the tree advanced AND the error is gone/changed.
_ac_loop_observe() {
    local id="$1" new_sha="$2" new_err="$3"
    local file; file=$(_ac_loop_state_path "$id")
    local next
    next=$(jq --arg sha "$new_sha" --arg err "$new_err" '
        (.last_tree_sha == $sha) as $samesha
        | (($err != "") and (.error_signature == $err)) as $sameerr
        | .stall_streak = (if ($samesha or $sameerr) then (.stall_streak + 1) else 0 end)
        | .last_tree_sha = $sha
        | .error_signature = $err
        | .updated = (now | todateiso8601)' "$file") || return 1
    printf '%s\n' "$next" | _ac_loop_write "$id"
}

ac_loop_init() {
    local objective="$1" project="$2" max_iter="${3:-$ANTCRATE_LOOP_MAX_ITER}" budget="${4:-}"
    [[ -n "$objective" && -n "$project" ]] || { ac_error "loop: --loop requires \"<objective>\" --project <p>"; return 2; }
    ac_registry_has "$project" || { ac_error "loop: project '$project' not registered"; return 2; }
    _ac_loop_safety_floor_armed || return 1
    [[ "$max_iter" =~ ^[1-9][0-9]*$ ]] || max_iter="$ANTCRATE_LOOP_MAX_ITER"

    local id; id=$(_ac_loop_gen_id "$project")
    local now_iso; now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local now_epoch; now_epoch=$(date -u +%s)
    local ceiling="null"; [[ "$budget" =~ ^[1-9][0-9]*$ ]] && ceiling="$budget"

    jq -n \
        --arg id "$id" --arg obj "$objective" --arg proj "$project" \
        --argjson mi "$max_iter" --argjson bstart "$now_epoch" \
        --argjson ceil "$ceiling" --arg now "$now_iso" \
        '{id:$id, objective:$obj, project:$proj, status:"running", tick:0,
          max_iter:$mi, last_tree_sha:"", error_signature:"", stall_streak:0,
          signoff:"none", budget_counter_start:$bstart, budget_ceiling:$ceil,
          checkpoint:{step_completed:"",key_decisions:"",current_state:"",next_step:""},
          created:$now, updated:$now}' \
        | _ac_loop_write "$id" || return 1

    ac_info "loop: initialized '$id' for project '$project' (max-iter $max_iter)"
    printf 'Paste this into Claude Code to start the loop, then walk away:\n\n'
    printf '  /loop antcrate --loop-tick %s\n' "$id"
}

# Halt: write checkpoint, append ledger, quarantine uncommitted WIP, set
# status=halted-<reason>, stop. Reason is one of the stop names or "manual".
_ac_loop_halt() {
    local id="$1" reason="$2"
    local file; file=$(_ac_loop_state_path "$id")
    local project tick objective
    project=$(jq -r '.project' "$file"); tick=$(jq -r '.tick' "$file")
    objective=$(jq -r '.objective' "$file")

    # checkpoint (the doc's memory-file format)
    local next
    next=$(jq --arg r "$reason" '
        .status = ("halted-" + $r)
        | .checkpoint.current_state = ("halted at tick " + (.tick|tostring) + " due to " + $r)
        | .checkpoint.next_step = "resume with: antcrate --loop-resume " + .id
        | .updated = (now | todateiso8601)' "$file") || return 1
    printf '%s\n' "$next" | _ac_loop_write "$id" || return 1

    # ledger line (append only)
    local ledger="${ANTCRATE_LEDGER:-$HOME/.claude/skills/antcrate/ledger.md}"
    printf '\n## %s — loop %s halted-%s\n\n%s (tick %s)\n' \
        "$(date -u +%Y-%m-%d)" "$id" "$reason" "$objective" "$tick" >> "$ledger" 2>/dev/null || true

    # quarantine uncommitted WIP (Gateway Law: never leave a half-edit live)
    local ppath; ppath=$(ac_registry_get "$project" path 2>/dev/null)
    if [[ -n "$ppath" ]] && ! _ac_quarantine_capture "$project" "$ppath" "loop-halt" "loop-$id-$reason"; then
        _ac_loop_set "$id" wip_quarantine "failed" || true
        ac_warn "loop: WIP quarantine failed for '$id'; resume will warn"
    fi
    ac_info "loop: '$id' halted ($reason)"
}

# git tree hash of the project (override in tests). Empty if not a git repo.
_ac_loop_tree_sha() {
    local ppath="$1"
    git -C "$ppath" rev-parse 'HEAD^{tree}' 2>/dev/null || git -C "$ppath" rev-parse HEAD 2>/dev/null || printf '\n'
}

# Run the project CI gate. Prints an error-signature on failure (empty when
# green); returns 0 green / non-zero red. Override in tests.
_ac_loop_run_ci() {
    local ppath="$1"
    local out
    if out=$(bash "${ANTCRATE_SELFSRC:-$HOME/.claude/skills/antcrate/assets/code}/bin/antcrate" --ci 2>&1); then
        printf '\n'; return 0
    fi
    printf '%s\n' "$out" | grep -iE 'fail|error|not ok' | head -1
    return 1
}

ac_loop_tick() {
    local id="$1"
    local file; file=$(_ac_loop_state_path "$id")
    [[ -f "$file" ]] || { ac_error "loop: unknown loop '$id'"; return 1; }
    local st; st=$(jq -r '.status' "$file")
    if [[ "$st" != "running" ]]; then
        printf 'Loop %s is %s (not running). LOOP COMPLETE — do not reschedule.\n' "$id" "$st"
        return 0
    fi

    # 1. stops first
    local tripped; tripped=$(_ac_loop_check_stops "$id")
    if [[ -n "$tripped" ]]; then
        _ac_loop_halt "$id" "$tripped"
        printf 'Loop %s halted (%s). LOOP COMPLETE — do not reschedule.\n' "$id" "$tripped"
        return 0
    fi

    # 2. observe progress: tree-sha + CI error-signature
    local project ppath; project=$(jq -r '.project' "$file")
    ppath=$(ac_registry_get "$project" path 2>/dev/null)
    local sha err ci_rc
    sha=$(_ac_loop_tree_sha "$ppath")
    err=$(_ac_loop_run_ci "$ppath"); ci_rc=$?
    [[ -z "$err" || "$err" == $'\n' ]] && err=""
    _ac_loop_observe "$id" "$sha" "$err"

    # 3. increment tick
    local next; next=$(jq '.tick += 1 | .updated = (now | todateiso8601)' "$file")
    printf '%s\n' "$next" | _ac_loop_write "$id"

    # 4. two-key done decision: CI green AND signoff pass
    local signoff; signoff=$(jq -r '.signoff' "$file")
    if (( ci_rc == 0 )) && [[ "$signoff" == "pass" ]]; then
        _ac_loop_set "$id" status "done"
        printf 'Loop %s: objective verified (CI green + sign-off). LOOP COMPLETE — do not reschedule.\n' "$id"
        return 0
    fi

    # 5. emit the Clyde instruction block + RESCHEDULE contract
    local objective tick; objective=$(jq -r '.objective' "$file"); tick=$(jq -r '.tick' "$file")
    cat <<EOF
── Loop $id · tick $tick ──
Objective : $objective
Project   : $project
CI gate   : $( ((ci_rc==0)) && echo GREEN || echo "RED — $err" )
Sign-off  : $signoff
Next for Clyde:
  $( ((ci_rc==0)) \
       && echo "CI is green. Dispatch Claudia to verify the objective is semantically met, then: antcrate --loop-signoff $id pass|fail" \
       || echo "Dispatch Cody to address the CI failure above (max 3 attempts on the same wall — the no-progress stop is watching)." )
RESCHEDULE — call ScheduleWakeup to fire the next: antcrate --loop-tick $id
EOF
}

# Clyde records Claudia's semantic verdict. Consumed by the next tick's
# done-decision (the second key of the two-key verify gate).
ac_loop_signoff() {
    local id="$1" verdict="$2"
    case "$verdict" in
        pass|fail) ;;
        *) ac_error "loop: signoff verdict must be 'pass' or 'fail'"; return 2 ;;
    esac
    _ac_loop_set "$id" signoff "$verdict" || return 1
    ac_info "loop: '$id' sign-off recorded: $verdict"
}

ac_loop_status() {
    local id="$1" mode="${2:-}"
    local file; file=$(_ac_loop_state_path "$id")
    [[ -f "$file" ]] || { ac_error "loop: unknown loop '$id'"; return 1; }
    if [[ "$mode" == "--porcelain" ]]; then cat "$file"; return 0; fi
    jq -r '"loop      : \(.id)\nproject   : \(.project)\nstatus    : \(.status)\ntick      : \(.tick)/\(.max_iter)\nstall     : \(.stall_streak)\nsign-off  : \(.signoff)\nobjective : \(.objective)"' "$file"
}

ac_loop_list() {
    local dir; dir=$(_ac_loop_dir)
    [[ -d "$dir" ]] || { ac_info "loop: no loops yet"; return 0; }
    local f
    for f in "$dir"/*.json; do
        [[ -e "$f" ]] || continue
        jq -r '"\(.id)\t\(.status)\ttick \(.tick)/\(.max_iter)"' "$f"
    done
}

ac_loop_resume() {
    local id="$1"
    local file; file=$(_ac_loop_state_path "$id")
    [[ -f "$file" ]] || { ac_error "loop: unknown loop '$id'"; return 1; }
    local wipq; wipq=$(jq -r '.wip_quarantine // ""' "$file")
    [[ "$wipq" == "failed" ]] && ac_warn "loop: prior WIP quarantine FAILED — inspect the tree before resuming"
    _ac_loop_set "$id" status "running" || return 1
    jq -r '"We are resuming loop \(.id) from a previous session.\nObjective: \(.objective)\nCurrent state: \(.checkpoint.current_state)\nNext step: \(.checkpoint.next_step)\n\nConfirm understanding, identify the next step, do NOT repeat completed work, then: antcrate --loop-tick \(.id)"' "$file"
}

# Manual halt wrapper (public). Reason defaults to "manual".
ac_loop_halt() {
    local id="$1" reason="${2:-manual}"
    local file; file=$(_ac_loop_state_path "$id")
    [[ -f "$file" ]] || { ac_error "loop: unknown loop '$id'"; return 1; }
    _ac_loop_halt "$id" "$reason"
}
