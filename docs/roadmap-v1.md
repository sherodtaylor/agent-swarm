# agent-smith v1 roadmap

**Status:** draft for review
**Author:** DevBot (with Sherod)
**Last updated:** 2026-05-25

A critical pass on the v1 candidate list. Goal: name the items that earn
their weight, the items that don't yet, and the gaps the original list
missed. Ordering reflects leverage-per-effort, not arbitrary preference.

---

## Ship now (v1 core)

These three are the foundation. Everything in "Ship soon" assumes them.

### 1. Agent Memory

"Memory" hides three distinct problems. Don't conflate them.

| Problem | Status today | Action |
|---|---|---|
| Cross-session persistence — a single agent remembering its own past work | Solved — Claude Code's auto-memory at `/root/.claude/projects/<cwd>/memory/MEMORY.md` already handles this; we use it. | Keep using; document the convention in `agents/_shared/CLAUDE.md`. |
| Cross-agent shared memory — DevBot writes a decision, InfraBot reads it | **Real gap.** Today we rely on `#audit` room scrollback + NATS events, both unstructured. | **Build.** NATS-backed typed KV (records: `decision`, `incident`, `pattern`, `runbook`) + a `memory` MCP server exposing read/write to both bots. |
| Project KB — long-context retrieval over past PRs, docs, incident reports | Solved by #6 (Native KB) below. | Pair with #6, ship together. |

**v1 scope:** the middle row. Concretely:

- A new NATS stream `agent-smith.memory.v1` with a JSON schema per record type.
- `mcp-memory` Go binary (sibling of `mcp-nats`) that exposes `write_record`, `read_records(type, agent?, since?)`, `find_records(query)`.
- Wire into `agents/_shared/mcp.json`.

**Effort:** ~1 week. **Leverage:** unblocks coherent multi-agent operation.

### 2. Orchestration Hub for debugging

Today we have three observability tiers that don't talk to each other:

- **NATS** — structured event log, no UI, queried only when explicitly asked.
- **VictoriaLogs** — every pod's stdout/stderr, full-text searchable, no schema.
- **Matrix** — semantic context (who asked what, what bot replied), unstructured and per-room.

When something goes wrong (a PR review goes off the rails, an Infra change loops, a tmux pane gets stuck), there is no single pane that joins these on a per-task timeline. Diagnosing requires three tabs and lots of correlation by hand.

**v1 scope:**

- Define a `run_id` UUID generated per Matrix message that wakes an agent. Thread it through every NATS event, every log line (`echo "[run=$RUN_ID] ..."`), and every Matrix reply (footer).
- Grafana dashboard with three rows: NATS events for run, log lines for run, Matrix messages for run — all filtered by `run_id`.
- One panel per agent showing the live `run_id` and tmux pane state.

**Effort:** ~3–5 days on existing infra (Grafana + VictoriaLogs/VictoriaMetrics already deployed). **Leverage:** mandatory before ephemeral agents (#7) — debugging an ephemeral with no hub is misery.

### 3. Per-agent capability scopes *(NOT on Sherod's original list)*

Today the Matrix allowlist gates *who* can trigger a bot. Nothing gates *what* the bot can do once triggered. DevBot has the same tools as InfraBot; both can `kubectl apply` if the cluster RBAC allows it.

This is wrong:

- DevBot shouldn't be able to `flux reconcile` or apply manifests.
- InfraBot shouldn't `gh pr create` or modify code in `sherodtaylor/agent-smith`.
- Neither should be able to read or write secrets they don't need.

**v1 scope:**

- Per-agent allowed-tools list in `agents/<name>/capabilities.yaml`. Enforced at the tool-call layer (claude settings `permissions.deny`) and at the k8s layer (per-agent ServiceAccount with scoped RBAC, already partially done in the Helm chart).
- Per-agent `existingSecret` scoping so DevBot doesn't see InfraBot's cluster-admin token, and vice versa.
- An audit event on every cross-boundary tool call.

**Effort:** 2–3 days. **Leverage:** cheap to add now, painful and risky once both agents have grown into their current permissions.

---

## Ship soon (v1.1)

### 4. Native KB integration (#6 in original list)

Define "native" tightly. Three plausible flavours:

1. **Read-only MCP** over a vector DB of past PRs, `#audit` history, and `docs/` markdown. Useful immediately; low coupling.
2. **Read-write to Obsidian / Notion** as the persistence layer. Appealing because Sherod already uses Obsidian, but adds a sync layer and second source of truth.
3. **Memory promotion** — move long-lived `memory/` records into the KB on a TTL.

**v1.1 scope:** #1 only. Build the MCP server pointing at a self-hosted vector DB (qdrant or pgvector). Treat Obsidian export as a one-way mirror via a cron-job, not as the live store.

**Effort:** ~1 week. **Leverage:** lets agents recall prior decisions and past PRs without re-reading every time. Pairs with Agent Memory (#1).

### 5. Ephemeral Agents (#7 in original list)

Short-lived, task-scoped bots that spin up for a single PR review / one investigation / one incident, then terminate. K8s `Job`s, not `StatefulSet`s.

**Wins:** no state pollution between runs; horizontal scale; per-run cost accounting.

**Risks worth designing for:**

- **Matrix credential churn.** Each ephemeral needs a login — a session broker that issues short-lived tokens to the Job pod.
- **No persistent memory.** Has to use the shared `memory` MCP (#1) for everything that should outlive the run.
- **Debuggability.** Without the orchestration hub (#2) running, you cannot reconstruct what an ephemeral did after it exits.

**v1.1 scope:** one ephemeral agent type — `pr-reviewer`. Triggered by `swarm.events.pr_opened` on NATS, runs the `code-review` skill, posts inline comments, exits. Tightly scoped to prove the pattern.

**Effort:** ~1 week after #1 + #2 + #3 are in. **Strict dep:** ship after the hub.

---

## Defer (need a real use case first)

### 6. Harness-agnostic / multi-model (#1 in original list)

The current value of agent-smith is *tight* Claude integration — `CLAUDE.md` format, MCP, plugin marketplace, Matrix channel plugin, settings.json conventions. Decoupling means rewriting the agent loop, the persona format, the tool layer, and the channel plumbing — and **gives nothing back today** because we have no second-model use case.

The realistic case for multi-model is *sub-agent dispatch*: use a cheap model (Hermes 4 local, Haiku) for classification, embeddings, or low-stakes tool calls. Keep Claude for the main loop.

**v1 stance:** model adapter at the sub-agent call site only. No harness rewrite. Revisit if a real model-portability requirement appears.

### 7. Decentralized agent discovery via DID / central registry (#3 in original list)

DIDs solve federation between mutually-distrusting peers. We have two bots, both running in the same homelab, both controlled by one operator. There is no trust boundary to cross.

A `team.yaml` file the bot reads at startup (replacing the hard-coded list in `agents/_shared/CLAUDE.md`) is the right v1 answer. Revisit DID/registry only when we have ≥5 agents OR a cross-org collab use case.

**v1 scope:** `team.yaml` only. ~1 hour of work, no new infra.

### 8. Native eBPF for networking/security monitoring (#5 in original list)

Iron-proxy already controls egress at the network layer. VictoriaLogs captures per-pod stdout/stderr. eBPF would add syscall-level audit (file writes, fork chains, network connects per-process) — genuinely useful *if* bots accept untrusted input.

Today the only realistic untrusted-input vector is a malicious dotfiles install script (see PR #28 review thread, comments on `setup.command`). Iron-proxy + a tightened README warning is a much cheaper mitigation than an eBPF deployment.

**v1 stance:** defer until bots take untrusted input from outside Sherod's perimeter.

---

## Other gaps worth naming

These weren't on the original list but should be on the roadmap.

### 9. Cost / budget controls

No per-agent spend cap today. With ephemeral agents (#5) this becomes critical — a bug in a Job loop could rack up real money.

**v1.1 scope:** daily token budget per agent, enforced at the proxy layer; hard kill when exceeded; alert to `#audit`.

### 10. Proactive work origination

Today bots are 100% reactive (Sherod pings → bot acts). The "always-on swarm" promise implies bots that *originate* work:

- Weekly stale-PR sweep.
- Daily dep-bump triage (Dependabot review + merge of green PRs).
- Oncall rotation (which bot is responsible for incident response right now?).
- Quarterly memory compaction (promote `memory/` to KB, drop stale records).

**v1.x scope:** start with the stale-PR sweep — concrete, bounded, observable. Cron-triggered via the existing `schedule` skill.

---

## Suggested sequencing

```
v1.0  →  #1 Agent Memory
         #2 Orchestration Hub
         #3 Capability scopes
         #7 team.yaml (cheap; drop in alongside)

v1.1  →  #4 Native KB (read-only MCP)
         #5 Ephemeral pr-reviewer
         #9 Cost budgets

v1.2  →  #10 First proactive workflow (stale-PR sweep)

v2.x  →  Revisit #6 (multi-model) and #7 (DID) only with concrete need
         Revisit #8 (eBPF) only if untrusted-input vector emerges
```

---

## Open questions for Sherod

1. **Capability scope enforcement layer.** Cluster RBAC + Claude permissions is two layers — do we want a third (the bot itself rejects calls before they hit either)? Three layers is safer but more code to maintain.
2. **KB substrate.** Qdrant, pgvector, or something else? Qdrant is a separate Helm release; pgvector reuses an existing Postgres if you have one.
3. **Ephemeral agent egress.** Iron-proxy currently has stable upstream credentials per *agent name*. Ephemerals need a credential per *run*. Is that within iron-proxy's design, or does it need a new component?
4. **NATS stream retention.** The memory stream (#1) needs different retention from the event log (`swarm.events.*`). Comfortable with a new stream + retention policy, or want to overload the existing one?
