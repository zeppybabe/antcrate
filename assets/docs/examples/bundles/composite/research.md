# antframe — composite research

## What we're assembling

A SvelteKit admin app with credentialed auth out of the box. Neither upstream
has the full thing — but they're complementary:

- `auth-starter` has lucia-based session auth, login/register/logout flows,
  and the right TypeScript hygiene. No admin UI to speak of.
- `svelte-admin` has a polished admin panel (CRUD pages, table components,
  a sidebar layout) but no auth — assumes the user is already authed.

Glueing them gives us the shape we want without writing either piece from
scratch.

## Merge plan

See `attachments/merge-plan.md` for the per-path conflict resolution. Summary:

| Path | Source | Reason |
|---|---|---|
| `src/lib/server/auth/**` | auth-starter | the entire reason this source is included |
| `src/routes/admin/**` | svelte-admin | the entire reason this source is included |
| `src/routes/+layout.svelte` | auth-starter, with admin sidebar grafted in | needs hand-merge — flagged for the dev agent |
| `src/app.html` | auth-starter | identical between sources, picking first |
| `package.json` | merged (union of deps) | hand-merge required, flagged |
| `tsconfig.json` | auth-starter | strict mode is non-negotiable |

## Hand-merge tasks for the dev side

1. Resolve `+layout.svelte` — keep auth-starter's auth guard, graft in
   svelte-admin's sidebar component conditionally for `/admin/**` routes.
2. Resolve `package.json` — union the dependencies, prefer newer versions.
3. Add a smoke test that logs in and reaches the admin panel.

Estimated dev effort: 4–8 hours.
