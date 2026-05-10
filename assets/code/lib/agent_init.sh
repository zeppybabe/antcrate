#!/usr/bin/env bash
# antcrate :: lib/agent_init.sh — drop a project-scoped Cody pointer
#
# Companion to ~/.claude/agents/cody.md (the home Cody). Per AGENTS.md
# proposal #89, every AntCrate-registered project gets its own Cody
# variant under <project>/.claude/agents/<project>-cody.md plus an
# attempt counter at <project>/.antcrate/cody-attempts.json that
# --delegate (#93) increments on failed edits.
#
# Today's surface (small, idempotent):
#   ac_agent_init <project>     — create both files if missing; no-op otherwise
#
# Idempotency: existing files are kept as-is. We never overwrite. If the
# user wants a fresh template, they delete the file first.
#
# Public API:
#   ac_agent_init <project>
#
# Internal: (none)
#
# Sourced by wrapper. Depends on registry.sh, log.sh.

# ac_agent_init <project>
# Drop a project-scoped Cody pointer + initialize the attempt counter.
# Idempotent. The pointer file's name is "<project>-cody.md" so it does
# not shadow the home cody.md — both are addressable via Claude Code.
ac_agent_init() {
    local project="${1:-}"
    [[ -n "$project" ]] || { ac_error "agent_init: missing project name"; return 1; }

    if ! ac_registry_has "$project"; then
        ac_error "agent_init: unknown project '$project' (use --register or --start first)"
        return 1
    fi

    local proj_path
    proj_path=$(ac_registry_get "$project" path) || {
        ac_error "agent_init: failed to resolve path for '$project'"
        return 1
    }
    [[ -d "$proj_path" ]] || { ac_error "agent_init: project path missing on disk: $proj_path"; return 1; }

    local agents_dir="$proj_path/.claude/agents"
    local cody_file="$agents_dir/${project}-cody.md"
    local antcrate_dir="$proj_path/.antcrate"
    local attempts_file="$antcrate_dir/cody-attempts.json"

    mkdir -p "$agents_dir" "$antcrate_dir"

    if [[ -f "$cody_file" ]]; then
        ac_info "agent_init: ${project}-cody.md already exists — leaving as-is"
    else
        local domain
        domain=$(ac_registry_get "$project" parent 2>/dev/null || true)
        [[ -z "$domain" ]] && domain="_generic"
        cat > "$cody_file" <<EOF
---
name: ${project}-cody
description: Project-scoped Cody for the AntCrate-registered project '${project}' (domain: ${domain}). Code authoring, debugging, refactoring, and testing within ${proj_path}/. Inherits every rule from the home Cody at ~/.claude/agents/cody.md.
tools: Read, Edit, Write, Bash, Grep, Glob, TodoWrite, Skill
model: sonnet
---

You are **${project}-cody** — a project-scoped variant of Cody, the AntCrate code agent.

## Your project

- **Name:** ${project}
- **Domain:** ${domain}
- **Path:** ${proj_path}
- **Project rules:** ${proj_path}/CLAUDE.md (read first)
- **Attempt counter:** ${proj_path}/.antcrate/cody-attempts.json (increment on failures)

## Inherited rules

You inherit every rule from \`~/.claude/agents/cody.md\` — most importantly:

1. No destructive op without backup + explicit user approval. Surface to Clyde.
2. Never bypass AntCrate (no bare mv / rm / git push on registered paths).
3. Stay inside \`${proj_path}/\`.
4. **Three-attempt rule:** after 3 failed edits on the same line/symbol, increment the attempt counter and surface back to Clyde with a short failure report.

## Workflow shortcut

1. Read \`${proj_path}/CLAUDE.md\` and the relevant section of \`state.md\` / \`ledger.md\` first.
2. Make the edit. Run the project's test command per CLAUDE.md.
3. Self-review with the \`simplify\` skill before reporting back. Use \`security-review\` for credential / SQL / path-handling changes.
4. Tell Clyde what changed in one or two sentences plus what to verify.

For full conventions, defer to \`~/.claude/agents/cody.md\`.
EOF
        ac_info "agent_init: wrote $cody_file"
    fi

    if [[ -f "$attempts_file" ]]; then
        ac_info "agent_init: cody-attempts.json already exists — leaving as-is"
    else
        printf '%s\n' '{}' > "$attempts_file"
        ac_info "agent_init: initialized $attempts_file"
    fi

    return 0
}
