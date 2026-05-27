# Matrix channel plugin — threading + tools + step support

**Status:** approved 2026-05-27 (Sherod via Matrix brainstorm)
**Owner:** DevBot
**Last updated:** 2026-05-27
**Upstream target:** `zekker6/claude-code-channel-matrix`
**Working fork:** `sherodtaylor/claude-code-channel-matrix`

A spec for three additive changes to the Matrix channel plugin used by
agent-smith bots. Goal: close the capability gap between the official
Discord plugin (`anthropics/claude-plugins-official/external_plugins/discord`)
and the current Matrix plugin, while staying upstream-mergeable.

The intent is to **upstream all three changes** back to
`zekker6/claude-code-channel-matrix`. The fork is a staging ground for
testing in agent-smith pods; once upstream accepts, we flip the bot's
plugin marketplace pin back to `zekker6/...` and retire the fork
branch.

**Research grounding:**
- `docs/research/2026-05-27-discord-channel-plugin-deepdive.md`
- `docs/research/2026-05-27-matrix-threading-tools-research.md`

---

## 1. Goals + non-goals

### Goals

1. The `reply` tool gains a per-call `reply_to_event_id` parameter so
   the model can thread a follow-up under any prior event without
   relying on the room-global `MATRIX_THREADS` env config.
2. A new `edit_message` tool lets the model update a prior bot
   message in place (Matrix `m.replace`), enabling Discord's
   "working… → result" progress pattern.
3. The plugin sends a Matrix typing indicator (`PUT /typing`) on
   inbound messages so the user sees "agent is typing" while Claude
   generates, gated by `MATRIX_TYPING=true` (default **on**).
4. The MCP server's `instructions` field is expanded with explicit
   guidance for when to use each new tool, mirroring the Discord
   plugin's pattern (see `external_plugins/discord/server.ts:455-465`).
5. A new `skills/threading/SKILL.md` is auto-discovered and exposes
   `/matrix:thread` for live operator inspection of the bot's current
   thread state.

### Non-goals (deliberately not in scope)

- **Per-tool-call posts.** The plugin cannot observe Claude
  mid-turn — tool calls happen inside the Claude Code runtime, not
  via MCP. Progress reporting stays model-driven through
  `reply` + `edit_message`. This is the same constraint the Discord
  plugin lives with.
- **Reaction-based progress streams.** Considered; rejected as too
  noisy for a working bot.
- **Multiplexer changes.** `mux.ts` is the most edit-active region in
  the upstream plugin; we leave it untouched to keep upstream merges
  clean. Threading + edit + typing all live in `server.ts` only.
- **Custom homeserver support beyond what upstream already does.**
- **Encrypted rooms.** Upstream doesn't support them; we don't add it.

---

## 2. The three feature additions

### 2.1 Per-call threading: `reply_to_event_id`

#### API change

The existing `reply` tool gains one optional argument:

```ts
reply({
  room_id: string,
  text: string,
  reply_to_event_id?: string,   // NEW — Matrix event_id to thread under
  html?: string,                 // (unchanged, if already present)
})
```

#### Behaviour

When `reply_to_event_id` is set, the outbound Matrix event carries
**both** relation forms for client compatibility (per `matrix-spec`
threading.md §11.42 and rich_replies.md §11.39):

```jsonc
{
  "msgtype": "m.text",
  "body": "fallback prose",
  "format": "org.matrix.custom.html",
  "formatted_body": "<p>html body</p>",
  "m.relates_to": {
    "rel_type": "m.thread",
    "event_id": "<thread-root-event-id>",
    "is_falling_back": true,
    "m.in_reply_to": {
      "event_id": "<reply_to_event_id>"
    }
  }
}
```

The thread root is the **earliest event in the thread** (whatever the
client passed `reply_to_event_id` against, OR — if that event itself
is already part of a thread — the existing thread's root). Resolution:
the plugin fetches `/_matrix/client/v3/rooms/{roomId}/event/{eventId}`
and reads `m.relates_to.event_id` if present; otherwise the passed
event_id IS the thread root.

`is_falling_back: true` is the spec-blessed signal that non-thread
clients should render this as a regular reply, while thread-aware
clients render it inside the thread (threading.md §11.42.2).

#### Backwards compat

The room-global `MATRIX_THREADS` env config stays. When set, every
reply is threaded under `MATRIX_THREAD_ROOT_ROOM_ID`+
`MATRIX_THREAD_PROJECT` (current behaviour). When `reply_to_event_id`
is also passed on a specific call, **the per-call value wins** for
that call only.

#### Edit ownership validation

(Companion behaviour for `edit_message` below, surfaced here so the
event-fetch infrastructure is shared.) Before sending `m.replace` the
plugin fetches the target event and asserts `sender == bot user`;
otherwise returns a structured tool error to Claude rather than
letting the server return `M_FORBIDDEN`.

### 2.2 `edit_message` tool

#### API

```ts
edit_message({
  room_id: string,
  event_id: string,     // event_id of bot's prior message to edit
  text: string,         // new body
  html?: string,        // new formatted body (if applicable)
})
```

Returns `{ event_id: string }` — the event_id of the replacement
event (which is distinct from the original; Matrix represents edits as
new events that replace the original).

#### Behaviour

Wire format per `matrix-spec/event_replacements.md` §11.40:

```jsonc
{
  "msgtype": "m.text",
  "body": " * fallback for old clients",
  "format": "org.matrix.custom.html",
  "formatted_body": " * old-client fallback HTML",
  "m.new_content": {
    "msgtype": "m.text",
    "body": "new body",
    "format": "org.matrix.custom.html",
    "formatted_body": "<p>new html</p>"
  },
  "m.relates_to": {
    "rel_type": "m.replace",
    "event_id": "<original-event-id>"
  }
}
```

The asterisk-prefixed body is the spec-recommended fallback for
clients that don't render `m.new_content` — it lets users see "this
message was edited to: …" without thread-aware rendering.

#### Edit + thread interaction

Per `event_replacements.md` §11.40.5, `m.replace` preserves the
original event's thread membership implicitly. **But** several
real-world clients (older Element, FluffyChat ≤ 1.x, custom forks)
require the replacement event to **also** carry `m.thread` on its own
`m.relates_to` for correct in-thread rendering.

The plugin therefore:
1. Fetches the original event.
2. If the original is part of a thread (its `m.relates_to.rel_type`
   is `m.thread`), the replacement event carries
   `m.relates_to: { rel_type: 'm.replace', event_id: <orig>, 'm.in_reply_to': { event_id: <orig> } }`
   AND a separate top-level `m.relates_to` is not possible (Matrix
   only allows one `rel_type` per event), so we follow the spec
   recommendation: set `m.relates_to.rel_type: 'm.replace'` and rely
   on the server's implicit thread preservation. Clients that need
   explicit thread membership can be addressed by a future PR
   upstream.
3. **Acceptance criterion**: edits posted to a thread render under
   the thread in Element Web ≥ 1.11 and in CLI clients like
   `matrix-commander`.

#### Edit ownership validation

Before sending the edit, the plugin fetches
`/_matrix/client/v3/rooms/{roomId}/event/{eventId}` and verifies
`sender == ${MATRIX_BOT_USER_ID}`. If not, return a tool error:

```json
{ "error": "edit_message: target event was not authored by this bot" }
```

This matches Discord's pattern (`server.ts:594-606` checks
`message.author.id === client.user.id`) and avoids the confusing
`M_FORBIDDEN` server error.

### 2.3 Typing indicator on inbound

#### Behaviour

When the plugin's `/sync` loop sees an inbound message that passes
the access gate (i.e. would wake Claude), the plugin fires:

```
PUT /_matrix/client/v3/rooms/{roomId}/typing/{botUserId}
Body: { "typing": true, "timeout": 30000 }
```

Fire-and-forget — no waiting, no retry. The 30s timeout auto-expires
without us needing to call it again. If Claude's turn takes longer
than 30s, we don't refresh (matches Discord's behaviour:
`server.ts:852-854` doesn't refresh either).

No tool — this is plugin chrome, the model doesn't trigger it.

#### Config

Gated by `MATRIX_TYPING` env var. **Default: `true`** (per Sherod's
refinement). Operators who want to disable typing (e.g. in shared
rooms where bot typing would confuse other humans) set
`MATRIX_TYPING=false`.

### 2.4 MCP `instructions` field expansion

The plugin already populates the MCP server's `instructions` field
(equivalent to Discord's `server.ts:455-465`). We expand it with
explicit guidance for the three new behaviours:

```
- Set `reply_to_event_id` on follow-ups that continue a prior topic;
  it puts your reply in the right thread without requiring
  MATRIX_THREADS to be globally enabled. Pass the event_id from the
  most recent <channel> tag's `event_id=` attribute.
- Use `edit_message` for "working..." status updates that should NOT
  trigger a push notification on the user's phone. Send a fresh
  `reply` for the final result so the phone pings.
- Don't `edit_message` someone else's event — only your own. The
  plugin returns an error if you try.
- The plugin sets the Matrix typing indicator automatically when an
  inbound message arrives. Don't try to manage it via tools.
```

These are MCP-server-level instructions that ride with every
`<channel>` notification, so the model sees them as context on every
turn.

### 2.5 `skills/threading/SKILL.md`

New user-invocable skill, auto-discovered from the
`skills/<name>/SKILL.md` convention the plugin already uses for
`access` and `configure`.

`/matrix:thread` operations:
- `current` — print the active thread root for this conversation
  (resolved by walking `m.relates_to.event_id` chain).
- `branch <event_id>` — instruct the bot to start its next reply as
  a new thread off the given event (sets a one-shot
  `reply_to_event_id`).
- `flat` — instruct the bot to drop the active thread anchor on its
  next reply (post to the room root).

These are sherod-only operator escape-hatches; the model is **not**
expected to use them.

---

## 3. `access.json` schema additions

```jsonc
{
  // ...existing keys (allowedUsers, ackReaction)...

  "replyToMode": "first" | "all" | "off",   // NEW. Default: "first"
}
```

Semantics:

- `"first"` (default, matches Discord's `replyToMode` at
  `external_plugins/discord/server.ts:626`): when a long reply is
  split into multiple chunks (>maxTextBytes), only chunk 0 carries
  the `m.in_reply_to` reference. Subsequent chunks are plain replies
  to the room.
- `"all"`: every chunk carries the `m.in_reply_to` reference. More
  visible in clients but spammier.
- `"off"`: chunks 2+ never carry the reference, **and even chunk 0's
  `m.in_reply_to` is dropped**, but `m.thread` membership is
  preserved. Useful in flat rooms where reply chrome adds noise.

**Crucial clarification**: `replyToMode: "off"` does **not** suppress
per-call `reply_to_event_id` routing. Per-call always wins for *which
thread* the reply goes to; `replyToMode` only governs the
`m.in_reply_to` chrome attached to each chunk.

---

## 4. File structure (in the fork)

We keep all changes additive and in distinct file regions where
possible, to make `git merge upstream/main` clean.

```
server.ts                          # modified — add tools + typing
  ├─ existing reply()              # extended with reply_to_event_id
  ├─ NEW edit_message()            # new tool, ~80 lines
  ├─ NEW assertOwnedByBot()        # helper for edit ownership check
  ├─ NEW typingIndicator()         # helper for the PUT /typing call
  ├─ existing /sync loop           # one-line addition to fire typing
  └─ existing instructions string  # extended copy

server.test.ts                     # NEW — see §6 below

skills/threading/SKILL.md          # NEW

# access.json: NO file change; the schema additions are in code only
# (zod schema + docs). Operators who want the new fields add them
# manually to their existing access.json; defaults are coded so
# absence is non-breaking.
```

**Total estimated diff:** ~250 lines added, ~10 lines modified in
`server.ts`, ~120 lines in `server.test.ts`, ~30 lines in
`SKILL.md`.

---

## 5. Fork + upstream-sync strategy

### Repository setup

```
sherodtaylor/claude-code-channel-matrix    # our fork
├── main                                    # tracks upstream/main verbatim, never edited
├── feat/matrix-channel-additions           # our work branch; rebased on main
└── (additional branches for in-flight upstream PRs as they get raised)

upstream remote: zekker6/claude-code-channel-matrix
```

### Workflow

1. **Implement on `feat/matrix-channel-additions`** in the fork. One
   PR per logical feature: per-call threading, edit_message, typing,
   skills/instructions. Each PR is self-contained and small.
2. **Test in agent-smith pods**: temporarily flip the plugin
   marketplace pin in `agents/_shared/settings.json`:
   ```jsonc
   "extensions": {
     "marketplaces": [
       "sherodtaylor/claude-code-channel-matrix"   // temp during test
     ]
   }
   ```
   AND in `scripts/setup.sh`:
   ```bash
   claude plugin marketplace add sherodtaylor/claude-code-channel-matrix
   claude plugin install matrix@claude-code-channel-matrix
   ```
   This is the documented "test on fork" path.
3. **Open upstream PRs to `zekker6/claude-code-channel-matrix`**.
   Cite Matrix spec sections and provide concrete behaviour
   diff vs. upstream main.
4. **Once an upstream PR merges**, immediately rebase
   `feat/matrix-channel-additions` onto the new upstream main —
   shrinks our diff.
5. **Once all upstream PRs merge**, flip the marketplace pin in
   `agents/_shared/settings.json` and `setup.sh` back to
   `zekker6/claude-code-channel-matrix`, retire
   `feat/matrix-channel-additions`. Fork remains as a passive
   safety net.

### What to avoid touching

Per the research (`docs/research/2026-05-27-matrix-threading-tools-research.md`
§D), three areas in `server.ts` are the most edit-active upstream and
should be left alone unless absolutely necessary:

- `runSyncLoop()` and `runMultiplexerSyncLoop()` — the inbound `/sync`
  pull. Touch only at one well-defined point (`typingIndicator(roomId)`
  call) where the gate accepts a message.
- `mux.ts` (the Unix-socket multiplexer) — not modified.
- The credential/login boot path — not modified.

### Upstream-PR-friendly commit hygiene

- One feature per PR.
- Each PR ≤ 250 LOC where possible.
- Tests included in the same PR (no separate "tests later" PR).
- Spec citations in PR body (matrix-spec section references).
- Mention this design doc as motivation.

---

## 6. Testing strategy

Tests live in `server.test.ts` alongside `server.ts` (matches the
upstream layout — there's no existing test file, so we introduce one
with this PR).

### What to test

| Behaviour | Test approach |
|---|---|
| `reply(reply_to_event_id)` constructs correct wire body | mock `client.sendEvent`; assert payload shape |
| `reply(reply_to_event_id)` resolves thread root via fetch | mock `/event/<id>` returning a threaded event; assert root is propagated |
| `edit_message` constructs `m.replace` wire body | mock `client.sendEvent`; assert payload shape including `m.new_content` and `* `-prefixed fallback body |
| `edit_message` rejects non-bot targets | mock `/event/<id>` returning `sender: '@someone:other'`; assert tool error |
| typing indicator fires on inbound | mock `client.sendTyping`; tail the `/sync` loop; assert single call per gated message |
| typing indicator respects `MATRIX_TYPING=false` | env override; assert `sendTyping` never called |
| `replyToMode: "first"` puts in_reply_to on chunk 0 only | construct a >maxTextBytes reply; assert two outbound events, only first carries the reference |
| `replyToMode: "all"` puts it on every chunk | same as above, all chunks carry |
| `replyToMode: "off"` strips in_reply_to but keeps thread | assert no in_reply_to, but if thread was set, m.relates_to.rel_type stays `m.thread` |

### Test runner

Bun (`bun test`) — matches the existing zekker6 plugin's tooling and
avoids adding a new dependency.

### Mock layer

A minimal `Client` test double in `server.test.ts` that records the
last `sendEvent` payload and lets tests assert against it. No real
HTTP, no real Matrix homeserver.

### Out of scope for tests

- Integration against a real `synapse` or `conduit` homeserver.
  Would catch real edge cases but adds operational cost. Deferred to a
  follow-up; manual smoke-test against `lab.sherodtaylor.dev` is
  enough for v1.
- Multi-client rendering verification. Documented as a manual check
  in the PR description.

---

## 7. Rollout plan

### Phase A — fork + implement
1. Fork `zekker6/claude-code-channel-matrix` to
   `sherodtaylor/claude-code-channel-matrix`.
2. Add `upstream` remote pointing at `zekker6/...`.
3. Branch `feat/matrix-channel-additions` from `main`.
4. Implement per §2 + §3 + §6.
5. Open a single integrated PR on the fork for self-review (DevBot
   opens, InfraBot reviews).

### Phase B — test in agent-smith
1. Pin agent-smith's plugin marketplace at
   `sherodtaylor/claude-code-channel-matrix` (temporary).
2. Bump agent-smith chart version, deploy to devbot + infrabot pods.
3. Smoke-test via Matrix: per-call threading, edit_message in a
   visible "working… → result" flow, typing indicator on inbound.
4. Iterate on the fork until smoke-tests pass.

### Phase C — upstream
1. Split the fork's integrated PR into 3-4 small upstream PRs:
   one per feature (threading, edit, typing, instructions+skill).
2. Open against `zekker6/claude-code-channel-matrix`.
3. Address review.

### Phase D — flip back
1. Once all upstream PRs merge, flip the plugin marketplace pin in
   `agents/_shared/settings.json` + `scripts/setup.sh` back to
   `zekker6/claude-code-channel-matrix`.
2. Bump agent-smith chart version.
3. Deploy. Confirm same behaviour with upstream-only.
4. Retire `feat/matrix-channel-additions` on the fork (delete
   branch). Fork's `main` keeps tracking upstream as a safety net.

---

## 8. Operational concerns

- **Token scope.** No new permissions needed; all four behaviours
  use the existing Matrix access token's `room_event` permissions.
- **Push notifications.** Edits explicitly do NOT push. Documented in
  the expanded `instructions` field so the model knows to use a
  fresh `reply` for the final user-visible result.
- **Rate limits.** Typing indicator + 1 reply per inbound is well
  under Matrix's default rate limit. `edit_message` adds at most one
  extra event per progress update; model is instructed to use it
  sparingly.
- **Telemetry / observability.** Each new outbound event still
  flows through the existing log line in `server.ts` (the upstream
  plugin logs every sendEvent). No new logging needed.
- **Failure modes.**
  - `edit_message` on non-bot target → tool error to Claude (handled).
  - `edit_message` on a deleted/redacted event → server returns
    `M_NOT_FOUND`; surface as tool error.
  - `reply_to_event_id` referring to an event from a different room
    → server rejects; surface as tool error.
  - Typing-indicator PUT fails (network) → fire-and-forget, log warn,
    continue.

---

## 9. Out of scope (named explicitly, deferred)

- **Step-level / tool-call streaming.** Not possible from plugin
  layer — Claude tool-calls happen inside the Claude Code runtime,
  invisible to MCP. Stays model-driven via `reply` + `edit_message`.
- **`fetch_messages` tool** (Discord has one). Useful but not on the
  critical path; defer to a follow-up PR if a real need surfaces.
- **`download_attachment` tool.** Matrix media handling is already
  partial in the upstream plugin (inbound `m.image` auto-downloads);
  the model-callable tool variant is deferred.
- **Encrypted rooms (E2EE).** Upstream doesn't support; we don't
  either.
- **Multiplexer (`mux.ts`) changes.** Deliberately untouched to
  protect upstream merge cleanliness.
- **Reaction-based progress.** Considered, rejected as noisy.

---

## 10. Open implementation questions

Not blocking spec approval; nail down during writing-plans.

1. **Test framework for the fork.** Bun is implicit (the plugin
   already uses Bun); but should we ALSO add a Vitest fallback for
   maintainers without Bun? Recommend Bun-only.
2. **Where does `assertOwnedByBot` cache?** If a single Claude turn
   calls `edit_message` 5 times on the same event_id, we fetch the
   event 5 times. Cheap LRU? Recommend yes — `Map<string, Promise<...>>`
   bounded at 32 entries.
3. **Should we PR the typing indicator to upstream FIRST** (smallest,
   safest change) **to validate the upstream contribution flow**
   before the larger threading PR? Recommend yes — minimum-viable
   upstream proof.
4. **Naming**: `reply_to_event_id` (snake_case matching MCP tool arg
   convention in Discord plugin) or `replyToEventId` (camelCase
   matching JS norms)? Recommend `reply_to_event_id` for consistency
   with Discord's `reply_to`.
