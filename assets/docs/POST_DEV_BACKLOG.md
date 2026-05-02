# AntCrate — Post-Development Backlog

Items deferred until antcrate as a whole reaches GA. AntCrate is theoretically never "done" (urban-dictionary sense — evergreen), but a baseline GA cut exists where the Gateway Law (rule #12) and the no-deletion-without-approval baseline (rule #1) are *enforced* rather than *requested*. Items below tighten enforcement, harden surfaces, and extend scope beyond a single workstation.

During active development, agents act rapidly. The hard line that stays in force: **no deletion of anything without explicit human approval.** Everything else here is post-baseline.

---

## Hardening: gateway enforcement beyond policy

- **Native (C/C++) plugin layer** — so an AI agent literally cannot bypass `ac_safety_guard_destructive` or the Gateway Law verify chain. Today's enforcement is bash + cooperative; native enforcement would intercept syscalls / wrap dangerous binaries.
- **Runtime enforcement of AGENTS.md rule #13** (`~/.antcrate/config` is human-only). Currently policy — agent-side discipline. Add: integrity hash recorded at last-known-good state, surface alert if config mtime/hash changes between wrapper invocations without a corresponding ledger entry.
- **Config file modification audit log** — every change to `~/.antcrate/config` (timestamp, hash before/after, user) appended to `~/.antcrate/config.audit.log`. Tampering with the audit log itself is detectable via append-only chain hash.
- **Bypass flag scope-narrowing** — current `ANTCRATE_*_PREAPPROVED` flags are global. Replace with per-project / per-action / time-bounded grants (e.g., `ANTCRATE_GRANT="remove:ac-livetest:30s"`).

## Per-tier deployment

- **Dedicated antcrate per security / development / infrastructure tier.** Servers run an antcrate scoped to one tier; cross-tier operations require a documented bridge (signed bundle, audit-logged transfer). Today's model is one antcrate per workstation; the multi-tier model formalizes the dev/infra/sec separation the user has flagged as architectural intent.
- **Tier-specific AGENTS.md overlays** — security tier gets stricter rules (no internet egress, no bypass flags at all, all destructive ops require two-person approval). Dev tier matches today's behavior. Infra tier in between.
- **Cross-tier bundle handshake** — extends BUNDLE_SPEC with tier metadata. A dev-tier producer cannot write a security-tier bundle without an explicit cross-tier endorsement step.

## Universal-removal coverage

Rule #12 names these in policy but the wrapper does not yet cover them:
- **Branch deletion** (`git branch -D`, remote branch removal) — should require Gateway Law verify chain.
- **GitHub issues/PRs** (`gh issue delete`, `gh pr close --delete-branch`) — same.
- **Database table drops** — out of antcrate's current scope, but the Gateway Law applies wherever antcrate is the orchestration shell. Future `--db-drop` wrapper or refusal-by-default integration with project-local db tools.
- **Container/VM destruction** — `docker rm`, `kubectl delete`, `terraform destroy` — tier-dependent (infra tier mainly).

## Bundle pipeline (BUNDLE_SPEC v1.1+)

- **Bundle signing** — `signature` field for cross-trust-boundary scenarios (research machine → dev machine over public network). GPG or sigstore-style.
- **Campaign manifests** ("bundle bundles") — group multiple bundles for atomic ingest. Punted from v1.0 pending one round of real-world ingest experience.
- **Live source tracking** (`source.tracking: "head"`) — for upstreams evolving faster than research can re-bundle. Trades reproducibility for currency.
- **Multi-consumer queue** — `queue.json` semantics for >1 dev machine pulling from the same `research-bundles` repo (currently designed for 1:1).

## Backup hardening

- **Backup encryption** — current backups are plaintext `tar.gz`. Projects on disk often contain `.env*` (gitignored but present locally), so backups capture them. Opt-in `gpg` encryption for `~/.antcrate/backups/`.
- **Off-machine backup target** — push backups to user-controlled remote storage (S3, B2, Storj) on a schedule. Lost-laptop scenario coverage.

## Schema robustness

- **Domain allowlist** — current model accepts any `<domain>` value, creating a directory if it doesn't exist. Typos like `webaps` vs `webapps` silently bifurcate. Optional allowlist in `~/.antcrate/config`.
- **Editor swap-file rules** — current filter covers `nano`, `helix`, `vim` (`4913` probe). Confirm against `kakoune`, `micro`, `neovim` (different swap-file conventions).
- **`mailx` vs `sendmail` runtime detection** — current order works on most distros, but minimal containers (alpine, distroless) may have neither. Detect at install time, surface a clear setup hint.

## Wrapper consistency / rule-#11 internal compliance

- **`cmd_pp` bypasses the secret-pattern guard.** `bin/antcrate:cmd_pp` does bare `git add -A; git commit -qm "antcrate: auto-commit ..."` before delegating to `ac_git_push`. That misses the secret-pattern guard newly built into `lib/commit.sh::ac_commit_run`. Refactor `--pp` to delegate the commit step through `ac_commit_run` (mode `all`) so push-and-pipe shares the same secret-blocking gate as `--commit`. AGENTS.md rule #11 ("no bare command on a registered project when a wrapper exists") effectively requires this once `--commit` is the wrapper for staging.
- **`install.sh` writes to `~/.antcrate/config`.** `install.sh` lines 38–42 use `printf '%s\n' >> "$CONFIG"` and `sed -i` to set `ANTCRATE_SELFSRC=`. AGENTS.md rule #13 makes `~/.antcrate/config` human-only territory. The installer is human-initiated, so the *intent* of rule #13 isn't violated — but the *literal* action conflicts with the rule's wording, and an agent reading the rule in isolation could be confused. Resolve by writing `ANTCRATE_SELFSRC` to a sibling file (e.g., `~/.antcrate/install.env`) that the wrapper sources separately, leaving `~/.antcrate/config` exclusively under human control even during install.

## Wrapper coverage gaps

- **`--commit` flag itself** — *currently being implemented (2026-05-01); promote to default-on once stable.*
- **`--diff <project>`** — exists; consider adding `--diff <project> --since <ref>` for verify-chain integration.
- **`--rollback <project> <commit>` / `--undo-last`** — branch protection for the dev tier; never auto-runs, always Gateway-Law-gated.
- **`--rotate-secrets <project>`** — paired with secret-pattern guard from `lib/commit.sh`. Helps users move secrets out of the staged set into vaulted storage.

## Observability

- **Action provenance log** — every wrapper invocation logged with: agent ID (Claude / human / scripted), action, target, args, exit. Currently fragmented across `wrapper.log`, `daemon.log`, ledger.
- **Per-project audit timeline** — `antcrate --audit <project>` reconstructs the full lifecycle from logs + git history + registry mutations.

---

## Maintenance of this file

Append, don't reorganize, while in active dev. After GA cut: triage into milestones (e.g., v1.1, v1.2). Items can graduate to a tracked issue/PR before that, but don't have to.
