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

## Available tools

The plugin exposes two MCP tools to Claude:

### `reply`

```
room_id  string  required  — from the <channel> tag
text     string  required  — plain text body
html     string  optional  — HTML-formatted body (org.matrix.custom.html)
```

Sends a message to the room. If the server has a **thread configured** for this
room (see "Threading" below), the message is automatically posted into that
thread. Claude has no parameter to choose between "main room" and "thread" — the
routing is transparent and server-controlled.

### `react`

```
room_id   string  required  — from the <channel> tag
event_id  string  required  — from the <channel> tag (the message to react to)
emoji     string  required
```

Adds an emoji reaction to a specific message event.

## Threading

The plugin maintains a `threadRootByRoom` map: one thread root event ID per room,
established at startup via `ensureThreadRoot()` or loaded from `threads.json`.
When a thread root exists for a room:

- All bot `reply` calls in that room are posted inside the thread (the plugin
  injects `m.relates_to: { rel_type: "m.thread", event_id: <root> }` automatically)
- Only messages already in that thread are delivered to Claude; main-room messages
  are filtered out

When no thread root is configured, `reply` posts to the main room directly.

**Claude has no per-call control over threading.** There is no thread-root or
reply-to parameter in the `reply` tool. The routing decision is baked into the
server config at startup.

## Current limitations

- **No selective thread routing** — Claude cannot post "this message to main room,
  that message to thread" within the same room. It's all-or-nothing per room.
- **No native reply capability** — `reply` does not accept a `reply_to` or
  `in_reply_to` parameter. A native Matrix reply (which triggers a notification
  for the sender) is not currently possible via this tool.
- **No per-message reaction** — `react` reacts to `event_id`, which must come
  from the inbound `<channel>` tag. Claude cannot react to its own outbound
  messages (no event ID is returned by `reply`).

These limitations are in the plugin's current implementation
([`zekker6/claude-code-channel-matrix`](https://github.com/zekker6/claude-code-channel-matrix)).
A plugin PR adding `thread_root_id` and `reply_to` parameters to `reply` would
unlock the full room/thread/notification routing model.

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

1. 👀 reaction on your message within ~2 s (plugin is alive and `allowedUsers` matches)
2. A plan message in the room within ~5 s (the `reply` tool is working)
3. Progress updates as the task runs (narration rules firing)
4. A final-result message with a verification command (round-trip complete)

If 1 fires but 2 doesn't, the bot can read but can't write — check the access
token's room permissions and the agent pod logs:

```bash
kubectl logs -n agents <agent>-0 --tail=100 | grep -E 'reply|matrix'
```

If 2 fires but 3 doesn't, the agent CLAUDE.md narration rules aren't being followed
or the agent is suppressing progress updates. Check the session logs inside the pod:

```bash
kubectl exec -n agents <agent>-0 -- tmux capture-pane -pt 0 -S -1000
```

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
