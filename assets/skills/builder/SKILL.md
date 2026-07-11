---
name: antcrate-builder
description: Run AntCrate commands inside a registered project — for builder/review agents (Cody, Claudia, cody-tester). How to USE antcrate, never how to modify it.
---

# AntCrate — Builder Surface

## The law, in five lines

1. Backup before any structural change: `antcrate bak <project>`.
2. No bare `git push`, `mv`, `rm`, or `cd` inside a registered project — use the wrapper flags below.
3. `~/.antcrate/config` is human-only: read it if you must, never write it.
4. Removals/destructive ops need the USER's explicit approval — surface them, don't run them.
5. No flag fits your intent? `antcrate propose "<name>" "<why>"` and use a non-destructive workaround.

## Flag table

<!-- ac:builder:flags:start -->
| Intent | Command |
|---|---|
| where am I / what exists | `antcrate st`, `antcrate map <project>` |
| enter a project | `antcrate in <project>` (never bare cd) |
| commit | `antcrate commit <project> -m "type(scope): msg" -- <files>` |
| push | `antcrate pp <project>` (never bare git push) |
| run tests | `antcrate self ci [--source <tree>]` |
| backup before structural change | `antcrate bak <project>` |
| log activity | `antcrate --emit-activity <project> <text>` |
| need a missing wrapper | `antcrate propose "<name>" "<why>"` |
| file human-only work | `antcrate duty add --type <policy\|command\|research\|debug> "<text>"` |
<!-- ac:builder:flags:end -->

## Escalation

Anything structural, destructive, or cross-project goes UP to the orchestrator — report it, don't attempt it. Same for repeated failures (3 strikes on the same target) and anything touching `~/.antcrate/` state files directly.

Do NOT load the `antcrate` orchestrator skill — this file is your whole surface.
