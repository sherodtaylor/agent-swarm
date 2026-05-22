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
  # claude shows several interactive first-run prompts that have no headless
  # config bypass (Bypass Permissions warning; development-channels consent for
  # --dangerously-load-development-channels). Drive past them by polling the
  # pane and sending the appropriate keystroke. claude column-positions text,
  # so each detector uses a regex tolerant of variable spacing.
  quiet=0
  for _ in $(seq 1 30); do
    pane="$(tmux capture-pane -p -t main 2>/dev/null || true)"
    if printf '%s' "$pane" | grep -qE "Bypass.*Permissions"; then
      sleep 2
      tmux send-keys -t main Down
      sleep 0.3
      tmux send-keys -t main Enter
      echo "[entrypoint] auto-accepted: Bypass Permissions warning"
      quiet=0; sleep 3
    elif printf '%s' "$pane" | grep -q "I am using this for local development"; then
      sleep 2
      tmux send-keys -t main Enter
      echo "[entrypoint] auto-accepted: development channels prompt"
      quiet=0; sleep 3
    else
      quiet=$((quiet + 1))
      [ "$quiet" -ge 5 ] && break
      sleep 2
    fi
  done
fi

echo "[entrypoint] claude+matrix channel started in tmux session 'main'"
echo "[entrypoint] attach: kubectl exec -it -n agents ${AGENT_NAME}-0 -- tmux attach -t main"

# Keep the container alive; exit if the tmux session dies.
while tmux has-session -t main 2>/dev/null; do
  sleep 30
done
echo "[entrypoint] tmux session ended — exiting"
exit 1
