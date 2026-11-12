# MCP Guest Sessions (#1066 Phase 2, read-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A registered MCP client's `iris_send` gets its own confined, ephemeral `IrisEngine` session (principal `.mcpGuest`, two-tool allowlist) that asks the owner's role sessions over existing peer messaging, with the final answer returned through the Phase 1 mailbox.

**Architecture:** A new `Conversation.isGuest` kind (never persisted, hidden, addressable only as a reply target) bound to a new `Principal.mcpGuest` whose tool set is built by **positive construction** (two declarations, not a subtraction from the main list) and re-checked at dispatch. A turn is routed to an engine by its **target conversation**, with a principal/conversation agreement check at the head of `processInputBody` so a missed path fails closed. A `GuestSessionRegistry` owns create, reuse, idle expiry, caps and revoke; a `GuestSessionDriver` runs one turn per request and hands the result to `ProviderMailbox.deliverReply`.

**Tech Stack:** Swift 6, Swift Testing, the Phase 1 `MCPProvider` module, `IrisEngine`/`AppState`, `KeychainManager`, `DispatchSourceTimer` for the reaper.

**Spec:** `docs/specs/2026-11-12-mcp-guest-sessions-design.md` (read all of section 5, especially 5.2a). Neighbours: `docs/specs/2026-11-11-iris-devteam-mcp-collaboration-design.md` (#1063, whose section 3.2 the spec corrects), `docs/superpowers/plans/2026-11-11-mcp-provider-phase1.md`, `docs/mcp_provider.md`. Out of scope: #1088 (credentialed guests), #1089 (egress check).

**Citations are by symbol.** Line numbers drift between `~/src/iris` and `origin/main`; locate every symbol with `git grep` on `origin/main`. Where this plan says "find every site", the task's test is what proves the search was complete.

## Global Constraints

- Guest tool floor in this phase is exactly `send_to_session` and `list_sessions` (`GuestToolset.allowedNames`). No host tool, no `inbox_item`, no `describe_session`, no memory, goal, job or subagent tool.
- A guest session is never persisted: `isGuest` and `guestClientId` are excluded from `Conversation.CodingKeys`, and `durableConversations` drops guest rows (Invariant 1 satisfied by exclusion, not a new column).
- The guest prompt contains none of USER.md, SOUL.md, the workspace AGENTS.md, retrieved facts, an agent profile or the skills catalogue. A guest has no workspace.
- A guest may address only `role:<name>` targets whose role is in its client's allowlist; the default allowlist is empty. Never `iris`, `session_id`, `name:` or `topic:`, and never another guest. `list_sessions` returns only those roles, with name, role and description (no workspace, skills, topics or status detail).
- A guest arrival is stamped at depth 1. The never-steer rule holds: a guest arrival queues and runs its own turn.
- Provenance is derived from the sender conversation's `isGuest` and `guestClientId` at framing time. No `peer_messages` column.
- `ProviderMailbox.deliverReply` has exactly one production caller, `GuestSessionDriver`. It is still not an MCP tool.
- Defaults (planner-cleared 2026-11-12, tunable): idle TTL 15 minutes, at most 1 live session per client and 4 overall, 12 guest turns per hour per token, cheapest model tier, the existing `TurnBudget` per turn. **The D4 values are Brian-tunable on review: guest traffic spends the owner's tokens** (the guest's turn and each asked role session's turn).
- The whole path is behind a new guarded flag `GuardedKey.mcpGuestSessionsEnabled`, protective value off, in addition to `mcpProviderEnabled`.
- AGENTS.md: deadlines and the reaper run on dispatch timers, never `Task.sleep` (Invariant 4); tests never mutate `ConfigManager.shared`, never write process-global state, and time bounds with `TestClock` (Invariant 7); zero compiler warnings; every behaviour change searches `README.md`, `docs/` and agent-facing strings for what it made untrue (Invariant 9).

## Review Focus

Most likely first. Each has its enforcing test in the task named.

1. **A `.mcpGuest` turn falls through to main-like or unconfined-subagent behaviour at some `== .main` / `!= .main` site.** The allowlist must govern every tool path: declaration, `hardStrip`, stickiness, the `fireBeforeToolSelection` hook, `offeredToolNames`, the `executeFunctionCall` guards, `agentToolScope`. Task 2 owns the enumeration test and the per-path tests.
2. **A turn runs on the wrong engine.** A role reply to a guest running under `.main`, or a guest message running the role's turn under `.mcpGuest`. Task 3 owns the routing and the agreement check, with one test per turn-starting path.
3. **A guest names a target outside its allowlist** (`iris`, a `session_id`, a topic, another guest, a role it was not granted, a malformed or case-varied role). Refused with no gate spent beyond the call itself. Task 5.
4. **The token is revoked, or the TTL fires, while a turn is in flight or a role session is mid-answer.** The session must die cleanly; a late reply addressed to the dead guest is refused, not delivered to a recycled id. Task 7, Task 8.
5. **A flood of clients or requests.** More sessions than the global cap, or more turns than the per-token gate: a busy error to the client, no queue, no unbounded conversations. Task 7, Task 8.

---

## Task 1: The guest conversation kind

**Files:**
- Modify: `Sources/IrisKit/AppState.swift` (`Conversation`, `AppState.createNewConversation`, `durableConversations`, the `ConversationStore.takeBatch` filter, the sidebar and search sources, `sweepIdleSessions`)
- Test: `Tests/irisTests/GuestConversationTests.swift`

**Interfaces:**
- Produces: `Conversation.isGuest: Bool` (default `false`), `Conversation.guestClientId: String?`, `Conversation.isReplyTarget: Bool { isUserFacing || isGuest }`; `AppState.createNewConversation(id:isSubagent:isBackground:isGuest:guestClientId:title:select:agentProfile:)` where a guest defaults to `select: false` and ignores `agentProfile`.

- [ ] **Step 1: Write the failing tests** in `GuestConversationTests`: a guest conversation is not `isUserFacing`, not `isSelectable`, `isReplyTarget` is true; it is absent from `durableConversations` and from the `takeBatch` output; a `Conversation` JSON round trip never writes `isGuest` or `guestClientId` and decodes a row that lacks them; `sweepIdleSessions` never archives a guest; `SessionDirectory.resolve` for a guest's `session_id` returns `.inactive` and `activePeers` omits it.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestConversationTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** the two stored properties, left out of `CodingKeys`, `isReplyTarget`, and the `createNewConversation` parameters. Exclude guests wherever `isSubagent` rows are excluded from persistence. Find every `isUserFacing` and `isSubagent` reader (sidebar list, search, export, unread badge) with `git grep` and decide each; the test per reader is the proof.
- [ ] **Step 4: Run the suite and a mutation check** (drop the `CodingKeys` exclusion; drop the `durableConversations` filter): each must fail a test.
- [ ] **Step 5: Commit** `feat: #1066 guest conversation kind (ephemeral, hidden, reply-target only)`.

## Task 2: `Principal.mcpGuest` and the tool floor

**Files:**
- Create: `Sources/IrisKit/GuestToolset.swift`
- Modify: `Sources/IrisKit/SandboxPolicy.swift` (`Principal`, `SandboxPolicy.resolve`), `Sources/IrisKit/iris.swift` (the tool-list build in `buildRequest`, `hardStrip`, the `send_to_session` / `list_sessions` declarations and handlers, `executeFunctionCall`, `approvalOrigin`, `turnAgentProfile`, `CachePolicy.resolve`)
- Test: `Tests/irisTests/GuestToolsetTests.swift`

**Interfaces:**
- Produces: `Principal.mcpGuest`; `enum GuestToolset { static let allowedNames: Set<String> = ["send_to_session", "list_sessions"]; static func restrict(_ tools: [FunctionDeclaration]) -> [FunctionDeclaration] }` (same shape as `EvaluatorToolset.restrict`); `IrisEngine.guestToolDeclarations() -> [FunctionDeclaration]` (the two declarations, with the inline `send_to_session` and `list_sessions` declarations extracted into static builders the main path also uses).

- [ ] **Step 1: Write the failing tests.** (a) **Enumeration:** for a `.mcpGuest` engine, collect every tool name the engine can declare (the base list from `ToolExecutor.getTools`, every gated append, the sticky set, the hook's rewrite) and assert the declared set equals `GuestToolset.allowedNames`, so a tool added later is denied by default. (b) **Per path:** a guest `executeFunctionCall` for each of `run_command`, `read_file`, `write_file`, `search_web`, `inbox_item`, `describe_session`, `invoke_subagent`, a job tool, a memory tool and a goal tool is refused with the guest refusal, before any handler runs; a call to a tool the round did not offer is refused by `offeredToolNames`. (c) A `fireBeforeToolSelection` hook that adds `run_command` does not survive (`restrict` runs after the hook). (d) `agentToolScope` and stickiness cannot add a tool. (e) `SandboxPolicy.resolve(principal: .mcpGuest, ...)` returns sandboxed whatever the other inputs.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestToolsetTests`. Expected: fails to compile.
- [ ] **Step 3: Implement.** Add the case; add an explicit case (no `default`) to every exhaustive `switch principal` the compiler flags. In the tool-list build, branch first: `if principal == .mcpGuest { toolsList = Self.guestToolDeclarations() }` and skip every append, `hardStrip`, sticky record and `ToolIntent.augment` for it; after the hook, `toolsList = GuestToolset.restrict(toolsList)`. Put one guard at the **top** of `executeFunctionCall`: for `.mcpGuest`, any `functionCall.name` outside `allowedNames` is refused. `send_to_session` and `list_sessions` handlers accept `.mcpGuest` as well as `.main` and take the guest paths of Task 5. Give `approvalOrigin` a guest label that is never the user's; `turnAgentProfile` returns `(nil, nil, nil)`; `CachePolicy.resolve` keeps `.standard` for a non-main principal (verify with a test).
- [ ] **Step 4: Run the suite and mutation-check:** delete the top-of-`executeFunctionCall` guard (the per-path refusals must fail); delete `restrict` after the hook (test (c) must fail); add `run_command` to `allowedNames` (the enumeration must fail).
- [ ] **Step 5: Commit** `feat: #1066 mcpGuest principal with a positively-constructed two-tool floor`.

## Task 3: Engine routing by target, and the agreement check

**Files:**
- Modify: `Sources/IrisKit/AppState.swift` (`AppState.engine`, `startTurn`, `drainPendingUserMessages`, `PendingUserMessage.engine`), `Sources/IrisKit/iris.swift` (`deliverSanitizedSystemEvent`, `deliverPeerMessage`, `processInputBody`)
- Test: `Tests/irisTests/GuestEngineRoutingTests.swift`

**Interfaces:**
- Consumes: `Conversation.isGuest` (Task 1), `Principal.mcpGuest` (Task 2).
- Produces: `AppState.engine(forTurnOn conversationId: UUID) -> IrisEngine`; `AppState.guestEngines: [UUID: IrisEngine]` (registered by Task 7's registry through `AppState.register(guestEngine:for:)` and removed with the conversation); the refusal `IrisEngine.principalMismatchRefusal`.

- [ ] **Step 1: Write the failing tests**, one per path that starts a turn on a conversation another caller named: the idle peer-arrival path (`deliverSanitizedSystemEvent`), the busy path (`queuePeerArrival` then drain), `AppState.startTurn`, and any other `processInput(` caller the search finds. For each: drive it with the wrong engine and assert the turn is **refused** with `principalMismatchRefusal` and a visible diagnostic; drive it with the routed engine and assert it runs. Add the two directional cases from the spec: a role reply to a guest runs on the guest's engine; a guest message to a role session runs the role's turn on `AppState.engine`.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestEngineRoutingTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** `engine(forTurnOn:)`; replace the caller-engine use in `deliverSanitizedSystemEvent` and the drain and `startTurn` paths with it; add the check at the head of `processInputBody`: refuse unless `conversation.isGuest == (principal == .mcpGuest)`. Search `git grep -n "processInput("` on `origin/main` and list every caller and its decision in the PR body.
- [ ] **Step 4: Run the suite and mutation-check:** remove the agreement check (the wrong-engine cases must stop being refused and the test must fail); route one path by the caller again (its test must fail).
- [ ] **Step 5: Commit** `feat: #1066 route a turn by its target conversation; refuse a principal/kind mismatch`.

## Task 4: The guest prompt and the guest engine

**Files:**
- Create: `Sources/IrisKit/GuestPrompt.swift`
- Modify: `Sources/IrisKit/iris.swift` (`composedSystemPrompt`, `ensureSystemPrompt`, `IrisEngine.init` call site, `CachePolicy` / `promptCacheKey`)
- Test: `Tests/irisTests/GuestPromptTests.swift`

**Interfaces:**
- Consumes: `Principal.mcpGuest` (Task 2).
- Produces: `enum GuestPrompt { static func text(clientId: String) -> String }`; the guest branch of `IrisEngine.composedSystemPrompt(workspacePath:additionalRoots:agentProfile:)`, which returns `GuestPrompt.text` and nothing else for `.mcpGuest`; `IrisEngine.makeGuestEngine(state: AppState, clientId: String) -> IrisEngine` (principal `.mcpGuest`, the engine's cheapest tier case, a role label naming the guest).

- [ ] **Step 1: Write the failing tests** against a populated `MemoryManager` (injected, Invariant 7) and a workspace holding an `AGENTS.md`, with a sentinel string in each of USER.md, SOUL.md, the workspace AGENTS.md and a stored fact: the guest prompt contains none of the four sentinels, no skills catalogue and no agent-profile text, and contains the guest-caution marker and states that the requester is an external agent that cannot act as Iris; a `.main` engine over the same inputs still contains the sentinels (the branch did not leak the other way); the guest's prompt-cache key differs from the main key; `makeGuestEngine` returns an engine whose `principal` is `.mcpGuest` and whose tier is the cheapest case.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestPromptTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** `GuestPrompt` (the text is decided in the PR body and pinned by the marker assertions) and the branch in `composedSystemPrompt`. Skip `ensureSystemPrompt`'s SOUL.md read, the USER.md and AGENTS.md appends and the profile append for a guest; locate each read with `git grep` and prove the skip with the sentinels.
- [ ] **Step 4: Run the suite and mutation-check:** remove the guest branch (the sentinels must appear and fail the test); keep the USER.md append for guests.
- [ ] **Step 5: Commit** `feat: #1066 guest prompt with none of the owner's context`.

## Task 5: Per-client role allowlist and guest addressing

**Files:**
- Modify: `Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift`, `Sources/IrisKit/KeychainManager.swift` (a service constant), `Sources/IrisKit/AppState.swift` (`decidePeerSend`), `Sources/IrisKit/SessionDirectory.swift`, `Sources/IrisKit/iris.swift` (guest `list_sessions` handler)
- Test: `Tests/irisTests/GuestAddressingTests.swift`, extend `ProviderTokenRegistryTests`

**Interfaces:**
- Produces: `ProviderTokenRegistry.setRoles(_ roles: Set<String>, forClientId: String) throws`, `roles(forClientId: String) -> Set<String>` (default empty, role names normalised with `SessionRoles.normalizedName`, stored in a second Keychain item `KeychainManager.mcpProviderRolesService` as `[clientId: [role]]`, revoked with the token); `AppState.guestRoleAllowlist: (String) -> Set<String>` (an injected provider, so `AppState` does not import provider types); `SessionDirectory.peersForGuest(roles:in:) -> [GuestPeerRow]` with `GuestPeerRow { name, role, description }`.

- [ ] **Step 1: Write the failing tests.** `decidePeerSend` from a guest sender: an allowed `role:x` resolves to the holder; each of `iris`, a `session_id` (including another guest's and its own), `name:y`, `topic:z`, a role not in the allowlist, `ROLE:X` case variants of a role not granted, and a vacant role is refused, and the refusal text does not reveal whether a session exists; an empty allowlist refuses everything. The reply branch accepts a guest reply target through `isReplyTarget` and skips the generic `resolve` equality check for it, and refuses a reply to a deleted guest. `list_sessions` for a guest returns only allowed roles with the three fields. Registry: roles survive reload, default empty, `revokeToken` removes them, and a client id that fails the shape check cannot hold roles.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestAddressingTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** the registry methods (one lock, `updateSecretsOrThrow`), the guest branch in `decidePeerSend` (look up the sender's `guestClientId`, call `guestRoleAllowlist`), and the guest `list_sessions` rows.
- [ ] **Step 4: Run the suite and mutation-check:** make the guest branch fall back to the normal `resolve` (the refusals must fail); widen the allowlist check to a prefix match.
- [ ] **Step 5: Commit** `feat: #1066 per-client role allowlist and guest-only addressing`.

## Task 6: Provenance framing and depth stamp

**Files:**
- Modify: `Sources/IrisKit/iris.swift` (`framePeerMessage`, `deliverPeerMessage`, the `PeerEnvelope` depth for a guest sender), the guest `send_to_session` handler
- Test: `Tests/irisTests/GuestProvenanceTests.swift`

**Interfaces:**
- Produces: `IrisEngine.framePeerMessage(_:senderName:senderId:senderRole:envelope:guestClientId: String? = nil)`; a guest `PeerEnvelope.depth` of 1.

- [ ] **Step 1: Write the failing tests.** A framed guest message names an external MCP guest and its client id, carries the standard "not from the user, not from the system" footer plus the guest-caution paragraph, and repeats the footer after the body; a message whose **content** claims to be from the user or Iris is still framed as a guest (the stamp comes from the sender conversation, never the text); `peerSource` stays the constant; repeated guest messages leave the receiving role session's `peerDepths` at 1 and do not block a local planner-to-reviewer send; a guest-started chain is still bounded by `maxSessionCascade`; the arrival sets the receiver's sticky taint (`markReadUntrusted`); a guest session's sends draw from its own `peerRateLimiter` bucket (capacity 20, one per 15 s), independent of any role session's, and the 21st send in a burst is refused.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestProvenanceTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** the guest branch of the framing (text decided in the PR body and pinned by a test) and the fixed depth.
- [ ] **Step 4: Run the suite and mutation-check:** take `guestClientId` from the message text; stamp depth `+1` per message.
- [ ] **Step 5: Commit** `feat: #1066 guest provenance framing and fixed arrival depth`.

## Task 7: `GuestSessionRegistry` (lifecycle, caps, revoke)

**Files:**
- Create: `Sources/IrisKit/MCPProvider/GuestSessionRegistry.swift`
- Modify: `Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift` (`revoke(clientId:)`), `Sources/IrisKit/MCPProvider/MCPProviderRuntime.swift`
- Test: `Tests/irisTests/MCPProvider/GuestSessionRegistryTests.swift`

**Interfaces:**
- Consumes: `AppState.createNewConversation(... isGuest:guestClientId:)` (Task 1), `AppState.register(guestEngine:for:)` (Task 3), `IrisEngine.makeGuestEngine(state:clientId:)` (Task 4), `AppState.deleteConversation`, `hasTurnInFlight(for:)`.
- Produces: `@MainActor final class GuestSessionRegistry` with `init(state: AppState, ttl: Duration = .seconds(900), maxLive: Int = 4, now: @escaping @Sendable () -> SuspendingClock.Instant, makeEngine: @escaping @MainActor (AppState) -> IrisEngine)`; `func session(for clientId: String) throws -> UUID` (creates once per client; throws `GuestSessionError.busy` over `maxLive`); `func touch(_ clientId: String)`; `func close(clientId: String)`; `func reapIdle()` (called by a `DispatchSourceTimer`, `startReaper()`/`stopReaper()`); `GuestSessionError.busy`.

- [ ] **Step 1: Write the failing tests** with an injected clock and a fake engine factory: the first call creates a guest conversation and a second returns the same id; two clients get two sessions; the fifth live session is refused with `busy` and creates nothing; a session idle past the TTL is deleted (its peer requests closed, engine unregistered) and a later call creates a fresh one; `touch` extends it; a session with a turn in flight is not closed, and closes after the turn ends; `close(clientId:)` deletes at once; **`IrisMCPProviderServer.revoke(clientId:)` closes the guest session even when `revokeToken` throws**; the reaper timer is a dispatch source (a test that the registry source contains no `Task.sleep`); a restart starts empty.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestSessionRegistryTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** the registry; the reaper interval is a named constant (60 s) and the TTL, `maxLive` are initializer parameters whose defaults are the planner-cleared values.
- [ ] **Step 4: Run the suite and mutation-check:** skip the in-flight check; drop the `close` call in `revoke`; drop the cap.
- [ ] **Step 5: Commit** `feat: #1066 guest session registry (create, reuse, idle TTL, caps, revoke)`.

## Task 8: The guest driver and the `iris_send` path

**Files:**
- Create: `Sources/IrisKit/MCPProvider/GuestSessionDriver.swift`
- Modify: `Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift` (the `iris_send` handler), `Sources/IrisKit/MCPProvider/ProviderRequestGate.swift`, `Sources/IrisKit/MCPProvider/MCPProviderRuntime.swift`, `Sources/IrisKit/GuardedSettings.swift` and `ConfigManager.swift` (`mcpGuestSessionsEnabled`)
- Test: `Tests/irisTests/MCPProvider/GuestSessionDriverTests.swift`; update the Phase 1 `deliverReply` scan test in `ProviderMailboxTests`

**Interfaces:**
- Consumes: `GuestSessionRegistry` (Task 7), `ProviderMailbox.deliverReply(to:text:fileRefs:)`, `IrisEngine.processInput(_:source:conversationId:turnBudget:)`.
- Produces: `struct GuestSessionDriver` with `func submit(text: String, from clientId: String) async -> GuestSubmitResult` where `enum GuestSubmitResult { accepted(messageId: UUID), busy, rateLimited, disabled }`; `ProviderRequestGate.admit(clientId:) -> Admission` (admits by an already-resolved client id; the turns-per-hour gate is a second `ProviderRequestGate` instance, capacity 12, refilling one per 5 minutes); `GuardedKey.mcpGuestSessionsEnabled` (`.flag(protectiveOn: false)`).

- [ ] **Step 1: Write the failing tests** with a fake turn runner: with the flag off, `iris_send` behaves as in Phase 1 (stores to the mailbox, no session); with it on, `submit` creates the session, runs one turn, and `deliverReply` stores the final assistant message for that client, which `iris_poll` returns with its sequence; the 13th turn in an hour is `rateLimited` and creates no turn; a `busy` registry returns `busy` to the MCP client as a tool error, not a queue; a turn that throws or times out delivers a short failure reply, not silence; a reply is never delivered to a client id that was revoked mid-turn (re-check `isRegistered` through `deliverReply`'s existing check); a role session answering after the guest session was reaped gets the "no longer active" refusal. **Source scan:** `deliverReply` has call sites in `GuestSessionDriver.swift` and `ProviderMailbox.swift` only, and `ProviderTokenRegistry.reservedClientId` is still never a guest key.
- [ ] **Step 2: Run** `scripts/test-filter.sh GuestSessionDriverTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** the driver and the `iris_send` branch (an `isGuestSessionsEnabled` closure injected into `IrisMCPProviderServer`'s init, default reading the guarded flag), the gate overload, and the flag. Cheapest-tier selection and the per-turn `TurnBudget` come from named constants.
- [ ] **Step 4: Run the suite and mutation-check:** deliver the reply to a different client id; skip the rate gate; skip the `isRegistered` re-check.
- [ ] **Step 5: Commit** `feat: #1066 guest session driver and iris_send guest path`.

## Task 9: Docs and the Invariant 9 sweep

**Files:**
- Modify: `docs/mcp_provider.md`, `docs/features.md` (pointer text only), `docs/specs/2026-11-11-iris-devteam-mcp-collaboration-design.md` (a pointer under section 3.2), `AGENTS.md` (only if the search finds a stale sentence), the `send_to_session` and `list_sessions` tool descriptions (guest notes)
- Test: a docs-claims check in the existing docs tests if one exists; otherwise none

**Interfaces:** none.

- [ ] **Step 1: Search** `README.md`, `docs/`, `AGENTS.md` and the agent-facing strings for what this change made untrue: "only stores", "`iris_poll` always empty", "nothing here touches `Conversation.history`", "no way to turn it on", the `deliverReply` call-site claim, the list of principals, and the `send_to_session` and `list_sessions` descriptions. List each hit and the fix in the PR body (finding nothing is a valid result).
- [ ] **Step 2: Fix** each hit in place. `docs/mcp_provider.md` gains a "Guest sessions" section: what a guest is, the two-tool floor, the allowlist, the cost statement, the flag, the caps and TTL, and that it is dormant until token and allowlist issuing exist.
- [ ] **Step 3: Run** `scripts/check-warnings.sh` and the full `swift test --no-parallel`; quote the Swift Testing and XCTest counts.
- [ ] **Step 4: Commit** `docs: #1066 guest sessions, and what they made untrue`.

## Final reviewer note

Review Focus items 1 and 2 are the access boundary: do not accept "the allowlist is declared". For each tool-dispatch path and each turn-starting path, the reviewer reproduces the wrong-principal and wrong-engine case and watches it refused, then breaks the guard (Task 2 and Task 3 mutations) and watches a test fail. Also confirm: no guest-reachable path reads USER.md, SOUL.md, AGENTS.md or facts; `grep` shows `deliverReply` in two files; the guarded flag defaults off; and the D4 and D5 values are the named constants in one place for Brian to tune.
