# Runbook: Anthropic 401 Unauthorized

Use when an agent's tmux pane shows `401 Unauthorized` from `*.anthropic.com`,
or `kubectl logs` reports auth errors after a successful pod startup.

## The shape of this bug

The pod never holds a real OAuth token — `~/.claude/.credentials.json`
contains literal stub strings (`access-token-stub`, `refresh-token-stub`).
iron-proxy sees those strings in the `Authorization` header and rewrites them
to the real token at egress. A 401 means iron-proxy's swap **didn't fire**.

Two common causes:

1. **`.credentials.json` no longer contains the stub.** Claude Code's OAuth
   refresh path overwrites the file mid-flight with the upstream response,
   which strips `subscriptionType` and may change the access token. With the
   stub string gone, iron-proxy has nothing to match against — the request
   goes upstream with whatever Claude wrote, which fails because it's stale
   or never had `subscriptionType: "max"`.
2. **iron-proxy is holding a stale upstream token.** The real
   `CLAUDE_CODE_OAUTH_TOKEN` in iron-proxy's environment has expired or been
   rotated, but iron-proxy hasn't re-read it. ESO syncs the k8s Secret on its
   refresh interval, but iron-proxy must restart to pick up the new env value.

## Preconditions

- `kubectl` access to the `agents` and `agent-infra` namespaces.
- Awareness of which token rotated, if any (check Infisical history).

## Steps

### 1. Confirm it's actually a 401 (and not a different error)

```bash
kubectl logs -n agents <agent>-0 --tail=200 | grep -E '401|Unauthorized|Invalid API key'
```

You want a clear 401 from `api.anthropic.com` or similar. If it's a 403, a
network error, or "no API key", that's a different problem — go to
[`agent-down.md`](agent-down.md).

### 2. Check whether the stub is still in place

```bash
kubectl exec -n agents <agent>-0 -- \
  jq -r '.claudeAiOauth.accessToken' /root/.claude/.credentials.json
```

Expected output: `access-token-stub`

If you see anything else (a real JWT, an empty string, `null`), cause #1
applies. `claude-loop.sh` restores the stub before each `claude` start, so
this should only stick if Claude is currently running mid-refresh.

### 3. Force-restore and restart the agent

```bash
kubectl delete pod -n agents <agent>-0
```

The StatefulSet recreates the pod. `setup.sh` runs (re-copies the stub) and
`claude-loop.sh` starts fresh. Watch:

```bash
kubectl logs -n agents <agent>-0 -c setup -f
# … wait for "[setup] complete" …
kubectl logs -n agents <agent>-0 -f
```

You should see `[claude-loop] credentials restored from template` followed by
a successful Claude Code startup banner.

### 4. If 401 persists, check iron-proxy

The pod-side stub is fine, so the swap is happening but the *upstream* token
iron-proxy holds is bad.

```bash
# Last time iron-proxy restarted vs last time ESO synced the secret
kubectl get pod -n agent-infra -l app=iron-proxy -o wide
kubectl describe externalsecret -n agent-infra iron-proxy-upstream-secrets
```

If the ExternalSecret's `LastSync` is newer than the iron-proxy pod's start
time, the pod is running with a stale env value:

```bash
kubectl rollout restart deployment/iron-proxy -n agent-infra
kubectl rollout status  deployment/iron-proxy -n agent-infra
```

### 5. Verify

After both pods are Ready, send a Matrix message to the agent:

```
@<agent> ping
```

You're looking for:

- The 👀 reaction (Matrix channel alive).
- A reply (Anthropic egress working).
- No new 401s in `kubectl logs -n agents <agent>-0 --tail=50`.

```bash
# Sanity: count 401s vs 200s over the last few minutes
kubectl logs -n agents <agent>-0 --tail=500 | grep -c "401 Unauthorized"
kubectl logs -n agents <agent>-0 --tail=500 | grep -c " 200 "
```

The first number should be `0`. The second should be non-zero.

## Rollback

There's nothing to roll back here — the operation is idempotent. If a restart
makes it worse, check `claude-loop.sh` and the stub credentials file in the
repo for accidental modifications:

```bash
git -C /workspace/agent-smith diff agents/_shared/.credentials.json
```

The stub file is committed to the repo for a reason. If a PR accidentally
swapped in a real credential, revert and re-publish.

## Why this works

iron-proxy matches on the literal string `access-token-stub` in the
`Authorization` header. Two ways that match can fail:

1. The pod sent a different string (Claude Code refreshed the credentials
   file). `claude-loop.sh` restoring the stub before every start fixes this.
2. iron-proxy's own copy of the real upstream token expired. ESO refreshed
   the k8s Secret but iron-proxy reads env at process start. A rollout
   restart re-reads it.

Both fixes are restarts, just of different pods. The order matters: restart
the agent first (it's cheaper), restart iron-proxy only if the agent stub is
intact and 401s persist.
