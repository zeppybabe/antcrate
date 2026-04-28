# Diagram Automation — General-Purpose Guide

A toolkit for generating diagrams **from source-of-truth artifacts** (SQL, code, configs, prose) instead of hand-drawing them. Organized by what you're trying to diagram.

## Core Principle

Hand-drawn diagrams drift. The moment the underlying code/schema/config changes, your PNG is wrong. Every recommendation here treats some text artifact as the source of truth and generates the diagram from it. If you can't generate it from text, version it as text (PlantUML, Mermaid, D2, DBML).

---

## Quick Picker

| You want to diagram… | Use this | Why |
|---|---|---|
| Live database schema | **SchemaSpy** | Connects to DB, generates ERD + per-table HTML site |
| Schema in version control | **DBML** (`dbdiagram.io`) or **PlantUML** | Text source, prettiest output |
| Code architecture (any lang) | **Mermaid** or **PlantUML** | Markdown-native; renders in GitHub/GitLab/Notion |
| Class diagrams from code | **PlantUML + language plugin** | One command per language |
| Python project structure | **pyreverse** (built into pylint) | Generates UML class + package diagrams |
| Java/Kotlin codebase | **PlantUML** + IntelliJ diagrams | Built into IDE |
| C/C++ call graphs | **Doxygen + Graphviz** | Industry standard |
| TypeScript/JS dependency graph | **Madge** or **dependency-cruiser** | Detects circular deps |
| Go package structure | **godepgraph** + Graphviz | Native Go tooling |
| Rust crate graph | **cargo-depgraph** | Native cargo tooling |
| Sequence diagrams | **Mermaid** or **PlantUML** | Both excel at this |
| Cloud / infra architecture | **Diagrams (mingrammer/diagrams)** | Python DSL with AWS/GCP/Azure icons |
| Terraform infra | **Inframap** or **Rover** | Reads `.tf` state directly |
| Kubernetes resources | **k8sviz** or **KubeView** | Reads cluster live |
| State machines | **Mermaid stateDiagram** or **XState visualizer** | XState if you're actually running them |
| API flows | **Mermaid sequenceDiagram** | Most-supported renderer |
| Network topology | **D2** (terrastruct) | Best modern layout engine |
| Anything in a slide deck | **Excalidraw** | Hand-drawn aesthetic, exports to SVG |
| Anything you'll iterate on with a team | **D2** or **Mermaid** | Both have live editors |

---

## The Seven Tools You Actually Need

### 1. Mermaid — Markdown-Native, Universal

Renders inline in GitHub READMEs, GitLab issues, Notion, Obsidian, and most static site generators. Zero install for the common case.

```mermaid
graph LR
    A[Client] --> B[API Gateway]
    B --> C[Auth Service]
    B --> D[Database]
```

**Strengths:** Flowcharts, sequence diagrams, class diagrams, ERDs, state diagrams, Gantt, git graphs. Lives next to your prose docs.
**Weaknesses:** Layout engine is weaker than Graphviz; large diagrams get cramped.
**Install:** none for GitHub/GitLab. CLI: `npm install -g @mermaid-js/mermaid-cli` then `mmdc -i in.mmd -o out.svg`.

### 2. PlantUML — Most Powerful Text-to-Diagram

Java-based. Largest diagram-type catalog of any tool: UML class, sequence, activity, state, deployment, component, use case, ERD, Gantt, mind map, work breakdown.

```plantuml
@startuml
class User { +id : int; +login() }
class Session { +token : str }
User "1" --> "*" Session
@enduml
```

**Strengths:** Anything UML, very mature, Graphviz-backed layout. Ships in the JetBrains IDEs and VSCode via extensions.
**Weaknesses:** Requires Java. Default theme is dated (load `!theme plain` or one from plantuml-themes).
**Install:** `sudo apt install plantuml graphviz` or use the live editor at plantuml.com.

### 3. D2 — Modern Successor to PlantUML

Newer (2022+), text-based, designed by ex-Terrastruct. Better layout engine, prettier defaults, simpler syntax. Worth using over PlantUML for greenfield work where you don't need the strict UML notation.

```d2
client -> api: HTTPS
api -> db: SQL
api.shape: cloud
```

**Strengths:** Beautiful defaults, animations, multiple layout engines (dagre, ELK, TALA), great for system architecture. CLI is a single Go binary.
**Weaknesses:** Smaller community than Mermaid/PlantUML. Some renderers (TALA) require account.
**Install:** `curl -fsSL https://d2lang.com/install.sh | sh -s --` then `d2 in.d2 out.svg`.

### 4. Graphviz / DOT — The Foundation

Most other tools (PlantUML, Doxygen, pyreverse) compile to Graphviz under the hood. Direct use is worth knowing for one-off graphs and when you need fine layout control.

```dot
digraph G { A -> B -> C; A -> C [label="shortcut"] }
```

**Install:** `sudo apt install graphviz` then `dot -Tsvg in.dot -o out.svg`.

### 5. Mingrammer Diagrams — Cloud Architecture as Python

Python DSL with hundreds of provider icons (AWS, GCP, Azure, K8s, Alibaba, OCI, on-prem). The right answer for "draw our microservices on AWS."

```python
from diagrams import Diagram
from diagrams.aws.compute import EC2
from diagrams.aws.database import RDS
with Diagram("Web", show=False):
    EC2("web") >> RDS("db")
```

**Install:** `pip install diagrams` + Graphviz.

### 6. SchemaSpy — Database Schema Auto-ERD

Points at any JDBC database, produces a static HTML site with ERDs, per-table pages, FK graph, anomalies report. The standard answer for "diagram our existing database."

**Install:** download JAR + JDBC driver. Works with MySQL/MariaDB, Postgres, Oracle, SQL Server, SQLite, DB2.

### 7. Excalidraw — When You Need to Draw, Not Generate

Hand-drawn aesthetic, web-based, free, exports to SVG/PNG. Use for ad-hoc whiteboard-style diagrams that don't have a textual source-of-truth equivalent. The `.excalidraw` file *is* JSON, so it does version-control.

**URL:** excalidraw.com. Self-host via Docker if needed.

---

## By Source-of-Truth Type

### Generating diagrams from a database

```bash
# SchemaSpy (full HTML site + ERD)
java -jar schemaspy.jar -t mariadb -dp ./mariadb-jdbc.jar \
    -host localhost -db mydb -u user -p pass -o ./out

# Or: dump to DBML and render at dbdiagram.io
db2dbml mysql 'mysql://user:pass@host/db' -o schema.dbml
```

Postgres has the additional option of `pg_dump --schema-only` piped into [pgmodeler](https://pgmodeler.io) or [DBeaver](https://dbeaver.io) for a visual diagram.

### Generating diagrams from code

| Language | Tool | Command |
|---|---|---|
| Python | pyreverse (pylint) | `pyreverse -o png -p MyProj mypackage/` |
| Java | PlantUML's class-diagram extractor + IntelliJ | IDE: right-click → Diagrams → Show Diagram |
| TypeScript / JS | Madge | `madge --image graph.svg src/` |
| TypeScript / JS | dependency-cruiser | `depcruise --output-type dot src \| dot -Tsvg > deps.svg` |
| Go | godepgraph | `godepgraph -s github.com/me/proj \| dot -Tsvg > out.svg` |
| Rust | cargo-depgraph | `cargo depgraph \| dot -Tsvg > out.svg` |
| C / C++ | Doxygen + Graphviz | `doxygen -g; doxygen Doxyfile` |
| Ruby | RailRoady (Rails) | `railroady -M \| dot -Tsvg > models.svg` |
| Any | Sourcetrail (interactive) | GUI app, indexes the codebase |

### Generating diagrams from infrastructure

| Source | Tool |
|---|---|
| Terraform `.tf` files | **Inframap** (`inframap generate main.tf \| dot -Tsvg`) or **Rover** (web UI) |
| Terraform plan output | `terraform graph \| dot -Tsvg` (built-in) |
| Live Kubernetes cluster | **k8sviz**, **KubeView**, or `kubectl tree` |
| Helm chart | **helm-diagram** plugin |
| Docker Compose | **docker-compose-viz** (`dcv render docker-compose.yml \| dot`) |
| Cloud account (AWS) | **CloudMapper** or **AWS Perspective** |

### Generating diagrams from prose / specs

OpenAPI / Swagger → use [openapi-to-plantuml](https://github.com/davidmoten/openapi-to-plantuml) or render directly with Swagger UI.
GraphQL schema → **graphql-voyager** (interactive) or **graphql-schema-diagram**.
Protocol Buffers → **protoc-gen-doc** with the HTML template.

---

## Recommended Stack for a New Project

For most software projects, this five-tool stack covers ~95% of diagramming needs:

1. **Mermaid** in the README and architecture docs — renders for free on GitHub.
2. **PlantUML** or **D2** files in `docs/diagrams/` for anything Mermaid can't handle.
3. **SchemaSpy** in CI, output published as a GitHub Pages site, regenerated on every schema migration.
4. **Mingrammer Diagrams** for the one-pager cloud architecture diagram.
5. **Excalidraw** for ad-hoc whiteboard sessions — paste the SVG into the doc afterward.

Add one language-specific tool from the table above for code-structure diagrams.

---

## CI Integration Pattern

Auto-render diagrams on every commit to keep them in sync with the code:

```yaml
# .github/workflows/diagrams.yml
on: [push]
jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt install -y plantuml graphviz
      - run: |
          for f in docs/diagrams/*.puml; do
            plantuml -tsvg "$f"
          done
      - run: |
          npm install -g @mermaid-js/mermaid-cli
          for f in docs/diagrams/*.mmd; do
            mmdc -i "$f" -o "${f%.mmd}.svg"
          done
      - uses: stefanzweifel/git-auto-commit-action@v5
        with:
          commit_message: "ci: re-render diagrams"
```

For SchemaSpy: run it as a job on every migration, push the output to GitHub Pages or an S3 bucket.

---

## Tools to Avoid (or Use Sparingly)

- **draw.io / diagrams.net** — XML format works, but it's not human-editable in practice; it becomes a manual artifact that drifts. OK for one-offs, bad for long-lived projects.
- **Lucidchart / Visio** — proprietary file format, no diff, no CI. Only viable if your org is already locked in.
- **PowerPoint shapes** — fine for the final slide deck, never the source of truth.
- **PlantUML for cloud architecture** — works but cumbersome; use Mingrammer Diagrams instead.

---

## Cheat Sheet: One-Liners

```bash
# Mermaid file → SVG
mmdc -i diagram.mmd -o diagram.svg

# PlantUML file → PNG
plantuml -tpng diagram.puml

# D2 file → SVG
d2 diagram.d2 diagram.svg

# Python code → UML
pyreverse -o svg -p MyProj mypackage/

# JS/TS imports → graph
madge --image graph.svg src/

# Live database → full HTML site
java -jar schemaspy.jar -t mariadb -dp jdbc.jar -host localhost -db mydb -u u -p p -o out/

# Terraform → architecture
terraform graph | dot -Tsvg > infra.svg

# Docker Compose → service graph
dcv render docker-compose.yml | dot -Tsvg > stack.svg

# Doxygen for any C-family code
doxygen -g && doxygen Doxyfile
```

---

## File Format Recommendation

For text-source diagrams in version control:

- `.mmd` — Mermaid
- `.puml` — PlantUML
- `.d2` — D2
- `.dot` — Graphviz DOT
- `.dbml` — DBML (database)
- `.excalidraw` — Excalidraw (JSON, diffs OK)

Avoid binary formats (`.drawio`, `.vsdx`, `.lucidchart`) in version-controlled repos.
