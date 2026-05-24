# agent-swarm

A thin wrapper that runs the Claude Code CLI as a persistent Matrix-driven agent.

Each agent is this one Docker image (`ghcr.io/sherodtaylor/agent-swarm`) with a
different `AGENT_NAME` selecting a baked-in `AgentConfig` under `agents/<name>/`.
The `claude` CLI runs continuously with the `claude-code-channel-matrix` channel
plugin (installed from its marketplace via `settings.json`), so incoming Matrix
messages drive Claude Code directly.

## Layout

- `agents/_shared/` — base `CLAUDE.md` and `settings.json` for every agent
- `agents/<name>/CLAUDE.md` — per-agent persona and role
- `agents/<name>/mcp.json` — per-agent MCP server config
- `agents/<name>/subagents/*.md` — subagent definitions
- `scripts/setup.sh` — init: assemble `~/.claude`, install iron-proxy CA, write `.credentials.json`, clone repos
- `scripts/entrypoint.sh` — main: launch `claude` + Matrix channel in tmux, mirror to stdout
- `scripts/check-pr-comments.sh` — Stop hook: exits 2 (async rewake) if new PR review comments exist

## Agents

**InfraBot** — homelab infrastructure specialist. Manages Kubernetes, Flux, and
Helm in `sherodtaylor/homelab`. Has two subagents (`DocWriter`, `TestWriter`) for
documentation and validation work. MCP servers: `victoria-metrics`, `victoria-logs`,
`nats`.

**DevBot** — general-purpose software developer. Writes and fixes code across
`sherodtaylor/homelab`, `sherodtaylor/agent-swarm`, and other repos. Opens PRs,
adds tests, and coordinates with InfraBot via Matrix. MCP servers: `nats`.

Both agents are peers. They coordinate through Matrix rooms (`#dev`, `#infra`,
`#general`). NATS JetStream is a durable shared event log they publish to and
query on demand — it never triggers agents autonomously.

## Environment Variables (init container)

| Variable | Source | Purpose |
|----------|--------|---------|
| `MATRIX_ACCESS_TOKEN` | Infisical | Matrix bot auth |
| `IRON_PROXY_CA_CRT` | Infisical | iron-proxy MITM CA — installed into system trust store |
| `SWARM_CLAUDE_CREDENTIALS` | Infisical | Full JSON content of `~/.claude/.credentials.json` — written silently (mode 600) for remote-control Claude access; never echoed |

## Security (iron-proxy)

All agent egress runs through **iron-proxy** (0.41.0) at ClusterIP `10.43.100.100`.
This is the egress credential firewall: agents hold only worthless proxy tokens and
iron-proxy swaps real secrets in at the network boundary.

- Agents carry `proxy-token-github` and `proxy-token-claude` — literal placeholder
  strings, never the real GitHub PAT or Claude OAuth token.
- iron-proxy MITMs all HTTPS egress, enforces a default-deny domain allowlist, and
  rewrites `Authorization` headers with the real credentials scoped to each host.
- Agent DNS is pointed at iron-proxy (`dnsPolicy: None`). In-cluster names
  (`*.cluster.local`) pass through to CoreDNS so NATS and the Matrix homeserver
  still resolve normally.
- The iron-proxy CA cert is distributed to agent pods via ExternalSecret. It is
  installed into the system trust store (`update-ca-certificates`) so `git`, `gh`,
  and `curl` trust the MITM, and `NODE_EXTRA_CA_CERTS` is set for the Node-based
  `claude` CLI. If the Matrix channel plugin (Bun runtime) makes TLS calls, it
  needs `SSL_CERT_FILE` or `NODE_EXTRA_CA_CERTS` set as well.

## PR Monitoring

A stop hook fires `check-pr-comments.sh` after every agent turn. The script
inspects the agent's open PRs for new inline review comments. If any are found it
exits 2, which signals the Claude Code harness to perform an async rewake: the
agent is reinvoked with context pointing at the new comments, addresses them, pushes
a fix commit, and replies on the PR thread. No human nudge is needed.

After opening a PR, the agent posts the link in `#dev` and mentions the other bot
to request a cross-agent review. The reviewer uses `gh pr diff` and the `code-review`
skill to post inline findings.

## Build

    docker build -t agent-swarm:local .
