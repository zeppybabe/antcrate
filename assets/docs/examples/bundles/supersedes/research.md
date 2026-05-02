# tasklite (v2) — supersedes

## Why a new bundle

Original tasklite bundle was ingested 2026-04-28 against
`example-owner/tasklite`. As of 2026-05-10:

- Upstream has had zero commits in 14 days
- Two PRs sitting unreviewed since April
- Active maintainer transferred ownership of the org

A community fork (`active-fork-owner/tasklite-fork`) has been healthy:
- 47 commits in the last week
- Telegram notifier already wired (we were about to build this by hand)
- Drizzle 0.30 upgrade already done (we had this on our list)

## What changes for the dev side

- Source repo URL changes — clean re-clone
- Upstream rebases policy: fork DOES NOT rebase, so future updates will be
  trackable via normal merges
- Two of our planned hand-modifications are no longer needed (Telegram, drizzle)

## Continuity

The per-project skill (`~/.claude/skills/tasklite/`) carries forward — same
domain knowledge, just pointed at a healthier source. The existing project's
work-in-progress changes (if any) need to be preserved by backup before the
overwrite. This is exactly what AGENTS.md rule #1 + the `supersedes`
relationship are for.

## Dev-side checklist

1. Backup current `~/projects/webapps/tasklite/` tree (auto, via rule #1).
2. Backup current `~/.claude/skills/tasklite/` (manual flag may be needed).
3. Re-clone from the fork.
4. Restore any in-progress work by hand-merging from the backup tarball.
5. Re-run `bun install`, `bun run db:push`, smoke test.
