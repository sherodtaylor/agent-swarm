# Matrix communication — how the bots talk to rooms

This is the reference for how `agent-smith` agents send messages to Matrix.
Per-agent behavioral rules live in `agents/_shared/CLAUDE.md`
("How Matrix replies work" + "Communication style"); this doc is the deeper
"why" behind those rules and the things the agent CLAUDE.md is too terse to
explain.

## The mental model

Each agent pod runs one `claude` process with the
[`claude-code-channel-matrix`](https://github.com/zekker6/claude-code-channel-matrix)
plugin loaded as a **channel**. Channels are Claude Code's MCP-server-based
bridge between an external platform (Matrix, in this case) and the running
session. They are bidirectional but **not transparent**:

1. The plugin polls Matrix and adds 👀 to every message that matches the
   `allowedUsers` allowlist. The ack is automatic — Claude is not involved.
2. The matched message is delivered into Claude's session as a
   `<channel source="matrix" room_id="!…" sender="@…" event_id="$…" room_name="#…">…</channel>`
   tag.
3. Claude reads it, decides what to do, does the work — and the conversational
   text Claude generates stays in the local terminal. **It does not leave the
   pod.**
4. To put anything in Matrix, Claude must explicitly call the plugin's `reply`
   tool. Outbound text only reaches Matrix via that tool.

This last point is the gotcha that broke the bots between v0.1.13 and v0.1.15:
the narration rules said "post in the room" but never specified the mechanism,
so agents generated text into the terminal and the rooms stayed silent.

## The three reply destinations

The Matrix plugin's `reply` tool can route a message to one of three places
depending on which parameters are set alongside `room_id`. The exact parameter
names are defined by the plugin's runtime schema — check the schema on startup
rather than hard-coding names.

| Destination          | When to use it                                                            | Visibility                                                                          |
| -------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Main room**        | Plan, final result, verification command                                  | Visible to anyone in the room without opening a thread                              |
| **Thread**           | Task progress, reasoning, intermediate findings, "still working" notes    | Visible only when someone clicks into the thread off the original message           |
| **Native reply**     | A question, confirmation, or choice that requires the sender to act       | Triggers a notification for the original sender; thread-only posts do not           |

The `event_id` from the inbound `<channel>` tag is the anchor for both
threading and native replies. Same ID, different roles in the tool call.

## Why split the cadence

The room/thread split is the difference between a usable channel and one that
nobody reads. The main room is a feed of **what was asked and what got done**.
The thread is the **debugging trace** — anyone who wants to know *how* the
agent got there opens the thread and follows the reasoning step by step.

If everything piles into the main room you get the v0.1.14 problem: a wall of
"1/3 done", "still working: linting", "kustomize passes" updates between every
real outcome. The room becomes useless for catching up cold, and Sherod has to
scroll through ten messages to find the one verification command he actually
needs.

The native-reply destination exists for a separate reason: **notifications**.
Threaded messages do not page Sherod's phone; a native reply does. Use it
sparingly — only when the agent is genuinely blocked on user input.

## Configuration touch points

| Setting / file                                | Purpose                                                                                                    |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `~/.claude/channels/matrix/.env`              | `MATRIX_HOMESERVER_URL`, `MATRIX_ACCESS_TOKEN`, `MATRIX_BOT_USER_ID` — written by `setup.sh` from env vars |
| `~/.claude/channels/matrix/access.json`       | `allowedUsers` list + `ackReaction` (👀) — what triggers the bot and what reaction confirms receipt        |
| `agents/_shared/settings.json` (enabledPlugins) | Registers `matrix@claude-code-channel-matrix` as an enabled plugin                                       |
| `scripts/claude-loop.sh` (`--dangerously-load-development-channels`) | Loads the plugin as a development channel (it's not on the official allowlist)         |

## How to verify a change

After modifying the agent CLAUDE.md or the plugin config, tag the bot:

```
@devbot ping — confirming new behaviour
```

You should observe, in this order:

1. 👀 reaction on your message within ~2 s (plugin is alive)
2. A short plan message in the main room within ~5 s (`reply` to room is working)
3. If the task has more than one step: a thread appears under your message and
   the per-step updates land there (thread routing is working)
4. A final-result message in the main room with a verification command
   (round-trip complete)

If 1 fires but 2 doesn't, the bot can read but can't write — check the access
token's room permissions and the agent pod logs:

```bash
kubectl logs -n agents <agent>-0 --tail=100 | grep -E 'reply|matrix'
```

If 2 fires but 3 doesn't, the plugin schema may not expose threading, or the
agent CLAUDE.md is out of sync with the current plugin behaviour — degrade to
"everything in the main room" is acceptable in that case.

## See also

- `agents/_shared/CLAUDE.md` — the in-bot behavioural rules (source of truth
  for agent behaviour)
- [`zekker6/claude-code-channel-matrix`](https://github.com/zekker6/claude-code-channel-matrix)
  — the plugin source and its README for the tool schemas
- [Claude Code channels](https://code.claude.com/docs/en/channels) — official
  docs for the channel architecture (Telegram/Discord/iMessage examples)
- [Channels reference](https://code.claude.com/docs/en/channels-reference) —
  protocol-level detail for the `notifications/claude/channel` envelope and
  reply tools
