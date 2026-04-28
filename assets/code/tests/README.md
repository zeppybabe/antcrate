# AntCrate Tests

Run with [bats-core](https://github.com/bats-core/bats-core):

```bash
sudo apt install bats   # or: brew install bats-core
bats assets/code/tests/
```

## Files

- `schema.bats` — positional decoder: csv-meta, kv-meta, swap/backup rejection, embedded periods.
- `registry.bats` — atomic jq CRUD: upsert, has, get, link bidirectionality, delete with back-link pruning.
- `git_triage.bats` — push wrapper with mocked `git` and `mailx`: success path, rejection → `/tmp/antcrate_conflict.log` + dispatch, 300-line truncation, missing-email graceful skip.
- `scaffold.bats` — end-to-end: `start` creates dir + registry entry, html/css/js stubs honored, idempotency, `subbranch` atomicity (incl. pipe resume on failure), `branch from=<base>` copy+link.

## Coverage gaps (need real hardware)

- Daemon `inotifywait` debounce timing across editors (nano/helix/vim/neovim/micro).
- Real `git push` against a remote with diverged history.
- Real `mailx` MTA dispatch.
- Systemd user-unit lifecycle.

These are deferred to the post-GitHub audit phase.
