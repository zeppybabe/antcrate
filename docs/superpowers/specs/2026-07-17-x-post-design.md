# Design: `antcrate post` — X update publishing (v1)

**Date:** 2026-07-17
**Status:** Approved design, pending implementation plan
**Scope:** X (Twitter) only; other platforms are explicit non-goals for v1.

## Problem

After shipping work (`antcrate pp <project>`), the maintainer wants to announce the
update on X — from one or more accounts — without:

- scripting the X website (explicitly prohibited by X's automation rules; documented
  permanent-suspension trigger, enforcement tightened in 2026),
- requiring an X developer app or pay-per-use API billing in v1,
- exposing secrets or repo internals in the announcement,
- adding credentials or tokens anywhere in AntCrate.

## Decision summary (2026-07-17)

| Fork | Decision |
|---|---|
| Delivery | **Web-intent handoff** (`x.com/intent/post?text=…`): CLI pre-fills the compose box; the human click on Post is the publish gate. ToS-compliant, free, credential-less. |
| Trigger | **On-demand command** — no `pp` hook; several pushes may roll into one post. |
| Composer | **AI words it, CLI delivers** — CLI emits secret-filtered material; the AI session (orchestrator) writes the tweet and hands it back via `--open`. Deterministic template as no-AI fallback. |
| Accounts | **Profile map in human-only config** — account handle → Firefox profile; per-project default handle; `--as` overrides. |

Rejected alternatives: browser scripting (ToS violation, brittle, reputational risk to
the tool); official X API pay-per-use (~$0.015/post, $0.20 with link — viable, deferred
to v2 as opt-in `--send`); MCP servers (the official X MCP server, live since
2026-06-30, cannot post from its hosted endpoint — writes need a local `xurl mcp`
bridge + developer app + pay-per-use billing; community MCP servers either need API
credentials or scrape). MCP/API is the natural v2 `--send` backend.

## Command surface

Words-only, per CLI convention. `x` is a platform slot for later expansion.

### `antcrate post x <project>` — material mode

1. Resolve `<project>` via the registry; fail with the usual unknown-project message.
2. Read the update log (below) for the last posted commit; range is
   `<last>..HEAD` of the project's default branch (first post: last N=10 commits).
3. Emit a `MATERIAL` block: commit subjects + bodies in range, project repo URL from
   registry metadata — everything piped through a content secret guard. Guard hits
   are redacted, never printed. *(As-built note, 2026-07-17: the existing `--commit`
   guard is filename-based and inapplicable to commit-message content, so `post`
   ships its own content-shape guard — `AC_POST_SECRET_ERE` in `lib/post.sh`. The
   two guards are independent surfaces; keep both in mind when adding patterns.)*
4. Emit a `DRAFT` block: mechanical fallback template
   (`<project> update: <subject-1>; <subject-2> … <repo-url>`), truncated to fit.
5. Exit codes: `0` material available · `3` nothing new since last post ·
   nonzero registry/config errors as per house convention.

### `antcrate post x <project> --open "<text>"` — delivery mode

1. Run the secret-pattern guard on `<text>`; refuse on any hit.
2. Enforce X length: ≤ 280 chars, any URL counted as 23 (t.co wrapping). Reject with
   the computed count on overflow.
3. Resolve account: `--as <handle>` if given, else the project's default handle from
   config; error (with a sample config) if unresolvable.
4. URL-encode and launch:
   `$ANTCRATE_BROWSER_CMD -P <profile> --new-tab "https://x.com/intent/post?text=<enc>"`
   (`ANTCRATE_BROWSER_CMD` defaults to `firefox`; env override doubles as test seam).
   If the browser binary is missing, print the intent URL for manual opening.
5. Append an update-log entry and advance the range pointer (see below).
6. Never interacts with the opened page. The human clicks Post. This is the approval
   gate — same shape as Gateway Rule #1's backup-and-approval gate for destructive ops.

### `antcrate post x log <project>` — audit view

Pretty-prints the update log, newest first.

## Update log

`~/.local/state/antcrate/posts/<project>.log` — append-only, one record per `--open`:

```
2026-07-17T21:04:11Z  @handle  abc1234..def5678  opened  "rfm-music update: …"
```

- Written at `--open` time; the CLI cannot observe the browser click, so `opened` is
  the terminal v1 status. (A `confirm`/`skip` status flip is a v2 nicety.)
- Advancing the pointer at `--open` means an abandoned compose tab skips those
  commits; acceptable for v1 — rerunning material mode with `--from <sha>` (v2) or
  hand-editing is the escape hatch. Documented in MANUAL.
- Contents derive only from git state and pass the secret guard: safe by construction,
  the "update log that doesn't expose secrets or internals" requirement.

## Account config

`~/.config/antcrate/x-accounts.json` — **human-only** (Rule #13 pattern: agents read,
never write; suggest changes via `antcrate propose` or a duty).

```json
{
  "accounts": { "@antcrate": { "profile": "x-antcrate" } },
  "projects": { "antcrate": "@antcrate" }
}
```

Multi-account = one Firefox profile per X account, each logged in once, manually, by
the human. The intent URL posts as whoever the profile is logged in as.

## AI workflow (the "AI connects via the CLI" contract)

```
orchestrator:  antcrate post x rfm-music          # material
orchestrator:  <words the tweet from MATERIAL>
orchestrator:  antcrate post x rfm-music --open "Shipped: …"
human:         clicks Post in the pre-filled tab
```

Two plain commands; no MCP server, no tokens, nothing resident.

## Error handling

- Missing/invalid config → print a sample `x-accounts.json` to copy.
- Unknown project → registry lookup failure message.
- Empty range → "nothing to post since <sha> (<date>)", exit 3.
- Over-length text → rejected with computed count.
- Browser missing → print intent URL.

## Testing (`antcrate self ci`)

- Range computation incl. first-post and empty-range cases (fixture repo).
- URL encoding of quotes, newlines, emoji, `#`/`&`.
- Length rule: URL-counts-as-23 boundary cases.
- Secret-guard filtering on material and on `--open` text.
- Config resolution: default handle, `--as` override, missing config.
- Delivery via `ANTCRATE_BROWSER_CMD=echo`-style double asserting the exact URL —
  no real browser in CI.

## Non-goals (v1)

API/MCP `--send` backend · `pp` auto-draft hooks · threads, media, polls ·
platforms other than X · post scheduling · engagement metrics.

## As-built amendment (2026-07-18): drafts-folder delivery replaces web-intent

Owner decision 2026-07-18: the web-intent browser delivery (`--open`, Firefox
profiles, `x-accounts.json`) was **retired** the day after shipping, in favor of
a simpler delivery with the same safety shape: `post x <project> --draft "<text>"`
prepends the guarded, length-checked post to the project's **git-ignored
`X-POSTS.md`** (newest first), and the human copies it into X — the paste is the
publish gate. Same guard, same 280/URL=23 rule, same update log (status
`drafted`, handle `-`; field order unchanged — antcrate-mcp parses it). Account
config and browser plumbing deleted; multi-account is now free (paste from any
logged-in account). The API/MCP `--send` backend remains the designated v2 slot.
