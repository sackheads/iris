# Iris MCP Provider — Phase 1 (Shape 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a loopback, token-gated MCP **provider** on the running Iris app: a read-only app-level self-report door (window/responder/composer/turn/activation snapshots + an event ring buffer) plus a plain messaging/file-exchange mailbox between registered local clients — with no role-session turns, no model access, and no Conversation/history reads anywhere in the surface.

**Architecture:** A new `Sources/IrisKit/MCPProvider/` module hosts a `MCP.Server` (from the existing `swift-sdk` dependency) behind a hand-rolled loopback-only HTTP/1.1 listener that bridges raw socket bytes to the SDK's framework-agnostic `StatelessHTTPServerTransport`. Bearer tokens are Keychain-bound (one per registered client), checked and rate/concurrency-budgeted *before* any MainActor hop. The self-report door reads live AppKit/AppState through a small set of enumerated, bounded queries raced against a dispatch-timer deadline (`withTimeout`, never `Task.sleep`, per Invariant 4). The mailbox and file exchange are a standalone actor with their own content-addressed store and TTL sweep — intentionally outside `Conversation`/`AppState.history`, so nothing here touches shared turn state, the peer-cascade budget, or the taint model.

**Tech Stack:** Swift 6, `swift-sdk` (MCP) `Server`/`StatelessHTTPServerTransport`, `Network.framework` (`NWListener`) for the loopback socket, `KeychainManager` for token storage, `CryptoKit` for SHA-256 content addressing, Swift Testing.

**Spec:** `docs/specs/2026-11-11-iris-devteam-mcp-collaboration-design.md` (PR #1063, head `fa89958b`) — read §3.1, §3.3, §3.4, §3.6, §3.7, §3.8. Scope and guardrails: issue #1067. Neighbouring (unbuilt, not used by Phase 1): `docs/superpowers/specs/2026-11-08-iris-local-agent-mcp-design.md` (#964, branch `design/iris-local-agent-mcp`).

**Design resolution (planner-confirmed 2026-11-11, vetoable by Brian):** §1067's "send/poll/discover/status... no role-session turns in Phase 1" leaves open what `send` addresses, since #964's role-session/inbox delivery is explicitly out of scope here. This plan resolves it as **client-to-client relay**: `send`/`poll`/`discover`/`status` operate over a flat registry of tokens issued to local MCP clients (the dev-team sessions), with no session, role, or Conversation on either end — the mailbox is new, standalone state, never `AppState`. This sidesteps every §3.2 confidentiality problem (no shared history, no principal, no model in the loop) and matches "serves the debugging motivator with no confidentiality exposure" (§5). Dev↔Iris-*agent* messaging needs a role-session turn, which is Shape 5 — Phase 2, gated on #1066 — and this plan does not build it.

This is infra investment, not throwaway: Task 1's per-token registry, Task 3's auth/budget gate, Task 6's send/poll/provenance machinery, and Task 7's content-addressed store are the exact scaffold Phase 2's dev↔Iris messaging reuses once #1066's context partitioning lands — Phase 2 adds a role-session-addressed delivery path on top of this, it does not replace it.

## SDK spike findings (dev-2 review, blockers 1 & 2 — confirmed 2026-11-11 against pinned `swift-sdk` @ `a0ae212ebf6eab5f754c3129608bc5557637e605`)

Read directly, not run (no harness exists yet to run it against):

- **`Server.swift` ~928-969 (`Initialize` handler):** `isInitialized` is set `true` in `setInitialState` and never reset. A second `initialize` call on the *same* `Server` instance throws `MCPError.invalidRequest("Server is already initialized")` unconditionally — `strict` does not gate this check, only the ones below do. **Confirmed:** one shared `MCP.Server` cannot serve a second client's `initialize`, so the original Task 8 (one `Server` + one `StatelessHTTPServerTransport`, started once at app launch) cannot work for more than one client session.
- **`Server.swift` `Configuration.default = Configuration(strict: false)`, and `handleMessage`/`processRequest` (~750-765, ~854-865):** the `checkInitialized()` gate that would otherwise reject `tools/call` before `initialize` only runs `if configuration.strict`. With the default (non-strict) configuration, a **fresh** `Server` that has never seen an `initialize` call accepts a bare `tools/call` (or any other request) directly. **Confirmed:** a fresh `Server` + fresh transport, built per authenticated HTTP request and never asked to `initialize` at all, serves exactly one JSON-RPC request with no "already initialized" state ever touched.
- **`StatelessHTTPServerTransport.swift` `handleJSONRPCRequest` (~220-244):** `httpRequestContexts[requestID]` and `responseWaiters[requestID]` are both keyed by the **JSON-RPC request id string**, not by connection or client. Two concurrent requests that both carry id `"1"` (two independent MCP clients each starting their own id sequence at 1, which every MCP client does) overwrite each other's dictionary entry between the `httpRequestContexts[requestID] = request` write and the point the server's handler later reads `httpRequestContext(for:)` — the intervening `await` on `responseWaiters[requestID]`'s continuation is a real suspension point, so this is a genuine same-actor interleaving hazard, not just a data race. **Confirmed:** under one shared `Server`+transport, client A's handler can read client B's `Authorization` header (breaking `from` provenance and the mailbox boundary) and B's own HTTP response can hang forever (its waiter was silently replaced).

**Resolution, replacing Task 8's original architecture (see the rewritten Task 8 below):** the loopback listener's `handle` closure resolves the bearer token and the client id **before constructing any `MCP.Server`** (this also makes Gap 3's pre-dispatch auth free — the raw `HTTPRequest`'s `Authorization` header is read straight off the socket-parsed request, with no need to round-trip through `Server.currentHandlerContext?.httpContext` at all). On a successful admit, it builds **one fresh `MCP.Server(configuration: .default)` and one fresh `StatelessHTTPServerTransport()` per request**, registers that request's tool handlers closed over the already-resolved `clientId`, calls `transport.handleRequest(request)` exactly once, and lets both the `Server` and the `transport` fall out of scope when the request completes. No `Server` instance is ever asked to `initialize` twice, and no two requests ever share a `transport`'s `httpRequestContexts`/`responseWaiters` dictionary, so the JSON-RPC id collision in blocker 2 cannot occur structurally — there is no shared keyspace left for two ids to collide in.

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
- Off by default: the provider only binds its socket when the feature toggle (new `ConfigManager.mcpProviderEnabled`) is on, following the existing `enableSandboxing` toggle pattern (`ConfigManager.swift:303-305`).
- `ProviderArtifactStore.get` is **not** a bare-hash-grants-a-read surface (§7.6 B's rule: a hash alone grants nothing) — a read succeeds only for a client in that object's own authorized set, populated at `put`/`send` time (Task 7/6, planner review on PR #1068).
- The loopback listener binds its socket to `127.0.0.1` via `NWParameters.requiredLocalEndpoint` (construction-time, not just a runtime connection filter) — the per-connection endpoint check (Task 2) is defence in depth on top of that bind, not a substitute for it (planner review on PR #1068).
- `DiagnosticEventRing` preserves the physical order events occurred in; a diagnostic ring that can reorder the very sequence it exists to capture (#1055's point) is worse than no ring. Use a synchronous, lock-based recorder, not `Task { await actor.record(...) }` from a sync callback (planner review on PR #1068).
- **No `MCP.Server` instance is ever used for more than one JSON-RPC request** (dev-2 blocker 1/2 — see "SDK spike findings" above). A fresh `Server` + fresh `StatelessHTTPServerTransport` pair is built per authenticated HTTP request, inside Task 8's wiring, never shared or cached across requests or clients.
- **Auth happens on the raw `HTTPRequest`, before any `MCP.Server` exists** (dev-2 Gap 3) — the listener's `handle` closure resolves the bearer token and calls the appropriate `ProviderRequestGate.admit(bearerToken:)` first; `initialize`, `tools/list`, and `ping` get no free pass just because they look harmless. A 401 at this layer touches no SDK type at all.
- **`ProviderArtifactStore.authorize` requires the sender to already hold read access** (dev-2 Gap 4, closing the hole in the planner's own ACL fix on PR #1068): `authorize(sha256:, by: senderId, adding:)` throws `.unauthorized` unless `senderId` is already in that object's authorized-reader set. A client that merely *learns* a hash (e.g. because another message mentioned it) must never be able to grant a third party read access to it.
- **Every SHA-256 string reaching the filesystem is validated as 64 lowercase hex digits first** (dev-2 Gap 4) — `ProviderArtifactStore` never passes a caller-supplied or message-supplied string to a file path without that check.
- **Resource bounds are named constants with enforcing tests, not narrative "bounded" language** (dev-2 Gap 7): the listener caps request-line length, header count and byte size, `Content-Length`, and read timeout (Task 2); the inline `artifact_put` body cap for Phase 1 is 8 MiB, not romar's 64 MiB baseline (base64 inflation makes 64 MiB ~86 MB resident per request — Task 7); `ProviderArtifactStore` has a per-client daily quota and a total store cap, mirroring `ArtifactLimits.sessionDailyBytes` (200 MiB) and `.defaultExchangeCapMB` (2048 MiB) at `Sources/IrisKit/Artifacts.swift:56-60` (Task 7); `ProviderMailbox` caps message count, text size, and `fileRefs` count per message, has its own TTL, and exposes a monotonic sequence cursor for polling instead of `since: Date` (Task 6).
- Every elapsed-time bound in this surface (`ProviderRequestGate`'s token bucket, `ProviderMailbox`'s poll cursor) uses a monotonic clock (`ContinuousClock`/`Duration`), never `Date`/`TimeInterval` — AGENTS.md #605: `Date()` counts a Mac sleep, and a maintenance sleep mid-run has produced impossible walls before.

## Review Focus

- **A client with no token, a malformed token, or a token for a different/unknown client sends a request — including `initialize`, `tools/list`, or `ping`, not just a tool call.** Expected: 401 before any tool dispatch and before any `MCP.Server` is even constructed (dev-2 Gap 3), no MainActor hop, no budget consumed. Task 8's listener-level auth wrapper owns this, with tests for missing, malformed, and well-formed-but-unknown tokens distinctly.
- **The loopback listener receives a non-HTTP byte stream, a truncated request, or a request with a huge/absent `Content-Length`.** Expected: the connection is closed or answered with an error; the listener itself never hangs, crashes, or blocks other connections. Task 2 owns this, with named constants for the request-line/header/`Content-Length`/read-timeout caps and a test per cap (dev-2 Gap 7).
- **The self-report door is called while Iris is backgrounded (not key/active).** Expected: the snapshot still returns, tagged with its own activation state, rather than silently reporting "not key" as if the queried fact itself were false (§3.7 key-window subtlety). Task 5 owns this.
- **A client floods the self-report door faster than its rate/concurrency budget allows.** Expected: requests over budget are rejected at the entry point before the MainActor hop — never queued, never left to time out on the main actor race. Task 3's budget gate, exercised by Task 5's door, must have a test proving rejection happens pre-hop with the budget actually exhausted first (dev-2 Gap 5: Task 5 Step 1 as originally written covers only the unauthorized case — add a second case that admits up to capacity, exhausts it, then asserts the MainActor-only probe counter stayed at zero on the next call).
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
  - `func issueToken(forClientId clientId: String) throws -> String` — generates a token from 32 random bytes via `SecRandomCopyBytes` (base64url- or hex-encode them; **not** `UUID().uuidString`, which has only 122 bits of entropy from a generator not specified as cryptographically secure and is the wrong tool for a bearer credential), stores `[clientId: token]` into the Keychain under a new service `KeychainManager.mcpProviderService = "iris.mcp.provider"` via `KeychainManager.shared.updateSecretsOrThrow(service:_:)` (which itself `throws`, so this does too), updates the in-memory cache, and returns the token.
  - `func revokeToken(forClientId clientId: String) throws` — removes that client's entry via the same `updateSecretsOrThrow` pattern, invalidates/updates the in-memory cache, and **purges that client's mailbox/file-ACL state** (dev-2 smaller item: a later `issueToken` for the same `clientId` must not silently inherit the old inbox or file ACLs). Since this registry has no reference to `ProviderMailbox`/`ProviderArtifactStore`, this task only documents the requirement and adds the registry-level piece (returning the old token, if any, so Task 8's wiring can call the mailbox/store purge); Task 8's revoke path is where the actual purge call happens.
  - `func clientId(forToken token: String) -> String?` — reverse lookup against the **in-memory cache**, not a fresh Keychain read. Dev-2 smaller item: a Keychain lookup on every HTTP request (and a locked or denied Keychain item can raise a user-facing prompt) is unacceptable on a hot path; load the registry's whole map into memory once (on init, and again on every `issueToken`/`revokeToken`), and resolve tokens against that cache. The cache is guarded by the same internal lock as the rest of this class's mutable state.
  - `func allClientIds() -> [String]` — every registered client id (backs `discover` in Task 6), from the in-memory cache.
  - `init(keychain: KeychainManager = .shared)` — injectable for tests, per `AGENTS.md` Invariant 7 (never touch `KeychainManager.shared` from a test); loads the initial cache from the Keychain in `init`.
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

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh ProviderTokenRegistryTests`
Expected: fails to compile (`ProviderTokenRegistry` undefined) or runs 0 tests — confirm the script reports a non-zero test count once Step 3 exists, not before.

- [ ] **Step 3: Implement `ProviderTokenRegistry` in `Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift`, and `KeychainManager.mcpProviderService`**

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-filter.sh ProviderTokenRegistryTests`
Expected: PASS, test count > 0

- [ ] **Step 5: Add `mcpProviderEnabled` to `GuardedSettings.swift`'s `GuardedKey`, and `mcpProviderPort` to `ConfigManager`**

`mcpProviderEnabled` opens a network listener when on, so **off must be the protective value** — the opposite of every existing `.flag` case (`enableSandboxing`/`enableVibecop`/`enablePromptInjectionProtection`), whose `protective` is hardcoded `"true"` regardless of case (`GuardedSettings.swift` `protective`, ~line 76). Extend `GuardedKey.Kind.flag` to carry its own protective default — `case flag(protectiveOn: Bool)` — update the three switch sites that currently pattern-match a bare `.flag` (`kind`'s computed `builtIn`, `protective`, and `carriesOver`, ~lines 54, 76-79, 96-99) so each existing case passes `protectiveOn: true` (no behavior change for them) and the new case:

```swift
case mcpProviderEnabled = "MCP_PROVIDER_ENABLED"
// in `kind`:
case .mcpProviderEnabled: .flag(protectiveOn: false)
```

Add `mcpProviderPort: Int` to `ConfigManager` as a plain (non-guarded) setting, per this task's Files note above — it is a bind port, not a spend/safety control, so it does not belong in `GuardedSettings` at all.

- [ ] **Step 6: Write the failing test that `mcpProviderEnabled`'s protective value is `"false"`, following the existing `GuardedSettings`/`GuardedKey` test pattern for an existing flag, plus the mirrored `ConfigManager` persistence test for `mcpProviderPort` (isolated `ConfigManager(store:)`, per Invariant 7)**

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
  - `static let maxRequestLineBytes = 8 * 1024`, `static let maxHeaderBytes = 32 * 1024`, `static let maxHeaderCount = 64`, `static let maxContentLength = 16 * 1024 * 1024` (dev-2 Gap 7 — named constants; `maxContentLength` is a transport-level ceiling above Task 7's own 8 MiB object cap, since this listener also carries JSON-RPC envelope overhead), `static let readTimeout: Duration = .seconds(30)` — all enforced by the parser in this task, not left as "bounded" prose.
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
```

- [ ] **Step 8: Run both, verify they fail if the parser currently hangs, dies, or reads an oversize body; fix; verify they pass**

Run: `scripts/test-filter.sh LoopbackHTTPListenerTests`
Expected: PASS, test count ≥ 5

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

**Interfaces:**
- Consumes: `ProviderRequestGate.admit(bearerToken:)` (Task 3), `DiagnosticEventRing.shared.snapshot()` (Task 4), `withTimeout(seconds:_:)` (`Sources/IrisKit/Timeout.swift`), `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (dev-2 Gap 6 — **not** `Bundle.main.bundleIdentifier`, which is trivially Iris's own id and answers nothing; the #1055 diagnosis needs the actually-frontmost app), a new `@MainActor func anyTurnInFlight() -> (any: Bool, count: Int)` added to `AppState` in this task (derived from `engineTurnCounts.values`, `rotationHold`, and `activeTasks` exactly as `hasTurnInFlight(for:)` at `AppState.swift:1198` does, but aggregated across every conversation with **no conversation id anywhere in its return value** — Global Constraint 2 forbids a conversational read here, and a per-conversation `hasTurnInFlight(for:)` call would need one), `NSApp.isActive`.
- Produces: `struct SelfReportDoor: Sendable` (a plain `nonisolated` struct — never `@MainActor` itself, per Global Constraints) with:
  - `static let mainActorTimeout: Duration = .milliseconds(500)` (named constant; `withTimeout(seconds:_:)` takes `Double` seconds, not `Duration` — dev-2 smaller item — so the implementation converts once at the call site, e.g. `withTimeout(seconds: Double(mainActorTimeout.components.seconds) + Double(mainActorTimeout.components.attoseconds) / 1e18)`, or simply hold the constant as `TimeInterval = 0.5` instead of `Duration` if that conversion reads as needless ceremony for a single call site — either is acceptable, but the plan's citation of `withTimeout(seconds:_:)` must match whichever is chosen).
  - `enum Query: String, Sendable, CaseIterable { case windowOwner, responderClass, composerState, turnState, activationState, eventRing }`
  - `enum ComposerDisabledReason: String, Sendable, Codable { case turnInFlight, noReason }` — dev-2 Gap 6: a free-text `reason: String?` on `.composerState` re-opens exactly the "no free-text content leaves this door" rule (Global Constraints — §3.7 Rune fix applies as much to a reason string as to a window title); enumerate the actual reasons the composer disables itself (grep `ChatView.swift`'s `isSendDisabled` at line ~1177/1209 for what conditions it, and add one enum case per distinct condition found — `turnInFlight` covers at least one; add more if `isSendDisabled` has others) instead of passing any string through.
  - `struct Snapshot: Sendable, Encodable { let query: Query; let isAppActive: Bool; let isKeyWindow: Bool; let value: Value } ` where `Value` is whatever `enum`/struct shape each query needs (frontmost-app bundle id `String?` for `.windowOwner`, class name `String` for `.responderClass`, `(enabled: Bool, reason: ComposerDisabledReason?)` for `.composerState`, `(any: Bool, count: Int)` for `.turnState`, `[DiagnosticEventRing.Entry]` for `.eventRing`) — pick a concrete `Codable` shape per query and hold to it; a `[String: Value]`-style untyped bag is not acceptable here (it is exactly the kind of structure the SDK's `Tool.Result.structuredContent: Value` needs you to produce, so define it once and reuse it for every query's JSON encoding).
  - `func handle(query: Query, bearerToken: String?) async -> Result<Snapshot, DoorError>` where `enum DoorError: Error { case unauthorized; case budgetExceeded; case mainActorUnresponsive(afterMilliseconds: Int) }`.
- The `.mainActorUnresponsive` case is the literal diagnosis the spec calls for (§3.7: "main actor unresponsive for N ms" *is* the diagnosis) — never silently time out into a different error.
- `MainWindow`/`AppState`-reading closures injected into `SelfReportDoor` must themselves be `@MainActor` closures (dev-2 smaller item: `MainWindow` and `AppState.anyTurnInFlight()` are both `@MainActor`-isolated; an injected plain `() -> T` closure called from a non-isolated context would not type-check against them), e.g. `init(windowOwnerReader: @escaping @MainActor () -> String?, ...)`, with `withTimeout` wrapping the `await` hop to each one.

- [ ] **Step 1: Write the failing tests for unauthorized and budget-exceeded short-circuiting before any MainActor work (Review Focus item 4 needs both cases, not just unauthorized — dev-2 Gap 5)**

```swift
@Test("an unauthorized call never reaches the MainActor hop")
func unauthorizedNeverHopsToMainActor() async {
    // Inject a gate whose admit() always returns .unauthorized; assert handle(...) returns
    // .failure(.unauthorized) and that some MainActor-only probe (a counter incremented only
    // inside the MainActor closure) stayed at zero.
}

@Test("a budget exhausted by prior calls also never reaches the MainActor hop")
func budgetExceededNeverHopsToMainActor() async {
    // Build a real ProviderRequestGate with capacity: 1; admit it once (consuming the budget),
    // then call handle(...) again; assert .failure(.budgetExceeded) and that the MainActor-only
    // probe counter is still zero (it was never incremented by this call or the first one, since
    // this test's point is the SECOND, over-budget call never hops — the first call's own
    // MainActor probe count is irrelevant here; isolate it, or use a fresh probe per call).
}

@Test("the activation state is reported even when Iris is not key") // Review Focus item 3
func reportsBackgroundedHonestly() async {
    // Inject a fake "is key" / "is active" reader returning false; assert the snapshot's
    // isAppActive/isKeyWindow fields reflect false rather than the call failing or lying.
}
```

Make `SelfReportDoor`'s MainActor-reading closures and the "is active/is key" reader injectable constructor parameters (mirroring `MainWindowTracking`'s own `appIsActive`/`activate` injection pattern at `StatusItem.swift:41-47`) so these tests never depend on a real `NSApp`/`NSWindow`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: fails to compile

- [ ] **Step 3: Implement `SelfReportDoor`, racing each MainActor read against `withTimeout` at `mainActorTimeout` and mapping `TimeoutError` to `.mainActorUnresponsive(afterMilliseconds: 500)`; implement `AppState.anyTurnInFlight()`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: PASS

- [ ] **Step 5: Write the failing test that `.windowOwner` never emits anything but a bundle id, and `.responderClass` never emits `stringValue`-shaped content**

```swift
@Test("windowOwner reports only the frontmost app's bundle identifier, never a title")
func windowOwnerBoundsField() async {
    // Inject a fake window-owner reader whose underlying fake window has a title set to
    // something identifiable (e.g. "SECRET CONVERSATION TITLE"); assert the Snapshot's
    // encoded JSON does not contain that string anywhere.
}
```

- [ ] **Step 6: Run it, verify it fails if the implementation reads title anywhere, fix, verify it passes**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: PASS, test count ≥ 5

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/SelfReportDoor.swift Sources/IrisKit/AppState.swift Tests/irisTests/MCPProvider/SelfReportDoorTests.swift
git commit -m "feat: #1067 self-report door — bounded, non-MainActor-entry diagnostic reads"
```

---

## Task 6: Provider mailbox (send/poll/discover/status)

**Files:**
- Create: `Sources/IrisKit/MCPProvider/ProviderMailbox.swift`
- Create: `Tests/irisTests/MCPProvider/ProviderMailboxTests.swift`

**Interfaces:**
- Consumes: `ProviderTokenRegistry.clientId(forToken:)`, `.allClientIds()` (Task 1); `ProviderRequestGate.admit(bearerToken:)` (Task 3, a **second**, independently-configured instance from the door's — Global Constraints).
- Produces: `actor ProviderMailbox` with:
  - `static let maxPendingPerClient = 500`, `static let maxTextBytes = 16 * 1024`, `static let maxFileRefsPerMessage = 8`, `static let ttl: TimeInterval = 7 * 24 * 60 * 60` (dev-2 Gap 7 — named caps, matching the no-"bounded"-left-unspecified rule the ring already follows; `ttl` matches Task 7's own object TTL so an undelivered message and the files it references expire together).
  - `struct Message: Sendable, Codable { let id: UUID; let sequence: UInt64; let from: String; let to: String; let text: String; let fileRefs: [String]; let sentAt: Date }` (`fileRefs` are SHA-256 hex strings into Task 7's store; `from` is always the *resolved* client id from the token, never a client-asserted field — provenance per Global Constraints; `sequence` is a mailbox-wide monotonically increasing counter, assigned at `send` time).
  - `func send(from: String, to: String, text: String, fileRefs: [String]) throws -> Message` — throws `MailboxError.unknownRecipient` if `to` is not in the token registry's known client ids, `.textTooLarge` if `text` exceeds `maxTextBytes`, `.tooManyFileRefs` if `fileRefs.count` exceeds `maxFileRefsPerMessage`, `.recipientMailboxFull` if `to`'s pending count is already at `maxPendingPerClient`.
  - `func poll(for clientId: String, sinceSequence: UInt64?) -> [Message]` — every message addressed `to: clientId` with `sequence > sinceSequence` (or all, if `sinceSequence` is nil), oldest first; **does not delete** on poll (so a second poll after a dropped connection still sees them) — delivery is pull, per #1067's "pull mailbox for replies." **A monotonic sequence cursor, not `since: Date`** (dev-2 Gap 7): two messages can share a timestamp at millisecond resolution, and a `Date`-keyed cursor would then drop or duplicate one of them; `sequence` has no ties.
  - `func discover() -> [String]` — `registry.allClientIds()` passthrough.
  - `func status(for clientId: String) -> (pendingCount: Int, lastMessageAt: Date?)`.
  - `func sweepExpired(now: Date = Date())` — deletes every message older than `ttl` for every client, called from Task 8's lifecycle wiring on the same timer as Task 7's `sweepExpired`.
  - `func purge(clientId: String)` — deletes every pending message to or from `clientId`. Dev-2 smaller item: revoking a `clientId` and later re-issuing it to a *different* person must not hand them the old occupant's undelivered mailbox; Task 1/Task 8's revoke path calls this.
- Produced for: Task 8 wires `send`/`poll`/`discover`/`status` as MCP tools, and calls `sweepExpired`/`purge` from its lifecycle wiring.

- [ ] **Step 1: Write the failing tests for send/poll ordering, unknown recipient, discover/status, and the three new caps**

```swift
@Test("poll returns messages addressed to the caller, oldest first, without deleting them, keyed by sequence not timestamp")
func pollIsNonDestructivePull() async throws {
    let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b"]))
    _ = try await mailbox.send(from: "a", to: "b", text: "first", fileRefs: [])
    _ = try await mailbox.send(from: "a", to: "b", text: "second", fileRefs: [])
    let firstPoll = await mailbox.poll(for: "b", sinceSequence: nil)
    #expect(firstPoll.map(\.text) == ["first", "second"])
    let secondPoll = await mailbox.poll(for: "b", sinceSequence: nil)
    #expect(secondPoll.count == 2)  // not deleted
    let onlySecond = await mailbox.poll(for: "b", sinceSequence: firstPoll[0].sequence)
    #expect(onlySecond.map(\.text) == ["second"])
}

@Test("sending to an unregistered client id throws unknownRecipient")
func unknownRecipientRejected() async { /* ... */ }

@Test("text over the cap, too many fileRefs, and a full recipient mailbox are each rejected before storing")
func capsEnforced() async throws {
    // text: String(repeating: "x", count: ProviderMailbox.maxTextBytes + 1) -> throws .textTooLarge
    // fileRefs: an array one longer than maxFileRefsPerMessage -> throws .tooManyFileRefs
    // send maxPendingPerClient messages to "b", then one more -> throws .recipientMailboxFull
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
@Test("the mailbox's public send signature has no way to assert a different sender than the resolved client id")
func fromIsNotASeparateCallerControlledField() async throws {
    // This is a regression guard on ProviderMailbox's own shape, not the full enforcing test —
    // the end-to-end proof that a tool call's "from" argument is ignored belongs to Task 8, which
    // drives this through the actual MCP tool wiring (dev-2 Gap 5: this task's version "should
    // already pass" by construction and does not, on its own, prove the wiring is safe). Call
    // send(from: resolvedId, ...) and confirm the stored Message's `from` equals exactly what was
    // passed; there is no second parameter or arguments bag this signature could pull an
    // overriding "from" out of.
}

@Test("sweepExpired removes only messages past the TTL; purge removes everything for one client id")
func sweepAndPurge() async throws { /* backdate via an injectable now:, as Task 7's store does */ }
```

- [ ] **Step 6: Run both; this task's `from` test should already pass by construction (fix if it doesn't — that means something let a second identity in); implement and verify `sweepExpired`/`purge` pass**

Run: `scripts/test-filter.sh ProviderMailboxTests`
Expected: PASS, test count ≥ 5

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
- Produces: `actor ProviderArtifactStore` with:
  - `static let maxBytesPerObject = 8 * 1024 * 1024` (8 MiB for Phase 1, **not** romar's 64 MiB conformance baseline — dev-2 Gap 7: a 64 MiB inline-base64 `artifact_put` body is ~86 MB resident per request once base64-decoded and wrapped in the SDK's `Value`, with no per-request concurrency cap in front of it yet; romar's 64 MiB figure was sized for a different transport) as a named constant.
  - `static let ttl: TimeInterval = 7 * 24 * 60 * 60` (7 days, matching romar's object TTL, §3.6) as a named constant.
  - `static let perClientDailyBytes = 200 * 1024 * 1024`, `static let totalStoreCapBytes = 2048 * 1024 * 1024` (dev-2 Gap 7 — mirroring `ArtifactLimits.sessionDailyBytes`/`.defaultExchangeCapMB` at `Sources/IrisKit/Artifacts.swift:56-60`, 200 MiB/day per client and a 2 GiB total ceiling for the whole store, so a registered client cannot fill the disk; `put` rejects with `.quotaExceeded` once either is hit, computed from this store's own bookkeeping — never `ArtifactStore`'s).
  - `func put(bytes: Data, from clientId: String) throws -> String` — rejects (`ArtifactError.tooLarge`) over `maxBytesPerObject`, rejects (`.quotaExceeded`) if it would put `clientId` over `perClientDailyBytes` for the current day or the store over `totalStoreCapBytes`; computes `SHA256.hash(data:)` (CryptoKit) hex string as the key, writes `bytes` under a directory scoped to this store (not the conversation `ArtifactStore`'s directory — Global Constraints), records `(sha256, storedAt, sizeBytes)`, **and initializes that object's authorized-reader set to `{clientId}`** — the uploader can always read back what it uploaded — returns the hex sha256.
  - `func authorize(sha256: String, by senderId: String, adding clientIds: Set<String>) throws` — **validates `sha256` is 64 lowercase hex digits first** (dev-2 Gap 4 — reject anything else as `.invalidHash` before it ever reaches a file path), then throws `.notFound` if the object doesn't exist, **throws `.unauthorized` unless `senderId` is already in that object's authorized-reader set** (dev-2 Gap 4, closing the hole in the planner's own PR #1068 fix: `authorize(sha256:adding:)` with no sender check let any client who merely *learned* a hash grant a third party a read, which is exactly the §7.6 B violation this ACL was built to close), otherwise unions `clientIds` into that object's authorized-reader set. Populated by Task 8's `iris_send` wiring (not by this task) at the point a message carrying `fileRefs` is actually sent, passing the **resolved sender's** client id as `senderId` — never a caller-supplied one.
  - `func get(sha256: String, requestingClientId: String) throws -> Data` — validates `sha256` the same way as `authorize`; throws `.notFound` if the object doesn't exist, **`.unauthorized` if `requestingClientId` is not in that object's authorized-reader set** — knowing the hash is no longer sufficient on its own.
  - `func sweepExpired(now: Date = Date())` — deletes every stored object whose `storedAt` is older than `ttl`, and removes its bookkeeping record (including its authorized-reader set and its contribution to the per-client daily bytes bookkeeping). Called on a timer from Task 8's lifecycle wiring, not from `ArtifactStore.sweep` (Global Constraints — this store's sweep is independent).

- [ ] **Step 1: Write the failing tests for put/get round-trip, SHA verification, and the authorized-reader ACL — including the directed version (Gap 4)**

```swift
@Test("the uploader can always read its own object; an unauthorized client cannot, even knowing the hash")
func putGetACLEnforced() throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    let sha = try store.put(bytes: Data("hello".utf8), from: "a")
    #expect(try store.get(sha256: sha, requestingClientId: "a") == Data("hello".utf8))
    #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
        try store.get(sha256: sha, requestingClientId: "b")  // knows the hash, was never authorized
    }
    try store.authorize(sha256: sha, by: "a", adding: ["b"])
    #expect(try store.get(sha256: sha, requestingClientId: "b") == Data("hello".utf8))  // now readable
    #expect(throws: ProviderArtifactStore.ArtifactError.notFound) {
        try store.get(sha256: String(repeating: "0", count: 64), requestingClientId: "a")
    }
}

@Test("a client who only learned the hash cannot grant anyone else a read (Gap 4)")
func authorizeRequiresSenderAlreadyAuthorized() throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    let sha = try store.put(bytes: Data("hello".utf8), from: "a")  // "a" holds it; "c" and "b" do not
    #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
        try store.authorize(sha256: sha, by: "c", adding: ["b"])  // "c" was never authorized itself
    }
    #expect(throws: ProviderArtifactStore.ArtifactError.unauthorized) {
        try store.get(sha256: sha, requestingClientId: "b")  // "c"'s attempted grant must not have landed
    }
}

@Test("a malformed sha256 is rejected before touching the filesystem")
func malformedHashRejected() throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    #expect(throws: ProviderArtifactStore.ArtifactError.invalidHash) {
        try store.get(sha256: "../../etc/passwd", requestingClientId: "a")
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

- [ ] **Step 5: Write the failing test for the oversize rejection, the per-client/total quota, and the TTL sweep**

```swift
@Test("an object over the size cap is rejected before any write")
func oversizeRejected() throws { /* put bytes of size maxBytesPerObject + 1 -> throws .tooLarge, file not created */ }

@Test("a client's own daily quota and the store's total cap are each enforced")
func quotasEnforced() throws {
    // Drive one client past perClientDailyBytes across several put() calls -> .quotaExceeded,
    // while a second client's own put still succeeds (quota is per-client). Separately, drive
    // several clients' puts past totalStoreCapBytes in aggregate -> .quotaExceeded for whichever
    // call crosses it, regardless of which client makes it.
}

@Test("sweepExpired reclaims an object past its TTL and leaves a fresh one alone")
func sweepReclaimsOnlyExpired() throws {
    // Write one object, backdate its stored record past `ttl` via an injectable clock/now
    // parameter (constructor-inject a `now: @Sendable () -> Date` the same way other stores in
    // this codebase inject time — grep for an existing pattern before adding a new one), write a
    // second fresh object, sweep, assert only the expired one is gone.
}
```

- [ ] **Step 6: Run them, verify they fail, implement, verify they pass**

Run: `scripts/test-filter.sh ProviderArtifactStoreTests`
Expected: PASS, test count ≥ 7

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderArtifactStore.swift Tests/irisTests/MCPProvider/ProviderArtifactStoreTests.swift
git commit -m "feat: #1067 provider-scoped content-addressed artifact store, directed ACL, quotas, TTL sweep"
```

---

## Task 8: MCP server wiring and app lifecycle

**Files:**
- Create: `Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift`
- Create: `Tests/irisTests/MCPProvider/IrisMCPProviderServerTests.swift`
- Modify: `Sources/IrisKit/IrisApp.swift` (or wherever the app's startup sequence already lives — grep for where `StatusItem`/`LaunchGate` wire up at launch, and add the provider's start/stop beside them, gated on `ConfigManager.shared.mcpProviderEnabled`)

**Architecture, revised per dev-2's review of PR #1068 (blockers 1 & 2 — see "SDK spike findings" above):** this task does **not** build one long-lived `MCP.Server`. It builds a **per-request** `MCP.Server` + `StatelessHTTPServerTransport` pair, constructed fresh inside the listener's `handle` closure after that request's bearer token has already been resolved to a client id. Auth is checked on the raw `HTTPRequest`, before any SDK type exists, so `initialize`/`tools/list`/`ping` get no free pass (dev-2 Gap 3) and there is no shared `httpRequestContexts`/`responseWaiters` keyspace left for two clients' JSON-RPC ids to collide in (blocker 2 is structurally impossible here, not merely mitigated).

**Interfaces:**
- Consumes: Tasks 1–7 in full: `ProviderTokenRegistry`, `LoopbackHTTPListener`, `ProviderRequestGate` (two instances — door and mailbox), `SelfReportDoor`, `DiagnosticEventRing.shared`, `ProviderMailbox`, `ProviderArtifactStore`. Also `MCP.Server` (`init(name:version:configuration:)` — use `.default`, i.e. `strict: false`, confirmed in the spike above to accept a bare `tools/call` on a never-initialized `Server`; `withMethodHandler(ListTools.self) { ... }`, `withMethodHandler(CallTool.self) { ... }`, `withMethodHandler(ListResources.self) { ... }`, `withMethodHandler(ReadResource.self) { ... }`, `start(transport:)`) and `MCP.StatelessHTTPServerTransport.handleRequest(_:)` (Task 2's already-confirmed citation).
- Produces: `final class IrisMCPProviderServer: Sendable` with:
  - `init(tokenRegistry: ProviderTokenRegistry, mailbox: ProviderMailbox, artifactStore: ProviderArtifactStore, door: SelfReportDoor, doorGate: ProviderRequestGate, mailboxGate: ProviderRequestGate, port: UInt16)`
  - `func start() async throws` — builds a `LoopbackHTTPListener(port: port, handle: handleAuthenticated)` where `handleAuthenticated` is this class's own method, **not** a bare `transport.handleRequest` reference (that was the pre-spike shape; it no longer applies):
    1. Read the `Authorization` header off the raw `HTTPRequest` directly (`request.header("Authorization")`); strip a `Bearer ` prefix if present.
    2. Call the request's appropriate `ProviderRequestGate.admit(bearerToken:)` — which gate depends on which tool the request's JSON-RPC body names, so the body must be peeked (parsed once) before picking door-gate vs. mailbox-gate; `initialize`/`tools/list`/`ping` have no tool name to dispatch on, so they go through **both** gates' `admit` only to the extent of resolving a valid client id — reject outright (401, no gate-specific budget consumed) if the token resolves to no client id at all, before looking at the method name. On `.unauthorized`/`.budgetExceeded`, return the appropriate HTTP error response **immediately**, having constructed no `MCP.Server`, called no tool handler, and made no MainActor hop.
    3. On `.admitted(clientId:)`, construct a fresh `MCP.Server(name: "iris", version: ..., configuration: .default)` and a fresh `StatelessHTTPServerTransport()`. Register this request's handlers — the 6 door tools (`iris_window_owner`, `iris_responder_class`, `iris_composer_state`, `iris_turn_state`, `iris_activation_state`, `iris_event_ring` — one per `SelfReportDoor.Query` case) each calling `door.handle(query:bearerToken:)` with the **already-resolved** token (no need to re-extract it from `Server.currentHandlerContext?.httpContext` — this request already has it); 4 mailbox tools (`iris_send`, `iris_poll`, `iris_discover`, `iris_status`) each closed over the **resolved `clientId`** from step 2, never reading a `from`/`clientId` argument out of the tool call's own arguments (dev-2 Gap 5/provenance — `iris_send`'s handler calls `mailbox.send(from: clientId, to: <argument>, ...)`, with `clientId` coming only from the closure capture); the `iris_send` handler, after a successful `mailbox.send`, calls `artifactStore.authorize(sha256: ref, by: clientId, adding: [to])` for every `ref` in that message's `fileRefs` (dev-2 Gap 4 — `by: clientId` is the resolved sender, so a client cannot name a hash it does not hold and grant someone else access to it); a `resources/read` handler resolving `iris-artifact://<sha256>` URIs to `artifactStore.get(sha256:requestingClientId: clientId)`; an `artifact_put` tool calling `artifactStore.put(bytes:from: clientId)` (inline base64 bytes in the tool call arguments, capped by `LoopbackHTTPListener.maxContentLength` upstream and `ProviderArtifactStore.maxBytesPerObject` here, never a host path — Global Constraints).
    4. Call `try await server.start(transport: transport)` once (the SDK's own usage docstring on `StatelessHTTPServerTransport` requires this before `handleRequest` is ever called — it registers the default handlers and connects the transport's incoming stream), then call `transport.handleRequest(request)` exactly once and return its `HTTPResponse`. Let `server` and `transport` fall out of scope.
    5. On `ProviderTokenRegistry.revokeToken` (surfaced however Task 1's revoke path is driven), call `mailbox.purge(clientId:)` and leave `artifactStore`'s existing authorized-reader sets alone (revoking access to *future* sends, not retroactively erasing grants already made — Task 1 asks the implementer to decide and document which; this plan's position is: purge the mailbox, leave the store, since the store's own TTL already bounds how long a stale grant can matter).
    Also schedules `artifactStore.sweepExpired()` and `mailbox.sweepExpired()` on a repeating timer matching `AppState.sweepArtifacts`'s own cadence ("at launch, and daily through the maintenance hook" — `AppState.swift:3002-3009`).
  - `func stop() async`.
- The app-lifecycle modification instantiates one `IrisMCPProviderServer` and calls `start()`/`stop()` as `ConfigManager.shared.mcpProviderEnabled` flips, mirroring however the existing sandboxing toggle's `didSet` already drives a side effect (if it drives one directly; if `enableSandboxing` is read lazily instead, follow whatever wiring pattern an adjacent toggle-that-does-start-something uses instead — identify one by grep before copying).

- [ ] **Step 1: Write the failing tests that an unauthorized call to each of `initialize`, `tools/list`, `ping`, and a tool call is rejected before any `MCP.Server` is constructed and before `SelfReportDoor.handle`/`mailbox` is touched (dev-2 Gap 3 — Review Focus item 1 now explicitly covers the non-tool-call methods too)**

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: fails to compile

- [ ] **Step 3: Implement `IrisMCPProviderServer.handleAuthenticated` through the auth step only (no `MCP.Server` construction yet)**

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS

- [ ] **Step 5: Write the failing test confirming blocker 1 is actually fixed: two successive `initialize` calls, from what look like two different clients, both succeed against this server (where one shared `Server` would throw "already initialized" on the second)**

```swift
@Test("two clients can each initialize without the second failing on \"already initialized\"")
func secondClientInitializeSucceeds() async throws {
    // Issue tokens for "a" and "b". Drive an `initialize` request as "a" through
    // handleAuthenticated, then a second, unrelated `initialize` request as "b". Assert both
    // succeed (this is the blocker-1 regression test: the pre-spike one-shared-Server shape would
    // make the second throw MCPError.invalidRequest("Server is already initialized")).
}
```

- [ ] **Step 6: Run it, verify it fails against a naive single-shared-`Server` implementation (confirm the regression is real before fixing it — write the naive version first if it isn't already the thing Step 3 built, see it fail here, then move to the per-request shape), implement the full per-request `Server`+`transport` construction, verify it passes**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS, test count ≥ 3

- [ ] **Step 7: Write the failing end-to-end test: start the server on a real (test) port, issue a token, POST a `tools/call` for `iris_discover` over real HTTP, assert the registered client list comes back**

- [ ] **Step 8: Write the failing tests for the file-sharing ACL composition, including the Gap-4 negative case at the full wiring level (not just inside Task 7's own store tests)**

```swift
@Test("sending a file reference authorizes its recipient, but nobody else")
func sendAuthorizesRecipientOnly() async throws {
    // registry has clients "a", "b", "c"; "a" calls artifact_put (gets sha), then iris_send to
    // "b" with fileRefs: [sha]; assert artifactStore.get(sha256: sha, requestingClientId: "b")
    // now succeeds, and artifactStore.get(sha256: sha, requestingClientId: "c") still throws
    // .unauthorized.
}

@Test("a client cannot name another client's object in a send and thereby grant a third client access")
func sendCannotGrantAccessToAnUnheldHash() async throws {
    // "a" calls artifact_put (gets sha; only "a" holds it). "c" (who was never authorized for sha)
    // calls iris_send to "b" with fileRefs: [sha]. Assert the send itself is refused (or at least
    // that it does not call authorize successfully) and that artifactStore.get(sha256: sha,
    // requestingClientId: "b") still throws .unauthorized afterward — the clientId closed over in
    // "c"'s request is "c", so Task 7's authorize(by: "c", ...) throws .unauthorized, and this
    // test is what proves that failure actually blocks the send end-to-end rather than being
    // silently swallowed by the wiring.
}
```

- [ ] **Step 9: Write the failing test that `iris_send`'s `from` and `iris_poll`'s caller identity are always the gate-resolved `clientId`, never read from the tool call's own arguments, even if an argument named `from`/`clientId` is present in the call (dev-2 Gap 5 — this is the real enforcing test Task 6 Step 5 could only gesture at)**

```swift
@Test("a tool call argument named from or clientId is ignored; provenance is the resolved token's client id")
func toolArgumentsCannotOverrideResolvedIdentity() async throws {
    // Drive an iris_send call as client "a" whose JSON-RPC arguments include an extra "from": "b"
    // key (arguments the schema doesn't declare but the handler might carelessly read with a
    // dictionary subscript); assert the stored Message's `from` is "a", not "b".
}
```

- [ ] **Step 10: Run Steps 7-9's tests, verify they fail, wire the remaining pieces until they pass**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS, test count ≥ 7

- [ ] **Step 11: Wire the app-lifecycle start/stop, and the revoke→`mailbox.purge` call; add a test (or, if the app-lifecycle file has no existing test harness for this kind of toggle, note in the ledger that this one piece is verified by manual GUI check only, flagged for the task reviewer)**

- [ ] **Step 12: Run the full warnings-clean build**

Run: `scripts/check-warnings.sh`
Expected: exit 0

- [ ] **Step 13: Run the full suite**

Run: `swift test --no-parallel`
Expected: all green, note the total test count

- [ ] **Step 14: Commit**

```bash
git add Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift Sources/IrisKit/IrisApp.swift Tests/irisTests/MCPProvider/IrisMCPProviderServerTests.swift
git commit -m "feat: #1067 wire the MCP provider server (per-request Server+transport) + app lifecycle toggle"
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

Confirm explicitly: (1) no task's code path reads `Conversation.history`, `AppState.peerDepths`, `AppState.peerRateLimiter`, `AppState.inboxEmitRateLimiter`, or calls `queuePeerArrival`/`startTurn`/`send_to_session`/`inbox_item` — Phase 1 must not touch any of the §3.2/§3.5 machinery, by design; (2) the self-report door's MainActor hop is always raced via `withTimeout`, never a bare `MainActor.run` with no deadline; (3) the loopback listener binds via `NWParameters.requiredLocalEndpoint` at construction time AND refuses non-loopback connections as a second layer (Task 2, Steps 5-6) — both, not either; (4) no window title, `stringValue`, transcript text, memory, or file content appears in any self-report door response (grep every `Snapshot`/`Value` construction site); (5) `ProviderArtifactStore` and `ProviderMailbox` are entirely separate storage from the conversation-scoped `ArtifactStore`/`artifact_refs` — no accidental reuse of either; (6) `ProviderArtifactStore.get` never succeeds for a client absent from the object's authorized-reader set, even with the correct hash — a bare hash must not grant a read; (7) `DiagnosticEventRing.record`/`.snapshot` are synchronous and lock-guarded, never routed through `Task { await ... }` from a sync AppKit callback — the ring's whole purpose is preserving event order; (8) **no `MCP.Server` instance in Task 8's wiring is ever reused across more than one `handleAuthenticated` call** — grep for exactly one `MCP.Server(` construction site and confirm it sits inside the per-request closure, not hoisted to `IrisMCPProviderServer.start()` or a stored property (dev-2 blocker 1); (9) **auth (`ProviderRequestGate.admit`) runs before that construction site, on every method** — `initialize`, `tools/list`, and `ping` included, not just tool calls (dev-2 Gap 3); (10) `ProviderArtifactStore.authorize` is never called with a `by:` argument the caller supplied — only with the gate-resolved `clientId` from that request's own closure (dev-2 Gap 4); (11) every `sha256` string that reaches `ProviderArtifactStore`'s filesystem calls passed the 64-lowercase-hex check first; (12) `ProviderMailbox.poll` is called with `sinceSequence`, never a `Date`-keyed cursor, anywhere in Task 8's wiring; (13) the listener's request-line/header/`Content-Length`/read-timeout caps (Task 2) and the artifact store's per-client/total quotas (Task 7) are each backed by a named constant and an enforcing test, not left as narrative "bounded" language.
