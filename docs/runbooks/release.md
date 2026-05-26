# Runbook: Cut a release

Use when you're shipping a new version of the image **and** chart. A
maintenance branch / hotfix follows the same flow with a patch bump.

## Reference scripts

Scripts in [`.claude/references/`](../../.claude/references/README.md) cover
the repeatable steps:

```bash
.claude/references/compare-since-tag.sh           # step 1
.claude/references/cut-release.sh --help          # step 3
.claude/references/check-release.sh --help        # step 5
.claude/references/bump-homelab-chart.sh --help   # step 6
```

## Preconditions

- All PRs intended for this release are merged into `main`.
- Local `main` is up-to-date, or you're working via the GitHub API.
- `CHANGELOG.md` has an `[Unreleased]` section listing the changes (or you'll
  populate one in step 2).
- `GH_TOKEN` set in env or `~/.config/gh/hosts.yml` present (reference scripts
  resolve it automatically).

## Steps

### 1. Pick the version

Semver. Read the merged PRs since the last tag and pick:

- **Patch** (`vX.Y.Z+1`) — bug fix, doc, internal refactor, no behaviour
  change for consumers.
- **Minor** (`vX.Y+1.0`) — new feature, new Helm value, anything additive.
- **Major** (`vX+1.0.0`) — breaking change to values, env vars, or expected
  cluster shape.

```bash
.claude/references/compare-since-tag.sh
```

### 2. Update CHANGELOG.md

Move everything under `[Unreleased]` into a new `[X.Y.Z] - YYYY-MM-DD`
section. Keep `[Unreleased]` as an empty stub. Commit on `main` (or via PR)
**before** tagging — the GitHub Release body is copied from this section.

### 3. Tag and create the GitHub Release

```bash
.claude/references/cut-release.sh --version vX.Y.Z --message "one-line summary" --dry-run
# Review dry-run output, then:
.claude/references/cut-release.sh --version vX.Y.Z --message "one-line summary"
```

The script creates the annotated tag and GitHub Release in one shot. CI picks
up the tag and publishes the image + chart automatically.

### 5. Wait for CI and verify artifacts

```bash
gh run watch --repo sherodtaylor/agent-smith   # or watch GitHub Actions in browser
.claude/references/check-release.sh --version X.Y.Z
```

`check-release.sh` verifies all four artifacts: git tag, GitHub Release,
container image, and Helm chart OCI artifact.

### 6. Bump the consuming HelmReleases

```bash
.claude/references/bump-homelab-chart.sh --version X.Y.Z --dry-run
# Review, then:
.claude/references/bump-homelab-chart.sh --version X.Y.Z
```

Updates every `*-helmrelease.yaml` that references `chart: agent-smith` in
`sherodtaylor/homelab/k8s/apps/agents/` via the GitHub API. Flux reconciles
on the next poll.

### 7. Verify in the cluster

```bash
flux reconcile helmrelease devbot   -n agents
flux reconcile helmrelease infrabot -n agents

kubectl get helmrelease -n agents
kubectl get pods -n agents -w
```

Both pods should roll, come up Ready, and post the next acknowledged 👀
reaction in Matrix on the next message you send them. Test with a tag in
`#dev`:

```
@devbot @infrabot ping — confirming you're on vX.Y.Z
```

## Rollback

If something is wrong post-tag:

- **Image is broken but `:latest` already moved.** Pin the consumers to the
  previous specific version (`vX.Y.Z-1`) by bumping the HelmReleases to that.
  `:latest` itself can't be unmoved without re-tagging.
- **Chart is broken but image is fine.** Re-pin consumers to the previous
  chart version; the image they already have stays good.
- **Both broken.** Pin consumers to `vX.Y.Z-1` for both, then publish a
  `vX.Y.Z+1` with the fix.

`git tag -d vX.Y.Z` + `git push --delete origin vX.Y.Z` is **possible** but
discouraged — published Helm OCI artifacts at that version are immutable, and
having the tag removed leaves an orphaned chart.

## Verify the release end-to-end

```bash
.claude/references/check-release.sh --version X.Y.Z
kubectl get helmrelease -n agents -o jsonpath='{range .items[*]}{.metadata.name}={.spec.chart.spec.version}{"\n"}{end}'
```

All should report `X.Y.Z`. If one disagrees, that's the layer to fix.

## Why this works

Tags are the **only** trigger for the chart job (see `.github/workflows/docker.yml`,
`if: startsWith(github.ref, 'refs/tags/v')`). Pushes to `main` never publish
a chart and never move `:latest`. The chart version is derived from the tag
name (`GITHUB_REF_NAME#v`), so the chart and image are always at the same
version — you can't release one without the other.
