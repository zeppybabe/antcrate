# AntCrate — Lib Map

Relocated verbatim from the orchestrator `SKILL.md` (three-tier skill cut, spec 2026-06-11): the full catalog of where every binary, lib, hook, doc, and state file lives. Read at the moment of need, not as a session-start tax.

## Where things live

### Code (`assets/code/`)

- **`bin/antcrate`** — the Wrapper CLI (single dispatcher, sources all libs)
- **`bin/antcrated`** — the Pipe (inotifywait daemon: schema dispatch + live-tree auto-regen, longest-prefix project resolution, per-project debounce, registry-cache mtime keyed)
- **`lib/*.sh`** — sourced helpers:
  - `registry.sh` — atomic jq CRUD on `registry.json`
  - `schema.sh` — positional filename decoder
  - `scaffold.sh` — `--start` / `--branch` / `--link` / `--register`
  - `subbranch.sh` — atomic `--resume --expand` nesting (backup-protected)
  - `safety.sh` — path-zone guard + `ac_safety_guard_destructive` (rule #1 enforcement)
  - `backup.sh` — verified tar.gz + sha256 manifests, retention pruning, restore
  - `commit.sh` — `--commit` wrapper with secret-pattern guard + Gateway-Law preview/prompt (rule #12)
  - `git_triage.sh` — `--pp` push wrapper with conflict triage to `/tmp/antcrate_conflict.log`
  - `gh.sh` — `--gh-init` (HTTPS via `gh` CLI, no plaintext PATs)
  - `address.sh` — layered positional addressing (`1a3` = 3rd entry inside the 1st sub-branch of the 1st top-level dir; bijective base-26 letters)
  - `anchor.sh` — `--in` / `--anchor` (no bare `cd`)
  - `devops.sh` — `--map`, `--rename`, `--archive`, `--unarchive`, `--remove`, `--touch`, `--mkdir`, `--logs`, `--diff`, `--selfsrc`/`--selfinstall`/`--install-from-source`/`--selftest`/`--selfedit`, `--ci`
  - `diagrams.sh` — Mermaid registry + tree generation, `ac_diagrams_auto_regen` (silent, opt-out via `ANTCRATE_AUTO_DIAGRAMS=0`)
  - `hooks.sh` — `--hooks` (read-only listing) + `--hook-log` (debug blocked commits)
  - `events.sh` — append-only activity stream (`~/.antcrate/events/<project>.jsonl`); `--emit-activity` writes
  - `watch.sh` — colored tree renderer over the active event overlay; `--watch` loops, `--once` for scripts; `--watch-smoke` emits + renders in one call
  - `watch_window.sh` — detached terminal window management; `--watch-window` spawns alacritty with PID-file dedup
  - `cleanup.sh` — classifier + apply for test-tmp / empty-dir candidates; `--cleanup <project> [--apply <id>...]`
  - `hygiene.sh` — registry hygiene; `--ghosts` (read-only list of entries whose path is missing) + `--deregister <project>` (capture-first registry-only drop of a ghost; refuses if path exists → `--archive`). See AGENTS.md rule #19.
  - `git_init.sh` — local-only `git init` for a registered project (idempotent + `core.hooksPath` wire); `--git-init <project>`
  - `bootstrap.sh` — one-liner: `--git-init` + default `.gitignore` + first commit; `--bootstrap <project> [-m] [--with-remote --public/--private]`
  - `propose.sh` — `--propose` / `--proposals` (escape valve when no flag fits)
  - `log.sh` — leveled logging (logfile only, stderr only for warn/error)
  - `lock.sh` — flock + pause-flag helpers
  - `canary.sh` — Wave 1 compaction-canary gate; `--canary-init` / `--canary-verify` / `--canary-status` / `--canary-gate-check`; wraps `antcrate-core canary` C++ binary (AGENTS.md rule #15)
  - `loop.sh` — durable objective loop; `--loop` / `--loop-tick` / `--loop-signoff` / `--loop-status` / `--loop-list` / `--loop-resume` / `--loop-halt`; three hard stops (max-iter / no-progress / budget), two-key verify, composes with Claude Code `/loop`
  - `selfcheck.sh` — `--selfcheck [--quiet]` self-source persistence health (registry path, skill link, git, unpushed, dirty, backup age; exit 0/1/2); `selfsrc` line in `--status`; pairs with `systemd/antcrate-backup.timer`
  - `health.sh` — the `st` doctor (deliberately NO separate command — owner directive 2026-07-11: fewer commands, more info per command); `ac_health_checks` TAB rows (req/opt · ok/miss/skip · fix command) over PATH/wrapper/config/root/registry/timers/tools/gh/git-id; `ac_health_status_line` renders the `health:` section of `--status`; install.sh ends by running `antcrate st` so install delivers the first report
  - `cost.sh` — `--cost [--since][--session][--porcelain]` real-dollar spend from Claude Code session JSONL (per-model table + total; price table embedded, `ANTCRATE_COST_PRICES_FILE` override); backs the loop's `$`-budget mode (`--budget 5.00` = USD, integer = legacy seconds)
  - `intel.sh` — intel tracker; `intel pull [--quiet] [<id>]` / `intel ls [--json] [--kind <k>]` / `intel ack all|<id>[ <sha>]` / `intel st`; pinned Anthropic-ONLY seed (`sources.json`, non-Anthropic seed host = exit 2, all kind=dev) + HUMAN-ONLY extras `~/.config/antcrate/intel-sources.json` ({id,url,kind?}, https-only, dup ids refused, agents never write it), snapshot-on-hash-change + append-only `new.jsonl`/`acked.jsonl`; `intel: N unread · S sources · last pull <age>` line in `--status`; pairs with `systemd/antcrate-intel.timer` (retrieval); the cognition procedure is folded into the root SKILL.md "Intel review" section (proposals only, never edits — the separate intel skill retired 2026-07-10, recoverable on origin/attic). Spec: `docs/specs/2026-06-10-anthropic-intel-tracker-design.md`
  - `duties.sh` — human-only action checklist (`duties.md` at repo root); `--duty [--type policy|command|research|debug] "<text>"` append / `--duties` list open (typed tags) / `--duty-done <n>` user-driven close / `--duty-involvement` effective knob (lean|standard|hands-on; env > config > lean); `duties: N open (oldest <date>)` line in `--status`; reviewed in session-close part 3. Agents file duties, never close them.
  - `policy.sh` — model/tier/budget policy (`~/.antcrate/anycrate/policy.json`); `--policy` show / `--policy-init` idempotent seed; models cost table + classes (T0 orchestrator `inherit` / T1 opus heavy / T2 sonnet review / T3 haiku build / TH human) + per-model session budgets (Fable soft 250k / hard 400k). Only `budgets.fable` is agent-adjustable (evidence-backed, ledger-recorded); all else human-only or via `--propose`.
  - `fetch.sh` — `--fetch <url> [--name slug]` no-LLM web fetcher (intel normalizer reuse, append-only hash-keyed snapshots to `~/.antcrate/fetch/`); research order: TH duty → `--fetch` → model research LAST.
- **`hooks/claude/`** — Claude Code hooks (wired in `~/.claude/settings.json`):
  - `session-budget-guard.sh` — PreToolUse `*` context-window gate; model-aware budgets from policy.json (env override > `budgets.<model>` > `budgets.default` > builtin 100k/140k; Fable 250k/400k); soft warns (throttled per 10k growth), hard blocks all but the wrap-up whitelist (commit / pp / state-file edits / duties / git status-diff-log-add) until the USER runs `/clear`; fails open; `ANTCRATE_SESSION_SOFT/HARD` config overrides are human-only, agents MUST NOT set `ANTCRATE_SESSION_GATE_DISABLE`. Spec: `docs/specs/2026-06-10-session-budget-gate-and-duties-design.md`
  - `cost-anticipator.sh` — PreToolUse Skill|Agent|Read predictive gate: estimates token load (bytes/4 × tokenizer factor) BEFORE the call; warns past soft, BLOCKS past hard budget or model window, naming a cheaper path; reads only policy.json + transcript; fails open; agents MUST NOT set `ANTCRATE_COST_GUARD_DISABLE`. Spec: `docs/specs/2026-06-11-least-cost-allocation-and-skill-scoping-design.md`
  - `env-guard.sh` — PreToolUse Bash+Read secret-value guard: secret VALUES never enter the transcript (names/assignment only)
- **`core/`** — C++17 helper binary `antcrate-core` (CMake + doctest + nlohmann/json vendored). Wave 1 ships the canary subsystem; the Bash wrapper continues to be the user-facing CLI.
- **`templates/<domain>/`** — scaffolding templates per domain (`webapps`, `scripts`, `notes`, `projects`, `_generic`)
- **`tests/*.bats`** — bats coverage; run all via `antcrate --ci`
- **`install.sh`** — idempotent installer; copies binaries to `~/.local/bin`, libs to `~/.local/share/antcrate/`
- **`systemd/antcrated.service`** — optional user-mode daemon unit

### Docs (`assets/docs/`)

- **`PATTERNS.md`** — the orientation index (always read first)
- **`architecture.md`** — original blueprint (Core Objectives, Glossary, Schema, Registry, Triage, Sub-Branching)
- **`BUNDLE_SPEC.md`** (v1.0) — typed handshake between research-AntCrate (producer) and dev-AntCrate (consumer). Defines `manifest.json`, four `source.type` variants, `relationships`, status lifecycle, validate-before-write contract. Consumer-side `--ingest` is the next planned implementation pass.
- **`examples/bundles/`** — four reference bundles: `git-pinned/`, `theoretical/`, `composite/`, `supersedes/`
- **`HOOK_PLAN.md`** — git-hook surface roadmap. Shipped: `--hooks`, `--hook-log`, `--hook-install` / `--hook-remove` / `--hook-bypass` / `--hook-debug` / `--hook-autoinstall` / `--hook-smoke`, opt-in `.githooks/pre-commit`, `.github/workflows/ci.yml`.
- **`GH_PIPELINE_PLAN.md`** — running ledger of `gh` CLI usage being absorbed into antcrate flags. Every `gh` use logged here as a candidate. Proposed first pass: `--gh-info`, `--runs`, `--watch-run`, `--run-log`, `--issues`, `--issue-new`, `--prs`.
- **`DIAGRAM_PLAN.md`** — case-by-case diagram selection algorithm. Shipped: universal pair (`registry.mmd` + `tree.mmd`) auto-regenerated everywhere. Queued: stack-aware presets (`bash`, `node`, `svelte`, `python`, `rust`, `go`, `terraform`, `db`, `k8s`), `--diagram-preset`, `--diagram-detect`, auto-install on `--start`. Diagrams are first-class AntCrate output, not an external dependency.
- **`POST_DEV_BACKLOG.md`** — items deferred until GA: native-plugin gateway enforcement, per-tier antcrate (dev/infra/sec), bundle signing, backup encryption, `--pp` secret-guard fix.
- **`DIAGRAM_AUTOMATION_GUIDE.md`** — underlying tool catalog (Quick Picker, the seven core tools, source-of-truth-by-type sections). The reference that backs `DIAGRAM_PLAN.md`.
- **`LIB_MAP.md`** — this file.

### Hooks + CI (root of skill repo)

- **`.github/workflows/ci.yml`** — runs `antcrate --ci` on push to master/main + PRs
- **`.githooks/pre-commit`** — opt-in local hook (enable per-clone via `git config core.hooksPath .githooks`); runs `antcrate --ci`, tees output to `.git/antcrate-hook.log`

### State (`~/.antcrate/`)

- `registry.json` — single source of truth (jq-mutated, atomic temp-file replacement)
- `registry.mmd` — auto-regenerated Mermaid view of the whole registry (archived dimmed)
- `config` — user defaults (rule #13: human-only)
- `proposals.log` — `--propose` append-only log
- `anycrate/policy.json` — model/tier/budget policy (seeded by `--policy-init`)
- `fetch/<slug>/` — `--fetch` snapshots (append-only, hash-keyed)
- `backups/<project>/` — verified tar.gz snapshots
- `log/{wrapper,daemon}.log` — leveled logs
- `daemon.{pid,lock}` — single-instance + flock coord
- `pipe.paused` — pause flag (atomic sub-branching)
