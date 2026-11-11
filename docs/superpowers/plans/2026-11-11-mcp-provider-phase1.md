# Iris MCP Provider — Phase 1 (Shape 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a loopback, token-gated MCP **provider** on the running Iris app: a read-only app-level self-report door (window/responder/composer/turn/activation snapshots + an event ring buffer) plus a plain messaging/file-exchange mailbox between registered local clients — with no role-session turns, no model access, and no Conversation/history reads anywhere in the surface.

**Architecture:** A new `Sources/IrisKit/MCPProvider/` module hosts a `MCP.Server` (from the existing `swift-sdk` dependency) behind a hand-rolled loopback-only HTTP/1.1 listener that bridges raw socket bytes to the SDK's framework-agnostic `StatelessHTTPServerTransport`. Bearer tokens are Keychain-bound (one per registered client), checked and rate/concurrency-budgeted *before* any MainActor hop. The self-report door reads live AppKit/AppState through a small set of enumerated, bounded queries raced against a dispatch-timer deadline (`withTimeout`, never `Task.sleep`, per Invariant 4). The mailbox and file exchange are a standalone actor with their own content-addressed store and TTL sweep — intentionally outside `Conversation`/`AppState.history`, so nothing here touches shared turn state, the peer-cascade budget, or the taint model.

**Tech Stack:** Swift 6, `swift-sdk` (MCP) `Server`/`StatelessHTTPServerTransport`, `Network.framework` (`NWListener`) for the loopback socket, `KeychainManager` for token storage, `CryptoKit` for SHA-256 content addressing, Swift Testing.

**Spec:** `docs/specs/2026-11-11-iris-devteam-mcp-collaboration-design.md` (PR #1063, head `fa89958b`) — read §3.1, §3.3, §3.4, §3.6, §3.7, §3.8. Scope and guardrails: issue #1067. Neighbouring (unbuilt, not used by Phase 1): `docs/superpowers/specs/2026-11-08-iris-local-agent-mcp-design.md` (#964, branch `design/iris-local-agent-mcp`).

**Design resolution (revised 2026-11-11 — Brian vetoed client-to-client relay, relayed by the planner):** §1067's "send/poll/discover/status... no role-session turns in Phase 1" leaves open what `send` addresses, since #964's role-session/inbox delivery is explicitly out of scope here. An earlier draft of this plan resolved it as client-to-client relay — any registered MCP client could `send` to any other, over a flat registry of tokens issued to local MCP clients (the dev-team sessions). Brian struck that: "whether one iris mcp client can directly message another mcp client through iris? that seems out of bounds." This plan now resolves it as **client↔Iris only**: a client `send`s to Iris (the running app/operator) and `poll`s for Iris's replies to it — the mailbox is never a relay between two MCP clients, and still new, standalone state, never `AppState`. `discover`/`status` surface Iris itself as the peer a client is talking to, not a roster of other registered clients (an enumerable client roster is itself a client-to-client discovery primitive, even once direct `send` to another client is gone). This still sidesteps every §3.2 confidentiality problem (no shared history, no principal, no model in the loop) and matches "serves the debugging motivator with no confidentiality exposure" (§5). Peer-to-peer (client↔client) messaging is struck from Phase 1 entirely, not deferred: Phase 2's dev↔Iris-*agent* messaging (Shape 5, gated on #1066, needing a role-session turn) is also client↔Iris-agent, never client↔client, so no later phase in this program reintroduces a direct relay either.

This is infra investment, not throwaway: Task 1's per-token registry, Task 3's auth/budget gate, Task 6's send/poll/provenance machinery (now client↔Iris, not client↔client), and Task 7's content-addressed store are the exact scaffold Phase 2's dev↔Iris messaging reuses once #1066's context partitioning lands — Phase 2 adds a role-session-addressed delivery path on top of this, it does not replace it.

## SDK spike findings (dev-2 review, blockers 1 & 2 — confirmed 2026-11-11 against pinned `swift-sdk` @ `a0ae212ebf6eab5f754c3129608bc5557637e605`)

Read directly, not run (no harness exists yet to run it against):

- **`Server.swift` ~928-969 (`Initialize` handler):** `isInitialized` is set `true` in `setInitialState` and never reset. A second `initialize` call on the *same* `Server` instance throws `MCPError.invalidRequest("Server is already initialized")` unconditionally — `strict` does not gate this check, only the ones below do. **Confirmed:** one shared `MCP.Server` cannot serve a second client's `initialize`, so the original Task 8 (one `Server` + one `StatelessHTTPServerTransport`, started once at app launch) cannot work for more than one client session.
- **`Server.swift` `Configuration.default = Configuration(strict: false)`, and `handleMessage`/`processRequest` (~750-765, ~854-865):** the `checkInitialized()` gate that would otherwise reject `tools/call` before `initialize` only runs `if configuration.strict`. With the default (non-strict) configuration, a **fresh** `Server` that has never seen an `initialize` call accepts a bare `tools/call` (or any other request) directly. **Confirmed:** a fresh `Server` + fresh transport, built per authenticated HTTP request and never asked to `initialize` at all, serves exactly one JSON-RPC request with no "already initialized" state ever touched.
- **`StatelessHTTPServerTransport.swift` `handleJSONRPCRequest` (~220-244):** `httpRequestContexts[requestID]` and `responseWaiters[requestID]` are both keyed by the **JSON-RPC request id string**, not by connection or client. Two concurrent requests that both carry id `"1"` (two independent MCP clients each starting their own id sequence at 1, which every MCP client does) overwrite each other's dictionary entry between the `httpRequestContexts[requestID] = request` write and the point the server's handler later reads `httpRequestContext(for:)` — the intervening `await` on `responseWaiters[requestID]`'s continuation is a real suspension point, so this is a genuine same-actor interleaving hazard, not just a data race. **Confirmed:** under one shared `Server`+transport, client A's handler can read client B's `Authorization` header (breaking `from` provenance and the mailbox boundary) and B's own HTTP response can hang forever (its waiter was silently replaced).

**Resolution, replacing Task 8's original architecture (see the rewritten Task 8 below):** the loopback listener's `handle` closure resolves the bearer token and the client id **before constructing any `MCP.Server`** (this also makes Gap 3's pre-dispatch auth free — the raw `HTTPRequest`'s `Authorization` header is read straight off the socket-parsed request, with no need to round-trip through `Server.currentHandlerContext?.httpContext` at all). On a successful admit, it builds **one fresh `MCP.Server(configuration: .default)` and one fresh `StatelessHTTPServerTransport()` per request**, registers that request's tool handlers closed over the already-resolved `clientId`, starts the server against the transport, calls `transport.handleRequest(request)` exactly once, and **explicitly stops the server before returning** (`Server.start(transport:)` spawns a receive-loop task that holds both objects alive until `Server.stop()` cancels it and disconnects the transport — dev-2 round 2, item 1: letting them merely "fall out of scope" leaks a Server, its task, and a transport per request, since nothing else ever ends that task). No `Server` instance is ever asked to `initialize` twice, and no two requests ever share a `transport`'s `httpRequestContexts`/`responseWaiters` dictionary, so the JSON-RPC id collision in blocker 2 cannot occur structurally — there is no shared keyspace left for two ids to collide in.

## Global Constraints

- Loopback only: the listener binds `127.0.0.1` exclusively; binding any other interface is a bug, not a config choice.
- No role-session turns, no model calls, no read of `Conversation.history` or `AppState` conversational state anywhere in this surface (§1, §3.2 — Phase 1 is Shape 4).
- The self-report door's window-owner query emits the app **bundle identifier only**, never the window title string (§3.7 Rune fix).
- The self-report door's responder query emits the **class name only**, never `stringValue` or any control contents (§3.7 Rune fix).
- The MCP/HTTP entry point is **non-`@MainActor`**; a diagnostic read that needs AppKit/`AppState` state races a dispatch-timer deadline, never `Task.sleep` (Invariant 4; reuse `withTimeout(seconds:_:)` from `Sources/IrisKit/Timeout.swift`).
- The self-report door has its **own** per-token rate/concurrency budget, enforced at the MCP entry point **before** the MainActor hop (§3.7 Rune fix) — distinct from any budget on the mailbox tools.
- The event ring buffer's size, per-entry cap, and retention are named constants, not "bounded" left unspecified (§3.7 Rune fix).
- The bearer token is bound to something a plain file read can't lift: a Keychain item (one per client), never written in plaintext under `~` (§3.3 — "bind the token" branch, not "declare any local process").
- Every mailbox message and stored artifact is provenance-stamped with its sending client's id; nothing a guest sends is ever representable as Iris-origin (§3.4).
- Guest/client file exchange gets its **own** TTL sweep, independent of `ArtifactStore.sweep`'s conversation-row model — a client here has no `Conversation` and so no row-delete path (§4).
- Guest→Iris file ingest is inline bytes or an `artifact_put`-style tool call only, **never** a host `{path}` read (§3.1 — `IrisEngine.attachFile` authorizes against a `Conversation`'s scope a client here does not have).
- Off by default: the provider only binds its socket when the feature toggle (new `GuardedKey.mcpProviderEnabled`) is on, following the existing `enableSandboxing` toggle's `didSet`-persisted pattern (cite by symbol, not line number — `ConfigManager`/`GuardedSettings` line numbers drift between `~/src/iris` and `origin/main`, per this repo's own citation convention).
- `ProviderArtifactStore.get` is **not** a bare-hash-grants-a-read surface (§7.6 B's rule: a hash alone grants nothing) — a read succeeds only for a client in that object's own authorized set, populated at `put`/`send` time (Task 7/6, planner review on PR #1068).
- The loopback listener binds its socket to `127.0.0.1` via `NWParameters.requiredLocalEndpoint` (construction-time, not just a runtime connection filter) — the per-connection endpoint check (Task 2) is defence in depth on top of that bind, not a substitute for it (planner review on PR #1068).
- `DiagnosticEventRing` preserves the physical order events occurred in; a diagnostic ring that can reorder the very sequence it exists to capture (#1055's point) is worse than no ring. Use a synchronous, lock-based recorder, not `Task { await actor.record(...) }` from a sync callback (planner review on PR #1068).
- **No `MCP.Server` instance is ever used for more than one JSON-RPC request** (dev-2 blocker 1/2 — see "SDK spike findings" above). A fresh `Server` + fresh `StatelessHTTPServerTransport` pair is built per authenticated HTTP request, inside Task 8's wiring, never shared or cached across requests or clients.
- **Auth happens on the raw `HTTPRequest`, before any `MCP.Server` exists** (dev-2 Gap 3) — the listener's `handle` closure resolves the bearer token and calls the appropriate `ProviderRequestGate.admit(bearerToken:)` first; `initialize`, `tools/list`, and `ping` get no free pass just because they look harmless. A 401 at this layer touches no SDK type at all.
- **`ProviderArtifactStore.authorize` requires the sender to already hold read access** (dev-2 Gap 4, closing the hole in the planner's own ACL fix on PR #1068): `authorize(sha256:, by: senderId, adding:)` throws `.unauthorized` unless `senderId` is already in that object's authorized-reader set. A client that merely *learns* a hash (e.g. because another message mentioned it) must never be able to grant a third party read access to it.
- **Every SHA-256 string reaching the filesystem is validated as 64 lowercase hex digits first** (dev-2 Gap 4) — `ProviderArtifactStore` never passes a caller-supplied or message-supplied string to a file path without that check.
- **Resource bounds are named constants with enforcing tests, not narrative "bounded" language** (dev-2 Gap 7): the listener caps request-line length, header count and byte size, `Content-Length`, and read timeout (Task 2); the inline `artifact_put` body cap for Phase 1 is 8 MiB, not romar's 64 MiB baseline (base64 inflation makes 64 MiB ~86 MB resident per request — Task 7); `ProviderArtifactStore` has a per-client daily quota and a total store cap, mirroring `ArtifactLimits.sessionDailyBytes` (200 MiB) and `.defaultExchangeCapMB` (2048 MiB) at `Sources/IrisKit/Artifacts.swift:56-60` (Task 7); `ProviderMailbox` caps message count, text size, and `fileRefs` count per message, has its own TTL, and exposes a monotonic sequence cursor for polling instead of `since: Date` (Task 6).
- Every elapsed-time bound in this surface (`ProviderRequestGate`'s token bucket, `ProviderMailbox`'s poll cursor) uses a monotonic clock (`ContinuousClock`/`Duration`), never `Date`/`TimeInterval` — AGENTS.md #605: `Date()` counts a Mac sleep, and a maintenance sleep mid-run has produced impossible walls before.
- **The mailbox is client↔Iris only — no API anywhere in this surface accepts an arbitrary other-client id as a message's recipient** (Brian's veto, 2026-11-11): `ProviderMailbox.send` always addresses Iris; the only way a message is ever addressed to a *client* id is `deliverReply`, which Task 8 does not expose as an MCP tool, so no MCP client can write into another client's inbox, directly or by naming it as an argument.

## Review Focus

- **A client with no token, a malformed token, or a token for a different/unknown client sends a request — including `initialize`, `tools/list`, or `ping`, not just a tool call.** Expected: 401 before any tool dispatch and before any `MCP.Server` is even constructed (dev-2 Gap 3), no MainActor hop, no budget consumed. Task 8's listener-level auth wrapper owns this, with tests for missing, malformed, and well-formed-but-unknown tokens distinctly.
- **The loopback listener receives a non-HTTP byte stream, a truncated request, or a request with a huge/absent `Content-Length`.** Expected: the connection is closed or answered with an error; the listener itself never hangs, crashes, or blocks other connections. Task 2 owns this, with named constants for the request-line/header/`Content-Length`/read-timeout caps and a test per cap (dev-2 Gap 7).
- **The self-report door is called while Iris is backgrounded (not key/active).** Expected: the snapshot still returns, tagged with its own activation state, rather than silently reporting "not key" as if the queried fact itself were false (§3.7 key-window subtlety). Task 5 owns this.
- **A client floods the self-report door faster than its rate/concurrency budget allows.** Expected: requests over budget are rejected at the entry point before the MainActor hop — never queued, never left to time out on the main actor race. Task 3's budget gate is admitted exactly once, in Task 8's `handleAuthenticated`, structurally before `SelfReportDoor` is ever constructed or called (dev-2 round 2, item 2 — the door takes an already-resolved `clientId`, not a `bearerToken`, and has no `admit` call of its own to test); Task 8's own test suite is where the enforcing test for "budget exhausted → the door's MainActor-only probe never moves" lives, since that is the only place the admission decision is made at all.
- **A registered client disconnects (or is revoked) with files still in the guest artifact store.** Expected: those blobs are reclaimed by the store's own TTL sweep without needing a `Conversation` row or `deleteConversation` call. Task 7 owns this.
- **A client that only ever learns a hash (from a message mentioning it, never from its own `put` or an `authorize` grant) tries to read or re-grant it.** Expected: refused both ways — `get` throws `.unauthorized`, and `authorize(sha256:, by:, adding:)` throws unless the caller passed as `by:` already holds a read. Task 7 owns the store-level test; Task 8 owns the end-to-end one (dev-2 Gap 4).

---

## Task 1: Provider token registry and feature toggle

**Files:**
- Create: `Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift`
- Create: `Tests/irisTests/MCPProvider/ProviderTokenRegistryTests.swift`
- Modify: `Sources/IrisKit/ConfigManager.swift` (add `mcpProviderPort: Int`, a **plain**, non-guarded stored property — dev-2 smaller item: a port number fits neither `GuardedKey.Kind.cap` nor `.flag` — defaulting to a new named constant `ConfigManager.defaultMCPProviderPort = 8787`, persisted the same way any other plain `ConfigManager` setting is; grep an existing non-guarded `didSet`-persisted `Int` property for the exact pattern to mirror)
- Modify: `Sources/IrisKit/GuardedSettings.swift` (add `mcpProviderEnabled` as a new `GuardedKey` case — see Step 5)

**Interfaces:**
- Produces: `ProviderTokenRegistry`, a `final class ... : @unchecked Sendable` (mirroring `KeychainManager`'s own concurrency shape — an internal lock guards the in-memory cache below) with:
  - `static let reservedClientId = "iris"` — the string identity `ProviderMailbox.MailboxParty.iris` (Task 6) is distinct from by construction at the mailbox layer, but `ProviderArtifactStore`'s authorized-reader sets (Task 7) are plain `Set<String>` with no equivalent type separation, so a client that successfully registered under this literal could still gain a read via `authorizeAll(adding: Self.reservedClientId)`'s string match alone. Reserving it here closes that second surface (dev-3's rule-26 read on PR #1068, finding 1, folded per planner's rule).
  - `enum RegistryError: Error, Equatable { case reservedClientId }` — thrown by `issueToken` below; `revokeToken`/`clientId(forToken:)` continue to surface `KeychainManager`'s own errors, since this is the only new failure mode this task adds.
  - `func issueToken(forClientId clientId: String) throws -> String` — **first throws `RegistryError.reservedClientId` if `clientId == Self.reservedClientId`**, before any Keychain write; otherwise generates a token from 32 random bytes via `SecRandomCopyBytes` (base64url- or hex-encode them; **not** `UUID().uuidString`, which has only 122 bits of entropy from a generator not specified as cryptographically secure and is the wrong tool for a bearer credential), stores `[clientId: token]` into the Keychain under a new service `KeychainManager.mcpProviderService = "iris.mcp.provider"` via `KeychainManager.shared.updateSecretsOrThrow(service:_:)` (which itself `throws`, so this does too), updates the in-memory cache, and returns the token.
  - `func revokeToken(forClientId clientId: String) throws` — removes that client's entry via the same `updateSecretsOrThrow` pattern and invalidates/updates the in-memory cache. **This method does not, and cannot, purge mailbox/file-ACL state** — this registry has no reference to `ProviderMailbox`/`ProviderArtifactStore`, so it is not the right place to do it (dev-2 round 2, item 4: an earlier draft of this task said `revokeToken` purges that state and separately said it returns the old token, which contradicted this `throws`-with-no-return signature and had no caller to hand the old token to anyway). The one place a client's token, mailbox, and file-ACL state are all torn down together is `IrisMCPProviderServer.revoke(clientId:)` in Task 8 — see that task for the actual purge, which this registry's `revokeToken` is one of three calls inside.
  - `func clientId(forToken token: String) -> String?` — reverse lookup against the **in-memory cache**, not a fresh Keychain read. Dev-2 smaller item: a Keychain lookup on every HTTP request (and a locked or denied Keychain item can raise a user-facing prompt) is unacceptable on a hot path; load the registry's whole map into memory once (on init, and again on every `issueToken`/`revokeToken`), and resolve tokens against that cache. The cache is guarded by the same internal lock as the rest of this class's mutable state.
  - `func allClientIds() -> [String]` — every registered client id (backs `discover` in Task 6), from the in-memory cache.
  - `func isRegistered(clientId: String) -> Bool` — `allClientIds().contains(clientId)` against the in-memory cache, no Keychain read (dev-2 round 3 smaller item 2: `ProviderMailbox.send` and `ProviderArtifactStore.put` re-check this at mutation time, below, so a request admitted before a concurrent `revoke(clientId:)` cannot create new state under the just-revoked id — this is the cheap lookup that check needs; consumed by Tasks 6 and 7).
  - `init(keychain: KeychainManager = .shared)` — injectable for tests, per `AGENTS.md` Invariant 7 (never touch `KeychainManager.shared` from a test); loads the initial cache from the Keychain in `init`, **skipping any entry keyed `Self.reservedClientId`** (dev-3's rule-26 re-read: `issueToken`'s guard only stops a *new* registration — an item already sitting in the Keychain service under that key from before this guard existed, or written by any path other than `issueToken`, would otherwise load straight into the cache and `isRegistered`/`allClientIds` would treat it as a normal, usable client id). A skipped entry is not deleted or repaired, just never surfaced through this cache.
- Consumes: `KeychainManager.updateSecretsOrThrow(service:_:)`, `.secretsOrThrow(service:)`, `.deleteSecrets(service:)` (existing, `Sources/IrisKit/KeychainManager.swift`).

**Out of scope for this task, flagged minor from PR #1068's review:** this plan builds `issueToken`/`revokeToken` as a programmatic API only — no UI, menu command, or CLI flag calls them yet. Getting a token into a dev-team session's `.mcp.json` (or wherever Claude Code's MCP client config lives) is a manual step for whoever builds this, done once per client by calling `issueToken` from a debug/REPL path (e.g. a temporary `--mcp-provider-issue-token <clientId>` headless CLI flag, if one is added — not specified by this plan, since #1067's scope is the provider surface, not its own onboarding UI). Note this gap explicitly in the task's self-review rather than silently shipping a registry nothing can populate outside tests. **Also flag as a follow-up, not something this plan closes (dev-2 smaller item):** the Keychain binding protects only the *server's* copy of the token — the client's copy sits in plaintext in Claude Code's own config file once issued (Clomp's #5 on #1063). Add `~/.claude`, `~/.claude.json`, and `**/.mcp.json` to whatever deny-list governs `read_file`'s reach, as a tracked follow-up issue; do not claim in this plan or its docs that a plain file read cannot lift the token — it can, from the client's side.

- [ ] **Step 1: Write the failing test for issue/lookup/revoke round-trip**

```swift
@Test("issuing a token makes it resolve back to the client id, and revoking removes it")
func issueLookupRevoke() throws {
    let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
    let registry = ProviderTokenRegistry(keychain: keychain)
    let token = try registry.issueToken(forClientId: "iris-dev-1")
    #expect(registry.clientId(forToken: token) == "iris-dev-1")
    #expect(registry.allClientIds() == ["iris-dev-1"])
    try registry.revokeToken(forClientId: "iris-dev-1")
    #expect(registry.clientId(forToken: token) == nil)
}
```

Dev-2 smaller item: `KeychainManager(serviceSuffix:)` alone hits the real Keychain — grep existing test call sites in `Tests/irisTests/` for `KeychainManager(serviceSuffix:`, confirm it exposes an `inMemory: true` (or equivalently named) test-isolation parameter, and use that exact pattern here, not a bare `serviceSuffix:` call.

```swift
@Test("issueToken refuses the reserved \"iris\" client id, before any Keychain write")
func reservedClientIdRejected() throws {
    let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)", inMemory: true)
    let registry = ProviderTokenRegistry(keychain: keychain)
    #expect(throws: ProviderTokenRegistry.RegistryError.reservedClientId) {
        try registry.issueToken(forClientId: ProviderTokenRegistry.reservedClientId)
    }
    #expect(registry.allClientIds().isEmpty)  // the rejected call left no trace
}

@Test("a pre-existing Keychain entry keyed \"iris\", written by any path other than issueToken, is skipped on load")
func reservedClientIdSkippedOnLoad() throws {
    // Write a raw [ "iris": "some-token" ] entry directly via KeychainManager.updateSecretsOrThrow,
    // bypassing ProviderTokenRegistry.issueToken entirely (simulating an item that predates this
    // guard, or was written by some other path) — then construct a *new* ProviderTokenRegistry
    // over that same keychain and assert allClientIds() does not contain "iris" and
    // isRegistered(clientId: "iris") is false, even though the raw entry is sitting there.
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh ProviderTokenRegistryTests`
Expected: fails to compile (`ProviderTokenRegistry` undefined) or runs 0 tests — confirm the script reports a non-zero test count once Step 3 exists, not before.

- [ ] **Step 3: Implement `ProviderTokenRegistry` in `Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift`, and `KeychainManager.mcpProviderService`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh ProviderTokenRegistryTests`
Expected: PASS, test count ≥ 3

- [ ] **Step 5: Add `mcpProviderEnabled` to `GuardedSettings.swift`'s `GuardedKey`, and `mcpProviderPort` to `ConfigManager`**

`mcpProviderEnabled` opens a network listener when on, so **off must be the protective value** — the opposite of every existing `.flag` case (`enableSandboxing`/`enableVibecop`/`enablePromptInjectionProtection`), whose `protective` is hardcoded `"true"` regardless of case. Extend `GuardedKey.Kind.flag` to carry its own protective default — `case flag(protectiveOn: Bool)` — and update **every** switch over `.flag` in `GuardedSettings.swift` (dev-2 round 2 smaller item: there are five, not three — `kind`'s own `.flag` case assignment, `builtIn`, `protective`, `isValid`, and `carriesOver` — grep `case .flag` in that file rather than trusting a count from memory) so each existing case passes `protectiveOn: true` (no behavior change for them) and the new case:

```swift
case mcpProviderEnabled = "MCP_PROVIDER_ENABLED"
// in `kind`:
case .mcpProviderEnabled: .flag(protectiveOn: false)
```

Also grep `GuardedSettingsTests` for any test that enumerates `GuardedKey.allCases` and switches on `.flag` directly (dev-2 round 2 smaller item) — a non-exhaustive `switch` there would compile today and silently skip the new case; make sure it doesn't.

Add `mcpProviderPort: Int` to `ConfigManager` as a plain (non-guarded) setting, per this task's Files note above — it is a bind port, not a spend/safety control, so it does not belong in `GuardedSettings` at all. **Default per build identity, not one shared constant** (dev-2 round 2 smaller item): the dev build and the installed release build can both have the provider enabled at once (same machine, two home directories, two Keychain-suffixed token stores already kept separate per `AGENTS.md`'s dev/release split) and a single shared default port would collide (`EADDRINUSE`, surfacing as a thrown `start()` error with no clear cause). Define `ConfigManager.defaultMCPProviderPort: Int` as a `BuildIdentity`-keyed value (e.g. `8787` release, `8788` dev — grep `BuildIdentity.current` for the existing dev/release branching pattern and mirror it) rather than one bare literal.

- [ ] **Step 6: Write the failing test that `mcpProviderEnabled`'s protective value is `"false"`, following the existing `GuardedSettings`/`GuardedKey` test pattern for an existing flag, plus the mirrored `ConfigManager` persistence test for `mcpProviderPort` (isolated `ConfigManager(store:)`, per Invariant 7) confirming the dev/release defaults differ**

- [ ] **Step 7: Run both; verify they pass**

Run: `scripts/test-filter.sh GuardedSettingsTests && scripts/test-filter.sh ConfigManagerTests` (or whatever suites these live in — grep for the existing ones rather than guessing names)
Expected: both PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift Sources/IrisKit/KeychainManager.swift Sources/IrisKit/ConfigManager.swift Sources/IrisKit/GuardedSettings.swift Tests/irisTests/MCPProvider/ProviderTokenRegistryTests.swift Tests/irisTests/ConfigManagerTests.swift Tests/irisTests/GuardedSettingsTests.swift
git commit -m "feat: #1067 provider token registry + feature toggle"
```

---

## Task 2: Loopback HTTP listener bridging to the MCP SDK transport

**Files:**
- Create: `Sources/IrisKit/MCPProvider/LoopbackHTTPListener.swift`
- Create: `Tests/irisTests/MCPProvider/LoopbackHTTPListenerTests.swift`

**Interfaces:**
- Consumes: `MCP.StatelessHTTPServerTransport` — **confirmed against the pinned SDK revision** (`Package.resolved`, `swift-sdk` @ `a0ae212ebf6eab5f754c3129608bc5557637e605`, branch `main`): `public func handleRequest(_ request: HTTPRequest) async -> HTTPResponse` at `.build/checkouts/swift-sdk/Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift:156` (and the stateful variant at the equivalent line in `StatefulHTTPServerTransport.swift:170`, not used here), plus the `HTTPRequest`/`HTTPResponse` types from `HTTPServerTypes.swift` (`HTTPRequest.init(method:headers:body:path:)`, `HTTPRequest.header(_:)` case-insensitive lookup, `HTTPResponse.statusCode`/`.headers`/`.bodyData`). If `Package.resolved`'s pinned revision has moved by the time this task starts, re-grep for `handleRequest` at that revision before trusting this citation — the plan review (PR #1068) flagged this exact drift risk.
- Produces: `final class LoopbackHTTPListener: @unchecked Sendable` (the mutable `NWListener`/connection state needs a lock, not actor isolation — this type's `start`/`stop` are called from app-lifecycle code, not from inside an actor context, so plain `Sendable` would be a lie without one; guard the mutable state with an `NSLock`, same shape as `DiagnosticEventRing`) with:
  - `init(port: UInt16, handle: @escaping @Sendable (HTTPRequest) async -> HTTPResponse)` — `handle` is the transport's `handleRequest`, injected so this task's tests never need a real `MCP.Server`.
  - `static let maxRequestLineBytes = 8 * 1024`, `static let maxHeaderBytes = 32 * 1024`, `static let maxHeaderCount = 64`, `static let maxContentLength = 16 * 1024 * 1024` (dev-2 Gap 7 — named constants; `maxContentLength` is a transport-level ceiling above Task 7's own 8 MiB object cap, since this listener also carries JSON-RPC envelope overhead), `static let readTimeout: Duration = .seconds(30)` (bounds the *body* read once headers are complete) — all enforced by the parser in this task, not left as "bounded" prose. **`static let headerCompletionDeadline: Duration = .seconds(5)`** (dev-2 round 3 smaller item 4 — a separate, shorter bound on how long a connection may sit *before* its headers finish: with `maxConcurrentConnections` capping total slots and no deadline on an idle, headers-never-sent connection, up to `maxConcurrentConnections` idle sockets from any local process can occupy every slot for the full `readTimeout`, locking out every legitimate client meanwhile — low severity on loopback, but the cap and the body timeout interact badly without this). A connection whose request line and headers are not fully parsed within `headerCompletionDeadline` is closed, freeing its slot. **`static let maxConcurrentConnections = 16`** (dev-2 round 2 smaller item: with no cap, each of an unbounded number of simultaneously accepted connections can hold up to `maxContentLength` — 16 MiB — of buffered body before its handler even runs, which is an unbounded-in-aggregate memory ceiling masquerading as a per-request bound). `start()`'s connection-accept callback refuses (immediately closes) a new connection once `maxConcurrentConnections` are already open, tracked by the same lock guarding this type's other mutable state.
  - `func start() async throws` — binds the socket to loopback at **construction time**, not just by filtering connections after the fact (planner review on PR #1068 — defence in depth has two independent layers here): build `var params = NWParameters.tcp` and set `params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)` before constructing `NWListener(using: params)` — confirm `NWParameters.requiredLocalEndpoint` exists on the deployment target (Network.framework, available since macOS 10.15) before writing code that assumes it; if it is unavailable for any reason, that is a plan-breaking finding to report back, not something to silently work around. **`async throws`, not plain `throws`** (dev-2 smaller item): `NWListener` reports bind failure asynchronously through its `stateUpdateHandler` (`.failed`), not as a thrown error from the constructor or `start`, and reading back the real port after a port-`0` ephemeral bind needs to await the `.ready` state — `start()` awaits that state transition and throws if it resolves to `.failed` instead of `.ready`. **On top of** that bind, still check each accepted connection's remote endpoint and refuse (cancel) anything not `127.0.0.1`/`::1` — the second, independent layer, in case the bind-time restriction is ever misconfigured or bypassed by a future refactor.
  - `func stop()`.
  - A minimal HTTP/1.1 request-line + header + `Content-Length`-bounded body parser, reading from an `NWConnection`'s receive loop into an `HTTPRequest`, enforcing the four caps above (an oversize request line, too many/too-large headers, a `Content-Length` over `maxContentLength` or missing on a method that requires a body, or a connection idle past `readTimeout`, all close the connection with an error response or no response, never hang), and a response writer serializing `HTTPResponse.statusCode`/`.headers`/`.bodyData` back as raw bytes. (This parser is net-new, hand-rolled, and intentionally minimal: POST only, no chunked transfer-encoding, no keep-alive required for a single local client.)

- [ ] **Step 1: Write the failing test for a loopback POST round-trip**

```swift
@Test("a POST to the listener's port reaches the injected handler and returns its response")
func postRoundTrips() async throws {
    let listener = LoopbackHTTPListener(port: 0) { request in
        .data(Data("{\"ok\":true}".utf8), headers: ["Content-Type": "application/json"])
    }
    // start, discover the bound ephemeral port, POST to it with URLSession, assert 200 + body
}
```

Use port `0` (ephemeral) if `NWListener` supports it for a deterministic test port; otherwise pick a fixed high test port and accept the small flake risk, documenting the choice in a comment. Read the bound port back from the listener (`NWListener.port` once the listener reports ready) rather than hardcoding it blind.

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh LoopbackHTTPListenerTests`
Expected: fails to compile (`LoopbackHTTPListener` undefined)

- [ ] **Step 3: Implement `LoopbackHTTPListener`**

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-filter.sh LoopbackHTTPListenerTests`
Expected: PASS

- [ ] **Step 5: Write the failing test that `start()` configures a loopback-bound `NWParameters` (layer 1), and the failing test that a connection from a non-loopback remote address is refused (layer 2)**

```swift
@Test("start() binds via NWParameters.requiredLocalEndpoint to 127.0.0.1, not just any interface on the port")
func bindsToLoopbackAtConstructionTime() throws {
    // Extract the parameter-building step into a static/testable function, e.g.
    // `static func loopbackParameters(port: UInt16) -> NWParameters`, and assert its
    // `.requiredLocalEndpoint` equals `.hostPort(host: "127.0.0.1", port: ...)`. Unit-testable
    // without opening a real socket.
}

@Test("a connection whose remote endpoint is not loopback is refused, not served")
func nonLoopbackRefused() async throws {
    // Exercise the endpoint-check path directly (unit-test the predicate function extracted
    // from start()'s connection handler) rather than trying to fake a non-loopback NWConnection,
    // which the test process cannot originate. Name the predicate so it's testable in isolation,
    // e.g. `static func isLoopback(_ endpoint: NWEndpoint) -> Bool`. This is layer 2, defence in
    // depth on top of Step 5's bind-time restriction — it must stay even once the bind exists.
}
```

- [ ] **Step 6: Run both, verify they fail, implement `LoopbackHTTPListener.loopbackParameters(port:)` and `.isLoopback(_:)`, run again, verify they pass**

Run: `scripts/test-filter.sh LoopbackHTTPListenerTests`
Expected: PASS, test count ≥ 3

- [ ] **Step 7: Write the failing test for a malformed/truncated request not hanging or crashing the listener, plus the huge/absent `Content-Length` case (Review Focus item 2)**

```swift
@Test("a truncated request closes its connection without affecting a later well-formed one")
func truncatedRequestDoesNotWedgeListener() async throws {
    // Open a raw TCP connection to the listener's port, write a partial request line, close it.
    // Then issue a normal POST (as in postRoundTrips) and assert it still succeeds.
}

@Test("a Content-Length over the cap, or absent on a POST, is refused rather than read into memory")
func contentLengthBoundsEnforced() async throws {
    // Open a raw TCP connection; send a POST with Content-Length larger than
    // LoopbackHTTPListener.maxContentLength and assert the connection is closed/errored before
    // the body is fully read (the listener must check the header, not read-then-reject). Repeat
    // with no Content-Length header at all on a POST with a body.
}

@Test("a connection past maxConcurrentConnections is refused outright, not queued")
func concurrentConnectionCapEnforced() async throws {
    // Open maxConcurrentConnections raw TCP connections to the listener's port and leave them
    // idle (no request sent yet, so they're still "open" from the listener's perspective); open
    // one more and assert it is refused/closed immediately rather than accepted and left waiting.
}

@Test("a connection that never finishes sending headers is closed after headerCompletionDeadline, freeing its slot")
func headerCompletionDeadlineEnforced() async throws {
    // Open a connection and write only a partial request line (no terminating CRLF, never
    // completing headers); wait past headerCompletionDeadline (drive the wait via a test
    // clock/injected deadline rather than a real sleep, same as truncatedRequestDoesNotWedgeListener's
    // approach); assert the connection is closed, and that a fresh well-formed request still
    // succeeds immediately afterward (the slot was freed, not permanently consumed).
}
```

- [ ] **Step 8: Run all four, verify they fail if the parser currently hangs, dies, reads an oversize body, accepts unlimited connections, or lets an idle connection sit past its header deadline; fix; verify they pass**

Run: `scripts/test-filter.sh LoopbackHTTPListenerTests`
Expected: PASS, test count ≥ 7

- [ ] **Step 9: Commit**

```bash
git add Sources/IrisKit/MCPProvider/LoopbackHTTPListener.swift Tests/irisTests/MCPProvider/LoopbackHTTPListenerTests.swift
git commit -m "feat: #1067 loopback-only HTTP listener for the MCP provider transport"
```

---

## Task 3: Per-token auth and rate/concurrency budget gate

**Files:**
- Create: `Sources/IrisKit/MCPProvider/ProviderRequestGate.swift`
- Create: `Tests/irisTests/MCPProvider/ProviderRequestGateTests.swift`

**Interfaces:**
- Consumes: `ProviderTokenRegistry.clientId(forToken:)` (Task 1).
- Produces: `actor ProviderRequestGate` with:
  - `init(registry: ProviderTokenRegistry, capacity: Int, refillInterval: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now })` — a token-bucket per client id, same *algorithm* as `AppState.PeerRateLimiter` (grep `Sources/IrisKit/AppState.swift` for `PeerRateLimiter`'s `take(for:)`/`refund(for:)`), but **not** its `Date`/`TimeInterval` clock: `PeerRateLimiter` is exactly the case AGENTS.md #605 warns about (a `Date()`-timed bucket counts a Mac sleep as elapsed budget), so this bucket's bookkeeping uses `ContinuousClock.Instant`/`Duration` throughout, with `now` injectable for tests. This is a **new, separate** limiter instance; it must never read or write `AppState.peerRateLimiter` or `AppState.inboxEmitRateLimiter`, per this plan's Global Constraints. This gate is **rate-only, not a concurrency cap** (dev-2 smaller item — name this explicitly in the doc comment): `admit` has no matching release, so there is no in-flight-request ceiling here, only a refilling-bucket limit on requests per interval. If a true concurrency cap (bounding simultaneous in-flight requests, not just their rate) turns out to be needed, that is a different primitive and a follow-up, not something this type silently also does.
  - `enum Admission: Equatable { case admitted(clientId: String); case unauthorized; case budgetExceeded }`
  - `func admit(bearerToken: String?) async -> Admission` — resolves the token to a client id (bare lookup, no network/MainActor work), then takes one unit from that client's bucket; `nil`/unresolvable token → `.unauthorized` without touching the bucket at all.
- Produced for: Task 5 (the self-report door) and Task 8's mailbox tool wiring both call `admit(bearerToken:)` **before** any MainActor hop or mailbox mutation; each gets its **own** `ProviderRequestGate` instance with its own capacity (Global Constraints — the door's budget is distinct from the mailbox's).

- [ ] **Step 1: Write the failing tests for unauthorized, admitted, and budget-exceeded**

```swift
@Test("a nil or unknown token is unauthorized and never touches the bucket")
func unknownTokenUnauthorized() async { /* admit(bearerToken: nil) == .unauthorized, admit("garbage") == .unauthorized */ }

@Test("a known token is admitted up to capacity, then budget-exceeded")
func capacityEnforced() async {
    // registry.issueToken(forClientId: "c"); gate = ProviderRequestGate(registry:, capacity: 2, refillInterval: .seconds(60))
    // admit(token) twice -> .admitted; third -> .budgetExceeded
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-filter.sh ProviderRequestGateTests`
Expected: fails to compile

- [ ] **Step 3: Implement `ProviderRequestGate`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh ProviderRequestGateTests`
Expected: PASS, test count ≥ 2

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderRequestGate.swift Tests/irisTests/MCPProvider/ProviderRequestGateTests.swift
git commit -m "feat: #1067 per-token admission gate (auth + rate/concurrency budget)"
```

---

## Task 4: Diagnostic event ring buffer and its instrumentation hooks

**Files:**
- Create: `Sources/IrisKit/MCPProvider/DiagnosticEventRing.swift`
- Create: `Tests/irisTests/MCPProvider/DiagnosticEventRingTests.swift`
- Modify: `Sources/IrisKit/TranscriptFocusAnchor.swift` (`AnchorView.mouseWentDown(at:)` and `.focusTable(clickedAt:)`)
- Modify: `Sources/IrisKit/ComposerTextView.swift` (the `acceptsFirstMouse` override added for #1055, and wherever `effectiveAppearance` is observable on the composer's `NSTextView`)

**Interfaces:**
- Produces: `final class DiagnosticEventRing: @unchecked Sendable` — **not an actor** (planner review on PR #1068: a ring that exists to pin the #1055 event *sequence* must not let its own recording mechanism reorder entries, and `Task { await actor.record(...) }` fired from synchronous AppKit callbacks gives no ordering guarantee between the two `Task`s it creates). Use a single `NSLock` guarding an in-memory array, the same shape `KeychainManager`'s own lock-guarded mutable state uses:
  - `static let capacity = 200` (named constant — Global Constraints; pick this value or another explicit one, but it must be named, not implicit).
  - `enum Event: Sendable { case transcriptMouseDown(atWindowPoint: CGPoint); case transcriptFocusHop(tookFocus: Bool); case composerAcceptsFirstMouse(Bool); case windowAppearanceChanged(name: String); case composerAppearanceChanged(name: String) }` — no free-text, no titles, no `stringValue` (Global Constraints).
  - `struct Entry: Sendable { let timestamp: Date; let event: Event }`
  - `func record(_ event: Event)` — **synchronous**, lock-guarded; appends, dropping the oldest entry once `capacity` is exceeded. Callable directly from a synchronous AppKit callback with no `Task {}` wrapper, so two calls made in physical event order are recorded in that same order.
  - `func snapshot() -> [Entry]` — synchronous, lock-guarded; returns entries oldest-first, read by Task 5's `.eventRing` query and registered as the `iris_event_ring` MCP tool in Task 8.
  - `static let shared = DiagnosticEventRing()` — one process-wide ring, written from multiple AppKit callbacks; injected nowhere else, so Task 4's own tests construct their own instance (`DiagnosticEventRing()`), never `.shared`.
- Consumes: nothing new; `TranscriptFocusAnchor.AnchorView.mouseWentDown(at:)`/`.focusTable(clickedAt:)` and `ComposerTextView`'s `acceptsFirstMouse` call `DiagnosticEventRing.shared.record(...)` directly and synchronously, before and after the existing `DispatchQueue.main.async` hop in `AnchorView.viewDidMoveToWindow`'s monitor closure (§3.7 Clomp note: record both pre- and post-hop, since first responder changes only after the hop) — the whole point of making this synchronous is that the pre-hop and post-hop calls land in the ring in the same relative order the physical events and the hop actually occurred in.

- [ ] **Step 1: Write the failing tests for bounded capacity and in-order recording**

```swift
@Test("the ring drops the oldest entry once it exceeds capacity")
func dropsOldestPastCapacity() {
    let ring = DiagnosticEventRing()
    for i in 0..<(DiagnosticEventRing.capacity + 10) {
        ring.record(.composerAcceptsFirstMouse(i.isMultiple(of: 2)))
    }
    let entries = ring.snapshot()
    #expect(entries.count == DiagnosticEventRing.capacity)
}

@Test("entries come back in the exact order they were recorded, synchronously")
func preservesRecordingOrder() {
    let ring = DiagnosticEventRing()
    ring.record(.transcriptMouseDown(atWindowPoint: .zero))
    ring.record(.transcriptFocusHop(tookFocus: true))
    ring.record(.composerAcceptsFirstMouse(true))
    let events = ring.snapshot().map(\.event)
    // assert the three cases appear in exactly this sequence — the property a Task-based
    // actor recorder cannot guarantee under concurrent AppKit callbacks.
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh DiagnosticEventRingTests`
Expected: fails to compile

- [ ] **Step 3: Implement `DiagnosticEventRing`**

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-filter.sh DiagnosticEventRingTests`
Expected: PASS

- [ ] **Step 5: Instrument `TranscriptFocusAnchor.AnchorView`**

In `mouseWentDown(at:)`, after setting `downInside`, call `DiagnosticEventRing.shared.record(.transcriptMouseDown(atWindowPoint: point))` directly (window-local point, not screen — no title, no content). In `focusTable(clickedAt:)`, after the existing `window.makeFirstResponder(table)` call (and also on each early `return` path where focus was *not* taken), record `.transcriptFocusHop(tookFocus:)` with the correct bool for that path. `DiagnosticEventRing.record` is synchronous and lock-guarded (Task 4's interface), so call it directly from these synchronous AppKit callbacks — no `Task {}` wrapper, no `await`. That is the whole fix for the ordering problem the planner flagged: a `Task` would race two unordered hops; a direct synchronous call records in exactly the order the callbacks fire.

- [ ] **Step 6: Instrument `ComposerTextView`'s `acceptsFirstMouse` override to record `.composerAcceptsFirstMouse(true)` on every call (it always returns `true` since #1055's fix; recording it anyway gives the ring a timestamped signal that a reactivating click reached the composer)**

- [ ] **Step 7: Add `NSView.effectiveAppearance` observation on the window and the composer's `NSTextView`**

Grep `Sources/IrisKit/ComposerTextView.swift` and `Sources/IrisKit/ChatView.swift` for any existing `viewDidChangeEffectiveAppearance` or KVO on `effectiveAppearance`; if none exists, override `viewDidChangeEffectiveAppearance()` on the composer's `NSTextView` subclass and record `.composerAppearanceChanged(name: effectiveAppearance.name.rawValue)`, and do the equivalent for the main window (its `contentView` or the window itself) recording `.windowAppearanceChanged`. `NSAppearance.Name` is a `String`-backed enum case name (e.g. `"NSAppearanceNameDarkAqua"`), not user content — safe to record verbatim.

- [ ] **Step 8: Run the full `DiagnosticEventRingTests` suite plus the existing `ComposerStashShortcutTests` to confirm nothing already covering these views regressed**

Dev-2 smaller item: no `TranscriptFocusAnchorTests` suite exists on `main` — only `ComposerStashShortcutTests` covers this area today. Do not invent a run of a suite that doesn't exist (`test-filter.sh` would report 0 tests and the gate's own rule — AGENTS.md, "matching nothing looks exactly like passing" — would make that look like a pass). If this task's instrumentation changes warrant a dedicated suite for `TranscriptFocusAnchor`, add it as part of this task's own test file instead of assuming one already exists.

Run: `scripts/test-filter.sh DiagnosticEventRingTests && scripts/test-filter.sh ComposerStashShortcutTests`
Expected: all PASS, each with a non-zero test count

- [ ] **Step 9: Commit**

```bash
git add Sources/IrisKit/MCPProvider/DiagnosticEventRing.swift Sources/IrisKit/TranscriptFocusAnchor.swift Sources/IrisKit/ComposerTextView.swift Tests/irisTests/MCPProvider/DiagnosticEventRingTests.swift
git commit -m "feat: #1067 bounded diagnostic event ring + #1055/#1052 instrumentation hooks"
```

---

## Task 5: The self-report door

**Files:**
- Create: `Sources/IrisKit/MCPProvider/SelfReportDoor.swift`
- Create: `Tests/irisTests/MCPProvider/SelfReportDoorTests.swift`
- Modify: `Sources/IrisKit/AppState.swift` (add the aggregate turn accessor — see Interfaces)
- Modify: `Sources/IrisKit/MCPProvider/DiagnosticEventRing.swift` (add `Encodable` to `Event`/`Entry` — Task 4 built them `Sendable` only; this task is the first consumer that needs them encoded, so it adds the conformance it needs)
- Modify: `Sources/IrisKit/ComposerTextView.swift` (add `ComposerFocus`, the named tracker `.composerState` actually reads from — see Interfaces; dev-2 round 3 smaller item 3: an earlier draft said this reader "requires the composer's `NSTextView` instance to be reachable" with no registry named, which two executors would build two different ways)

**Architecture note (dev-2 round 2, item 2):** `SelfReportDoor` does **not** call `ProviderRequestGate.admit` itself, and does not take a `bearerToken`. Admission happens exactly once, in Task 8's `handleAuthenticated`, before any `MCP.Server` — and therefore before this door — is ever touched; a door call that reaches `handle` at all has already been admitted. Giving the door its own second `admit` call (as an earlier draft of this plan did) either double-charges a client's budget for one logical request or silently drops one of the two checks, since nothing says which result wins. The door receives the already-resolved `clientId` as a plain argument instead.

**Interfaces:**
- Consumes: `DiagnosticEventRing.shared.snapshot()` (Task 4), `withTimeout(seconds:_:)` (`Sources/IrisKit/Timeout.swift`), `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (dev-2 Gap 6 — **not** `Bundle.main.bundleIdentifier`, which is trivially Iris's own id and answers nothing; the #1055 diagnosis needs the actually-frontmost app), a new `@MainActor func anyTurnInFlight() -> (any: Bool, count: Int)` added to `AppState` in this task (derived from `engineTurnCounts.values`, `rotationHold`, and `activeTasks` exactly as `hasTurnInFlight(for:)` does, cite that method by symbol rather than a line number that drifts between `~/src/iris` and `origin/main`, but aggregated across every conversation with **no conversation id anywhere in its return value** — Global Constraint 2 forbids a conversational read here, and a per-conversation `hasTurnInFlight(for:)` call would need one), the window hierarchy's own first-responder identity (see `.composerState` below), `NSApp.isActive`.
- Produces: `struct SelfReportDoor: Sendable` (a plain `nonisolated` struct — never `@MainActor` itself, per Global Constraints) with:
  - `static let mainActorTimeout: Duration = .milliseconds(500)` (named constant; `withTimeout(seconds:_:)` takes `Double` seconds, not `Duration` — dev-2 smaller item — so the implementation converts once at the call site, e.g. `withTimeout(seconds: Double(mainActorTimeout.components.seconds) + Double(mainActorTimeout.components.attoseconds) / 1e18)`, or simply hold the constant as `TimeInterval = 0.5` instead of `Duration` if that conversion reads as needless ceremony for a single call site — either is acceptable, but the plan's citation of `withTimeout(seconds:_:)` must match whichever is chosen).
  - `enum Query: String, Sendable, CaseIterable { case windowOwner, responderClass, composerState, turnState, activationState, eventRing }`
  - `struct ComposerState: Sendable, Codable { let isFirstResponder: Bool; let isEmpty: Bool }` — dev-2 round 2, item on `composerState`'s source: an earlier draft of this task invented an `(enabled, reason)` shape and a `turnInFlight` disabled-reason that do not exist — `ChatView.isSendDisabled` is just `isInputEmpty && draftAttachments.isEmpty` (it gates the send *button*, nothing about an in-flight turn disables the composer; steering mid-turn is allowed), and both `isSendDisabled` and `isInputEmpty`/`draftAttachments` are private `@State` on the `ChatView` SwiftUI view, unreachable from a non-UI query at all. What the #1055 diagnosis actually needs — "did the reactivating click's keystroke reach the composer or get swallowed" — is answered by `isFirstResponder` (is the composer's `NSTextView` the window's current `firstResponder`, the same identity check `TranscriptFocusAnchor`'s own focus-hop code already does against its own view) and `isEmpty` (`NSTextView.string.isEmpty` on that same view — a derived boolean, not the text itself, so it stays inside the Global Constraints' "no content" rule the same way `.responderClass` does). This requires the composer's `NSTextView` instance to be reachable from an injected `@MainActor` reader, the same pattern as `.windowOwner`'s reader below — concretely, `enum ComposerFocus { @MainActor static func track(_ textView: NSTextView?); @MainActor static var current: NSTextView? }` in `ComposerTextView.swift` (dev-2 round 3 smaller item 3: name one tracker rather than leave "reachable" unspecified), mirroring `MainWindow`'s own `track(_:)`/`current` shape (cite by symbol, not line number) with its own weak-reference holder. `KeyCatchingTextView` (the composer's actual `NSTextView` subclass) calls `ComposerFocus.track(self)` from an added `viewDidMoveToWindow()` override (`super.viewDidMoveToWindow()` first). `SelfReportDoor`'s injected `composerStateReader` closure reads `ComposerFocus.current` in production; tests inject their own closure and never touch `ComposerFocus` directly.
  - `struct Snapshot: Sendable, Encodable { let query: Query; let isAppActive: Bool; let isKeyWindow: Bool; let value: Value } ` where `Value` is whatever `enum`/struct shape each query needs (frontmost-app bundle id `String?` for `.windowOwner`, class name `String` for `.responderClass`, `ComposerState` for `.composerState`, `(any: Bool, count: Int)` for `.turnState`, `[DiagnosticEventRing.Entry]` for `.eventRing`) — pick a concrete `Codable` shape per query and hold to it; a `[String: Value]`-style untyped bag is not acceptable here (it is exactly the kind of structure the SDK's `Tool.Result.structuredContent: Value` needs you to produce, so define it once and reuse it for every query's JSON encoding). **`DiagnosticEventRing.Event`/`.Entry` are only `Sendable` today (Task 4's own interface), not `Encodable`** (dev-2 round 2 smaller item) — this task adds `Encodable` conformance to both (the `CGPoint` case needs an explicit `encode(to:)` or a `Codable`-friendly substitute shape, since `CGPoint` itself is not `Codable`) so `.eventRing`'s `Snapshot` actually compiles and encodes.
  - `func handle(query: Query, clientId: String) async -> Result<Snapshot, DoorError>` where `enum DoorError: Error { case mainActorUnresponsive(afterMilliseconds: Int) }` — no `.unauthorized`/`.budgetExceeded` case: those decisions are made and ruled out entirely before this function is ever called (see the architecture note above).
- The `.mainActorUnresponsive` case is the literal diagnosis the spec calls for (§3.7: "main actor unresponsive for N ms" *is* the diagnosis) — never silently time out into a different error.
- `MainWindow`/`AppState`/composer-reading closures injected into `SelfReportDoor` must themselves be `@MainActor` closures (dev-2 smaller item: `MainWindow`, `AppState.anyTurnInFlight()`, and the composer's `NSTextView` are all `@MainActor`-isolated; an injected plain `() -> T` closure called from a non-isolated context would not type-check against them), e.g. `init(windowOwnerReader: @escaping @MainActor () -> String?, composerStateReader: @escaping @MainActor () -> ComposerState, ...)`, with `withTimeout` wrapping the `await` hop to each one.

- [ ] **Step 1: Write the failing test that the MainActor hop actually happens (now that nothing upstream of `handle` gates it, this task's own test is about correctness of the race, not about auth) and the backgrounded-reporting test**

```swift
@Test("a slow MainActor reader produces .mainActorUnresponsive at the named timeout, not a hang or a different error")
func mainActorTimeoutProducesNamedDiagnosis() async {
    // Inject a windowOwnerReader (or any MainActor reader) that never returns within
    // mainActorTimeout (e.g. an injected delay beyond it, driven by a test clock rather than a
    // real sleep); assert handle(query: .windowOwner, clientId: "a") returns
    // .failure(.mainActorUnresponsive(afterMilliseconds: 500)), not a hang and not some other
    // error TimeoutError got mapped to by accident.
}

@Test("the activation state is reported even when Iris is not key") // Review Focus item 3
func reportsBackgroundedHonestly() async {
    // Inject a fake "is key" / "is active" reader returning false; assert the snapshot's
    // isAppActive/isKeyWindow fields reflect false rather than the call failing or lying.
}
```

Make `SelfReportDoor`'s MainActor-reading closures and the "is active/is key" reader injectable constructor parameters (mirroring `MainWindowTracking`'s own `appIsActive`/`activate` injection pattern — cite by symbol, not line number) so these tests never depend on a real `NSApp`/`NSWindow`. **Review Focus item 4's pre-hop-budget-rejection test now lives in Task 8**, not here (dev-2 round 2, item 2): since `handle` is only ever called after `handleAuthenticated` has already admitted the request, there is no "unauthorized call reaches the door" case left for this task to test — that guarantee is structural, and Task 8's own tests are where it is proven.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: fails to compile

- [ ] **Step 3: Implement `SelfReportDoor`, racing each MainActor read against `withTimeout` at `mainActorTimeout` and mapping `TimeoutError` to `.mainActorUnresponsive(afterMilliseconds: 500)`; implement `AppState.anyTurnInFlight()`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: PASS

- [ ] **Step 5: Write the failing test that `.windowOwner` never emits anything but a bundle id, `.responderClass` never emits `stringValue`-shaped content, and `.composerState` never emits the composer's actual text**

```swift
@Test("windowOwner reports only the frontmost app's bundle identifier, never a title")
func windowOwnerBoundsField() async {
    // Inject a fake window-owner reader whose underlying fake window has a title set to
    // something identifiable (e.g. "SECRET CONVERSATION TITLE"); assert the Snapshot's
    // encoded JSON does not contain that string anywhere.
}

@Test("composerState reports isEmpty as a bool, never the composer's actual text")
func composerStateBoundsField() async {
    // Inject a fake composerStateReader backed by an NSTextView whose string is set to
    // "SECRET DRAFT TEXT"; assert the Snapshot's encoded JSON contains neither that string nor
    // any substring of it — only isFirstResponder/isEmpty booleans.
}
```

- [ ] **Step 6: Run both, verify they fail if the implementation reads title or composer text anywhere, fix, verify they pass**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: PASS, test count ≥ 4

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/SelfReportDoor.swift Sources/IrisKit/AppState.swift Sources/IrisKit/MCPProvider/DiagnosticEventRing.swift Tests/irisTests/MCPProvider/SelfReportDoorTests.swift
git commit -m "feat: #1067 self-report door — bounded, non-MainActor-entry diagnostic reads"
```

---

## Task 6: Provider mailbox (send/poll/discover/status)

**Files:**
- Create: `Sources/IrisKit/MCPProvider/ProviderMailbox.swift`
- Create: `Tests/irisTests/MCPProvider/ProviderMailboxTests.swift`

**Interfaces:**
- Consumes: `ProviderTokenRegistry.allClientIds()`, `.isRegistered(clientId:)` (Task 1). **Not** `ProviderRequestGate.admit` — admission happens exactly once, in Task 8's `handleAuthenticated`, before this actor is ever touched (dev-2 round 2, item 2); an earlier draft of this task's Interfaces line listed `admit` as a dependency, which was stale once that architecture landed.
- Produces: `actor ProviderMailbox` with:
  - `enum MailboxParty: Sendable, Hashable, Codable { case client(String); case iris }` — **impossible-by-construction, not reserve-and-reject** (dev-3's rule-26 read on PR #1068, finding 1; planner's fold-rule: lean typed-and-distinct over a guard where the cost is acceptable): `.client("iris")` and `.iris` are different enum cases, so even if a client somehow held a token issued under the literal string `"iris"`, every message it sends is stored `from: .client("iris")`, which can never equal `to: .iris` or be matched by a `poll(for: "iris")` call that filters on `.client("iris")` specifically — there is no comparison in this type that conflates "the client who happens to be named iris" with "Iris itself." (`ProviderTokenRegistry.reservedClientId`, Task 1, still rejects issuing that literal at registration — not because this type needs it, but because `ProviderArtifactStore`'s ACL in Task 7 is a plain `Set<String>` with no equivalent type separation, and that surface does need the reservation.)
  - `static let maxPendingPerClient = 500`, `static let maxTextBytes = 16 * 1024`, `static let maxFileRefsPerMessage = 8`, `static let ttl: TimeInterval = 7 * 24 * 60 * 60` (dev-2 Gap 7 — named caps, matching the no-"bounded"-left-unspecified rule the ring already follows; `ttl` matches Task 7's own object TTL so an undelivered message and the files it references expire together).
  - `struct Message: Sendable, Codable { let id: UUID; let sequence: UInt64; let from: MailboxParty; let to: MailboxParty; let text: String; let fileRefs: [String]; let sentAt: Date }` (`fileRefs` are SHA-256 hex strings into Task 7's store; `from` is always the *resolved* party — `.client(<token-resolved id>)` or `.iris` — never a client-asserted field — provenance per Global Constraints; `sequence` is a mailbox-wide monotonically increasing counter, assigned at send time).
  - `func send(from clientId: String, text: String, fileRefs: [String]) throws -> Message` — **no `to` parameter: every call stores `from: .client(clientId), to: .iris`**, since a client can only ever send to Iris. First re-checks `registry.isRegistered(clientId)`, throwing `.senderNoLongerRegistered` if not (dev-2 round 3 smaller item 2: a request already admitted before a concurrent `revoke(clientId:)` holds it in its closure for up to `requestDeadline` and could otherwise still write a message under a just-revoked id, which a later re-issue of that same id would then inherit — this cheap in-memory check at the actual mutation closes that window, independent of whatever check happened earlier in the request's lifecycle); then throws `.textTooLarge` if `text` exceeds `maxTextBytes`, `.tooManyFileRefs` if `fileRefs.count` exceeds `maxFileRefsPerMessage`, **`.inboxFull` if `clientId`'s own count of pending `.client(clientId) → .iris` messages is already at `maxPendingPerClient`** (dev-3's rule-26 read, finding 2, folded: the cap is **per sender**, not a shared count across the one physical Iris inbox — an earlier draft of this task capped Iris's inbox as a whole, so one client's 500 sends would lock out every other client from sending at all, and that lock-out would be externally observable; counting only that sender's own unconsumed messages means client "a" filling its cap never affects client "b"'s `send`), **`.malformedFileRef` if any entry in `fileRefs` is not 64 lowercase hex digits** (dev-2 round 2 smaller item: `ProviderArtifactStore` already validates this shape on its own calls, but the final whole-branch reviewer's item 11 only checked the store — this mailbox is a second place a caller-controlled string could reach a filesystem-facing API later, via Task 8's `authorize` call on each ref, so it validates its own input too rather than trusting the store to catch it downstream). There is no `unknownRecipient` case for `send` any more — there is nothing left for it to be unknown about.
  - `func poll(for clientId: String, sinceSequence: UInt64?) -> [Message]` — every message with `to == .client(clientId)` (i.e. Iris's replies to this specific client) with `sequence > sinceSequence` (or all, if `sinceSequence` is nil), oldest first; **does not delete** on poll (so a second poll after a dropped connection still sees them) — delivery is pull, per #1067's "pull mailbox for replies." **A monotonic sequence cursor, not `since: Date`** (dev-2 Gap 7): two messages can share a timestamp at millisecond resolution, and a `Date`-keyed cursor would then drop or duplicate one of them; `sequence` has no ties. **Phase 1 note:** since nothing wires `deliverReply` below to any MCP tool, `poll` always returns empty in this phase's shipped build — the primitive and its tests exist, the reply-composition path does not yet (dev-3's rule-26 read, question 3).
  - `func deliverReply(to clientId: String, text: String, fileRefs: [String]) throws -> Message` — the Iris-side half of the mailbox: stores a message `from: .iris, to: .client(clientId)`, checked against that recipient's own caps (`.unknownRecipient` if `clientId` is not a registered client — this is the only place that case still applies; `.textTooLarge`/`.tooManyFileRefs`/`.malformedFileRef`/`.inboxFull` against `clientId`'s own pending-from-Iris count, the same per-recipient accounting `send`'s cap uses, just the other direction). **Out of scope for Task 8's wiring, the same onboarding-style gap as Task 1's `issueToken`:** nothing in this plan calls `deliverReply` from a UI or operator affordance — Phase 1 ships the primitive and this task's own tests for it, not a way for a human at Iris to compose a reply. Task 8 does **not** expose `deliverReply` as an MCP tool: an MCP client has no business writing "from Iris" messages into another client's inbox, and exposing it would reopen exactly the client-to-client relay Brian struck, through the back door of one client posing as Iris. (See Task 8's new source-scan test, Step 11, which pins this as an enforced fact, not just prose.)
  - `func discover() -> ProviderIdentity` where `struct ProviderIdentity: Sendable, Codable { let peerId: String; let version: String }` — always describes **Iris itself** (`peerId: "iris"`, the running app's version string — `ProviderIdentity` is a wire-facing struct, so it carries a plain `String` for JSON, backed internally by `MailboxParty.iris`), never `registry.allClientIds()` (an enumerable roster of other registered clients is itself a client-to-client discovery primitive, struck along with direct `send` — Brian's veto reaches "can one client even learn another exists through Iris," not only "can it message it directly"). This replaces the earlier `[String]`-of-all-clients return.
  - `func status(for clientId: String) -> (pendingCount: Int, lastMessageAt: Date?)` — the pending count and most recent timestamp of **Iris's replies to `clientId`** (equivalently, what `poll(for: clientId)` would return right now) — a client's own view of its one relationship with Iris, never a cross-client roster. **Phase 1 note:** always `(0, nil)` in this phase's shipped build, for the same reason `poll` is always empty (dev-3's rule-26 read, question 3).
  - `func retract(id: UUID)` — deletes one pending message by id, regardless of direction. **Used only by Task 8's `iris_send` wiring** when `ProviderArtifactStore.authorizeAll` throws after `send` already stored the message (dev-2 round 3 smaller item 1 — closes the residual race between a successful `send` and the grant it depends on: if the grant fails, the message it describes must not remain delivered with an unreadable ref, so Task 8 retracts it rather than leaving it half-finished).
  - `func sweepExpired(now: Date = Date())` — deletes every message older than `ttl` in either direction, called from Task 8's lifecycle wiring on the same timer as Task 7's `sweepExpired`.
  - `func purge(clientId: String)` — deletes every pending message to or from `.client(clientId)` (both directions: that client's own unread sends-to-Iris and Iris's unread replies to it). Dev-2 smaller item: revoking a `clientId` and later re-issuing it to a *different* person must not hand them the old occupant's undelivered mailbox; Task 1/Task 8's revoke path calls this.
- Produced for: Task 8 wires `send`/`poll`/`discover`/`status` as MCP tools — none of them take or expose another client's id — and calls `sweepExpired`/`purge` from its lifecycle wiring. `deliverReply` is exercised only by this task's own tests; Task 8 does not wire it to any MCP tool in Phase 1.

- [ ] **Step 1: Write the failing tests for send-always-addresses-Iris, poll ordering of Iris's replies, deliverReply's unknown-recipient case, discover/status, and the caps**

```swift
@Test("send always addresses Iris; there is no recipient argument to get wrong")
func sendAlwaysAddressesIris() async throws {
    let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
    let message = try await mailbox.send(from: "a", text: "hello", fileRefs: [])
    #expect(message.to == .iris)
    #expect(message.from == .client("a"))
}

@Test("a client registered under the literal \"iris\" is still just a client — its messages are .client(\"iris\"), never .iris")
func clientNamedIrisCannotBecomeIrisByConstruction() async throws {
    // registryWithClients normally goes through ProviderTokenRegistry.issueToken, which Task 1
    // now rejects for this literal — this test exercises ProviderMailbox in isolation, bypassing
    // that registration guard, to prove the mailbox's own type structurally cannot be fooled even
    // if some other path ever let the literal through. Build a registry stub whose
    // isRegistered/allClientIds say "yes" for the literal "iris" (not ProviderTokenRegistry
    // itself — this is the mailbox's defense-in-depth, independent of Task 1's guard).
    let mailbox = ProviderMailbox(registry: registryWithClients(["iris", "b"]))
    let fromImpersonator = try await mailbox.send(from: "iris", text: "pretending", fileRefs: [])
    #expect(fromImpersonator.from == .client("iris"))  // never == .iris
    _ = try await mailbox.deliverReply(to: "b", text: "a real reply from Iris", fileRefs: [])
    let impersonatorsPoll = await mailbox.poll(for: "iris", sinceSequence: nil)
    #expect(impersonatorsPoll.isEmpty)  // the client calling itself "iris" does not see "b"'s reply
}

@Test("poll returns Iris's replies to the caller, oldest first, without deleting them, keyed by sequence not timestamp")
func pollIsNonDestructivePull() async throws {
    let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
    _ = try await mailbox.deliverReply(to: "a", text: "first", fileRefs: [])
    _ = try await mailbox.deliverReply(to: "a", text: "second", fileRefs: [])
    let firstPoll = await mailbox.poll(for: "a", sinceSequence: nil)
    #expect(firstPoll.map(\.text) == ["first", "second"])
    let secondPoll = await mailbox.poll(for: "a", sinceSequence: nil)
    #expect(secondPoll.count == 2)  // not deleted
    let onlySecond = await mailbox.poll(for: "a", sinceSequence: firstPoll[0].sequence)
    #expect(onlySecond.map(\.text) == ["second"])
}

@Test("deliverReply to an unregistered client id throws unknownRecipient")
func deliverReplyToUnknownClientRejected() async { /* ... */ }

@Test("discover always reports Iris's own peer identity, never a roster of other clients")
func discoverReportsIrisOnly() async throws {
    let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b", "c"]))
    let identity = await mailbox.discover()
    #expect(identity.peerId == "iris")
    // no API on this type returns "a", "b", "c" as a roster
}

@Test("text over the cap, too many fileRefs, a full inbox, and a malformed fileRef are each rejected before storing, for both send and deliverReply")
func capsEnforced() async throws {
    // send: text over maxTextBytes -> .textTooLarge; fileRefs one longer than maxFileRefsPerMessage
    // -> .tooManyFileRefs; maxPendingPerClient sends from "a" then one more -> .inboxFull (a's own
    // unconsumed count, per dev-3's per-sender fold below); fileRefs: ["not-a-hash"] -> .malformedFileRef.
    // deliverReply: the same four checks, enforced against the recipient client's own pending count.
}

@Test("the inbox-full cap is per sender, not a single shared Iris inbox — one client filling its cap never blocks another's send") // dev-3's rule-26 read, finding 2
func inboxFullCapIsPerSender() async throws {
    let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b"]))
    for _ in 0..<ProviderMailbox.maxPendingPerClient {
        _ = try await mailbox.send(from: "a", text: "x", fileRefs: [])
    }
    await #expect(throws: ProviderMailbox.MailboxError.inboxFull) {
        try await mailbox.send(from: "a", text: "one too many", fileRefs: [])
    }
    // "a" is at its cap; "b", who has sent nothing yet, must still be able to send.
    let fromB = try await mailbox.send(from: "b", text: "still fine", fileRefs: [])
    #expect(fromB.from == .client("b"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-filter.sh ProviderMailboxTests`
Expected: fails to compile

- [ ] **Step 3: Implement `ProviderMailbox`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh ProviderMailboxTests`
Expected: PASS

- [ ] **Step 5: Write the failing test that `from` is always the token-resolved id, never a caller-supplied override, and the failing test for `sweepExpired`/`purge`**

```swift
@Test("the mailbox's public send signature has no way to assert a different sender than the resolved client id, and no way to name a recipient other than Iris")
func fromIsNotASeparateCallerControlledField() async throws {
    // This is a regression guard on ProviderMailbox's own shape, not the full enforcing test —
    // the end-to-end proof that a tool call's "from" argument is ignored belongs to Task 8, which
    // drives this through the actual MCP tool wiring (dev-2 Gap 5: this task's version "should
    // already pass" by construction and does not, on its own, prove the wiring is safe). Call
    // send(from: resolvedId, ...) and confirm the stored Message's `from` equals exactly
    // .client(resolvedId) and `.to` is always `.iris`; there is no second parameter or arguments
    // bag this signature could pull an overriding "from" or a "to" out of.
}

@Test("sweepExpired removes only messages past the TTL in either direction; purge removes everything for one client id")
func sweepAndPurge() async throws { /* backdate via an injectable now:, as Task 7's store does */ }

@Test("a sender revoked after admission but before send cannot create a new message under its old id")
func senderNoLongerRegisteredRejected() async throws {
    let registry = registryWithClients(["a"])
    let mailbox = ProviderMailbox(registry: registry)
    try registry.revokeToken(forClientId: "a")  // simulates revoke landing mid-request
    await #expect(throws: ProviderMailbox.MailboxError.senderNoLongerRegistered) {
        try await mailbox.send(from: "a", text: "late", fileRefs: [])
    }
}

@Test("retract removes a specific pending message regardless of direction")
func retractRemovesOneMessage() async throws {
    let mailbox = ProviderMailbox(registry: registryWithClients(["a"]))
    let message = try await mailbox.deliverReply(to: "a", text: "oops", fileRefs: [])
    await mailbox.retract(id: message.id)
    #expect(await mailbox.poll(for: "a", sinceSequence: nil).isEmpty)
}
```

- [ ] **Step 6: Run all tests, this task's `from`/`to` test should already pass by construction (fix if it doesn't — that means something let a second identity or an arbitrary recipient in); implement and verify `sweepExpired`/`purge`/the registration recheck/`retract`/`discover`/`deliverReply`/the per-sender `.inboxFull` accounting all pass**

Run: `scripts/test-filter.sh ProviderMailboxTests`
Expected: PASS, test count ≥ 12

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderMailbox.swift Tests/irisTests/MCPProvider/ProviderMailboxTests.swift
git commit -m "feat: #1067 provider mailbox — send/poll/discover/status, token-provenanced, capped"
```

---

## Task 7: Guest/client file exchange (content-addressed store + TTL sweep)

**Files:**
- Create: `Sources/IrisKit/MCPProvider/ProviderArtifactStore.swift`
- Create: `Tests/irisTests/MCPProvider/ProviderArtifactStoreTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 by type — see `isRegistered` below.
- Produces: `actor ProviderArtifactStore` with:
  - `init(root: URL, isRegistered: @escaping @Sendable (String) -> Bool = { _ in true }, now: @escaping @Sendable () -> Date = Date.init)` — `isRegistered` is a closure, not a direct dependency on `ProviderTokenRegistry` (dev-2 round 3 smaller item 2's fix only needs a yes/no check, and a closure keeps every existing test in this task working unchanged with the default `{ _ in true }`; Task 8 wires the real `init: { tokenRegistry.isRegistered(clientId: $0) }`).
  - `static let maxBytesPerObject = 8 * 1024 * 1024` (8 MiB for Phase 1, **not** romar's 64 MiB conformance baseline — dev-2 Gap 7: a 64 MiB inline-base64 `artifact_put` body is ~86 MB resident per request once base64-decoded and wrapped in the SDK's `Value`, with no per-request concurrency cap in front of it yet; romar's 64 MiB figure was sized for a different transport) as a named constant.
  - `static let ttl: TimeInterval = 7 * 24 * 60 * 60` (7 days, matching romar's object TTL, §3.6) as a named constant.
  - `static let perClientDailyBytes = 200 * 1024 * 1024`, `static let totalStoreCapBytes = 2048 * 1024 * 1024` (dev-2 Gap 7 — mirroring `ArtifactLimits.sessionDailyBytes`/`.defaultExchangeCapMB` (cite by symbol — `Sources/IrisKit/Artifacts.swift` line numbers drift between `~/src/iris` and `origin/main`), 200 MiB/day per client and a 2 GiB total ceiling for the whole store, so a registered client cannot fill the disk; `put` rejects with `.quotaExceeded` once either is hit, computed from this store's own bookkeeping — never `ArtifactStore`'s).
  - `func put(bytes: Data, from clientId: String) throws -> String` — **first checks `isRegistered(clientId)`**, throwing `.uploaderNoLongerRegistered` if false (dev-2 round 3 smaller item 2: the same revoke-landed-mid-request race Task 6's `send` closes — a request admitted before a concurrent `revoke(clientId:)` otherwise still writes a new object under the just-revoked id, which a later re-issue of that id would then inherit); then rejects (`ArtifactError.tooLarge`) over `maxBytesPerObject`, rejects (`.quotaExceeded`) if it would put `clientId` over `perClientDailyBytes` for the current day or the store over `totalStoreCapBytes`; computes `SHA256.hash(data:)` (CryptoKit) hex string as the key, writes `bytes` under a directory scoped to this store (not the conversation `ArtifactStore`'s directory — Global Constraints), records `(sha256, storedAt, sizeBytes)`, **and initializes that object's authorized-reader set to `{clientId}`** — the uploader can always read back what it uploaded — returns the hex sha256.
  - `func authorize(sha256: String, by senderId: String, adding clientIds: Set<String>) throws` — **validates `sha256` is 64 lowercase hex digits first** (dev-2 Gap 4 — reject anything else as `.invalidHash` before it ever reaches a file path), then throws `.notFound` if the object doesn't exist, **throws `.unauthorized` unless `senderId` is already in that object's authorized-reader set** (dev-2 Gap 4, closing the hole in the planner's own PR #1068 fix: `authorize(sha256:adding:)` with no sender check let any client who merely *learned* a hash grant a third party a read, which is exactly the §7.6 B violation this ACL was built to close), otherwise unions `clientIds` into that object's authorized-reader set. Populated by Task 8's `iris_send` wiring (not by this task) at the point a message carrying `fileRefs` is actually sent, passing the **resolved sender's** client id as `senderId` — never a caller-supplied one.
  - `func authorizeAll(sha256s: [String], by senderId: String, adding clientId: String) throws` — **the atomic, all-or-nothing version `iris_send` actually calls** (dev-2 round 3 smaller item 1): one actor hop that validates and authorizes every hash in `sha256s` for `senderId`/`clientId` together, throwing (with **no partial grant left behind**) on the first one that fails `authorize`'s own checks. This closes a residual race in a *sequence* of separate `authorize` calls — `sweepExpired`/`purge(clientId:)` running on this same actor between two individually-awaited calls in Task 8's handler could expire or revoke one ref mid-loop, leaving some refs granted and others not even though the preflight (Task 8 step 4) checked all of them moments earlier. A single actor call has no such gap: nothing else runs on this actor between the first hash's check and the last's. `authorize(sha256:by:adding:)` above may be implemented as a one-hash call to this method, or kept separate — either is fine as long as `iris_send`'s wiring (Task 8) uses the plural, atomic form.
  - `func get(sha256: String, requestingClientId: String) throws -> Data` — validates `sha256` the same way as `authorize`; throws `.notFound` if the object doesn't exist, **`.unauthorized` if `requestingClientId` is not in that object's authorized-reader set** — knowing the hash is no longer sufficient on its own.
  - `func sweepExpired(now: Date = Date())` — deletes every stored object whose `storedAt` is older than `ttl`, and removes its bookkeeping record (including its authorized-reader set and its contribution to the per-client daily bytes bookkeeping). Called on a timer from Task 8's lifecycle wiring, not from `ArtifactStore.sweep` (Global Constraints — this store's sweep is independent).
  - `func purge(clientId: String)` — removes `clientId` from every object's authorized-reader set and clears its quota bookkeeping (dev-2 round 2, item 4: Task 1's `revokeToken` documentation said revoking purges "mailbox/file-ACL state", but an earlier draft of this task left the store's reader sets untouched, so a re-issued `clientId` could read every object previously granted to its old holder for up to the remaining TTL — exactly the inheritance Task 1 says revocation prevents. This method is the store's half of closing that; `IrisMCPProviderServer.revoke(clientId:)` in Task 8 is the one place that calls both this and `ProviderMailbox.purge`.) Does **not** remove objects `clientId` itself uploaded — those stay until `sweepExpired` reclaims them on the normal TTL, since another authorized reader may still hold a valid grant to them.

- [ ] **Step 1: Write the failing tests for put/get round-trip, SHA verification, and the authorized-reader ACL — including the directed version (Gap 4). `ProviderArtifactStore` is an `actor` (dev-2 round 2, item 5): every test that calls it is `async`, and every call is `await`ed, including `throws`-only methods — an actor-isolated method is awaited from outside regardless of whether it is itself marked `async`.**

```swift
@Test("the uploader can always read its own object; an unauthorized client cannot, even knowing the hash")
func putGetACLEnforced() async throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    let sha = try await store.put(bytes: Data("hello".utf8), from: "a")
    #expect(try await store.get(sha256: sha, requestingClientId: "a") == Data("hello".utf8))
    await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
        try await store.get(sha256: sha, requestingClientId: "b")  // knows the hash, was never authorized
    }
    try await store.authorize(sha256: sha, by: "a", adding: ["b"])
    #expect(try await store.get(sha256: sha, requestingClientId: "b") == Data("hello".utf8))  // now readable
    await #expect(throws: ProviderArtifactStore.ArtifactError.notFound) {
        try await store.get(sha256: String(repeating: "0", count: 64), requestingClientId: "a")
    }
}

@Test("a client who only learned the hash cannot grant anyone else a read (Gap 4)")
func authorizeRequiresSenderAlreadyAuthorized() async throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    let sha = try await store.put(bytes: Data("hello".utf8), from: "a")  // "a" holds it; "c" and "b" do not
    await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
        try await store.authorize(sha256: sha, by: "c", adding: ["b"])  // "c" was never authorized itself
    }
    await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
        try await store.get(sha256: sha, requestingClientId: "b")  // "c"'s attempted grant must not have landed
    }
}

@Test("a malformed sha256 is rejected before touching the filesystem")
func malformedHashRejected() async throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    await #expect(throws: ProviderArtifactStore.ArtifactError.invalidHash) {
        try await store.get(sha256: "../../etc/passwd", requestingClientId: "a")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-filter.sh ProviderArtifactStoreTests`
Expected: fails to compile

- [ ] **Step 3: Implement `ProviderArtifactStore`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh ProviderArtifactStoreTests`
Expected: PASS

- [ ] **Step 5: Write the failing test for the oversize rejection, the per-client/total quota, the TTL sweep, and `purge`**

```swift
@Test("an object over the size cap is rejected before any write")
func oversizeRejected() async throws { /* put bytes of size maxBytesPerObject + 1 -> throws .tooLarge, file not created */ }

@Test("a client's own daily quota and the store's total cap are each enforced")
func quotasEnforced() async throws {
    // Drive one client past perClientDailyBytes across several put() calls -> .quotaExceeded,
    // while a second client's own put still succeeds (quota is per-client). Separately, drive
    // several clients' puts past totalStoreCapBytes in aggregate -> .quotaExceeded for whichever
    // call crosses it, regardless of which client makes it.
}

@Test("sweepExpired reclaims an object past its TTL and leaves a fresh one alone")
func sweepReclaimsOnlyExpired() async throws {
    // Write one object, backdate its stored record past `ttl` via an injectable clock/now
    // parameter (constructor-inject a `now: @Sendable () -> Date` the same way other stores in
    // this codebase inject time — grep for an existing pattern before adding a new one), write a
    // second fresh object, sweep, assert only the expired one is gone.
}

@Test("purge removes a client's authorized-reader grants but not objects it uploaded itself")
func purgeRemovesGrantsOnly() async throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    let sha = try await store.put(bytes: Data("hello".utf8), from: "a")
    try await store.authorize(sha256: sha, by: "a", adding: ["b"])
    await store.purge(clientId: "b")
    await #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
        try await store.get(sha256: sha, requestingClientId: "b")  // "b"'s grant is gone
    }
    #expect(try await store.get(sha256: sha, requestingClientId: "a") == Data("hello".utf8))  // "a" still holds it
}

@Test("a client no longer registered cannot put a new object under its old id")
func uploaderMustBeRegistered() async throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory(), isRegistered: { $0 != "a" })
    await #expect(throws: ProviderArtifactStore.ArtifactError.uploaderNoLongerRegistered) {
        try await store.put(bytes: Data("late".utf8), from: "a")
    }
}
```

- [ ] **Step 6: Run them, verify they fail, implement `authorizeAll` and the `isRegistered` check, verify they pass**

Run: `scripts/test-filter.sh ProviderArtifactStoreTests`
Expected: PASS, test count ≥ 9

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderArtifactStore.swift Tests/irisTests/MCPProvider/ProviderArtifactStoreTests.swift
git commit -m "feat: #1067 provider-scoped content-addressed artifact store, directed ACL, quotas, TTL sweep, purge"
```

---

## Task 8: MCP server wiring and app lifecycle

**Files:**
- Create: `Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift`
- Create: `Tests/irisTests/MCPProvider/IrisMCPProviderServerTests.swift`
- Modify: `Sources/IrisKit/IrisApp.swift` (or wherever the app's startup sequence already lives — grep for where `StatusItem`/`LaunchGate` wire up at launch, and add the provider's start/stop beside them, gated on `ConfigManager.shared.mcpProviderEnabled`)

**Architecture, revised per dev-2's review of PR #1068 (blockers 1 & 2 — see "SDK spike findings" above):** this task does **not** build one long-lived `MCP.Server`. It builds a **per-request** `MCP.Server` + `StatelessHTTPServerTransport` pair, constructed fresh inside the listener's `handle` closure after that request's bearer token has already been resolved to a client id. Auth is checked on the raw `HTTPRequest`, before any SDK type exists, so `initialize`/`tools/list`/`ping` get no free pass (dev-2 Gap 3) and there is no shared `httpRequestContexts`/`responseWaiters` keyspace left for two clients' JSON-RPC ids to collide in (blocker 2 is structurally impossible here, not merely mitigated).

**Interfaces:**
- Consumes: Tasks 1–7 in full: `ProviderTokenRegistry` (including `.isRegistered(clientId:)`, `.revokeToken(forClientId:)`), `LoopbackHTTPListener` (including `.headerCompletionDeadline`/`.maxConcurrentConnections`), `ProviderRequestGate` (two instances — door and mailbox), `SelfReportDoor` (its `handle(query:clientId:)` — a resolved `clientId`, not a bearer token), `DiagnosticEventRing.shared`, `ProviderMailbox` (including `.retract(id:)`, `.purge(clientId:)`), `ProviderArtifactStore` (including `.authorizeAll(sha256s:by:adding:)`, `.purge(clientId:)`). Also `MCP.Server` (`init(name:version:capabilities:configuration:)` — **`capabilities:` must be passed explicitly** (dev-2/planner round 3, item A; see step 4); use `configuration: .default`, i.e. `strict: false`, confirmed in the spike above to accept a bare `tools/call` on a never-initialized `Server`; `withMethodHandler(ListTools.self) { ... }`, `withMethodHandler(CallTool.self) { ... }`, `withMethodHandler(ListResources.self) { ... }`, `withMethodHandler(ReadResource.self) { ... }`, `start(transport:)`) and `MCP.StatelessHTTPServerTransport.handleRequest(_:)` (Task 2's already-confirmed citation).
- Produces: `final class IrisMCPProviderServer: Sendable` with:
  - `init(tokenRegistry: ProviderTokenRegistry, mailbox: ProviderMailbox, artifactStore: ProviderArtifactStore, door: SelfReportDoor, doorGate: ProviderRequestGate, mailboxGate: ProviderRequestGate, port: UInt16, requestDeadline: Duration = .seconds(10))` — takes already-constructed dependencies; the caller assembling them (this task's own app-lifecycle wiring, step 14) constructs `mailbox`/`artifactStore` with `registry: tokenRegistry`/`isRegistered: { tokenRegistry.isRegistered(clientId: $0) }` respectively, so the revoke-race recheck (dev-2 round 3 smaller item 2) is wired to the same registry this server authenticates against.
  - `func start() async throws` — builds a `LoopbackHTTPListener(port: port, handle: handleAuthenticated)` where `handleAuthenticated` is this class's own method, **not** a bare `transport.handleRequest` reference (that was the pre-spike shape; it no longer applies):
    1. **Resolve, don't admit, first.** Read the `Authorization` header off the raw `HTTPRequest` directly (`request.header("Authorization")`); strip a `Bearer ` prefix if present. Call `tokenRegistry.clientId(forToken:)` (Task 1's existing, **non-consuming** lookup — no budget is spent here) to get a 401 decision for free: a missing header or an unknown token rejects outright, with **no JSON-RPC body parsed at all yet** (dev-2 round 2, item 2: parsing an untrusted body of up to `LoopbackHTTPListener.maxContentLength` — 16 MiB — before the token check would let an unauthenticated connection spend CPU on a big body for free). This step produces a resolved `clientId: String` or an immediate 401; it never touches either `ProviderRequestGate`.
    2. **Reject a batch body outright.** If the parsed JSON-RPC body is a top-level array (a JSON-RPC batch), return 400 and go no further (dev-2 round 2, item 2: this listener's minimal parser has no batch support, and "peek the body for one method name" silently breaks — or silently admits N calls for the price of one — against a batch; make the restriction explicit rather than accidental).
    **Parse the body exactly once, with the same parser the SDK's own transport uses for its own classification** (dev-3 round 4, finding 2 — `MCP`'s `JSONRPCMessageKind(data:)`, the SDK's own request/notification/response classifier, uses `JSONSerialization.jsonObject(with:)`, not `JSONDecoder` — confirmed by reading `HTTPServerTypes.swift`). This step's `method`/tool-name peek must decode the body with `JSONSerialization` too, not a second, independently-written parser, and the `LoopbackHTTPListener` parser from Task 2 is HTTP-only — it never parses JSON-RPC content, only the request line/headers/body-length framing around it (state this explicitly; it is easy to misread Task 2's "parser" as covering this too). **Reject a body whose top-level JSON object, *or* whose nested `params` object, contains a duplicate key** (e.g. two `"method"` entries at the top level, or two `"name"` entries inside `params` — dev-3 round 5, finding a: the charged tool name is `params.name`, not a top-level field, so a scan that stops at the top level lets a duplicate key inside `params` straight through) rather than relying on whichever of `JSONSerialization`/`JSONDecoder` happens to pick the same one first — dev-3 round 4 tested the two against each other on a top-level duplicate-key body and found they agree today (both first-wins), but that agreement is an implementation detail of two libraries this plan does not control, not a guarantee, and the point of rejecting outright is that the method/tool name *this gate* charges against a budget can never differ from what the SDK's `Server` later actually dispatches. Fail closed on this the same way `StrictJSON.rejectDuplicateKeys(_:)` does elsewhere in this codebase (`Sources/IrisKit/A2A/Crypto/PeerSignatureVerifier.swift`, #974 H4 — a raw-bytes scan over the JSON text, since `JSONSerialization` has already silently collapsed the duplicate by the time a decoded dictionary exists to inspect): if that type has landed on `main` by the time this task is built, call it directly; if not yet merged, vendor a small duplicate-key scanner scoped to this task — covering both the top-level object and every object nested under `params`, not just the outermost one — with the same fail-closed posture, rather than block Phase 1 on unrelated unmerged work or skip the check.
    3. **Dispatch by method against an explicit, default-deny allowlist — not an open-ended "`tools/call` is charged, everything else just proceeds" rule** (dev-2 round 3, item B: the round-2 text only named `initialize`/`tools/list`/`ping` as free and `tools/call` as charged, which left `resources/read` — a distinct JSON-RPC method, not a `tools/call` — uncharged and undefined, along with `notifications/initialized`, `resources/list`, `prompts/*`, `logging/setLevel`, `completion/complete`, and anything else the SDK or a client might send). The allowlist, exhaustively:
       - **Free (resolved `clientId` required, no gate charge):** `initialize`, `notifications/initialized`, `tools/list`, `ping`, **`resources/list`, `resources/templates/list`** (dev-3 round 4, finding 1: this plan's `serverCapabilities` advertises a `resources` capability, and a spec-following client may call these on connect; artifacts are reached only by URI, never enumerated — §3.6/§7.6 — so these two return an empty list rather than refusing a call the server's own advertised capability invited).
       - **Charged to `doorGate`, one `admit(bearerToken:)` call:** a `tools/call` naming one of the 6 door tools.
       - **Charged to `mailboxGate`, one `admit(bearerToken:)` call:** a `tools/call` naming one of the 4 mailbox tools or `artifact_put`, **and `resources/read`** (not a `tools/call` at all, but still a chargeable read against this surface — charged the same as the mailbox/file tools since it reads from the same `ProviderArtifactStore`).
       - **Any other `notifications/*` method** (e.g. `notifications/cancelled`, `notifications/roots/list_changed`) **is accepted with 202 and dropped — not refused** (dev-3 round 4, finding 3: a notification carries no id, so nothing is waiting on a response, but a 400 may still surface as a transport-level error to a well-behaved client sending a standard notification this surface has no use for; accepting and discarding it costs nothing and avoids that). No gate call for any notification, free or otherwise.
       - **Everything else — any other request method name, including `prompts/*`, `logging/setLevel`, `completion/complete`, and a `tools/call` naming an unknown tool — is refused with a 400/method-not-found, with no gate call at all.** This is a default-deny allowlist: a method this plan did not name is refused, not silently passed through.
       Exactly one `admit(bearerToken:)` call happens for a chargeable request, from whichever one of the two charged branches above applies — never from inside `SelfReportDoor` or `ProviderMailbox` themselves (dev-2 round 2, item 2 — see Task 5's architecture note), and never for a free method or a dropped notification. On `.unauthorized`/`.budgetExceeded`, return the appropriate HTTP error response immediately, having constructed no `MCP.Server` and made no MainActor hop.
    4. On success, construct a fresh `MCP.Server(name: "iris", version: ..., capabilities: Self.serverCapabilities, configuration: .default)` — **`capabilities:` must be passed explicitly, never left at its `.init()` default** (dev-2/planner round 3, item A — confirmed independently by the planner against `Server.swift`: `Server.init`'s `capabilities` parameter defaults to `Server.Capabilities()`, whose `tools`/`resources` fields default to `nil`, and the `initialize` response literally returns `self.capabilities` — so a default-capabilities Server advertises no tools or resources at all, and a spec-following client like Claude Code never calls `tools/list` or `tools/call` against it. This plan's own tests post a bare `tools/call` directly and would pass against a broken server anyway, which is exactly how this escaped three review rounds until a real-client read caught it.) Define `static let serverCapabilities = Server.Capabilities(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false))` and register a `ListTools` handler (the Consumes line already named `withMethodHandler(ListTools.self)`; this step is where it actually gets registered — list the 10 tools: the 6 door tools, `iris_send`/`iris_poll`/`iris_discover`/`iris_status`, and `artifact_put`), **and `ListResources`/`ListResourceTemplates` handlers, each returning an empty list** (dev-3 round 5, finding b: the allowlist in step 3 marks `resources/list`/`resources/templates/list` as free, but "free" only means no gate charge — the request still reaches the `MCP.Server`, and without these two handlers registered the SDK itself answers method-not-found, reintroducing the exact 400 round 4's finding 1 removed). Register all of this alongside the other handlers below. Those handlers: the 6 door tools (`iris_window_owner`, `iris_responder_class`, `iris_composer_state`, `iris_turn_state`, `iris_activation_state`, `iris_event_ring` — one per `SelfReportDoor.Query` case) each calling `door.handle(query:clientId:)` with the **resolved `clientId`** (Task 5's door takes a plain `clientId`, not a bearer token — there is nothing left for it to re-authenticate); 4 mailbox tools (`iris_send`, `iris_poll`, `iris_discover`, `iris_status`) each closed over the same resolved `clientId`, never reading a `from`/`clientId` argument out of the tool call's own arguments (dev-2 Gap 5/provenance) — **`iris_send`'s declared arguments are `text`/`fileRefs` only, with no `to`/recipient argument at all**, since every send addresses Iris (Brian's veto on client-to-client relay); `iris_discover` and `iris_status` return `mailbox.discover()`/`mailbox.status(for: clientId)` as defined in Task 6 — Iris's own identity and this client's relationship to it, never a roster of other registered clients; a `resources/read` handler resolving `iris-artifact://<sha256>` URIs to `artifactStore.get(sha256:requestingClientId: clientId)`; an `artifact_put` tool calling `artifactStore.put(bytes:from: clientId)` (inline base64 bytes in the tool call arguments, capped by `LoopbackHTTPListener.maxContentLength` upstream and `ProviderArtifactStore.maxBytesPerObject` here, never a host path — Global Constraints). `ProviderMailbox.deliverReply` (Task 6) is not registered as an MCP tool handler anywhere in this step — no client-reachable surface writes a message addressed to another client.
       **`iris_send`'s handler is not a bare `mailbox.send` + a loop of `authorize` calls** (dev-2 round 2, item 3 — atomicity): it first **preflights every entry in `fileRefs`** — each is 64-lowercase-hex (cheap, no I/O) and `artifactStore.authorize(sha256: ref, by: clientId, adding: [])` would not throw for it (calling `authorize` with an empty `adding:` set is a pure permission check with no side effect other than the union-with-empty-set no-op; if the SDK or store implementation makes that awkward, add a dedicated non-mutating `func canAuthorize(sha256:by:) -> Bool` to `ProviderArtifactStore` instead — Task 7's choice to make, this task only needs *a* non-mutating check). **If any ref fails preflight, the whole send is refused before `mailbox.send` is ever called** — no partial message, no partial grant. Only once every ref preflights clean does the handler call `mailbox.send(from: clientId, text: <argument>, fileRefs: <argument>)` (always addressed to Iris — there is no recipient argument to read) and then, in **one** call, `artifactStore.authorizeAll(sha256s: <the message's fileRefs>, by: clientId, adding: ProviderTokenRegistry.reservedClientId)` — **`adding:` is always this constant, never a tool-call argument or `ProviderMailbox.MailboxParty.iris` itself** (`ProviderArtifactStore`'s ACL, Task 7, is a plain `Set<String>`, so the string Task 1 reserved is the identity that must land there — dev-3's rule-26 read, question 2, folding into item 10 below) — the atomic, all-or-nothing form (Task 7), not a loop of individual `authorize` calls, granting the read to Iris itself, never to another client. **If `authorizeAll` throws anyway** — the preflight and the grant are two separate actor hops with an `await` between them, during which `sweepExpired`/`purge(clientId:)` could in principle run and invalidate a ref that preflighted clean moments earlier (dev-2 round 3 smaller item 1: this is the residual race the preflight alone does not close) — the handler calls `mailbox.retract(id: message.id)` to undo the just-stored message before returning the error, so a grant failure never leaves a half-delivered message behind. This ordering means a message with any invalid or since-invalidated file reference never ends up durably in Iris's mailbox, rather than arriving with some refs readable and others not.
    5. Wrap the whole of steps 3-4 (from the moment a gate `admit`s a request through the final response) in a `requestDeadline` bound (dev-2 round 2 smaller item: Task 2's listener only bounds the *read*, not the time a handler takes to produce a response — a handler that never returns leaves the HTTP connection, and the transport's `responseWaiters` continuation for it, waiting forever). On expiry, return a 504-equivalent `HTTPResponse` and still run step 6's teardown.
    6. **Always stop what step 4 started, on every exit path.** `Server.start(transport:)` spawns a receive-loop task that holds both the `Server` and the `transport` alive until `Server.stop()` cancels it and disconnects the transport (dev-2 round 2, item 1 — the **high** finding: "let them fall out of scope" was wrong, since nothing else ever ends that task, leaking a `Server` + task + transport per request). So: `try await server.start(transport: transport)`, then `let response = await transport.handleRequest(request)` (or the deadline timeout from step 5), then **`await server.stop()`**, then return `response` — and if `server.start` itself throws, still call `server.stop()` before returning the error (a `do`/`catch` with `server.stop()` in both the success path and the `catch`, since Swift has no async `defer`).
    Also schedules `artifactStore.sweepExpired()` and `mailbox.sweepExpired()` on a repeating timer matching `AppState.sweepArtifacts`'s own cadence ("at launch, and daily through the maintenance hook" — cite by symbol (`AppState.sweepArtifacts`), not a line number that drifts between `~/src/iris` and `origin/main`).
  - `func revoke(clientId: String) async throws` — the **one** entry point that tears a client down completely (dev-2 round 2, item 4: an earlier draft of this task said revocation happened "however Task 1's revoke path is driven" with nothing actually calling it, and separately said only the mailbox was purged while the store's grants lived on — both are fixed here by making this the single, real call site): `try tokenRegistry.revokeToken(forClientId: clientId)`, then `await mailbox.purge(clientId: clientId)`, then `await artifactStore.purge(clientId: clientId)`. Whatever drives revocation (a future admin tool, a manual script — out of scope for Phase 1's own UI per Task 1's onboarding note) calls this, never `tokenRegistry.revokeToken` directly.
  - `func stop() async`.
- The app-lifecycle modification instantiates one `IrisMCPProviderServer` and calls `start()`/`stop()` as `ConfigManager.shared.mcpProviderEnabled` flips, mirroring however the existing sandboxing toggle's `didSet` already drives a side effect (if it drives one directly; if `enableSandboxing` is read lazily instead, follow whatever wiring pattern an adjacent toggle-that-does-start-something uses instead — identify one by grep before copying, citing the pattern by symbol rather than a line number).

- [ ] **Step 1: Write the failing tests that an unauthorized call to each of `initialize`, `tools/list`, `ping`, and a tool call is rejected before any `MCP.Server` is constructed and before `SelfReportDoor.handle`/`mailbox` is touched (dev-2 Gap 3 — Review Focus item 1 now explicitly covers the non-tool-call methods too), plus the batch-body rejection (dev-2 round 2, item 2)**

```swift
@Test("initialize, tools/list, ping, and a tool call are all rejected pre-Server on a missing, malformed, or unknown-but-well-formed token")
func allMethodsAuthEnforcedBeforeServerConstruction() async throws {
    // Build an IrisMCPProviderServer with a door/mailbox whose touch-points each increment a
    // counter; for each of {no Authorization header, "Bearer garbage", a syntactically valid but
    // unissued token} and each of {initialize, tools/list, ping, tools/call iris_window_owner},
    // drive the request through handleAuthenticated directly (constructing the HTTPRequest body
    // by hand, not over a real socket) and assert: the HTTP response is an error, and no counter
    // moved. A missing token and a malformed token must both be distinguishable failures in the
    // test's own assertions, not collapsed into one case (Review Focus item 1).
}

@Test("a JSON-RPC batch (top-level array) body is rejected before any gate is touched")
func batchBodyRejected() async throws {
    // A well-formed valid token, but the body is a JSON array of two requests; assert a 400 and
    // that no gate's admit() was called (one admit must never cover N calls).
}

@Test("initialize, tools/list, and ping consume no gate budget; only tools/call does")
func onlyToolCallConsumesBudget() async throws {
    // Build gates with capacity: 1. Drive initialize, tools/list, and ping as the same client,
    // several times each; assert none of them exhausted either gate's budget (a subsequent
    // tools/call for that client still admits). Then drive one tools/call; assert the budget is
    // now consumed for that gate.
}

@Test("a door tool call over its gate's budget never reaches the door's MainActor hop") // Review Focus item 4
func doorBudgetExceededNeverConstructsDoor() async throws {
    // Build doorGate with capacity: 1, and a door built from a MainActor-only probe closure that
    // increments a counter. Drive one iris_window_owner call (consumes the budget), then a second;
    // assert the second is rejected (429-equivalent) and the probe counter is still at the value
    // the first call left it at — the second call never constructed a Server, never called
    // door.handle, never touched the MainActor probe again.
}

@Test("a method not on the allowlist is refused, spending neither gate's budget")
func disallowedMethodRefused() async throws {
    // Build doorGate and mailboxGate with capacity: 1 each (dev-3 round 4, finding 4: the
    // observable for "no gate call was made" is that a legitimate call still admits afterward,
    // not an internal call-count assertion). Drive each of prompts/list, logging/setLevel, and a
    // tools/call naming an unknown tool, through handleAuthenticated as the same client; assert
    // each is a 400/method-not-found. Then drive one real door tool call and one real mailbox
    // tool call for that same client; assert both still admit — if the refused calls had spent
    // either gate's single unit of budget, one of these would now be rejected instead.
}

@Test("resources/read is charged to mailboxGate, not left free or uncharged")
func resourcesReadChargedToMailboxGate() async throws {
    // Build mailboxGate with capacity: 1. "a" puts an object (artifact_put), authorizes "b" via a
    // send; drive a resources/read for that sha256 as "b" once (succeeds, consumes the budget),
    // then again (budget exhausted -> rejected). Confirm doorGate's budget is untouched by either
    // call (dev-2 round 3, item B: resources/read is a distinct JSON-RPC method, not a tools/call,
    // and must still cost a unit of the mailbox/file surface's budget).
}

@Test("resources/list and resources/templates/list are free and return an empty list") // dev-3 round 4, finding 1
func resourcesListReturnsEmpty() async throws {
    // A well-formed valid token; drive resources/list, then resources/templates/list, through
    // handleAuthenticated with no prior artifact_put/authorize. Assert both succeed (not a 400 —
    // this surface advertises the `resources` capability via Self.serverCapabilities, so a
    // spec-following client may call these on connect) and each returns an empty resources/
    // resourceTemplates array, never erroring just because nothing has been shared yet. Assert
    // neither gate's admit() was called (these are free, like initialize/tools-list/ping).
}

@Test("a body with a duplicate top-level JSON key is rejected at the gate, never reaches dispatch") // dev-3 round 4, finding 2
func duplicateTopLevelKeyRejected() async throws {
    // A well-formed valid token; construct a raw body with two "method" keys (one "tools/call",
    // one naming a door tool directly as a top-level "method" too, or any two differing values —
    // the point is the key repeats, not which value a lenient parser would pick) by hand, since
    // JSONSerialization/JSONEncoder would collapse it before this test could observe the
    // ambiguity. Drive it through handleAuthenticated; assert it is rejected before any gate call
    // and before any Server is constructed — the gate's own duplicate-key scan over the raw bytes
    // must catch this, not a decode that already silently picked one value.
}

@Test("a body with a duplicate key inside params is rejected too, not just at the top level") // dev-3 round 5, finding a
func duplicateParamsKeyRejected() async throws {
    // A well-formed valid token; construct a raw body for tools/call whose "params" object has
    // two "name" keys (one naming a door tool, one naming a mailbox tool — different gates, so a
    // scan that only checked the top level and let this through could charge the wrong one).
    // Drive it through handleAuthenticated; assert it is rejected before any gate call, the same
    // as duplicateTopLevelKeyRejected — this is the case a top-level-only scan misses.
}

@Test("an unlisted notification is accepted and dropped, not refused") // dev-3 round 4, finding 3
func unlistedNotificationAcceptedAndDropped() async throws {
    // A well-formed valid token; drive notifications/cancelled (a method with no id — a JSON-RPC
    // notification, not a request) through handleAuthenticated. Assert a 202-equivalent response
    // (or whatever this transport's notification-accepted shape is), not a 400, and that neither
    // gate's admit() was called. notifications/initialized (already free per the allowlist) is a
    // different case from this one; this test is specifically the "no entry names this
    // notification, but it's still a notification" path.
}

@Test("the tools/list response names exactly the tool names the dispatch allowlist accepts") // dev-3 round 4, finding 5
func listToolsMatchesDispatchAllowlist() async throws {
    // Drive a tools/list request through handleAuthenticated; decode the response's tool names
    // into a Set<String>. Compare it against a Set<String> built from the same source the
    // dispatch allowlist's tool-name checks read from (not a second, separately maintained
    // literal list in the test — if the implementation hard-codes the allowlist as a separate
    // array from ListTools's registration, this test's own list must be built from whichever one
    // is NOT what's under test, so a future tool added to one and not the other actually fails
    // this test rather than both lists silently matching each other).
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: fails to compile

- [ ] **Step 3: Implement `IrisMCPProviderServer.handleAuthenticated` through the auth/dispatch steps only (no `MCP.Server` construction yet)**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS

- [ ] **Step 5: Write the failing test confirming blocker 1 is actually fixed: two successive `initialize` calls, from what look like two different clients, both succeed against this server (where one shared `Server` would throw "already initialized" on the second); and the failing test that the `initialize` response actually advertises tools and resources (dev-2/planner round 3, item A)**

```swift
@Test("two clients can each initialize without the second failing on \"already initialized\"")
func secondClientInitializeSucceeds() async throws {
    // Issue tokens for "a" and "b". Drive an `initialize` request as "a" through
    // handleAuthenticated, then a second, unrelated `initialize` request as "b". Assert both
    // succeed (this is the blocker-1 regression test: the pre-spike one-shared-Server shape would
    // make the second throw MCPError.invalidRequest("Server is already initialized")).
}

@Test("the initialize response advertises both a tools and a resources capability")
func initializeAdvertisesCapabilities() async throws {
    // Drive a well-formed initialize request through handleAuthenticated; decode the JSON-RPC
    // response and assert its result.capabilities.tools and .resources are both non-nil. A Server
    // built with the default Server.Capabilities() would fail this (dev-2/planner round 3, item A:
    // the default leaves both nil, so a real client never calls tools/list or tools/call at all —
    // this plan's own tests posting a bare tools/call directly would pass against that broken
    // server anyway, which is exactly how this escaped three review rounds; this test is what
    // would have caught it).
}
```

- [ ] **Step 6: Run both, verify the first fails against a naive single-shared-`Server` implementation (confirm the regression is real before fixing it — write the naive version first if it isn't already the thing Step 3 built, see it fail here, then move to the per-request shape) and the second fails against a `Server` built with default capabilities; implement the full per-request `Server`+`transport` construction with `Self.serverCapabilities` and the `ListTools` handler, verify both pass**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS, test count ≥ 5

- [ ] **Step 7: Write the failing teardown test that a per-request `Server`+`transport` does not leak (dev-2 round 2, item 1 — the high finding)**

```swift
@Test("the per-request Server and transport are stopped and released after handleRequest returns")
func perRequestServerIsTornDown() async throws {
    // Drive N well-formed requests (N small, e.g. 5) through handleAuthenticated sequentially.
    // Hold a weak reference to each constructed Server (requires a test seam: either an injectable
    // Server factory the test can observe, or asserting via StatelessHTTPServerTransport's own
    // `terminated`-equivalent state that each transport reports itself done after its one request).
    // Assert every weak reference is nil (or every transport reports terminated) once its request
    // has returned — proving `server.stop()` actually ran rather than merely being written.
}
```

- [ ] **Step 8: Run it, verify it fails against a "let it fall out of scope" implementation (confirm the leak is real — Swift won't crash or hang on a leaked actor+task, so this test must actually check liveness, not just "no crash"), add the explicit `server.stop()` on every exit path (success, `handleRequest` returning an error body, the deadline-timeout path, and a thrown `server.start`), verify it passes**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS, test count ≥ 5

- [ ] **Step 9: Write the failing end-to-end test: start the server on a real (test) port, issue a token, POST a `tools/call` for `iris_discover` over real HTTP, assert Iris's own peer identity comes back — not a roster of other clients**

```swift
@Test("iris_discover over real HTTP returns Iris's own identity, never a client roster")
func discoverReturnsIrisIdentityOverHTTP() async throws {
    // Issue tokens for "a" and "b" so the registry is non-trivial. POST a tools/call for
    // iris_discover as "a" over real HTTP; decode the result and assert it names Iris
    // (ProviderIdentity.peerId == "iris"), and contains neither "a" nor "b" — the earlier
    // client-to-client-relay draft's version of this test asserted the opposite (that the
    // registered client list came back); this test is the replacement, not an addition.
}
```

- [ ] **Step 10: Write the failing tests for the file-sharing ACL composition and `iris_send`'s atomicity, including the Gap-4 negative case at the full wiring level (not just inside Task 7's own store tests) — now that every send's recipient is Iris, these are about what Iris, and only Iris, ends up authorized to read**

```swift
@Test("sending a file reference authorizes Iris, but nobody else")
func sendAuthorizesIrisOnly() async throws {
    // registry has clients "a", "b"; "a" calls artifact_put (gets sha), then iris_send with
    // fileRefs: [sha]; assert artifactStore.get(sha256: sha, requestingClientId:
    // ProviderTokenRegistry.reservedClientId) now succeeds, and artifactStore.get(sha256: sha,
    // requestingClientId: "b") still throws .unauthorized — "b" gains nothing just because "a"
    // sent a message, since there is no longer any way to name "b" as a send's recipient at all.
}

@Test("a client cannot name an object it never held and thereby grant Iris access to someone else's upload")
func sendCannotGrantAccessToAnUnheldHash() async throws {
    // "a" calls artifact_put (gets sha; only "a" holds it). "c" (who was never authorized for sha)
    // calls iris_send with fileRefs: [sha]. Assert the whole send is refused — "c"'s poll-facing
    // state shows nothing sent (dev-2 round 2, item 3: this is the atomicity test — the earlier
    // "or at least does not call authorize successfully" hedge is gone; the message itself must
    // never have been delivered either, and Iris must not have been granted access to "a"'s
    // object via "c"'s claim).
}

@Test("a send with one valid and one invalid fileRef delivers nothing, not a partially-authorized message")
func sendWithOneBadRefDeliversNoMessage() async throws {
    // "a" holds sha1 (its own upload) but not sha2 (never uploaded, never authorized). "a" calls
    // iris_send with fileRefs: [sha1, sha2]. Assert no message was stored in Iris's inbox at all —
    // not a message with sha1 readable and sha2 not. Then assert sha1's authorized-reader set
    // still does not include ProviderTokenRegistry.reservedClientId (the preflight-before-send
    // ordering means no partial grant happened either).
}
```

- [ ] **Step 11: Write the failing test that `iris_send`'s `from` and `iris_poll`'s caller identity are always the gate-resolved `clientId`, never read from the tool call's own arguments, even if an argument naming `from`/`clientId`/`to` is present in the call (dev-2 Gap 5 — this is the real enforcing test Task 6 Step 5 could only gesture at)**

```swift
@Test("a tool call argument named from, clientId, or to is ignored; provenance is the resolved token's client id and the recipient is always Iris")
func toolArgumentsCannotOverrideResolvedIdentity() async throws {
    // Drive an iris_send call as client "a" whose JSON-RPC arguments include extra "from": "b"
    // and "to": "c" keys (arguments the schema doesn't declare but the handler might carelessly
    // read with a dictionary subscript); assert the stored Message's `from` is .client("a"), not
    // .client("b"), and its `to` is .iris, not .client("c") — a client cannot even attempt to
    // name another client as a send's recipient, let alone succeed at it.
}
```

- [ ] **Step 11a: Write the failing source-scan test that `deliverReply` has no call site in this surface's production code** (dev-3's rule-26 read, question 1 — a prose claim in Task 6/Task 8's text is not an enforced fact until a test pins it)

```swift
@Test("ProviderMailbox.deliverReply is never called from production code outside ProviderMailbox.swift itself")
func deliverReplyHasNoProductionCallSite() throws {
    // Recursively walk Sources/ and App/ (dev-3's rule-26 re-read: a single top-level
    // Sources/IrisKit listing missed a subdirectory in #1046's own scan, so walk the full tree
    // the same way #1046's fix does) for "deliverReply(" and assert every match's file is
    // Sources/IrisKit/MCPProvider/ProviderMailbox.swift (its own definition/any internal use) —
    // zero matches anywhere else, in particular IrisMCPProviderServer.swift. This is the
    // enforced version of item 25's grep in the final whole-branch reviewer note: it pins today's
    // absence as a fact this task's own commit leaves true, and a future PR that wires
    // deliverReply to an MCP tool without updating this test fails it, which is the point.
}
```

- [ ] **Step 12: Write the failing test for `IrisMCPProviderServer.revoke(clientId:)` as the single real teardown entry point (dev-2 round 2, item 4)**

```swift
@Test("revoke tears down the token, the mailbox, and the store's grants for that client in one call")
func revokeTearsDownEverything() async throws {
    // Issue a token for "x"; have "a" send "x" a message with a file ref, authorizing "x" to read
    // it. Call server.revoke(clientId: "x"). Assert: the old token no longer resolves
    // (tokenRegistry.clientId(forToken:) == nil), x's pending mailbox is empty (mailbox.status),
    // and x's authorized-reader grant on that ref is gone (artifactStore.get(..., requestingClientId:
    // "x") now throws .unauthorized). Then issue a *new* token for "x" and confirm the new "x"
    // starts with none of the old one's mailbox or file access.
}
```

- [ ] **Step 13: Run Steps 9-12's tests (including Step 11a's source scan), verify they fail, wire the remaining pieces until they pass**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS, test count ≥ 10

- [ ] **Step 14: Wire the app-lifecycle start/stop, and the app's revoke-driving path (if any exists yet — Task 1's onboarding note already flags that Phase 1 ships no UI for this) to call `revoke(clientId:)`; add a test (or, if the app-lifecycle file has no existing test harness for this kind of toggle, note in the ledger that this one piece is verified by manual GUI check only, flagged for the task reviewer)**

- [ ] **Step 15: Run the full warnings-clean build**

Run: `scripts/check-warnings.sh`
Expected: exit 0

- [ ] **Step 16: Run the full suite**

Run: `swift test --no-parallel`
Expected: all green, note the total test count

- [ ] **Step 17: Commit**

```bash
git add Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift Sources/IrisKit/IrisApp.swift Tests/irisTests/MCPProvider/IrisMCPProviderServerTests.swift
git commit -m "feat: #1067 wire the MCP provider server (per-request Server+transport, torn down on every exit) + app lifecycle toggle"
```

---

## Task 9: Package manifest and worktree hygiene

**Files:**
- Modify: `Package.swift` (confirm, don't necessarily change — `MCP` is already a dependency of `IrisKit` and `irisTests`; this task is a checkpoint, not new wiring, unless `Network` needs an explicit product dependency, which it does not on Apple platforms)

**Interfaces:** none new.

- [ ] **Step 1: Confirm `swift build` picks up `Network` (system framework, no `Package.swift` entry needed) and the full `MCPProvider/` module compiles clean**

Run: `swift build`
Expected: exit 0, no new dependency needed

- [ ] **Step 2: Re-run `scripts/check-warnings.sh` once more on the full branch (not just the last task's diff)**

Run: `scripts/check-warnings.sh`
Expected: exit 0

- [ ] **Step 3: Grep for what this change makes untrue (Invariant 9) — `README.md`, `docs/`, and any agent-facing string**

This surface adds no new *agent-facing* tool (the self-report door and mailbox are MCP tools exposed to external guests, not `ToolExecutor.getTools()` entries Iris's own model sees) — confirm that by grepping `ToolExecutor.swift` and `iris.swift`'s tool declarations for anything this plan's tool names collide with, and confirm none of this plan's new tools are reachable from `ToolExecutor.execute()`. If the README or a `docs/` feature page claims Iris has no MCP server/provider surface, or claims "no file transfer" (the messaging spec, `docs/specs/2026-10-10-sessions-a2a-messaging.md`, says artifacts never cross the network in v1 — note Task 7 is loopback-only, so that claim may still hold; check it isn't *unqualified*), fix what's now false.

- [ ] **Step 4: Commit if Step 3 found anything to fix; otherwise this task ends with no commit**

---

## Note for the final whole-branch reviewer

Confirm explicitly: (1) no task's code path reads `Conversation.history`, `AppState.peerDepths`, `AppState.peerRateLimiter`, `AppState.inboxEmitRateLimiter`, or calls `queuePeerArrival`/`startTurn`/`send_to_session`/`inbox_item` — Phase 1 must not touch any of the §3.2/§3.5 machinery, by design; (2) the self-report door's MainActor hop is always raced via `withTimeout`, never a bare `MainActor.run` with no deadline; (3) the loopback listener binds via `NWParameters.requiredLocalEndpoint` at construction time AND refuses non-loopback connections as a second layer (Task 2, Steps 5-6) — both, not either; (4) no window title, `stringValue`, transcript text, memory, or file content appears in any self-report door response (grep every `Snapshot`/`Value` construction site); (5) `ProviderArtifactStore` and `ProviderMailbox` are entirely separate storage from the conversation-scoped `ArtifactStore`/`artifact_refs` — no accidental reuse of either; (6) `ProviderArtifactStore.get` never succeeds for a client absent from the object's authorized-reader set, even with the correct hash — a bare hash must not grant a read; (7) `DiagnosticEventRing.record`/`.snapshot` are synchronous and lock-guarded, never routed through `Task { await ... }` from a sync AppKit callback — the ring's whole purpose is preserving event order; (8) **no `MCP.Server` instance in Task 8's wiring is ever reused across more than one `handleAuthenticated` call** — grep for exactly one `MCP.Server(` construction site and confirm it sits inside the per-request closure, not hoisted to `IrisMCPProviderServer.start()` or a stored property (dev-2 blocker 1); (9) **every request resolves a client id (401 if it can't) before any JSON-RPC body is parsed, and every chargeable method (a `tools/call`, or `resources/read`) is admitted through exactly one `ProviderRequestGate.admit` call** — `initialize`/`notifications/initialized`/`tools/list`/`ping` resolve but never admit (no gate consumed), every other method is refused with no gate call at all (dev-2 round 3, item B), and `SelfReportDoor.handle`/the mailbox tool handlers never call `admit` themselves (grep for **`admit(` outside `handleAuthenticated`** — there should be none, not "exactly once per gate," since the one dispatch site legitimately calls each gate's `admit` from its own branch — dev-2 round 3 smaller item 5 corrected this wording) (dev-2 Gap 3 / round 2 item 2 / round 3 item B); (10) `ProviderArtifactStore.authorize`/`.authorizeAll` are never called with a `by:` argument the caller supplied — only with the gate-resolved `clientId` from that request's own closure (dev-2 Gap 4) — **and every `adding:` argument on both is `ProviderTokenRegistry.reservedClientId`, never a tool-call argument, `ProviderMailbox.MailboxParty.iris`, or any other client id** (dev-3's rule-26 read, question 2: grep Task 8's wiring for every `authorize(`/`authorizeAll(` call site and confirm `adding:` is always that one constant, since `ProviderArtifactStore`'s ACL has no type separation of its own to rely on); (11) every `sha256` string that reaches `ProviderArtifactStore`'s or `ProviderMailbox`'s filesystem/bookkeeping calls passed the 64-lowercase-hex check first; (12) `ProviderMailbox.poll` is called with `sinceSequence`, never a `Date`-keyed cursor, anywhere in Task 8's wiring; (13) the listener's request-line/header/`Content-Length`/read-timeout/concurrent-connection caps (Task 2) and the artifact store's per-client/total quotas (Task 7) are each backed by a named constant and an enforcing test, not left as narrative "bounded" language; (14) **every per-request `Server`/`transport` pair is stopped on every exit path of `handleAuthenticated`** — the success path, an error response, the request-deadline timeout, and a thrown `server.start` — grep for `server.stop()` and confirm it appears on all of them, not only the happy path (dev-2 round 2, item 1, the round's highest-severity finding); (15) `iris_send` never leaves a message delivered with an unauthorized or nonexistent `fileRefs` entry readable by Iris, and never leaves a partial grant behind for a send that was ultimately refused — the preflight-before-send-before-authorize ordering in Task 8 step 4 (dev-2 round 2, item 3); (16) `IrisMCPProviderServer.revoke(clientId:)` is the only call site for `ProviderTokenRegistry.revokeToken` — grep for `revokeToken(` outside `ProviderTokenRegistry.swift` and `IrisMCPProviderServer.swift` and confirm there isn't one (dev-2 round 2, item 4); (17) `ProviderArtifactStore`'s own test file calls every actor method with `await` (dev-2 round 2, item 5 — a compile-time check, but worth a glance: a test that silently stopped compiling and got skipped by a stale filter would be invisible otherwise); (18) `SelfReportDoor.ComposerState`'s `isEmpty`/`isFirstResponder` never expose the composer's actual text, only booleans (dev-2 round 2 smaller item on `.composerState`'s source); (19) **every per-request `MCP.Server` is built with `Self.serverCapabilities`, never the SDK's default `Server.Capabilities()`** — grep every `MCP.Server(` construction site for an explicit `capabilities:` argument (dev-2/planner round 3, item A — a default-capabilities Server advertises neither `tools` nor `resources`, so a real client never calls `tools/list`/`tools/call` against it at all, and this plan's own tests posting a bare `tools/call` directly would not have caught it); (20) the method dispatch (Task 8 step 3) is a closed, default-deny allowlist — `resources/read` is explicitly charged to `mailboxGate`, and any method not named in the allowlist (`resources/list`, `prompts/*`, `logging/setLevel`, `completion/complete`, an unknown tool name, etc.) is refused with no gate call, never silently passed through uncharged (dev-2 round 3, item B); (21) `iris_send`'s grant uses `ProviderArtifactStore.authorizeAll` (one atomic actor call for every ref), not a loop of individual `authorize` calls, and `mailbox.retract(id:)` runs if that call throws after `send` already stored the message (dev-2 round 3 smaller item 1); (22) `ProviderMailbox.send` and `ProviderArtifactStore.put` each re-check `isRegistered`/`registry.isRegistered` on their caller-supplied client id at the actual mutation, not only earlier in the request's lifecycle (dev-2 round 3 smaller item 2 — closes the window between admission and a concurrent `revoke(clientId:)`); (23) the composer's `NSTextView` is tracked through the named `ComposerFocus.track(_:)`/`.current` holder (`ComposerTextView.swift`), not an unspecified "reachable" reader (dev-2 round 3 smaller item 3); (24) `LoopbackHTTPListener.headerCompletionDeadline` bounds an idle, headers-never-sent connection separately from `readTimeout`'s body bound (dev-2 round 3 smaller item 4); (25) **no MCP tool or JSON-RPC method anywhere in this surface lets one registered client send a message, a file grant, or any other state to another registered client** (Brian's veto on client-to-client relay, 2026-11-11) — Task 8 Step 11a's source-scan test is the enforced version of this, not just this prose; also confirm `iris_send`'s declared tool arguments have no `to`/recipient field, and confirm `iris_discover`/`iris_status`'s return shape carries only Iris's own identity/relationship-to-caller, never `ProviderTokenRegistry.allClientIds()` or any other enumeration of clients reachable from an MCP tool response; (26) `ProviderTokenRegistry.issueToken` throws for `forClientId: ProviderTokenRegistry.reservedClientId` ("iris") — grep for the negative test (Task 1, `reservedClientIdRejected`) and confirm it runs — and `ProviderMailbox.MailboxParty` keeps `.iris` and `.client(String)` as distinct enum cases, never collapsed to a single `String` representation anywhere in `ProviderMailbox.swift` (dev-3's rule-26 read, finding 1 — the mailbox's own type must make "a client named iris" and "Iris itself" structurally unconfusable, independent of Task 1's registration-time guard); (27) every `.inboxFull` check in `ProviderMailbox.send`/`.deliverReply` counts only the caller's own unconsumed messages in that direction, never a single shared count across all senders (dev-3's rule-26 read, finding 2) — grep for `maxPendingPerClient` comparisons and confirm each is scoped to one party, with `inboxFullCapIsPerSender`'s test (Task 6) covering it.
