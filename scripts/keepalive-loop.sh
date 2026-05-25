#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PROMPTS_FILE="/opt/agent-smith/agents/${AGENT_NAME}/keepalive-prompts.txt"
PANE="main:0.0"
MIN_SLEEP=3600
MAX_SLEEP=10800

if [ ! -f "$PROMPTS_FILE" ]; then
  echo "[keepalive] no prompts file at ${PROMPTS_FILE} — exiting"
  exit 0
fi

mapfile -t PROMPTS < "$PROMPTS_FILE"
PROMPT_COUNT=${#PROMPTS[@]}

if [ "$PROMPT_COUNT" -eq 0 ]; then
  echo "[keepalive] prompts file is empty — exiting"
  exit 0
fi

echo "[keepalive] loaded ${PROMPT_COUNT} prompts for ${AGENT_NAME}"

while true; do
  SLEEP=$(( MIN_SLEEP + RANDOM % (MAX_SLEEP - MIN_SLEEP) ))
  echo "[keepalive] sleeping ${SLEEP}s before next prompt"
  sleep "$SLEEP"

  # Idle check: if pane content changed in last 30s, claude is mid-task — skip
  SNAP1="$(tmux capture-pane -p -t "$PANE" 2>/dev/null || true)"
  sleep 30
  SNAP2="$(tmux capture-pane -p -t "$PANE" 2>/dev/null || true)"
  if [ "$SNAP1" != "$SNAP2" ]; then
    echo "[keepalive] pane is active — skipping this cycle"
    continue
  fi

  IDX=$(( RANDOM % PROMPT_COUNT ))
  PROMPT="${PROMPTS[$IDX]}"
  echo "[keepalive] injecting prompt [${IDX}]: ${PROMPT}"
  tmux send-keys -t "$PANE" "$PROMPT" Enter
done
