# Runbook: CI failure

Use when the `Build and push image` workflow failed on either a `main` push
or a `vX.Y.Z` tag.

## Preconditions

- `gh` CLI authenticated against `sherodtaylor/agent-smith`, or the API token
  from `~/.config/gh/hosts.yml`.
- Read access to the workflow logs.

## Steps

### 1. Identify the failing job

```bash
gh run list --repo sherodtaylor/agent-smith --limit 5
gh run view <run-id> --repo sherodtaylor/agent-smith --log-failed
```

Two jobs run:

- **`build`** — fires on every push to `main` and every tag.
- **`chart`** — fires only on `v*.*.*` tags, depends on `build`.

### 2. `build` job failures

| Symptom | Cause | Fix |
|---|---|---|
| `failed to solve: process "/bin/sh -c …" did not complete successfully` during the `mcp-nats` Go build | upstream `sinadarbouy/mcp-nats` broke compatibility with the pinned Go version | Bump the `golang:1.X-bookworm` stage in `Dockerfile`, or pin the mcp-nats clone to a specific commit |
| `npm install -g @anthropic-ai/claude-code` fails | npm registry hiccup or a CLI version pulled and re-published | Re-run the workflow; if persistent, pin the CLI version in the Dockerfile |
| `unable to acquire registry: 403 Forbidden` | GHCR token scope drift | Confirm `permissions: packages: write` is still set in the workflow |
| `metadata-action` produces no tags | The semver tag isn't `vX.Y.Z` shaped | Re-tag correctly; delete the malformed tag |
| Buildx cache miss + multi-hour build | The `actions/cache` backing for `type=gha` was evicted | Annoying but transient — let it complete, the next build will be cached again |

Re-run from the GH UI or:

```bash
gh run rerun <run-id> --repo sherodtaylor/agent-smith
```

### 3. `chart` job failures (only on tags)

| Symptom | Cause | Fix |
|---|---|---|
| `helm lint` errors | A template references a value the chart's required-values check didn't catch | Fix the template or values; re-tag (see step 5) |
| `helm package` fails on `--version` | The tag isn't `vX.Y.Z` — `${GITHUB_REF_NAME#v}` produced something Helm rejects | Re-tag correctly |
| `helm push` 403 to `ghcr.io/sherodtaylor/charts` | GHCR token scope / package visibility | Confirm the chart's GHCR package allows the GH Actions token to publish |
| `action-gh-release` `fail_on_unmatched_files` | `helm package` step before it didn't actually emit a `.tgz` | Re-run; if persistent, check whether the `chart` job is running in the same checkout as `build` |

### 4. Image published but chart job failed (partial release)

This is the worst state: consumers may pull the new `:vX.Y.Z` image but the
chart at `oci://ghcr.io/sherodtaylor/charts/agent-smith:X.Y.Z` doesn't exist.

Fix forward:

```bash
gh run rerun <chart-run-id> --repo sherodtaylor/agent-smith
```

If the chart job has a real bug (helm lint failure, value drift), fix it in
a follow-up PR, merge to `main`, then publish a `vX.Y.Z+1` tag — do **not**
re-tag the same version (Helm OCI artifacts at a given version are
immutable; a re-tag will fail to push).

### 5. Re-tagging a release that never got published

```bash
# Delete the broken tag locally and remotely
git tag -d vX.Y.Z
git push --delete origin vX.Y.Z

# Re-tag once the fix is on main
git tag -a vX.Y.Z -m "vX.Y.Z — …"
git push origin vX.Y.Z
```

**Only do this when no consumer has pulled the broken `:vX.Y.Z` yet.** The
image at that tag is mutable until something pulls it; the chart artifact at
that version is immutable from the first successful publish.

## Verify

```bash
gh run list --repo sherodtaylor/agent-smith --limit 1
# Most recent run: status=completed, conclusion=success

docker pull ghcr.io/sherodtaylor/agent-smith:vX.Y.Z
helm pull   oci://ghcr.io/sherodtaylor/charts/agent-smith --version X.Y.Z
```

Both pulls succeed and the SHA returned by `docker inspect` matches what CI
logged.

## Rollback

Within a release: re-run the failed job; failing that, publish the next
patch.

For a fully broken release that's already in production: pin consumers to
`vX.Y.Z-1` (see [`release.md`](release.md) §Rollback).

## Why this works

The two jobs are intentionally split (`chart` depends on `build`) so that an
image failure short-circuits the whole release — you can't accidentally
publish a chart that points at a missing image. The opposite case (image
published, chart job failed) is the harder one to recover from, which is why
it's the one to re-run aggressively before rolling forward.
