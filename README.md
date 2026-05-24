# agent-swarm

A thin wrapper that runs the Claude Code CLI as a persistent Matrix-driven agent.

Each agent is this one Docker image (`ghcr.io/sherodtaylor/agent-swarm`) with a
different `AGENT_NAME` selecting a baked-in `AgentConfig` under `agents/<name>/`.
The `claude` CLI runs continuously with the `claude-code-channel-matrix` channel
plugin (installed from its marketplace via `settings.json`), so incoming Matrix
messages drive Claude Code directly.

## Layout

- `agents/_shared/` — base `CLAUDE.md` and `settings.json` for every agent
- `agents/<name>/` — per-agent `CLAUDE.md`, `mcp.json`, and `subagents/`
- `scripts/setup.sh` — assembles `~/.claude`, installs iron-proxy CA, writes `.credentials.json` from `SWARM_CLAUDE_CREDENTIALS`, and clones working repos
- `scripts/entrypoint.sh` — launches `claude` + the Matrix channel in tmux
- `scripts/check-pr-comments.sh` — Stop hook: exits 2 (async rewake) if new PR review comments exist

## Environment Variables (init container)

| Variable | Source | Purpose |
|----------|--------|---------|
| `MATRIX_ACCESS_TOKEN` | Infisical | Matrix bot auth |
| `IRON_PROXY_CA_CRT` | Infisical | iron-proxy MITM CA — installed into system trust store |
| `SWARM_CLAUDE_CREDENTIALS` | Infisical | Full JSON content of `~/.claude/.credentials.json` — written silently (mode 600) for remote-control Claude access; never echoed |

## Build

    docker build -t agent-swarm:local .
