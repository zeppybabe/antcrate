# Contributing

## Orientation

Before opening an issue or PR, skim [`assets/code/AGENTS.md`](assets/code/AGENTS.md) for the hard rules governing structural and destructive operations, and [`assets/docs/PATTERNS.md`](assets/docs/PATTERNS.md) for the full flag index. (Maintainers keep live project state and the append-only decision log in a local `dev/` tree that is not published.)

## Test gate

Every PR must keep `antcrate --ci` green: shellcheck clean, full bats suite passing, and cmake/ctest passing for the C++ core. New functions added to `lib/*.sh` require a companion test file at `tests/<name>.bats`. Adding a flag without tests will not be merged.

## Commit style

Use `type(scope): description` with types `feat`, `fix`, `refactor`, `style`, `docs`, `test`, or `chore`. One logical change per commit. Use `antcrate --commit <project> -m "..."` rather than bare `git commit` — the wrapper applies the secret-pattern guard and enforces the commit message format.

## New flag proposals

File proposals via `antcrate --propose "<flag-name>" "<rationale>"`. Proposals are reviewed with `antcrate --proposals` before implementation begins. Do not start implementation before a proposal is on record.

## Solo-maintained, pre-1.0

Expect review latency. Issues are triaged first; PRs are reviewed against the `state.md` Top of mind alignment. New contributors should read `state.md` and [`assets/code/README.md`](assets/code/README.md) to understand what work is currently in-flight before proposing changes that touch the same surface.
