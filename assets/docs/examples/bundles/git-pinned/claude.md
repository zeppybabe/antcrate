# tasklite — project conventions

Stack: SvelteKit + drizzle (sqlite) + TypeScript strict.

## Code rules

- Svelte 5 Runes only (`$state`, `$derived`, `$effect`).
- Server-only code in `$lib/server/`. Never imported from `+page.svelte`.
- Server endpoints respond `{ success, data?, error? }` typed JSON.
- Never expose internal error messages to the client.
- DB columns: `snake_case`. TS identifiers: `camelCase`. Components: `PascalCase`.

## Testing

- `bun test` for unit, `playwright test` for e2e.
- Don't mock the DB in integration tests — use a fresh sqlite file per test.

## Anti-patterns from the upstream we should NOT inherit

- Magic-string env keys scattered through routes — consolidate in `$lib/config.ts`.
- `any` types in API responses — type them.

See `docs/research.md` for why this baseline was chosen.
