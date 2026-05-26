# Runbook: Agent is unresponsive

Use when an agent is silent in Matrix, hasn't reacted to a tag in `#dev`, or
appears to be in a restart loop. Excludes the specific 401 case — for that
go to [`oauth-401.md`](oauth-401.md) first.

## Decision tree

```
Agent silent on Matrix
   │
   ├── Pod CrashLoopBackOff?  ────────►  step 3 (restart loop diagnosis)
   ├── Pod Running but no 👀 reaction?  ►  step 4 (Matrix channel diagnosis)
   ├── Pod Running, 👀 but no reply?  ──►  step 5 (Claude alive but stuck)
   └── Pod Pending / Init: …?  ────────►  step 2 (init container diagnosis)
```

## Preconditions

- `kubectl` access to the `agents` namespace.
- Ability to `tmux attach` into the pod (`kubectl exec -it … -- tmux attach -t main`).

## Steps

### 1. Establish the symptom

```bash
kubectl get pods -n agents
kubectl describe pod -n agents <agent>-0 | tail -30
```

Note the pod phase, container statuses, and the most recent events. Pick a
branch below.

### 2. Init container failures (`Init:0/1`, `Init:CrashLoopBackOff`)

```bash
kubectl logs -n agents <agent>-0 -c setup
```

Common causes you'll see:

| Log line | Cause | Fix |
|---|---|---|
| `FATAL: no AgentConfig at /opt/agent-smith/agents/<name>` | `AGENT_NAME` doesn't match a directory in the image | Bump the image to a tag that includes the new agent, or fix `AGENT_NAME` |
| `git clone … fatal: could not read Username` | `GIT_GITHUB_TOKEN` empty or stub | Check the `existingSecret` actually contains `GIT_GITHUB_TOKEN` |
| `update-ca-certificates: not found` (rare) | Base image regression | Rebuild from a known-good tag |
| `claude plugin install … failed` | Network blocked, iron-proxy down | Check `kubectl get pods -n agent-infra`; the cluster's egress is broken upstream of this pod |

### 3. Main container restart loop

The expected behaviour of `claude-loop.sh` is to restart `claude` on crash
with exponential backoff (15 s → 30 s → 60 s → 120 s, with jitter). If you
see continuous restarts on the *pod* (not just the inner loop), something is
killing PID 1.

```bash
kubectl logs -n agents <agent>-0 --previous --tail=200
```

Look for the last lines before the crash. The most common cause is `tmux` not
finding any session — usually because `entrypoint.sh` failed before
`new-session` ran. Re-check the init container logs (step 2).

If `claude` itself is crashing inside the loop:

```bash
kubectl exec -n agents <agent>-0 -- tmux capture-pane -p -t main:0.0
```

That captures the live pane content — you'll see the exact error Claude
printed before exiting.

### 4. Pod Running but no 👀 reaction

The Matrix channel plugin isn't running, isn't logged in, or isn't allowed to
react to your user.

```bash
# Is the plugin installed?
kubectl exec -n agents <agent>-0 -- \
  ls /root/.claude/plugins/cache/

# Is the agent in the rooms you tagged it in?
kubectl exec -n agents <agent>-0 -- \
  cat /root/.claude/channels/matrix/.env | grep -v TOKEN
kubectl exec -n agents <agent>-0 -- \
  cat /root/.claude/channels/matrix/access.json
```

If `access.json` doesn't list your Matrix ID under `allowedUsers`, your
message is being silently dropped. Fix:

```bash
# Update MATRIX_ALLOWED_USERS in Infisical, then restart the pod
kubectl delete pod -n agents <agent>-0
```

If the plugin is installed and you're in the allowlist but still no 👀, attach
and look:

```bash
kubectl exec -it -n agents <agent>-0 -- tmux attach -t main
# Ctrl-b o → pane 0 (claude)
# Look for "Matrix channel connected" or an error
```

### 5. 👀 but no reply

Claude saw your message and acknowledged. It's either still working (give it
30 s on a hard task) or the request reached Anthropic and is failing.

```bash
kubectl logs -n agents <agent>-0 --tail=100 | grep -E '401|429|5..|timeout|ECONNRESET'
```

- 401 → [`oauth-401.md`](oauth-401.md)
- 429 → rate-limited. Check whether the keepalive injector fired at the same
  time (low likelihood — it only fires after 30 s of idle).
- 502/504 → iron-proxy or upstream Anthropic blip. Usually self-heals;
  retry the tag in a minute.
- `ECONNRESET` → flap. Look at iron-proxy logs (`kubectl logs -n agent-infra
  -l app=iron-proxy --tail=200`).

### 6. Last resort: attach and inspect

```bash
kubectl exec -it -n agents <agent>-0 -- tmux attach -t main
# Ctrl-b o      toggle panes
# Ctrl-b d      detach (does NOT kill anything)
```

Pane 0 is the live `claude` process. Pane 1 is a plain bash shell in the
working repo — `kubectl get pods`, `git status`, `flux logs` from there.

Do **not** kill `claude` from inside the pane; the loop will restart it. To
force a clean restart, delete the pod from outside (`kubectl delete pod …`).

## Verify

```bash
# After whatever fix, tag the bot and confirm:
# - 👀 within ~2 s
# - on-topic reply within ~30 s
# - no errors in:
kubectl logs -n agents <agent>-0 --tail=50
```

## Rollback

If you've changed something in Infisical or in the homelab manifests:

```bash
# Roll the consuming HelmRelease back to the previous chart version
# (this is also the rollback path for a broken image release)
flux suspend helmrelease/<agent> -n agents
# Edit k8s/apps/agents/<agent>-helmrelease.yaml back to the prior version
git -C /workspace/homelab commit && git push
flux resume helmrelease/<agent> -n agents
flux reconcile helmrelease/<agent> -n agents
```

If you `kubectl delete pod`'d and made things worse, just delete it again —
the StatefulSet always re-creates.

## Why this works

The pod is a thin shell around a single `claude` process. Three things can
go wrong:

1. `setup.sh` (init) — failures here mean `~/.claude/` is never assembled.
   Pod phase will be `Init:…` and `setup` container logs have the story.
2. `entrypoint.sh` / `claude-loop.sh` (main) — failures here are visible in
   the main container's logs and in the live tmux pane.
3. Matrix channel plugin — failures here are silent from the pod's POV (the
   process is happy; it just isn't getting input). The 👀 reaction is the
   single best liveness signal because it proves the channel-receive path
   end-to-end.

Restart in the order: init failure → reroll image / fix secret. Channel
issue → fix config + delete pod. Claude itself stuck → delete pod (the loop
will restart it cleanly).
