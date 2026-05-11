#!/usr/bin/env bash
# antcrate :: lib/hooks.sh — git-hook inspection + template install for a project.
#
# Public API:
#   ac_hooks_list   <project>                            — list active hooks + which dir is in use
#   ac_hooks_log    <project> [N]                        — tail .git/antcrate-hook.log (default 50)
#   ac_hook_install <project> <template> [hook] [--force] — install a template hook (idempotent;
#                                                          backup-then-overwrite on --force)
#   ac_hook_remove  <project> <hook> [--force]            — remove a hook, backup-then-delete,
#                                                          audit to global JSONL + per-project log
#   ac_hook_debug   <project> [hook] [--with-stash] [--no-trace]
#                                                        — re-run a hook with annotated trace +
#                                                          stdout/stderr capture; appends to
#                                                          .git/antcrate-hook.log and audits
#   ac_hook_bypass  <project> --reason "<text>"           — write a single-shot bypass flag at
#                                                          .git/antcrate-hook-bypass; consumed by
#                                                          the next antcrate-shipped hook
#
# Internal:
#   ac_hooks_dir            — resolve effective hooks dir (honors core.hooksPath)
#   _ac_hook_template_path  — resolve absolute path to a template by name
#   _ac_hook_render         — token-substitute a template into a target file
#   _ac_hooks_audit_append  — write one event to both audit sinks (JSONL + plain)
#
# Templates live at assets/code/hooks/templates/. Each is a stand-alone
# shell script with a header line `# antcrate-template-version: <ver>`
# so installed hooks can be audited for staleness later. Tokens
# substituted at install time: __PROJECT_NAME__, __ANTCRATE_BIN__.
#
# Larger queued surface (see assets/docs/HOOK_PLAN.md):
#   --hook-remove / --hook-bypass / commit-msg-format template
#
# Sourced by wrapper. Depends on registry.sh, log.sh.

# ac_hooks_dir <project_path>
# Echo the absolute path of the directory git will read hooks from for this
# project (honors core.hooksPath; falls back to .git/hooks).
ac_hooks_dir() {
    local proj_path="$1"
    [[ -d "$proj_path" ]] || return 1
    [[ -d "$proj_path/.git" ]] || return 1   # not a git repo

    local hp
    hp=$(git -C "$proj_path" config --get core.hooksPath 2>/dev/null || true)
    if [[ -n "$hp" ]]; then
        if [[ "$hp" = /* ]]; then
            printf '%s\n' "$hp"
        else
            printf '%s/%s\n' "$proj_path" "$hp"
        fi
    else
        printf '%s/.git/hooks\n' "$proj_path"
    fi
}

# ac_hooks_list <project>
# Tab-separated lines: <hook-name>\t<status>\t<path>
# Status: "active" (executable, non-sample), "disabled" (file present, not
# executable), or absent entries are simply not listed.
# Header line printed first describes the effective hooks dir.
ac_hooks_list() {
    local project="$1"
    ac_registry_has "$project" || { ac_error "hooks-list: unknown project: $project"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "hooks-list: missing path: $p"; return 1; }

    local dir
    dir=$(ac_hooks_dir "$p") || { ac_error "hooks-list: $p is not a git repo"; return 1; }

    if [[ ! -d "$dir" ]]; then
        printf 'hooks-dir: %s (does not exist)\n' "$dir"
        return 0
    fi

    # Indicate whether antcrate's shipped opt-in dir (.githooks) is active.
    local hp_set
    hp_set=$(git -C "$p" config --get core.hooksPath 2>/dev/null || true)
    if [[ "$hp_set" == ".githooks" ]]; then
        printf 'hooks-dir: %s (antcrate opt-in: ENABLED via core.hooksPath=.githooks)\n' "$dir"
    elif [[ -n "$hp_set" ]]; then
        printf 'hooks-dir: %s (custom: core.hooksPath=%s)\n' "$dir" "$hp_set"
    else
        printf 'hooks-dir: %s (default)\n' "$dir"
    fi

    local f base status
    while IFS= read -r -d '' f; do
        base=$(basename "$f")
        # skip git's bundled samples (only meaningful in default .git/hooks)
        case "$base" in *.sample) continue ;; esac
        if [[ -x "$f" ]]; then status="active"; else status="disabled"; fi
        printf '%s\t%s\t%s\n' "$base" "$status" "$f"
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
}

# ac_hooks_log <project> [lines]
# Tail $project/.git/antcrate-hook.log (the file the shipped pre-commit hook
# tees output to). Useful when a commit got blocked and the terminal output
# is gone (or the commit was attempted from an automation context).
ac_hooks_log() {
    local project="$1" lines="${2:-50}"
    ac_registry_has "$project" || { ac_error "hook-log: unknown project: $project"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p" ]] || { ac_error "hook-log: missing path: $p"; return 1; }

    local logfile="$p/.git/antcrate-hook.log"
    if [[ ! -f "$logfile" ]]; then
        printf 'no hook log yet at %s\n' "$logfile"
        printf '(the shipped .githooks/pre-commit writes here on every run)\n'
        return 0
    fi

    printf '=== %s (last %s lines) ===\n' "$logfile" "$lines"
    tail -n "$lines" "$logfile"
}

# _ac_hook_template_path <name>
# Resolve absolute path to a hook template. Templates live next to this
# library at ../hooks/templates/<name>. Returns nonzero if not found.
_ac_hook_template_path() {
    local name="$1"
    [[ -n "$name" ]] || return 1
    local lib_dir; lib_dir=$(dirname "${BASH_SOURCE[0]}")
    local tmpl="$lib_dir/../hooks/templates/$name"
    [[ -f "$tmpl" ]] || return 1
    printf '%s\n' "$(cd "$(dirname "$tmpl")" && pwd)/$(basename "$tmpl")"
}

# _ac_hook_bypass_check_snippet > stdout
# The bypass-check block injected at install time into every antcrate-shipped
# hook template that carries the `# __ANTCRATE_BYPASS_CHECK__` marker. The
# block reads `.git/antcrate-hook-bypass` if present, captures the reason,
# logs consumption to BOTH `.git/antcrate-hook.log` and
# `.git/antcrate-hook-audit.log` (parity with the audit sinks the wrapper
# writes), deletes the flag (single-shot), and exits 0. `__PROJECT_NAME__`
# inside the snippet is substituted by the same sed pass that handles other
# template tokens. Keep this terse — every byte ships into every installed
# hook.
_ac_hook_bypass_check_snippet() {
    cat <<'SNIP'
# antcrate hook-bypass check (auto-inserted at install time)
__ac_flag="$(git rev-parse --git-dir 2>/dev/null)/antcrate-hook-bypass"
if [[ -f "$__ac_flag" ]]; then
    __ac_hook=$(basename "$0")
    __ac_reason=$(jq -r '.reason // "<no reason>"' "$__ac_flag" 2>/dev/null || tr '\n' ' ' < "$__ac_flag")
    __ac_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    __ac_dir=$(git rev-parse --git-dir 2>/dev/null)
    printf '%s [%s] BYPASSED via antcrate --hook-bypass; reason=%s\n' \
        "$__ac_ts" "$__ac_hook" "$__ac_reason" >> "$__ac_dir/antcrate-hook.log" 2>/dev/null || true
    printf '%s hook-bypass-consumed project=__PROJECT_NAME__ hook=%s reason=%s\n' \
        "$__ac_ts" "$__ac_hook" "$__ac_reason" >> "$__ac_dir/antcrate-hook-audit.log" 2>/dev/null || true
    rm -f "$__ac_flag"
    exit 0
fi
SNIP
}

# _ac_hook_render <template-path> <project-name> > stdout
# Token-substitute a template. Two-stage:
#   1. awk replaces the `# __ANTCRATE_BYPASS_CHECK__` marker line with the
#      multi-line bypass-check block (templates without the marker pass
#      through unchanged — appropriate for hooks where bypass doesn't
#      apply, e.g. a future commit-msg-format).
#   2. sed substitutes single-line tokens (__PROJECT_NAME__, __ANTCRATE_BIN__),
#      including the __PROJECT_NAME__ baked into the snippet's consume log.
#
# The snippet is passed via ENVIRON, not `awk -v`, because `-v` interprets
# escape sequences in the value (gawk: "Escape sequences in val are
# interpreted") — that would mangle `\n` inside the snippet's printf format
# strings into real newlines, breaking the rendered hook. ENVIRON passes
# the value byte-for-byte.
_ac_hook_render() {
    local tmpl="$1" project="$2"
    local antcrate_bin
    antcrate_bin=$(command -v antcrate 2>/dev/null || echo "antcrate")

    AC_HOOK_BYPASS_SNIPPET=$(_ac_hook_bypass_check_snippet) \
    awk '
        /^# __ANTCRATE_BYPASS_CHECK__$/ { print ENVIRON["AC_HOOK_BYPASS_SNIPPET"]; next }
        { print }
    ' "$tmpl" \
    | sed -e "s|__PROJECT_NAME__|$project|g" \
          -e "s|__ANTCRATE_BIN__|$antcrate_bin|g"
}

# ac_hook_install <project> <template> [hook-name] [--force]
# Install a template into the project's effective hooks dir. The hook
# filename defaults to the part of the template name before the first
# dash (e.g. pre-commit-secrets → pre-commit). Pass an explicit
# hook-name to override.
#
# Conflict behavior:
#   - hook absent              → write template, chmod +x
#   - hook present, identical  → no-op (idempotent)
#   - hook present, different  → refuse (default) OR backup-then-overwrite (--force)
# The backup goes to <hooks_dir>/<hook>.bak.<UTC-timestamp>.
ac_hook_install() {
    local project="" template="" hook_name="" force=0
    while (( $# > 0 )); do
        case "$1" in
            --force) force=1; shift ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                elif [[ -z "$template" ]]; then template="$1"
                elif [[ -z "$hook_name" ]]; then hook_name="$1"
                else ac_error "hook-install: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project"  ]] || { ac_error "hook-install: missing project name"; return 1; }
    [[ -n "$template" ]] || { ac_error "hook-install: missing template name"; return 1; }

    ac_registry_has "$project" || { ac_error "hook-install: unknown project '$project'"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p"      ]] || { ac_error "hook-install: missing path: $p"; return 1; }
    [[ -d "$p/.git" ]] || { ac_error "hook-install: not a git repo: $p (use --git-init first)"; return 1; }

    local tmpl
    tmpl=$(_ac_hook_template_path "$template") || {
        ac_error "hook-install: unknown template '$template'"
        local tdir; tdir=$(dirname "${BASH_SOURCE[0]}")/../hooks/templates
        if [[ -d "$tdir" ]]; then
            ac_error "available: $(find "$tdir" -mindepth 1 -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
        fi
        return 1
    }

    # Default hook name = template prefix before the first dash-after-prefix.
    # pre-commit-secrets → pre-commit; pre-push-tests → pre-push;
    # commit-msg-format → commit-msg. Falls back to template name if no match.
    if [[ -z "$hook_name" ]]; then
        case "$template" in
            pre-commit-*) hook_name="pre-commit" ;;
            pre-push-*)   hook_name="pre-push" ;;
            commit-msg-*) hook_name="commit-msg" ;;
            post-commit-*) hook_name="post-commit" ;;
            *)            hook_name="$template" ;;
        esac
    fi

    local dir
    dir=$(ac_hooks_dir "$p") || return 1
    mkdir -p "$dir"
    local target="$dir/$hook_name"

    local rendered; rendered=$(_ac_hook_render "$tmpl" "$project")

    if [[ -f "$target" ]]; then
        local existing; existing=$(cat "$target")
        if [[ "$existing" == "$rendered" ]]; then
            ac_info "hook-install: $hook_name already matches '$template' — no-op"
            return 0
        fi
        if (( force == 0 )); then
            ac_error "hook-install: $hook_name exists and differs from template '$template'"
            ac_error "    pass --force to backup-then-overwrite (creates $target.bak.<ts>)"
            return 1
        fi
        local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
        cp -p "$target" "$target.bak.$ts"
        ac_info "hook-install: backed up existing $hook_name to $target.bak.$ts"
    fi

    printf '%s' "$rendered" > "$target"
    chmod +x "$target"
    ac_info "hook-install: installed '$template' as $hook_name in $dir"
    return 0
}

# _ac_hooks_audit_append <project> <project_path> <action> <hook> <hooks_dir> <sha256> <backup>
# Append one event to both audit sinks:
#   - global JSONL at $ANTCRATE_HOME/hooks.log (one well-formed object per line)
#   - per-project plain text at $project_path/.git/antcrate-hook-audit.log
# Best-effort: log failures are non-fatal so a write-perm issue on one sink
# doesn't block the destructive op itself.
_ac_hooks_audit_append() {
    local project="$1" proj_path="$2" action="$3" hook="$4" dir="$5" sha="$6" bak="$7"
    local ts ts_ms
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ts_ms=$(date -u +%s%3N 2>/dev/null || printf '%s000' "$(date -u +%s)")
    local home="${ANTCRATE_HOME:-$HOME/.antcrate}"
    mkdir -p "$home" 2>/dev/null || true
    local global="$home/hooks.log"
    local local_log="$proj_path/.git/antcrate-hook-audit.log"

    # JSONL — build with jq when available (safe quoting); fall back to printf
    # if jq is somehow missing (registry.sh already requires jq so this is belt-
    # and-suspenders).
    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg ts "$ts" --argjson ts_ms "$ts_ms" \
            --arg action "$action" --arg project "$project" \
            --arg hook "$hook" --arg dir "$dir" \
            --arg sha256 "$sha" --arg backup "$bak" \
            '{ts:$ts, ts_ms:$ts_ms, action:$action, project:$project, hook:$hook, hooks_dir:$dir, sha256:$sha256, backup:$backup}' \
            >> "$global" 2>/dev/null || true
    else
        printf '{"ts":"%s","ts_ms":%s,"action":"%s","project":"%s","hook":"%s","hooks_dir":"%s","sha256":"%s","backup":"%s"}\n' \
            "$ts" "$ts_ms" "$action" "$project" "$hook" "$dir" "$sha" "$bak" \
            >> "$global" 2>/dev/null || true
    fi

    printf '%s %s project=%s hook=%s sha256=%s backup=%s\n' \
        "$ts" "$action" "$project" "$hook" "$sha" "$bak" \
        >> "$local_log" 2>/dev/null || true
}

# ac_hook_remove <project> <hook-name> [--force]
# Remove a hook from the project's effective hooks dir.
#   - hook absent           → no-op, returns 0 with friendly notice
#   - hook present          → sha256 the file, copy to <hook>.bak.<UTC-ts>,
#                             delete the live file, append audit to both sinks
# Returns nonzero on validation errors (unknown project, missing path, non-git).
# --force is reserved for future use (e.g. skip backup); today it's accepted
# as a no-op so callers can pass it consistently with --hook-install.
ac_hook_remove() {
    local project="" hook_name="" force=0
    while (( $# > 0 )); do
        case "$1" in
            --force) force=1; shift ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                elif [[ -z "$hook_name" ]]; then hook_name="$1"
                else ac_error "hook-remove: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project"   ]] || { ac_error "hook-remove: missing project name"; return 1; }
    [[ -n "$hook_name" ]] || { ac_error "hook-remove: missing hook name"; return 1; }

    ac_registry_has "$project" || { ac_error "hook-remove: unknown project '$project'"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p"      ]] || { ac_error "hook-remove: missing path: $p"; return 1; }
    [[ -d "$p/.git" ]] || { ac_error "hook-remove: not a git repo: $p"; return 1; }

    local dir
    dir=$(ac_hooks_dir "$p") || return 1
    local target="$dir/$hook_name"

    if [[ ! -f "$target" ]]; then
        ac_info "hook-remove: $hook_name not present in $dir — nothing to do"
        return 0
    fi

    local sha bak ts
    sha=$(sha256sum "$target" | cut -d' ' -f1)
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    bak="$target.bak.$ts"
    cp -p "$target" "$bak"
    rm -f "$target"

    _ac_hooks_audit_append "$project" "$p" "hook-remove" "$hook_name" "$dir" "$sha" "$bak"

    ac_info "hook-remove: removed $hook_name from $dir (backup: $bak)"
    # silence the unused-var warning when --force lands but doesn't branch yet
    : "$force"
    return 0
}

# ac_hook_debug <project> [hook-name] [--with-stash] [--no-trace]
# Re-run a hook with annotated trace + captured stdout/stderr so the human or
# agent can see exactly which check fired and what each one emitted. Default
# hook name is "pre-commit" (the only template antcrate auto-installs today).
#
# Trace strategy: BASH_XTRACEFD pinned to a dedicated fd so `bash -x` output
# is captured in its own stream, leaving the hook's real stdout / stderr clean.
# PS4 is set to `+ <file>:<line>: ` so each trace line carries source coords.
#
# --with-stash:
#   git stash push --keep-index --include-untracked before running, then pop
#   after. The hook then runs against exactly the staged set the commit would
#   use. Stash detection is via stash-list-count delta (push returns 0 even
#   when nothing is stashed).
#
# --no-trace:
#   Skip xtrace entirely; just run the hook plain. Useful when the hook
#   itself is verbose enough or xtrace adds noise.
#
# Audit: appends one entry to both hook audit sinks with action="hook-debug",
# sha256 of the live hook file, and `backup` field carrying the stash refspec
# (if --with-stash created one) or empty. Also appends a labeled block to
# `<project>/.git/antcrate-hook.log` so `--hook-log` tails surface the debug
# run alongside real commit-time runs.
#
# Exits with the hook's exit code (0 on pass, nonzero on fail) so callers /
# scripts can branch on the underlying check.
ac_hook_debug() {
    local project="" hook_name="" with_stash=0 no_trace=0
    while (( $# > 0 )); do
        case "$1" in
            --with-stash) with_stash=1; shift ;;
            --no-trace)   no_trace=1;   shift ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                elif [[ -z "$hook_name" ]]; then hook_name="$1"
                else ac_error "hook-debug: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project" ]] || { ac_error "hook-debug: missing project name"; return 1; }
    [[ -z "$hook_name" ]] && hook_name="pre-commit"

    ac_registry_has "$project" || { ac_error "hook-debug: unknown project '$project'"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p"      ]] || { ac_error "hook-debug: missing path: $p"; return 1; }
    [[ -d "$p/.git" ]] || { ac_error "hook-debug: not a git repo: $p"; return 1; }

    local dir
    dir=$(ac_hooks_dir "$p") || return 1
    local target="$dir/$hook_name"

    if [[ ! -f "$target" ]]; then
        ac_error "hook-debug: $hook_name not present in $dir — nothing to debug"
        return 1
    fi

    local sha ts ts_human
    sha=$(sha256sum "$target" | cut -d' ' -f1)
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    ts_human=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local tmpdir
    tmpdir=$(mktemp -d -t antcrate-hookdbg.XXXXXX) || {
        ac_error "hook-debug: mktemp failed"; return 1
    }
    local out_file="$tmpdir/stdout" err_file="$tmpdir/stderr" trace_file="$tmpdir/trace"
    : > "$out_file"; : > "$err_file"; : > "$trace_file"

    # Stash unstaged work-tree changes if requested. Detect success via stash-
    # list delta — `git stash push` exits 0 even when nothing was saved.
    local stashed=0 stash_label="antcrate-hook-debug-$ts"
    if (( with_stash == 1 )); then
        local pre_count post_count
        pre_count=$(git -C "$p" stash list 2>/dev/null | wc -l)
        git -C "$p" stash push --keep-index --include-untracked -m "$stash_label" \
            >/dev/null 2>&1 || true
        post_count=$(git -C "$p" stash list 2>/dev/null | wc -l)
        if (( post_count > pre_count )); then stashed=1; fi
    fi

    # Header — printed in a subshell so a closed downstream pipe (e.g. user
    # piped output to `head`) cannot SIGPIPE us before we reach stash pop.
    # The `|| true` swallows the subshell's nonzero exit on SIGPIPE under
    # `set -e` / `pipefail` inherited from the wrapper.
    (
        printf '=== antcrate hook-debug ===\n'
        printf 'project   : %s\n' "$project"
        printf 'hook      : %s\n' "$hook_name"
        printf 'path      : %s\n' "$target"
        printf 'sha256    : %s\n' "$sha"
        printf 'ts        : %s\n' "$ts_human"
        if (( with_stash == 1 )); then
            if (( stashed == 1 )); then
                printf 'stash     : pushed (%s)\n' "$stash_label"
            else
                printf 'stash     : requested, no local changes to save\n'
            fi
        fi
        if (( no_trace == 1 )); then
            printf 'mode      : plain (no xtrace)\n'
        else
            printf 'mode      : xtrace (BASH_XTRACEFD)\n'
        fi
        if [[ ! -x "$target" ]]; then
            # shellcheck disable=SC2016
            printf '[note] hook is not executable; running via `bash <path>` anyway\n'
        fi
        printf '\n'
    ) || true

    # Execute the hook. Subshell isolates cwd + fds; xtrace is pinned to fd 9
    # so the hook's real stderr doesn't get mixed with trace output.
    local hook_exit=0
    if (( no_trace == 1 )); then
        ( cd "$p" && bash "$target" ) > "$out_file" 2> "$err_file"
        hook_exit=$?
    else
        (
            cd "$p" || exit 127
            exec 9>"$trace_file"
            export BASH_XTRACEFD=9
            export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
            bash -x "$target"
        ) > "$out_file" 2> "$err_file"
        hook_exit=$?
    fi

    # ---- Critical cleanup section: NOTHING in here may write to stdout. ----
    # All operations below are file-only (no pipe-sensitive I/O) so a closed
    # downstream pipe in later printing cannot strand the stash or skip the
    # audit log entry.

    # Pop the stash first so worktree state is restored before any output.
    local pop_failed=0
    if (( stashed == 1 )); then
        if ! git -C "$p" stash pop >/dev/null 2>&1; then
            pop_failed=1
        fi
    fi

    # Append a labeled block to the project's hook log so --hook-log surfaces
    # the debug run later. Best-effort: a .git/ that's somehow read-only must
    # not block the primary action.
    {
        printf '\n--- antcrate hook-debug %s ---\n' "$ts_human"
        printf 'hook=%s sha256=%s exit=%s\n' "$hook_name" "$sha" "$hook_exit"
        if [[ -s "$trace_file" ]]; then
            printf '[trace]\n'
            sed 's/^/  /' "$trace_file"
        fi
        if [[ -s "$out_file" ]]; then
            printf '[stdout]\n'
            sed 's/^/  /' "$out_file"
        fi
        if [[ -s "$err_file" ]]; then
            printf '[stderr]\n'
            sed 's/^/  /' "$err_file"
        fi
    } >> "$p/.git/antcrate-hook.log" 2>/dev/null || true

    # Audit. `backup` carries the stash refspec when --with-stash created one;
    # this gives a future --hook-audit consumer a single field to recover the
    # exact pre-debug worktree state from.
    local audit_bak=""
    (( stashed == 1 )) && audit_bak="stash:$stash_label"
    _ac_hooks_audit_append "$project" "$p" "hook-debug" "$hook_name" "$dir" "$sha" "$audit_bak"

    # ---- End critical cleanup. Below this point all output is in subshells. ----

    # Annotated output, each stream prefixed so a fast skim shows what came
    # from where. Empty streams are skipped to keep noise low on clean runs.
    (
        if [[ -s "$trace_file" ]]; then
            printf '=== TRACE ===\n'
            sed 's/^/[trace] /' "$trace_file"
            printf '\n'
        fi
        if [[ -s "$out_file" ]]; then
            printf '=== STDOUT ===\n'
            sed 's/^/[out] /' "$out_file"
            printf '\n'
        fi
        if [[ -s "$err_file" ]]; then
            printf '=== STDERR ===\n'
            sed 's/^/[err] /' "$err_file"
            printf '\n'
        fi
        printf '=== exit %s ===\n' "$hook_exit"
        if (( pop_failed == 1 )); then
            printf '[warn] stash pop failed (likely conflict between staged + unstaged edits to the same file).\n'
            # shellcheck disable=SC2016
            printf '[warn] stash preserved as: %s. resolve via `git -C %s stash list` / `git stash pop`.\n' \
                "$stash_label" "$p"
        fi
    ) || true

    rm -rf "$tmpdir"

    # ac_info logs to stderr but we still wrap it: a downstream `2>&1 | head`
    # could close stderr too.
    if (( hook_exit != 0 )); then
        ac_info "hook-debug: $hook_name exited $hook_exit (see annotated output above)" 2>/dev/null || true
    else
        ac_info "hook-debug: $hook_name passed (exit 0)" 2>/dev/null || true
    fi
    return "$hook_exit"
}

# ac_hook_bypass <project> --reason "<text>"
# Write a single-shot bypass flag at $project/.git/antcrate-hook-bypass. The
# next antcrate-shipped hook to fire reads the flag's `reason`, logs the
# bypass to BOTH `.git/antcrate-hook.log` and `.git/antcrate-hook-audit.log`,
# deletes the flag (single-shot guarantee), and exits 0 without running its
# own check.
#
# Required:
#   --reason "<text>" — every bypass MUST carry a human-readable reason; the
#                      audit trail is the entire point of this surface.
#
# Refusals:
#   - missing project / not a git repo: stock validation refusal.
#   - flag already present: refuse with a notice naming the path so the user
#     either consumes it (run a commit) or rm's it deliberately. We never
#     silently overwrite — that would silently extend a stale bypass.
#
# Audit:
#   - Wrapper-side row at write-time via _ac_hooks_audit_append: action
#     "hook-bypass", `backup` field carries `reason:<text>` (same overload
#     pattern as hook-debug's stash refspec).
#   - Hook-side row at consume-time: written by the auto-injected snippet in
#     the hook itself; mirrors the wrapper's row at the per-project plain-
#     text sink and the .git/antcrate-hook.log tail target.
#
# AGENTS.md rule #14 (the bypass rule) restricts agents from CALLING this
# function directly or writing the flag file by hand — only humans run the
# bypass command. The function itself doesn't enforce that (no way to
# distinguish caller intent from inside Bash); the discipline lives at the
# AGENTS.md / Gateway Law layer.
ac_hook_bypass() {
    local project="" reason=""
    while (( $# > 0 )); do
        case "$1" in
            --reason)
                reason="${2:-}"
                if [[ $# -ge 2 ]]; then shift 2; else shift; fi
                ;;
            *)
                if [[ -z "$project" ]]; then project="$1"
                else ac_error "hook-bypass: too many positional args"; return 1
                fi
                shift ;;
        esac
    done

    [[ -n "$project" ]] || { ac_error "hook-bypass: missing project name"; return 1; }
    [[ -n "$reason"  ]] || { ac_error "hook-bypass: --reason \"<text>\" is required (every bypass must be logged)"; return 1; }

    ac_registry_has "$project" || { ac_error "hook-bypass: unknown project '$project'"; return 1; }
    local p; p=$(ac_registry_get "$project" path)
    [[ -d "$p"      ]] || { ac_error "hook-bypass: missing path: $p"; return 1; }
    [[ -d "$p/.git" ]] || { ac_error "hook-bypass: not a git repo: $p"; return 1; }

    local flag="$p/.git/antcrate-hook-bypass"
    if [[ -f "$flag" ]]; then
        ac_error "hook-bypass: flag already present at $flag"
        ac_error "    a prior bypass is queued. consume it by running the hook (e.g. a commit), or"
        ac_error "    'rm $flag' deliberately to discard."
        return 1
    fi

    local ts_human
    ts_human=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Write structured JSON so the hook-side snippet's `jq -r '.reason'` works
    # reliably across editors and reason texts.
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg ts "$ts_human" --arg reason "$reason" --arg project "$project" \
            '{ts:$ts, reason:$reason, project:$project}' > "$flag"
    else
        # Crude escape: replace " with \" in reason. Last-resort fallback;
        # registry.sh already requires jq so this branch is belt-and-suspenders.
        local esc; esc="${reason//\"/\\\"}"
        printf '{"ts":"%s","reason":"%s","project":"%s"}\n' "$ts_human" "$esc" "$project" > "$flag"
    fi

    # Wrapper-side audit. `hook` is empty because the bypass isn't tied to a
    # specific hook name at write time — whichever hook fires next consumes
    # it. `backup` overloads to carry the reason payload.
    _ac_hooks_audit_append "$project" "$p" "hook-bypass" "" "" "" "reason:$reason"

    ac_info "hook-bypass: flag written to $flag"
    ac_info "hook-bypass: single-shot — will be consumed by the next antcrate-shipped hook"
    ac_info "hook-bypass: reason=$reason"
    return 0
}
