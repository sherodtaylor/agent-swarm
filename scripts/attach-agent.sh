#!/usr/bin/env bash
# Attach to a running agent's tmux session inside its pod.
# Pane 0 (top): Claude Code — type /login here to refresh OAuth credentials.
# Pane 1 (bottom): plain shell for inspection.
#
# Usage:
#   ./attach-agent.sh devbot
#   ./attach-agent.sh infrabot
#   NAMESPACE=agents ./attach-agent.sh devbot
#
# Detach with Ctrl-b d (standard tmux). Do not exit the shell in pane 0 —
# that will kill the tmux session and take down the agent.
set -euo pipefail

NAMESPACE="${NAMESPACE:-agents}"
AGENT="${1:-}"

if [ -z "$AGENT" ]; then
  echo "Usage: $0 <agent-name>  (e.g. devbot, infrabot)" >&2
  exit 1
fi

POD="${AGENT}-0"

echo "[attach] connecting to ${NAMESPACE}/${POD} — tmux session 'main'"
echo "[attach] pane 0 = claude-loop (type /login to refresh credentials)"
echo "[attach] pane 1 = shell"
echo "[attach] detach: Ctrl-b d"

kubectl exec -it -n "${NAMESPACE}" "${POD}" -- tmux attach -t main
