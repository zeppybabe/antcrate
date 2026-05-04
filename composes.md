# AntCrate — Skill Composition

How AntCrate cooperates with the rest of this Claude Code workspace. The
old version of this file pointed at skills (`project-forge`,
`research-recon`, `research-swarm`, `docx`, `pdf`, `pdf-reading`,
`frontend-design`) that don't exist in this user's setup. This is the
honest version.

## What AntCrate composes with today

### Auto-loaded across every session

- **`~/.claude/projects/-home-twntydotsix/memory/MEMORY.md`** + the
  feedback files it indexes. These are loaded into context every
  conversation:
  - `feedback_antcrate_as_sole_surface.md` — route project ops through
    AntCrate flags; propose new patterns instead of bare commands.
  - `feedback_gateway_law.md` — updates/removals are LAST in any
    roadmap; removals require executive joint decision.
  - `feedback_gh_pipeline.md` — every `gh` CLI use logged into
    `assets/docs/GH_PIPELINE_PLAN.md` as a candidate flag.
  Memory is the cross-session persistence layer. Updates/decisions that
  should survive a fresh chat go here, not in a "skill."

- **`~/CLAUDE.md`** — home-directory orchestration layer. Defines the
  Claude-Code-as-coding-agent contract: AntCrate owns layout/registry/
  push-triage/backups; Claude Code owns source authoring. Read on every
  session by the harness.

### Available harness skills (Claude-side, on demand)

These ship with Claude Code itself and don't need to be added to a
composes file — the harness loads them when their trigger conditions
match. AntCrate cooperates with them rather than depending on them:

- **`update-config`** — for changes to `~/.claude/settings.json` (hooks,
  permissions, env vars). Used when AntCrate's behavior needs the
  *harness* to do something automatically (e.g., a Claude Code hook
  that runs `antcrate --ci` after every file edit).
- **`schedule`** — for recurring or one-time remote agents. Useful for
  AntCrate maintenance tasks the user wants the harness to fire on a
  cadence (e.g., "every Monday, run `antcrate --status` and surface
  any drift").
- **`loop`** — for in-session polling (e.g., watching CI runs across
  several pushes).
- **`fewer-permission-prompts`** — to allowlist common AntCrate Bash
  invocations so they stop prompting.
- **`claude-api`** — when the research-side AntCrate (on the other
  machine) is implemented as an Anthropic SDK app and we need to
  configure prompt caching, model selection, etc.
- **`security-review`** — when changes to AntCrate touch the safety
  guard, Gateway Law enforcement, or the secret-pattern guard in
  `lib/commit.sh`.
- **`review`** — for second-opinion review when we eventually open PRs
  on the public mirror.
- **`init`** / **`keybindings-help`** / **`simplify`** — tangential to
  AntCrate but available.

## Future composition: per-project skills

Once `BUNDLE_SPEC.md` consumer-side (`antcrate --ingest`) ships, every
ingested project will drop a per-project skill into
`~/.claude/skills/<project>/`. The runtime composition then becomes:

1. **`antcrate` skill** (this one) — orchestration commands.
2. **`<project>` skill** (created by ingest) — per-project knowledge:
   stack-specific conventions, key files, common operations, gotchas
   captured during research.
3. **`<project>/CLAUDE.md`** — project-local convention overrides.

That triple is the Phase-3 design target. Until `--ingest` ships,
per-project knowledge lives in the project's own `CLAUDE.md` plus
whatever ad-hoc context Claude Code reads from the tree.

## What's NOT a composition concern

- **`gh` CLI**, **`jq`**, **`bats`**, **`shellcheck`** — these are
  runtime *tools*, not skills. Documented in `stack.md`.
- **`gh` workflow integration** — handled by `assets/docs/
  GH_PIPELINE_PLAN.md` as flags absorbed into the AntCrate wrapper, not
  by composing with another skill.

## Diagram automation is an AntCrate feature, not a composition

Diagrams are first-class AntCrate output, not an external skill or
optional dependency:

- **Every registered project gets diagrams.** Today: `architecture.mmd`
  on `--start`, `tree.mmd` auto-regenerated on every state change
  (wrapper-side AND direct filesystem events via the daemon hook),
  `~/.antcrate/registry.mmd` covering relationships across all
  projects.
- **Tool selection is case-by-case** based on the project's domain,
  stack tags, file extensions, and (eventually) bundle manifest hints.
  Mermaid for tree/registry/quick-overview; PlantUML for class +
  sequence when the stack is OO; D2 for architectural overviews;
  SchemaSpy for any project with a database. The selection logic lives
  in `assets/docs/DIAGRAM_PLAN.md`.
- **Renderers (`mmdc`, `plantuml`, `d2`) are an implementation detail**
  — they convert AntCrate's emitted text-of-truth files into images.
  Their absence is graceful-degradation (Mermaid renders inline on
  GitHub regardless); their presence promotes text → SVG. The choice
  of *which diagram to emit per project* is AntCrate's responsibility
  and lives in the wrapper, not the renderer.
- **`assets/docs/DIAGRAM_AUTOMATION_GUIDE.md`** is the underlying tool
  catalog (Quick Picker, the seven core tools, source-of-truth-by-type
  sections). It's the reference that backs the selection algorithm in
  `DIAGRAM_PLAN.md`.

The principle: diagrams ease development and make every project legible
to anyone working with AntCrate. They're how the wrapper's coherent
view of state becomes a coherent view of *meaning*. Treating them as a
mere external dependency would have under-stated their role.

## Why this file exists at all

Mostly for transparency: when a future agent (or the user) asks "what
does AntCrate plug into?" the answer is on disk in one place. The
honest answer right now is *very little* — AntCrate is the
orchestration shell, the harness loads its own skills when relevant,
and memory + `CLAUDE.md` carry cross-session and project-local context.
The interesting future composition is the per-project skill drop on
ingest, captured above.
