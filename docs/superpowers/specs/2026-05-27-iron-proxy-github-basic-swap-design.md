# Iron-proxy github.com Basic-Auth swap — design

**Status:** approved 2026-05-27 (Sherod, via Matrix brainstorm)
**Owner:** DevBot
**Last updated:** 2026-05-27

A config-only change to iron-proxy so `git push` to github.com works
from inside agent-smith pods using a stub credential in
`.git-credentials`. Iron-proxy already implements Basic-Auth header
swap (`internal/transform/secrets/secrets.go:493-527`,
`TestSecrets_BasicAuthSwap`); this spec wires it up for github.com and
flips the agent-smith setup script to write the stub instead of the
real PAT.

**Research:** `docs/research/2026-05-27-iron-proxy-deepdive.md`

---

## 1. Goal

`git push origin <branch>` from inside any agent-smith pod succeeds
without the pod holding any real GitHub credential. The real PAT lives
only in iron-proxy's secret store; iron-proxy decodes the Basic-Auth
header, replaces the stub with the real token, re-encodes, and
forwards to github.com. Streaming packfiles are not buffered.

Two motivations:
- Today the pod holds the real PAT in `.git-credentials`. Pod
  compromise leaks the PAT and (per the workflow-scope debug
  session) can push workflow files. Iron-proxy is the right network
  boundary for credential hygiene; nothing in the pod should hold a
  real GitHub token.
- The current setup confused several debugging cycles
  ("update SWARM_GITHUB_TOKEN, restart, ESO-sync, restart again") that
  iron-proxy ownership eliminates entirely.

## 2. Non-goals

- iron-proxy code changes — the swap implementation already exists.
- Swap for `*.anthropic.com` (already covered by the existing config).
- Multi-org support — single `sherodtaylor` PAT.
- Encrypting the stub or making it pod-unique.

---

## 3. Design decisions (per Sherod's "go with recommended" on
2026-05-27)

| Q | Decision | Why |
|---|---|---|
| 1 — one PAT or split | **One PAT** (`SWARM_GITHUB_TOKEN`) covers both `gh api` Bearer + `git push` Basic | One secret to rotate; same identity for both auth flows |
| 2 — stub naming | **`stub-token-github`** | Matches existing `access-token-stub`, `refresh-token-stub` convention in `agents/_shared/.credentials.json` |
| 3 — swap failure mode | **Pass-through** when stub not present | Operator-facing tools (humans running `gh` from a `kubectl exec`) shouldn't need to know iron-proxy internals; if their cred ≠ stub, iron-proxy lets it through to github.com which then authenticates them normally |
| 4 — retire `GIT_GITHUB_TOKEN` | **Yes, retire entirely** | Cleaner; no tool routes around iron-proxy today |
| 5 — LFS / raw.githubusercontent.com | **Same swap config block** covers both `github.com` and `raw.githubusercontent.com` | One config entry per host; the swap logic is identical |
| 6 — NATS audit mirror | **Skip for now** | No consumer; would add noise without value |

---

## 4. Changes by file

### 4.1 homelab — iron-proxy config

**File:** `k8s/infrastructure/config/agent-swarm/iron-proxy/configmap.yaml`

Add a new host rule entry with a `secrets` transform set in
basic-auth-aware mode. Concrete shape (per iron-proxy's existing
config schema documented at `iron-proxy.example.yaml:121-129` and the
analog `*.anthropic.com` entry already in this ConfigMap):

```yaml
hosts:
  # ...existing api.anthropic.com / api.github.com Bearer swap entries unchanged...

  - name: github.com
    upstream: https://github.com
    transforms:
      - kind: secrets
        config:
          require: false        # pass-through if stub absent (Q3)
          match_body: false     # header-only, keeps git-receive-pack
                                # packfiles streamed (research §B)
          replacements:
            - stub_value: stub-token-github
              proxy_value_from_env: GITHUB_PAT   # real PAT, see §4.3

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

(Exact YAML keys match what's already in the file for the
`*.anthropic.com` entry — preserve indentation + key naming.)

### 4.2 homelab — iron-proxy secret (existing or new)

**File:** `k8s/infrastructure/config/agent-swarm/iron-proxy/externalsecret.yaml`

Verify the existing ExternalSecret pulls a `GITHUB_PAT` (or whatever
the analog key is for the existing api.github.com Bearer swap, if
any). If a real PAT is not already mounted into iron-proxy via that
ExternalSecret, add one entry:

```yaml
data:
  # ...existing entries...
  - secretKey: GITHUB_PAT
    remoteRef:
      key: IRONPROXY_GITHUB_PAT   # new Infisical key — see §6 rollout
```

If `IRONPROXY_GITHUB_PAT` overlaps semantically with the existing
`SWARM_GITHUB_TOKEN` Infisical key (per decision Q1, single PAT), the
spec aliases them: iron-proxy reads the same upstream value, just
under a different name in iron-proxy's env. The Infisical UI should
have ONE row holding the actual PAT; the two ExternalSecrets reference
the same key under different `remoteRef.key` names if the existing
convention is per-app namespacing, OR share a key directly.

(Implementer: choose the path consistent with the existing
ExternalSecret patterns in homelab. Document the choice in the PR.)

### 4.3 homelab — agent ExternalSecrets

**Files:**
- `k8s/apps/agents/externalsecret-devbot.yaml`
- `k8s/apps/agents/externalsecret-infrabot.yaml`

**Delete** the `GIT_GITHUB_TOKEN` entry from both (decision Q4 —
retire entirely):

```yaml
# BEFORE
- secretKey: GIT_GITHUB_TOKEN
  remoteRef:
    key: SWARM_GITHUB_TOKEN

# AFTER: removed
```

This stops the agent k8s Secrets from carrying a real PAT.

### 4.4 agent-smith — setup.sh

**File:** `scripts/setup.sh`

Replace the `_GIT_TOKEN` resolution + `.git-credentials` write
(currently lines ~103-112) with a stub write:

```bash
# git HTTPS Basic Auth is swapped at the network boundary by
# iron-proxy: the stub `stub-token-github` here is decoded from the
# b64 Authorization header and replaced with the real PAT held in
# iron-proxy's secret store before the request hits github.com. See
# docs/architecture.md#security--iron-proxy and the design at
# docs/superpowers/specs/2026-05-27-iron-proxy-github-basic-swap-design.md.
git config --global user.name  "${AGENT_NAME}"
git config --global user.email "${AGENT_NAME}@lab.sherodtaylor.dev"
git config --global http.sslCAInfo "${HOME}/iron-proxy.crt"
git config --global credential.helper store
printf 'https://x-access-token:stub-token-github@github.com\n' \
  > "${HOME}/.git-credentials"
chmod 600 "${HOME}/.git-credentials"
echo "[setup] git credentials configured (stub — iron-proxy swaps at egress)"
```

Note the deletions:
- `_GIT_TOKEN="${GIT_GITHUB_TOKEN:-${GITHUB_TOKEN}}"` — gone
- The `if [ -n "${_GIT_TOKEN:-}" ]` guard — gone (stub always present)
- Use of `GITHUB_TOKEN` env var — kept only for `gh` API calls (still
  routes through iron-proxy's existing api.github.com Bearer swap)

### 4.5 agent-smith — architecture.md

**File:** `docs/architecture.md`

The current `## Security — iron-proxy` section says (per the
research) that iron-proxy "cannot swap Basic Auth"; remove that
sentence and replace with a paragraph documenting that github.com
Basic Auth IS now swapped, citing this spec.

### 4.6 agent-smith — CLAUDE.md (project root, optional but recommended)

**File:** `CLAUDE.md`

The "Security model" section likely has the same stale claim — update
in lockstep with §4.5.

---

## 5. Rollout sequencing (load-bearing)

**Iron-proxy must be configured to swap BEFORE setup.sh starts writing
stubs**, or pushes will fail with the literal string
`stub-token-github` hitting github.com (which returns 401).

Order:

1. Land homelab PR (§4.1, §4.2, §4.3) — Flux reconciles iron-proxy
   ConfigMap. Iron-proxy pod restart picks up the new config.
2. Verify swap is live: from a fresh pod (or by editing `.git-credentials`
   to the stub manually), `git ls-remote https://github.com/sherodtaylor/agent-smith.git`
   succeeds. If it 401s, iron-proxy config is wrong; abort.
3. **Only after #2 passes**: land agent-smith PR (§4.4, §4.5, §4.6).
4. Bump agent-smith chart version, deploy. Agent pods restart.
   `setup.sh` writes the stub. `git push` from inside a pod (touching
   a workflow file) succeeds end-to-end.
5. (Optional cleanup) After 1 week of green operation, delete the
   `SWARM_GITHUB_TOKEN` Infisical entry IF no other consumer needed
   it (Q4 says retire — verify nothing else references it before
   deletion).

If anything goes wrong at step 4, roll back the agent-smith chart (the
old version still writes the real PAT and the ExternalSecret still
holds it). The k8s Secret value lags ESO refresh by up to 1h, so a
revert is non-instant.

## 6. Testing

### 6.1 Iron-proxy side

- Iron-proxy already has `TestSecrets_BasicAuthSwap` and
  `TestSecrets_BasicAuthAllHeaders` in `internal/transform/secrets/secrets_test.go`
  covering the decode/replace/encode round-trip. No NEW unit tests
  needed — the change is config, not code.
- After the ConfigMap merges, smoke from an agent pod:
  ```
  curl -v -H "Authorization: Basic $(printf 'x-access-token:stub-token-github' | base64 -w0)" \
    https://api.github.com/user
  ```
  Expected: `200 OK` with the bot account's user info (iron-proxy
  swapped the stub for the real PAT before egress).

### 6.2 Agent-smith side

- `bash -n scripts/setup.sh` after the change (syntax).
- Manual smoke after deploy: from inside a pod,
  ```
  git push origin <some-branch-that-touches-.github/workflows>
  ```
  must succeed. The token GitHub sees is the real PAT from
  iron-proxy's secret store, which has workflow scope.

### 6.3 Negative: what should NOT happen

- `git push` from outside iron-proxy's path (impossible from pod, but
  worth documenting) would fail because the stub isn't valid.
- Operators running `gh` interactively from `kubectl exec` see `gh`
  use `GITHUB_TOKEN` env var (still iron-proxy stub) — works via the
  existing Bearer swap on api.github.com. Unchanged behaviour.

---

## 7. Out of scope

- Per-pod PAT (one real token serves both bots).
- Non-github Basic Auth swap (e.g. gitlab, bitbucket) — add when
  needed.
- Iron-proxy code changes — none required.
- Stub rotation — the stub is a literal string; it never rotates.
  The REAL PAT in iron-proxy's secret store rotates as needed via the
  existing Infisical workflow.

---

## 8. Open implementation questions

Address during writing-plans, not blocking spec approval.

1. **Existing iron-proxy ExternalSecret** — does it already pull the
   `SWARM_GITHUB_TOKEN` (or analog) into iron-proxy's env? If yes, just
   reuse. If no, add an entry — choose key name consistent with the
   ExternalSecret's existing naming convention.
2. **Iron-proxy pod restart trigger** — does the iron-proxy Deployment
   have a configmap-checksum annotation so Flux reconcile auto-restarts
   on ConfigMap change? If not, the implementer adds a
   `kubectl rollout restart deployment/iron-proxy -n agent-infra`
   step in the rollout.
3. **Verify iron-proxy supports `proxy_value_from_env`** vs an
   alternate key name like `proxy_value_env`/`fromEnv`. Confirm in
   `iron-proxy.example.yaml` / the existing ConfigMap entries for
   `*.anthropic.com` before writing the new entry.
