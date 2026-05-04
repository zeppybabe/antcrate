# AntCrate — Diagram Plan

Status: **partial implementation as of 2026-05-01.** Auto-regen of two
universal diagrams (registry-level + project-tree) is shipped and
firing on both wrapper-side mutations and direct filesystem events
(daemon hook). What's queued is the **case-by-case selection algorithm**
that picks additional context-appropriate diagrams per project (stack-
specific class diagrams, sequence diagrams for API flows, ERDs for
database projects, infrastructure diagrams for IaC repos, etc.).

This document is the contract for that follow-up so the surface stays
coherent across sessions. It treats `assets/docs/
DIAGRAM_AUTOMATION_GUIDE.md` as the underlying tool catalog (Quick
Picker, the seven core tools, source-of-truth-by-type sections) and
adds the *AntCrate-specific* logic on top: which diagrams ship per
project, when, and how the wrapper auto-selects.

## Why this matters

Every registered project should be legible at a glance to anyone
working with AntCrate. The wrapper already gives you a coherent view
of *state* (registry.json, `--map`, `--list`); diagrams give you the
coherent view of *meaning* — what the project does, how its parts
connect, what depends on what. Without auto-generation, those views
drift the moment code changes. With auto-generation tied to the right
case-by-case tool, every project gets a current, appropriate visual
representation for free.

The principle: **diagrams are first-class AntCrate output.** Renderers
(`mmdc`, `plantuml`, `d2`, `schemaspy`) are an implementation detail.
The choice of *which diagram to emit per project* belongs to the
wrapper, governed by this document.

## What's shipped today (2026-05-01)

### Universal diagrams (every project gets these)

| Diagram | Path | When refreshed | Tool |
|---|---|---|---|
| Registry overview | `~/.antcrate/registry.mmd` | Every wrapper mutation; daemon-event-driven via auto-regen | Mermaid `graph LR` |
| Project tree (addressed) | `<project>/docs/diagrams/tree.mmd` | Every wrapper mutation in this project; any direct filesystem event under it (daemon hook with per-project debounce) | Mermaid `graph TD` |
| Architecture seed | `<project>/docs/diagrams/architecture.mmd` | Once, on `--start`, from `_generic/` template | Mermaid `graph TD` (placeholder for the user/agent to expand) |

### Wrapper flags (shipped)

| Flag | What it emits | Renders if tools present |
|---|---|---|
| `--diagrams <project>` | Bulk-renders every `*.mmd` / `*.puml` / `*.d2` in `<project>/docs/diagrams/` to SVG | Yes — graceful skip with one-line warn per missing tool |
| `--registry-diagram [out]` | Manual override: regenerates the registry-level Mermaid | n/a (text output) |
| `--tree-diagram <project> [out]` | Manual override: regenerates the project tree Mermaid | n/a (text output) |

Manual flags are now mostly fallback / repair paths since auto-regen
covers normal operation.

### Auto-regen invariants (shipped)

- **Wrapper-side**: every mutating action (`start`, `register`,
  `branch`, `link`, `resume --expand`, `rename`, `archive`,
  `unarchive`, `remove`, `touch`, `mkdir`, `restore`) calls
  `ac_diagrams_auto_regen <project>` after the underlying op succeeds.
  Silent on stdout (preserves `--touch` / `--mkdir` composition
  contract). Errors swallowed (a diagram refresh never blocks the
  triggering action).
- **Daemon-side**: `bin/antcrated` watches every registered project
  and fires `ac_diagrams_auto_regen <project>` on
  `create | close_write | moved_to | moved_from | delete` events
  (filtered for swap/dot files). Per-project debounce
  (`ANTCRATE_TREE_DEBOUNCE_MS`, default 600ms) coalesces bursts
  (`git checkout`, batch saves).
- **Opt-out**: `export ANTCRATE_AUTO_DIAGRAMS=0` disables both paths.
  For batch scripted mutations where one explicit regen at the end is
  preferred.

---

## What's queued: case-by-case diagram selection

The shipped universal diagrams cover *structure* (file tree) and
*relationships across projects* (registry). What they don't cover is
the *project-specific* views — class diagrams, sequence/flow,
infrastructure, ERDs. These are what make a project legible in a way
the universal pair can't.

### Selection inputs

The selector should consider, in priority order:

1. **Bundle manifest hints** (when ingested via BUNDLE_SPEC `--ingest`):
   `manifest.stack` array drives which diagram presets fit. Stack tags
   like `sveltekit`, `python`, `rust`, `terraform`, `postgres`,
   `kubernetes` map to known presets.
2. **Project domain** (registered): `webapps` defaults differ from
   `scripts` differ from `notes`. A `webapps` project gets at least a
   request-flow sequence diagram seed; a `scripts` project gets a
   call-graph; a `notes` project gets only the universal tree.
3. **File extensions present** in the project tree: `.sql` → ERD
   eligible; `.tf` → infra eligible; `package.json` → JS dep graph
   eligible; `Cargo.toml` → crate graph eligible.
4. **Explicit user choice** via `--diagram-preset <preset>` flag (see
   below).

### Preset library (queued)

A registered set of *presets* — named bundles of diagram types — that
map to one or more emitter functions. Initial set:

| Preset | Diagrams | Tool(s) | Triggered by |
|---|---|---|---|
| `bash` | universal + bash call-graph (functions → callers) | Mermaid (custom emitter) | `domain in (scripts, notes)` or `*.sh` files present |
| `node` / `js` | universal + dep graph + module-import overview | Madge / dependency-cruiser → JSON → Mermaid | `package.json` present |
| `svelte` | `node` + request-flow sequence (server endpoints → DB calls) | PlantUML sequence | `svelte.config.js` or `+page.server.ts` files |
| `python` | universal + class/package via pyreverse | pyreverse → PlantUML → SVG | `*.py` files present + pylint installed |
| `rust` | universal + crate graph | cargo-depgraph → DOT → Graphviz | `Cargo.toml` present |
| `go` | universal + package graph | godepgraph → DOT → Graphviz | `go.mod` present |
| `terraform` / `iac` | universal + infra layout | Inframap or Rover | `*.tf` files present |
| `k8s` | universal + cluster resource view | k8sviz | `k8s/`, `manifests/`, or `*.yaml` with `kind:` |
| `db` | universal + ERD | SchemaSpy (live DB) or DBML (text source) | `db/schema.sql`, `prisma/schema.prisma`, `drizzle/*.ts` detected, or explicit |
| `cloud-arch` | universal + cloud architecture diagram | mingrammer/diagrams (Python DSL) | explicit only — author-driven |
| `none` | universal only | — | explicit opt-out |

Each preset is a small Bash function in `lib/diagrams.sh` (or a
sub-module) that emits the appropriate text-of-truth files into
`<project>/docs/diagrams/`. The preset chooses *which files to emit*;
the existing `--diagrams` bulk render handles converting them to SVG
when the renderer is on PATH.

### Wrapper flags (queued)

| Flag | Purpose |
|---|---|
| `--diagram-preset <project> [<preset>]` | List/set the active preset for a project. Stored in `registry.json` under `diagrams.preset`. With no `<preset>` argument, prints the current. |
| `--diagram-detect <project>` | Run the auto-detection heuristic (file extensions + bundle hints) and propose a preset. Read-only — does not change state until the user opts in. |
| `--diagrams <project> --refresh-all` | Force-regenerate every diagram in the active preset (not just the auto-regen pair). Useful after a major refactor. |
| `--start <name> --domain <d> --diagrams <preset>` | Auto-install a preset on scaffold. Default: domain → preset mapping (webapps→`svelte` if `--meta` includes `sveltekit`; scripts→`bash`; etc.). |

### registry.json schema extension

```json
{
  "projects": {
    "<name>": {
      "path": "...",
      "parent": "...",
      "diagrams": {
        "preset": "svelte",
        "active": ["tree", "registry", "request-flow"],
        "last_regen": "2026-05-01T20:30:00Z"
      }
    }
  }
}
```

Backward-compatible: missing `diagrams` field → preset defaults to
`auto` (run `--diagram-detect` on first auto-regen attempt).

### Source-of-truth invariants (carry forward to v2)

- **Text is the source of truth.** Every preset emits text files
  (`.mmd`, `.puml`, `.d2`, `.dbml`, `.dot`). SVGs are derived. Never
  the other way around.
- **Diagrams render inline on GitHub when text-of-truth is Mermaid.**
  Default to Mermaid where it's a reasonable fit so the "no renderer
  installed" case still produces a usable artifact.
- **Renderer absence is graceful.** `--diagrams` already warns and
  continues per-renderer; presets must follow the same pattern.
- **Diagrams live with the code they describe.** All emitted diagrams
  go under `<project>/docs/diagrams/`; never in `~/.antcrate/` or a
  global cache (with the single exception of the registry-level
  diagram which spans projects).

### Surface boundaries (what diagram automation WILL NOT do)

- **Will not fabricate structure that doesn't exist in the code.** A
  request-flow diagram is generated from real route files and real
  function calls — never made up to look impressive.
- **Will not auto-publish diagrams to external services** (Lucidchart,
  Miro, Confluence, etc.). All output stays on disk + git.
- **Will not regenerate on every keystroke.** Daemon debounce caps
  refresh frequency at one per `ANTCRATE_TREE_DEBOUNCE_MS` per project.
- **Will not require optional renderers** to be installed. Mermaid
  text renders inline on GitHub regardless; SVG promotion is a bonus.

---

## Order of implementation (proposed)

1. **`lib/diagrams.sh` preset infrastructure** — `ac_diagrams_preset_*`
   helpers, registry schema extension, `--diagram-preset` /
   `--diagram-detect` flags.
2. **First non-trivial preset: `bash`** — call-graph emitter from
   shell function definitions + invocations. Tests against
   `lib/registry.sh` itself (a moderately complex call graph).
3. **Auto-detection heuristic** — file-extension scan + bundle-stack
   integration, produces preset proposals.
4. **`--start --diagrams <preset>` auto-install** — scaffolds the
   preset's text-of-truth files on project creation.
5. **Stack-specific presets, in priority order**: `node` → `svelte` →
   `python` → `rust` → `go` → `terraform` → `db` → `k8s`.
6. **Bundle-driven preset selection** (depends on `--ingest`): when a
   bundle declares `manifest.stack`, the consumer side automatically
   selects the matching preset on ingest.
7. **`--refresh-all`** — final convenience flag for force-regeneration
   after major changes.

Each step is one focused pass with bats coverage, a `state.md` "Top
of mind" entry, and a `ledger.md` entry. This document is the spec
they all reference.

## Maintenance

- **New preset added**: append a row to the Preset library table.
  Each preset entry MUST include: name, what it emits, tool(s)
  required, trigger condition.
- **New emitter function in `lib/diagrams.sh`**: name pattern is
  `ac_diagrams_emit_<preset_or_diagram>`; behavior must be silent on
  stdout, errors swallowed (so it can be called from auto-regen
  without breaking the triggering action).
- **Tool catalog updates** belong in `DIAGRAM_AUTOMATION_GUIDE.md`,
  not here. This file is the *AntCrate selection logic*; that file is
  the *underlying reference*.
