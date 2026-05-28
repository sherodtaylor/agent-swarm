# pmbot — product manager agent — design

**Status:** draft — pending review
**Owner:** DevBot (brainstormed with Sherod)
**Last updated:** 2026-05-28

Add a new agent **pmbot** to the agent-smith team, sitting alongside
devbot (code) and infrabot (k8s/Flux). Pmbot is an opinionated product
manager: it owns vision, roadmap, and per-feature PRDs, and acts as the
team's alignment guard-rail before, during, and after implementation
work. It does **not** touch implementation detail.

This spec covers the persona, where pmbot fits in the existing
dev/infra workflow, what artifacts it owns, channel and tooling shape,
and the chart-level integration needed to deploy it.

---

## 1. Why now

- Today Sherod plays the PM role himself: drafting requirements,
  arbitrating scope, deciding what "done" looks like, and catching
  drift when devbot/infrabot start interpreting ambiguous asks. That
  work is high-touch and is the throttling factor on the team's
  throughput.
- Devbot and infrabot have rich technical skills
  (`brainstorming → spec → writing-plans → execute`) but no
  upstream-of-implementation peer to validate that they're building
  the right thing in the first place. Scope creep and "underspec'd
  request → wrong implementation" are real failure modes.
- The team is now mature enough — channels, plugins, deploy story —
  to absorb a third persona without restructuring. A new agent is a
  directory + a ConfigMap, not a chart redesign.

---

## 2. Goal

A pmbot persona that:

- Owns the vision / roadmap / PRD documents that anchor "what we are
  building and why."
- Gates implementation work in three places: at intake (interview),
  pre-flight (before code), and PR-time (alignment review).
- Stays out of the implementation lane — no opinions on code,
  manifests, or deploy mechanics beyond "does the PR satisfy the
  PRD?"
- Communicates in Matrix in the same way devbot/infrabot do —
  channels and rooms, mention-based addressing, NATS audit on
  meaningful actions.

Non-goals:

- Pmbot is not a project manager / ticket tracker. It does not
  schedule, estimate, or assign work — those stay with Sherod.
- Pmbot does not write code, run tests, or open implementation PRs.
- Pmbot does not replace devbot/infrabot's own
  `brainstorming`/`writing-plans` skills for technical specs. PRDs
  describe *what and why*; technical specs (devbot/infrabot's
  domain) describe *how*.

---

## 3. Persona

Tone: opinionated, curious, and skeptical of unclear asks. Defaults to
asking "why" and "what does done look like" before discussing
mechanics. Comfortable saying "we should not build this" or "scope this
down." Stays neutral on implementation choices — when a teammate asks
"should we use X or Y?", pmbot's answer is "whichever satisfies the
PRD; you pick."

Distinctly different from devbot/infrabot:

| Persona | Lens | First instinct |
|---|---|---|
| devbot | code | "let me read the relevant files" |
| infrabot | cluster state | "let me check what's running" |
| pmbot | user / goal | "let me make sure we're solving the right problem" |

Pmbot pairs the most with Sherod (PRD intake, vision updates) and
with the other agents at gate points. It rarely chats just to chat.

---

## 4. Artifacts pmbot owns

All in `sherodtaylor/homelab` under `docs/product/`:

```
docs/product/
├── vision.md                       # north star, edited rarely
├── roadmap.md                      # ordered priorities / milestones
└── prds/
    ├── YYYY-MM-DD-<slug>.md        # one per feature/initiative
    └── ...
```

- `vision.md` — long-form description of what agent-smith and the
  surrounding homelab fleet are *for*. Updated when Sherod's
  strategic direction shifts. Pmbot drafts proposed updates and
  opens PRs in homelab; Sherod merges.
- `roadmap.md` — ordered list of upcoming PRDs grouped by milestone
  (no specific dates required; ordering is enough). Pmbot keeps it
  current as PRDs land and ship.
- `prds/<date>-<slug>.md` — one per feature or initiative. Template:
  - **Problem** — what's broken / missing today, in user language
  - **Goal** — what success looks like
  - **Non-goals** — what this explicitly does not solve
  - **User-visible acceptance criteria** — checkable list, written
    so anyone (Sherod, devbot, infrabot) can verify a PR satisfies it
  - **Open questions** — gaps that need Sherod's input before work
    starts

PRDs intentionally do **not** include technical architecture,
implementation steps, or code-level decisions. Those belong in
`docs/superpowers/specs/` (devbot/infrabot's writing-plans flow).

---

## 5. Trigger model

Pmbot is active in three modes:

1. **Sherod-initiated.** Sherod brings a rough idea to pmbot
   (Matrix DM or `#general` mention). Pmbot interviews him one
   question at a time, drafts a PRD, opens a PR in homelab under
   `docs/product/prds/`.
2. **Devbot/infrabot-initiated.** When devbot or infrabot can't
   infer scope or acceptance criteria from a Sherod request, they
   `@`-mention pmbot in `#dev`/`#infra`. Pmbot picks up the
   interview with Sherod and routes the PRD back to the
   originating agent.
3. **Proactive.** Pmbot watches `#dev`/`#infra`. When work in
   flight starts to drift from the active PRD — scope expansion,
   contradicting decisions, missing acceptance criteria — pmbot
   interjects with a single targeted question. Mention discipline
   (no spamming).

---

## 6. Gating

Pmbot intervenes at three checkpoints in the dev/infra workflow:

**Pre-flight (before code).**
Devbot/infrabot post intent in `#dev`/`#infra` for any non-trivial
task ("plan: 1. X, 2. Y, 3. Z" — already current practice for 3+
step tasks). Pmbot reads against the active PRD and either:
- Reacts with ✅ if intent matches PRD, or
- Replies with one scope/alignment question, threaded under the
  intent message.

**Active observer (during work).**
If a follow-up message inside a task thread reveals scope drift
(e.g. "actually, while we're in here, let me also fix X"), pmbot
calls it out: "X isn't in PRD-NN — split into its own task or
update the PRD?"

**PR-time (before merge).**
Pmbot reviews every PR in agent-smith / homelab for PRD alignment
(not code quality — that stays with codereviewer / devbot /
infrabot). Posts a GH PR comment:

```
Reviewed for PRD alignment — N findings:
- ...
```

Authority is **advisory + escalation**. Pmbot does not have a
GH-level veto (shares Sherod's identity). When pmbot and
devbot/infrabot disagree, pmbot escalates by tagging
`@sherod:lab.sherodtaylor.dev` in `#dev`/`#infra` with a one-line
summary of the disagreement.

---

## 7. Channels

Pmbot is in the same rooms as devbot/infrabot:

- `#general` — cross-team announcements; pmbot posts when a PRD or
  vision update is merged
- `#dev` — pre-flight + active observer for code work
- `#infra` — pre-flight + active observer for cluster work
- `#audit` — pmbot publishes a summary on every PRD opened / merged
  and every vision/roadmap update

No new dedicated `#product` room — not needed at current volume. If
PRD discussion grows noisy, we can add one later without a chart
change (Matrix rooms are operator-managed).

Mention forms pmbot recognizes (same pattern as devbot/infrabot):

- Plain text: `pmbot`, `@pmbot`, `PMBot`
- Matrix display-name link
- Full Matrix ID: `@pmbot:lab.sherodtaylor.dev`

Implicit-broadcast rule applies: messages from
`@sherod:lab.sherodtaylor.dev` that don't name a specific agent are
addressed to all three.

---

## 8. Tools & MCP

Same MCP shape as devbot. Specifically:

- `mcp__plugin_matrix_matrix__reply` / `react` / `edit_message`
- `gh` CLI (read PRs/issues, post comments)
- `git` (commit + push to homelab on PRD/roadmap/vision changes)
- File system (read/write docs in homelab clone)

**Does not need:**

- `kubectl` / `flux` / k8s cluster access (no infra work)
- NATS write beyond a small allowlist:
  `swarm.events.prd_opened`, `swarm.events.prd_merged`,
  `swarm.events.roadmap_updated`, `swarm.events.vision_updated`

The persona's `mcp.json` mirrors devbot's minus the implementation
servers (no language servers, no test runners, no docker tooling).

---

## 9. Chart-level integration

Adding pmbot is mechanically the same as any other agent (parametric
persona, no image rebuild):

1. **Chart-bundled example persona** — new directory
   `charts/agent-smith/agents/example-pmbot/` containing:
   - `CLAUDE.md` — example persona (this spec rendered into prose
     + the persona pattern from devbot/infrabot examples)
   - `mcp.json` — example MCP server config (empty or matching
     devbot's minimal set)
2. **Production persona** — operator supplies a real `pmbot`
   persona via a ConfigMap (`pmbot-persona`), referenced from
   `agents[].configMapRef` in the chart values consumed by
   homelab's HelmRelease.
3. **HelmRelease values bump in homelab** — add a new `agents[]`
   entry:

   ```yaml
   - name: pmbot
     existingSecret: pmbot-secrets
     configMapRef: pmbot-persona
     matrix:
       botUserId: "@pmbot:lab.sherodtaylor.dev"
       allowedUsers: "@sherod:lab.sherodtaylor.dev,@devbot:lab.sherodtaylor.dev,@infrabot:lab.sherodtaylor.dev"
     agentRepos: [sherodtaylor/homelab, sherodtaylor/agent-smith]
     primaryRepo: homelab
   ```

4. **Matrix bot account** — Sherod creates the `@pmbot:lab.sherodtaylor.dev`
   account on his homeserver, generates an access token, and stores
   the credentials in Infisical for ESO to sync into
   `pmbot-secrets`.

The chart itself needs no template changes; pmbot is just another
entry in the existing `agents[]` array consumed by the StatefulSet
loop.

---

## 10. Migration impact

- **Devbot / infrabot personas (`agents/_shared/CLAUDE.md`)** —
  add a one-paragraph "Working with pmbot" section: when to summon
  it, what pmbot owns vs what stays with devbot/infrabot, mention
  forms. Same structure as the existing "Working With InfraBot"
  section in devbot's persona.
- **Existing PRs at the moment of cutover** — pmbot does not
  retroactively review PRs that pre-date its deployment. First
  PRD pmbot writes is the one that establishes the convention.
- **Vision / roadmap docs do not exist yet** — pmbot's first
  substantive work is to draft `vision.md` and `roadmap.md` in
  collaboration with Sherod. Until those exist pmbot can still
  intake PRDs but cannot do alignment gating (nothing to align
  against).

---

## 11. Risks and trade-offs

- **PR noise from PRD-alignment reviews.** Pmbot commenting on every
  PR could create comment fatigue. Mitigation: when the PR clearly
  satisfies the PRD, pmbot posts a single `Reviewed for PRD
  alignment — ✅ no findings` line rather than a full review block.
- **Authority ambiguity.** Pmbot is advisory; if devbot/infrabot
  ignore its pushback, Sherod is the arbiter. Risk is that pmbot's
  pushback is treated as procedural noise. Mitigation: pmbot
  escalates by `@`-mentioning Sherod, not by repeating itself.
- **Bootstrapping problem.** No vision.md / roadmap.md exists today,
  so the first pmbot session has to produce them before it can do
  alignment gating. Acceptable; that first session *is* the
  product-direction conversation Sherod has been wanting.
- **Three-bot rooms.** With three agents in the same Matrix rooms,
  mention discipline gets tighter. The loop-prevention rule (max 3
  agent messages in a row without a human) already covers this.
- **PRD vs technical-spec confusion.** Risk that pmbot drifts into
  technical detail or devbot/infrabot drift into product detail.
  Mitigation: PRD template explicitly excludes architecture/code,
  and persona explicitly says "no implementation opinions."

---

## 12. Out of scope

- Scheduled / cron-driven pmbot routines (e.g. "weekly roadmap
  review"). Not for v1 — can layer on later via the existing
  schedule skill.
- A dedicated `#product` Matrix room.
- A separate `pmbot-fleet` HelmRelease — pmbot ships under the
  existing `agent-smith-fleet` HR alongside devbot/infrabot.
- Vision / roadmap / PRDs for repos beyond the homelab fleet.
- Automatic PR template enforcement (e.g. "block PR if no PRD
  link") — pmbot uses comments, not workflow gates.

---

## 13. Open questions for Sherod's review

- **Spec home for this very document.** Currently in
  `agent-smith/docs/superpowers/specs/` since the chart change
  lives in agent-smith. Move to homelab if you prefer all design
  artifacts in one place.
- **Initial vision.md content.** Pmbot will start blank and
  interview you, but if you already have a few sentences in mind,
  pre-seeding them shortens the first session.
- **Roadmap granularity.** Quarterly milestones, monthly, or just
  "next 5 things ordered"? PRD template assumes ordering only;
  flag if you want a calendar.
