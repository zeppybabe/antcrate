#!/usr/bin/env bash
# antcrate :: lib/lifecycle.sh — fire the AntCrate treatment chain on a project.
#
# Called by the dispatcher after --register, --start, and --rename succeed
# so every project automatically gets the same baseline:
#   1. Project-scoped Cody pointer + attempt counter (ac_agent_init).
#   2. Internal-md skeletons (ac_md_scaffold).
#   3. Hook autoinstall + .gitignore env-guard (ac_hook_autoinstall),
#      gated on the project being a git repo.
#
# Each step is idempotent. Failures of individual steps are warned but
# do not break the originating lifecycle event — the project is already
# registered / started / renamed by the time this fires.
#
# Public API:
#   ac_lifecycle_treatment <project>
#
# Internal: (none)
#
# Sourced by wrapper. Depends on agent_init.sh, md_scaffold.sh,
# hook_autoinstall.sh, registry.sh, log.sh.

# ac_lifecycle_treatment <project>
# Idempotent. Does not return nonzero on individual step failures.
ac_lifecycle_treatment() {
    local project="${1:-}"
    [[ -n "$project" ]] || return 0
    ac_registry_has "$project" || return 0

    local p
    p=$(ac_registry_get "$project" path 2>/dev/null) || return 0
    [[ -d "$p" ]] || return 0

    ac_agent_init  "$project" 2>/dev/null || ac_warn "lifecycle: agent_init failed for $project"
    ac_md_scaffold "$project" 2>/dev/null || ac_warn "lifecycle: md_scaffold failed for $project"

    # Hook autoinstall only makes sense when the project is a git repo.
    if [[ -d "$p/.git" ]]; then
        ac_hook_autoinstall "$project" >/dev/null 2>&1 \
            || ac_warn "lifecycle: hook_autoinstall failed for $project"
    fi

    return 0
}
