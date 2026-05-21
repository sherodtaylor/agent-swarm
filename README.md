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
- `scripts/setup.sh` — assembles `~/.claude` and clones working repos
- `scripts/entrypoint.sh` — launches `claude` + the Matrix channel in tmux

## Build

    docker build -t agent-swarm:local .
