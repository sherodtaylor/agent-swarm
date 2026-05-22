#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
PRIMARY_REPO="${PRIMARY_REPO:-homelab}"
WORKDIR="/workspace/${PRIMARY_REPO}"

echo "[entrypoint] agent=${AGENT_NAME} workdir=${WORKDIR}"

# The matrix plugin + marketplace are registered in ~/.claude/settings.json
# (extraKnownMarketplaces + enabledPlugins). --dangerously-load-development-channels
# is required because the plugin is not on the official channel allowlist.
CLAUDE_CMD=(
  claude
  --remote-control "${AGENT_NAME}"
  --dangerously-load-development-channels plugin:matrix@claude-code-channel-matrix
  --permission-mode bypassPermissions
)

if ! tmux has-session -t main 2>/dev/null; then
  tmux new-session -d -s main -x 220 -y 50 -c "${WORKDIR}"
  # Mirror the pane to pod stdout so VictoriaLogs captures the Claude session.
  tmux pipe-pane -t main -o 'cat >> /proc/1/fd/1'
  tmux send-keys -t main "${CLAUDE_CMD[*]}" Enter
  # claude shows a one-time "Bypass Permissions mode" warning with no headless
  # config bypass — accept it by driving the tmux pane once the prompt appears.
  # claude column-positions the words "Bypass" and "Permissions", so the
  # rendered pane has variable spacing between them — match with a regex.
  accepted=0
  for _ in $(seq 1 20); do
    if tmux capture-pane -p -t main 2>/dev/null | grep -qE "Bypass.*Permissions"; then
      sleep 2                                   # let the prompt fully render
      tmux send-keys -t main Down
      sleep 0.5
      tmux send-keys -t main Enter
      accepted=1
      break
    fi
    sleep 1
  done
  if [ "$accepted" = 1 ]; then
    echo "[entrypoint] bypass-permissions warning auto-accepted"
  else
    echo "[entrypoint] bypass-permissions warning not seen in 20s"
  fi
fi

echo "[entrypoint] claude+matrix channel started in tmux session 'main'"
echo "[entrypoint] attach: kubectl exec -it -n agents ${AGENT_NAME}-0 -- tmux attach -t main"

# Keep the container alive; exit if the tmux session dies.
while tmux has-session -t main 2>/dev/null; do
  sleep 30
done
echo "[entrypoint] tmux session ended — exiting"
exit 1
