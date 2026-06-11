# Session-Budget Gate + User Duties Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hook-enforce the least-cost policy: warn at 100k context, hard-block all non-wrap-up tools at 140k until the user `/clear`s — plus a first-class checklist (`duties.md` + `--duty` flags) for actions only the human can perform.

**Architecture:** Two units. (1) `lib/duties.sh` clones the `propose.sh` pattern: tiny append/flip helpers over a markdown checklist, plus a rc-guarded `--status` line. (2) `hooks/claude/session-budget-guard.sh` clones the `env-guard.sh` pattern: PreToolUse hook (matcher `*`), reads context size from the transcript's last `usage` record, stateless (a fresh post-`/clear` transcript measures small), fails open.

**Tech Stack:** Pure Bash 5+, jq, bats. Spec: `docs/specs/2026-06-10-session-budget-gate-and-duties-design.md`.

**Repo root:** `~/projects/antcrate` (= `~/.claude/skills/antcrate`). Code under `assets/code/`. Run bats from `assets/code/`. Baseline: 591 bats. This build crosses the 598 audit line → Task 9 runs the codebase audit.

---

### Task 1: duties tests (RED)

**Files:**
- Test: `assets/code/tests/duties.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
# tests for lib/duties.sh — human-action checklist (user duties)
#
# Actions only the human can perform (control-plane seeds, systemd enables,
# rule-#13 config edits, key rotation) live in duties.md as a markdown
# checklist. Append/flip only — items are never removed (quarantine
# philosophy applied to prose).

setup() {
    LIB="$BATS_TEST_DIRNAME/../lib"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_DUTIES_FILE="$BATS_TEST_TMPDIR/duties.md"
    export ANTCRATE_LOG_LEVEL="error"
    mkdir -p "$ANTCRATE_HOME"
}

src() {
    bash -c "
        export ANTCRATE_HOME='$ANTCRATE_HOME'
        export ANTCRATE_DUTIES_FILE='$ANTCRATE_DUTIES_FILE'
        export ANTCRATE_LOG_LEVEL='$ANTCRATE_LOG_LEVEL'
        . '$LIB/log.sh'
        . '$LIB/duties.sh'
        $1
    "
}

@test "duty: add creates file with header and checkbox line" {
    run src "ac_duty_add 'rotate gh token — why: owner-only credential'"
    [ "$status" -eq 0 ]
    grep -q '^# AntCrate — User Duties' "$ANTCRATE_DUTIES_FILE"
    grep -Eq '^- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2} — rotate gh token — why: owner-only credential$' "$ANTCRATE_DUTIES_FILE"
}

@test "duty: add appends, order preserved" {
    src "ac_duty_add 'first'" >/dev/null
    src "ac_duty_add 'second'" >/dev/null
    [ "$(grep -c '^- \[ \]' "$ANTCRATE_DUTIES_FILE")" -eq 2 ]
    [ "$(grep -n 'first' "$ANTCRATE_DUTIES_FILE" | cut -d: -f1)" -lt "$(grep -n 'second' "$ANTCRATE_DUTIES_FILE" | cut -d: -f1)" ]
}

@test "duty: add with empty text exits 2" {
    run src "ac_duty_add ''"
    [ "$status" -eq 2 ]
}

@test "duty: add flattens embedded newlines" {
    run src "ac_duty_add 'line one
line two'"
    [ "$status" -eq 0 ]
    grep -q '^- \[ \] .* — line one line two$' "$ANTCRATE_DUTIES_FILE"
}

@test "duties: list numbers OPEN items only" {
    src "ac_duty_add 'open one'" >/dev/null
    src "ac_duty_add 'open two'" >/dev/null
    src "ac_duty_done 1" >/dev/null
    run src "ac_duty_list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"1."*"open two"* ]]
    [[ "$output" != *"open one"* ]]
}

@test "duties: empty list exits 0 with 'No open duties'" {
    run src "ac_duty_list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No open duties"* ]]
}

@test "duty-done: flips nth open item and stamps done-date" {
    src "ac_duty_add 'alpha'" >/dev/null
    src "ac_duty_add 'beta'" >/dev/null
    run src "ac_duty_done 2"
    [ "$status" -eq 0 ]
    grep -Eq '^- \[x\] .* — beta \(done [0-9]{4}-[0-9]{2}-[0-9]{2}\)$' "$ANTCRATE_DUTIES_FILE"
    grep -q '^- \[ \] .* — alpha$' "$ANTCRATE_DUTIES_FILE"
}

@test "duty-done: out-of-range index exits 1; non-numeric exits 2" {
    src "ac_duty_add 'only'" >/dev/null
    run src "ac_duty_done 5"
    [ "$status" -eq 1 ]
    run src "ac_duty_done abc"
    [ "$status" -eq 2 ]
}

@test "duties: status line counts open only" {
    src "ac_duty_add 'a'" >/dev/null
    src "ac_duty_add 'b'" >/dev/null
    src "ac_duty_done 1" >/dev/null
    run src "ac_duties_status_line"
    [ "$status" -eq 0 ]
    [ "$output" = "duties: 1 open" ]
}
```

- [ ] **Step 2: Run to verify RED**

Run: `cd ~/projects/antcrate/assets/code && bats tests/duties.bats`
Expected: 9 failures (exit 127 class — `ac_duty_add: command not found` since `lib/duties.sh` doesn't exist).

---

### Task 2: `lib/duties.sh` (GREEN)

**Files:**
- Create: `assets/code/lib/duties.sh`

- [ ] **Step 1: Write the implementation**

```bash
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
        printf '# AntCrate — User Duties\n\nActions only the human can perform. Agents append via `antcrate --duty`;\nitems flip to done via `antcrate --duty-done <n>` — never deleted.\n\n' > "$f"
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
```

- [ ] **Step 2: Run to verify GREEN**

Run: `cd ~/projects/antcrate/assets/code && bats tests/duties.bats`
Expected: 9/9 PASS.

- [ ] **Step 3: Shellcheck**

Run: `shellcheck assets/code/lib/duties.sh` (from repo root)
Expected: clean (no output).

- [ ] **Step 4: Commit**

```bash
ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate \
  -m "feat(duties): lib/duties.sh — human-action checklist (TDD, 9 bats)" \
  -- assets/code/lib/duties.sh assets/code/tests/duties.bats
```

---

### Task 3: wrapper wiring (`--duty` / `--duties` / `--duty-done` + status line)

**Files:**
- Modify: `assets/code/bin/antcrate` — source block (~line 46), usage (~line 186), arg parse (~line 611), `cmd_status` (~line 384), dispatch (~line 1009)
- Modify: `assets/docs/PATTERNS.md` — flag-by-intent rows

- [ ] **Step 1: Source the lib** — next to the `propose.sh` source line:

```bash
# shellcheck disable=SC1091
. "$LIB_DIR/duties.sh"
```

- [ ] **Step 2: Usage lines** — in the usage text near `--propose`:

```
  --duty "<text>"                     append a human-only action to duties.md (checklist)
  --duties                            numbered list of OPEN duties
  --duty-done <n>                     mark nth open duty done (user-driven)
```

- [ ] **Step 3: Globals + arg parsing** — add `DUTY_TEXT="" DUTY_N=""` to the globals block (~line 403), then in the parse `case` (house idiom — copy the `--propose` shift dance):

```bash
        --duty)
            ACTION="duty"
            if [[ $# -ge 2 && -n "${2:-}" && "${2:0:2}" != "--" ]]; then
                DUTY_TEXT="$2"; shift 2
            else
                shift
            fi ;;
        --duties)            ACTION="duties"; shift ;;
        --duty-done)         ACTION="duty-done"; DUTY_N="${2:-}"; shift 2 ;;
```

- [ ] **Step 4: Dispatch** — next to the `propose)` arm:

```bash
    duty)
        [[ -z "$DUTY_TEXT" ]] && { ac_error "--duty requires \"<text>\""; exit 2; }
        ac_duty_add "$DUTY_TEXT" ;;
    duties)    ac_duty_list ;;
    duty-done) ac_duty_done "$DUTY_N" ;;
```

- [ ] **Step 5: Status line** — in `cmd_status()`, after the `audit_out` block (field width matches `selfsrc   :` / `intel     :` — `duties` is 6 chars so 4 spaces):

```bash
    local duties_out
    duties_out=$(ac_duties_status_line 2>/dev/null) || true
    [[ -n "$duties_out" ]] && printf '  %s\n' "${duties_out/: /    : }"
```

- [ ] **Step 6: PATTERNS.md rows** — add to the flag-by-intent table, matching surrounding format:

```
| record an action only the human can do | `antcrate --duty "<text>"` | appended to duties.md, surfaced in --status + session gate |
| see open human duties | `antcrate --duties` | numbered; mark done with `--duty-done <n>` (user-driven) |
```

- [ ] **Step 7: Install + live smoke**

```bash
cd ~/projects/antcrate/assets/code
antcrate --install-from-source
antcrate --duty "smoke item — delete-me-not, flip me" && antcrate --duties && antcrate --duty-done 1
antcrate --status | grep duties
```
Expected: add → list shows `1.` → done flips; status shows `duties    : 0 open` (the smoke item flipped; real seeds come in Task 7).

- [ ] **Step 8: Full suite + commit**

Run: `antcrate --ci` — Expected: PASS, 600 bats (591+9), shellcheck clean.

```bash
ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate \
  -m "feat(duties): wrapper wiring + duties status line + PATTERNS rows" \
  -- assets/code/bin/antcrate assets/docs/PATTERNS.md duties.md
```

---

### Task 4: session-gate tests (RED)

**Files:**
- Test: `assets/code/tests/session_gate.bats`

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
# tests for hooks/claude/session-budget-guard.sh — context-window session gate
#
# Gate measures the LAST usage record in the session transcript (input +
# cache_read + cache_creation). Soft (default 100k) warns, throttled per 10k
# growth. Hard (default 140k) blocks everything except the wrap-up whitelist.
# Stateless across /clear: a fresh transcript measures small. Fails OPEN.

setup() {
    HOOK="$BATS_TEST_DIRNAME/../hooks/claude/session-budget-guard.sh"
    export ANTCRATE_SESSION_GATE_DIR="$BATS_TEST_TMPDIR/gate"
    export ANTCRATE_SESSION_SOFT=100000
    export ANTCRATE_SESSION_HARD=140000
}

# mk_transcript <input_tokens> [cache_read] — fixture JSONL, prints its path
mk_transcript() {
    local f="$BATS_TEST_TMPDIR/transcript.jsonl"
    printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$f"
    printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0,"output_tokens":12}}}\n' \
        "$1" "${2:-0}" >> "$f"
    printf '%s' "$f"
}

# run_hook <tool_name> <tool_input_json> <transcript_path>
run_hook() {
    printf '{"session_id":"testsess","transcript_path":"%s","tool_name":"%s","tool_input":%s}' \
        "$3" "$1" "$2" | "$HOOK"
}

@test "gate: under soft — silent allow" {
    t=$(mk_transcript 50000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gate: cache_read counts toward context" {
    t=$(mk_transcript 2000 145000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: soft — allows but emits systemMessage warn" {
    t=$(mk_transcript 112000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 0 ]
    [[ "$output" == *'systemMessage'* ]]
    [[ "$output" == *'soft limit'* ]]
}

@test "gate: soft warn throttled until +10k growth" {
    t=$(mk_transcript 112000)
    run_hook Bash '{"command":"x"}' "$t" >/dev/null
    run run_hook Bash '{"command":"x"}' "$t"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    t=$(mk_transcript 123000)
    run run_hook Bash '{"command":"x"}' "$t"
    [[ "$output" == *'systemMessage'* ]]
}

@test "gate: hard blocks non-whitelisted Bash with checklist" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 2 ]
    [[ "$output" == *'SESSION HARD LIMIT'* ]]
    [[ "$output" == *'/clear'* ]]
}

@test "gate: hard allows each wrap-up command" {
    t=$(mk_transcript 143000)
    while IFS= read -r c; do
        run run_hook Bash "{\"command\":\"$c\"}" "$t"
        [ "$status" -eq 0 ]
    done <<'EOF'
antcrate --commit antcrate -m wrap
antcrate --pp antcrate
antcrate --status
antcrate --duties
antcrate --duty add-me
antcrate --duty-done 1
antcrate --emit-activity antcrate --kind note
git status
git diff HEAD
git log --oneline -5
git add ledger.md
EOF
}

@test "gate: hard allows preapproved non-TTY commit form" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate -m wrap -- ledger.md"}' "$t"
    [ "$status" -eq 0 ]
}

@test "gate: hard — quoted text cannot smuggle a segment" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"antcrate --commit antcrate -m \"feat: a && b; c\" -- ledger.md"}' "$t"
    [ "$status" -eq 0 ]
}

@test "gate: hard — compound with non-whitelisted segment blocks" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"git status && make deploy"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: hard — command substitution always blocks" {
    t=$(mk_transcript 143000)
    run run_hook Bash '{"command":"git log $(whoami)"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: hard — Edit allowed only on the four state files" {
    t=$(mk_transcript 143000)
    for f in state.md ledger.md state-archive.md duties.md; do
        run run_hook Edit "{\"file_path\":\"/home/u/projects/antcrate/$f\"}" "$t"
        [ "$status" -eq 0 ]
    done
    run run_hook Edit '{"file_path":"/home/u/projects/antcrate/assets/code/lib/cost.sh"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: hard — Read/Grep/Glob allowed, Task blocked" {
    t=$(mk_transcript 143000)
    run run_hook Read '{"file_path":"/etc/hostname"}' "$t"
    [ "$status" -eq 0 ]
    run run_hook Grep '{"pattern":"x"}' "$t"
    [ "$status" -eq 0 ]
    run run_hook Task '{"prompt":"spawn"}' "$t"
    [ "$status" -eq 2 ]
}

@test "gate: fails OPEN on missing transcript and garbage JSONL" {
    run run_hook Bash '{"command":"make build"}' "/nonexistent/t.jsonl"
    [ "$status" -eq 0 ]
    g="$BATS_TEST_TMPDIR/garbage.jsonl"
    printf 'not json at all\n{broken\n' > "$g"
    run run_hook Bash '{"command":"make build"}' "$g"
    [ "$status" -eq 0 ]
}

@test "gate: DISABLE hatch bypasses even hard" {
    t=$(mk_transcript 190000)
    ANTCRATE_SESSION_GATE_DISABLE=1 run run_hook Bash '{"command":"make build"}' "$t"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify RED**

Run: `cd ~/projects/antcrate/assets/code && bats tests/session_gate.bats`
Expected: 14 failures (hook script missing → exec error / status 127).

---

### Task 5: `session-budget-guard.sh` (GREEN)

**Files:**
- Create: `assets/code/hooks/claude/session-budget-guard.sh` (chmod +x)

- [ ] **Step 1: Write the hook**

```bash
#!/usr/bin/env bash
# session-budget-guard.sh — Claude Code PreToolUse hook (matcher: *).
#
# Gates the session on CONTEXT-WINDOW health (spec:
# docs/specs/2026-06-10-session-budget-gate-and-duties-design.md).
# context = input + cache_read + cache_creation of the LAST usage record in
# the transcript. Soft limit warns (throttled per 10k growth); hard limit
# blocks everything except the wrap-up whitelist until the USER runs /clear —
# a fresh transcript measures small, so the measurement IS the state (no flag
# files). Fails OPEN: a health guard must never brick the session it guards.
#
# NOTE: no `set -e` — the guard must always exit with its own computed code.
set -uo pipefail

[ "${ANTCRATE_SESSION_GATE_DISABLE:-0}" = "1" ] && exit 0

SOFT="${ANTCRATE_SESSION_SOFT:-100000}"
HARD="${ANTCRATE_SESSION_HARD:-140000}"
GATE_DIR="${ANTCRATE_SESSION_GATE_DIR:-$HOME/.antcrate/session-gate}"

payload="$(cat)"

transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0    # fail open

# Last usage record wins. fromjson? makes garbage lines a no-op, not an error.
context="$(tail -n 200 "$transcript" 2>/dev/null \
    | jq -R 'fromjson? | .message.usage? // empty
             | select(type == "object" and .input_tokens != null)
             | .input_tokens + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null \
    | tail -n 1)"
[ -n "$context" ] || exit 0                               # fail open
case "$context" in *[!0-9]*) exit 0 ;; esac               # fail open

[ "$context" -lt "$SOFT" ] && exit 0

session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || session_id="$(printf '%s' "$transcript" | cksum | cut -d' ' -f1)"

# ---- soft stage: warn, throttled per 10k growth -----------------------------
if [ "$context" -lt "$HARD" ]; then
    mkdir -p "$GATE_DIR" 2>/dev/null || exit 0
    # stale markers are gate-internal state (not user data) — prune >7 days
    find "$GATE_DIR" -name '*.lastwarn' -mtime +7 -delete 2>/dev/null
    marker="$GATE_DIR/$session_id.lastwarn"
    last=0
    [ -f "$marker" ] && last="$(cat "$marker" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $(( context - last )) -ge 10000 ]; then
        printf '%s\n' "$context" > "$marker"
        printf '{"systemMessage":"session-budget-guard: context %sk — soft limit %sk (hard %sk). Wrap up after the current task: commit, push, state.md objective, review duties, then /clear."}\n' \
            "$(( context / 1000 ))" "$(( SOFT / 1000 ))" "$(( HARD / 1000 ))"
    fi
    exit 0
fi

# ---- hard stage: wrap-up whitelist only -------------------------------------

block() {
    duties_note=""
    if command -v antcrate >/dev/null 2>&1; then
        n="$(antcrate --duties 2>/dev/null | grep -c '^ *[0-9]')" || n=""
        [ -n "$n" ] && duties_note=" ($n open)"
    fi
    printf 'SESSION HARD LIMIT: context %sk >= %sk. %s\nWrap up now — only wrap-up tools are allowed:\n  1. commit:  antcrate --commit <project> -m "..."\n  2. push:    antcrate --pp <project>\n  3. state:   write the resume objective into state.md (rolling protocol)\n  4. duties:  antcrate --duties%s — review with the user\n  5. then the USER runs /clear to start a fresh session.\n' \
        "$(( context / 1000 ))" "$(( HARD / 1000 ))" "$1" "$duties_note" >&2
    exit 2
}

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"

_seg_allowed() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"    # ltrim
    [ -z "$s" ] && return 0
    case "$s" in
        antcrate\ --commit*|antcrate\ --pp*|antcrate\ --status*|antcrate\ --duties*|antcrate\ --duty*|antcrate\ --emit-activity*) return 0 ;;
        ANTCRATE_COMMIT_PREAPPROVED=1\ antcrate\ --commit*) return 0 ;;
        git\ status*|git\ diff*|git\ log*|git\ add*) return 0 ;;
    esac
    return 1
}

case "$tool" in
    Read|Grep|Glob) exit 0 ;;
    Edit|Write|MultiEdit)
        fpath="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
        case "$(basename "$fpath")" in
            state.md|ledger.md|state-archive.md|duties.md) exit 0 ;;
        esac
        block "(edit target is not a wrap-up state file)"
        ;;
    Bash)
        cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        # quoted spans cannot start a new command segment — drop before split
        stripped="$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")"
        case "$stripped" in *'$('*|*'`'*) block "(command substitution not allowed past the hard limit)" ;; esac
        ok=1
        while IFS= read -r seg; do
            _seg_allowed "$seg" || { ok=0; break; }
        done <<EOF
$(printf '%s\n' "$stripped" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g')
EOF
        [ "$ok" -eq 1 ] && exit 0
        block "(command is not on the wrap-up whitelist)"
        ;;
    *) block "(tool '$tool' not allowed past the hard limit)" ;;
esac
```

- [ ] **Step 2: `chmod +x assets/code/hooks/claude/session-budget-guard.sh`**

- [ ] **Step 3: Run to verify GREEN**

Run: `cd ~/projects/antcrate/assets/code && bats tests/session_gate.bats`
Expected: 14/14 PASS.

- [ ] **Step 4: Shellcheck**

Run: `shellcheck assets/code/hooks/claude/session-budget-guard.sh`
Expected: clean. If SC2317/SC2086 fire, fix the code rather than disabling (defensive-disable review is part of the 598 audit).

- [ ] **Step 5: Commit**

```bash
ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate \
  -m "feat(hooks): session-budget-guard — context-window gate, soft 100k / hard 140k (TDD, 14 bats)" \
  -- assets/code/hooks/claude/session-budget-guard.sh assets/code/tests/session_gate.bats
```

---

### Task 6: settings.json wiring + `--hook-smoke` live check

**Files:**
- Modify: `~/.claude/settings.json` (PreToolUse) — **may be user-only**: background agents cannot write under `~/.claude` (2026-06-06 carve-out root-cause)

- [ ] **Step 1: Attempt the wiring** — append to `hooks.PreToolUse` (note: hook paths in settings.json use the `~/.claude/skills/antcrate` symlink, matching gateway-guard/env-guard):

```json
{
  "matcher": "*",
  "hooks": [
    {
      "type": "command",
      "command": "/home/twntydotsix/.claude/skills/antcrate/assets/code/hooks/claude/session-budget-guard.sh"
    }
  ]
}
```

- [ ] **Step 2: If the write is denied (carve-out), file it as the first organic duty:**

```bash
antcrate --duty "wire session-budget-guard into ~/.claude/settings.json PreToolUse (matcher '*') — agents cannot write under ~/.claude; run: jq '.hooks.PreToolUse += [{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"/home/twntydotsix/.claude/skills/antcrate/assets/code/hooks/claude/session-budget-guard.sh\"}]}]' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json"
```

- [ ] **Step 3: Live smoke via `--hook-smoke`** (benign payloads per the field note; the fixture transcript makes the block path safe to assert live):

```bash
cd ~/projects/antcrate/assets/code
# under-soft allow (real session transcripts are fine to point at):
printf '{"type":"assistant","message":{"usage":{"input_tokens":50000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > /tmp/ac_gate_low.jsonl
antcrate --hook-smoke hooks/claude/session-budget-guard.sh --payload \
  '{"session_id":"smoke","transcript_path":"/tmp/ac_gate_low.jsonl","tool_name":"Bash","tool_input":{"command":"make build"}}'
# hard block:
printf '{"type":"assistant","message":{"usage":{"input_tokens":150000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > /tmp/ac_gate_high.jsonl
antcrate --hook-smoke hooks/claude/session-budget-guard.sh --payload \
  '{"session_id":"smoke","transcript_path":"/tmp/ac_gate_high.jsonl","tool_name":"Bash","tool_input":{"command":"make build"}}'
```
Expected: first exits 0 (allow verdict); second exits 2 with the SESSION HARD LIMIT checklist on stderr.

---

### Task 7: seeds + session-close integration

**Files:**
- Modify: `duties.md` (repo root — created by Task 3 smoke)
- Modify: `~/CLAUDE.md` session-close protocol part 3
- Append: `~/.antcrate/proposals.log` via `--propose`

- [ ] **Step 1: Seed the real duties**

```bash
antcrate --duty "decide gh public-repo policy (parked: gh-publish + mirror + 2 extensions) — policy call is yours"
antcrate --duty "decide key-rotation cadence for gh/remote credentials — owner-only"
```

- [ ] **Step 2: File the telemetry proposal**

```bash
antcrate --propose "session-telemetry" "Per-session accomplishment-per-token record: tokens, USD (via ac_cost), per-model split, bats delta, commits, ledger entries appended to ~/.antcrate/sessions.jsonl at wrap time + a diff view against the previous session. Surfaced 2026-06-10 designing the session-budget gate (user: automate the least-cost comparison instead of relying on discipline). Build with roadmap #6 --health."
```

- [ ] **Step 3: ~/CLAUDE.md** — in "3. End-of-session learning", add one bullet after the state.md line:

```
- Review `antcrate --duties` with the user — anything blocked on a human action gets a duty entry, not a state.md bullet.
```

- [ ] **Step 4: Commit** (duties.md only; ~/CLAUDE.md is outside the repo)

```bash
ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate \
  -m "chore(duties): seed initial human duties" -- duties.md
```

---

### Task 8: docs + ledger + state roll + push

**Files:**
- Modify: `SKILL.md` (lib list), `ledger.md` (append top), `state.md` (roll per protocol)

- [ ] **Step 1: SKILL.md** — add to the `lib/*.sh` list after `intel.sh`, and a hooks line:

```
  - `duties.sh` — human-action checklist; `--duty "<text>"` / `--duties` / `--duty-done <n>`; `duties: N open` in `--status`; duties.md at repo root (append/flip only)
```
and under Hooks: `hooks/claude/session-budget-guard.sh` — PreToolUse context-window gate (soft 100k warn / hard 140k wrap-up-whitelist block; `/clear` releases; spec `docs/specs/2026-06-10-session-budget-gate-and-duties-design.md`).

- [ ] **Step 2: Full CI** — `antcrate --ci` — Expected: PASS, **614 bats** (591+9+14), shellcheck clean.

- [ ] **Step 3: Ledger entry** (newest-first, follow house format): title `## 2026-06-10 — Session-budget gate + duties SHIPPED — bats 591 → 614`; body: what shipped (both units + wiring + seeds), the whitelist posture (quote-strip + segment split + `$(`-reject, deny-by-default), fail-open rationale, settings.json wiring outcome (done or duty-filed), audit-line crossing.

- [ ] **Step 4: state.md roll** — new top block (gate+duties shipped, audit next); move blocks older than the prior session to `state-archive.md` verbatim per rolling protocol.

- [ ] **Step 5: Commit + push**

```bash
ANTCRATE_COMMIT_PREAPPROVED=1 antcrate --commit antcrate \
  -m "docs(state): gate+duties ship — ledger, state roll, SKILL.md" \
  -- SKILL.md ledger.md state.md state-archive.md
antcrate --pp antcrate
```
Expected: push accepted; CI fires on GitHub.

---

### Task 9: codebase audit (598 line crossed) + snapshot

- [ ] **Step 1: Run the audit per ~/CLAUDE.md part 2** — dispatch the read-only `agents-rule-auditor` agent (AGENTS rule scan, Shipped-claim drift scan), then inline: orphan-state scan (`.git/antcrate-hook-bypass`, `/tmp/ac_*` fixtures incl. `/tmp/ac_gate_*.jsonl` from Task 6, backups >90d), and defensive-disable review (`git log -p --since=2026-06-09 -- '*.sh' | grep 'shellcheck disable'`).

- [ ] **Step 2: Fix anything CRITICAL inline; file `--propose` for the rest.**

- [ ] **Step 3: Snapshot the new baseline**

```bash
antcrate --ci --snapshot
antcrate --status | grep audit
```
Expected: `audit : 614/714 (baseline 614)` — next audit at 714.

- [ ] **Step 4: Final ledger line for the audit verdict + update the audit counter line at the bottom of ~/CLAUDE.md (or duty-file it if the write is denied). Commit + `--pp`.**
