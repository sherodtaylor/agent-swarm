#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PRIMARY_REPO="${PRIMARY_REPO:-homelab}"
CREDS_SRC="${CREDS_SRC:-/opt/agent-smith/agents/_shared/.credentials.json}"
CREDS_DST="${HOME}/.claude/.credentials.json"
SESSION_DIR="${HOME}/.claude/projects/-workspace-${PRIMARY_REPO}"
BACKOFF=15

if [ ! -f "$CREDS_SRC" ]; then
  echo "[claude-loop] FATAL: credentials template not found at ${CREDS_SRC}" >&2
  exit 1
fi

echo "[claude-loop] starting (agent=${AGENT_NAME})"

while true; do
  # Preserve real tokens written by Claude Code after an OAuth refresh cycle.
  # iron-proxy is configured with require:false — real tokens pass through
  # without swapping. Carry accessToken, refreshToken, and expiresAt forward so
  # Claude continues to self-refresh rather than falling back to stub values.
  _existing=""
  _refresh=""
  _expires=""
  if [ -f "$CREDS_DST" ]; then
    _existing=$(python3 -c "import json; d=json.load(open('$CREDS_DST')); print(d.get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null || true)
    _refresh=$(python3 -c "import json; d=json.load(open('$CREDS_DST')); print(d.get('claudeAiOauth',{}).get('refreshToken',''))" 2>/dev/null || true)
    _expires=$(python3 -c "import json; d=json.load(open('$CREDS_DST')); print(d.get('claudeAiOauth',{}).get('expiresAt',''))" 2>/dev/null || true)
  fi
  if [ -n "$_existing" ] && [ "$_existing" != "access-token-stub" ]; then
    CREDS_TOKEN="$_existing" CREDS_REFRESH="${_refresh:-refresh-token-stub}" CREDS_EXPIRES="${_expires:-9999999999999}" \
      python3 -c "
import json, os
d = json.load(open('$CREDS_SRC'))
d['claudeAiOauth']['accessToken'] = os.environ['CREDS_TOKEN']
d['claudeAiOauth']['refreshToken'] = os.environ['CREDS_REFRESH']
expires = os.environ['CREDS_EXPIRES']
if expires and expires not in ('', 'None'):
    d['claudeAiOauth']['expiresAt'] = int(expires)
open('$CREDS_DST', 'w').write(json.dumps(d))
"
    echo "[claude-loop] credentials refreshed (real tokens preserved from prior refresh)"
  else
    cp "$CREDS_SRC" "$CREDS_DST"
    echo "[claude-loop] credentials restored from template"
  fi
  chmod 600 "$CREDS_DST"

  RESUME_FLAGS=()
  if [ -d "$SESSION_DIR" ] && [ -n "$(ls -A "$SESSION_DIR" 2>/dev/null)" ]; then
    RESUME_FLAGS=(--continue)
    echo "[claude-loop] resuming prior session from ${SESSION_DIR}"
  fi

  START=$(date +%s)
  EXIT_CODE=0
  claude \
    "${RESUME_FLAGS[@]}" \
    --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix \
    --remote-control "${AGENT_NAME}" \
    --permission-mode bypassPermissions || EXIT_CODE=$?
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
