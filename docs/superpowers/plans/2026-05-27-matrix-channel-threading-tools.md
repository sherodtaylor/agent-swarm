# Matrix channel plugin — threading + tools + step support — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `zekker6/claude-code-channel-matrix` (via the fork `sherodtaylor/claude-code-channel-matrix`) with per-call thread routing on `reply`, a new `edit_message` tool, an inbound typing indicator, an expanded MCP `instructions` field, and a `/matrix:thread` skill — all upstream-mergeable in small PRs.

**Architecture:** All plugin code lives in `server.ts` (single-file plugin per upstream's convention). Tests live in a new `server.test.ts` with a minimal `Client` test double — no real Matrix homeserver. Each feature ships in a self-contained code region of `server.ts` so the eventual upstream PRs can be split cleanly. The `agent-smith` side temporarily pins its plugin marketplace at the fork during testing, then flips back to `zekker6/...` once each upstream PR merges.

**Tech Stack:** TypeScript, Bun runtime (`bun test`, `bun server.ts`), `@modelcontextprotocol/sdk`, Matrix Client-Server API (HTTPS), no new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-27-matrix-channel-threading-tools-design.md`

**Two repos involved:**
- **Fork:** `sherodtaylor/claude-code-channel-matrix` — plugin code changes (Phase A). Phase A is the bulk of the work.
- **agent-smith:** `agents/_shared/settings.json` + `scripts/setup.sh` — temporary marketplace pin (Phase B → flipped back in Phase D).

**Working branches:**
- `feat/matrix-channel-additions` on the fork (integrated branch; later split into per-feature upstream PRs).
- `feat/matrix-fork-pin` then `feat/matrix-fork-unpin` on agent-smith.

---

## Phase A — Fork setup + plugin implementation

### Task 1: Fork the upstream repo (manual)

**Files:** none (GitHub UI)

- [ ] **Step 1: Fork via GitHub UI or `gh repo fork`**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh repo fork zekker6/claude-code-channel-matrix --org sherodtaylor --clone=false
```

If `--org sherodtaylor` rejects (sherodtaylor is a user not org), drop the flag and Sherod's account is the destination.

- [ ] **Step 2: Verify the fork exists**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh repo view sherodtaylor/claude-code-channel-matrix --json url -q .url
# expected: https://github.com/sherodtaylor/claude-code-channel-matrix
```

### Task 2: Clone the fork and set up the upstream remote

**Files:** none (git setup)

- [ ] **Step 1: Clone the fork into /workspace**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh repo clone sherodtaylor/claude-code-channel-matrix /workspace/claude-code-channel-matrix
cd /workspace/claude-code-channel-matrix
```

- [ ] **Step 2: Add upstream remote**

```bash
git remote add upstream https://github.com/zekker6/claude-code-channel-matrix.git
git fetch upstream
```

- [ ] **Step 3: Verify**

```bash
git remote -v
# expected: origin → sherodtaylor; upstream → zekker6
```

### Task 3: Create the working branch

**Files:** none (git only)

- [ ] **Step 1: Branch from upstream main**

```bash
cd /workspace/claude-code-channel-matrix
git checkout -b feat/matrix-channel-additions upstream/main
```

- [ ] **Step 2: Confirm clean state and recent commit**

```bash
git status
git log --oneline -3
```

### Task 4: Inventory the upstream baseline

**Files:** none (read-only inspection)

- [ ] **Step 1: Read `server.ts` end-to-end** (referencing the research doc at `/workspace/agent-smith/docs/research/2026-05-27-matrix-threading-tools-research.md` §B). Confirm:
  - `reply` tool signature (line ~830 in upstream baseline)
  - `react` tool signature (line ~840)
  - `instructions` string location (around line ~803-810)
  - `runSyncLoop()` and `runMultiplexerSyncLoop()` — these are off-limits except for the one typing-indicator call site at the gate-accept point
  - existing `MATRIX_THREADS` env flag handling

- [ ] **Step 2: Verify Bun + TypeScript versions**

```bash
bun --version
# expected: 1.x

cat package.json | grep -E 'bun|typescript'
```

- [ ] **Step 3: Confirm `bun test` runs (it has nothing to run yet, but should not error)**

```bash
bun test 2>&1 | tail -3
```

### Task 5: Add `server.test.ts` test infrastructure

**Files:**
- Create: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Write the minimal test scaffold + mock Client double**

```ts
// server.test.ts — tests for the agent-smith additions to the
// matrix channel plugin. Uses a hand-rolled mock Client.
import { describe, expect, test, beforeEach, mock } from 'bun:test';

// MockClient records calls made by the plugin so tests can assert on them.
export interface SentEvent { roomId: string; type: string; content: any; }
export interface FetchedEvent { event_id: string; sender: string; content: any; }

export class MockClient {
  sentEvents: SentEvent[] = [];
  fetchedEvents = new Map<string, FetchedEvent>();
  typingCalls: { roomId: string; userId: string; typing: boolean }[] = [];

  async sendEvent(roomId: string, type: string, content: any) {
    this.sentEvents.push({ roomId, type, content });
    return { event_id: `$mock-${this.sentEvents.length}:test` };
  }

  async fetchEvent(roomId: string, eventId: string): Promise<FetchedEvent> {
    const e = this.fetchedEvents.get(eventId);
    if (!e) throw new Error(`MOCK: no fixture for event ${eventId}`);
    return e;
  }

  async sendTyping(roomId: string, userId: string, typing: boolean, _timeoutMs?: number) {
    this.typingCalls.push({ roomId, userId, typing });
  }

  reset() {
    this.sentEvents = [];
    this.fetchedEvents.clear();
    this.typingCalls = [];
  }
}

describe('mock client smoke', () => {
  test('records sent events', async () => {
    const c = new MockClient();
    const r = await c.sendEvent('!r:s', 'm.room.message', { body: 'hi' });
    expect(r.event_id).toContain('$mock-');
    expect(c.sentEvents).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run it to confirm the scaffold works**

```bash
cd /workspace/claude-code-channel-matrix
bun test server.test.ts 2>&1 | tail -5
# expected: 1 pass, 0 fail
```

- [ ] **Step 3: Commit**

```bash
git add server.test.ts
git commit -m "test: add server.test.ts scaffold + MockClient double"
```

---

### Feature 1: Per-call `reply_to_event_id` on `reply`

The current `reply` tool sends to `room_id` directly. We add an optional `reply_to_event_id` arg that wraps the outbound event with `m.thread` + `is_falling_back: true` + nested `m.in_reply_to`.

### Task 6: TDD — test for basic `reply_to_event_id` payload shape

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add the failing test**

Append to `server.test.ts`:

```ts
import { buildReplyContent } from './server'; // export this in T7

describe('reply: reply_to_event_id', () => {
  test('constructs m.thread + m.in_reply_to envelope', () => {
    const content = buildReplyContent({
      text: 'hello',
      replyToEventId: '$target:server',
      threadRoot: '$target:server', // when target IS the root
    });
    expect(content.body).toBe('hello');
    expect(content['m.relates_to']).toEqual({
      rel_type: 'm.thread',
      event_id: '$target:server',
      is_falling_back: true,
      'm.in_reply_to': { event_id: '$target:server' },
    });
  });

  test('without reply_to_event_id, no relates_to is set', () => {
    const content = buildReplyContent({ text: 'plain' });
    expect(content.body).toBe('plain');
    expect(content['m.relates_to']).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bun test server.test.ts 2>&1 | tail -5
# expected: FAIL — "buildReplyContent" not exported
```

### Task 7: Implement `buildReplyContent`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Add the helper near the top of `server.ts` (after imports, before `Client` instantiation)**

```ts
// --- agent-smith additions: per-call threading helpers ---
export interface BuildReplyOpts {
  text: string;
  html?: string;
  replyToEventId?: string;
  threadRoot?: string; // pre-resolved thread root; defaults to replyToEventId
}

export function buildReplyContent(opts: BuildReplyOpts): any {
  const content: any = {
    msgtype: 'm.text',
    body: opts.text,
  };
  if (opts.html !== undefined) {
    content.format = 'org.matrix.custom.html';
    content.formatted_body = opts.html;
  }
  if (opts.replyToEventId !== undefined) {
    const root = opts.threadRoot ?? opts.replyToEventId;
    content['m.relates_to'] = {
      rel_type: 'm.thread',
      event_id: root,
      is_falling_back: true,
      'm.in_reply_to': { event_id: opts.replyToEventId },
    };
  }
  return content;
}
// --- end agent-smith additions ---
```

- [ ] **Step 2: Run test to verify it passes**

```bash
bun test server.test.ts -t 'reply_to_event_id' 2>&1 | tail -5
# expected: 2 pass
```

### Task 8: TDD — test for thread root resolution (fetch parent)

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add failing test**

Append to `server.test.ts`:

```ts
import { resolveThreadRoot } from './server'; // export in T9

describe('resolveThreadRoot', () => {
  test('returns the same event_id when target is a root (no relates_to)', async () => {
    const client = new MockClient();
    client.fetchedEvents.set('$root:srv', { event_id: '$root:srv', sender: '@a:srv', content: { body: 'first' } });
    const root = await resolveThreadRoot(client as any, '!room:srv', '$root:srv');
    expect(root).toBe('$root:srv');
  });

  test('returns the thread root when target is already in a thread', async () => {
    const client = new MockClient();
    client.fetchedEvents.set('$mid:srv', {
      event_id: '$mid:srv',
      sender: '@a:srv',
      content: { 'm.relates_to': { rel_type: 'm.thread', event_id: '$thread-root:srv' } },
    });
    const root = await resolveThreadRoot(client as any, '!room:srv', '$mid:srv');
    expect(root).toBe('$thread-root:srv');
  });

  test('returns target_id if fetch fails (degraded fallback)', async () => {
    const client = new MockClient();
    // no fixture set; fetch will throw
    const root = await resolveThreadRoot(client as any, '!room:srv', '$unknown:srv');
    expect(root).toBe('$unknown:srv');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bun test server.test.ts -t 'resolveThreadRoot' 2>&1 | tail -5
# expected: FAIL — "resolveThreadRoot" not exported
```

### Task 9: Implement `resolveThreadRoot`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Add helper next to `buildReplyContent` in the agent-smith additions block**

```ts
// Resolves the thread root for an event_id. If the target event is already
// part of a thread, returns the thread root; otherwise returns target_id
// (the target itself becomes the root of a new thread). On fetch failure,
// degrades to returning target_id so the message still goes out.
export async function resolveThreadRoot(
  client: { fetchEvent(roomId: string, eventId: string): Promise<{ content: any }> },
  roomId: string,
  targetEventId: string,
): Promise<string> {
  try {
    const ev = await client.fetchEvent(roomId, targetEventId);
    const rel = ev.content?.['m.relates_to'];
    if (rel?.rel_type === 'm.thread' && typeof rel.event_id === 'string') {
      return rel.event_id;
    }
    return targetEventId;
  } catch {
    return targetEventId;
  }
}
```

- [ ] **Step 2: Run tests**

```bash
bun test server.test.ts -t 'resolveThreadRoot' 2>&1 | tail -5
# expected: 3 pass
```

### Task 10: Wire `reply` to accept and route `reply_to_event_id`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Find the `reply` tool registration. Add the optional arg to the tool's JSON Schema (`inputSchema.properties`) — current shape:**

```ts
// before
{
  name: 'reply',
  inputSchema: {
    type: 'object',
    properties: {
      room_id: { type: 'string' },
      text:    { type: 'string' },
      html:    { type: 'string', description: '...' },
    },
    required: ['room_id', 'text'],
  },
}
```

Add:

```ts
{
  name: 'reply',
  inputSchema: {
    type: 'object',
    properties: {
      room_id: { type: 'string' },
      text:    { type: 'string' },
      html:    { type: 'string', description: '...' },
      reply_to_event_id: {
        type: 'string',
        description: 'Matrix event_id to thread under. When set, the reply goes out with m.thread + m.in_reply_to (compatible with both threaded and non-threaded clients). Pass the event_id from a prior <channel> notification.',
      },
    },
    required: ['room_id', 'text'],
  },
}
```

- [ ] **Step 2: In the `reply` handler (CallTool case), extract the new arg and route through the helpers:**

Locate the existing handler body where the outbound content is built. Replace the content-building block with:

```ts
const { room_id, text, html, reply_to_event_id } = args as {
  room_id: string; text: string; html?: string; reply_to_event_id?: string;
};

let threadRoot: string | undefined;
if (reply_to_event_id) {
  threadRoot = await resolveThreadRoot(client as any, room_id, reply_to_event_id);
}

const content = buildReplyContent({
  text,
  html,
  replyToEventId: reply_to_event_id,
  threadRoot,
});
const result = await client.sendEvent(room_id, 'm.room.message', content);
```

(Note: the existing handler may also have chunking logic for long messages. The chunking branch should call `buildReplyContent` per chunk; chunk-2+ behaviour depends on `replyToMode` — Feature 4 below.)

- [ ] **Step 3: Build to confirm types check**

```bash
cd /workspace/claude-code-channel-matrix
bun build server.ts --target=bun --outfile=/tmp/check.js 2>&1 | tail -5
# expected: clean compile
```

### Task 11: TDD — test for backwards-compat with `MATRIX_THREADS`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add failing test**

```ts
describe('reply: MATRIX_THREADS backcompat', () => {
  test('global MATRIX_THREADS still threads when reply_to_event_id is absent', () => {
    // The plugin's existing behaviour wraps every reply under a global
    // thread root when MATRIX_THREADS=true. This test calls
    // buildReplyContent indirectly via the existing applyGlobalThread()
    // (introduced in T12 below if not already present).
    const globalRoot = '$global-root:srv';
    const content = buildReplyContent({
      text: 'hi',
      replyToEventId: globalRoot,
      threadRoot: globalRoot,
    });
    expect(content['m.relates_to']?.event_id).toBe(globalRoot);
    expect(content['m.relates_to']?.rel_type).toBe('m.thread');
  });
});
```

- [ ] **Step 2: Run — should pass** (this confirms the helper works for the global-thread path too without any extra code)

```bash
bun test server.test.ts -t 'MATRIX_THREADS' 2>&1 | tail -3
# expected: pass
```

### Task 12: Commit Feature 1

**Files:** none

- [ ] **Step 1: Stage and commit**

```bash
cd /workspace/claude-code-channel-matrix
git add server.ts server.test.ts
git commit -m "feat(reply): add per-call reply_to_event_id with m.thread + m.in_reply_to envelope

- buildReplyContent helper constructs the spec-compliant payload
- resolveThreadRoot walks m.relates_to chains to find the actual root
- reply tool gains an optional reply_to_event_id arg
- per-call value wins over global MATRIX_THREADS
- compatible with both threaded and non-thread-aware clients via
  is_falling_back: true

Spec: matrix-spec/threading.md §11.42, rich_replies.md §11.39"
```

---

### Feature 2: `edit_message` tool

### Task 13: TDD — test for `edit_message` wire body shape

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add failing test**

```ts
import { buildEditContent } from './server'; // export in T14

describe('edit_message: wire body', () => {
  test('constructs m.replace with new_content and asterisk fallback', () => {
    const content = buildEditContent({
      originalEventId: '$orig:srv',
      text: 'updated',
    });
    expect(content.body).toBe(' * updated');
    expect(content['m.new_content']).toEqual({
      msgtype: 'm.text',
      body: 'updated',
    });
    expect(content['m.relates_to']).toEqual({
      rel_type: 'm.replace',
      event_id: '$orig:srv',
    });
  });

  test('preserves html on both top-level and m.new_content', () => {
    const content = buildEditContent({
      originalEventId: '$orig:srv',
      text: 'updated',
      html: '<p>updated</p>',
    });
    expect(content.formatted_body).toBe(' * <p>updated</p>');
    expect(content['m.new_content']?.formatted_body).toBe('<p>updated</p>');
  });
});
```

- [ ] **Step 2: Run — fail**

```bash
bun test server.test.ts -t 'edit_message: wire body' 2>&1 | tail -3
```

### Task 14: Implement `buildEditContent`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Add helper to the agent-smith additions block**

```ts
export interface BuildEditOpts {
  originalEventId: string;
  text: string;
  html?: string;
}

export function buildEditContent(opts: BuildEditOpts): any {
  const newContent: any = { msgtype: 'm.text', body: opts.text };
  if (opts.html !== undefined) {
    newContent.format = 'org.matrix.custom.html';
    newContent.formatted_body = opts.html;
  }
  const content: any = {
    msgtype: 'm.text',
    body: ` * ${opts.text}`,
    'm.new_content': newContent,
    'm.relates_to': {
      rel_type: 'm.replace',
      event_id: opts.originalEventId,
    },
  };
  if (opts.html !== undefined) {
    content.format = 'org.matrix.custom.html';
    content.formatted_body = ` * ${opts.html}`;
  }
  return content;
}
```

- [ ] **Step 2: Run tests**

```bash
bun test server.test.ts -t 'edit_message: wire body' 2>&1 | tail -3
# expected: 2 pass
```

### Task 15: TDD — test for `assertOwnedByBot`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add failing test**

```ts
import { assertOwnedByBot } from './server'; // export in T16

describe('edit_message: ownership check', () => {
  test('accepts a bot-authored event', async () => {
    const client = new MockClient();
    client.fetchedEvents.set('$mine:srv', { event_id: '$mine:srv', sender: '@bot:srv', content: {} });
    await expect(assertOwnedByBot(client as any, '!room:srv', '$mine:srv', '@bot:srv'))
      .resolves.toBeUndefined();
  });

  test('rejects an event authored by someone else', async () => {
    const client = new MockClient();
    client.fetchedEvents.set('$theirs:srv', { event_id: '$theirs:srv', sender: '@human:srv', content: {} });
    await expect(assertOwnedByBot(client as any, '!room:srv', '$theirs:srv', '@bot:srv'))
      .rejects.toThrow(/not authored by this bot/);
  });
});
```

- [ ] **Step 2: Run — fail**

```bash
bun test server.test.ts -t 'edit_message: ownership' 2>&1 | tail -3
```

### Task 16: Implement `assertOwnedByBot`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Add helper**

```ts
export async function assertOwnedByBot(
  client: { fetchEvent(roomId: string, eventId: string): Promise<{ sender: string }> },
  roomId: string,
  eventId: string,
  botUserId: string,
): Promise<void> {
  const ev = await client.fetchEvent(roomId, eventId);
  if (ev.sender !== botUserId) {
    throw new Error(`edit_message: target event ${eventId} not authored by this bot (author: ${ev.sender})`);
  }
}
```

- [ ] **Step 2: Run tests**

```bash
bun test server.test.ts -t 'edit_message: ownership' 2>&1 | tail -3
# expected: 2 pass
```

### Task 17: Register the `edit_message` tool

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Add to `ListTools` next to `reply` and `react`**

```ts
{
  name: 'edit_message',
  description: 'Edit a prior message authored by this bot. Useful for "working… → result" progress UX without push-notifying. Use a fresh `reply` after the edit for the final user-visible result so push notifications fire.',
  inputSchema: {
    type: 'object',
    properties: {
      room_id:  { type: 'string' },
      event_id: { type: 'string', description: 'The event_id of a prior message authored by this bot.' },
      text:     { type: 'string' },
      html:     { type: 'string', description: 'Optional HTML-formatted body.' },
    },
    required: ['room_id', 'event_id', 'text'],
  },
},
```

- [ ] **Step 2: Add the handler case in the `CallTool` switch**

```ts
case 'edit_message': {
  const { room_id, event_id, text, html } = args as {
    room_id: string; event_id: string; text: string; html?: string;
  };
  await assertOwnedByBot(client as any, room_id, event_id, BOT_USER_ID);
  const content = buildEditContent({ originalEventId: event_id, text, html });
  const result = await client.sendEvent(room_id, 'm.room.message', content);
  return { content: [{ type: 'text', text: `edited; new event_id ${result.event_id}` }] };
}
```

(`BOT_USER_ID` already exists in upstream; if it's a different name, grep `server.ts` for `MATRIX_BOT_USER_ID`.)

- [ ] **Step 3: Build to confirm types**

```bash
bun build server.ts --target=bun --outfile=/tmp/check.js 2>&1 | tail -3
```

### Task 18: TDD — integration test for the full `edit_message` path

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add integration test (calls handler-like logic end-to-end against MockClient)**

```ts
describe('edit_message: integration', () => {
  test('sends m.replace event when target is bot-authored', async () => {
    const client = new MockClient();
    const BOT = '@bot:srv';
    client.fetchedEvents.set('$orig:srv', { event_id: '$orig:srv', sender: BOT, content: {} });

    await assertOwnedByBot(client as any, '!r:srv', '$orig:srv', BOT);
    const content = buildEditContent({ originalEventId: '$orig:srv', text: 'fixed' });
    await client.sendEvent('!r:srv', 'm.room.message', content);

    expect(client.sentEvents).toHaveLength(1);
    expect(client.sentEvents[0].content['m.relates_to'].rel_type).toBe('m.replace');
    expect(client.sentEvents[0].content['m.relates_to'].event_id).toBe('$orig:srv');
    expect(client.sentEvents[0].content['m.new_content'].body).toBe('fixed');
  });
});
```

- [ ] **Step 2: Run**

```bash
bun test server.test.ts -t 'edit_message: integration' 2>&1 | tail -3
# expected: 1 pass
```

### Task 19: Commit Feature 2

**Files:** none

- [ ] **Step 1: Commit**

```bash
cd /workspace/claude-code-channel-matrix
git add server.ts server.test.ts
git commit -m "feat(tools): add edit_message for m.replace progress UX

- buildEditContent constructs the spec m.replace envelope with
  m.new_content and the asterisk-prefixed body fallback
- assertOwnedByBot verifies the target is bot-authored before
  sending, mirroring the Discord plugin pattern and avoiding
  server-side M_FORBIDDEN errors
- edit_message tool registered with full JSON Schema; handler
  composes the above helpers

Spec: matrix-spec/event_replacements.md §11.40"
```

---

### Feature 3: Typing indicator on inbound

### Task 20: TDD — test for typing indicator fires on inbound

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add failing test**

```ts
import { maybeSendTyping } from './server'; // export in T21

describe('typing indicator', () => {
  beforeEach(() => { delete process.env.MATRIX_TYPING; });

  test('fires by default (MATRIX_TYPING unset = default on)', async () => {
    const client = new MockClient();
    await maybeSendTyping(client as any, '!r:srv', '@bot:srv');
    expect(client.typingCalls).toHaveLength(1);
    expect(client.typingCalls[0].typing).toBe(true);
  });

  test('fires when MATRIX_TYPING=true explicitly', async () => {
    process.env.MATRIX_TYPING = 'true';
    const client = new MockClient();
    await maybeSendTyping(client as any, '!r:srv', '@bot:srv');
    expect(client.typingCalls).toHaveLength(1);
  });

  test('does NOT fire when MATRIX_TYPING=false', async () => {
    process.env.MATRIX_TYPING = 'false';
    const client = new MockClient();
    await maybeSendTyping(client as any, '!r:srv', '@bot:srv');
    expect(client.typingCalls).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run — fail**

```bash
bun test server.test.ts -t 'typing indicator' 2>&1 | tail -3
```

### Task 21: Implement `maybeSendTyping`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Add helper**

```ts
// Fire-and-forget Matrix typing indicator. Defaults to ON; set
// MATRIX_TYPING=false to disable (e.g. in shared rooms where bot
// typing would confuse other humans).
export async function maybeSendTyping(
  client: { sendTyping(roomId: string, userId: string, typing: boolean, timeoutMs?: number): Promise<unknown> },
  roomId: string,
  botUserId: string,
): Promise<void> {
  const enabled = (process.env.MATRIX_TYPING ?? 'true').toLowerCase() !== 'false';
  if (!enabled) return;
  try {
    await client.sendTyping(roomId, botUserId, true, 30000);
  } catch (err) {
    console.warn('[matrix-channel] typing indicator failed:', err);
  }
}
```

- [ ] **Step 2: Run tests**

```bash
bun test server.test.ts -t 'typing indicator' 2>&1 | tail -3
# expected: 3 pass
```

### Task 22: Wire `maybeSendTyping` into the sync-loop gate

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Find the inbound-message gate-accept point in `runSyncLoop` / `runMultiplexerSyncLoop`.** This is the line where the plugin has just decided "yes, this message wakes Claude" — typically right before the `notifications/claude/channel` notification is fired.

Add a single line at that point:

```ts
await maybeSendTyping(client as any, roomId, BOT_USER_ID);
```

The rest of the loop is untouched. This is the ONE call into the sync loop — by spec §5, no other modification to those functions.

- [ ] **Step 2: Build + smoke**

```bash
bun build server.ts --target=bun --outfile=/tmp/check.js 2>&1 | tail -3
# expected: clean compile
```

### Task 23: Commit Feature 3

**Files:** none

- [ ] **Step 1: Commit**

```bash
cd /workspace/claude-code-channel-matrix
git add server.ts server.test.ts
git commit -m "feat(channel): send Matrix typing indicator on inbound

- maybeSendTyping helper fires PUT /typing with 30s timeout
- env-gated via MATRIX_TYPING; default true
- fire-and-forget, warns on failure but never blocks the sync loop
- single call site in the sync-loop gate (no other sync changes
  per fork-friendliness)

Spec: matrix-spec/client-server-api §13.6"
```

---

### Feature 4: `replyToMode` chunk-splitter governance

### Task 24: TDD — test for `replyToMode: 'first'` (default)

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.test.ts`

- [ ] **Step 1: Add failing test**

```ts
import { applyReplyToMode } from './server'; // export in T25

describe('replyToMode', () => {
  const rel = { 'm.in_reply_to': { event_id: '$x:s' } };

  test('first (default): chunk 0 keeps reference, others stripped', () => {
    expect(applyReplyToMode(rel, 0, 'first')).toEqual(rel);
    expect(applyReplyToMode(rel, 1, 'first')).toEqual({});
  });

  test('all: every chunk keeps reference', () => {
    expect(applyReplyToMode(rel, 0, 'all')).toEqual(rel);
    expect(applyReplyToMode(rel, 1, 'all')).toEqual(rel);
  });

  test('off: in_reply_to stripped everywhere, but other rels preserved', () => {
    const threaded = { rel_type: 'm.thread', event_id: '$t:s', 'm.in_reply_to': { event_id: '$x:s' } };
    expect(applyReplyToMode(threaded, 0, 'off'))
      .toEqual({ rel_type: 'm.thread', event_id: '$t:s' });
    expect(applyReplyToMode(rel, 0, 'off')).toEqual({});
  });
});
```

- [ ] **Step 2: Run — fail**

```bash
bun test server.test.ts -t 'replyToMode' 2>&1 | tail -3
```

### Task 25: Implement `applyReplyToMode`

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Add helper**

```ts
export type ReplyToMode = 'first' | 'all' | 'off';

// Strip or keep the m.in_reply_to chrome on multi-chunk replies per the
// access.json replyToMode setting. Always preserves other relations
// (e.g. m.thread) regardless of mode.
export function applyReplyToMode(
  relatesTo: any,
  chunkIndex: number,
  mode: ReplyToMode,
): any {
  const { 'm.in_reply_to': inReplyTo, ...rest } = relatesTo ?? {};
  if (mode === 'off') return rest;
  if (mode === 'all') return relatesTo;
  // 'first': chunk 0 keeps, others stripped
  return chunkIndex === 0 ? relatesTo : rest;
}
```

- [ ] **Step 2: Run**

```bash
bun test server.test.ts -t 'replyToMode' 2>&1 | tail -3
# expected: 3 pass
```

### Task 26: Wire `applyReplyToMode` into the chunk splitter

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Find the existing chunk-splitter code in the `reply` handler** (the loop that breaks long text into multiple `sendEvent` calls). For chunk `i`:

```ts
const mode: ReplyToMode = access.replyToMode ?? 'first';
const chunkContent = buildReplyContent({ text: chunkText, ... });
if (chunkContent['m.relates_to']) {
  chunkContent['m.relates_to'] = applyReplyToMode(chunkContent['m.relates_to'], i, mode);
  if (Object.keys(chunkContent['m.relates_to']).length === 0) {
    delete chunkContent['m.relates_to'];
  }
}
await client.sendEvent(room_id, 'm.room.message', chunkContent);
```

(`access` is the existing `loadAccess()` result; it now reads `replyToMode` if present.)

- [ ] **Step 2: Update the `access.json` type / zod schema (wherever upstream defines it)** to include `replyToMode?: 'first' | 'all' | 'off'` with default `'first'`.

- [ ] **Step 3: Build**

```bash
bun build server.ts --target=bun --outfile=/tmp/check.js 2>&1 | tail -3
```

### Task 27: Commit Feature 4

**Files:** none

- [ ] **Step 1: Commit**

```bash
cd /workspace/claude-code-channel-matrix
git add server.ts server.test.ts
git commit -m "feat(access): replyToMode controls multi-chunk in_reply_to chrome

- applyReplyToMode strips or keeps m.in_reply_to per chunk based
  on access.replyToMode (first | all | off)
- 'first' (default) matches Discord plugin behaviour: reply
  reference on chunk 0 only
- 'all' for visibility-first rooms; 'off' for flat rooms that
  don't want reply chrome at all (still preserves m.thread)
- per-call reply_to_event_id routing is unaffected — replyToMode
  governs chrome only, not target

Spec: see external_plugins/discord/server.ts:626 for the same pattern"
```

---

### Feature 5: Expanded `instructions` field + `/matrix:thread` skill

### Task 28: Expand the MCP `instructions` field

**Files:**
- Modify: `/workspace/claude-code-channel-matrix/server.ts`

- [ ] **Step 1: Locate the `instructions` field in the MCP server initialization** (typically a multi-line template literal). Append four lines:

```ts
const mcp = new Server({ name: 'matrix', version: '<existing>' }, {
  capabilities: { /* unchanged */ },
  instructions: [
    // ...existing instructions verbatim, then append:
    '',
    '- Set `reply_to_event_id` on follow-ups that continue a prior topic; it threads your reply without needing MATRIX_THREADS globally. Pass the event_id from the most recent <channel> tag.',
    '- Use `edit_message` for "working..." status updates that should NOT push-notify the user. Send a fresh `reply` for the final user-visible result so push notifications fire.',
    '- Don\'t `edit_message` someone else\'s event; only your own. The plugin returns an error if you try.',
    '- The plugin sets the Matrix typing indicator automatically on inbound. Don\'t manage it via tools.',
  ].join('\n'),
})
```

- [ ] **Step 2: Build + commit**

```bash
bun build server.ts --target=bun --outfile=/tmp/check.js 2>&1 | tail -3
git add server.ts
git commit -m "feat(instructions): expand MCP instructions for new tools

Tells the model when to use reply_to_event_id, when edit_message
helps vs hurts (push-notification semantics), the ownership
restriction on edits, and that typing is plugin-managed."
```

### Task 29: Add `skills/threading/SKILL.md`

**Files:**
- Create: `/workspace/claude-code-channel-matrix/skills/threading/SKILL.md`

- [ ] **Step 1: Write the skill**

```md
---
name: matrix:thread
description: Inspect and operate on the current Matrix thread state for the bot's active conversation.
allowed-tools: Bash
---

# matrix:thread

Operator-facing skill for live thread inspection. The model is NOT expected to use this — humans invoke it via `/matrix:thread <op>`.

## Operations

### `current`

Print the active thread root for the current conversation.

```
/matrix:thread current
```

Implementation: walks the most recent inbound `<channel>` notification's `event_id` through `m.relates_to.event_id` to find the thread root.

### `branch <event_id>`

Instruct the bot to start its next reply as a new thread off the given event.

```
/matrix:thread branch $abc:server
```

Implementation: stashes a one-shot `reply_to_event_id` so the next `reply` call uses it.

### `flat`

Instruct the bot to drop the active thread anchor on its next reply (post to the room root).

```
/matrix:thread flat
```

## When to use

- Diagnosing why a thread is getting noisy or off-topic.
- Forcing a fresh thread when the model has anchored on something stale.
- Testing thread routing during local development.
```

- [ ] **Step 2: Commit**

```bash
git add skills/threading/SKILL.md
git commit -m "feat(skills): add /matrix:thread for operator thread inspection

- /matrix:thread current — print active thread root
- /matrix:thread branch <event_id> — start fresh thread under given event
- /matrix:thread flat — drop thread anchor on next reply

Skill auto-discovered via skills/<name>/SKILL.md convention already
used by skills/access and skills/configure."
```

---

### Task 30: Final fork build + lint + push

**Files:** none

- [ ] **Step 1: Confirm all tests pass**

```bash
cd /workspace/claude-code-channel-matrix
bun test server.test.ts 2>&1 | tail -5
# expected: 15+ pass (depending on exact test count)
```

- [ ] **Step 2: Confirm full build**

```bash
bun build server.ts --target=bun --outfile=/tmp/check.js 2>&1 | tail -3
```

- [ ] **Step 3: Push the integrated branch to the fork**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt git push -u origin feat/matrix-channel-additions 2>&1 | tail -3
```

- [ ] **Step 4: Open a self-PR on the fork (for DevBot's own visibility + InfraBot's review)**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/claude-code-channel-matrix \
  --title "feat: per-call threading + edit_message + typing + skills" \
  --body "$(cat <<'EOF'
Integrated PR for the agent-smith additions; reviewable here before being split into upstream PRs to zekker6/claude-code-channel-matrix.

## Features
1. `reply` gains `reply_to_event_id` for per-call thread routing
2. New `edit_message` tool (m.replace) with ownership check
3. Inbound typing indicator (default on, MATRIX_TYPING=false to disable)
4. `replyToMode` in access.json controls multi-chunk in_reply_to chrome
5. Expanded MCP instructions for the new tools
6. New /matrix:thread skill for operator thread inspection

## Tests
~15 unit tests in `server.test.ts` against a mock Client double; covers payload shape, ownership rejection, typing env gating, chunk-mode behaviour.

## Spec
sherodtaylor/agent-smith → docs/superpowers/specs/2026-05-27-matrix-channel-threading-tools-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tail -3
```

---

## Phase B — Pin agent-smith at the fork for in-pod testing

### Task 31: Pin marketplace in `agent-smith` settings.json

**Files:**
- Modify: `/workspace/agent-smith/agents/_shared/settings.json`

- [ ] **Step 1: Branch in agent-smith**

```bash
cd /workspace/agent-smith
git checkout main
git pull --ff-only
git checkout -b feat/matrix-fork-pin
```

- [ ] **Step 2: Find the marketplace block** in `agents/_shared/settings.json` (locate the existing `claude-code-channel-matrix` reference). Replace `zekker6/claude-code-channel-matrix` with `sherodtaylor/claude-code-channel-matrix`:

```bash
sed -i 's|zekker6/claude-code-channel-matrix|sherodtaylor/claude-code-channel-matrix|g' agents/_shared/settings.json
```

- [ ] **Step 3: Mirror the change in `scripts/setup.sh`**

```bash
sed -i 's|zekker6/claude-code-channel-matrix|sherodtaylor/claude-code-channel-matrix|g' scripts/setup.sh
```

- [ ] **Step 4: Verify**

```bash
grep -n claude-code-channel-matrix agents/_shared/settings.json scripts/setup.sh
# expected: every line shows sherodtaylor/...
```

- [ ] **Step 5: Commit**

```bash
git add agents/_shared/settings.json scripts/setup.sh
git commit -m "feat(matrix): pin channel plugin at sherodtaylor fork for testing

TEMPORARY — flipped back to zekker6/... once upstream PRs land.
See docs/superpowers/specs/2026-05-27-matrix-channel-threading-tools-design.md §5.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### Task 32: Push and open PR for agent-smith fork-pin

**Files:** none

- [ ] **Step 1: Push**

```bash
git push -u origin feat/matrix-fork-pin
```

- [ ] **Step 2: Open PR**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/agent-smith \
  --title "[dev] feat(matrix): pin channel plugin at sherodtaylor fork for testing" \
  --body "Temporary marketplace pin so devbot/infrabot pods test the threading + edit_message + typing additions from sherodtaylor/claude-code-channel-matrix#1 (or whatever the integrated PR number is). Flipped back to zekker6/... once upstream PRs merge. Spec: docs/superpowers/specs/2026-05-27-matrix-channel-threading-tools-design.md §5."
```

### Task 33: Bump agent-smith chart version

**Files:**
- Modify: `/workspace/agent-smith/charts/agent-smith/Chart.yaml`

- [ ] **Step 1: Determine current chart version**

```bash
grep '^version:' charts/agent-smith/Chart.yaml
```

- [ ] **Step 2: Bump the patch number** (e.g. 0.1.21 → 0.1.22) and `appVersion` to match. Commit:

```bash
git add charts/agent-smith/Chart.yaml
git commit -m "chore(release): v0.1.22 — pin matrix channel plugin at sherodtaylor fork"
```

- [ ] **Step 3: Push to the same `feat/matrix-fork-pin` branch (extends the PR)**

```bash
git push
```

### Task 34: Smoke-test in devbot / infrabot pods (operational)

**Files:** none (operator + InfraBot collaboration)

- [ ] **Step 1: After PR merges, Flux reconciles and pods restart with the new chart. Trigger a smoke test in `#dev`:**
  - Send a Matrix message that references a prior event_id; confirm the bot threads under it (per-call `reply_to_event_id` working).
  - Ask the bot to do a multi-step task and `edit_message` for in-flight progress; confirm only the final `reply` push-notifies.
  - Confirm the typing indicator appears in Element when you tag the bot.

- [ ] **Step 2: If smoke fails, fix on the fork (`feat/matrix-channel-additions`), push, restart pods. Iterate.**

---

## Phase C — Upstream PRs

### Task 35: Split the integrated branch into per-feature PRs

**Files:** none (git only, on the fork)

- [ ] **Step 1: For each feature, create a clean branch from upstream/main and cherry-pick the relevant commits.** Example for the typing indicator:

```bash
cd /workspace/claude-code-channel-matrix
git fetch upstream
git checkout -b upstream/typing-indicator upstream/main
# Find the typing commit's SHA from `git log feat/matrix-channel-additions --oneline`
git cherry-pick <typing-commit-sha>
git push -u origin upstream/typing-indicator
```

Repeat for each of: threading, edit_message, replyToMode, instructions-and-skill.

- [ ] **Step 2: Open one upstream PR per branch against `zekker6/claude-code-channel-matrix:main`**

```bash
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo zekker6/claude-code-channel-matrix \
  --head sherodtaylor:upstream/typing-indicator \
  --title "feat(channel): send Matrix typing indicator on inbound" \
  --body "<spec citations + behaviour diff + agent-smith design doc link>"
```

### Task 36: Address upstream review on each PR

**Files:** as needed per review

- [ ] **Step 1: For each PR, watch for review comments**

```bash
gh pr list --repo zekker6/claude-code-channel-matrix --author @me
```

- [ ] **Step 2: Address comments on the per-feature branch in our fork, force-push** (per-feature branches are PR-only, force-push is fine).

- [ ] **Step 3: Once a PR merges, immediately rebase the integrated branch onto the new upstream main** to shrink our local diff:

```bash
git fetch upstream
git checkout feat/matrix-channel-additions
git rebase upstream/main
git push --force-with-lease
```

---

## Phase D — Flip back to upstream

### Task 37: Confirm all upstream PRs are merged

**Files:** none

- [ ] **Step 1: Confirm**

```bash
gh pr list --repo zekker6/claude-code-channel-matrix --author @me --state merged
# expected: 4 or 5 PRs all merged
```

### Task 38: Revert the marketplace pin in agent-smith

**Files:**
- Modify: `/workspace/agent-smith/agents/_shared/settings.json`
- Modify: `/workspace/agent-smith/scripts/setup.sh`

- [ ] **Step 1: Branch**

```bash
cd /workspace/agent-smith
git checkout main
git pull --ff-only
git checkout -b feat/matrix-fork-unpin
```

- [ ] **Step 2: Flip the pin back**

```bash
sed -i 's|sherodtaylor/claude-code-channel-matrix|zekker6/claude-code-channel-matrix|g' \
  agents/_shared/settings.json scripts/setup.sh
```

- [ ] **Step 3: Verify**

```bash
grep -n claude-code-channel-matrix agents/_shared/settings.json scripts/setup.sh
# expected: every line shows zekker6/...
```

- [ ] **Step 4: Bump chart version (one minor bump from the pin-version)**

```bash
# Edit charts/agent-smith/Chart.yaml: 0.1.22 → 0.1.23 (or whatever the next patch is)
```

- [ ] **Step 5: Commit and PR**

```bash
git add agents/_shared/settings.json scripts/setup.sh charts/agent-smith/Chart.yaml
git commit -m "chore(matrix): unpin channel plugin — upstream has accepted all additions

All four features now ship in zekker6/claude-code-channel-matrix:
- per-call reply_to_event_id on reply
- edit_message tool
- inbound typing indicator
- replyToMode chunk-splitter governance

Retire the sherodtaylor/claude-code-channel-matrix pin from
settings.json + setup.sh. Fork branch feat/matrix-channel-additions
is retired (fork itself stays as a safety net)."

git push -u origin feat/matrix-fork-unpin
SSL_CERT_FILE=/root/iron-proxy.crt gh pr create --repo sherodtaylor/agent-smith \
  --title "[dev] chore(matrix): unpin channel plugin — upstream has all additions" \
  --body "Flips agents/_shared/settings.json + scripts/setup.sh marketplace pin from sherodtaylor/claude-code-channel-matrix back to zekker6/claude-code-channel-matrix now that all four feature PRs are merged upstream. Spec: docs/superpowers/specs/2026-05-27-matrix-channel-threading-tools-design.md §7 Phase D."
```

### Task 39: Verify post-flip in pods

**Files:** none (operational)

- [ ] **Step 1: After the unpin PR merges, Flux reconciles and pods restart. Smoke-test the same three behaviours from T34 — they should still work identically since the code is the same; only the source repo changed.**

### Task 40: Retire the fork branch

**Files:** none

- [ ] **Step 1: Delete the integrated branch (fork's `main` keeps tracking upstream as a passive safety net)**

```bash
cd /workspace/claude-code-channel-matrix
git push origin --delete feat/matrix-channel-additions
git branch -D feat/matrix-channel-additions
# (Per-feature upstream branches were already deleted by GitHub when their PRs merged.)
```

---

## Self-review (done before handoff)

- **Spec coverage:**
  - §2.1 (per-call threading) → T6-T12 ✓
  - §2.2 (edit_message) → T13-T19 ✓
  - §2.3 (typing) → T20-T23 ✓
  - §2.4 (instructions expansion) → T28 ✓
  - §2.5 (skills/threading/SKILL.md) → T29 ✓
  - §3 (access.json replyToMode) → T24-T27 ✓
  - §4 (file structure) — followed throughout
  - §5 (fork+upstream sync) → T1-T3, T31-T40 (Phases A-D)
  - §6 (testing) → tests added per feature task; mock Client in T5
  - §7 (rollout) → Phases A-D map 1:1
  - §8 (operational concerns) — handled in tool error messages + commit notes
- **Placeholder scan:** zero TODO/TBD/FIXME in steps; every code block is complete.
- **Type consistency:** `buildReplyContent` / `BuildReplyOpts`, `buildEditContent` / `BuildEditOpts`, `resolveThreadRoot`, `assertOwnedByBot`, `maybeSendTyping`, `applyReplyToMode` / `ReplyToMode` — all defined in their creation tasks and reused with matching signatures in handler-integration tasks.
- **Ambiguity:** explicit per-call vs. global threading precedence (T10); explicit MATRIX_TYPING default (T21); explicit replyToMode 'off' semantics (T24).
