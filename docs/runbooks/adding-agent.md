# Runbook: Add a new agent persona

Use when adding a third (or fourth, …) agent — e.g. `securitybot`, `qabot`.
The image is parametric on `AGENT_NAME`, so no image rebuild is required for
the runtime change; only a new `agents/<name>/` directory and a Matrix
identity.

## Preconditions

- You've picked a short, lowercase name. Match the regex `^[a-z][a-z0-9-]*$`.
  This will be the Matrix local-part, the chart release name, and the
  `agents/<name>/` directory name.
- You have shell access to the homelab to provision a Matrix user.
- The new agent has a clear, narrow scope. Two specialised bots beat one
  generalist; if you can't name what the new bot is *for* in one sentence,
  stop.

## Steps

### 1. Provision the Matrix identity

On the Matrix homeserver (Conduit / Tuwunel, namespace `agent-infra`):

```bash
# Register a user; capture the access token in Infisical, NOT in this shell history
register-appservice-user <name> -p '<password>'
# Or via the admin API — see your homeserver's docs.
```

Store the resulting access token in Infisical under
`/agents/<name>/MATRIX_ACCESS_TOKEN`. **Never paste it into a Matrix room or a
PR description.**

### 2. Add the agent config directory

Copy an existing persona as a template:

```bash
cp -r agents/devbot agents/<name>
```

Edit `agents/<name>/CLAUDE.md`:

- Change the heading and identity (replace `DevBot` / `InfraBot`).
- Rewrite the scope section — what repos, what languages, what concerns.
- Update the example interactions so they match the new role.
- Leave the cross-agent rules alone (they live in `agents/_shared/CLAUDE.md`).

Edit `agents/<name>/mcp.json`:

- At minimum, keep `nats` so the bot can publish `swarm.events.*`.
- Add any persona-specific MCP servers (observability, GitHub, internal APIs).

`agents/<name>/subagents/*.md` is optional — add only if you need
delegated specialists.

### 3. Update the **Your Team** roster

In `agents/_shared/CLAUDE.md`, add the new agent under the **Your Team**
section. The cross-agent PR review fan-out reads this list at runtime — no
per-agent code change is required.

```markdown
- **InfraBot** (`@infrabot:lab.sherodtaylor.dev`) — k8s/Flux/Helm infrastructure specialist
- **DevBot** (`@devbot:lab.sherodtaylor.dev`) — software developer across all repos
- **<NewBot>** (`@<name>:lab.sherodtaylor.dev`) — <one-line scope>
```

### 4. Verify the AgentConfig assembles

```bash
docker build -t agent-smith:test .

# Dry-run the setup script in a throwaway container:
docker run --rm -e AGENT_NAME=<name> agent-smith:test \
  bash -c 'AGENT_NAME=<name> bash /opt/agent-smith/scripts/setup.sh && \
           ls -la ~/.claude/ && cat ~/.claude/CLAUDE.md | head -40'
```

You should see `~/.claude/CLAUDE.md` containing both the shared base **and**
the new persona, `~/.claude/.mcp.json` matching your file, and any subagents
under `~/.claude/agents/`.

### 5. Open a PR with the persona changes

One PR per agent. Title: `[Dev] feat(agents): add <name> persona`. Body
should answer:

- What's the agent for?
- What MCP servers does it have?
- What repos does it work in?

Merge to `main`. The image rebuild on `main` picks up the new directory.

### 6. Cut a release that includes the new persona

Follow [`release.md`](release.md). The chart doesn't need changes — it's
parametric on `agentName`.

### 7. Deploy a `HelmRelease` for the new agent

In `sherodtaylor/homelab/k8s/apps/agents/`, add `<name>-helmrelease.yaml`:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <name>
  namespace: agents
spec:
  interval: 10m
  releaseName: <name>
  chart:
    spec:
      chart: agent-smith
      version: "X.Y.Z"
      sourceRef:
        kind: HelmRepository
        name: agent-smith-charts
        namespace: agents
  valuesFrom:
    - kind: ConfigMap
      name: agent-smith-shared-values
      valuesKey: values.yaml
  values:
    agentName: <name>
    agentRepos:
      - sherodtaylor/<repo>
    primaryRepo: <repo>
    matrix:
      botUserId: "@<name>:lab.sherodtaylor.dev"
      allowedUsers: "@sherod:lab.sherodtaylor.dev,@infrabot:lab.sherodtaylor.dev,@devbot:lab.sherodtaylor.dev"
    existingSecret: <name>-secrets
    serviceAccount:
      name: <name>
```

And an ExternalSecret backed by Infisical that materialises `<name>-secrets`
with `MATRIX_ACCESS_TOKEN`, `GITHUB_TOKEN`, `IRON_PROXY_CA_CRT`.

### 8. Watch it come up

```bash
flux reconcile kustomization apps -n flux-system
kubectl get pods -n agents -w

# Tail the new pod's init container
kubectl logs -n agents <name>-0 -c setup -f
```

The pod should:

1. Run `setup.sh` (init), assemble `~/.claude/`, clone repos.
2. Start `entrypoint.sh` (main), launch tmux + `claude-loop.sh`.
3. Accept the theme picker / Bypass / dev-channels prompts via `dispatch()`.
4. Join the Matrix rooms it's been invited to.

### 9. Verify on Matrix

Invite the new bot to `#dev`, `#infra`, `#general`, `#audit` from a Matrix
client. Tag it:

```
@<name> introduce yourself — what's your scope?
```

You're looking for:

- The 👀 reaction on the message (channel plugin alive).
- A short on-topic reply (persona file loaded).
- The bot mentioned in the next cross-agent PR fan-out (shared rules updated).

## Rollback

If the new agent is broken in some way you can't fix quickly:

```bash
kubectl scale statefulset/<name> -n agents --replicas=0
```

That keeps the PVCs and secrets intact. Delete the HelmRelease (and the
ExternalSecret) to fully uninstall.

## Verify

```bash
kubectl get pods -n agents
# All three (devbot, infrabot, <name>) should be Ready 1/1.

curl -sH "Authorization: token $GH_TOKEN" \
  https://api.github.com/users/sherodtaylor/repos \
  | jq '[.[] | select(.name == "<repo-the-bot-works-on>")] | length'
# Should be 1.

# The bot reacts 👀 to a tag in #dev.
```

## Why this works

The image is built once with all known agents baked in (it's just `COPY
agents/ ./agents/`). At pod startup `setup.sh` reads `agents/${AGENT_NAME}/`
and assembles `~/.claude/` from that directory plus `agents/_shared/`. There's
no per-agent code path — the persona file is the entire interface. That's why
adding a new agent is a directory + a `HelmRelease`, not a code change.
