# Security Policy

## Supported versions

AntCrate is pre-1.0. Only HEAD of the `master` branch is supported. No backports to older commits or tags.

## Reporting a vulnerability

Do NOT open a public GitHub issue for security reports. Use GitHub's private vulnerability reporting feature instead: on the repository page, go to **Security → Report a vulnerability**. This keeps the report confidential until a fix is ready.

## Attack surface

AntCrate's non-trivial exposure points:

- **`git push` wrapper** — captures stderr from `git push`, generates diffs, and sends truncated output via `mailx`/`sendmail` on rejection. A crafted remote response or local hook could influence what gets emailed.
- **Repo-local hook execution** — `--ci`, `--hook-debug`, and the opt-in pre-commit path execute scripts under `.githooks/` without additional sandboxing.
- **`inotifywait` daemon** — `antcrated` watches filesystem paths and translates create/write events on specially-named files into CLI invocations. Filename crafting in a watched directory is equivalent to issuing a CLI command.
- **`jq`-managed registry** — `~/.antcrate/registry.json` is read and mutated via atomic temp-file replacement. Corruption or injection of this file affects all registered projects.

None of these run with elevated privileges. All operations are scoped to the invoking user's environment.

## What is NOT a security issue

Feature requests, hook template suggestions, and documentation gaps are regular issues — file them on the public tracker.
