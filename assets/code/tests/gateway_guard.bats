#!/usr/bin/env bats
# tests for hooks/claude/gateway-guard.sh — tiered whole-system perimeter
# (PreToolUse / Bash). See docs/specs/2026-05-31-harness-enforcement-layer.md.

setup() {
    HOOKS="$BATS_TEST_DIRNAME/../hooks/claude"
    GUARD="$HOOKS/gateway-guard.sh"
    export ANTCRATE_HOME="$BATS_TEST_TMPDIR/.antcrate"
    export ANTCRATE_REGISTRY="$ANTCRATE_HOME/registry.json"
    export ANTCRATE_ROOT="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$ANTCRATE_HOME" "$ANTCRATE_ROOT"
    ROOT="$ANTCRATE_ROOT/myproj"
    mkdir -p "$ROOT/src"
    jq -n --arg p "$ROOT" \
        '{projects:{myproj:{path:$p,parent:"webapps",linked_nodes:[],git_remote:""}}}' \
        > "$ANTCRATE_REGISTRY"
}

# Pipe a command through the guard exactly as Claude Code would.
guard() {
    jq -n --arg c "$1" '{tool_input:{command:$c}}' | "$GUARD"
}

# ---- sanctioned zone (registered project trees) ----

@test "sanctioned: recursive delete under a registered root is blocked" {
    run guard "rm -rf $ROOT/x"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--remove"* || "$output" == *"sanctioned"* ]]
}

@test "sanctioned: moving a whole registered root is blocked" {
    run guard "mv $ROOT $ANTCRATE_ROOT/other"
    [ "$status" -eq 2 ]
}

@test "sanctioned: single-file rm inside a registered tree is allowed silently" {
    run guard "rm $ROOT/src/one.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- critical zone (system + identity + control plane) ----

@test "critical: rm -rf into a system path is blocked" {
    run guard "rm -rf /etc/foo"
    [ "$status" -eq 2 ]
}

@test "critical: moving an ssh key out is blocked" {
    run guard "mv ~/.ssh/id_rsa /tmp"
    [ "$status" -eq 2 ]
}

@test "critical: rm of a shell identity file is blocked" {
    run guard "rm ~/.bashrc"
    [ "$status" -eq 2 ]
}

@test "critical: redirect into the registry is blocked" {
    run guard "jq '.' > $ANTCRATE_REGISTRY"
    [ "$status" -eq 2 ]
}

# ---- dangerous-command class (any path) ----

@test "dangerous: dd to a raw disk is blocked" {
    run guard "dd if=/dev/zero of=/dev/sda"
    [ "$status" -eq 2 ]
}

@test "dangerous: mkfs is blocked" {
    run guard "mkfs.ext4 /dev/sdb1"
    [ "$status" -eq 2 ]
}

@test "dangerous: systemctl enable is blocked" {
    run guard "systemctl enable myd.service"
    [ "$status" -eq 2 ]
}

@test "dangerous: recursive chmod on a system path is blocked" {
    run guard "chmod -R 777 /usr"
    [ "$status" -eq 2 ]
}

@test "dangerous: fork-bomb signature is blocked" {
    run guard ":(){ :|:& };:"
    [ "$status" -eq 2 ]
}

# ---- neutral zone (rest of ~ and /tmp) ----

@test "neutral: rm under /tmp warns but proceeds" {
    run guard "rm /tmp/x"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "neutral: rm of an unregistered home file warns but proceeds" {
    run guard "rm ~/scratch.txt"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ---- push ----

@test "push: bare git push warns and names --pp" {
    run guard "git push origin main"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--pp"* ]]
}

# ---- safe /dev pseudo-devices (must not wedge the ubiquitous idiom) ----

@test "allow: stderr redirect to /dev/null is silent" {
    run guard "ls /nonexistent 2>/dev/null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "allow: stdout+stderr redirect to /dev/null is silent" {
    run guard "jq . foo > /dev/null 2>&1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dangerous: redirect to a raw block device is still blocked" {
    run guard "echo x > /dev/sda"
    [ "$status" -eq 2 ]
}

# ---- shell-quoting awareness (operators inside strings are not real ops) ----

@test "allow: destructive-looking text inside a quoted argument is not an op" {
    run guard 'antcrate --propose "hook-smoke" "caught its own 2>/dev/null and a {command|file_path} note"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "allow: a commit message mentioning rm -rf is not a delete" {
    run guard 'git commit -m "remove the rm -rf /etc footgun from docs"'
    [ "$status" -ne 2 ]
}

@test "critical: rm of a quoted system path is still blocked" {
    run guard 'rm -rf "/etc/foo"'
    [ "$status" -eq 2 ]
}

# ---- non-destructive ----

@test "allow: a read command is silent" {
    run guard "cat $ROOT/src/one.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- fail-open boundary ----

@test "fail-open: unreadable registry still blocks a critical-zone delete" {
    export ANTCRATE_REGISTRY="$BATS_TEST_TMPDIR/.antcrate/missing.json"
    run guard "rm -rf /etc/x"
    [ "$status" -eq 2 ]
}

@test "fail-open: unreadable registry still blocks a dangerous command" {
    export ANTCRATE_REGISTRY="$BATS_TEST_TMPDIR/.antcrate/missing.json"
    run guard "dd if=/dev/zero of=/dev/nvme0n1"
    [ "$status" -eq 2 ]
}

@test "fail-open: unreadable registry lets a project-scoped op pass (no wedge)" {
    export ANTCRATE_REGISTRY="$BATS_TEST_TMPDIR/.antcrate/missing.json"
    run guard "rm -rf $ROOT/x"
    [ "$status" -eq 0 ]
}

# ---- most-protective-wins across segments ----

@test "compound: a safe segment plus a critical delete is blocked" {
    run guard "rm /tmp/ok && rm -rf /etc/pwn"
    [ "$status" -eq 2 ]
}

# ---- heredoc bodies are data, not commands (2026-06-09 false positive) ----

@test "heredoc: destructive text in a cat heredoc body is allowed" {
    run guard 'cat > /tmp/fixture.bats <<EOF
@test "x" {
  rm -rf "\$SOMEVAR/y"
  rm -rf /etc/pwn
}
EOF'
    [ "$status" -eq 0 ]
}

@test "heredoc: quoted-marker heredoc body with critical paths is allowed" {
    run guard "cat <<'DOC'
rm -rf /etc
dd if=/dev/zero of=/dev/sda
DOC"
    [ "$status" -eq 0 ]
}

@test "heredoc: body piped into a shell interpreter is still scanned" {
    run guard 'bash <<EOF
rm -rf /etc/pwn
EOF'
    [ "$status" -eq 2 ]
}

@test "heredoc: commands after the closing marker are still scanned" {
    run guard 'cat <<EOF
harmless body text
EOF
rm -rf /etc/pwn'
    [ "$status" -eq 2 ]
}

@test "heredoc: herestring is not mistaken for a heredoc opener" {
    run guard 'grep -q x <<< "harmless" && rm -rf /etc/pwn'
    [ "$status" -eq 2 ]
}
