---
title: Contributing
description: How to add features and agents to agent-smith.
---

The repo's homelab origin is incidental. The design constraints are
production constraints. Treat any change as software anyone could
deploy into their own cluster — not a personal script.

## Working in this repo

1. **Read before writing.** Open the file. Open the surrounding files.
   Match the existing style — bash uses `set -euo pipefail`, YAML is
   2-space, Go matches what's already there. Don't write a function
   whose conventions clash with the file it lives in.
2. **One concern per PR.** A release bump is one PR. A new runbook is
   one PR. Don't ride a refactor on top of a bug fix. This applies to
   docs too — README and runbook edits go through a PR, not direct
   pushes to `main`.
3. **Verify before claiming done.** `helm lint charts/agent-smith`,
   `bash -n scripts/*.sh`, `docker build .` if available. State the
   verification command in the PR body.
4. **Document the *why*, not the *what*.** A comment that just
   restates the code is noise. A comment that names the constraint
   (`# git HTTPS uses Basic Auth which iron-proxy can't swap → use
   GIT_GITHUB_TOKEN`) earns its place.
5. **No placeholders, no TODOs, no commented-out code** in merged PRs.
6. **Update `CHANGELOG.md`** in the same PR for any user-visible
   change. The release runbook expects to copy from `[Unreleased]`
   into the new version section.
7. **Update the affected runbook** if the change alters operational
   behaviour. A new env var → update `release.md` and/or
   `adding-agent.md`. A new failure mode → add it to `agent-down.md` or
   `oauth-401.md`.

## Git workflow

1. **Never commit to `main`** — always work on a feature branch.
2. Branch naming: `feat/<short-slug>` or `fix/<short-slug>`.
3. Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`,
   `refactor:`.
4. PR title prefix: `[Dev]` (DevBot) or `[Infra]` (InfraBot). Humans
   can use a descriptive prefix or none.
5. PR body: what was requested, what changed, how to verify.
6. Review the diff before opening. Catch obvious mistakes early.
7. One concern per PR. Don't bundle unrelated changes.

Use git worktrees for isolated feature work when it prevents
conflicts.

## Code quality standards

- No placeholders, no TODOs, no commented-out code in PRs.
- Match surrounding style: same indentation, naming conventions,
  quoting style.
- **YAML** — 2-space indent, no trailing whitespace, leading `---` on
  multi-document files.
- **Bash** — `set -euo pipefail`, quote all variables, avoid
  unnecessary subshells.
- **Go** — run `go vet ./...` before pushing; match the existing
  error-handling style.
- Keep PRs small and focused. One concern per PR. If it touches 5+
  unrelated files, split it.

## Testing requirements

Before opening a PR, verify the change:

- **k8s YAML manifests** — `kubectl kustomize <dir>` must succeed with
  no errors.
- **Bash scripts** — `bash -n <script>` for syntax; trace through the
  logic mentally.
- **Dockerfile changes** — the image must build:
  `docker build -t test:local .`.
- **Helm chart** — `helm lint charts/agent-smith` and `helm template`
  against representative values.
- **Go code** — `go build ./...` and `go test ./...` must pass.

If the test can't be run, say so explicitly in the PR body. Don't
claim it works.

## Where to make changes

The repo has two distinct CLAUDE.md files for two distinct audiences:

| File | Audience | Purpose |
|---|---|---|
| `CLAUDE.md` (project root) | Whoever is editing this codebase | How to work in the repo |
| `agents/_shared/CLAUDE.md` | The running bot | How to behave on Matrix |
| `agents/<name>/CLAUDE.md` | The running bot | Per-persona rules |

When changing **how the bot acts at runtime**, edit
`agents/_shared/CLAUDE.md` or the persona file. When changing **how
this codebase is maintained**, edit the project-root `CLAUDE.md`.

The Kubernetes manifests that deploy the agents intentionally live in
a separate repo
([`sherodtaylor/homelab`](https://github.com/sherodtaylor/homelab)),
not in this one. Bumping the chart version there is the last step of
every release.
