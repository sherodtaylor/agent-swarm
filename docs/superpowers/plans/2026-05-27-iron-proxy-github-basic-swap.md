# Iron-proxy github.com Basic-Auth swap — implementation plan (revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the GitHub Basic-Auth credential entirely into iron-proxy. Agent pods carry the stub `proxy-token-github` in `.git-credentials`; iron-proxy decodes the b64 Authorization header on github.com requests, swaps the stub for the real PAT in its `GITHUB_TOKEN` env, re-encodes, forwards. No real PAT ever sits in agent pod env at rest.

**Architecture:** Iron-proxy already implements the swap AND has the github.com entry. Remaining work: add `raw.githubusercontent.com` to the existing host list, drop the dead `GIT_GITHUB_TOKEN` from agent ExternalSecrets, and rewrite `setup.sh` to write the stub instead of the real PAT.

**Tech Stack:** YAML (k8s), bash (setup.sh), Markdown (docs).

**Spec:** `docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md`
**Research:** `docs/research/2026-05-27-iron-proxy-deepdive.md`

**Two repos involved:**
- **homelab:** add `raw.githubusercontent.com` host rule + drop `GIT_GITHUB_TOKEN` from agent ExternalSecrets (Phase A).
- **agent-smith:** rewrite `setup.sh` + docs (Phase B).

**Sequencing constraint (load-bearing):** iron-proxy's `GITHUB_TOKEN` env must hold a workflow-scoped PAT BEFORE agent-smith starts writing the stub. Today iron-proxy is holding a stale pre-rotation PAT — Phase 0 is a one-time ops rollout (no commit) to pick up the already-synced new value.

---

## Phase 0 — One-time ops (no commits)

### Task 0: Restart iron-proxy to pick up the post-rotation SWARM_GITHUB_TOKEN

**Files:** none

- [ ] **Step 1: InfraBot runs**

```bash
kubectl rollout restart deployment/iron-proxy -n agent-infra
kubectl rollout status deployment/iron-proxy -n agent-infra --timeout=60s
```

- [ ] **Step 2: Smoke-verify** (from any agent pod):

```bash
SSL_CERT_FILE=/root/iron-proxy.crt curl -sI \
  -H 'Authorization: Bearer proxy-token-github' \
  https://api.github.com/user | grep -i 'x-oauth-scopes'
# expected: a header containing the substring `workflow`
```

If `workflow` is missing, STOP. `SWARM_GITHUB_TOKEN` in Infisical lacks workflow scope — run `make infisical-sync` from a Mac with `gh auth refresh -s repo,workflow,read:org` first, then re-run Task 0.

---

## Phase A — homelab (small additions)

### Task 1: Add `raw.githubusercontent.com` to the existing GitHub host rule

**Files:**
- Modify: `/workspace/homelab/k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml`

- [ ] **Step 1: Branch**

```bash
cd /workspace/homelab
git checkout main && git pull --ff-only
git checkout -b feat/iron-proxy-github-swap-finishing
```

- [ ] **Step 2: Edit the existing GitHub host rule** (currently `configmap.yaml:60-70`). Append one `host:` line for `raw.githubusercontent.com` and refresh the comment block:

```yaml
            # GitHub token swap — agent pods send a stub `proxy-token-github`
            # in Authorization (Bearer or Basic), iron-proxy decodes b64 if
            # needed, replaces with the real PAT from $GITHUB_TOKEN, re-encodes,
            # forwards. require: false so any non-stub auth (e.g. an operator
            # running `gh` directly) passes through unchanged.
            - source:
                type: env
                var: GITHUB_TOKEN
              proxy_value: "proxy-token-github"
              match_headers: ["Authorization"]
              require: false
              rules:
                - host: "github.com"
                - host: "*.github.com"
                - host: "raw.githubusercontent.com"
```

- [ ] **Step 3: Validate YAML**

```bash
kubectl --dry-run=client apply -f k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml 2>&1 | tail -3
# expected: "configured (dry run)"
```

- [ ] **Step 4: Commit**

```bash
git add k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml
git commit -m "feat(iron-proxy): include raw.githubusercontent.com in github stub swap

raw.githubusercontent.com isn't a subdomain of github.com so the
existing *.github.com wildcard didn't cover it. Adds an explicit
host rule so dotfiles/install.sh fetches and any other raw fetch
also goes through the proxy-token-github swap.

Updated the surrounding comment to reflect the architecture: agents
now ship a stub in Authorization (Basic or Bearer); iron-proxy
swaps. Pods no longer hold real PATs.

Spec: agent-smith/docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 2: Drop `GIT_GITHUB_TOKEN` from agent ExternalSecrets

**Files:**
- Modify: `/workspace/homelab/k8s/apps/agents/externalsecret-devbot.yaml`
- Modify: `/workspace/homelab/k8s/apps/agents/externalsecret-infrabot.yaml`

- [ ] **Step 1: Remove the entry from both files**

```yaml
# BEFORE
- secretKey: GIT_GITHUB_TOKEN
  remoteRef:
    key: SWARM_GITHUB_TOKEN

# AFTER: removed
```

- [ ] **Step 2: Validate**

```bash
kubectl --dry-run=client apply \
  -f k8s/apps/agents/externalsecret-devbot.yaml \
  -f k8s/apps/agents/externalsecret-infrabot.yaml 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add k8s/apps/agents/externalsecret-devbot.yaml k8s/apps/agents/externalsecret-infrabot.yaml
git commit -m "chore(agents): drop GIT_GITHUB_TOKEN — iron-proxy now swaps at egress

Pair commit with agent-smith feat/git-stub-credentials (setup.sh
now writes the stub into .git-credentials). After both land + Flux
reconciles, no agent pod env contains a real GitHub PAT.

Iron-proxy still pulls SWARM_GITHUB_TOKEN into its own env via the
iron-proxy-upstream-secrets ExternalSecret; this commit only removes
the now-unused pod-side copy."
```

### Task 3: Push + PR for homelab

**Files:** none

- [ ] **Step 1: Push**

```bash
cd /workspace/homelab
git push -u origin feat/iron-proxy-github-swap-finishing
```

- [ ] **Step 2: Open PR**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/homelab \
  --head feat/iron-proxy-github-swap-finishing --base main \
  --title "feat(iron-proxy): finish github stub swap (raw.git + drop pod GIT_GITHUB_TOKEN)" \
  --body "$(cat <<'EOF'
## What
Two small changes that finish moving GitHub credential handling entirely into iron-proxy:

1. iron-proxy ConfigMap: add `raw.githubusercontent.com` to the existing github stub-swap host list (raw isn't a subdomain of github.com so the `*.github.com` wildcard missed it). Comment updated.
2. agent ExternalSecrets (devbot + infrabot): drop the dead `GIT_GITHUB_TOKEN` entry — the agent-smith setup.sh (pair PR) now writes the stub `proxy-token-github` into `.git-credentials` instead of the real PAT.

## Companion agent-smith PR
**Must land + deploy AFTER this**: `<agent-smith feat/git-stub-credentials PR #>`.

## Verify
```
kubectl rollout status deployment/iron-proxy -n agent-infra
# from a devbot pod, after Flux reconciles agent ExternalSecrets:
env | grep -E 'GIT_GITHUB_TOKEN|GITHUB_TOKEN'
# expected: GITHUB_TOKEN=proxy-token-github (stub), GIT_GITHUB_TOKEN unset
```

Spec: agent-smith/docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Phase B — agent-smith (setup.sh stub + docs)

### Task 4: Rewrite `setup.sh` to write the stub

**Files:**
- Modify: `/workspace/agent-smith/scripts/setup.sh`

- [ ] **Step 1: Branch**

```bash
cd /workspace/agent-smith
git checkout main && git pull --ff-only
git checkout -b feat/git-stub-credentials
```

- [ ] **Step 2: Locate the existing block** (around lines 93-112) starting `# git / gh auth …` through the `if [ -n "${_GIT_TOKEN:-}" ]; then … fi` block.

- [ ] **Step 3: Replace it with**

```bash
# git / gh auth — both paths route through iron-proxy as the credential
# boundary.
#   - `gh` reads GITHUB_TOKEN env (stub `proxy-token-github`); iron-proxy
#     swaps it on Bearer calls to api.github.com.
#   - `git push/pull/clone` over HTTPS uses Basic Auth with the same stub
#     in .git-credentials; iron-proxy decodes the b64 Authorization, swaps
#     the stub for the real PAT held in iron-proxy's GITHUB_TOKEN env,
#     re-encodes, forwards. No real PAT ever lives in this pod.
#
# Design: docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
git config --global user.name  "${AGENT_NAME}"
git config --global user.email "${AGENT_NAME}@lab.sherodtaylor.dev"
git config --global http.sslCAInfo "${HOME}/iron-proxy.crt"
git config --global credential.helper store
printf 'https://x-access-token:proxy-token-github@github.com\n' \
  > "${HOME}/.git-credentials"
chmod 600 "${HOME}/.git-credentials"
echo "[setup] git credentials configured (stub — iron-proxy swaps at egress)"
```

- [ ] **Step 4: Verify shell syntax**

```bash
bash -n /workspace/agent-smith/scripts/setup.sh
# expected: clean exit
```

- [ ] **Step 5: Commit**

```bash
git add scripts/setup.sh
git commit -m "feat(setup): write stub git credential, let iron-proxy swap at egress

The pod no longer holds a real GitHub PAT. .git-credentials carries
\`proxy-token-github\` as the basic-auth password; iron-proxy decodes
the b64 Authorization header on github.com requests, replaces the
stub with the real PAT held in its GITHUB_TOKEN env (sourced from
Infisical via iron-proxy-upstream-secrets ExternalSecret),
re-encodes, forwards. Streaming packfiles unaffected
(match_headers: [\"Authorization\"] in iron-proxy config — header-only).

Removes the _GIT_TOKEN resolution and the conditional credential
write — the stub is always present.

Spec: docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 5: Update `docs/architecture.md`

**Files:**
- Modify: `/workspace/agent-smith/docs/architecture.md`

- [ ] **Step 1: Find the Security / iron-proxy section**

```bash
grep -nE 'iron-proxy.*swap|cannot swap|holds? the real (token|PAT)|.git-credentials' docs/architecture.md
```

- [ ] **Step 2: Rewrite the relevant paragraph(s)** to assert:
  - Iron-proxy swaps both Bearer (api.github.com, *.anthropic.com) and Basic (github.com, *.github.com, raw.githubusercontent.com)
  - The pod's `.git-credentials` carries the stub `proxy-token-github`
  - The real PAT lives only in iron-proxy's `GITHUB_TOKEN` env, populated from Infisical's `SWARM_GITHUB_TOKEN` via the `iron-proxy-upstream-secrets` ExternalSecret in `agent-infra`
  - Cite this spec

Remove any sentence asserting iron-proxy "cannot swap" Basic Auth — that's stale.

- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md
git commit -m "docs(architecture): document github.com Basic-Auth swap at iron-proxy

The prior claim that iron-proxy cannot swap git Basic Auth was stale;
iron-proxy's secret transform decodes b64 and replaces stubs in the
header before egress. Documented for github.com + raw.git case."
```

### Task 6: Sync CLAUDE.md (project root) if it carries the same stale claim

**Files:**
- Modify (if needed): `/workspace/agent-smith/CLAUDE.md`

- [ ] **Step 1: Search**

```bash
grep -nE 'iron-proxy.*swap|cannot swap|holds? the real (token|PAT)' /workspace/agent-smith/CLAUDE.md
```

- [ ] **Step 2: If found, update in lockstep + commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): sync security note with architecture.md github.com swap"
```

If grep returned nothing, skip.

### Task 7: Push + PR for agent-smith

**Files:** none

- [ ] **Step 1: Push** (no workflow files in this PR; standard `git push` path works regardless of any current credential-scope state)

```bash
cd /workspace/agent-smith
git push -u origin feat/git-stub-credentials
```

- [ ] **Step 2: Open PR**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/agent-smith \
  --head feat/git-stub-credentials --base main \
  --title "[dev] feat(setup): write stub git credential, let iron-proxy swap at egress" \
  --body "$(cat <<'EOF'
## What
Pod no longer holds a real GitHub PAT. `setup.sh` writes `proxy-token-github` into `.git-credentials`; iron-proxy decodes the Authorization header on github.com requests, swaps the stub for the real PAT in its GITHUB_TOKEN env, re-encodes, forwards.

## Companion homelab PR
**Must merge + deploy FIRST**: sherodtaylor/homelab PR #<n> — adds `raw.githubusercontent.com` to the iron-proxy host swap and drops the dead `GIT_GITHUB_TOKEN` from agent ExternalSecrets.

## Verify after deploy
```
# from inside an agent pod (after chart bumps + pod restart):
cat /root/.git-credentials | sed 's|:[^@]*@|:<stub>@|g'
# expected: https://x-access-token:<stub>@github.com   (literal proxy-token-github)

git push origin <any-branch>                          # generic push — works
git push origin <branch-with-workflow-file-change>    # workflow push — also works via iron-proxy's swapped real PAT
```

Spec: docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Task 8: Bump agent-smith chart version

**Files:**
- Modify: `/workspace/agent-smith/charts/agent-smith/Chart.yaml`

- [ ] **Step 1: Bump patch number** (e.g. 0.1.22 → 0.1.23). `appVersion` to match.

- [ ] **Step 2: Commit on the same branch + push**

```bash
git add charts/agent-smith/Chart.yaml
git commit -m "chore(release): v0.1.23 — stub git creds with iron-proxy swap"
git push
```

### Task 9: Deploy + verify

**Files:** none (operational)

- [ ] **Step 1:** After both PRs merge, InfraBot bumps the agent-smith HelmRelease in homelab to the new chart version (`.claude/references/bump-homelab-chart.sh --version 0.1.23 --agent devbot,infrabot`).

- [ ] **Step 2:** Wait for Flux + pod restart. Confirm pods Ready.

- [ ] **Step 3: Smoke from inside devbot pod**

```bash
cat /root/.git-credentials | sed 's|:[^@]*@|:<stub>@|g'
# expected: line shows <stub>
env | grep GIT_GITHUB_TOKEN
# expected: empty
```

- [ ] **Step 4: End-to-end workflow-file push** (the original failing case)

```bash
git -C /workspace/agent-smith fetch origin
git -C /workspace/agent-smith checkout -b chore/smoke-iron-proxy-swap origin/main
mkdir -p /workspace/agent-smith/.github/workflows
cat > /workspace/agent-smith/.github/workflows/smoke.yml <<'YAML'
name: smoke
on: [workflow_dispatch]
jobs:
  hi: { runs-on: ubuntu-latest, steps: [{ run: echo "hi from stub swap" }] }
YAML
git -C /workspace/agent-smith add -f .github/workflows/smoke.yml
git -C /workspace/agent-smith commit -m "chore: smoke iron-proxy stub swap"
git -C /workspace/agent-smith push -u origin chore/smoke-iron-proxy-swap
# expected: pushed cleanly

# cleanup
SSL_CERT_FILE=/root/iron-proxy.crt gh api -X DELETE repos/sherodtaylor/agent-smith/git/refs/heads/chore/smoke-iron-proxy-swap
git -C /workspace/agent-smith checkout main && git -C /workspace/agent-smith branch -D chore/smoke-iron-proxy-swap
```

If the smoke fails, document and roll back the agent-smith chart version. The homelab cleanup (Phase A) is benign by itself.

---

## Phase C — Cleanup (optional, after 1 week green)

### Task 10: Audit remaining `SWARM_GITHUB_TOKEN` references

**Files:** none

- [ ] **Step 1: Grep both repos**

```bash
grep -rln 'SWARM_GITHUB_TOKEN' /workspace/homelab /workspace/agent-smith 2>/dev/null | head -10
```

- [ ] **Step 2:** If the only remaining references are iron-proxy's ExternalSecret (still consuming `SWARM_GITHUB_TOKEN`), do nothing — iron-proxy is the rightful consumer. Otherwise audit each.

No commit (Phase C is just an audit pass).

---

## Self-review (done before handoff)

- **Spec coverage:** Q1 already-true (no change), Q2 stub corrected to `proxy-token-github` in T4, Q3 already-true (no change), Q4 in T2+T4, Q5 in T1, Q6 no NATS (no task). Files §4.1→T1, §4.3→T2, §4.4→T4, §4.5→T5, §4.6→T6. Sequencing §5 explicit (Phase 0 → A → B → deploy).
- **Placeholder scan:** zero TBD/FIXME.
- **Identifier consistency:** `proxy-token-github` used identically in T1, T4, T9.
- **Ambiguity:** rollback path documented (chart revert); Phase 0 smoke gate explicit; Phase A is benign without Phase B (no break).
