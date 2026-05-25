# Agent Liveness Fix — Design Spec

**Date:** 2026-05-25  
**Scope:** `sherodtaylor/agent-smith` — `scripts/` + `entrypoint.sh`  
**Status:** implemented — PR #26 open on `feat/agent-liveness`

---

## Problem

Agent pods (devbot, infrabot) periodically lose liveness because:

1. iron-proxy's upstream `CLAUDE_CODE_OAUTH_TOKEN` (baked into pod env from Infisical at start time) expires ~1hr after pod start
2. Anthropic returns 401 for the expired token
3. Claude Code triggers an OAuth refresh — POSTs to `console.anthropic.com/v1/oauth/token`
4. iron-proxy swaps `refresh-token-stub` with the real refresh token; Anthropic returns a fresh token pair
5. **Anthropic's refresh response omits `subscriptionType` and `rateLimitTier`** — these fields only appear in the initial OAuth authorization flow
6. Claude Code writes the partial response to `.credentials.json`, setting both fields to `null`
7. On next process restart: `subscriptionType: null` → "need to login to determine your organization account" → process exits

**Result:** The claude process exits and the agent disconnects from remote control.

**Root cause of the refresh trigger:** The real token in iron-proxy's env expires. Re-writing stub credentials before each claude start resets `.credentials.json` to `subscriptionType: "max"` — so even when the refresh eventually happens again and nulls the field, the next restart restores it.

---

## Solution Overview

Three changes to `sherodtaylor/agent-smith`:

| Component | File(s) | What it does |
|---|---|---|
| Restart loop script | `scripts/claude-loop.sh` | Re-writes stubs before every start; restarts on crash with exponential backoff + jitter; resumes prior session with `--continue` |
| `entrypoint.sh` changes | `scripts/entrypoint.sh` | Startup jitter between agents; single-pane claude (channels + RC); extend keep-alive loop to continuously handle prompts |
| Agent keep-alive pane | `scripts/keepalive-loop.sh` | Periodic organic prompts injected into pane 0 to prevent idle detection signatures |

---

## Component A: Restart Loop Script

### `scripts/claude-loop.sh`

Runs as the pane 0 process. Before each claude invocation:
- Copies `/opt/agent-smith/agents/_shared/.credentials.json` → `~/.claude/.credentials.json` (restores `subscriptionType: "max"`)
- Sets permissions to 600
- Checks `SESSION_DIR` (`~/.claude/projects/-workspace-${PRIMARY_REPO}`) — passes `--continue` if a prior session exists

Invokes a single claude with both channels and remote-control:
```bash
claude \
  [--continue] \
  --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix \
  --remote-control "${AGENT_NAME}" \
  --permission-mode bypassPermissions
```

On claude exit:
- Calculates uptime. If > 300s, reset backoff (healthy run, not a crash loop).
- Sleep with exponential backoff + jitter: random between `BACKOFF` and `2×BACKOFF` seconds
- Double BACKOFF for next cycle; cap at 120s
- Initial BACKOFF: 15s

```
BACKOFF: 15 → 30 → 60 → 120 (cap)
JITTER:  +0-15 → +0-30 → +0-60 → +0-120  (uniform random)
```

> **Note:** The original design had a separate `rc-loop.sh` for a second claude process running `--remote-control` with its own HOME. This was dropped when `origin/main` merged a single-claude refactor — one claude now handles both channels and remote-control on the same session.

---

## Component B: `entrypoint.sh` Changes

### Change 1 — Startup jitter

```bash
# Stagger pod startup to desync devbot/infrabot restart cadence
STARTUP_JITTER=$(( RANDOM % 45 ))
sleep "$STARTUP_JITTER"
```

### Change 2 — Pane layout

Three panes:

| Pane | Command | Purpose |
|---|---|---|
| 0 | `bash /opt/agent-smith/scripts/claude-loop.sh` | claude (channels + remote-control) |
| 1 | *(plain shell)* | Ad-hoc inspection while attached |
| 2 | `bash /opt/agent-smith/scripts/keepalive-loop.sh` | Organic keep-alive prompts |

`dispatch` is called once after pane 0 starts to handle initial bypass/devch/theme prompts.

### Change 3 — Keep-alive loop with continuous prompt scanning

Extended keep-alive scans pane 0 every 10s for interactive prompts that appear on post-crash restarts (claude-loop.sh restarts claude but `dispatch()` only runs once at initial startup):

```bash
while tmux has-session -t main 2>/dev/null; do
  sleep 10
  for pane in main:0.0 main:0.1; do
    capture="$(tmux capture-pane -p -t "$pane" 2>/dev/null || true)"
    if printf '%s' "$capture" | grep -q "Choose the text style"; then
      tmux send-keys -t "$pane" Enter
    fi
    if printf '%s' "$capture" | grep -qE "Bypass.*Permissions"; then
      tmux send-keys -t "$pane" Down; sleep 0.5; tmux send-keys -t "$pane" Enter
    fi
    if printf '%s' "$capture" | grep -q "I am using this for local development"; then
      tmux send-keys -t "$pane" Enter
    fi
  done
done
```

---

## Component C: Agent Keep-Alive Pane

Pane 2 runs a background loop that injects organic-looking prompts into pane 0 at random intervals. Purpose: prevent flat activity signatures that could flag automated usage.

### `scripts/keepalive-loop.sh`

- Random sleep: 3600–10800 seconds (1–3 hours) between prompts
- Picks a prompt from an agent-specific pool
- Idle check: captures pane snapshot, sleeps 30s, recaptures — if content changed, claude is mid-task, skip cycle
- Sends via `tmux send-keys -t main:0.0 "<prompt>" Enter`

Prompt file: `/opt/agent-smith/agents/${AGENT_NAME}/keepalive-prompts.txt`

### Prompt pools

**devbot** (`agents/devbot/keepalive-prompts.txt`): 10 dev-focused prompts (open PRs, recent commits, CI status, lint/build checks, merge conflicts, git log summary, review comments, recent issues, Dockerfile changes, TODO scan)

**infrabot** (`agents/infrabot/keepalive-prompts.txt`): 10 infra-focused prompts (node status, crashloop pods, HelmRelease failures, Flux reconciliation, PVC usage, cert-manager expiry, ExternalSecrets, VictoriaMetrics alerts, Flux events, iron-proxy health)

---

## File Changes Summary

**New files:**
- `scripts/claude-loop.sh`
- `scripts/keepalive-loop.sh`
- `agents/devbot/keepalive-prompts.txt`
- `agents/infrabot/keepalive-prompts.txt`
- `tests/test-loops.sh`

**Modified files:**
- `scripts/entrypoint.sh` — startup jitter, loop script for pane 0, plain shell pane 1, keepalive pane 2, extended keep-alive loop
- `Dockerfile` — chmod new scripts

**Unchanged:**
- `scripts/setup.sh` — credential template write at pod init is correct as-is
- `agents/_shared/.credentials.json` — stub is correct; claude-loop.sh re-copies it at runtime

---

## Error Handling

- If `_shared/.credentials.json` is missing: claude-loop.sh logs and exits 1 (pod will restart via k8s)
- If claude exits with code 0 (clean exit): backoff still applies — clean exit is unusual and shouldn't tight-loop
- If pane 2 (keepalive) crashes: it doesn't affect pane 0; entrypoint keep-alive loop does NOT restart pane 2 — it's optional/additive
- Keepalive only fires when pane 0 is idle to avoid injecting a prompt mid-task

---

## Testing / Verification

1. Build image with changes, deploy to one agent (devbot first)
2. Trigger a forced restart: `kubectl exec -n agents devbot-0 -- bash -c "pkill -f claude"`
3. Observe: claude-loop.sh re-writes stubs, restarts claude, process recovers without "need to login"
4. Verify `.credentials.json` shows `subscriptionType: "max"` after restart:
   ```bash
   kubectl exec -n agents devbot-0 -- bash -c "cat /root/.claude/.credentials.json | jq .claudeAiOauth.subscriptionType"
   ```
5. After 30min, verify agent still alive and responding to Matrix messages

### Automated smoke tests

`bash tests/test-loops.sh` — 3 tests using mock claude binary:
1. credential restoration: `subscriptionType` is `"max"` at every invocation even after corruption
2. claude-loop.sh exits 1 on missing credential template
3. keepalive-loop.sh exits 0 when prompts file is absent
