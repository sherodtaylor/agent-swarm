# Iron-proxy github.com Basic-Auth swap — design

**Status:** approved 2026-05-27 (Sherod, via Matrix brainstorm); revised
2026-05-27 after Phase A inventory + live probes shrank the scope.
**Owner:** DevBot
**Last updated:** 2026-05-27

A config + scripts change so `git push` to github.com works from inside
agent-smith pods using a stub credential in `.git-credentials`. The
real PAT lives only in iron-proxy's env. **Iron-proxy already
implements Basic-Auth header swap AND is already configured for
`github.com` + `*.github.com`** (`homelab/k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml:60-70`,
stub `proxy-token-github`, source `env:GITHUB_TOKEN` ← Infisical
`SWARM_GITHUB_TOKEN` via existing ExternalSecret).

This spec therefore drops the proposed homelab config additions and
focuses on the actual remaining work: **flip agent-smith's setup.sh to
write the stub instead of the real PAT, and retire the now-dead
`GIT_GITHUB_TOKEN` from agent ExternalSecrets**.

**Research:** `docs/research/2026-05-27-iron-proxy-deepdive.md`

**Live probes that confirmed the new scope (recorded for future
auditors):**

| Probe | Result | Implication |
|---|---|---|
| `Authorization: Basic <b64(x-access-token:proxy-token-github)>` to `git ls-remote` of `github.com/sherodtaylor/agent-smith.git` | `200 OK`, ref SHA returned | iron-proxy IS swapping basic auth on github.com today |
| `Authorization: Bearer proxy-token-github` to `api.github.com/user` | `200 OK`, `X-Oauth-Scopes: admin:public_key, gist, read:org, read:packages, repo` (NO `workflow`) | iron-proxy's `GITHUB_TOKEN` env holds a stale pre-rotation PAT |
| `Authorization: Bearer <real-PAT-from-.git-credentials>` to `api.github.com/user` | `200 OK`, `X-Oauth-Scopes: ..., workflow, ...` (HAS `workflow`) | the rotated `SWARM_GITHUB_TOKEN` value DOES have workflow scope — iron-proxy just needs to restart to pick it up |

---

## 1. Goal

`git push origin <branch>` from inside any agent-smith pod succeeds
without the pod holding any real GitHub credential. The real PAT lives
only in iron-proxy's env (sourced from Infisical via the existing
`iron-proxy-upstream-secrets` ExternalSecret). Streaming packfiles are
not buffered (header-only swap; `match_headers: ["Authorization"]`).

Two motivations:
- Today the pod holds the real PAT in `.git-credentials`. Pod
  compromise leaks the PAT and (per the workflow-scope debug session)
  can push workflow files. Iron-proxy is the right network boundary
  for credential hygiene; nothing in the pod should hold a real
  GitHub token.
- The current setup confused several debugging cycles (rotate
  SWARM_GITHUB_TOKEN, restart, ESO-sync, restart again) that
  iron-proxy-only ownership eliminates entirely.

## 2. Non-goals

- iron-proxy code changes — swap is already implemented.
- New iron-proxy config — `github.com` + `*.github.com` entry already
  exists; `proxy-token-github` stub already in place.
- Swap for `*.anthropic.com` (already covered).
- Multi-org support — single `sherodtaylor` PAT.
- Encrypting the stub or making it pod-unique.

---

## 3. Design decisions (per Sherod's "go with recommended" on
2026-05-27)

| Q | Decision | Why |
|---|---|---|
| 1 — one PAT or split | **One PAT** (`SWARM_GITHUB_TOKEN`) covers both `gh api` Bearer + `git push` Basic. Already true today. | One secret to rotate; same identity for both auth flows |
| 2 — stub naming | **`proxy-token-github`** (matches existing convention, NOT `stub-token-github` as originally proposed). | Already in iron-proxy config; consistent with `proxy-token-*` family |
| 3 — swap failure mode | **Pass-through** when stub not present. Already true today. | Operator-facing tools (humans running `gh` from a `kubectl exec`) shouldn't need iron-proxy internals |
| 4 — retire `GIT_GITHUB_TOKEN` | **Yes, retire entirely** | Cleaner; no tool routes around iron-proxy |
| 5 — LFS / raw.githubusercontent.com | **Add a new rule for `raw.githubusercontent.com`** to the existing `github.com` entry's `rules:` list (raw is NOT a subdomain of github.com so the `*.github.com` wildcard doesn't cover it). | Single config block, one rule per host |
| 6 — NATS audit mirror | **Skip for now** | No consumer; would add noise without value |

---

## 4. Changes by file

### 4.1 homelab — iron-proxy ConfigMap (small addition for raw)

**File:** `k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml`

The existing entry (lines 60-70) reads:

```yaml
            # GitHub token: agents now use the real token for git HTTPS (Basic Auth).
            # require: false so real tokens pass through without rejection.
            - source:
                type: env
                var: GITHUB_TOKEN
              proxy_value: "proxy-token-github"
              match_headers: ["Authorization"]
              require: false
              rules:
                - host: "github.com"
                - host: "*.github.com"
```

Append one host rule for `raw.githubusercontent.com`:

```yaml
              rules:
                - host: "github.com"
                - host: "*.github.com"
                - host: "raw.githubusercontent.com"
```

Update the comment to reflect the post-change reality (pod-side credentials retired):

```yaml
            # GitHub token swap — agent pods send a stub `proxy-token-github`
            # in Authorization (Bearer or Basic), iron-proxy decodes b64 if
            # needed, replaces with the real PAT from $GITHUB_TOKEN, re-encodes,
            # forwards. require: false so any non-stub auth (e.g. an operator
            # running `gh` directly) passes through unchanged.
```

### 4.2 homelab — iron-proxy restart

The existing iron-proxy Deployment has no auto-restart-on-configmap-change
annotation. Manual rollout step is required after the ConfigMap merges:

```bash
kubectl rollout restart deployment/iron-proxy -n agent-infra
kubectl rollout status deployment/iron-proxy -n agent-infra --timeout=60s
```

(Operationally, this ALSO needs to happen IMMEDIATELY today to pick up
the post-rotation `SWARM_GITHUB_TOKEN` value with `workflow` scope —
independent of any config change.)

### 4.3 homelab — agent ExternalSecrets cleanup

**Files:**
- `k8s/apps/agents/externalsecret-devbot.yaml`
- `k8s/apps/agents/externalsecret-infrabot.yaml`

Delete the `GIT_GITHUB_TOKEN` entry from both:

```yaml
# BEFORE
- secretKey: GIT_GITHUB_TOKEN
  remoteRef:
    key: SWARM_GITHUB_TOKEN

# AFTER: removed
```

After this lands + ESO refreshes, pod env no longer carries the real
PAT.

### 4.4 agent-smith — setup.sh

**File:** `scripts/setup.sh`

Replace the `_GIT_TOKEN` resolution + conditional `.git-credentials`
write (currently around lines 103-112) with a stub write:

```bash
# git / gh auth — both paths route through iron-proxy as the credential
# boundary.
#   - `gh` reads GITHUB_TOKEN env (stub `proxy-token-github`); iron-proxy
#     swaps it on Bearer calls to api.github.com.
#   - `git push/pull/clone` over HTTPS uses Basic Auth with the same stub
#     in .git-credentials; iron-proxy decodes the b64, swaps the stub for
#     the real PAT, re-encodes, and forwards. No real PAT ever lives in
#     this pod.
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

Note the deletions:
- `_GIT_TOKEN="${GIT_GITHUB_TOKEN:-${GITHUB_TOKEN}}"` — gone
- The `if [ -n "${_GIT_TOKEN:-}" ]` guard — gone (stub always present)
- Use of `GITHUB_TOKEN` env var inside setup.sh for git — gone
  (GITHUB_TOKEN env is still the stub `proxy-token-github` for `gh`'s
  Bearer auth; that path is unchanged)

### 4.5 agent-smith — docs/architecture.md

Find the section that describes iron-proxy + credentials. Remove any
language asserting iron-proxy "cannot swap" Basic Auth or that
`.git-credentials` holds the real PAT; replace with the new model:
basic + bearer both swap at egress, pod holds stubs only.

### 4.6 agent-smith — CLAUDE.md (project root)

If the security section carries the same stale claim, update in
lockstep with §4.5.

---

## 5. Rollout sequencing (load-bearing)

**Iron-proxy's `GITHUB_TOKEN` env must hold a workflow-scoped PAT
BEFORE agent-smith starts writing the stub**, or workflow-file pushes
fail.

Order:

1. **Immediate (today, ops):** `kubectl rollout restart deployment/iron-proxy -n agent-infra` so iron-proxy picks up the already-rotated `SWARM_GITHUB_TOKEN` value with workflow scope. Smoke: `curl -H 'Authorization: Bearer proxy-token-github' https://api.github.com/user` from any agent pod and confirm `X-Oauth-Scopes` includes `workflow`.
2. **Phase A PR (homelab):** §4.1 (add raw rule + update comment) + §4.3 (drop GIT_GITHUB_TOKEN from agent ExternalSecrets). Flux reconciles iron-proxy and agent Secrets.
3. **Phase B PR (agent-smith):** §4.4 + §4.5 + §4.6. Chart version bump.
4. **Deploy Phase B:** bump HelmRelease versions in homelab; Flux reconciles; agent pods restart with the new setup.sh writing the stub.
5. **Verify end-to-end:** from devbot pod, push a branch that touches `.github/workflows/*.yml` — succeeds via iron-proxy swap.

Rollback path: if step 5 fails, the previous agent-smith chart still works (writes the real PAT). Revert the chart version; the homelab cleanup in step 2 only narrows what's in pod env, doesn't break behaviour by itself.

## 6. Testing

### 6.1 Iron-proxy side

- Iron-proxy already has `TestSecrets_BasicAuthSwap` /
  `TestSecrets_BasicAuthAllHeaders` covering the swap. No new unit
  tests.
- Smoke (after step 1 of rollout):
  ```bash
  # From an agent pod:
  curl -sI -H 'Authorization: Bearer proxy-token-github' https://api.github.com/user
  # expected: 200 OK, X-Oauth-Scopes includes `workflow`
  ```

### 6.2 Agent-smith side

- `bash -n scripts/setup.sh` (syntax).
- Manual smoke after deploy:
  ```bash
  # from inside a pod:
  cat /root/.git-credentials | sed 's|:[^@]*@|:<stub>@|g'
  # expected: https://x-access-token:<stub>@github.com (literal stub-token-github)
  git push origin <some-branch-touching-.github/workflows/*.yml>
  # expected: success
  ```

### 6.3 Regression check

- `gh api repos/sherodtaylor/agent-smith` should still work from the
  pod (uses GITHUB_TOKEN env stub, iron-proxy Bearer swap path —
  unchanged by this spec).

---

## 7. Out of scope

- Per-pod PAT (one real token serves both bots).
- Non-github Basic Auth swap (e.g. gitlab, bitbucket) — add when
  needed.
- iron-proxy code changes — none required.
- Stub rotation — the stub is a literal string; never rotates.

---

## 8. Open implementation questions

Nothing blocking. Plan handles the remaining concrete questions:
- How to verify iron-proxy has the workflow-scoped PAT after restart
  (step 1 smoke command).
- Sequencing rollback (chart-version revert).
