# AntCrate — Skill Composition

Other skills to co-load alongside this project skill.

- `project-forge` — when logging decisions, fixes, or state changes for AntCrate.
- `research-recon` — when surveying alternative approaches to filesystem watchers, Bash testing frameworks, or Git automation patterns.
- `research-swarm` — when accumulating findings on related dev-tool architectures.
- `docx` — when producing a formal AntCrate spec deliverable or README.
- `pdf` — when extracting from or producing PDF references (the original blueprint was a PDF).
- `pdf-reading` — when re-ingesting the architecture blueprint or related references.
- `frontend-design` — Phase 3+, if/when AntCrate gains a TUI or web dashboard.

Activation protocol: when this project skill is active and the user's request matches a when-rule above, Claude should `view` the referenced skill's `SKILL.md` at `/mnt/skills/user/<n>/SKILL.md` or `/mnt/skills/public/<n>/SKILL.md` before acting.

## Phase-2 diagram automation

When the user signals the AntCrate diagram-automation phase ("integrate diagrams", "wire up Mermaid/PlantUML/D2 into start templates", etc.), load `assets/docs/DIAGRAM_AUTOMATION_GUIDE.md` from this skill's assets — it is the source of truth for which tool to use per source-of-truth artifact type.
