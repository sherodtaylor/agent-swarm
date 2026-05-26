# .claude/references

Reusable scripts that back the operational runbooks in `docs/runbooks/`.

Every script is self-contained and parameterised. The runbooks reference them
by path rather than inlining the same snippet six times. If a procedure
changes, fix it here once.

## Index

| Script | What it does | Runbook(s) |
|---|---|---|
| `gh-token.sh` | Shared helper — resolves `GH_TOKEN` from env or `~/.config/gh/hosts.yml`. **Source**, don't run. | (all GitHub API scripts) |
| `compare-since-tag.sh` | Show commits on `main` since last semver tag. Use to decide the version bump before a release. | `release.md` |
| `cut-release.sh` | Create annotated tag + GitHub Release via API. CI publishes image + chart automatically. | `release.md` |
| `bump-homelab-chart.sh` | Bump `version:` on all `*-helmrelease.yaml` files in `sherodtaylor/homelab` via API. | `release.md` |
| `check-release.sh` | Verify tag + GitHub Release + image + chart all exist for a given version. | `release.md`, `ci-failure.md` |
| `restart-agent.sh` | Delete an agent pod and wait for Ready. Triggers full init + re-auth. | `agent-down.md`, `oauth-401.md`, `secret-rotation.md` |
| `restart-ironproxy.sh` | Rollout restart the iron-proxy deployment. Required after rotating Claude OAuth token. | `oauth-401.md`, `secret-rotation.md` |
| `force-eso-sync.sh` | Annotate an ExternalSecret to trigger immediate re-sync from Infisical. | `secret-rotation.md` |
| `restore-stub-creds.sh` | Restore stub credentials inside a running pod without a full restart. | `oauth-401.md` |

## Prerequisites

- `kubectl` in `$PATH`, configured for the homelab cluster.
- `GH_TOKEN` set in env, **or** `~/.config/gh/hosts.yml` present with a valid
  `oauth_token` for `github.com`. (`gh-token.sh` handles the fallback.)
- `python3` in `$PATH` (used for JSON parsing in the GitHub API scripts).
- `jq` in `$PATH` (used by `restore-stub-creds.sh`).

## Usage pattern

Scripts are not installed globally — run them directly from the repo:

```bash
.claude/references/compare-since-tag.sh
.claude/references/cut-release.sh --version v0.1.16 --message "your summary" --dry-run
.claude/references/cut-release.sh --version v0.1.16 --message "your summary"
.claude/references/check-release.sh --version 0.1.16
.claude/references/bump-homelab-chart.sh --version 0.1.16
```

All scripts support `--dry-run` where it's meaningful, and `--help` everywhere.

## Adding a new script

1. Put it in this directory.
2. Name it `<verb>-<noun>.sh` (e.g. `rotate-matrix-token.sh`).
3. Add a row to the index above.
4. Reference it from the relevant runbook with the full relative path
   `.claude/references/<script>.sh`.
5. `chmod +x` before committing.
