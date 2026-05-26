# Runbook: Cut a release

Use when you're shipping a new version of the image **and** chart. A
maintenance branch / hotfix follows the same flow with a patch bump.

## Preconditions

- All PRs intended for this release are merged into `main`.
- Local `main` is up-to-date, or you're working via the GitHub API.
- `CHANGELOG.md` has an `[Unreleased]` section listing the changes (or you'll
  populate one in step 2).

## Steps

### 1. Pick the version

Semver. Read the merged PRs since the last tag and pick:

- **Patch** (`vX.Y.Z+1`) — bug fix, doc, internal refactor, no behaviour
  change for consumers.
- **Minor** (`vX.Y+1.0`) — new feature, new Helm value, anything additive.
- **Major** (`vX+1.0.0`) — breaking change to values, env vars, or expected
  cluster shape.

```bash
# What's merged since the last tag?
git fetch --tags
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```

If you're working via the GitHub API:

```bash
GH_TOKEN=…  # from ~/.config/gh/hosts.yml
LAST=v0.1.X
curl -sH "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/sherodtaylor/agent-smith/compare/$LAST...main" \
  | jq -r '.commits[] | "\(.sha[0:8]) \(.commit.message | split("\n")[0])"'
```

### 2. Update CHANGELOG.md

Move everything under `[Unreleased]` into a new `[X.Y.Z] - YYYY-MM-DD`
section. Keep `[Unreleased]` as an empty stub. Commit on `main` (or via PR)
**before** tagging — the GitHub Release body is copied from this section.

### 3. Tag and push

```bash
git tag -a vX.Y.Z -m "vX.Y.Z — <one-line summary>"
git push origin vX.Y.Z
```

Via API (if you can't push locally):

```bash
MAIN_SHA=$(curl -sH "Authorization: token $GH_TOKEN" \
  https://api.github.com/repos/sherodtaylor/agent-smith/git/refs/heads/main \
  | jq -r .object.sha)

TAG_SHA=$(curl -sH "Authorization: token $GH_TOKEN" \
  -d "{\"tag\":\"vX.Y.Z\",\"message\":\"vX.Y.Z — …\",\"object\":\"$MAIN_SHA\",\"type\":\"commit\",\"tagger\":{\"name\":\"sherodtaylor\",\"email\":\"sherodtaylor@gmail.com\",\"date\":\"$(date -u +%FT%TZ)\"}}" \
  https://api.github.com/repos/sherodtaylor/agent-smith/git/tags | jq -r .sha)

curl -sH "Authorization: token $GH_TOKEN" \
  -d "{\"ref\":\"refs/tags/vX.Y.Z\",\"sha\":\"$TAG_SHA\"}" \
  https://api.github.com/repos/sherodtaylor/agent-smith/git/refs
```

### 4. Create the GitHub Release

Body = the new CHANGELOG section, verbatim. The `chart` job in `docker.yml`
attaches the chart `.tgz` automatically — don't upload it manually.

```bash
gh release create vX.Y.Z \
  --title "vX.Y.Z" \
  --notes-file <(awk '/^## \[X.Y.Z\]/,/^## \[/' CHANGELOG.md | sed '$d')
```

### 5. Wait for CI

```bash
gh run watch --repo sherodtaylor/agent-smith
```

You're looking for both jobs to succeed:

- **`build`** — published `:vX.Y.Z`, `:vX.Y`, `:vX`, `:latest` to
  `ghcr.io/sherodtaylor/agent-smith`.
- **`chart`** — published `oci://ghcr.io/sherodtaylor/charts/agent-smith:X.Y.Z`
  and attached `agent-smith-X.Y.Z.tgz` to the Release.

Verify the artifacts:

```bash
docker pull ghcr.io/sherodtaylor/agent-smith:vX.Y.Z
helm pull oci://ghcr.io/sherodtaylor/charts/agent-smith --version X.Y.Z
```

### 6. Bump the consuming HelmReleases

In `sherodtaylor/homelab`, update both:

- `k8s/apps/agents/devbot-helmrelease.yaml`
- `k8s/apps/agents/infrabot-helmrelease.yaml`

```yaml
spec:
  chart:
    spec:
      chart: agent-smith
      version: "X.Y.Z"   # ← bump
```

Commit on `main` (Flux reconciles automatically) or open a PR if you want a
review window.

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
docker pull ghcr.io/sherodtaylor/agent-smith:vX.Y.Z
helm pull   oci://ghcr.io/sherodtaylor/charts/agent-smith --version X.Y.Z
gh release view vX.Y.Z --repo sherodtaylor/agent-smith
kubectl get helmrelease -n agents -o jsonpath='{range .items[*]}{.metadata.name}={.spec.chart.spec.version}{"\n"}{end}'
```

All four should report `X.Y.Z`. If one disagrees, that's the layer to fix.

## Why this works

Tags are the **only** trigger for the chart job (see `.github/workflows/docker.yml`,
`if: startsWith(github.ref, 'refs/tags/v')`). Pushes to `main` never publish
a chart and never move `:latest`. The chart version is derived from the tag
name (`GITHUB_REF_NAME#v`), so the chart and image are always at the same
version — you can't release one without the other.
