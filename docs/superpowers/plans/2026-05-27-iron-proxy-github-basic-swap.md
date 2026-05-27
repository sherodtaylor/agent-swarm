# Iron-proxy github.com Basic-Auth swap — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure iron-proxy to swap a stub Basic-Auth credential (`stub-token-github`) for the real GitHub PAT at egress for `github.com` and `raw.githubusercontent.com`, then change agent-smith's `setup.sh` to write the stub into `.git-credentials` so no agent pod ever holds a real GitHub credential.

**Architecture:** Pure config change in homelab (iron-proxy ConfigMap + ExternalSecret edits) + a small `setup.sh` rewrite in agent-smith + doc updates in both repos. No iron-proxy code changes — the Basic-Auth swap is already implemented (research §B).

**Tech Stack:** YAML (k8s), bash (setup.sh), Markdown (docs).

**Spec:** `docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md`

**Research:** `docs/research/2026-05-27-iron-proxy-deepdive.md`

**Two repos involved:**
- **homelab:** iron-proxy ConfigMap + ExternalSecret edits (Phase A) + agent ExternalSecret cleanups (Phase A)
- **agent-smith:** setup.sh + architecture.md + CLAUDE.md edits (Phase B)

**Sequencing constraint (load-bearing):** iron-proxy must be configured to swap BEFORE agent-smith starts writing stubs, or pushes will fail with the literal stub string reaching github.com. Phase A merges + deploys first; Phase B follows.

---

## Phase A — Iron-proxy config (homelab)

### Task 1: Inventory the existing iron-proxy config

**Files (read-only):**
- `/workspace/homelab/k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml`
- `/workspace/homelab/k8s/infrastructure/config/agent-swarm/iron-proxy/externalsecret.yaml`
- `/workspace/homelab/k8s/infrastructure/config/agent-swarm/iron-proxy/deployment.yaml`

- [ ] **Step 1: Read all three files end-to-end.** Record the exact YAML key names used for:
  - The `hosts:` list shape (`name`/`upstream`/`transforms`/`config`)
  - The `secrets` transform config keys: confirm `require`, `match_body`, `replacements`, `stub_value`, and the env-source key (likely `proxy_value_from_env` per `/tmp/iron-proxy/iron-proxy.example.yaml:121-129`, but may be `proxy_value_env`, `fromEnv`, etc.)
  - How `*.anthropic.com` is currently configured (the closest analog — copy its shape)
  - Whether the iron-proxy deployment has a `kubectl.kubernetes.io/restartedAt` annotation or configmap-checksum trigger for restart on config change

- [ ] **Step 2: Inventory the existing iron-proxy ExternalSecret.** Note what GitHub-related keys (if any) are already pulled. Likely there's a Bearer-swap entry for `api.github.com` that already uses a real PAT — if so, reuse that key for the new Basic-Auth entry.

- [ ] **Step 3: Determine restart trigger.** If iron-proxy's Deployment has no auto-restart-on-configmap-change annotation, the implementer will add a manual `kubectl rollout restart deployment/iron-proxy -n agent-infra` step in T6.

No commit — this is inspection.

### Task 2: Add github.com + raw.githubusercontent.com hosts to iron-proxy ConfigMap

**Files:**
- Modify: `/workspace/homelab/k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml`

- [ ] **Step 1: Branch in homelab**

```bash
cd /workspace/homelab
git checkout main && git pull --ff-only
git checkout -b feat/iron-proxy-github-basic-swap
```

- [ ] **Step 2: Edit `configmap.yaml`** — append two new entries to the `hosts:` list (after any existing api.github.com / *.anthropic.com entries). Use the exact key naming you discovered in T1; the conceptual shape is:

```yaml
hosts:
  # ...existing entries unchanged...

  - name: github.com
    upstream: https://github.com
    transforms:
      - kind: secrets
        config:
          require: false        # pass-through if stub absent (Sherod: Q3 = pass-through)
          match_body: false     # header-only — keeps git-receive-pack packfiles streamed
          replacements:
            - stub_value: stub-token-github
              proxy_value_from_env: GITHUB_PAT   # source from iron-proxy's env, see T3

  - name: raw.githubusercontent.com
    upstream: https://raw.githubusercontent.com
    transforms:
      - kind: secrets
        config:
          require: false
          match_body: false
          replacements:
            - stub_value: stub-token-github
              proxy_value_from_env: GITHUB_PAT
```

If the existing convention uses a different env-source key (e.g. `proxy_value_env`), use THAT instead.

- [ ] **Step 3: Validate the YAML**

```bash
kubectl --dry-run=client apply -f k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml 2>&1 | tail -5
# expected: "created (dry run)" or "configured (dry run)"
```

- [ ] **Step 4: Commit**

```bash
git add k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml
git commit -m "feat(iron-proxy): add github.com + raw.githubusercontent.com Basic-Auth swap

Swap the stub credential 'stub-token-github' for the real PAT held in
iron-proxy's secret store before egress. Eliminates the need for any
agent-smith pod to hold a real GitHub credential.

- require: false — pass-through when stub absent (operators running gh
  via kubectl exec are unaffected)
- match_body: false — header-only swap keeps multi-MiB packfiles
  streamed through git-receive-pack

Spec: agent-smith/docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
Research: agent-smith/docs/research/2026-05-27-iron-proxy-deepdive.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 3: Ensure iron-proxy ExternalSecret pulls the real GitHub PAT

**Files:**
- Modify (if needed): `/workspace/homelab/k8s/infrastructure/config/agent-swarm/iron-proxy/externalsecret.yaml`

- [ ] **Step 1: Check whether `GITHUB_PAT` is already pulled** (T1 should have answered this). If yes, no change needed — skip to T4.

- [ ] **Step 2: If NOT already present, add the entry**

```yaml
spec:
  data:
    # ...existing entries...
    - secretKey: GITHUB_PAT
      remoteRef:
        key: SWARM_GITHUB_TOKEN   # reuse the existing PAT (Sherod: Q1 = one PAT)
```

If the existing convention uses an iron-proxy-specific key name (e.g. `IRONPROXY_GITHUB_PAT`) for separation, follow that pattern and ensure that Infisical key holds the same PAT as `SWARM_GITHUB_TOKEN`.

- [ ] **Step 3: Validate + commit (if changed)**

```bash
kubectl --dry-run=client apply -f k8s/infrastructure/config/agent-swarm/iron-proxy/externalsecret.yaml 2>&1 | tail -3
git add k8s/infrastructure/config/agent-swarm/iron-proxy/externalsecret.yaml
git commit -m "chore(iron-proxy): pull GITHUB_PAT for github.com Basic-Auth swap

Sourced from the existing SWARM_GITHUB_TOKEN Infisical key (single
PAT covers both gh-api Bearer and git push Basic per spec Q1)."
```

### Task 4: Drop `GIT_GITHUB_TOKEN` from agent ExternalSecrets

**Files:**
- Modify: `/workspace/homelab/k8s/apps/agents/externalsecret-devbot.yaml`
- Modify: `/workspace/homelab/k8s/apps/agents/externalsecret-infrabot.yaml`

- [ ] **Step 1: In both files, remove the `GIT_GITHUB_TOKEN` entry**

```yaml
# BEFORE
    - secretKey: GIT_GITHUB_TOKEN
      remoteRef:
        key: SWARM_GITHUB_TOKEN

# AFTER: removed
```

- [ ] **Step 2: Validate**

```bash
kubectl --dry-run=client apply -f k8s/apps/agents/externalsecret-devbot.yaml -f k8s/apps/agents/externalsecret-infrabot.yaml 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add k8s/apps/agents/externalsecret-devbot.yaml k8s/apps/agents/externalsecret-infrabot.yaml
git commit -m "chore(agents): drop GIT_GITHUB_TOKEN — iron-proxy now swaps at egress

setup.sh writes a stub credential into .git-credentials; iron-proxy
swaps it for the real PAT before the request hits github.com. The
pod no longer needs the real PAT at rest."
```

### Task 5: Push + PR for homelab Phase A

**Files:** none

- [ ] **Step 1: Push the branch**

```bash
cd /workspace/homelab
git push -u origin feat/iron-proxy-github-basic-swap
```

- [ ] **Step 2: Open PR**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/homelab \
  --head feat/iron-proxy-github-basic-swap --base main \
  --title "feat(iron-proxy): github.com Basic-Auth swap + retire pod-side PAT" \
  --body "$(cat <<'EOF'
## What
Iron-proxy already has Basic-Auth swap implemented; this PR wires it up for `github.com` + `raw.githubusercontent.com` so `git push` from agent pods works using a stub credential. Drops `GIT_GITHUB_TOKEN` from agent ExternalSecrets — pods no longer hold the real PAT.

## Sequencing — IMPORTANT
This PR must merge + Flux reconcile + iron-proxy restart BEFORE the agent-smith PR (which flips setup.sh to write the stub). Otherwise pushes fail with the literal stub reaching github.com.

## Verify (after Flux reconciles)
```
# from inside an agent pod:
curl -v -H "Authorization: Basic $(printf 'x-access-token:stub-token-github' | base64 -w0)" \
  https://api.github.com/user
# expected: 200 OK + bot account info
```

Spec: agent-smith/docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
Research: agent-smith/docs/research/2026-05-27-iron-proxy-deepdive.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Task 6: Wait for merge + Flux reconcile + verify swap is live

**Files:** none (operational gate)

- [ ] **Step 1: After PR merges, wait for Flux to reconcile iron-proxy.** If the Deployment has no configmap-checksum annotation, run:

```bash
SSL_CERT_FILE=/root/iron-proxy.crt kubectl rollout restart deployment/iron-proxy -n agent-infra
SSL_CERT_FILE=/root/iron-proxy.crt kubectl rollout status deployment/iron-proxy -n agent-infra --timeout=60s
```

- [ ] **Step 2: Smoke from an agent pod**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt curl -sI -H "Authorization: Basic $(printf 'x-access-token:stub-token-github' | base64 -w0)" \
  https://api.github.com/user | head -3
# expected: HTTP/1.1 200 OK
```

If this 401s, iron-proxy config is wrong — DO NOT proceed to Phase B. Debug iron-proxy first (likely: env var not propagated, key name typo in `proxy_value_from_env`, or the existing schema differs from what we wrote).

---

## Phase B — agent-smith stub credentials

Only proceed after Task 6 step 2 returns `200 OK`.

### Task 7: Rewrite the .git-credentials block in setup.sh

**Files:**
- Modify: `/workspace/agent-smith/scripts/setup.sh`

- [ ] **Step 1: Branch in agent-smith**

```bash
cd /workspace/agent-smith
git checkout main && git pull --ff-only
git checkout -b feat/git-stub-credentials
```

- [ ] **Step 2: Replace the existing block** (currently around setup.sh:103-112) with the stub-write version:

Locate (in setup.sh near line 93):
```bash
# git / gh auth — GITHUB_TOKEN is already in the environment...
#
# git HTTPS uses Basic Auth (base64-encoded credentials) which iron-proxy cannot
# swap (it matches plain-text stub values). GIT_GITHUB_TOKEN carries the real
# token specifically for .git-credentials so git clone/pull/push work...
_GIT_TOKEN="${GIT_GITHUB_TOKEN:-${GITHUB_TOKEN}}"
git config --global user.name  "${AGENT_NAME}"
git config --global user.email "${AGENT_NAME}@lab.sherodtaylor.dev"
git config --global http.sslCAInfo "${HOME}/iron-proxy.crt"
if [ -n "${_GIT_TOKEN:-}" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "${_GIT_TOKEN}" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
  echo "[setup] git credentials configured (GIT_GITHUB_TOKEN for clone/push, GITHUB_TOKEN for gh API)"
fi
```

Replace with:
```bash
# git / gh auth — both paths use iron-proxy as the credential boundary.
# `gh` reads GITHUB_TOKEN env (stub `proxy-token-github`); iron-proxy swaps
# it on Bearer calls to api.github.com.
# `git push/pull/clone` over HTTPS uses Basic Auth with a stub in
# .git-credentials; iron-proxy decodes the b64, swaps the stub for the real
# PAT, re-encodes, and forwards. No real PAT ever lives in this pod.
#
# Design: docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
git config --global user.name  "${AGENT_NAME}"
git config --global user.email "${AGENT_NAME}@lab.sherodtaylor.dev"
git config --global http.sslCAInfo "${HOME}/iron-proxy.crt"
git config --global credential.helper store
printf 'https://x-access-token:stub-token-github@github.com\n' \
  > "${HOME}/.git-credentials"
chmod 600 "${HOME}/.git-credentials"
echo "[setup] git credentials configured (stub — iron-proxy swaps at egress)"
```

- [ ] **Step 3: Verify shell syntax**

```bash
bash -n /workspace/agent-smith/scripts/setup.sh
# expected: clean exit, no output
```

- [ ] **Step 4: Commit**

```bash
git add scripts/setup.sh
git commit -m "feat(setup): write stub git credential, let iron-proxy swap at egress

The pod no longer holds a real GitHub PAT. .git-credentials carries
\`stub-token-github\` as the basic-auth password; iron-proxy decodes
the b64 Authorization header on github.com requests, replaces the
stub with the real PAT held in its secret store, re-encodes, and
forwards. Streaming packfiles (\`git-receive-pack\`) are unaffected
(\`match_body: false\` in iron-proxy config).

Removes the \`_GIT_TOKEN\` resolution and the conditional credential
write — the stub is always present.

Spec: docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 8: Update docs/architecture.md to reflect the new model

**Files:**
- Modify: `/workspace/agent-smith/docs/architecture.md`

- [ ] **Step 1: Find the Security / iron-proxy section** (grep for `iron-proxy`, then the paragraph that says iron-proxy "cannot swap" Basic Auth or describes `.git-credentials` holding the real PAT).

- [ ] **Step 2: Rewrite the paragraph** to reflect:
  - Iron-proxy swaps Basic Auth on github.com (and raw.githubusercontent.com) using the same secret-transform path as Bearer swap on api.github.com
  - The pod's `.git-credentials` carries the stub `stub-token-github`
  - The real PAT lives only in iron-proxy's secret store, populated from Infisical's `SWARM_GITHUB_TOKEN` via the iron-proxy ExternalSecret
  - Cite this spec by path

- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md
git commit -m "docs(architecture): describe github.com Basic-Auth swap at iron-proxy

The prior claim that iron-proxy cannot swap git Basic Auth was stale;
iron-proxy's secret transform decodes b64 and replaces stubs in the
header before egress. Documented for the github.com + raw.git case."
```

### Task 9: Update CLAUDE.md (project root) if it carries the same stale claim

**Files:**
- Modify (if needed): `/workspace/agent-smith/CLAUDE.md`

- [ ] **Step 1: Search** for the same stale "iron-proxy cannot swap" / "pod holds the real PAT" wording in CLAUDE.md.

```bash
grep -nE 'iron-proxy.*swap|holds? .* (PAT|token)|real (token|PAT)' /workspace/agent-smith/CLAUDE.md
```

- [ ] **Step 2: If found, update in lockstep with the architecture.md change.** If absent, skip.

- [ ] **Step 3: Commit (if changed)**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): sync security note with architecture.md github.com swap"
```

### Task 10: Push + PR for agent-smith Phase B

**Files:** none

- [ ] **Step 1: Push**

```bash
cd /workspace/agent-smith
git push -u origin feat/git-stub-credentials
```

- [ ] **Step 2: Open PR** (note: this PR creates a workflow file? No — it only touches setup.sh + docs. Should push cleanly without Contents-API workaround.)

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/agent-smith \
  --head feat/git-stub-credentials --base main \
  --title "[dev] feat(setup): write stub git credential, let iron-proxy swap at egress" \
  --body "$(cat <<'EOF'
## What
Pod no longer holds a real GitHub PAT. `setup.sh` writes `stub-token-github` into `.git-credentials`; iron-proxy decodes the Authorization header on github.com requests, swaps the stub for the real PAT in its secret store, re-encodes, forwards.

## Companion homelab PR
**Must merge + deploy FIRST**: <homelab PR number from Task 5> — adds the iron-proxy config that makes the swap happen. Without it, pushes fail with `stub-token-github` literally reaching github.com.

## Verify after deploy
```
# from inside an agent pod:
git push origin <any-branch>   # should succeed with the stub
```

Spec: docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md
Research: docs/research/2026-05-27-iron-proxy-deepdive.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Task 11: Bump agent-smith chart version

**Files:**
- Modify: `/workspace/agent-smith/charts/agent-smith/Chart.yaml`

- [ ] **Step 1: Bump patch number** (current → next, e.g. 0.1.22 → 0.1.23). `appVersion` to match.

- [ ] **Step 2: Commit on the same `feat/git-stub-credentials` branch** (extends the PR):

```bash
git add charts/agent-smith/Chart.yaml
git commit -m "chore(release): v0.1.23 — stub git creds with iron-proxy swap"
git push
```

### Task 12: Deploy + verify in pods

**Files:** none (operational)

- [ ] **Step 1: Wait for both PRs to merge.** Homelab first, then agent-smith.

- [ ] **Step 2: Bump the agent-smith HelmRelease in homelab** (separate small PR by InfraBot, or `.claude/references/bump-homelab-chart.sh --version 0.1.23 --agent devbot,infrabot`).

- [ ] **Step 3: Wait for Flux reconcile + pod restart.** Confirm pods are Ready.

- [ ] **Step 4: Smoke test from inside devbot pod**

```bash
# create a tiny branch and push (NOT touching workflow files — that's a separate stricter check)
git -C /workspace/agent-smith checkout -b chore/smoke-iron-proxy-swap
date > /tmp/smoke && cp /tmp/smoke smoke.txt
git -C /workspace/agent-smith add smoke.txt
git -C /workspace/agent-smith commit -m "chore: smoke test for iron-proxy github swap"
git -C /workspace/agent-smith push -u origin chore/smoke-iron-proxy-swap
# expected: branch pushed cleanly, no auth errors

# cleanup
SSL_CERT_FILE=/root/iron-proxy.crt gh api -X DELETE repos/sherodtaylor/agent-smith/git/refs/heads/chore/smoke-iron-proxy-swap
git -C /workspace/agent-smith checkout main && git -C /workspace/agent-smith branch -D chore/smoke-iron-proxy-swap
```

- [ ] **Step 5: Workflow-file smoke** (the original failure mode — must now succeed too)

```bash
# Try the workflows PR push that failed earlier
git -C /workspace/agent-smith fetch origin
git -C /workspace/agent-smith checkout -b chore/smoke-workflow-push origin/main
mkdir -p /workspace/agent-smith/.github/workflows
echo 'name: smoke' > /tmp/probe-wf.yml
echo 'on: [workflow_dispatch]' >> /tmp/probe-wf.yml
echo 'jobs: {smoke: {runs-on: ubuntu-latest, steps: [{run: echo hi}]}}' >> /tmp/probe-wf.yml
cp /tmp/probe-wf.yml /workspace/agent-smith/.github/workflows/smoke.yml
git -C /workspace/agent-smith add -f .github/workflows/smoke.yml
git -C /workspace/agent-smith commit -m "chore: smoke workflow push"
git -C /workspace/agent-smith push -u origin chore/smoke-workflow-push
# expected: branch pushed cleanly — iron-proxy swapped in the real PAT,
# which has workflow scope, so the receive-pack check accepts.

# cleanup
SSL_CERT_FILE=/root/iron-proxy.crt gh api -X DELETE repos/sherodtaylor/agent-smith/git/refs/heads/chore/smoke-workflow-push
git -C /workspace/agent-smith checkout main && git -C /workspace/agent-smith branch -D chore/smoke-workflow-push
```

- [ ] **Step 6: Confirm `.git-credentials` holds the stub** (not the real PAT)

```bash
grep -c stub-token-github /root/.git-credentials
# expected: 1
```

If either smoke fails, document the failure and roll back agent-smith's chart version (the prior release still writes the real PAT and works). Do NOT roll back homelab — leaving the iron-proxy config in place is benign.

---

## Phase C — Cleanup (optional, after 1 week green)

### Task 13: Retire `SWARM_GITHUB_TOKEN` from Infisical if no other consumer exists

**Files:** none

- [ ] **Step 1: Grep both repos for references**

```bash
grep -rln 'SWARM_GITHUB_TOKEN' /workspace/homelab /workspace/agent-smith 2>/dev/null | head -10
```

If the only references are in commit messages and historical docs, the Infisical row can be deleted. Otherwise keep it.

- [ ] **Step 2: Manual UI delete** (Sherod-only step) — log into Infisical, delete the `SWARM_GITHUB_TOKEN` row. Verify pod restart doesn't break anything (the only consumer was the agent ExternalSecrets we already removed in T4).

No commit — Infisical UI step.

---

## Self-review (done before handoff)

- **Spec coverage:**
  - §3 design decisions → encoded in T2 (Q3 require:false, Q5 same block both hosts) + T7 (stub naming) + T4 (retire GIT_GITHUB_TOKEN)
  - §4.1 iron-proxy ConfigMap → T2
  - §4.2 iron-proxy ExternalSecret → T3
  - §4.3 agent ExternalSecrets → T4
  - §4.4 setup.sh → T7
  - §4.5 architecture.md → T8
  - §4.6 CLAUDE.md → T9
  - §5 rollout sequencing → T5, T6 (Phase A gate), T10-T12 (Phase B after gate)
  - §6 testing → T6 (iron-proxy smoke), T12 (agent-smith smoke including the original workflow-file failure mode)
  - §8 open questions → addressed in T1 (schema discovery), T3 (existing key reuse), T6 (restart trigger)
- **Placeholder scan:** zero TBD/FIXME in steps. Every step has the actual edit / command / expected output.
- **Type / config consistency:** `stub-token-github` literal used identically in T2, T7, T12. `GITHUB_PAT` env name used in T2 + referenced in T3. ConfigMap key shape (`proxy_value_from_env`) flagged as "verify in T1, use whichever matches existing config."
- **Ambiguity:** explicit sequencing gate (T6 must pass before T7+); explicit rollback path (chart version revert); explicit failure mode if iron-proxy swap is misconfigured.
