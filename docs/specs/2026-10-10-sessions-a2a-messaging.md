# Sessions, Part 2: A2A-Shaped Cards, Roles, Correlated Messages, and Artifacts — Design

**Status:** proposed
**Issue:** #469
**Builds on:** #185 (sessions slice 1, `docs/specs/2026-09-20-sessions-identity-discovery-messaging.md`),
#240 (atomic busy decision), #256 (resolved-path reads), #418 (observed status)
**Related:** #194 (NATS transport), #231 (TTL auto-archive)

## 1. Overview

#185 made every active conversation a session: it has a card, it can list its peers, and it can
send one a message that wakes it. That is enough for two conversations to talk. It is not enough
for the use case that now drives this: a multi-session "factory" — sessions with standing roles
(overseer, planner, pr-minder, bug-minder) and named workers in topical lanes, with the overseer
routing work between them. Running that pattern elsewhere showed four gaps:

1. **Identity is too thin to route on.** A card is a model-written name and description. There is
   no role, no notion of a worker, no project, and nothing stops two sessions claiming one name.
2. **Replies are uncorrelated.** A send returns "You will not be notified when it completes"; a
   peer's answer, if any, is an unrelated new message. An overseer has to keep its own ledger of
   who owes it what, and doing that in a file is expensive in tokens.
3. **The cascade cap stops a factory immediately.** #185's budget is 8 hops, shared across
   fan-out, reset only when a human types. Five delegations and five replies exhaust it.
4. **Messages are text only.** There is no way to hand a peer a thing you made.

This spec closes those gaps. It is the second iris use case, alongside the original second-brain
flows rooted in the pinned Iris conversation, and it must cost those flows nothing (§2).

**A2A 0.3 as the internal model, not a wire.** #185 adopted A2A's vocabulary. This spec adopts its
*shapes*, pinned to protocol version 0.3 (the version Gemini Enterprise runs): `AgentCard`,
`AgentSkill`, `Message`, and `Part` (text, file, data) become the Swift types, and iris-only
fields travel as a declared A2A extension. In-process delivery stays a plain Swift call — no
serialization, no JSON-RPC, no Task state machine. The payoff is at the edge: the NATS transport
(#194) becomes a Codable encode plus one extension URI rather than a translation layer.

## 2. Constraints

- **The second brain pays nothing.** A session with no role, no open requests, and no peers gets
  no new standing context lines and no new tool declarations. #185's peer gate already does this
  for tools; every line added here follows the same rule, and a test pins it (§9).
- **Trust is never decoded.** Who sent something, and at what tier, is stamped by the harness from
  where the message entered. It is never read from message content or `metadata`, internally or at
  a future edge.
- **Nothing blocks.** Correlation and the request ledger are bookkeeping, not waits. Blocking
  primitives (handoff, wait-for-completion, A2A Task lifecycle) remain the coordination spec's
  problem, because a session waiting on a reply that never comes is this codebase's recurring
  trapped-state failure (#185 §2).

## 3. Scope

In: the reshaped card (roles, names, workers, lanes, skills, harness-stamped facts), addressing by
role and name, message ids and threads, the outstanding-request ledger, the cascade replacement,
artifacts, and provenance.

Out, deliberately:

- **A2A Task lifecycle and blocking waits** — the coordination spec (#185 §13).
- **NATS transport and the external trust tier** — #194. This spec reserves the provenance case
  and the extension URI so that work is additive.
- **A2A client access to remote agentic services** (the work use case) — its own spec; it is
  closer to an MCP server than to a peer.
- **Deep peer inspection for the overseer** beyond `describe_session` — #185 §13's main-chat
  orchestration item.
- **Live-path attachments.** Repo paths stay as plain text in a message (§7.4).
- **Model-proposed roles.** Only the user assigns roles (§4.3).
- **A cost backstop on peer traffic.** Spend is monitored elsewhere; the rate limit in §6 bounds
  runaway fan-out.

## 4. Cards and identity

### 4.1 Fields and their writers

Every field has exactly one writer. Peers act on card contents, so who wrote a field decides
whether it can be trusted.

| Field | Writer | Notes |
|---|---|---|
| `id` | harness | the conversation UUID, unchanged |
| `kind` | harness, derived | `iris` (the pinned conversation), `role` (a role is assigned), `worker` (otherwise). Job-run conversations stay undiscoverable, as today |
| `project` | harness, derived | workspace path; repo name and branch when it is a git repo. Branch is read at list time, not stored |
| `model`, `sandboxed` | harness | provider and tier; whether `run_command` goes through the session container |
| `status`, `lastActive` | harness | unchanged (#418): busy, waiting, idle |
| `role` | **user only** | via `/role <name>` or a UI control. No tool sets it |
| `name` | model, `set_session_card` | unique among active sessions (§4.2) |
| `description` | model, `set_session_card` | unchanged: what the session is doing now |
| `lane` | model, `set_session_card` | optional free text, meant for workers ("swift UI", "store migrations") |
| `skills` | model, `set_session_card` | role-holders only (§4.4) |

The pinned Iris has `kind: iris`, cannot hold a role, and stays discoverable and addressable as
`iris` — a factory session can hand it something, but it is not part of the factory's routing.

### 4.2 Names are identifiers

Workers are told apart by name, so the harness enforces uniqueness among active sessions,
case-insensitively. `set_session_card` with a taken name is refused, and the refusal lists the
names in use so the model can pick a meaningful one. The harness never adds a suffix itself: an
auto-generated `swift-worker-2` is exactly the kind of name an overseer cannot route on.

A name frees up when its session is archived or deleted.

### 4.3 Roles

A role is a standing responsibility the user assigned. It is unique among active sessions.

- **Assigning a role another session holds moves it.** The previous holder gets a harness event
  line ("role `planner` moved to session …") and loses its skills. This is a harness event, not a
  peer message, so it costs no cascade depth or rate (§6).
- **Uniqueness is enforced by the store**, not just by code: a partial unique index on the role
  column (§8), so two concurrent assignments cannot both win.
- **Archiving a role-holder clears its role**, after a confirmation that names the role.
- **A role-holder is exempt from auto-archive.** #231 has not landed; when it does, it must skip
  sessions holding a role, or the TTL quietly removes the overseer from discovery.
- **A session holding a role knows it**: one standing context line, `You hold role: <name>`.

Role names are free text from the user, flattened and capped like card fields.

### 4.4 Skills

A2A 0.3 skills describe what an agent will do on request. A role is a service in that sense, so
role-holders may advertise skills; general workers may not, because their skills would restate
their description and cost tokens in every listing.

- Shape: 0.3 `AgentSkill` — `id`, `name`, `description`, `tags`, `examples`.
- Bounds: at most 5 skills, at most 3 examples each; each string flattened and capped.
- `set_session_card` with `skills` on a session without a role is refused.
- Assigning a role seeds no skills; the role-holder writes them on its first turn after
  assignment, prompted by the role context line.

### 4.5 Mapping to A2A 0.3

`name`, `description`, and `skills` are `AgentCard` fields. Everything else — `id`, `kind`,
`project`, `model`, `sandboxed`, `status`, `lastActive`, `role`, `lane` — is declared under
`capabilities.extensions` as `{uri: "https://github.com/sackheads/iris/ext/session/v1", params: …}`.
Inside the app these are typed Swift properties, never a dictionary; the extension is only how
they would serialize.

### 4.6 Discovery

`list_sessions`:

- orders role-holders first, then workers, then the rest; within each, most recently active first;
- shows workers' name, lane, status, and description;
- adds role-holders' skills as one compact line each (name and tags, no examples);
- exempts role-holders from the 20-entry cap (`SessionDirectory.listCap`), so a large worker pool
  never truncates a role out of view.

`describe_session(to)` renders one full card, examples included. It has the same peer gate as
`list_sessions` and is the thin entry point for inspecting a peer more closely.

Standing context is unchanged — one line, the peer count — plus the role line for a role-holder
and the awaiting-replies line (§5.3) when requests are open.

## 5. Messages and correlation

### 5.1 The message

Internally a peer message is a 0.3 `Message`: `messageId`, `role: agent`, `parts`, `contextId`.
0.3 has no message-to-message reply field (`referenceTaskIds` points at Tasks), so `inReplyTo`
travels in the iris extension's `metadata`.

- A message without `in_reply_to` mints a new `contextId`: it starts a thread.
- A reply inherits its parent's `contextId`.

### 5.2 Sending and receiving

`send_to_session(to, message, in_reply_to?, expects_reply?, attachments?)`:

- `to` accepts a bare session id (as today), `role:<name>`, or `name:<name>`, or `iris` for the
  pinned conversation. The harness resolves it **at delivery time**, and the result names what it
  resolved to: `Sent msg 7f3a to worker-a (session …).` The sender records the resolved session, so
  a later move of the role cannot misattribute the reply.
- `in_reply_to` must name a message that was delivered **to this sender**. Anything else is
  refused. This stops a session closing a request that is not its to answer.
- `expects_reply` defaults to `false`, so status notes and FYIs do not fill the ledger. Role
  instructions for delegating sessions tell them to set it when they hand off work.

The receiver sees #185's peer framing, with a harness-written header and a reply hint:

```
Request from overseer (role assigned by you), session …, msg 7f3a:
<body>
To answer, send with in_reply_to: 7f3a.
```

A reply is rendered to the original sender as
`Reply from worker-a to your msg 7f3a ("first line of the request…")`. Every part of that header
is harness-written; the first line is the sender's own text, flattened.

### 5.3 Outstanding requests

A send with `expects_reply: true` opens a request. It closes when:

- a reply with a matching `in_reply_to` arrives;
- the sender calls `close_request(msg, reason)` — rerouted, no longer needed;
- the target is archived or deleted. The sender gets a harness event line:
  `worker-a archived; msg 7f3a closed unanswered.`

Requests never expire by themselves. Silence is information an overseer acts on; auto-closing
would hide it.

While at least one request is open, the sender's turn context carries one line:

```
Awaiting replies: worker-a (7f3a, 14m), planner (e012, 2h)
```

capped at 5 entries plus `+N more`. Nothing is shown when nothing is open.

The ledger is **persisted** (§8). It is the overseer's record of who owes it what, and a transient
field holding a durable decision has already cost this repo once (AGENTS.md, "Things that have
bitten us").

## 6. Loop and volume limits

#185's global cascade budget (`cascadeOf`/`cascadeBudget` on `AppState`, default
`maxSessionCascade` 8, reset when a human types) counts every hop of a fan-out against one number.
It is replaced by two limits that each catch one failure:

- **Hop depth per thread** catches ping-pong loops. Each message carries the depth of its thread
  since a human last typed into any session on that thread; delivery is refused once it exceeds
  the limit. The existing `maxSessionCascade` setting becomes this limit, keeping its default of 8.
  Depth resets when the user types into any session that has sent or received on the thread.
- **A per-sender token bucket** catches runaway fan-out: N sends, refilling at a fixed rate.
  Starting values (capacity 20, one every 15 s) are tuned in the plan against a realistic overseer
  fan-out.

Both refuse visibly — the sender's tool result says which limit and when it frees — never by a
silent drop. Silent drops were the worst part of the Claude Code protocol this is modelled on.

## 7. Artifacts

### 7.1 Storage

Artifacts live in an exchange directory under the build's home: `<IrisPaths>/exchange/<first two
hex of sha256>/<sha256>`, so `~/.iris-dev/exchange` in dev builds. A sidecar holds name,
mimeType, size, sending session, and creation time. Artifacts are content-addressed (one copy per
distinct content) and immutable (written once by the harness, never edited).

The URI is `iris-artifact://<sha256>`, never `file://`. Identity (the hash) is kept apart from
location (a local path today, an object-store key at the NATS edge), so an artifact can leave the
machine without leaking a host path.

### 7.2 Sending

`attachments` takes up to 10 entries:

- `{path}` becomes a 0.3 `FilePart` with `uri: iris-artifact://…`. The file is snapshotted into
  the exchange **using the sender's own read permissions** — the same resolved-path and `openat`
  checks as `read_file` (#256). A refused path fails the whole send, in the sender, at send time.
  Without this, `attachments` is an exfiltration route: a poisoned page could tell a session to
  attach a protected file and hand it to a peer.
- `{name, data}` with a JSON value becomes a `DataPart`, at most 64 KB encoded.

Directories are refused, as are files over 50 MB.

Inline file bytes (0.3 `FilePart.file.bytes`) are not used internally: content-addressing a small
file costs nothing, and one path is simpler than two. Whether to inline small files is the NATS
edge's decision.

### 7.3 Receiving

- Each file attachment renders as one harness-written line:
  `Attachment: report.md (text/markdown, 12 KB) — iris-artifact://ab12…`
- Data parts render pretty-printed inline, inside the peer framing, capped.
- `read_file` resolves `iris-artifact://`; `write_file` refuses the scheme.
- **Reading an artifact is reading peer-authored content.** Its output gets the untrusted framing
  and the `InjectionGuard` pass a peer message gets, with source `peer_artifact`.

A sandboxed receiver cannot see host paths. Either the exchange directory is mounted read-only into
the session container, or the harness materializes an artifact into it on read; the plan chooses
after reading `SandboxSessionManager`.

### 7.4 What attachments are for

Attachments are snapshots of things a session made: a plan, a report, a diff, a log. They are the
wrong tool for "go fix `Sources/X.swift`", where the sender means the live file in a shared repo
and a snapshot would be edited by nobody. Repo paths stay as plain text in the message body, as
today, and the `attachments` description says so.

### 7.5 Retention

An artifact is kept while any non-deleted conversation — archived ones included — has a message
that references it (`artifact_refs`, §8). When the last reference goes, it is swept after a 7-day
grace. Settings shows the exchange directory's total size; there is no hard cap yet.

## 8. Persistence

Every field below needs `decodeIfPresent` and a store column, or it vanishes on load
(Invariant 1).

- **`SessionCard` JSON** (the existing `sessionCard` column, migration `v8_session_card`) gains
  optional `lane` and `skills`.
- **`role`**: a new column on conversations with a partial unique index on non-null values.
  Archiving clears it.
- **`peer_messages`**: `msgId`, `fromSession`, `toSession`, `contextId`, `inReplyTo`, `depth`,
  `firstLine`, `sentAt`, `expectsReply`, `closedAt`, `closeReason`. One table serves correlation,
  `in_reply_to` validation, depth, and the ledger.
- **`artifact_refs`**: `sha256`, `conversationId`, `msgId`. Drives retention.

Token buckets are in memory; a restart refilling them is acceptable.

## 9. Testing

Swift Testing, each suite on its own `IrisPaths(root:)` and store; nothing touches
`ConfigManager.shared` (Invariant 7).

- Roles: assignment, move with the old holder's event line and skills cleared, archive clears, the
  unique index under two concurrent assignments, the pinned Iris refused.
- Names: collision refused with the taken names listed, case-insensitive; freed on archive.
- Skills: refused without a role; bounds enforced.
- Addressing: `role:`, `name:`, `iris`, and bare id resolve at delivery time; a role moved between
  send and reply still attributes to the session that received it.
- Correlation: a reply inherits `contextId`; `in_reply_to` to a message not delivered to the
  replier is refused.
- Ledger: opens on `expects_reply`, closes on reply, on `close_request`, and on archiving or
  deleting the target, each with the right sender-side line; survives a reload.
- Limits: depth refused past the limit and reset by a human turn on the thread; the bucket refuses
  and refills; both refusals are visible tool results.
- Artifacts: snapshot content-addressed and deduplicated; a protected path refused through the
  resolved-path check; directory and oversize refused; `write_file` to the scheme refused; read
  output carries the `peer_artifact` framing; retention sweep after the grace, not before.
- Provenance: rendering switches exhaustively, so an unhandled case fails to compile.
- **The second brain pays nothing**: a session with no role, no peers, and nothing open has the
  same tool declarations and standing context as before this spec.
- Tool gating (Invariant 6): `describe_session` follows the peer gate; `close_request` is declared
  only while the session has open requests, is in `StickyTools.eligible`, and refuses when none
  are open.

## 10. Documentation (Invariant 9)

Search for what this falsifies and fix it, at least:

- `"You will not be notified when it completes"` in the `send_to_session` result (`iris.swift`).
- The `send_to_session`, `list_sessions`, and `set_session_card` descriptions in `iris.swift`
  (`session_id` becomes `to`; names become unique; skills and lane).
- The system prompt's peer guidance and #185's framing text.
- README's sessions section.

## 11. Delivery

Three PRs, each based on `main` and mergeable alone:

1. **Cards, roles, names, addressing** — §4, the `role` column, `/role`, `describe_session`.
2. **Messages, correlation, ledger, limits** — §5, §6, `peer_messages`, `close_request`.
3. **Artifacts** — §7, the exchange directory, `artifact_refs`, the sandbox decision.

## 12. Provenance and the edge

The internal envelope carries a harness-only `Provenance`: `.user`, `.harness`, `.session(id)`,
and `.external(edge:identity:)`, declared now and produced by nothing. Rendering switches on it
exhaustively, so the NATS work (#194) cannot add an external producer without writing its framing,
and a home bot's message cannot come to look like a sibling session's by accident.

Roles name a sender; they confer no authority. The header `Request from overseer (role assigned by
you)` is trustworthy because the role and the session id are harness-written, but the body is
still a peer request: a worker may act on it, and anything needing approval still goes to the
user. An overseer cannot approve on the user's behalf. Job runs still cannot send or discover, and
a peer-woken turn still sets `hasUnattendedInput`.
