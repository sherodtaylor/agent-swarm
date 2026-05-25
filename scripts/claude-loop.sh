#!/usr/bin/env bash
set -euo pipefail

CREDS_SRC="${CREDS_SRC:-/opt/agent-swarm/agents/_shared/.credentials.json}"
CREDS_DST="${HOME}/.claude/.credentials.json"
BACKOFF=15

if [ ! -f "$CREDS_SRC" ]; then
  echo "[claude-loop] FATAL: credentials template not found at ${CREDS_SRC}" >&2
  exit 1
fi

echo "[claude-loop] starting (agent=${AGENT_NAME:-unknown})"

while true; do
  cp "$CREDS_SRC" "$CREDS_DST"
  chmod 600 "$CREDS_DST"
  echo "[claude-loop] credentials restored from template"

  START=$(date +%s)
  claude \
    --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix \
    --permission-mode bypassPermissions || true
  EXIT_CODE=$?
  UPTIME=$(( $(date +%s) - START ))

  echo "[claude-loop] claude exited (code=${EXIT_CODE} uptime=${UPTIME}s)"

  if [ "$UPTIME" -gt 300 ]; then
    BACKOFF=15
    echo "[claude-loop] healthy run — resetting backoff"
  fi

  JITTER=$(( BACKOFF + RANDOM % BACKOFF ))
  echo "[claude-loop] restarting in ${JITTER}s (backoff base=${BACKOFF}s)"
  sleep "$JITTER"

  BACKOFF=$(( BACKOFF < 60 ? BACKOFF * 2 : 120 ))
done
