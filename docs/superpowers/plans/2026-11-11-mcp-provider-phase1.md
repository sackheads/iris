# Iris MCP Provider — Phase 1 (Shape 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a loopback, token-gated MCP **provider** on the running Iris app: a read-only app-level self-report door (window/responder/composer/turn/activation snapshots + an event ring buffer) plus a plain messaging/file-exchange mailbox between registered local clients — with no role-session turns, no model access, and no Conversation/history reads anywhere in the surface.

**Architecture:** A new `Sources/IrisKit/MCPProvider/` module hosts a `MCP.Server` (from the existing `swift-sdk` dependency) behind a hand-rolled loopback-only HTTP/1.1 listener that bridges raw socket bytes to the SDK's framework-agnostic `StatelessHTTPServerTransport`. Bearer tokens are Keychain-bound (one per registered client), checked and rate/concurrency-budgeted *before* any MainActor hop. The self-report door reads live AppKit/AppState through a small set of enumerated, bounded queries raced against a dispatch-timer deadline (`withTimeout`, never `Task.sleep`, per Invariant 4). The mailbox and file exchange are a standalone actor with their own content-addressed store and TTL sweep — intentionally outside `Conversation`/`AppState.history`, so nothing here touches shared turn state, the peer-cascade budget, or the taint model.

**Tech Stack:** Swift 6, `swift-sdk` (MCP) `Server`/`StatelessHTTPServerTransport`, `Network.framework` (`NWListener`) for the loopback socket, `KeychainManager` for token storage, `CryptoKit` for SHA-256 content addressing, Swift Testing.

**Spec:** `docs/specs/2026-11-11-iris-devteam-mcp-collaboration-design.md` (PR #1063, head `fa89958b`) — read §3.1, §3.3, §3.4, §3.6, §3.7, §3.8. Scope and guardrails: issue #1067. Neighbouring (unbuilt, not used by Phase 1): `docs/superpowers/specs/2026-11-08-iris-local-agent-mcp-design.md` (#964, branch `design/iris-local-agent-mcp`).

**Design resolution (planner-confirmed 2026-11-11, vetoable by Brian):** §1067's "send/poll/discover/status... no role-session turns in Phase 1" leaves open what `send` addresses, since #964's role-session/inbox delivery is explicitly out of scope here. This plan resolves it as **client-to-client relay**: `send`/`poll`/`discover`/`status` operate over a flat registry of tokens issued to local MCP clients (the dev-team sessions), with no session, role, or Conversation on either end — the mailbox is new, standalone state, never `AppState`. This sidesteps every §3.2 confidentiality problem (no shared history, no principal, no model in the loop) and matches "serves the debugging motivator with no confidentiality exposure" (§5). Dev↔Iris-*agent* messaging needs a role-session turn, which is Shape 5 — Phase 2, gated on #1066 — and this plan does not build it.

This is infra investment, not throwaway: Task 1's per-token registry, Task 3's auth/budget gate, Task 6's send/poll/provenance machinery, and Task 7's content-addressed store are the exact scaffold Phase 2's dev↔Iris messaging reuses once #1066's context partitioning lands — Phase 2 adds a role-session-addressed delivery path on top of this, it does not replace it.

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

## Review Focus

- **A client with no token, an expired token, or a token for a different client sends a request.** Expected: 401 before any tool dispatch, no MainActor hop, no budget consumed. No task in this plan tests a wrong-but-well-formed token distinct from a missing one — Task 1 should.
- **The loopback listener receives a non-HTTP byte stream, a truncated request, or a request with a huge/absent `Content-Length`.** Expected: the connection is closed or answered with an error; the listener itself never hangs, crashes, or blocks other connections. Task 2 owns this.
- **The self-report door is called while Iris is backgrounded (not key/active).** Expected: the snapshot still returns, tagged with its own activation state, rather than silently reporting "not key" as if the queried fact itself were false (§3.7 key-window subtlety). Task 4 owns this.
- **A client floods the self-report door faster than its rate/concurrency budget allows.** Expected: requests over budget are rejected at the entry point before the MainActor hop — never queued, never left to time out on the main actor race. Task 3's budget gate, exercised by Task 4's door, must have a test proving rejection happens pre-hop (e.g. a budget-exhausted call makes zero calls into the MainActor-racing code path).
- **A registered client disconnects (or is revoked) with files still in the guest artifact store.** Expected: those blobs are reclaimed by the store's own TTL sweep without needing a `Conversation` row or `deleteConversation` call. Task 6 owns this.

---

## Task 1: Provider token registry and feature toggle

**Files:**
- Create: `Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift`
- Create: `Tests/irisTests/MCPProvider/ProviderTokenRegistryTests.swift`
- Modify: `Sources/IrisKit/ConfigManager.swift` (add `mcpProviderEnabled: Bool` and `mcpProviderPort: Int`, same pattern as `enableSandboxing` at `ConfigManager.swift:303-305` — new `didSet { persistGuarded(...) }` pair, new cases in whatever key enum `persistGuarded` takes)

**Interfaces:**
- Produces: `ProviderTokenRegistry`, a `final class ... : @unchecked Sendable` (mirroring `KeychainManager`'s own concurrency shape) with:
  - `func issueToken(forClientId clientId: String) -> String` — generates a token (`UUID().uuidString`), stores `[clientId: token]` into the Keychain under a new service `KeychainManager.mcpProviderService = "iris.mcp.provider"` via `KeychainManager.shared.updateSecretsOrThrow(service:_:)`, returns the token.
  - `func revokeToken(forClientId clientId: String)` — removes that client's entry via the same `updateSecretsOrThrow` pattern.
  - `func clientId(forToken token: String) -> String?` — reverse lookup, loaded via `KeychainManager.shared.secretsOrThrow(service:)`.
  - `func allClientIds() -> [String]` — every registered client id (backs `discover` in Task 5).
  - `init(keychain: KeychainManager = .shared)` — injectable for tests, per `AGENTS.md` Invariant 7 (never touch `KeychainManager.shared` from a test).
- Consumes: `KeychainManager.updateSecretsOrThrow(service:_:)`, `.secretsOrThrow(service:)`, `.deleteSecrets(service:)` (existing, `Sources/IrisKit/KeychainManager.swift`).

- [ ] **Step 1: Write the failing test for issue/lookup/revoke round-trip**

```swift
@Test("issuing a token makes it resolve back to the client id, and revoking removes it")
func issueLookupRevoke() throws {
    let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
    let registry = ProviderTokenRegistry(keychain: keychain)
    let token = registry.issueToken(forClientId: "iris-dev-1")
    #expect(registry.clientId(forToken: token) == "iris-dev-1")
    #expect(registry.allClientIds() == ["iris-dev-1"])
    registry.revokeToken(forClientId: "iris-dev-1")
    #expect(registry.clientId(forToken: token) == nil)
}
```

Check `KeychainManager`'s initializer: if `serviceSuffix:` is not a public/internal initializer usable from the test target, use whatever injectable constructor it already exposes for test isolation (grep existing `KeychainManager(` call sites in `Tests/irisTests/` for the established pattern — do not add a new one).

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh ProviderTokenRegistryTests`
Expected: fails to compile (`ProviderTokenRegistry` undefined) or runs 0 tests — confirm the script reports a non-zero test count once Step 3 exists, not before.

- [ ] **Step 3: Implement `ProviderTokenRegistry` in `Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift`, and `KeychainManager.mcpProviderService`**

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-filter.sh ProviderTokenRegistryTests`
Expected: PASS, test count > 0

- [ ] **Step 5: Add `mcpProviderEnabled`/`mcpProviderPort` to `ConfigManager`, with a test following the existing settings-persistence test pattern for `enableSandboxing` (grep `Tests/irisTests/` for its test and mirror it with an isolated `ConfigManager(store:)`, per Invariant 7)**

- [ ] **Step 6: Run the new ConfigManager test; verify it passes**

Run: `scripts/test-filter.sh ConfigManagerTests` (or whatever suite the mirrored test lives in)
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderTokenRegistry.swift Sources/IrisKit/KeychainManager.swift Sources/IrisKit/ConfigManager.swift Tests/irisTests/MCPProvider/ProviderTokenRegistryTests.swift Tests/irisTests/ConfigManagerTests.swift
git commit -m "feat: #1067 provider token registry + feature toggle"
```

---

## Task 2: Loopback HTTP listener bridging to the MCP SDK transport

**Files:**
- Create: `Sources/IrisKit/MCPProvider/LoopbackHTTPListener.swift`
- Create: `Tests/irisTests/MCPProvider/LoopbackHTTPListenerTests.swift`

**Interfaces:**
- Consumes: `MCP.StatelessHTTPServerTransport` (`.build/checkouts/swift-sdk/Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift`) — specifically its `handleRequest(_ request: HTTPRequest) async -> HTTPResponse` entry point (confirm the exact method name and signature by reading that file; the SDK's doc comment in the same file shows the intended call shape) and the `HTTPRequest`/`HTTPResponse` types from `HTTPServerTypes.swift`.
- Produces: `final class LoopbackHTTPListener: Sendable` with:
  - `init(port: UInt16, handle: @escaping @Sendable (HTTPRequest) async -> HTTPResponse)` — `handle` is the transport's `handleRequest`, injected so this task's tests never need a real `MCP.Server`.
  - `func start() throws` — opens an `NWListener` on `NWEndpoint.Port(rawValue: port)` with `NWParameters.tcp`, and **asserts/guards the listener's parameters restrict to loopback** (`NWParameters` has no "interface allow-list" for TCP by default on macOS — bind explicitly to the loopback `NWEndpoint.Host("127.0.0.1")` by using `NWListener(using:on:)` is port-only; loopback-only must instead be enforced by accepting a connection and checking `connection.endpoint`'s remote host is `127.0.0.1`/`::1`, rejecting (canceling) any other — write this check explicitly and test it).
  - `func stop()`.
  - A minimal HTTP/1.1 request-line + header + `Content-Length`-bounded body parser, reading from an `NWConnection`'s receive loop into an `HTTPRequest`, and a response writer serializing `HTTPResponse.statusCode`/`.headers`/`.bodyData` back as raw bytes. (This parser is net-new, hand-rolled, and intentionally minimal: POST only, no chunked transfer-encoding, no keep-alive required for a single local client.)

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

- [ ] **Step 5: Write the failing test for a connection from a non-loopback remote address being refused**

```swift
@Test("a connection whose remote endpoint is not loopback is refused, not served")
func nonLoopbackRefused() async throws {
    // Exercise the endpoint-check path directly (unit-test the predicate function extracted
    // from start()'s connection handler) rather than trying to fake a non-loopback NWConnection,
    // which the test process cannot originate. Name the predicate so it's testable in isolation,
    // e.g. `static func isLoopback(_ endpoint: NWEndpoint) -> Bool`.
}
```

- [ ] **Step 6: Run it, verify it fails, implement `LoopbackHTTPListener.isLoopback(_:)`, run again, verify it passes**

Run: `scripts/test-filter.sh LoopbackHTTPListenerTests`
Expected: PASS, test count ≥ 2

- [ ] **Step 7: Write the failing test for a malformed/truncated request not hanging or crashing the listener**

```swift
@Test("a truncated request closes its connection without affecting a later well-formed one")
func truncatedRequestDoesNotWedgeListener() async throws {
    // Open a raw TCP connection to the listener's port, write a partial request line, close it.
    // Then issue a normal POST (as in postRoundTrips) and assert it still succeeds.
}
```

- [ ] **Step 8: Run it, verify it fails if the parser currently hangs or the listener dies; fix; verify it passes**

Run: `scripts/test-filter.sh LoopbackHTTPListenerTests`
Expected: PASS, test count ≥ 3

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
  - `init(registry: ProviderTokenRegistry, capacity: Int, refillInterval: Duration)` — a token-bucket per client id, same shape as `AppState.PeerRateLimiter` (grep `Sources/IrisKit/AppState.swift` for `PeerRateLimiter`'s `take(for:)`/`refund(for:)` and mirror its bucket algorithm rather than reinventing one — but this is a **new, separate** limiter instance; it must never read or write `AppState.peerRateLimiter` or `AppState.inboxEmitRateLimiter`, per this plan's Global Constraints).
  - `enum Admission: Equatable { case admitted(clientId: String); case unauthorized; case budgetExceeded }`
  - `func admit(bearerToken: String?) async -> Admission` — resolves the token to a client id (bare lookup, no network/MainActor work), then takes one unit from that client's bucket; `nil`/unresolvable token → `.unauthorized` without touching the bucket at all.
- Produced for: Task 4 (the self-report door) and Task 5 (the mailbox) both call `admit(bearerToken:)` **before** any MainActor hop or mailbox mutation; each gets its **own** `ProviderRequestGate` instance with its own capacity (Global Constraints — the door's budget is distinct from the mailbox's).

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
- Produces: `actor DiagnosticEventRing` with:
  - `static let capacity = 200` (named constant — Global Constraints; pick this value or another explicit one, but it must be named, not implicit).
  - `enum Event: Sendable { case transcriptMouseDown(atWindowPoint: CGPoint); case transcriptFocusHop(tookFocus: Bool); case composerAcceptsFirstMouse(Bool); case windowAppearanceChanged(name: String); case composerAppearanceChanged(name: String) }` — no free-text, no titles, no `stringValue` (Global Constraints).
  - `struct Entry: Sendable { let timestamp: Date; let event: Event }`
  - `func record(_ event: Event)` — appends, dropping the oldest entry once `capacity` is exceeded.
  - `func snapshot() -> [Entry]` — returns entries oldest-first, read by Task 6's `iris_event_ring` tool.
  - `static let shared = DiagnosticEventRing()` — one process-wide ring, written from multiple AppKit callbacks; injected nowhere else, so Task 4's own tests construct their own instance (`DiagnosticEventRing()`), never `.shared`.
- Consumes: nothing new; `TranscriptFocusAnchor.AnchorView.mouseWentDown(at:)`/`.focusTable(clickedAt:)` and `ComposerTextView`'s `acceptsFirstMouse` call `DiagnosticEventRing.shared.record(...)` as a side effect, synchronously before and after the existing `DispatchQueue.main.async` hop in `AnchorView.viewDidMoveToWindow`'s monitor closure (§3.7 Clomp note: record both pre- and post-hop, since first responder changes only after the hop).

- [ ] **Step 1: Write the failing test for bounded capacity**

```swift
@Test("the ring drops the oldest entry once it exceeds capacity")
func dropsOldestPastCapacity() async {
    let ring = DiagnosticEventRing()
    for i in 0..<(DiagnosticEventRing.capacity + 10) {
        await ring.record(.composerAcceptsFirstMouse(i.isMultiple(of: 2)))
    }
    let entries = await ring.snapshot()
    #expect(entries.count == DiagnosticEventRing.capacity)
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

In `mouseWentDown(at:)`, after setting `downInside`, call `DiagnosticEventRing.shared.record(.transcriptMouseDown(atWindowPoint: point))` (window-local point, not screen — no title, no content). In `focusTable(clickedAt:)`, after the existing `window.makeFirstResponder(table)` call (and also on each early `return` path where focus was *not* taken), record `.transcriptFocusHop(tookFocus:)` with the correct bool for that path. This runs on the main thread already (it's inside the `DispatchQueue.main.async` closure); `DiagnosticEventRing.record` is `async` on an actor, so wrap each call in `Task { await DiagnosticEventRing.shared.record(...) }` from the synchronous AppKit callback.

- [ ] **Step 6: Instrument `ComposerTextView`'s `acceptsFirstMouse` override to record `.composerAcceptsFirstMouse(true)` on every call (it always returns `true` since #1055's fix; recording it anyway gives the ring a timestamped signal that a reactivating click reached the composer)**

- [ ] **Step 7: Add `NSView.effectiveAppearance` observation on the window and the composer's `NSTextView`**

Grep `Sources/IrisKit/ComposerTextView.swift` and `Sources/IrisKit/ChatView.swift` for any existing `viewDidChangeEffectiveAppearance` or KVO on `effectiveAppearance`; if none exists, override `viewDidChangeEffectiveAppearance()` on the composer's `NSTextView` subclass and record `.composerAppearanceChanged(name: effectiveAppearance.name.rawValue)`, and do the equivalent for the main window (its `contentView` or the window itself) recording `.windowAppearanceChanged`. `NSAppearance.Name` is a `String`-backed enum case name (e.g. `"NSAppearanceNameDarkAqua"`), not user content — safe to record verbatim.

- [ ] **Step 8: Run the full `DiagnosticEventRingTests` suite plus the existing `ComposerStashShortcutTests`/`TranscriptFocusAnchorTests` (whatever they are named — grep for the #1055/#703 test suites) to confirm nothing already covering these views regressed**

Run: `scripts/test-filter.sh DiagnosticEventRingTests && scripts/test-filter.sh TranscriptFocusAnchorTests && scripts/test-filter.sh ComposerStashShortcutTests`
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

**Interfaces:**
- Consumes: `ProviderRequestGate.admit(bearerToken:)` (Task 3), `DiagnosticEventRing.shared.snapshot()` (Task 4), `withTimeout(seconds:_:)` (`Sources/IrisKit/Timeout.swift`), `MainWindow.current`/`MainWindow.isFrontmost` (`Sources/IrisKit/StatusItem.swift`), `AppState.hasTurnInFlight(for:)` (`Sources/IrisKit/AppState.swift`), `NSApp.isActive`.
- Produces: `struct SelfReportDoor: Sendable` (a plain `nonisolated` struct — never `@MainActor` itself, per Global Constraints) with:
  - `static let mainActorTimeout: Duration = .milliseconds(500)` (named constant).
  - `enum Query: String, Sendable, CaseIterable { case windowOwner, responderClass, composerState, turnState, activationState, eventRing }`
  - `struct Snapshot: Sendable, Encodable { let query: Query; let isAppActive: Bool; let isKeyWindow: Bool; let value: Value } ` where `Value` is whatever `enum`/struct shape each query needs (bundle id `String` for `.windowOwner`, class name `String` for `.responderClass`, `(enabled: Bool, reason: String?)` for `.composerState`, `Bool` for `.turnState`, `[DiagnosticEventRing.Entry]` for `.eventRing`) — pick a concrete `Codable` shape per query and hold to it; a `[String: Value]`-style untyped bag is not acceptable here (it is exactly the kind of structure the SDK's `Tool.Result.structuredContent: Value` needs you to produce, so define it once and reuse it for every query's JSON encoding).
  - `func handle(query: Query, bearerToken: String?) async -> Result<Snapshot, DoorError>` where `enum DoorError: Error { case unauthorized; case budgetExceeded; case mainActorUnresponsive(afterMilliseconds: Int) }`.
- The `.mainActorUnresponsive` case is the literal diagnosis the spec calls for (§3.7: "main actor unresponsive for N ms" *is* the diagnosis) — never silently time out into a different error.

- [ ] **Step 1: Write the failing test for unauthorized and budget-exceeded short-circuiting before any MainActor work**

```swift
@Test("an unauthorized call never reaches the MainActor hop")
func unauthorizedNeverHopsToMainActor() async {
    // Inject a gate whose admit() always returns .unauthorized; assert handle(...) returns
    // .failure(.unauthorized) and that some MainActor-only probe (a counter incremented only
    // inside the MainActor closure) stayed at zero.
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

- [ ] **Step 3: Implement `SelfReportDoor`, racing each MainActor read against `withTimeout(seconds: 0.5) { ... }` and mapping `TimeoutError` to `.mainActorUnresponsive(afterMilliseconds: 500)`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: PASS

- [ ] **Step 5: Write the failing test that `.windowOwner` never emits anything but a bundle id, and `.responderClass` never emits `stringValue`-shaped content**

```swift
@Test("windowOwner reports only the bundle identifier, never a title")
func windowOwnerBoundsField() async {
    // Inject a fake window-owner reader whose underlying fake window has a title set to
    // something identifiable (e.g. "SECRET CONVERSATION TITLE"); assert the Snapshot's
    // encoded JSON does not contain that string anywhere.
}
```

- [ ] **Step 6: Run it, verify it fails if the implementation reads title anywhere, fix, verify it passes**

Run: `scripts/test-filter.sh SelfReportDoorTests`
Expected: PASS, test count ≥ 4

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/SelfReportDoor.swift Tests/irisTests/MCPProvider/SelfReportDoorTests.swift
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
  - `struct Message: Sendable, Codable { let id: UUID; let from: String; let to: String; let text: String; let fileRefs: [String]; let sentAt: Date }` (`fileRefs` are SHA-256 hex strings into Task 7's store; `from` is always the *resolved* client id from the token, never a client-asserted field — provenance per Global Constraints).
  - `func send(from: String, to: String, text: String, fileRefs: [String]) throws -> Message` — throws `MailboxError.unknownRecipient` if `to` is not in the token registry's known client ids.
  - `func poll(for clientId: String, since: Date?) -> [Message]` — every message addressed `to: clientId` with `sentAt > since` (or all, if `since` is nil), oldest first; **does not delete** on poll (so a second poll after a dropped connection still sees them) — delivery is pull, per #1067's "pull mailbox for replies."
  - `func discover() -> [String]` — `registry.allClientIds()` passthrough.
  - `func status(for clientId: String) -> (pendingCount: Int, lastMessageAt: Date?)`.
- Produced for: Task 8 wires these four as MCP tools.

- [ ] **Step 1: Write the failing tests for send/poll ordering, unknown recipient, and discover/status**

```swift
@Test("poll returns messages addressed to the caller, oldest first, without deleting them")
func pollIsNonDestructivePull() async throws {
    let mailbox = ProviderMailbox(registry: registryWithClients(["a", "b"]))
    _ = try await mailbox.send(from: "a", to: "b", text: "first", fileRefs: [])
    _ = try await mailbox.send(from: "a", to: "b", text: "second", fileRefs: [])
    let firstPoll = await mailbox.poll(for: "b", since: nil)
    #expect(firstPoll.map(\.text) == ["first", "second"])
    let secondPoll = await mailbox.poll(for: "b", since: nil)
    #expect(secondPoll.count == 2)  // not deleted
}

@Test("sending to an unregistered client id throws unknownRecipient")
func unknownRecipientRejected() async { /* ... */ }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-filter.sh ProviderMailboxTests`
Expected: fails to compile

- [ ] **Step 3: Implement `ProviderMailbox`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-filter.sh ProviderMailboxTests`
Expected: PASS

- [ ] **Step 5: Write the failing test that `from` is always the token-resolved id, never a caller-supplied override**

```swift
@Test("the mailbox's public send signature has no way to assert a different sender than the resolved client id")
func fromIsNotASeparateCallerControlledField() async throws {
    // This is really an interface-shape check: assert that the MCP tool wiring (Task 8) never
    // reads a `from` field out of the tool call's arguments — the test here is on
    // ProviderMailbox alone: call send(from: resolvedId, ...) and confirm the stored Message's
    // `from` equals exactly what was passed, no transformation point exists for a caller to
    // inject a second identity. Document in the test's comment that Task 8 is responsible for
    // never forwarding a client-supplied "from" argument into this call.
}
```

- [ ] **Step 6: Run it; this is a documentation-style regression guard, so it should already pass if Step 3's implementation has no such field — if it fails, something let a second identity in; fix and re-run**

Run: `scripts/test-filter.sh ProviderMailboxTests`
Expected: PASS, test count ≥ 3

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderMailbox.swift Tests/irisTests/MCPProvider/ProviderMailboxTests.swift
git commit -m "feat: #1067 provider mailbox — send/poll/discover/status, token-provenanced"
```

---

## Task 7: Guest/client file exchange (content-addressed store + TTL sweep)

**Files:**
- Create: `Sources/IrisKit/MCPProvider/ProviderArtifactStore.swift`
- Create: `Tests/irisTests/MCPProvider/ProviderArtifactStoreTests.swift`

**Interfaces:**
- Produces: `actor ProviderArtifactStore` with:
  - `static let maxBytesPerObject = 64 * 1024 * 1024` (64 MiB — romar's conformance baseline, §3.6) as a named constant.
  - `static let ttl: TimeInterval = 7 * 24 * 60 * 60` (7 days, matching romar's object TTL, §3.6) as a named constant.
  - `func put(bytes: Data, from clientId: String) throws -> String` — rejects (`ArtifactError.tooLarge`) over `maxBytesPerObject`; computes `SHA256.hash(data:)` (CryptoKit) hex string as the key, writes `bytes` under a directory scoped to this store (not the conversation `ArtifactStore`'s directory — Global Constraints), records `(sha256, clientId, storedAt)`, returns the hex sha256.
  - `func get(sha256: String, requestingClientId: String) throws -> Data` — throws `.notFound` if absent; **no ACL beyond existence** in Phase 1 (any registered client can read any sha256 it already knows — it must already have the hash, which is unguessable, and Phase 1 has no `Conversation` row to scope reads to; document this as the deliberate Phase 1 bound, inherited from option (b)'s "same channel, no second surface" but without a conversation-row ACL since none exists here).
  - `func sweepExpired(now: Date = Date())` — deletes every stored object whose `storedAt` is older than `ttl`, and removes its bookkeeping record. Called on a timer from Task 8's lifecycle wiring, not from `ArtifactStore.sweep` (Global Constraints — this store's sweep is independent).

- [ ] **Step 1: Write the failing test for put/get round-trip and SHA verification**

```swift
@Test("a stored object round-trips by its own sha256, and a tampered read is caught")
func putGetRoundTrips() throws {
    let store = ProviderArtifactStore(root: temporaryTestDirectory())
    let sha = try store.put(bytes: Data("hello".utf8), from: "a")
    #expect(try store.get(sha256: sha, requestingClientId: "b") == Data("hello".utf8))
    #expect(throws: ProviderArtifactStore.ArtifactError.notFound) {
        try store.get(sha256: "0000...", requestingClientId: "b")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh ProviderArtifactStoreTests`
Expected: fails to compile

- [ ] **Step 3: Implement `ProviderArtifactStore`**

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-filter.sh ProviderArtifactStoreTests`
Expected: PASS

- [ ] **Step 5: Write the failing test for the oversize rejection and the TTL sweep**

```swift
@Test("an object over the size cap is rejected before any write")
func oversizeRejected() throws { /* put bytes of size maxBytesPerObject + 1 -> throws .tooLarge, file not created */ }

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
Expected: PASS, test count ≥ 4

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/MCPProvider/ProviderArtifactStore.swift Tests/irisTests/MCPProvider/ProviderArtifactStoreTests.swift
git commit -m "feat: #1067 provider-scoped content-addressed artifact store with its own TTL sweep"
```

---

## Task 8: MCP server wiring and app lifecycle

**Files:**
- Create: `Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift`
- Create: `Tests/irisTests/MCPProvider/IrisMCPProviderServerTests.swift`
- Modify: `Sources/IrisKit/IrisApp.swift` (or wherever the app's startup sequence already lives — grep for where `StatusItem`/`LaunchGate` wire up at launch, and add the provider's start/stop beside them, gated on `ConfigManager.shared.mcpProviderEnabled`)

**Interfaces:**
- Consumes: Tasks 1–7 in full: `ProviderTokenRegistry`, `LoopbackHTTPListener`, `ProviderRequestGate` (two instances — door and mailbox), `SelfReportDoor`, `DiagnosticEventRing.shared`, `ProviderMailbox`, `ProviderArtifactStore`. Also `MCP.Server` (`init(name:version:...)`, `withMethodHandler(ListTools.self) { ... }`, `withMethodHandler(CallTool.self) { ... }`, `withMethodHandler(ListResources.self) { ... }`, `withMethodHandler(ReadResource.self) { ... }`, `start(transport:)`) and `MCP.StatelessHTTPServerTransport` (confirm its exact `handleRequest` method name/signature in `.build/checkouts/swift-sdk/Sources/MCP/Base/Transports/HTTPServer/StatelessHTTPServerTransport.swift` before wiring — Task 2 already did this lookup once; reuse that finding rather than re-deriving it).
- Produces: `final class IrisMCPProviderServer: Sendable` with:
  - `init(tokenRegistry: ProviderTokenRegistry, mailbox: ProviderMailbox, artifactStore: ProviderArtifactStore, door: SelfReportDoor, doorGate: ProviderRequestGate, mailboxGate: ProviderRequestGate, port: UInt16)`
  - `func start() async throws` — builds the `MCP.Server`, registers the 6 door tools (`iris_window_owner`, `iris_responder_class`, `iris_composer_state`, `iris_turn_state`, `iris_activation_state`, `iris_event_ring` — one per `SelfReportDoor.Query` case) each extracting the `Authorization` header's bearer token from `Server.currentHandlerContext?.httpContext` (confirmed available per the SDK's `HandlerContext.httpContext`, `Server.swift:300-320`) before calling `door.handle(query:bearerToken:)`; registers 4 mailbox tools (`iris_send`, `iris_poll`, `iris_discover`, `iris_status`), each reading the same header and calling `mailboxGate.admit(bearerToken:)` before touching `mailbox`; registers a `resources/read` handler resolving `iris-artifact://<sha256>` URIs to `artifactStore.get(sha256:requestingClientId:)`, and an `artifact_put` tool for guest→Iris ingest (inline base64 bytes in the tool call arguments, never a host path — Global Constraints); starts `LoopbackHTTPListener(port: port, handle: transport.handleRequest)`; schedules `artifactStore.sweepExpired()` on a repeating timer (e.g. daily, matching `ArtifactStore`'s own sweep cadence — grep it for the exact interval and mirror it).
  - `func stop() async`.
- The app-lifecycle modification instantiates one `IrisMCPProviderServer` and calls `start()`/`stop()` as `ConfigManager.shared.mcpProviderEnabled` flips, mirroring however the existing sandboxing toggle's `didSet` already drives a side effect (if it drives one directly; if `enableSandboxing` is read lazily instead, follow whatever wiring pattern an adjacent toggle-that-does-start-something uses instead — identify one by grep before copying).

- [ ] **Step 1: Write the failing test that an unauthorized `iris_window_owner` call never reaches `SelfReportDoor.handle`**

```swift
@Test("a tool call with a bad bearer token is rejected at the server layer before the door is touched")
func toolCallAuthEnforcedAtServerLayer() async throws {
    // Build an IrisMCPProviderServer with a door whose handle() increments a counter on any
    // call; drive a CallTool request for "iris_window_owner" through the server's registered
    // handler directly (not over the network — call the handler closure the test can reach, or
    // use MCP.InMemoryTransport if the SDK test helpers expose one) with a bad/missing bearer
    // token; assert the counter stayed at zero and the response is an MCP error.
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: fails to compile

- [ ] **Step 3: Implement `IrisMCPProviderServer`**

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS

- [ ] **Step 5: Write the failing end-to-end test: start the server on a real (test) port, issue a token, POST a `tools/call` for `iris_discover` over real HTTP, assert the registered client list comes back**

- [ ] **Step 6: Run it, verify it fails, wire the remaining pieces until it passes**

Run: `scripts/test-filter.sh IrisMCPProviderServerTests`
Expected: PASS, test count ≥ 3

- [ ] **Step 7: Wire the app-lifecycle start/stop; add a test (or, if the app-lifecycle file has no existing test harness for this kind of toggle, note in the ledger that this one piece is verified by manual GUI check only, flagged for the task reviewer)**

- [ ] **Step 8: Run the full warnings-clean build**

Run: `scripts/check-warnings.sh`
Expected: exit 0

- [ ] **Step 9: Run the full suite**

Run: `swift test --no-parallel`
Expected: all green, note the total test count

- [ ] **Step 10: Commit**

```bash
git add Sources/IrisKit/MCPProvider/IrisMCPProviderServer.swift Sources/IrisKit/IrisApp.swift Tests/irisTests/MCPProvider/IrisMCPProviderServerTests.swift
git commit -m "feat: #1067 wire the MCP provider server + app lifecycle toggle"
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

Confirm explicitly: (1) no task's code path reads `Conversation.history`, `AppState.peerDepths`, `AppState.peerRateLimiter`, `AppState.inboxEmitRateLimiter`, or calls `queuePeerArrival`/`startTurn`/`send_to_session`/`inbox_item` — Phase 1 must not touch any of the §3.2/§3.5 machinery, by design; (2) the self-report door's MainActor hop is always raced via `withTimeout`, never a bare `MainActor.run` with no deadline; (3) the loopback listener genuinely refuses non-loopback connections (Task 2, Step 6) and the test proves it via the refusal predicate, not by assuming `NWListener`'s defaults; (4) no window title, `stringValue`, transcript text, memory, or file content appears in any self-report door response (grep every `Snapshot`/`Value` construction site); (5) `ProviderArtifactStore` and `ProviderMailbox` are entirely separate storage from the conversation-scoped `ArtifactStore`/`artifact_refs` — no accidental reuse of either.
