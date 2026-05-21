#!/usr/bin/env bash
set -euo pipefail

AGENT_NAME="${AGENT_NAME:?AGENT_NAME must be set}"
APP_DIR="/opt/agent-swarm"
AGENT_DIR="${APP_DIR}/agents/${AGENT_NAME}"
CLAUDE_DIR="${HOME}/.claude"

echo "[setup] agent=${AGENT_NAME}"

if [ ! -d "$AGENT_DIR" ]; then
  echo "[setup] FATAL: no AgentConfig at ${AGENT_DIR}" >&2
  exit 1
fi

mkdir -p "${CLAUDE_DIR}/agents" "${CLAUDE_DIR}/channels/matrix"

# CLAUDE.md = shared base + agent persona
cat "${APP_DIR}/agents/_shared/CLAUDE.md" "${AGENT_DIR}/CLAUDE.md" \
  > "${CLAUDE_DIR}/CLAUDE.md"

# settings.json from the shared base (carries the channel plugin marketplace)
cp "${APP_DIR}/agents/_shared/settings.json" "${CLAUDE_DIR}/settings.json"

# MCP servers (user scope, applies regardless of cwd)
cp "${AGENT_DIR}/mcp.json" "${CLAUDE_DIR}/.mcp.json"

# Subagents
if [ -d "${AGENT_DIR}/subagents" ]; then
  cp "${AGENT_DIR}/subagents/"*.md "${CLAUDE_DIR}/agents/" 2>/dev/null || true
fi
echo "[setup] assembled ~/.claude for ${AGENT_NAME}"

# Matrix channel config from env
cat > "${CLAUDE_DIR}/channels/matrix/.env" <<EOF
MATRIX_HOMESERVER_URL=${MATRIX_HOMESERVER_URL}
MATRIX_ACCESS_TOKEN=${MATRIX_ACCESS_TOKEN}
MATRIX_BOT_USER_ID=${MATRIX_BOT_USER_ID}
EOF

# Access allowlist — who may trigger this bot
ALLOWED="${MATRIX_ALLOWED_USERS:-@sherod:lab.sherodtaylor.dev}"
python3 - "$ALLOWED" > "${CLAUDE_DIR}/channels/matrix/access.json" <<'PY'
import json, sys
users = [u.strip() for u in sys.argv[1].split(",") if u.strip()]
print(json.dumps({"allowedUsers": users, "ackReaction": "👀"}, indent=2))
PY
echo "[setup] wrote Matrix channel config"

# git / gh auth
git config --global user.name  "${AGENT_NAME}"
git config --global user.email "${AGENT_NAME}@lab.sherodtaylor.dev"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "${GITHUB_TOKEN}" | gh auth login --with-token
  gh auth setup-git
  echo "[setup] gh authenticated"
fi

# Clone working repos
mkdir -p /workspace
for repo in ${AGENT_REPOS:-sherodtaylor/homelab}; do
  name="$(basename "$repo")"
  if [ ! -d "/workspace/${name}/.git" ]; then
    git clone "https://github.com/${repo}.git" "/workspace/${name}"
    echo "[setup] cloned ${repo}"
  else
    git -C "/workspace/${name}" pull --ff-only || true
    echo "[setup] updated ${repo}"
  fi
done

echo "[setup] complete"
