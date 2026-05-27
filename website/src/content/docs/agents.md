---
title: Agents
description: Persona configuration and behavior.
---

An agent is a directory. The image is parametric on `AGENT_NAME`, and
`setup.sh` reads `agents/${AGENT_NAME}/` at pod startup to assemble
`~/.claude/`. Adding a new agent is a directory + a `StatefulSet`
referencing the same image with a different `AGENT_NAME`. No image
rebuild.

## The persona contract

To make a new agent, create `agents/<name>/`:

```
agents/<name>/
├── CLAUDE.md         # appended after _shared/CLAUDE.md; defines persona, repos, examples
├── mcp.json          # MCP servers to expose to this agent
└── subagents/        # optional persona-specific subagents (one .md per subagent)
    └── *.md
```

That is the entire contract.

`setup.sh` assembles `~/.claude/` from a fixed set of sources:

| Source file | Becomes | Purpose |
|---|---|---|
| `agents/_shared/CLAUDE.md` + `agents/<name>/CLAUDE.md` (concatenated) | `~/.claude/CLAUDE.md` | base rules + persona |
| `agents/_shared/settings.json` | `~/.claude/settings.json` | plugins, permissions, hooks |
| `agents/_shared/.credentials.json` | `~/.claude/.credentials.json` | stub OAuth (iron-proxy swaps in real tokens) |
| `agents/<name>/mcp.json` | `~/.claude/.mcp.json` | per-agent MCP servers |
| `agents/<name>/subagents/*.md` | `~/.claude/agents/*.md` | persona-specific subagents |

`agents/_shared/CLAUDE.md` is the base behaviour contract every agent
inherits. Persona files only add specifics — repos, languages, MCP
servers, example interactions. Don't duplicate cross-agent rules
(response triggers, PR review fan-out, secret hygiene) in a persona
file; they belong in `_shared` so all agents stay in lockstep.

## The agents today

**InfraBot** — homelab infrastructure specialist. Owns the k3s cluster,
Flux GitOps, Helm releases, and observability via the
VictoriaMetrics/VictoriaLogs MCP servers. Has subagents for diagnostics
(`DiagnosticsAgent`), Flux auditing (`FluxAuditor`), documentation
(`DocWriter`), and validation (`TestWriter`).

**DevBot** — software developer across all repos. Implements features,
fixes bugs, writes tests, and opens PRs. Has subagents for self-review
(`CodeReviewer`) and tests (`TestWriter`).

Both agents are peers. They coordinate through Matrix rooms (`#dev`,
`#infra`, `#general`, `#audit`). NATS JetStream is a shared durable
event log they publish to and query on demand — it never wakes them
autonomously; Matrix mentions do.

## Adding a new agent

Onboarding a third (or fourth, …) agent — e.g. `securitybot`,
`qabot` — is a documented sequence.

### 1. Pick a name

Short, lowercase, matching `^[a-z][a-z0-9-]*$`. This becomes the Matrix
local-part, the chart release name, and the `agents/<name>/` directory
name.

### 2. Provision the Matrix identity

On the Matrix homeserver, register the bot user and capture the access
token in the operator's secret store (Infisical, sealed-secrets, etc.).
**Never paste it into a Matrix room or a PR description.**

### 3. Add the agent config directory

Copy an existing persona as a template:

```bash
cp -r agents/devbot agents/<name>
```

Edit `agents/<name>/CLAUDE.md`:

- Change the heading and identity (replace `DevBot` / `InfraBot`).
- Rewrite the scope section — what repos, what languages, what concerns.
- Update the example interactions so they match the new role.
- Leave the cross-agent rules alone (they live in
  `agents/_shared/CLAUDE.md`).

Edit `agents/<name>/mcp.json`:

- At minimum, keep `nats` so the bot can publish `swarm.events.*`.
- Add any persona-specific MCP servers (observability, GitHub, internal
  APIs).

`agents/<name>/subagents/*.md` is optional — add only if the persona
needs delegated specialists.

### 4. Update the **Your Team** roster

In `agents/_shared/CLAUDE.md`, add the new agent under the **Your
Team** section. The cross-agent PR review fan-out reads this list at
runtime — no per-agent code change is required.

```markdown
- **InfraBot** (`@infrabot:lab.example.com`) — k8s/Flux/Helm infrastructure specialist
- **DevBot** (`@devbot:lab.example.com`) — software developer across all repos
- **<NewBot>** (`@<name>:lab.example.com`) — <one-line scope>
```

### 5. Verify the AgentConfig assembles

```bash
docker build -t agent-smith:test .

docker run --rm -e AGENT_NAME=<name> agent-smith:test \
  bash -c 'AGENT_NAME=<name> bash /opt/agent-smith/scripts/setup.sh && \
           ls -la ~/.claude/ && cat ~/.claude/CLAUDE.md | head -40'
```

Expected: `~/.claude/CLAUDE.md` contains both the shared base **and**
the new persona, `~/.claude/.mcp.json` matches `mcp.json`, and any
subagents land under `~/.claude/agents/`.

### 6. Ship it

- Open one PR per agent. Title: `[Dev] feat(agents): add <name>
  persona`. Body answers: what's the agent for, what MCP servers does it
  have, what repos does it work in.
- Merge to `main`. The image rebuild on `main` picks up the new
  directory.
- Cut a release that includes the new persona (see
  [Operations](/agent-smith/operations)).
- Deploy a `HelmRelease` for the new agent referencing the same chart
  with `agentName: <name>` and the new repos.
- Reconcile Flux. The pod comes up, joins Matrix, and is ready to be
  tagged in `#dev` or `#infra`.

The shared base rules (`agents/_shared/CLAUDE.md`) automatically include
the new agent in the cross-agent PR review fan-out — no per-agent code
change required.

## Why the persona file is the entire interface

The image is built once with all known agents baked in (it's just
`COPY agents/ ./agents/` in the Dockerfile). At pod startup `setup.sh`
reads `agents/${AGENT_NAME}/` and assembles `~/.claude/` from that
directory plus `agents/_shared/`. There's no per-agent code path — the
persona file is the entire interface. That's why adding a new agent is
a directory + a `HelmRelease`, not a code change.
