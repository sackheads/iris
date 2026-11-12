# MCP guest sessions: the incoming guest path (#1066, Phase 2). Design of record

**Status:** design of record, 2026-11-12. Formalizes the planner's locked draft
(`1066-guest-sessions-design.md`) and Brian's decisions of 2026-11-12 (section 2), and tightens it
against what `origin/main` actually contains (section 4). Gates the Phase 2 build; no code starts
until Brian greenlights it. The implementation plan is
`docs/superpowers/plans/2026-11-12-mcp-guest-sessions-phase2.md`.

It supersedes the earlier "history partition" design for #1066, and it corrects #1063 section 3.2
(see section 3). It builds on the Phase 1 provider (#1067, `docs/mcp_provider.md`,
`docs/superpowers/plans/2026-11-11-mcp-provider-phase1.md`).

Out of scope here, each tracked separately: credentialed guests (#1088), an egress check on replies
addressed to a guest (#1089).

## 1. The model

A guest connection gets **its own new, isolated, confined session**. It is not a turn inside an
existing session and not a read that reaches into one. The guest session:

- does the actions it is permitted to do **itself**, inside a floor enforced in code (an `mcpGuest`
  principal, a fixed tool allowlist, a guest prompt that carries none of the owner's context);
- learns about Iris's other sessions only by **asking them**, over the cross-session (peer)
  messaging Iris already has. The asked session answers in its **own turn** and decides for itself
  what to share. The guest only ever holds its own session plus the replies it is given.

This is the shape the kube-agents design uses at a smaller scale: each external agent gets its own
confined workspace and talks to the rest of the system through messages, not through reach-ins.

## 2. Decisions locked by Brian (2026-11-12)

1. **Read-only guests first.** A guest holds no credentials and cannot act as Iris (no posting, no
   credentialed `run_command`). Credentialed guests are #1088.
2. **Prompt-level disclosure for now.** The answering session is told it is talking to an untrusted
   guest and answers with its own judgment. An egress check on replies to a guest is #1089, the gate
   for opening past the in-house dev team.
3. **A real confined `IrisEngine` session per guest**, not a thin request/response handler.
4. **One guest, one session, for the whole connection**: reused across its requests, expired by a
   TTL when the guest departs.

## 3. Why this resolves #1066, and what it corrects in #1063

#1066 asked that an `mcpGuest` turn partition the model's context, not only strip tools. That
requirement existed because #1063 section 3.2 assumed a guest would reach into a role session's
history, either by running a turn inside it or through a bounded read tool. The moment a guest's
model holds another session's history, the model is a covert channel from that history to the guest,
and a partition has to be built to make it safe.

Under this model **the guest never holds another session's history, so there is nothing to
partition.** Disclosure is mediated by the session that owns the data: it answers what it chooses,
as session-to-session messaging already works. #1063 section 3.2 dismissed the plain isolated lane
because it assumed the value "ask a role session about itself" needed a reach-in read. It does not: the
role session can answer. The one thing ask/answer cannot give is deterministic, raw app state, and
that is what the Phase 1 self-report door (no model in the loop) is for. Deterministic measurements
come from the door; qualitative questions come from asking a session. Together they replace the old
"Shape 5" read tool entirely.

## 4. What is on main today, and what it forces

Everything below was read on `origin/main` on 2026-11-12 and is cited by symbol. "Absent" means no
such symbol exists.

| Piece | State on main | Consequence for the design |
|---|---|---|
| `Principal` (`SandboxPolicy.swift`) | `main`, `subagent`, `evaluator`. No guest, untrusted or external case. | A new `.mcpGuest` case is needed. |
| Branch sites on `Principal` | Three exhaustive switches (`SandboxPolicy.resolve`, `IrisEngine.approvalOrigin`, `IrisEngine.turnAgentProfile`); most others are `== .main` / `!= .main` (`hardStrip`, the `jobCreationTools` removal, `CachePolicy.resolve`, `stickyApplies`, `retrievesFacts`, the `executeFunctionCall` `guard principal == .main` refusals). | The compiler flags only the three switches. Every `!= .main` site silently treats a new case as subagent-like **with no allowlist**. The guest floor must therefore be an explicit allowlist, not "whatever a subagent gets". |
| Tool gating | `hardStrip` is a denylist (`mainOnlyDeclared`, `unattendedNeverDeclared`). The only allowlist is `EvaluatorToolset.restrict`. Dispatch refuses tools the round did not declare (`offeredToolNames`, `notOfferedRefusal`). | Add a guest allowlist applied last, in the same place as `EvaluatorToolset.restrict`, and enforce it again at dispatch. |
| `send_to_session` / `inbox_item` | Both are in `mainOnlyDeclared`, so `hardStrip` removes them for any non-main principal, and the handlers `guard principal == .main`. | The guest needs `send_to_session` (and not `inbox_item`), so the strip and the dispatch guard each need a guest exception, applied after the strip. |
| Hidden session kinds | `Conversation.isSubagent` and `isBackground`; `isUserFacing` is `!isSubagent && !isBackground`. There is no hidden-but-addressable kind. | A reply target must be `isUserFacing` (`decidePeerSend`), but `isBackground` implies `isUnattended`, which strips `send_to_session`, `list_sessions` and `inbox_item` and fails every approval closed. A guest session cannot be either existing kind: a new kind is needed (section 5.1). |
| Persistence | `Conversation` has an explicit `CodingKeys` and `decodeIfPresent`; `durableConversations` drops `isSubagent` rows. `isBackground` rows are persisted. | Guest sessions are ephemeral (never persisted, like subagents); a new field is excluded from `CodingKeys` (Invariant 1). |
| Profiles | `AgentProfile` only narrows (`tools:`) and appends prompt text; its own comment says it "approves, allowlists and grants nothing". `flowTools` are never narrowed. Not applied to subagent or background conversations. | A profile cannot be the floor. The floor is a principal plus an allowlist in code. |
| Memory scoping | Absent. `MemoryManager` is process-wide; `composedSystemPrompt` appends USER.md and AGENTS.md; `retrievesFacts` is gated on `.main`. | The guest prompt is built without USER.md, SOUL.md, AGENTS.md or facts, by construction (section 5.3). |
| Sandbox | `.subagent` and `.evaluator` always resolve to `.sandboxed`, but only for `run_command`; with the master switch off or no runtime, `resolve` returns `.host`. Host file tools are not covered (seam C1 in the access-boundary design). | A guest gets no host-touching tool at all in this phase. Host tools wait for #966's sandbox pin. |
| Peer rate limit | `PeerRateLimiter` is keyed by the **sending conversation's UUID** (capacity 20, one per 15 s). | One session per guest gives a per-guest bucket for free. |
| Peer depth | `notePeerArrival(depth:at:)` takes a `max`; `resetPeerDepth` fires only when a person types into that session. | A guest arrival stamped with a fixed depth never climbs, so a guest cannot wedge a role session (section 5.8). |
| Provenance | `PeerEnvelope` has no origin field; `framePeerMessage(_:senderName:senderId:senderRole:envelope:)` builds the label from harness-known data; the sender's card name is a model claim. | Derive "this sender is a guest" from the sender's `Conversation` at framing time. No `peer_messages` schema change. |
| Idle expiry | None per conversation. `sweepIdleSessions` is daily and archives only sessions with a role, card or `inSessions`. | A dedicated reaper (section 5.9). |
| Concurrency caps | None on conversations or turns. | Add explicit caps for guest sessions (section 5.9). |
| Reply path to an external client | `ProviderMailbox.deliverReply` exists and has no caller by design (Phase 1). | Phase 2 gives it exactly one caller: the guest session driver (section 5.10). |

## 5. The design

### 5.1 The guest session kind

`Conversation` gains two fields: `isGuest: Bool` and `guestClientId: String?` (the token's client id,
the provenance stamp `mcpGuest:<clientId>`). Neither is persisted: both are left out of
`CodingKeys`, and `durableConversations` and `takeBatch` drop `isGuest` rows exactly as they drop
`isSubagent` rows. A restart therefore starts with no guest sessions.

What a guest conversation is and is not:

| Surface | Guest session |
|---|---|
| Sidebar and selection | Excluded. It is never `isSelectable` (`isUserFacing && !isArchived`). |
| `isUserFacing` | Stays `false`. A new `isReplyTarget` predicate (`isUserFacing || isGuest`) is used only by the reply branch of `decidePeerSend`. |
| `SessionDirectory.resolve` / `activePeers` / `list_sessions` for **other** sessions | Excluded, because `resolve` and `activePeers` already require `isUserFacing` and a guest stays `false`; a guest also never holds a role, so `role:` cannot name it. The only way a message reaches a guest session is a reply (`in_reply_to`) to a message that guest sent, through the `isReplyTarget` exception below. |
| Idle sweeps (`sweepIdleSessions`) and auto-archive | Not a candidate; the guest reaper owns its lifetime. |
| Persistence | None (above). |
| Unattended behaviour | It is attended in the engine's sense (`isBackground == false`), so `send_to_session` can be declared. Its trust floor comes from the principal, not from `isBackground`. |

### 5.2 `Principal.mcpGuest` and the tool allowlist

`Principal` gains `.mcpGuest`. The exhaustive switches get explicit cases: `SandboxPolicy.resolve`
returns sandboxed (defence in depth; the toolset below has no sandboxed tool anyway),
`IrisEngine.approvalOrigin` gets a label that names a guest and is never the user's, and
`IrisEngine.turnAgentProfile` returns `(nil, nil, nil)` like the evaluator (a guest never runs under an
agent profile). The compiler lists the exact switches; the build adds a case to each rather than a
default.

The floor is `GuestToolset.allowedNames`, applied where `EvaluatorToolset.restrict` is applied and
**again after the `fireBeforeToolSelection` hook** (that hook can rewrite the declared list, so an
allowlist applied only before it could be undone), and re-checked at dispatch. In this phase it is
**`send_to_session` and `list_sessions` only** (decision D1, section 8):

- `send_to_session` is declared for `.mcpGuest` by a guest exception that runs after `hardStrip` (the
  strip would remove it as a `mainOnlyDeclared` tool) and by a guest exception in the dispatch
  `guard principal == .main`. Its handler enforces the addressing rule of section 5.5.
- `list_sessions` is declared for `.mcpGuest` and returns **only the roles in its client allowlist**
  (section 5.5), never a roster: an enumerable list of sessions is itself an information-leak and
  discovery primitive (the same principle as #1063 section 3.1's `discover`/`status`).
- Everything else is absent: no `run_command`, no file tools, no `search_web`, no `inbox_item`, no
  memory or goal tools, no subagents, no jobs. `inbox_item` being absent also means no attention
  budget is needed in this phase.

Because most `Principal` branch sites are `== .main` / `!= .main`, the plan adds a mutation-backed
test that enumerates every tool the engine can declare and asserts the guest sees exactly the
allowlist, so a tool added later is denied to guests by default.

### 5.2a Which engine runs a turn: the principal must agree with the conversation

This is the place a hole hides, and it is not a tool question. A turn on a conversation runs on whichever
`IrisEngine` instance the call site holds, and the engine's `principal` decides the floor. On main
today:

- `AppState.engine` is **one** main engine (`IrisEngine(state: self)`), used by `AppState.startTurn`
  and by the drain path for every user-facing conversation.
- `deliverSanitizedSystemEvent` ends in `await processInput(safeMessage, source:, conversationId:)` on
  **`self`**, i.e. the **sender's** engine runs the **target's** turn (the peer arrival when the target
  is idle).

With a second engine kind these two facts break in both directions. A role session replying to a guest
would run the **guest conversation's** turn on the main engine, under `.main`: the guest session would
get the full tool set. A guest asking a role session would run the **role's** turn on the guest's
`.mcpGuest` engine: the role session would answer under the guest floor, and its tool calls would be
judged as a guest's.

So a turn is routed by the **target conversation**, not by the caller:

- `AppState.engine(forTurnOn conversationId:)` returns the guest session's own engine (held by the
  `GuestSessionRegistry`) for a guest conversation and `AppState.engine` for anything else. Every site
  that starts a turn on a conversation another caller named (`deliverSanitizedSystemEvent`,
  `AppState.startTurn`, `drainPendingUserMessages`, and any other the build finds by searching
  `processInput(` callers) uses it.
- A check at the head of `IrisEngine.processInputBody` makes any site that was missed fail **closed
  and loud**: a turn is refused, with a visible diagnostic, unless
  `(conversation.isGuest) == (principal == .mcpGuest)`. A guest conversation never runs under any other
  principal, and a `.mcpGuest` engine never runs a turn on a non-guest conversation.

The review must show the routing and the agreement check on every path that starts a turn, with a test
per path that drives it with the wrong engine and sees the refusal.

### 5.3 Context confinement: what the guest model is given

A guest session's system prompt is built by a guest branch of `composedSystemPrompt`. It contains
a short guest base (what it is, that its requester is an external agent, that it cannot act as Iris),
the guest-caution text, and the tools' own descriptions. It **does not contain** the owner's
`USER.md`, `SOUL.md`, the workspace `AGENTS.md`, retrieved facts (`retrievesFacts` is already
`.main` only), the agent profile, or the skills catalogue. The guest has no workspace; its
`workspacePath` is empty and no tool that would read one is declared.

The guest's only context is therefore its own conversation: the guest's requests, and the replies role
sessions chose to send it.

### 5.4 Sandbox

With no host-touching tool in the allowlist, the C1 fail-open (a sandbox pin that falls back to the
host when no runtime is present, and that does not cover host file tools) cannot be reached by a guest.
Adding any host tool to the guest floor is blocked on #966's sandbox pin, and is a separate decision
(#1088 and later), not a tweak to this one.

### 5.5 Addressing: who a guest may ask

Each registered client carries a **role allowlist**, set when its token is issued
(`ProviderTokenRegistry`, which gains a per-client record). The default is empty: a client with no
allowed role can start a session and cannot address anyone (decision D3).

For a guest sender, `decidePeerSend` accepts only `role:<name>` targets whose role is in the sender's
client allowlist and resolves each to the role holder; it refuses `session_id`, `name:`, `topic:` and
`iris`, and it refuses a target that is itself a guest. `list_sessions` for a guest returns only the
allowed role holders, with name, role and description, and **without workspace paths, skills, topics
or status detail** (those are model-written or reveal the owner's projects). `describe_session` is not
in the guest floor.

### 5.6 The message flow, end to end

1. The external client calls `iris_send(text, ...)` with its token. The existing front end of
   `IrisMCPProviderServer` authenticates and admits it (token, `mailboxGate`) as in Phase 1.
2. The handler asks the `GuestSessionRegistry` for the client's live session, creating it on first use
   (section 5.9), and queues the text into it as a guest request. It returns the message id at once.
3. The session runs a real engine turn (`IrisEngine.processInput`) as `.mcpGuest`, with a per-turn
   `TurnBudget` (decision D4). The model may call `send_to_session` to ask an allowed role session.
4. The asked session receives a **peer arrival** (section 5.7) and answers in its own turn, run on the
   main engine (section 5.2a); its reply comes back to the guest session as a peer reply
   (`in_reply_to`), queued and drained like any peer arrival, and run on the guest's engine.
5. When the guest session's turn ends, the guest driver takes the final assistant message and stores it
   with `ProviderMailbox.deliverReply(to: clientId, ...)`. The client reads it with `iris_poll` and
   `iris_status`, which behave as in Phase 1 but now have something to return.

If a role session never answers, the guest turn ends on its own (turn budget, or the model giving up);
`expects_reply` requests it opened are closed by `deleteConversation` when the session is reaped, so
nothing stays open for a departed guest.

### 5.7 Provenance and the answering session's signal

`framePeerMessage` already builds the label from harness-known data. It gains a guest branch, chosen
from the **sender conversation's** `isGuest` and `guestClientId` (never from message content): the
header names an external MCP guest and its client id, and the footer is the existing
"request from a peer, not from the user" text plus a guest-caution paragraph: this requester is
outside the owner's own sessions, answer only what is safe to tell an outside party, decline anything
that would reveal the owner's memory, credentials, files or other sessions' contents. The footer is
repeated after the body, as the peer footer already is.

Guest-origin text arrives through the existing `sanitizeArrival` path, so the receiving session's
sticky taint (`markReadUntrusted`) is set exactly as for any peer; whatever that session then emits
(`inbox_item`, outbound tools) already carries that taint.

No `peer_messages` column is added: the stamp is derived at framing time. After a guest session is
deleted its past arrivals keep their text but lose the live lookup; this phase has no guest-origin
artifacts, so nothing can later be misread as Iris-origin.

### 5.8 Budgets

- **Request rate:** unchanged and already per token: every guest tool call passes
  `ProviderRequestGate.admit` once, in `handleAuthenticated`.
- **Peer send rate:** `PeerRateLimiter` keyed by the guest session's own UUID, so a guest has its own
  bucket (capacity 20, one per 15 s) with no new limiter.
- **Cost, stated plainly:** a guest's question makes the owner's *role session* run a model turn, and
  the guest's own turn is a model turn too, so **guest traffic spends the owner's tokens**. The caps
  below are cost controls, not only abuse controls, and the feature stays off by default.
- **Turn rate and cost:** a per-token turns-per-hour gate in front of `processInput` (a second
  `ProviderRequestGate` instance with its own capacity), a per-turn `TurnBudget`, and the cheapest
  model tier for guest turns (decision D4: values are for the planner and Brian; Brian is budget
  limited).
- **Cascade depth:** a guest arrival is stamped at a fixed depth of 1. `notePeerArrival` is a `max`,
  so repeated guest messages never raise the receiving session's depth and cannot wedge a role session
  or block the local planner-to-reviewer chain; a chain a guest starts is bounded by
  `maxSessionCascade` like any other.
- **Attention budget:** none needed in this phase (`inbox_item` is not in the floor). A role session
  that decides to ask the user about a guest's request does so as itself, tainted by the arrival.

### 5.9 Lifecycle

- **Key:** one live guest session per client id (decision D2). The provider is stateless HTTP, so
  there is no connection to key on; a client that reconnects within the TTL gets its session back.
- **Create:** on the first `iris_send`. **Reuse:** every later request queues into the same session.
- **Expire:** a `GuestSessionRegistry` reaper on a dispatch timer (not `Task.sleep`, Invariant 4)
  closes sessions idle past the TTL (default 15 minutes, D5) by `deleteConversation`, which already
  cancels tasks, closes peer requests, deletes peer messages and stops delegates.
- **Revoke:** `IrisMCPProviderServer.revoke(clientId:)` closes the client's guest session in the same
  call that purges its mailbox and store.
- **Shutdown:** guest sessions are ephemeral; none exists after a restart.
- **Caps:** at most one live session per client and at most four live guest sessions overall
  (D5); an `iris_send` that would exceed the global cap returns a busy error to the client, it does not
  queue.
- **A reaped session with a turn in flight:** the reaper never closes a session while a turn is in
  flight (`hasTurnInFlight`); it extends the deadline and closes after the turn ends.

### 5.10 Replies to the client

`deliverReply` gets its first real caller, the guest session driver, and only that. The Phase 1
source-scan test that asserts `deliverReply` has no call site outside `ProviderMailbox.swift` becomes
an allowlist of exactly that one driver file. `deliverReply` is still not an MCP tool: a client cannot
write a "from Iris" message.

## 6. The one boundary question that remains

When a role session answers a guest, what it says is its own model's judgment, informed by the guest
signal of section 5.7. That is **best-effort, prompt-level**, not a hard allowlist. For the in-house
dev team, the first and motivating peer, that is sufficient. Before opening past the dev team, an
egress check on replies addressed to a guest (per-target confinement through the access-boundary
design's `AccessProfile` transport and peer allowlist) is the gate (#1089). The role allowlist of
section 5.5 is a structural bound on **who can be asked**, not on **what is said**; it does not
replace #1089.

What the guest's own model could leak: only what the owner's sessions chose to tell it, plus whatever
the guest itself was told. It holds nothing else (section 5.3), has no tool that reads the machine, and
cannot reach the user.

## 7. Non-goals and anti-goals

Non-goals: credentialed guests (#1088); the egress check (#1089); host-touching tools for guests; guest
to guest messaging; a guest that addresses sessions by id; any history partition or reach-in read
tool; persistence of guest sessions across a restart; a Settings UI or token-issuing UI (still absent
from Phase 1).

Anti-goals: a guest that obtains the owner's `USER.md`, memory or workspace rules in its context; a
guest tool added later without an explicit decision (the enumeration test); a guest arrival that
steers a running user turn (the never-steer rule holds: it queues and runs its own turn); a guest
message that reads as a user or Iris message; a guest session that survives its token's revocation.

## 8. Parameters and open items (pending planner and Brian)

These have recommended defaults so the plan is concrete; each is a one-line change in the plan.

| Id | Question | Recommended |
|---|---|---|
| D1 | Guest toolset in this phase | `send_to_session` and filtered `list_sessions` only; no host tools until #966's sandbox pin |
| D2 | Session key | One live session per client id (token), not per MCP session id |
| D3 | Who a guest may ask | Per-client role allowlist set at token issue, default empty |
| D4 | Cost controls | Cheapest tier, 12 guest turns per hour per token, the existing `TurnBudget` per turn. The mechanism is settled; **the values are Brian-tunable on review** (they spend his tokens) |
| D5 | Caps | Idle TTL 15 minutes, at most 4 live guest sessions (tunable) |

D1 to D5 were cleared by the planner on 2026-11-12 on the recommended defaults (they follow from
Brian's read-only-first and fail-closed decisions); only the D4 values are left for Brian.

Open items found while writing this, for the build to settle: how a client's role allowlist is set
(Phase 1 has no token-issuing UI, so the allowlist shares that gap); whether `describe_session` is ever
added to the guest floor; the exact guest base prompt text.

## 9. What this change will make untrue (Invariant 9 sweep for the build)

- `docs/mcp_provider.md`: "no tool or method on this surface lets one registered client reach another"
  stays true, but its description of messaging as "only stores" and of `iris_poll` as "always empty"
  becomes false when the driver lands, as does "nothing here touches `Conversation.history`".
- `docs/specs/2026-11-11-iris-devteam-mcp-collaboration-design.md` section 3.2, which this document
  corrects; add a pointer rather than rewriting it.
- `AGENTS.md`: the architecture notes that list the principals, if any, and the `deliverReply` source
  scan described in the Phase 1 plan.
- Agent-facing strings: the `send_to_session` and `list_sessions` tool descriptions, which gain a
  guest note, and the new guest system prompt.
- The Phase 1 test `ProviderMailbox.deliverReply is never called from production code outside
  ProviderMailbox.swift itself`, which becomes the one-driver allowlist.

## 10. Risks

- **A turn running on the wrong engine** (section 5.2a): the peer-delivery and drain paths pick the
  engine from the caller today. Mitigated by routing on the target conversation and by the
  principal/conversation agreement check, tested per path.
- **A new principal that inherits subagent or main behaviour by accident.** The one place a hole can
  hide: every `== .main` / `!= .main` site treats `.mcpGuest` as non-main, i.e. subagent-like with no
  allowlist. Mitigated by the allowlist (applied after the tool-selection hook), the dispatch
  re-check, and an enumeration test; the review must verify the mechanism on **every** guest
  tool-dispatch path (declaration, `hardStrip`, stickiness, the hook, `offeredToolNames`, the
  `executeFunctionCall` guards, `agentToolScope`), not only that the allowlist is declared.
- **Cost.** A guest turn is a real model turn. Mitigated by D4, the global cap and the idle TTL.
- **Reply disclosure is prompt-level.** Accepted for the dev team (section 6); #1089 gates widening.
- **Role holders answering guests while a user turn runs.** The never-steer rule holds, but a busy
  role session delays the answer; the guest turn's budget bounds how long the guest waits.
- **No UI to issue tokens or set role allowlists.** Inherited from Phase 1; the build is testable
  without one, and the feature stays dormant until that lands.
