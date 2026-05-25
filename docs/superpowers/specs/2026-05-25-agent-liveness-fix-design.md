# Agent Liveness Fix — Design Spec

**Date:** 2026-05-25  
**Scope:** `sherodtaylor/agent-smith` — `scripts/` + `entrypoint.sh`  
**Status:** implemented — PR #26 open on `feat/agent-liveness`

---

## Problem

Agent pods (devbot, infrabot) periodically lose liveness because:

1. iron-proxy's upstream `CLAUDE_CODE_OAUTH_TOKEN` expires ~1hr after pod start
2. Anthropic returns 401 for the expired token
3. Claude Code triggers an OAuth refresh — POSTs to `console.anthropic.com/v1/oauth/token`
4. iron-proxy swaps `refresh-token-stub` with the real refresh token; Anthropic returns a fresh token pair
5. **Anthropic's refresh response omits `subscriptionType` and `rateLimitTier`**
6. Claude Code writes the partial response to `.credentials.json`, setting both fields to `null`
7. On next process restart: `subscriptionType: null` → "need to login" → process exits

**Fix:** Re-write stub credentials from template before every claude start. The stub always has `subscriptionType: "max"`, so even after a refresh nulls the field, the next restart restores it.

---

## Solution

Two changes to `sherodtaylor/agent-smith`:

| Component | File(s) | What it does |
|---|---|---|
| Restart loop | `scripts/claude-loop.sh` | Credential restore + restart with backoff/jitter + session resume |
| Entrypoint | `scripts/entrypoint.sh` | Startup jitter, launches claude-loop.sh, combined keep-alive loop |

---

## `scripts/claude-loop.sh`

Runs as the pane 0 process. On each iteration:

1. Copies `/opt/agent-smith/agents/_shared/.credentials.json` → `~/.claude/.credentials.json`, chmod 600
2. Checks `SESSION_DIR` (`~/.claude/projects/-workspace-${PRIMARY_REPO}`) — passes `--continue` if a prior session exists
3. Starts claude:
   ```bash
   claude [--continue] \
     --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix \
     --remote-control "${AGENT_NAME}" \
     --permission-mode bypassPermissions
   ```
4. On exit: if uptime > 300s reset backoff; sleep with jitter; restart

**Backoff formula:**
```
BACKOFF: 15 → 30 → 60 → 120 (cap)
JITTER:  BACKOFF + (RANDOM % BACKOFF)
Reset:   if uptime > 300s → BACKOFF = 15
```

Exits 1 if credential template is missing (pod restarts via k8s).

---

## `scripts/entrypoint.sh`

**Startup jitter** — before tmux session creation:
```bash
sleep $(( RANDOM % 45 ))
```
Prevents devbot/infrabot from synchronizing restart cadence after a rollout.

**Pane layout:**

| Pane | Command | Purpose |
|---|---|---|
| 0 | `bash /opt/agent-smith/scripts/claude-loop.sh` | claude (channels + remote-control) |
| 1 | *(shell)* | Ad-hoc inspection while attached |

`dispatch()` runs once after pane 0 starts to handle initial interactive prompts (theme picker, Bypass Permissions, development-channels consent).

**Foreground keep-alive loop** — runs in the entrypoint process, keeps the container alive:

- Every 10s: scans pane 0 for post-crash interactive prompts (same three prompts as `dispatch`) and auto-accepts them
- Every 1–3hr: if pane 0 is idle (content unchanged over 30s), injects a random prompt from `agents/${AGENT_NAME}/keepalive-prompts.txt` to prevent flat-activity signatures

---

## Keepalive Prompt Pools

**`agents/devbot/keepalive-prompts.txt`** — 10 dev-focused prompts (open PRs, recent commits, CI status, lint/build, merge conflicts, git log summary, review comments, recent issues, Dockerfile changes, TODO scan)

**`agents/infrabot/keepalive-prompts.txt`** — 10 infra-focused prompts (node status, crashloop pods, HelmRelease failures, Flux reconciliation, PVC usage, cert-manager expiry, ExternalSecrets, VictoriaMetrics alerts, Flux events, iron-proxy health)

---

## File Changes

**New files:**
- `scripts/claude-loop.sh`
- `agents/devbot/keepalive-prompts.txt`
- `agents/infrabot/keepalive-prompts.txt`
- `tests/test-loops.sh`

**Modified files:**
- `scripts/entrypoint.sh` — startup jitter, claude-loop.sh for pane 0, combined keep-alive loop
- `Dockerfile` — chmod claude-loop.sh

---

## Testing

`bash tests/test-loops.sh` — 2 smoke tests using a mock claude binary:

1. `subscriptionType` is `"max"` at every claude invocation even after OAuth corruption
2. `claude-loop.sh` exits 1 when credential template is missing

**Manual verification:**
1. Deploy to devbot
2. `kubectl exec -n agents devbot-0 -- bash -c "pkill -f claude"`
3. claude-loop.sh re-writes stubs, restarts, recovers without "need to login"
4. Check: `kubectl exec -n agents devbot-0 -- bash -c "cat /root/.claude/.credentials.json | jq .claudeAiOauth.subscriptionType"`
5. After 30min: confirm agent still responding to Matrix messages
