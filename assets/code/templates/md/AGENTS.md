# AGENTS.md — __NAME__

Agent rules for this project. Inherits from the home AntCrate AGENTS.md at `~/.claude/skills/antcrate/assets/code/AGENTS.md`. The home rules bind by default; the per-project section below is for overrides.

## Project-specific overrides

(Add rules that apply only to this project. Common cases: stricter test discipline, project-specific denylist for destructive paths, hooks the AI must always propose rather than run directly. If empty, home rules govern.)

## Inherited rules (summary)

1. **No destructive op without backup + explicit user approval.**
2. **Never bypass AntCrate's structure** — no bare `mv` / `rm` / `git push` on registered project paths.
3. **Read before write** (the harness enforces this).
4. **Stay in zone** — `~/projects/__NAME__/**` is in zone; everything else asks.
5. **Three-attempt rule** for delegated agents — see `~/.claude/agents/cody.md`.
6. **Gateway Law (#12)** — updates/removals last in any roadmap.

For the full list see the home AGENTS.md. The home file is the source of truth; do not duplicate its contents here.
