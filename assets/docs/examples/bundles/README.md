# Example bundles

Reference bundles demonstrating the v1.0 spec (`../BUNDLE_SPEC.md`). Each
directory is a complete, valid bundle — `manifest.json` parses, required
fields are populated, the file layout matches §1 of the spec.

Use these as templates when bringing up a research producer or testing the
dev-side `--ingest` flow.

| Bundle | source.type | Demonstrates |
|---|---|---|
| `git-pinned/` | `git` (commit-pinned) | Standard case. Full bundle: manifest + research + claude.md + skill + diagram seed. |
| `theoretical/` | `none` | Research-only — no baseline code. Bundle ships the literature review and rationale; dev side starts from an empty scaffold. |
| `composite/` | `composite` | Multi-source merge. Two upstreams combined into one project with documented conflict resolution. |
| `supersedes/` | `git` | Replaces an earlier bundle's project (`tasklite` → forked baseline). Demonstrates `relationships` + AGENTS.md rule #1 interaction. |

The example URLs and commit SHAs are fabricated — they exist to show the
shape of a real manifest, not to be ingested verbatim.

## Quick sanity-check

```bash
# Validate every manifest in this dir
for m in */manifest.json; do
  printf '%-20s ' "$m"
  jq -e '.spec_version, .name, .domain, .objective, .generated_at, .source.type' "$m" >/dev/null \
    && echo "OK" || echo "FAIL"
done
```
