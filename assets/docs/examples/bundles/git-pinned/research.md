# tasklite — research notes

## Why this bundle

Looked for a task tracker that's:
- Single binary (no docker-compose, no multi-service)
- File-based persistence (sqlite ok, postgres not)
- Has a usable web UI but isn't React-heavy
- MIT or BSD licensed

`example-owner/tasklite` was the closest match across ~14 candidates evaluated.
Notes on the four runner-ups and why they were rejected are in
`attachments/candidates.md`.

## What's in the upstream baseline

- SvelteKit app, drizzle for sqlite ORM
- Server endpoints under `src/routes/api/`
- Auth: session cookies, no third-party
- Tests: vitest, ~60% coverage

## What we're adapting

- Replace the homepage with our own branding (trivial)
- Add `--export json` and `--export markdown` to the CLI shim
- Wire optional Telegram notifier (we have a bot already)
- Drop the demo-data seed script

## Gotchas the research hit

- The upstream maintainer rebases `main` aggressively — pin to the commit in
  `manifest.json`, do not track HEAD.
- `drizzle-kit push` requires `DATABASE_URL` set even for sqlite; example .env
  provided in `attachments/`.
- The build expects Node 20+; CI uses 22.

## Pre-existing diagrams

`docs/diagrams/architecture.mmd` in the upstream is sound — we ship the seed
that mirrors it so auto-regen has a starting point.
