---
name: tasklite
description: Per-project context for the tasklite task tracker. Loads alongside the antcrate skill so an agent has both orchestration commands and project-specific knowledge.
---

# tasklite — Claude skill

Stack: SvelteKit, drizzle (sqlite), TypeScript strict, vitest.

## When to invoke

Whenever the user is working in `~/projects/webapps/tasklite/` or refers to
"tasklite", "the task tracker", "the personal todo app".

## Key files

- `src/routes/+layout.svelte` — top-level shell
- `src/routes/api/tasks/+server.ts` — task CRUD
- `src/lib/server/db.ts` — drizzle init + connection
- `src/lib/config.ts` — env handling (consolidated here, not scattered)

## Common operations

- New endpoint: scaffold under `src/routes/api/<resource>/`, return typed
  `{ success, data?, error? }`.
- New table: drizzle schema in `src/lib/server/schema.ts`, then `bun run
  db:push` (which calls `drizzle-kit push` with the right env).
- Run tests: `antcrate --in tasklite -- bun test`.

## See also

- `docs/research.md` — why we chose this upstream
- `docs/CLAUDE.md` — code conventions
- `context/upstream-quirks.md` — drizzle-kit + sqlite gotchas
