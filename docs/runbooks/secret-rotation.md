# Runbook: Rotate a credential

## Reference scripts

```bash
.claude/references/force-eso-sync.sh --help
.claude/references/restart-agent.sh --help
.claude/references/restart-ironproxy.sh
```

Use when rotating a Matrix access token, GitHub PAT, Claude OAuth token, or
the iron-proxy CA. Each credential has a slightly different blast radius and
restart requirement.

## The credential map

| Credential | Lives in | Read by | Pod restart needed? |
|---|---|---|---|
| `MATRIX_ACCESS_TOKEN` | Infisical → `<agent>-secrets` → env | Matrix channel plugin at startup | Yes (channel plugin only reads `.env` once) |
| `MATRIX_HOMESERVER_URL`, `MATRIX_BOT_USER_ID` | Infisical → `<agent>-secrets` → env | Matrix channel plugin at startup | Yes |
| `MATRIX_ALLOWED_USERS` | Infisical → env | `setup.sh` writes `access.json` once | Yes |
| `GITHUB_TOKEN` (proxy) | Infisical → env | `gh`, REST API calls; iron-proxy swaps | No — iron-proxy rotates the real PAT independently |
| `GIT_GITHUB_TOKEN` (real PAT) | Infisical → env (only when iron-proxy can't swap, e.g. git HTTPS Basic Auth) | `git` HTTPS clone/push | Yes |
| Claude `CLAUDE_CODE_OAUTH_TOKEN` (real) | Infisical → `iron-proxy-upstream-secrets` → iron-proxy env | iron-proxy at startup | Yes — restart **iron-proxy**, not the agents |
| `IRON_PROXY_CA_CRT` | Infisical → `<agent>-secrets` → env | `setup.sh` writes to `update-ca-certificates` + `~/iron-proxy.crt` | Yes (init container only sees env once) |
| iron-proxy domain allowlist | iron-proxy ConfigMap | iron-proxy at startup | Yes — restart **iron-proxy** |

## Preconditions

- Write access to Infisical for the relevant secret paths.
- `kubectl` access to `agents` and `agent-infra`.
- Awareness that ESO refresh interval is **1 hour** by default — the k8s
  Secret won't update instantly after you change Infisical.

## Steps

### 1. Update the source of truth (Infisical)

Update the value in Infisical. **Don't echo the new value into a terminal that
might end up in shell history.** Use the Infisical UI or:

```bash
infisical secrets set --env=prod /agents/<name>/MATRIX_ACCESS_TOKEN \
  --value "$(read -rs t; echo "$t")"   # password-style read
```

### 2. Force ESO to re-sync

```bash
.claude/references/force-eso-sync.sh --name <name>-secrets --namespace agents
# For the iron-proxy token:
.claude/references/force-eso-sync.sh --name iron-proxy-upstream-secrets --namespace agent-infra
```

### 3. Restart the right pod

| Credential type | Restart |
|---|---|
| Matrix anything | `.claude/references/restart-agent.sh --agent <name>` |
| `GIT_GITHUB_TOKEN` | `.claude/references/restart-agent.sh --agent <name>` |
| `IRON_PROXY_CA_CRT` | `.claude/references/restart-agent.sh --agent <name>` |
| Claude OAuth (`CLAUDE_CODE_OAUTH_TOKEN`) | `.claude/references/restart-ironproxy.sh` |
| iron-proxy domain allowlist | `.claude/references/restart-ironproxy.sh` |
| `GITHUB_TOKEN` (proxy stub) — there is no reason to rotate this, it's a literal string | n/a |

Wait for the pod(s) to come Ready:

```bash
kubectl get pods -n agents -w   # for an agent restart
kubectl rollout status deployment/iron-proxy -n agent-infra
```

### 4. Verify

#### Matrix token rotation

Tag the bot in `#dev`:

```
@<name> ping
```

Expected: 👀 within 2 s, reply within 30 s. If the bot never reacts, the new
token is wrong or the user the token was minted for no longer has access to
the room.

```bash
kubectl logs -n agents <name>-0 | grep -iE 'matrix|channel' | tail -20
```

#### GitHub PAT rotation (`GIT_GITHUB_TOKEN`)

```bash
kubectl exec -n agents <name>-0 -- \
  git -C /workspace/homelab pull --ff-only
```

Should succeed. If `fatal: Authentication failed`, the new PAT is wrong or
doesn't have repo scope.

#### Claude OAuth rotation (via iron-proxy)

```bash
# Send any prompt to the agent and watch for 200s
kubectl logs -n agents <name>-0 --tail=200 | grep -E '200|401' | tail -20
```

If you see only 401s after the iron-proxy restart, the new Claude OAuth
token is wrong (or the subscription tier downgraded). Go to
[`oauth-401.md`](oauth-401.md).

#### iron-proxy CA rotation

Trickier — the CA must be updated in **both** iron-proxy (so it serves the
new cert) and every agent pod (so it trusts it). Coordinate:

1. Generate new CA, update iron-proxy's signing material + restart it.
2. Update `IRON_PROXY_CA_CRT` in Infisical.
3. ESO refreshes the agent secrets.
4. Restart every agent pod.

There's a window between (1) and (4) where existing agents trust the **old**
CA but iron-proxy is serving the **new** one — all egress fails during that
window. Plan a maintenance window.

## Rollback

```bash
# Revert the Infisical value to the previous one
infisical secrets set --env=prod /agents/<name>/MATRIX_ACCESS_TOKEN \
  --value "$(read -rs t; echo "$t")"

# Force re-sync and restart
kubectl annotate externalsecret -n agents <name>-secrets \
  force-sync="$(date +%s)" --overwrite
kubectl delete pod -n agents <name>-0
```

For Claude OAuth: revert in Infisical and restart iron-proxy. The previous
token is good until its own expiry — Anthropic doesn't immediately invalidate
on rotation.

## Verify (full pass)

```bash
kubectl get pods -n agents
kubectl get pods -n agent-infra -l app=iron-proxy

# Send a tag to every agent in #dev; all should 👀 + reply
```

## Why this works

ESO is the single source-of-truth boundary between Infisical and the cluster.
Pods read env at startup, so a Secret change requires a pod restart to take
effect. iron-proxy is its own restartable unit: rotating Claude's OAuth
doesn't touch the agents, and rotating an agent's Matrix token doesn't touch
iron-proxy. The CA rotation is the only one that couples the two — that's
why it gets a maintenance window.
