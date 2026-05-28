---
title: Deployment
description: First install, upgrade, rollback, and the common failure modes you'll hit along the way.
---

End-to-end deployment of one agent into a Kubernetes cluster. Use
[Getting Started](/agent-smith/getting-started/) as the reference (what
the chart does, what every value means); this page is the tutorial
(what to type, in what order, to go from zero to a Matrix bot that
ships PRs).

The reference deployment is k3s + Flux + iron-proxy. The chart will
install onto any Kubernetes cluster ≥ 1.27 with a default
StorageClass.

---

## Before you start

You need these in hand, or you'll bounce off install:

| What | Why | How |
|---|---|---|
| **A Matrix bot account + access token** | The agent reads its work queue from a Matrix room and replies there. | Register the bot on your homeserver (or `matrix.org`), then `curl -s -XPOST https://<homeserver>/_matrix/client/r0/login -d '{"type":"m.login.password","user":"...","password":"..."}'` to get the token. |
| **A GitHub PAT with `repo` + `workflow`** | The agent clones, pushes, and edits workflow files. Without `workflow`, every push touching `.github/workflows/*.yml` is rejected. | https://github.com/settings/tokens → generate a classic PAT, both scopes. |
| **iron-proxy deployed** | The agent never holds real credentials at rest. iron-proxy intercepts egress and swaps stub tokens for real ones. | https://github.com/sherodtaylor/iron-proxy — a small Helm release, see its README. Its ConfigMap holds the real PAT + Matrix token; the agent only ever sees stub values. |
| **A Kubernetes secret with the stubs** | The chart references it by name; it must exist before the StatefulSet boots. | See [Step 2](#step-2-create-the-agent-secret) below. |
| **(Optional) NATS** | Cross-agent event bus + audit log for multi-agent setups. Single-agent installs can skip. | Run any NATS server reachable from the pod; pass `nats.url` in chart values. |

If you don't yet have iron-proxy: install agent-smith with `ironProxy.enabled=false` for an initial smoke test, then add iron-proxy in a follow-up upgrade. The agent will hold real credentials in pod env until then — fine for a sandbox, **not for anything you care about**.

---

## Step 1 — namespace

```bash
kubectl create namespace agents
```

Everything else in this guide assumes `-n agents`.

---

## Step 2 — create the agent secret

The chart **does not** create this Secret. You point it at one that
already exists (created by hand, by ExternalSecrets, sealed-secrets,
SOPS — anything). The required keys are:

| Key | Value |
|---|---|
| `MATRIX_HOMESERVER_URL` | e.g. `https://matrix.org` |
| `MATRIX_ACCESS_TOKEN` | The bot's access token from "Before you start." |
| `GITHUB_TOKEN` | **Stub** value when iron-proxy is enabled (e.g. `proxy-token-github`). Real PAT only if `ironProxy.enabled=false`. |
| `GIT_GITHUB_TOKEN` | Same stub/PAT as `GITHUB_TOKEN` — git HTTPS Basic Auth path uses this. |
| `IRON_PROXY_CA_CRT` | iron-proxy's MITM CA, PEM-encoded. iron-proxy publishes it as a Secret; copy the value here. Required when `ironProxy.enabled=true`. |
| `CLAUDE_ACCESS_TOKEN` / `CLAUDE_REFRESH_TOKEN` / `CLAUDE_EXPIRES_AT` | The agent's Claude account credentials. Captured by running `claude auth login` once on any host and reading from `~/.claude/.credentials.json`. |

Quick imperative form:

```bash
kubectl create secret generic devbot-secrets -n agents \
  --from-literal=MATRIX_HOMESERVER_URL='https://matrix.org' \
  --from-literal=MATRIX_ACCESS_TOKEN='syt_...' \
  --from-literal=GITHUB_TOKEN='proxy-token-github' \
  --from-literal=GIT_GITHUB_TOKEN='proxy-token-github' \
  --from-file=IRON_PROXY_CA_CRT=/path/to/iron-proxy-ca.pem \
  --from-literal=CLAUDE_ACCESS_TOKEN='...' \
  --from-literal=CLAUDE_REFRESH_TOKEN='...' \
  --from-literal=CLAUDE_EXPIRES_AT='9999999999999'
```

For real deployments, prefer a secret manager (Infisical + ExternalSecrets is the reference) — see [Security](/agent-smith/security/).

---

## Step 3 — install the chart

```bash
helm install devbot oci://ghcr.io/sherodtaylor/charts/agent-smith \
  --version 0.1.24 \
  --namespace agents \
  --set agentName=devbot \
  --set matrix.homeserverUrl='https://matrix.org' \
  --set matrix.botUserId='@devbot:matrix.org' \
  --set matrix.allowedUsers='@you:matrix.org' \
  --set existingSecret=devbot-secrets \
  --set agentRepos[0]='your-org/your-repo' \
  --set primaryRepo=your-repo
```

The chart renders:
- `StatefulSet/devbot` (one pod, one init container + main container)
- `ServiceAccount/devbot` + `ClusterRoleBinding` (default = read-only on pods/services/events/etc.)
- Two PVCs: `home-devbot-0` (~/.claude/, persistent across restarts) and `workspace-devbot-0` (cloned repos)

If `ironProxy.enabled=true` (the default), the StatefulSet sets `dnsPolicy: None` and points DNS at iron-proxy's ClusterIP. Verify the iron-proxy Service's IP matches `ironProxy.clusterIp` in your values (defaults to `10.43.100.100`).

---

## Step 4 — wait for Ready

```bash
kubectl rollout status -n agents sts/devbot --timeout=180s
kubectl logs -n agents devbot-0 -c setup | tail -20
```

The init container's `setup.sh` does ~15 things in order:
- Trust iron-proxy CA
- Write Claude credentials
- Assemble `~/.claude/` (persona + settings + MCP + subagents)
- Run the [plugin reconciler](/agent-smith/operations/#plugin-reconciler) (Matrix channel + superpowers)
- Write Matrix channel config + access allowlist
- Configure git + git credentials
- Clone all `agentRepos`
- Run optional `setup.command` (dotfiles, extra tooling)

Expected last line in setup logs: `[setup] complete`.

---

## Step 5 — verify in Matrix

Invite the bot to a room:

```
/invite @devbot:matrix.org
```

The bot should join (no acknowledgement message — joining IS the ack). Tag it:

```
@devbot:matrix.org hello
```

Within a few seconds you should see a 👀 reaction on your message (the [ackReaction](https://github.com/zekker6/claude-code-channel-matrix#access-control) from the Matrix channel plugin), then a reply.

If you don't get the 👀: check the agent allowlist:

```bash
kubectl exec -n agents devbot-0 -- cat /root/.claude/channels/matrix/access.json
```

`allowedUsers` must include your Matrix ID exactly (case-sensitive).

---

## Step 6 — verify GitHub egress

Tell the bot:

```
@devbot:matrix.org open a tiny PR on your-org/your-repo that adds a NOTICE.md with one line
```

You should see the bot:
1. `kubectl logs` shows the claude process working
2. A new branch on `your-org/your-repo`
3. A PR opened by the bot's GitHub account

If the PR doesn't open and you see a 401 in the agent logs, your `GITHUB_TOKEN`/`GIT_GITHUB_TOKEN` plumbing is wrong. With iron-proxy: the stub should match what iron-proxy's ConfigMap expects, and iron-proxy's real PAT in its env must have `repo` + `workflow` scopes.

---

## Upgrades

The chart version *is* the image version. To upgrade:

```bash
helm upgrade devbot oci://ghcr.io/sherodtaylor/charts/agent-smith \
  --version <new-version> --reuse-values --namespace agents
kubectl rollout restart -n agents sts/devbot
kubectl rollout status -n agents sts/devbot --timeout=180s
```

`--reuse-values` preserves everything you `--set` at install time. To
change a value, use `--reuse-values --set <key>=<new-value>`.

The PVCs survive every restart. `~/.claude/` (credentials, plugin
state, the matrix channel access list) carries forward; cloned repos
in `/workspace/` do too.

---

## Rollback

```bash
helm rollback devbot -n agents          # to the previous release
helm rollback devbot 7 -n agents        # to a specific revision
kubectl rollout status -n agents sts/devbot --timeout=180s
```

Helm's revision history is the source of truth; `helm history devbot -n agents` shows what's available.

Edge case: if the new release changed the chart's PVC template (rare, but the v0.1.x → v0.2.x major bump introduced one), rollback won't undo the StatefulSet's PVCs — you'll get a stuck pod. The fix is to `kubectl delete sts devbot -n agents --cascade=orphan`, then `helm rollback`, then let the StatefulSet re-adopt the existing pod. PVCs are never deleted by a Helm rollback.

---

## Adding more agents

For two or three agents, install the chart once per agent with a
different `agentName`, `existingSecret`, and `matrix.botUserId`:

```bash
helm install devbot   oci://... --set agentName=devbot   --set existingSecret=devbot-secrets   ...
helm install infrabot oci://... --set agentName=infrabot --set existingSecret=infrabot-secrets ...
```

Each gets its own StatefulSet, its own PVCs, its own RBAC binding.

For larger fleets, see the [agents array](/agent-smith/operations/#agents-array-fleet-mode) chart mode (v0.2.0+).

---

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod stuck in `Init:0/1` >2 min | iron-proxy unreachable; DNS to ClusterIP wrong | Confirm `kubectl -n agent-infra get svc iron-proxy` returns the IP set in `ironProxy.clusterIp`. Restart pod after correcting. |
| `setup.sh` exits `FATAL: no AgentConfig at /opt/agent-smith/agents/<name>` | `agentName` value doesn't match a directory baked into the image | Use one of the example personas (`example-devbot`, `example-infrabot`) or build your own image with `agents/<yourname>/CLAUDE.md` + `mcp.json`. |
| `git clone https://github.com/...` fails 401 in setup logs | `GIT_GITHUB_TOKEN` is the stub but iron-proxy isn't configured to swap | Inspect `iron-proxy`'s ConfigMap; the `github.com` + `*.github.com` hosts should swap `proxy-token-github` → the real PAT. |
| Agent never replies in Matrix; `kubectl logs` shows `claude` healthy | Sender not on the allowlist | `kubectl exec -n agents <pod> -- cat /root/.claude/channels/matrix/access.json` — `allowedUsers` must contain your full Matrix ID. |
| Agent replies but every reply 👀-only, no text | Claude credentials expired and auto-refresh failed | Re-run `claude auth login` on any host, capture the new `~/.claude/.credentials.json`, update the agent's Secret, rollout restart. |
| `helm upgrade` reports "no Secret with name <foo>" | Secret was renamed or moved | `existingSecret` value must match an existing Secret in the namespace; the chart never creates one. |
| 404 on `https://<host>/agent-smith/sprites/devbot.svg` | The site was deployed from a pre-fix commit | Wait for the next `website.yml` run, or trigger `gh workflow run website.yml --ref main`. |

---

## Where to go next

- [Architecture](/agent-smith/architecture/) — what the runtime actually looks like inside the pod
- [Security](/agent-smith/security/) — the iron-proxy credential boundary in detail
- [Operations](/agent-smith/operations/) — runbooks (release, rotate creds, recover credentials, etc.)
- [Agents](/agent-smith/agents/) — adding new personas + subagents
