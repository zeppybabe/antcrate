# AntCrate Bundle Specification — v1.0

A **bundle** is the typed handshake artifact between two AntCrate instances:
**research-AntCrate** (the producer, on the research machine) and
**dev-AntCrate** (the consumer, on the development machine). Both sides are
equally complex and equally deterministic — the bundle is what passes between
them, not a one-way data drop.

A bundle answers, in deterministic form, three questions the dev side needs
before it can begin work:

1. **What are we building, and why?** (objective, narrative research)
2. **What baseline do we start from?** (source repo + commit, or "no baseline" for
   theoretical projects)
3. **What context does the agent need to be useful immediately?** (per-project
   Claude skill, stack-specific `CLAUDE.md`, parsed schemas, etc.)

Everything else in a bundle — research narratives, papers, captured articles,
diagrams, schemas — is **opaque** to AntCrate. The wrapper copies these files
to well-defined locations on ingest and never parses or validates their
contents. The opaque payload is documentation that survives long after the
initial ingest, useful to any future developer (human or AI) picking up the
project.

---

## 1. Bundle layout

A bundle is a directory. Its name should match the bundle's `name` field.

```
<bundle-name>/
├── manifest.json           # REQUIRED — the routing contract (parsed by AntCrate)
├── research.md             # RECOMMENDED — narrative: objective, findings, gotchas
├── claude.md               # OPTIONAL — copied to <project>/CLAUDE.md on ingest
├── skill/                  # OPTIONAL — copied to ~/.claude/skills/<name>/
│   ├── SKILL.md
│   └── context/            # opaque to AntCrate; loaded by Claude Code
├── diagrams/               # OPTIONAL — *.mmd / *.puml / *.d2 seeds
│   └── architecture.mmd    # copied to <project>/docs/diagrams/ on ingest
└── attachments/            # OPTIONAL — fully opaque (papers, schemas, dumps)
```

Anything outside `manifest.json` is **opaque**. AntCrate copies these files to
predetermined destinations on ingest but never parses them. A research producer
is free to add more directories under `attachments/` without breaking the
spec.

A bundle MAY be packaged as a tarball (`<bundle-name>.tar.gz`) for transport;
on ingest it is unpacked and treated identically to a directory.

---

## 2. `manifest.json` — the routing contract

`manifest.json` is the only file AntCrate parses. Everything the wrapper needs
to register, clone, and route the project lives here.

### 2.1 Required fields

| Field | Type | Description |
|---|---|---|
| `spec_version` | string | Bundle spec version, e.g. `"1.0"`. AntCrate refuses unknown major versions. |
| `name` | string | Project name. Matches AntCrate registry rules: no whitespace, no `/`, no leading `.`, no `..`. |
| `domain` | string | Routing directory under `~/projects/`. One of: `webapps`, `scripts`, `notes`, `projects`, `_generic` (or any value if domain whitelisting is disabled). |
| `objective` | string | One-line plain-English purpose. Why this bundle exists. Stored on the registered project. |
| `generated_at` | string | ISO-8601 UTC timestamp of bundle creation, e.g. `"2026-04-28T15:00:00Z"`. |

### 2.2 The `source` object

Describes the baseline code AntCrate clones (or doesn't) when ingesting.
**Required** — but `type: "none"` is a valid value for theoretical bundles.

| `source.type` | Required sub-fields | Description |
|---|---|---|
| `git` | `url`, optionally `commit`, `branch` | Cloned via `git clone`; if `commit` is set, the wrapper checks out that SHA after clone (reproducibility). If absent, latest of `branch` (or default branch) is used. |
| `archive` | `url`, optionally `sha256` | Tarball/zip downloaded and extracted; if `sha256` is set, the download is verified before extraction. |
| `none` | — | Theoretical / research-only bundle. AntCrate registers an empty project tree (just the scaffolded `docs/`) and drops the bundle's narrative + skill into place. |
| `composite` | `sources: [<source>...]` | Multiple sub-sources, merged in declaration order (first wins on path conflicts). For projects assembled from several upstream repos. |

### 2.3 Optional fields

| Field | Type | Description |
|---|---|---|
| `stack` | `string[]` | Free-form tech tags (`["sveltekit", "drizzle", "typescript"]`). Informational; helps the dev agent orient. |
| `tags` | `string[]` | Free-form labels for queue grouping/searching. |
| `priority` | integer | Queue ordering hint (1 = highest, default 5). The consumer side decides how to honor it. |
| `notes` | string | Short producer notes — anything that doesn't belong in `research.md`. |
| `research_agent` | string | Producer identifier (`"claude-research-v0.3"`, `"human-curated"`, `"ollama-arxiv-scraper"`). Audit only. |
| `relationships` | array | See §2.4. |
| `claude` | object | Optional ingest hints. Recognized keys: `model_hint` (string), `skill_name` (string, defaults to `name`). |

### 2.4 `relationships` — bundle-to-bundle links

Each entry is `{ "kind": <kind>, "bundle": <name>, "note": <optional string> }`.

| `kind` | Meaning | Effect on ingest |
|---|---|---|
| `duplicate_of` | This bundle researches the same target as another. Producer side is flagging an overlap. | Informational. Dev side is free to ingest whichever it prefers and skip the other. |
| `supersedes` | This bundle replaces an earlier one (better research, different baseline). | Dev side, if the named bundle is already a registered project, treats ingest as a versioned update: backup the existing project + research/skill, then overwrite. Falls under AGENTS.md rule #1 (backup + approval gate). |
| `extends` | This bundle adds research/scope to an existing project; not a new project. | Dev side merges new files into the existing project's `docs/research/`, updates the per-project skill, **does not** re-clone the source repo. |
| `depends_on` | Producer notes that another project must exist before this one is useful. | Informational only. Dev side may warn if the dependency isn't registered. |

`duplicate_of` and `extends` may both be used by the *research* side to keep
the queue clean even before any ingest happens.

---

## 3. Status lifecycle

A bundle in transit between the two machines passes through a small state
machine. The state lives in a `STATUS` file alongside `manifest.json` (single
line: state name + optional reason).

```
ready ──► claimed ──► ingested ──► consumed
                  └─► failed
```

| State | Set by | Meaning |
|---|---|---|
| `ready` | producer | Research is complete, bundle committed, available for ingestion. |
| `claimed` | consumer | A consumer started ingestion. Acts as a lock; another consumer should not double-claim. |
| `ingested` | consumer | Ingestion succeeded, project is registered, work can begin. |
| `consumed` | consumer | Project work is complete (`antcrate --conclude <project>`). Bundle is closed. |
| `failed` | consumer | Ingestion failed. The `STATUS` file should include a one-line reason (e.g., `failed: source.url unreachable`). |

For solo-developer single-consumer setups, the lifecycle is mostly bookkeeping
— but spec'ing it now means multi-consumer setups (or replays from history)
work later without protocol changes.

---

## 4. Validation contract

On ingest, AntCrate validates **before any disk write**. Any failure aborts the
ingest with no side effects (other than possibly setting `STATUS = failed`).

In order:

1. `manifest.json` exists at the bundle root, parses as JSON.
2. `spec_version` is a recognized major version (currently `1.x`).
3. All required fields (§2.1) are present and non-empty.
4. `name` matches AntCrate's name rules (no whitespace, no `/`, no leading `.`, no `..`).
5. `domain` is acceptable (passes the active whitelist, if any; otherwise unrestricted).
6. `source.type` is recognized; required sub-fields present.
7. If `name` is already in the registry: refuse, **unless** the manifest declares
   `relationships` with `kind: "supersedes"` or `kind: "extends"` naming a
   registered project.
8. **Reachability**:
   - `source.type == "git"`: `git ls-remote <url>` succeeds.
   - `source.type == "archive"`: HTTP HEAD on `url` returns 2xx.
   - `source.type == "composite"`: each sub-source is checked.
   - `source.type == "none"`: skip.
9. If `source.commit` (git) or `source.sha256` (archive) is pinned, store it for
   verification at clone time.

A successful ingest writes:

- The cloned source repo (or empty scaffold) to `~/projects/<domain>/<name>/`
- `manifest.objective` into the registry alongside the project entry
- `research.md` → `<project>/docs/research.md`
- `claude.md` → `<project>/CLAUDE.md` (if present)
- `skill/` → `~/.claude/skills/<skill_name>/` (default `<skill_name> = name`)
- `diagrams/*` → `<project>/docs/diagrams/`
- `attachments/*` → `<project>/docs/attachments/`

Then the standard auto-regen fires: `~/.antcrate/registry.mmd` and the new
project's `tree.mmd` refresh.

---

## 5. Opaque-files policy

AntCrate parses **only** `manifest.json`. Every other file in a bundle is
opaque: AntCrate copies it to a documented destination and never reads,
validates, or transforms its contents.

This is deliberate. The research producer (whatever it is — Python script,
Claude agent, Ollama agent, human) needs freedom to record whatever shape of
research is most useful: prose, JSON dumps of API responses, captured paper
PDFs, hand-drawn diagrams scanned in, math notation. AntCrate's contract is
"route the bundle correctly"; the *meaning* of the research belongs to the
agent that consumes it (Claude Code, in our case).

Concretely, this means:

- A producer can add new file types (`.bib`, `.ipynb`, `.svg`) without bumping
  the spec version.
- A producer can add new top-level directories under `attachments/` freely.
- AntCrate will not refuse a bundle because of the *content* of an opaque
  file. Only `manifest.json` parsing/validation can fail-the-bundle.

Producers SHOULD keep opaque files reasonably small (a bundle is a unit of
transport, not a long-term archive). If a bundle needs to reference very large
files, prefer a URL in `manifest.notes` over embedding.

---

## 6. Versioning & forward compatibility

`spec_version` is a string `"<major>.<minor>"`.

- **Major** bumps signal breaking changes. AntCrate refuses unknown majors
  with a clear error directing the user to upgrade.
- **Minor** bumps add optional fields or relationship kinds. AntCrate ignores
  unknown optional fields (forward-compatible reads) but warns once per ingest
  if any are present, so producers know the consumer is older than the bundle.

Spec changes are recorded in `assets/docs/BUNDLE_SPEC.md` itself, with each
version's delta noted at the bottom.

---

## 7. Minimum-viable producer / consumer responsibilities

### Producer (research-AntCrate) MUST:

1. Emit a directory matching §1's layout, with a valid `manifest.json` per §2.
2. Write `STATUS` containing `ready` when the bundle is committed.
3. Honor `relationships` semantics — don't claim `supersedes` for a name that
   was never produced before.

### Producer SHOULD:

1. Pin `source.commit` (or `source.sha256` for archives) for reproducibility.
2. Provide `research.md` for any non-trivial bundle. A bundle with no narrative
   is permitted but reduces the value to the dev side.
3. Mark `duplicate_of` rather than producing two competing bundles.

### Consumer (dev-AntCrate) MUST:

1. Run all validation steps in §4 before any disk write.
2. Refuse unknown major `spec_version`.
3. Update `STATUS` to `claimed` → `ingested` (or `failed`) atomically.
4. Honor AGENTS.md rule #1 for `supersedes` ingests (backup the prior project
   tree before overwrite, get user approval).

### Consumer SHOULD:

1. Surface `relationships` to the user when ingesting (e.g., "this bundle
   supersedes 'foo' which is already registered — backup will be taken before
   overwrite").
2. Warn on stale `source.commit` (HEAD has moved since the bundle was generated)
   without refusing — the user/agent decides whether to ingest as-pinned or
   `--latest`.

---

## 8. Examples

See `assets/docs/examples/bundles/` for complete, minimal example bundles:

| Example | Demonstrates |
|---|---|
| `examples/bundles/git-pinned/` | Standard case: git source, commit-pinned, full skill seed. |
| `examples/bundles/theoretical/` | `source.type: "none"` — research-only bundle, no baseline code. |
| `examples/bundles/composite/` | Multiple git sources merged into one project. |
| `examples/bundles/supersedes/` | Replaces an earlier bundle's project; demonstrates `relationships`. |

---

## 9. Open items (deferred to v1.1+)

- **Bundle signing.** A `signature` field referencing a detached signature
  over `manifest.json`, so the consumer can verify the bundle came from a
  trusted producer. Useful once research bundles are exchanged across
  trust boundaries.
- **Bundle bundles.** A "campaign" manifest that groups several related
  bundles for ingestion as a unit (e.g., a frontend + backend + shared lib
  triple).
- **Live source tracking.** Optional `source.tracking: "head"` semantic where
  the dev side periodically checks for upstream changes and surfaces them
  via `--queue` instead of requiring a new bundle.

These are not part of v1.0 — they're noted so the field names don't get
accidentally consumed by something else.

---

## Changelog

- **v1.0 (2026-04-28)** — Initial spec.
