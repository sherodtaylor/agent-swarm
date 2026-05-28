# agent-smith platform branding — design

**Status:** draft — pending review
**Owner:** DevBot
**Last updated:** 2026-05-28

A platform-wide positioning shift. Today the project sells itself as
"AI engineering agents running in Kubernetes." That framing front-loads
Kubernetes (which scares first-time readers) and back-loads what the
project actually is: a framework for running a sandbox workforce of
autonomous engineering agents that act as force multipliers for a
solo or small team.

This spec defines the brand: name, tagline, voice, what we're selling
and what we're not, where the brand applies (website, README,
runtime), and the visual extensions (pixel-sprite crew portraits per
Sherod's prior ask). It is **copy + IA + a small visual addition** —
no architectural change.

---

## 1. Why now

- The README's current opener (`Your engineering team, running in Kubernetes.`)
  and the website's hero copy both lead with K8s. Two real readers
  this week noted the K8s framing as a barrier to "what does it
  actually do for me?"
- The project surface area has grown into something genuinely
  framework-shaped: channel-pluggable I/O, per-agent capability
  scopes (proposed), shared cross-agent memory (planned), egress
  credential boundary (iron-proxy), pre-authored personas, plugin
  reconciler. A reader who can't see *the framework* through the
  K8s framing misses the value.
- The pixel-sprite "crew portrait" idea (Sherod, 2026-05-28) needs
  somewhere intentional to live — not a one-off design tweak, but a
  brand element that signals "these are characters with personalities
  in a sandbox workforce."

---

## 2. What we're selling

**A framework for running a sandbox workforce of autonomous AI
engineers as force multipliers.**

Three load-bearing words:

- **Framework** — agent-smith is a *system you build agents in*, not a
  finished product. Personas, channels, capability scopes, memory,
  credential boundary, observability are framework primitives. New
  agents are configuration in the framework, not new code.
- **Sandbox workforce** — every agent runs in an isolated, observable,
  recoverable workspace. Mistakes are bounded; experiments are cheap.
  Production-grade substrate (real cluster, real PRs, real audit log)
  but with sandbox properties (single operator, recoverable state, no
  blast radius outside the allowlist). This is the *posture* that
  separates agent-smith from a chatbot toy or a runaway autonomous
  agent.
- **Force multipliers** — the agents amplify a solo or small team.
  One human direction in Matrix → ten units of engineering work
  shipped autonomously. The pitch is leverage, not replacement.

Kubernetes is the **reference deployment** — the way *we* run the
framework. Not the product.

---

## 3. What we're NOT selling

Named to prevent drift.

- **Not a SaaS / hosted product.** Self-hosted only. No "sign up here"
  page.
- **Not a chatbot.** Agents *ship code*. The Matrix interface is the
  control surface, not the deliverable.
- **Not a Kubernetes operator.** K8s is one deployment target. The
  framework runs anywhere you can run a long-lived process with
  filesystem + network egress.
- **Not "fully autonomous AGI."** The pitch is force-multiplication
  for a human in the loop, not replacement.
- **Not "the bots write themselves."** Personas are authored by
  humans; the framework is what makes them tractable to author.

---

## 4. Brand vocabulary

Words to use, words to avoid.

| Use | Avoid | Why |
|---|---|---|
| **Framework** | "platform", "system" | Framework is the right tier: opinionated, composable, you build *in* it |
| **Sandbox workforce** | "fleet", "swarm", "team of bots" | "Workforce" reads as productive; "sandbox" sets the safe-to-experiment posture |
| **Force multipliers** | "AI assistants", "copilots", "ChatOps" | Multiplier framing is the value prop |
| **Agent** (or named agent: DevBot, InfraBot) | "bot", "chatbot", "AI" | Agent reads as autonomous worker; bot reads as scripted toy |
| **The operator** | "the user", "the human" | Distance is the brand (already established) |
| **Channel** (Matrix, Discord, …) | "chat", "messaging" | Channel is the framework primitive; chat is the UX |
| **Capability scope** | "permission", "RBAC" | Capability is the framework primitive |
| **Egress credential boundary** | "secret management", "vault" | Specific + technical; ties to iron-proxy |
| **Persona** | "config", "definition" | Persona names what an agent IS |
| **Reference deployment** | "deployment", "install" (when describing K8s) | Demotes K8s from product to demo |
| `kubectl exec` / cluster commands | leading copy | Belongs in `/docs`, never in hero or first paragraph |

Tone rules (carry over from the existing voice section):
- Declarative, terse, terminal-grade. No marketing verbs ("empower",
  "supercharge"). No exclamation marks. No "we" except in product copy
  where the framework is the implicit subject.
- Read like a man page that respects the reader's time.

---

## 5. Tagline + hero copy (canonical, post-shift)

The README is canonical for tagline/sub; website mirrors verbatim per
the existing sync convention.

### 5.1 Tagline (1 line, oversized display)

> **A sandbox workforce — autonomous engineering agents as force multipliers.**

(Open-question alternatives in §10 if Sherod prefers shorter.)

### 5.2 Hero sub (2 sentences)

> **agent-smith is a framework for running long-lived AI engineering
> agents that operate as peers — they read code, open PRs, review
> each other's work, and learn from what they ship. Deploy them
> however you run servers; the reference deployment is one Kubernetes
> StatefulSet per agent.**

### 5.3 Status strip (chrome — unchanged)

> `● running · 2 agents · PRs this week: 11 · last release: v0.1.23`

### 5.4 CTAs

> `$ read the docs ›` · `$ view on github ›` · `$ meet the crew ↓`

The third CTA scrolls to the crew portraits (§7).

---

## 6. Landing IA — post-shift

Current order is fine; per-section copy shifts to lead with framework
concepts. K8s sinks to "Under the hood — reference deployment."

1. **Hero** (faux-tmux pane chrome unchanged) — tagline + sub + status
   strip + dual CTA per §5
2. **What this is** — framework concepts in plain prose. Three
   primitives that *together* make the framework: persona +
   channel-pluggable I/O + egress credential boundary. K8s is
   conspicuously not in this section.
3. **What your team can do** — unchanged 5 bullets; they already
   describe framework-level behaviour
4. **Meet the crew** *(new)* — pixel-sprite portraits + one-line
   bio per agent (DevBot — code; InfraBot — infra). Anchored from
   the §5.4 CTA. See §7.
5. **Under the hood — reference deployment** *(renamed from
   "Under the hood")* — opens with "*The way we run agent-smith.
   Yours can be different.*" then the existing K8s/iron-proxy
   architecture summary
6. **The crew right now** — build-time current status block
   (unchanged)
7. **Footer** — unchanged

---

## 7. Visual extension — pixel-sprite crew portraits

A new brand element rooted in the existing terminal-as-zine palette.
Per Sherod's prior ask (2026-05-28): "visualize the team agents pixel
style depicting the crew."

### 7.1 Constraints

- **Hand-rolled SVG**, `viewBox="0 0 16 16"`, scales 4×–8× via CSS.
- Pixels are `<rect width="1" height="1">` elements. Color is
  `currentColor` so they inherit from the section's text color (lets
  the palette tokens drive recoloring without re-authoring the SVG).
- Per-agent accent: one or two pixels in the agent's signature accent
  (DevBot: `--accent` phosphor-green; InfraBot: `--accent-warn` amber)
  to differentiate at a glance.
- Total visual asset budget: ≤ 8 KB raw (two SVGs combined).
  Well inside the existing 60 KB Lottie + JS sub-budget.
- A11y: each portrait is `role="img"` with a descriptive
  `aria-label` ("DevBot — code agent. 16×16 pixel portrait, …").
  No animation in v1.

### 7.2 Personality direction (for the engineer drawing them)

- **DevBot** — code agent. Wears a tiny baseball cap or visor (Sherod
  himself wears one); maybe holding a wrench or a `$` prompt sigil.
  Phosphor-green accent on the eyes or cap.
- **InfraBot** — infra agent. Hard hat or hard-hat-like silhouette;
  more "operator at the console" energy. Amber accent on the helmet
  rim or chest LED.
- Same skeleton (head shape, body) so they read as a pair from the
  same crew.

Drawing tool: any pixel editor (Aseprite, Piskel, lospec). Export
path: copy the SVG content into `website/src/components/SpriteDevbot.astro`
and `SpriteInfrabot.astro` (small Astro wrappers around the inline
SVG).

### 7.3 Where the sprites appear

Site:
- `/` Meet the crew section (§6.4) — large
- `/` Hero right pane status line *(optional)* — tiny `16×16` next
  to each agent in the audit-tail entries
- `/log` log feed — tiny `16×16` next to the agent column

README:
- One row of sprites under the tagline (raster fallback to a PNG
  if rendered in GitHub's README — GitHub strips `<svg>` inline,
  must be a file reference). Generated PNGs at 64×64 +
  Retina @2x committed to `website/public/sprites/` and
  embedded with `![DevBot](sprites/devbot.png)`.

---

## 8. Where the brand applies (surfaces + sync convention)

Single canonical source: **`README.md`**. Everywhere else syncs.
Existing convention from `docs/superpowers/specs/2026-05-26-agent-smith-website-design.md`
remains: README moves → small sync PR updates the rest.

| Surface | What carries the brand |
|---|---|
| `README.md` | Tagline + hero sub + "What this is" + "What your team can do" + sprite row |
| `website/` (Astro Starlight) | Hero copy (verbatim from README), Meet the crew section (sprites), Under the hood = reference deployment |
| `docs/` (in-repo Markdown) | Section openers use the framework vocabulary (§4); K8s scoped to runbooks |
| `agents/_shared/CLAUDE.md` | Persona rules already use "agent" + "operator" — extend to use "framework" and "channel" where currently saying "platform" or "chat" |
| GitHub social card | One-line tagline + sprite row (export from the website's hero) |
| GitHub topics | Replace `kubernetes` from first position; lead with `ai-agents`, `framework`, `autonomous-agents`, `claude-code` |

---

## 9. Out of scope (named to prevent scope creep)

- **Logo.** No logo design in v1. The wordmark `agent-smith` set in
  JetBrains Mono is enough.
- **Animated brand assets** (Lottie). Sprite portraits are static SVG;
  any animation would push past the existing JS payload budget.
- **Color palette change.** Existing palette (`--accent` phosphor green,
  `--accent-warn` amber, `--accent-err` rust) carries the brand. No
  new tokens.
- **Renaming the project.** `agent-smith` stays.
- **Multi-tenant / SaaS framing.** Out of scope per §3.

---

## 10. Open questions

1. **Tagline length.** §5.1 is 56 chars. Sherod may prefer shorter
   ("Autonomous engineering, in a sandbox." 38 chars / "An autonomous
   engineering workforce." 38 chars / "Engineers, not chatbots." 24
   chars). Pick one.
2. **Hero sub — keep the K8s sentence?** §5.2 ends with "the
   reference deployment is one Kubernetes StatefulSet per agent."
   Sherod's "Kubernetes scares people" framing might prefer dropping
   the K8s mention entirely from hero (push it down to §6.5). Worth a
   call.
3. **Sprite personality directions** (§7.2) — DevBot=cap+wrench /
   InfraBot=hard-hat is one read. Open to other directions (e.g.,
   robot/android, tarot-card characters, retro Apple //e operator,
   etc.).
4. **README sprite rendering** — PNG fallback (committed binaries) or
   SVG `<img src=".../devbot.svg">` (GitHub renders external SVGs as
   raster anyway)? Either works; PNG is more predictable.
5. **GitHub social card** — should the implementation include generating
   the 1280×640 PNG, or leave that as a follow-up?
