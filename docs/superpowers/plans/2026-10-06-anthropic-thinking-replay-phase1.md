# Anthropic Thinking Replay, Phase 1: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep every Anthropic reply's content blocks as they arrived, and send this turn's thinking blocks back within the turn, so Opus 5.5, Fable 5.1 and Sonnet 5.5 stop losing their reasoning each time a tool result comes back.
- PR 1 stores the blocks and shapes the request (the binding beta header, `input_transformations` logging), and sends no block back.
- PR 2 replays this turn's blocks after the turn's latest prefix edit. A `drop_block` retry, persisted per conversation, is the backstop for edits nobody predicted.

**Architecture:**
- `Content.anthropicBlocks` holds the reply's content array as JSON text.
  - The stream mapper renders it from the blocks it folded. A tool input's `partial_json` goes in verbatim.
  - The non-stream parser cuts the array out of the response bytes.
  - `parts` stays the source for the UI, hooks and other providers.
- A new `AnthropicCapabilities` table decides who gets the beta header. A new `LLMStreamEvent` case carries the blocks through `StreamAssembler`, so the replay path keeps them too.
- In PR 2, `AnthropicClient` splices stored blocks into the body after serialisation. It never re-encodes them, and a reply it cannot echo takes every earlier reply's blocks with it.
- A per-turn `ThinkingReplay` value in `processInputBody` keeps a floor below which no block is sent. Prefix edits raise it, so what is left out is always a front run.
- A 400 that names "bound to a different conversation" is retried once with `drop_block`. The conversation then keeps that setting (`v18_prefix_mismatch_behavior`).

**Tech Stack:** Swift 6, SwiftUI, GRDB (`ConversationStore`), Swift Testing. No new dependencies.

**Spec:** `docs/specs/2026-10-06-anthropic-thinking-replay.md`. It is on branch `docs/314-thinking-spec` (PR #384) and the owner approved it on 2026-10-06. Read `git show origin/docs/314-thinking-spec:docs/specs/2026-10-06-anthropic-thinking-replay.md` §0 decisions 1-7 and §2.1 before any task. "Decision N" below means §0.N. The Vertex probe results (`work`, 2026-10-06, 90 requests) are summarised on PR #384, and the facts this plan uses from them are under **Global Constraints**. Where this plan departs from the spec, see **Plan notes**. Each departure is a proposed ruling for the owner.

**Scope:** spec §3 PRs 1 and 2 only. PRs 3-8 (append-only tools, system and context, images, Phase 2, effort, measurement) get their own plan after this one lands.

## Global Constraints

- **Wire constants, verbatim from the spec and the probe:**
  - Header `anthropic-beta: thinking-binding-controls-2026-08-01`.
  - Body `"thinking": {"type": "adaptive", "block_binding": {"prefix_mismatch_behavior": "drop_block"}}`. `block_binding` is only ever sent inside a `thinking` object of type `adaptive`.
  - The 400 to match: the substring `bound to a different conversation` (MM:1624). The probe confirmed the exact text.
  - The diagnosis header `anthropic-thinking-prefix-mismatch`: "Use it if present; never depend on it" (PTM:146). The probe saw it forwarded on Vertex.
- **The header and the field travel together.** The field without the header is a 400 (`block_binding: Extra inputs are not permitted`), on the API and on Vertex. No code path may send the field without the header.
- **Vertex validates `anthropic-beta`.** An unknown beta is a 400 "Unexpected value(s)". Send a beta only where it is known to be accepted for the route and the model.
  - Direct API: the binding beta goes to `claude-opus-5-5`, `claude-fable-5-1` and `claude-sonnet-5-5`.
  - Vertex: only to `claude-opus-5-5` and `claude-fable-5-1`, the two the probe saw accept it.
  - Never to an unknown id, except on the retry after a binding 400 (decision 4).
- **`input_transformations`:** parse it from `message_start` on streams and from the top level on non-stream responses. Also parse the final `message_delta`: the docs say it carries the array after a mid-stream fallback, though the probe never saw one. Ignore unknown types and reasons (PTM:145).
- **No paid calls.** Every test runs on a scripted client (`RecordingClient`, `FakeLLMClient`) or a scoped mock session (`MockURLProtocol.scopedSession`), and bodies are built with `AnthropicClient.makeURLRequest`, the `RequestDump` path. The probe's `"error"` mode and the paid self-test (spec §2.3) are not part of this plan.
- **Fable 5.1 often doesn't think.** It skipped thinking on short prompts in 12 of 12 probe tries. Storage and replay must handle a reply with no thinking block, and the fixtures include such replies.
- **Never strip blocks on a model switch.** The API drops what the target model can't read, unbilled. The probe saw Fable 5.1 blocks sent to Opus 5.5 dropped as `model_binding_mismatch`. The client sends what the floor allows, whatever the model.
- **Invariant 1.**
  - `Content.anthropicBlocks` uses `decodeIfPresent` and a `CodingKeys` case. History rows are whole-`Content` JSON, so it needs no column.
  - `Conversation.prefixMismatchBehavior` needs both halves: `decodeIfPresent` in `Conversation.init(from:)`, and the `v18_prefix_mismatch_behavior` column, written by `upsertMetadata` (UPDATE and INSERT) and read by `loadAll`. Before writing the migration, confirm that no `v18_*` exists on `main`.
  - `ModelCallRecord.inputTransformations` is an optional `var`, which synthesized `Decodable` reads with `decodeIfPresent`. A test pins that.
  - New `GeminiRequest` and `GeminiResponse` fields are excluded from `Codable` through `CodingKeys`, as `cacheHints` is.
- **Invariant 3.** `ThinkingReplay` is a local in `processInputBody`, one per turn. It never goes on `IrisEngine` or `AppState`, where a concurrent turn or a subagent would share it. Blocks belong to a reply, not to a tool call, so the parallel tool batch never touches them.
- **Invariant 6.** No tool declaration changes in this plan. The invariant 6 amendment belongs to spec PR 3.
- **Invariant 7.**
  - Never mutate `ConfigManager.shared`.
  - Use `ConversationStore.inMemory()`, `FactStoreManager(inMemory: true)`, `protectionEnabled: false`, `sessionPeerCount: 0`, and an injected `HookManager` whose `configPathOverride` points into a temp directory of the test's own.
  - Hook scripts and temp files live in that directory and are removed by the test.
- **Invariant 9.** Each PR ends with a task that greps for what it made untrue and fixes it.
- **Bounded runs.**
  - Run focused tests as `timeout 300 scripts/test-filter.sh <TypeName>`, with the suite's *type* name (it fails on zero matches), and quote the count it ran.
  - Run the full suite as `timeout 900 swift test`. It is green only on all three: exit 0, the Swift Testing line `Test run with N tests … passed`, and XCTest's `Executed N tests, with 0 failures`.
  - If a `timeout` fires, sweep any orphaned `swiftpm-testing-helper`.
- **`max_tokens` is not this plan's.** It is being fixed on `fix/anthropic-max-tokens`, which edits `AnthropicClient.parseResponse`, `makeURLRequest`'s body and `GeminiRequest`. Whichever lands second rebases.
  - Keep that branch's `maxTokensKey(_:)` and this plan's `AnthropicCapabilities.key(_:)` as one function: the second to land makes one call the other.
  - Never touch the `max_tokens` value.
- **Branches.**
  - PR 1 is `feat/314-thinking-storage`, from `main`.
  - PR 2 is `feat/314-thinking-replay`, cut from `main` only after PR 1 has merged. Never stack it on PR 1's branch.
  - Conventional commits, each ending with the session's `Co-Authored-By` and `Claude-Session` trailers.

## Review Focus

1. **A thinking block that never got its signature.** A stream can be cut inside a thinking block, by `max_tokens` or a dropped connection. If that block were stored and replayed, every later request of the turn would be a 400. The reply must store nothing.
   - Tests: Task 2, `unsignedThinkingStoresNothing`, `unstoppedBlockStoresNothing` and `cutStreamStoresNothing`.
2. **A hook that changes nothing, counted as a rewrite.** `HookManager.fireEvent` returns the payload itself whenever any hook is registered for the event (`HookManager.swift:149`), so `.proceed(data)` alone proves nothing. A logging hook (`cat`, or a matcher that never fires) must not turn replay off.
   - Tests: Task 4, `passThroughAfterModelKeepsBlocks`. Task 11, `passThroughHooksKeepReplay`.
3. **A cache marker on a thinking block.** Marker (b), (c) or (d) can land on an echoed reply. If that reply's last block is a thinking block, merging `cache_control` into it is rejected. The marker is skipped for that message.
   - Test: Task 9, `markerSkipsAThinkingBlock`.
4. **A persisted `drop_block` reaching a model or route that cannot take it.** A tier or provider change can move the conversation to Haiku 4.5, Sonnet 5, or Sonnet 5.5 on Vertex. Sending the field there would be a 400 on every request, for good. The persisted field is sent only where the table says the beta is accepted.
   - Tests: Task 12, `persistedFieldOnlyWhereTheBetaIsTaken`. Task 13, `persistedValueFollowsTheModel`.
5. **A PreCompress hook that prepends.** A hook that inserts a summary at the front shifts an older turn's reply to an index at or above the turn's floor. Round one would then replay a block from another turn. Round one sends no block at all.
   - Test: Task 11, `preCompressPrependSendsNoOldBlocks`.

## Plan notes: where the spec and the code disagree (proposed rulings)

1. **5a's `firstDrop` does not see every mid-turn edit.** `TurnRequest.contents(for:from:)` returns early when the turn context is empty (`TurnContext.swift:92`), so `firstDrop` is never reported on such a turn. It also only checks the turn's entry, so an edit to any other message goes unreported.
   - *Ruling:* `ThinkingReplay.continues(_:)` compares each request with the last request the turn sent, message by message, with the blocks left out. A request that does not extend the last one raises the floor.
   - This one check covers `firstDrop`, any other UI edit, and PreCompress (its list gives way to AppState's at round two, spec decision 2).
2. **The request after a one-off BeforeModel rewrite also edits the prefix.** Say the hook rewrites request k only. Round k's reply was bound to the rewritten prefix, and request k+1, unrewritten, restores the original. The spec's event list strips only the blocks before request k, so round k's blocks would be replayed against a prefix they don't match. That is a 400 on an enforced account.
   - *Ruling:* plan note 1's check catches it, because request k+1 does not extend request k. Task 11 pins it.
3. **Decisions 4 and 6 conflict for unknown ids.** Decision 6 says to persist `drop_block` so every later request sends it. Decision 4 says never to send the beta to an unknown id, and the field cannot go without the beta.
   - *Ruling:* the persisted field is sent only where `AnthropicCapabilities.takesBindingBeta` holds. On an unknown id each later break pays one 400 and one retry instead.
   - The same rule protects Review Focus 4.
4. **The table gains a route fact in PR 1.** Decision 3 says PR 1 ships only `runsPrefixCheck`, but the probe found that Vertex rejects betas it does not accept for a model.
   - *Ruling:* add `AnthropicCapabilities.takesBindingBeta(model:transport:)`, with the Vertex set limited to what the probe saw. It is the header's first reader, so it lands with the header.
5. **Sonnet 5.5's thinking type is unverified.** The retry sends `thinking: {"type": "adaptive", …}`, the only form decision 4 allows. Version 2.1.292 of the skill says Sonnet 5.5's `between_tools` rejects `block_binding`. Nothing on this machine says whether Sonnet 5.5 accepts `adaptive`.
   - If it does not, the retry fails, and the turn shows the original error as it does today. Nothing is persisted, because the setting is recorded only on a successful retry.
   - Flag it for the next probe.
6. **After a `drop_block` retry, the floor rises too.** The API dropped blocks from that request, and spec decision 2 says "once a strip is recorded, keep it stripped". PTM also says to leave a removed block out.
   - *Ruling:* the engine raises the floor past everything the failed request carried. The retry's own reply keeps its blocks. `drop_block` stays persisted as well (decision 6).
7. **A reply stores blocks only when it has a thinking or `redacted_thinking` block.**
   - With nothing to replay, `parts` already says everything, and storing would only grow the row.
   - A reply holding a block type Iris does not fold stores nothing too. That covers citations and server tools. The cost is losing that one reply's thinking.
8. **Hooks see `anthropicBlocks`.** Decision 1 says "`parts` stays for the UI, hooks and other providers". Decision 2 counts "a BeforeModel rewrite, including one that returns JSON without `anthropicBlocks`", which implies the hook payload includes the field.
   - *Ruling:* `Content` encodes it. BeforeModel, PreCompress and AfterModel hooks see it, and a hook that keeps it keeps replay.
9. **Iris never sends `"error"`.** Decision 6 reserves it for CI fake-lane replays, and in this repo those are the probe's. `PrefixMismatchBehavior` has the one case Iris sends.
10. **PR 1 sends no block back.** The echo code lands in PR 2, with the floor that makes it safe, so PR 1 changes the wire only by the beta header.
11. **The diagnosis header needs a hook into the stream pump.** `LLMStreaming.stream` owns the `HTTPURLResponse`, and mappers see only SSE events.
    - *Ruling:* `StreamMapper` gains `headers(_:)`, which defaults to no events, and the pump calls it once after a 200.
    - On a 400, `APIError` keeps the header.
12. **Spec §2.1 asks for "one case per decision 2 event".** Plan note 1 adds two more cases: a UI edit on a turn with no context, and the request after a one-off rewrite.

---

## PR 1: storage and request shape, no replay

Branch: `feat/314-thinking-storage`, based on `main`.

### Task 1: `Content.anthropicBlocks`, persisted and never sent to Gemini

**Files:**
- Modify: `Sources/iris/Models.swift:20-23` (`Content`), `:229-239` (its `CodingKeys` and `init(from:)`)
- Modify: `Sources/iris/LLMClient.swift:125-130` (`encodeGeminiBody`)
- Test: `Tests/irisTests/AnthropicBlocksStorageTests.swift` (new)

**Interfaces:**
- Produces: `Content.anthropicBlocks: String?`, defaulting to `nil`. The memberwise init becomes `Content(role:parts:anthropicBlocks:)`, so every existing `Content(role:parts:)` call still compiles.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

/// #314 decision 1: the reply's blocks ride the history JSON, reach hooks, and never reach Gemini.
@Suite("Content.anthropicBlocks storage (#314)")
struct AnthropicBlocksStorageTests {
    static let blocks = #"[{"type":"thinking","thinking":"","signature":"sig-secret"},{"type":"text","text":"hi"}]"#

    private func request(blocks: String?) -> GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "q")]),
                                 Content(role: "model", parts: [Part(text: "hi")], anthropicBlocks: blocks)],
                      systemInstruction: nil, tools: nil)
    }

    @Test("a history row written before #314 decodes, with no blocks")
    func oldRowDecodes() throws {
        let row = #"{"role":"model","parts":[{"text":"hi"}]}"#
        let c = try JSONDecoder().decode(Content.self, from: Data(row.utf8))
        #expect(c.anthropicBlocks == nil)
        #expect(c.parts.first?.text == "hi")
    }

    @Test("the blocks survive the history JSON round trip unchanged")
    func roundTrips() throws {
        let c = Content(role: "model", parts: [Part(text: "hi")], anthropicBlocks: Self.blocks)
        let back = try JSONDecoder().decode(Content.self, from: JSONEncoder().encode(c))
        #expect(back.anthropicBlocks == Self.blocks)
    }

    @Test("a Gemini body never carries the field, and matches the body without it byte for byte")
    func geminiStrips() throws {
        let body = try LLMClient.encodeGeminiBody(request(blocks: Self.blocks))
        #expect(!String(decoding: body, as: UTF8.self).contains("anthropicBlocks"))
        #expect(body == (try LLMClient.encodeGeminiBody(request(blocks: nil))))
    }

    @Test("an OpenAI body never carries the blocks")
    func openAIIgnores() throws {
        let r = try OpenAIClient.makeURLRequest(request: request(blocks: Self.blocks), model: "gpt-5.6-terra",
                                                apiKey: "k", stream: false)
        #expect(!String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("sig-secret"))
    }

    @Test("BeforeModel and PreCompress hooks see the blocks, so a hook that keeps them keeps replay")
    func hookPayloadsCarry() throws {
        let payload = try #require(HookManager.beforeModelPayload(request(blocks: Self.blocks)))
        let back = try JSONDecoder().decode(GeminiRequest.self, from: payload)
        #expect(back.contents.last?.anthropicBlocks == Self.blocks)
    }

    @MainActor
    @Test("history keeps the blocks across a save and reload, and search never indexes them")
    func storeKeepsAndSearchIgnores() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation(title: "blocks")
        app.appendContentToHistory(for: id, content: Content(role: "user", parts: [Part(text: "q")]))
        app.appendContentToHistory(for: id, content: Content(role: "model", parts: [Part(text: "hi")],
                                                             anthropicBlocks: Self.blocks))
        app.flushSave()
        let loaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(loaded.history.last?.anthropicBlocks == Self.blocks)
        #expect(try store.searchConversations(query: "sig-secret").isEmpty)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh AnthropicBlocksStorageTests`. Expected: the build fails with "extra argument 'anthropicBlocks' in call".

- [ ] **Step 3: Implement.** In `Models.swift`, `Content` becomes:

```swift
struct Content: Codable, Sendable {
    var role: String?
    var parts: [Part]
    /// #314 decision 1: Anthropic's assistant `content` array exactly as it arrived, as JSON text,
    /// so a later request can send the thinking blocks back unchanged. `parts` stays the source for
    /// the UI and every other provider. nil for other providers, for a reply with no thinking
    /// block, for a reply an AfterModel hook rewrote, and for every row written before #314.
    var anthropicBlocks: String? = nil
}
```

The extension at `:229-239`:

```swift
extension Content {
    private enum CodingKeys: String, CodingKey { case role, parts, anthropicBlocks }

    /// `parts` is absent on a candidate Gemini stopped early. This type is also the persisted
    /// conversation history, so absence must decode, never throw (#136). `anthropicBlocks` is
    /// absent on every row older than #314 (invariant 1).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        anthropicBlocks = try c.decodeIfPresent(String.self, forKey: .anthropicBlocks)
    }
}
```

In `LLMClient.encodeGeminiBody`:

```swift
    static func encodeGeminiBody(_ request: GeminiRequest) throws -> Data {
        // #314: Anthropic's own blocks are not Gemini's; an unknown field is a 400.
        var wire = request
        for i in wire.contents.indices { wire.contents[i].anthropicBlocks = nil }
        wire.systemInstruction?.anthropicBlocks = nil
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(wire)
    }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 6 tests passed. Quote the count.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, and restore.
  - Change `decodeIfPresent` for `.anthropicBlocks` to `decode`: `oldRowDecodes` fails.
  - Delete the strip loop in `encodeGeminiBody`: `geminiStrips` fails.

- [ ] **Step 6: Grep the other encoders of `Content`.** Run `grep -rn "JSONEncoder().encode\|encoder.encode" Sources/iris | grep -i "content\|history\|request"`, and read every hit.
  - A hit that sends `Content` JSON to a model provider other than Gemini needs the same strip.
  - The history store, the hook payloads and `TurnContext.anchorBytes` need nothing: the field belongs in the first two, and the third only ever encodes user entries.
  - Record what you found in the commit body.

- [ ] **Step 7: Commit.** `git add Sources/iris/Models.swift Sources/iris/LLMClient.swift Tests/irisTests/AnthropicBlocksStorageTests.swift`, then `git commit` with `feat(anthropic): Content keeps the reply's blocks as received (#314)`.

### Task 2: The stream mapper keeps each block as received

**Files:**
- Create: `Sources/iris/AnthropicBlocks.swift`
- Modify: `Sources/iris/AnthropicStreamMapper.swift` (all of `handle`, `:13-77`)
- Modify: `Sources/iris/LLMStream.swift:5-18` (one new `LLMStreamEvent` case)
- Test: `Tests/irisTests/AnthropicStreamMapperTests.swift`. Rewrite `thinkingIgnored` (`:100-112`) and add the tests below.

**Interfaces:**
- Produces:
  - `LLMStreamEvent.anthropicBlocks(String)`, emitted once just before `.done` on `message_stop`, and only when the array may be stored.
  - `enum AnthropicBlocks` with `struct Streamed`, `static func render(_ blocks: [Streamed]) -> String?`, `static func string(_:) -> String` (a JSON string literal), `static func storable(_ raw: String) -> String?` and `static let storableTypes: Set<String>`.
  - Task 3 adds `enum RawJSON` to the same file.

- [ ] **Step 1: Write the failing tests.** Rewrite `thinkingIgnored` and add the cases below to `AnthropicStreamMapperTests`.

```swift
    @Test("thinking deltas emit no text and are kept as the reply's blocks")
    func thinkingKeptAsBlocks() throws {
        let events = try run([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":2}}"#),
            ("message_stop", #"{"type":"message_stop"}"#)
        ])
        #expect(events == [.usage(UsageMetadata(promptTokenCount: nil, candidatesTokenCount: 2, totalTokenCount: nil)),
                           .anthropicBlocks(#"[{"type":"thinking","thinking":"hmm","signature":"abc"}]"#),
                           .done(finishReason: "refusal")])
    }

    private static func thinking(_ index: Int, signature: String?) -> [(String, String)] {
        var out = [("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
                   ("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"thinking_delta","thinking":"Check \"x\"."}}"#)]
        if let signature {
            out.append(("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"signature_delta","signature":"\#(signature)"}}"#))
        }
        out.append(("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#))
        return out
    }
    private static let stop = [("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#),
                               ("message_stop", #"{"type":"message_stop"}"#)]
    private static func text(_ index: Int, _ s: String) -> [(String, String)] {
        [("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#),
         ("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(s)"}}"#),
         ("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)]
    }
    private func blocks(_ events: [LLMStreamEvent]) -> [String] {
        events.compactMap { if case .anthropicBlocks(let raw) = $0 { return raw } else { return nil } }
    }

    @Test("block order, the signature, and the tool input's own bytes are kept as received")
    func keepsBlocksAsReceived() throws {
        let events = try run(Self.thinking(0, signature: "sig-1") + Self.text(1, "Looking.") + [
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"Sea"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ttle\", \"b\": 1.0}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
        ] + Self.stop)
        let expected = #"[{"type":"thinking","thinking":"Check \"x\".","signature":"sig-1"},{"type":"text","text":"Looking."},{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{"query": "Seattle", "b": 1.0}}]"#
        #expect(blocks(events) == [expected])
        #expect(events.last == .done(finishReason: "end_turn"))
        // The UI and the dispatcher still get what they got before.
        #expect(events.contains(.textDelta("Looking.")))
        #expect(events.contains { event in
            if case .functionCall(let c) = event { return c.id == "toolu_1" }
            return false
        })
    }

    @Test("a redacted_thinking block is kept with its data")
    func redactedKept() throws {
        let events = try run([
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"ENC=="}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ] + Self.text(1, "ok") + Self.stop)
        #expect(blocks(events) == [#"[{"type":"redacted_thinking","data":"ENC=="},{"type":"text","text":"ok"}]"#])
    }

    @Test("a reply that did not think stores nothing (Fable 5.1 on a short prompt)")
    func unthoughtStoresNothing() throws {
        #expect(blocks(try run(Self.text(0, "hi") + Self.stop)).isEmpty)
    }

    @Test("a thinking block that never got its signature stores nothing (Review Focus 1)")
    func unsignedThinkingStoresNothing() throws {
        #expect(blocks(try run(Self.thinking(0, signature: nil) + Self.text(1, "hi") + Self.stop)).isEmpty)
    }

    @Test("a block that never stopped stores nothing, even when the message stopped (Review Focus 1)")
    func unstoppedBlockStoresNothing() throws {
        let open = Array(Self.thinking(0, signature: "sig-1").dropLast())
        #expect(blocks(try run(open + Self.stop)).isEmpty)
    }

    @Test("a stream that ends without message_stop stores nothing (Review Focus 1)")
    func cutStreamStoresNothing() throws {
        let events = try run(Self.thinking(0, signature: "sig-1") + Self.text(1, "hi"))
        #expect(blocks(events).isEmpty)
        #expect(events.last == .done(finishReason: nil))
    }

    @Test("a delta Iris does not fold (citations) stores nothing for that reply")
    func citationsStoreNothing() throws {
        let events = try run(Self.thinking(0, signature: "sig-1") + [
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"citations_delta","citation":{"type":"char_location"}}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ] + Self.stop)
        #expect(blocks(events).isEmpty)
    }

    @Test("a missing block index stores nothing: the array would not be what arrived")
    func indexGapStoresNothing() throws {
        #expect(blocks(try run(Self.thinking(0, signature: "sig-1") + Self.text(2, "hi") + Self.stop)).isEmpty)
    }
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh AnthropicStreamMapperTests`. Expected: the build fails with "type 'LLMStreamEvent' has no member 'anthropicBlocks'".

- [ ] **Step 3: Implement.** In `LLMStream.swift`, add the case to `LLMStreamEvent`:

```swift
    /// #314: an Anthropic reply's content array as received, for `Content.anthropicBlocks`. Once,
    /// at the end of a complete reply that has a thinking block; never for a cut-off one.
    case anthropicBlocks(String)
```

`StreamAssembler.apply` switches exhaustively, so add `case .anthropicBlocks: break` there for now. Task 3 replaces it.

Create `Sources/iris/AnthropicBlocks.swift`:

```swift
import Foundation

/// #314 decision 1: an Anthropic reply's content array as it arrived. The stream path renders it
/// from the blocks it folded. A tool_use block's input is never re-serialised: its `partial_json`
/// goes in verbatim, so the key order and number spelling the model produced are what goes back.
enum AnthropicBlocks {
    /// The block types Iris stores. A reply holding anything else stores nothing and is replayed
    /// from `parts`, as before #314 (plan note 7).
    static let storableTypes: Set<String> = ["text", "thinking", "redacted_thinking", "tool_use"]

    /// One streamed block, folded from its `content_block_start` and deltas.
    struct Streamed: Sendable, Equatable {
        var type: String
        var text = ""
        var thinking = ""
        var signature = ""
        var data = ""
        var id = ""
        var name = ""
        var json = ""
        var stopped = false
    }

    /// The reply's array, or nil when it must not be stored: nothing to replay (no thinking
    /// block), a block that never stopped (the stream died inside it), a thinking block with no
    /// signature (cut before it was signed; replayed, it is a 400), or a type Iris does not store.
    /// `blocks` must be every block of the reply, in index order.
    static func render(_ blocks: [Streamed]) -> String? {
        guard !blocks.isEmpty,
              blocks.allSatisfy({ $0.stopped && storableTypes.contains($0.type) }),
              blocks.contains(where: { $0.type == "thinking" || $0.type == "redacted_thinking" }),
              blocks.allSatisfy({ $0.type != "thinking" || !$0.signature.isEmpty }) else { return nil }
        return "[" + blocks.map(render).joined(separator: ",") + "]"
    }

    private static func render(_ b: Streamed) -> String {
        switch b.type {
        case "thinking":
            return #"{"type":"thinking","thinking":\#(string(b.thinking)),"signature":\#(string(b.signature))}"#
        case "redacted_thinking":
            return #"{"type":"redacted_thinking","data":\#(string(b.data))}"#
        case "tool_use":
            let input = b.json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : b.json
            return #"{"type":"tool_use","id":\#(string(b.id)),"name":\#(string(b.name)),"input":\#(input)}"#
        default:
            return #"{"type":"text","text":\#(string(b.text))}"#
        }
    }

    /// `s` as a JSON string literal.
    static func string(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(s)) ?? Data(#""""#.utf8), as: UTF8.self)
    }

    /// The same rules for an array that arrived whole (the non-stream path): `raw` itself, or nil.
    static func storable(_ raw: String) -> String? {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]],
              !array.isEmpty else { return nil }
        let types = array.map { $0["type"] as? String ?? "" }
        guard types.allSatisfy(storableTypes.contains),
              types.contains(where: { $0 == "thinking" || $0 == "redacted_thinking" }),
              array.allSatisfy({ ($0["type"] as? String) != "thinking"
                                 || !(($0["signature"] as? String) ?? "").isEmpty }) else { return nil }
        return raw
    }
}
```

In `AnthropicStreamMapper.swift`, update the type's doc comment (the old one says thinking deltas are dropped). Add the block map, and replace the `content_block_start`, `content_block_delta`, `content_block_stop` and `message_stop` cases:

```swift
/// Anthropic Messages streaming (`"stream": true`). Text deltas pass through; a `tool_use`
/// block's `input_json_delta` fragments are buffered per block index and emitted as one
/// `functionCall` on `content_block_stop`; `message_start`/`message_delta` carry the two
/// halves of usage. Every block is also folded as it arrived, and a complete reply that thought
/// emits its content array once, before `done` (#314); `ping` is dropped.
struct AnthropicStreamMapper: StreamMapper {
    private struct ToolBlock { var id: String; var name: String; var json = "" }
    private var tools: [Int: ToolBlock] = [:]
    /// #314: every block of the reply by index, so the array can be stored as received.
    private var blocks: [Int: AnthropicBlocks.Streamed] = [:]
    private var stopReason: String?
    private var stopped = false
```

```swift
        case "content_block_start":
            guard let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any] else { break }
            let type = block["type"] as? String ?? ""
            var streamed = AnthropicBlocks.Streamed(type: type)
            streamed.text = block["text"] as? String ?? ""
            streamed.thinking = block["thinking"] as? String ?? ""
            streamed.signature = block["signature"] as? String ?? ""
            streamed.data = block["data"] as? String ?? ""
            if type == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                tools[index] = ToolBlock(id: id, name: name)
                streamed.id = id
                streamed.name = name
            }
            blocks[index] = streamed
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any] else { break }
            let index = json["index"] as? Int
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String {
                    if let index { blocks[index]?.text += text }
                    return [.textDelta(text)]
                }
            case "input_json_delta":
                if let index, let partial = delta["partial_json"] as? String {
                    tools[index]?.json += partial
                    blocks[index]?.json += partial
                }
            case "thinking_delta":
                if let index, let thinking = delta["thinking"] as? String { blocks[index]?.thinking += thinking }
            case "signature_delta":
                if let index, let signature = delta["signature"] as? String { blocks[index]?.signature += signature }
            default:
                // A delta this mapper does not fold (citations): the block cannot be rebuilt as it
                // arrived, so the reply stores nothing.
                if let index { blocks[index]?.type = "unfolded" }
            }
        case "content_block_stop":
            if let index = json["index"] as? Int {
                blocks[index]?.stopped = true
                if let block = tools.removeValue(forKey: index) {
                    let args = try Self.decodeArguments(block.json)
                    return [.functionCall(FunctionCall(name: block.name, args: args, id: block.id))]
                }
            }
```

```swift
        case "message_stop":
            stopped = true
            var out: [LLMStreamEvent] = []
            // Every index from 0, with none missing: otherwise the array is not what arrived.
            let indices = blocks.keys.sorted()
            if indices == Array(0..<indices.count),
               let raw = AnthropicBlocks.render(indices.compactMap { blocks[$0] }) {
                out.append(.anthropicBlocks(raw))
            }
            out.append(.done(finishReason: stopReason))
            return out
```

`finish()` stays as it is. A stream with no `message_stop` emits `.done` and never the blocks.

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: every test in the suite passes, including `textThenTool` unchanged. Quote the count.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, and restore.
  - In `render`, drop the signature clause: `unsignedThinkingStoresNothing` fails.
  - Drop `$0.stopped &&`: `unstoppedBlockStoresNothing` fails.
  - Emit the blocks from `finish()` as well: `cutStreamStoresNothing` fails.
  - Drop the `indices == Array(0..<indices.count)` check: `indexGapStoresNothing` fails.

- [ ] **Step 6: Commit.** `feat(anthropic): the stream mapper keeps each reply's blocks as received (#314)`.

### Task 3: The assembler, the replay path and the non-stream parser carry the blocks

**Files:**
- Modify: `Sources/iris/LLMStream.swift:79-151` (`StreamAssembler`) and `:153-172` (`events(from:)`)
- Modify: `Sources/iris/AnthropicBlocks.swift` (add `RawJSON`)
- Modify: `Sources/iris/AnthropicClient.swift:344-361` (`generateOnce`) and `:368-393` (`parseResponse`)
- Test: `Tests/irisTests/AnthropicBlocksTests.swift` (new)

**Interfaces:**
- Consumes: `LLMStreamEvent.anthropicBlocks` and `AnthropicBlocks.storable` (Task 2).
- Produces:
  - `StreamAssembler.anthropicBlocks: String?`. `response()` puts it on the candidate's `Content`.
  - `LLMStreamEvent.events(from:)` emits `.anthropicBlocks` when the content has it, so `FakeLLMClient` and the streaming-off path keep it.
  - `enum RawJSON { static func topLevelValue(_ key: String, in data: Data) -> String? }`.
  - `AnthropicClient.parseResponse(_ json: [String: Any], raw: Data? = nil)`. Existing callers stay valid, and with no `raw` it stores no blocks.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

@Suite("Anthropic blocks through the assembler and the non-stream parser (#314)")
struct AnthropicBlocksTests {
    static let raw = #"[{"type":"thinking","thinking":"","signature":"sig-1"},{"type":"tool_use","id":"toolu_1","name":"search_memory","input":{"query": "Seattle", "b": 1.0}}]"#

    @Test("RawJSON cuts a top-level member out byte for byte, whitespace and all")
    func rawJSONCutsVerbatim() {
        let data = Data(#"{"id":"m", "content" : [ {"type":"text","text":"a } \" ] {"} ] ,"usage":{}}"#.utf8)
        #expect(RawJSON.topLevelValue("content", in: data) == #"[ {"type":"text","text":"a } \" ] {"} ]"#)
        #expect(RawJSON.topLevelValue("id", in: data) == #""m""#)
    }

    @Test("RawJSON reads only top-level keys, and answers nil for a missing key or a malformed body")
    func rawJSONTopLevelOnly() {
        let nested = Data(#"{"usage":{"content":[1]},"content":[2]}"#.utf8)
        #expect(RawJSON.topLevelValue("content", in: nested) == "[2]")
        #expect(RawJSON.topLevelValue("content", in: Data(#"{"usage":{"content":[1]}}"#.utf8)) == nil)
        #expect(RawJSON.topLevelValue("content", in: Data(#"{"content":[1"#.utf8)) == nil)
        #expect(RawJSON.topLevelValue("content", in: Data("[1]".utf8)) == nil)
    }

    @Test("a non-stream reply keeps the response's own bytes for its blocks")
    func nonStreamKeepsBytes() throws {
        let data = Data(#"{"id":"m","content":\#(Self.raw),"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try AnthropicClient.parseResponse(json, raw: data)
        let content = try #require(response.candidates?.first?.content)
        #expect(content.anthropicBlocks == Self.raw)
        #expect(content.parts.first?.functionCall?.id == "toolu_1")
    }

    @Test("a non-stream reply with no thinking block, or parsed without its bytes, stores nothing")
    func nonStreamWithoutThinking() throws {
        let data = Data(#"{"content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(try AnthropicClient.parseResponse(json, raw: data).candidates?.first?.content?.anthropicBlocks == nil)
        let thought = Data(#"{"content":\#(Self.raw)}"#.utf8)
        let thoughtJSON = try #require(try JSONSerialization.jsonObject(with: thought) as? [String: Any])
        #expect(try AnthropicClient.parseResponse(thoughtJSON).candidates?.first?.content?.anthropicBlocks == nil)
    }

    @Test("the assembler puts streamed blocks on the reply's content")
    func assemblerCarries() {
        var a = StreamAssembler()
        a.apply(.functionCall(FunctionCall(name: "search_memory", args: [:], id: "toolu_1")), now: 1)
        a.apply(.anthropicBlocks(Self.raw), now: 2)
        a.apply(.done(finishReason: "tool_use"), now: 3)
        #expect(a.response().candidates?.first?.content?.anthropicBlocks == Self.raw)
    }

    @Test("a finished response replayed as events keeps its blocks (the FakeLLMClient and streaming-off path)")
    func replayRoundTrip() {
        let content = Content(role: "model", parts: [Part(text: "hi")], anthropicBlocks: Self.raw)
        let events = LLMStreamEvent.events(from: GeminiResponse(candidates: [Candidate(content: content)], usageMetadata: nil))
        var a = StreamAssembler()
        for e in events { a.apply(e, now: 1) }
        #expect(a.response().candidates?.first?.content?.anthropicBlocks == Self.raw)
        #expect(a.firstTokenAt == 1, "the blocks event is not a token, but the text before it is")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh AnthropicBlocksTests`. Expected: the build fails with "cannot find 'RawJSON' in scope" and "extra argument 'raw'".

- [ ] **Step 3: Implement.** In `StreamAssembler`:

```swift
    /// #314: the reply's content array, when the stream ended a complete reply that thought.
    private(set) var anthropicBlocks: String?
```

```swift
        case .anthropicBlocks(let raw):
            anthropicBlocks = raw
```

In `response()`, replace the `let content = …` line:

```swift
        var content = parts.isEmpty ? nil : Content(role: "model", parts: parts)
        content?.anthropicBlocks = anthropicBlocks
```

In `events(from:)`, after the parts loop:

```swift
        if let raw = candidate?.content?.anthropicBlocks { out.append(.anthropicBlocks(raw)) }
```

Append `RawJSON` to `AnthropicBlocks.swift`:

```swift
/// One top-level member of a JSON object, cut out as bytes without parsing the value, so the
/// non-stream path stores a reply's blocks exactly as they arrived (#314 decision 1).
enum RawJSON {
    /// The bytes of `key`'s value in the top-level object `data`, or nil when `data` is not an
    /// object or has no such member. Strings are skipped escape-aware, so a brace or a quoted key
    /// inside a string is never taken for structure.
    static func topLevelValue(_ key: String, in data: Data) -> String? {
        let b = [UInt8](data)
        var i = 0
        func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }
        func skipString() -> Bool {               // at `"`; ends just past the closing quote
            guard i < b.count, b[i] == 0x22 else { return false }
            i += 1
            while i < b.count {
                switch b[i] {
                case 0x5C: i += 2                     // a backslash escapes the next byte
                case 0x22: i += 1; return true
                default: i += 1
                }
            }
            return false
        }
        func skipValue() -> Bool {
            skipSpace()
            guard i < b.count else { return false }
            if b[i] == 0x22 { return skipString() }
            if b[i] == 0x7B || b[i] == 0x5B {
                var depth = 0
                while i < b.count {
                    switch b[i] {
                    case 0x22:
                        guard skipString() else { return false }
                        continue
                    case 0x7B, 0x5B:
                        depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default:
                        break
                    }
                    i += 1
                }
                return false
            }
            let start = i
            while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
            return i > start
        }
        skipSpace()
        guard i < b.count, b[i] == 0x7B else { return nil }
        i += 1
        while true {
            skipSpace()
            let keyStart = i
            guard skipString() else { return nil }
            let name = try? JSONDecoder().decode(String.self, from: Data(b[keyStart..<i]))
            skipSpace()
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            let valueStart = i
            guard skipValue() else { return nil }
            if name == key { return String(decoding: b[valueStart..<i], as: UTF8.self) }
            skipSpace()
            guard i < b.count, b[i] == 0x2C else { return nil }
            i += 1
        }
    }
}
```

In `AnthropicClient`:
- `generateOnce`'s last line becomes `return try parseResponse(json, raw: data)`.
- `parseResponse` takes `raw: Data? = nil`. After the parts loop, before `if !content.parts.isEmpty`, add:

```swift
            // #314: the array as it arrived, cut from the response bytes, never re-serialised.
            if let raw, let array = RawJSON.topLevelValue("content", in: raw),
               let stored = AnthropicBlocks.storable(array) {
                content.anthropicBlocks = stored
            }
```

If `fix/anthropic-max-tokens` has landed, its `max_tokens` refusal and `finishReason` on the candidate stay as they are. This insertion goes after its loop.

- [ ] **Step 4: Run them and watch them pass.** Run the same filter, then `LLMStreamTests` and `AnthropicClientTests` (the old parser callers). Expected: all pass. Quote the counts.

- [ ] **Step 5: Mutation checks.**
  - In `RawJSON`, make `skipString` stop at the first `"` without honouring `\`: `rawJSONCutsVerbatim` fails.
  - Delete the `events(from:)` line: `replayRoundTrip` fails.

- [ ] **Step 6: Commit.** `feat(anthropic): blocks ride the assembler, the replay path and the non-stream parser (#314)`.

### Task 4: The engine stores the blocks, except for a reply a hook rewrote

**Files:**
- Modify: `Sources/iris/HookManager.swift` (append `HookRewrite`)
- Modify: `Sources/iris/iris.swift:2110-2115` (the AfterModel decode) and `:2131` (the stored reply)
- Create: `Tests/irisTests/ThinkingTestSupport.swift` (shared by Tasks 4, 7, 11 and 13)
- Test: `Tests/irisTests/ThinkingStorageEngineTests.swift` (new)

**Interfaces:**
- Consumes: `Content.anthropicBlocks` (Task 1), and the replay path keeping it (Task 3).
- Produces:
  - `enum HookRewrite { static func changes<T: Encodable>(_ original: T, _ rewritten: T) -> Bool }`, used again by Task 11.
  - The test support types `RecordingClient`, `ThinkingFixtures` and `ThinkingHarness`, with the signatures below.

- [ ] **Step 1: Write the test support.** Create `Tests/irisTests/ThinkingTestSupport.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// #314 engine tests: a scripted client that records what the engine sent, replies carrying fake
/// signed blocks, hooks as shell scripts in a temp dir of the test's own, and the Anthropic body
/// each recorded request builds. No network, no `ConfigManager.shared` writes (invariant 7).
final class RecordingClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    private let script: [GeminiResponse]

    init(_ script: [GeminiResponse]) { self.script = script }

    var requests: [GeminiRequest] { lock.withLock { recorded } }

    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        let n = lock.withLock { recorded.append(request); return recorded.count }
        return script[min(n - 1, script.count - 1)]
    }
}

enum ThinkingFixtures {
    struct Failure: Error { let message: String }

    static func thinkingBlock(_ n: Int) -> String { #"{"type":"thinking","thinking":"","signature":"sig-\#(n)"}"# }

    /// Reply `n`: one signed thinking block, then a `search_memory` call whose input keeps the
    /// model's own spacing (so a verbatim echo is visible), or a closing text.
    static func reply(_ n: Int, toolCall: Bool) -> GeminiResponse {
        if toolCall {
            let id = "toolu_\(n)"
            let blocks = "[\(thinkingBlock(n)),{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"search_memory\",\"input\":{\"query\": \"Seattle \(n)\"}}]"
            let call = FunctionCall(name: "search_memory", args: ["query": .string("Seattle \(n)")], id: id)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)],
                                                                          anthropicBlocks: blocks))], usageMetadata: nil)
        }
        let blocks = "[\(thinkingBlock(n)),{\"type\":\"text\",\"text\":\"done \(n)\"}]"
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done \(n)")],
                                                                      anthropicBlocks: blocks))], usageMetadata: nil)
    }

    /// Reply `n` from a model that did not think: no blocks at all (work's probe: Fable 5.1, 12 of 12).
    static func unthought(_ n: Int, toolCall: Bool) -> GeminiResponse {
        var r = reply(n, toolCall: toolCall)
        r.candidates?[0].content?.anthropicBlocks = nil
        return r
    }

    /// Three tool rounds, then an answer: four requests in one turn.
    static func fourRounds() -> [GeminiResponse] {
        [reply(1, toolCall: true), reply(2, toolCall: true), reply(3, toolCall: true), reply(4, toolCall: false)]
    }

    static func tempDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-314-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A HookManager reading only `dir/settings.json`, with each event's hook the given `/bin/sh`
    /// script. No events means no hooks at all.
    static func hooks(in dir: URL, _ scripts: [String: String] = [:]) throws -> HookManager {
        var events: [String: Any] = [:]
        for (event, script) in scripts {
            let url = dir.appendingPathComponent("\(event).sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            events[event] = [["matcher": event, "hooks": [["type": "command", "command": "/bin/sh '\(url.path)'"]]]]
        }
        let settings = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["hooks": events]).write(to: settings)
        var manager = HookManager()
        manager.configPathOverride = settings.path
        return manager
    }

    /// A script that runs `sed` on call `n` only and passes its input through otherwise.
    static func onCall(_ n: Int, sed expression: String, counter: URL) -> String {
        """
        c=$(cat '\(counter.path)' 2>/dev/null || echo 0); c=$((c+1)); echo $c > '\(counter.path)'
        if [ "$c" -eq \(n) ]; then sed -E '\(expression)'; else cat; fi
        """
    }

    static func urlRequest(_ request: GeminiRequest, model: String = "claude-opus-5-5") throws -> URLRequest {
        try AnthropicClient.makeURLRequest(request: request, model: model, apiKey: "k", stream: true)
    }

    static func body(_ request: GeminiRequest, model: String = "claude-opus-5-5") throws -> [String: Any] {
        let data = try urlRequest(request, model: model).httpBody ?? Data()
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "the body is not a JSON object")
        }
        return body
    }

    static func bodyText(_ request: GeminiRequest, model: String = "claude-opus-5-5") throws -> String {
        String(decoding: try urlRequest(request, model: model).httpBody ?? Data(), as: UTF8.self)
    }

    /// Every thinking signature in a body's messages, in order.
    static func signatures(_ body: [String: Any]) -> [String] {
        (body["messages"] as? [[String: Any]] ?? []).flatMap { message in
            (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "thinking" }
                .compactMap { $0["signature"] as? String }
        }
    }

    /// Each message of a body with every `cache_control` removed, as sorted-key bytes.
    static func messagesIgnoringCacheControl(_ body: [String: Any]) throws -> [Data] {
        func strip(_ v: Any) -> Any {
            if let d = v as? [String: Any] { return d.filter { $0.key != "cache_control" }.mapValues(strip) }
            if let a = v as? [Any] { return a.map(strip) }
            return v
        }
        return try (body["messages"] as? [[String: Any]] ?? []).map {
            try JSONSerialization.data(withJSONObject: strip($0), options: [.sortedKeys])
        }
    }

    /// Spec §2.1: each request's blocks are a contiguous run ending at the newest block this
    /// turn produced before it (a front-dropped window), and a block left out once stays out.
    /// `produced[i]` is reply i+1's signature, or nil for a reply that did not think.
    static func expectFrontDroppedWindows(_ sent: [[String]], produced: [String?],
                                          sourceLocation: SourceLocation = #_sourceLocation) {
        var dropped = 0
        for (n, blocks) in sent.enumerated() {
            let available = produced.prefix(n).compactMap { $0 }
            guard let first = blocks.first else { dropped = available.count; continue }
            guard let start = available.firstIndex(of: first) else {
                Issue.record("request \(n + 1) sends \(first), which no earlier reply of this turn produced",
                             sourceLocation: sourceLocation)
                continue
            }
            #expect(Array(available[start...]) == blocks, "request \(n + 1) is not a contiguous tail",
                    sourceLocation: sourceLocation)
            #expect(start >= dropped, "request \(n + 1) sends a block an earlier request left out",
                    sourceLocation: sourceLocation)
            dropped = start
        }
    }
}

/// One conversation on an engine over a recording client. `earlierTurn` seeds a finished turn
/// whose reply carries a block signed `sig-0`; `seedFact` gives the turn a non-empty context.
@MainActor
struct ThinkingHarness {
    let app: AppState
    let id: UUID
    let client: RecordingClient
    let engine: IrisEngine
    var history: [Content] { app.conversations.first { $0.id == id }?.history ?? [] }

    static func make(_ script: [GeminiResponse], hooks: HookManager, store: ConversationStore? = nil,
                     seedFact: Bool = false, earlierTurn: Bool = false,
                     roundStart: (@Sendable (Int) async -> Void)? = nil) throws -> ThinkingHarness {
        let facts = try FactStoreManager(inMemory: true)
        if seedFact { _ = try facts.addFact(content: "Brian lives in Seattle") }
        let app = AppState(store: try store ?? ConversationStore.inMemory(),
                           tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation(title: "thinking")
        if earlierTurn {
            app.appendContentToHistory(for: id, content: Content(role: "user", parts: [Part(text: "earlier question")]))
            app.appendContentToHistory(for: id, content: Content(
                role: "model", parts: [Part(text: "earlier answer")],
                anthropicBlocks: "[\(ThinkingFixtures.thinkingBlock(0)),{\"type\":\"text\",\"text\":\"earlier answer\"}]"))
        }
        let client = RecordingClient(script)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: false, factStore: facts, protectionEnabled: false,
                                sessionPeerCount: 0, roundStartHook: roundStart, hooks: hooks)
        return ThinkingHarness(app: app, id: id, client: client, engine: engine)
    }

    func run(_ input: String = "Tell me about Seattle") async {
        await engine.processInput(input, source: "UI", conversationId: id)
    }

    /// The signatures in the Anthropic body of each request the engine sent.
    func sentSignatures() throws -> [[String]] {
        try client.requests.map { ThinkingFixtures.signatures(try ThinkingFixtures.body($0)) }
    }
}
```

- [ ] **Step 2: Write the failing tests.** Create `Tests/irisTests/ThinkingStorageEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@MainActor
@Suite("The engine stores each reply's blocks (#314)", .timeLimit(.minutes(1)))
struct ThinkingStorageEngineTests {
    private func modelEntries(_ h: ThinkingHarness) -> [Content] { h.history.filter { $0.role == "model" } }

    @Test("every reply of a four-round turn keeps its blocks in history")
    func repliesStoreTheirBlocks() async throws {
        let dir = try ThinkingFixtures.tempDirectory("store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = ThinkingFixtures.fourRounds()
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        #expect(h.client.requests.count == 4)
        #expect(modelEntries(h).map(\.anthropicBlocks) == script.map { $0.candidates?.first?.content?.anthropicBlocks })
    }

    @Test("a reply that did not think stores no blocks, and its neighbours keep theirs")
    func unthoughtStoresNone() async throws {
        let dir = try ThinkingFixtures.tempDirectory("unthought")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = [ThinkingFixtures.reply(1, toolCall: true), ThinkingFixtures.unthought(2, toolCall: true),
                      ThinkingFixtures.reply(3, toolCall: false)]
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        #expect(modelEntries(h).map { $0.anthropicBlocks != nil } == [true, false, true])
    }

    @Test("a reply an AfterModel hook rewrote stores no blocks")
    func afterModelRewriteStoresNone() async throws {
        let dir = try ThinkingFixtures.tempDirectory("aftermodel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = ThinkingFixtures.onCall(2, sed: "s/Seattle 2/Seattle two/g", counter: dir.appendingPathComponent("n"))
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(),
                                         hooks: try ThinkingFixtures.hooks(in: dir, ["AfterModel": script]))
        await h.run()
        #expect(modelEntries(h).map { $0.anthropicBlocks != nil } == [true, false, true, true])
        #expect(modelEntries(h)[1].parts.first?.functionCall?.args["query"] == .string("Seattle two"),
                "precondition: the hook really rewrote round two")
    }

    @Test("an AfterModel hook that passes its input through is not a rewrite (Review Focus 2)")
    func passThroughAfterModelKeepsBlocks() async throws {
        let dir = try ThinkingFixtures.tempDirectory("passthrough")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(),
                                         hooks: try ThinkingFixtures.hooks(in: dir, ["AfterModel": "cat"]))
        await h.run()
        #expect(modelEntries(h).allSatisfy { $0.anthropicBlocks != nil })
    }

    @Test("HookRewrite compares canonical JSON: key order is not a change, a value is")
    func hookRewriteIsCanonical() throws {
        let a = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"a":1,"b":"x"}"#.utf8))
        let b = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"b":"x","a":1}"#.utf8))
        let c = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"{"b":"y","a":1}"#.utf8))
        #expect(!HookRewrite.changes(a, b))
        #expect(HookRewrite.changes(a, c))
    }
}
```

- [ ] **Step 3: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh ThinkingStorageEngineTests`. Expected: the build fails on `HookRewrite`. If you stub it, `repliesStoreTheirBlocks` fails, because `iris.swift:2131` builds the reply from `parts` only.

- [ ] **Step 4: Implement.** Append to `HookManager.swift`:

```swift
/// Whether a hook's output differs from what it was given, compared as sorted-key JSON so a hook
/// that re-serialises its input unchanged is not a rewrite. `fireEvent` hands back the payload
/// itself whenever any hook is registered for the event, so `.proceed(data)` alone says nothing.
enum HookRewrite {
    static func changes<T: Encodable>(_ original: T, _ rewritten: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(original)) != (try? encoder.encode(rewritten))
    }
}
```

In `iris.swift`, replace `:2110-2115`:

```swift
                var activeResponse = response
                // #314: whether the hook changed the reply. A rewritten reply's blocks no longer
                // match what is sent back, so it stores none.
                var replyRewritten = false
                if case .proceed(let modifiedData) = afterModelDecision, let data = modifiedData {
                    if let modifiedRes = try? JSONDecoder().decode(GeminiResponse.self, from: data) {
                        replyRewritten = HookRewrite.changes(response.candidates?.first?.content,
                                                             modifiedRes.candidates?.first?.content)
                        activeResponse = modifiedRes
                    }
                }
```

Replace `:2131`:

```swift
                var modelContent = Content(role: "model", parts: responseContent.parts)
                // #314 decision 1: the blocks as received, taken from the reply before any hook.
                if !replyRewritten {
                    modelContent.anthropicBlocks = response.candidates?.first?.content?.anthropicBlocks
                }
```

- [ ] **Step 5: Run them and watch them pass.** Run the same filter. Expected: 5 passed. Then run `TurnContextEngineTests` and `StreamingEngineTests` for regressions. Quote the counts.

- [ ] **Step 6: Mutation checks.**
  - Set `replyRewritten = true` whenever `data` decodes: `passThroughAfterModelKeepsBlocks` fails.
  - Store the blocks even when `replyRewritten`: `afterModelRewriteStoresNone` fails.

- [ ] **Step 7: Commit.** `feat(engine): store each reply's Anthropic blocks, none for a rewritten reply (#314)`.

### Task 5: `AnthropicCapabilities` and the binding beta header

**Files:**
- Create: `Sources/iris/AnthropicCapabilities.swift`
- Modify: `Sources/iris/AnthropicClient.swift:239-266` (the headers)
- Test: `Tests/irisTests/AnthropicCapabilitiesTests.swift` (new)

**Interfaces:**
- Produces:
  - `struct AnthropicCapabilities`, with `init(model:)`, `var runsPrefixCheck: Bool`, `static func key(_:) -> String` and `static func takesBindingBeta(model: String, transport: AnthropicTransport) -> Bool`.
  - Its constants: `static let bindingBeta = "thinking-binding-controls-2026-08-01"`, `static let prefixCheckModels` and `static let vertexBindingBetaModels`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

@Suite("AnthropicCapabilities and the binding beta (#314)")
struct AnthropicCapabilitiesTests {
    static let vertex = AnthropicTransport.vertex(project: "iris-test-project", location: "global", accessToken: "t")
    static let direct = AnthropicTransport.direct(apiKey: "k", baseURL: "")

    private func header(_ model: String, _ transport: AnthropicTransport) throws -> String? {
        let r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        return try AnthropicClient.makeURLRequest(request: r, model: model, transport: transport, stream: true)
            .value(forHTTPHeaderField: "anthropic-beta")
    }

    @Test("the prefix check is known for exactly three models, under any date spelling",
          arguments: ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5",
                      "claude-opus-5-5-20261001", "claude-opus-5-5@20261001"])
    func checkModels(model: String) {
        #expect(AnthropicCapabilities(model: model).runsPrefixCheck)
    }

    @Test("everything else is not known to check",
          arguments: ["claude-sonnet-5", "claude-fable-5", "claude-opus-5", "claude-mythos-5-1",
                      "claude-haiku-4-5-20251001", "claude-made-up-9", ""])
    func nonCheckModels(model: String) {
        #expect(!AnthropicCapabilities(model: model).runsPrefixCheck)
    }

    @Test("the API gets the header for the three check models")
    func directHeader() throws {
        for model in ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"] {
            #expect(try header(model, Self.direct) == "thinking-binding-controls-2026-08-01", Comment(rawValue: model))
        }
    }

    @Test("Vertex gets it only where the probe saw it accepted: never Sonnet 5.5")
    func vertexHeader() throws {
        #expect(try header("claude-opus-5-5", Self.vertex) == AnthropicCapabilities.bindingBeta)
        #expect(try header("claude-fable-5-1", Self.vertex) == AnthropicCapabilities.bindingBeta)
        #expect(try header("claude-sonnet-5-5", Self.vertex) == nil)
    }

    @Test("no beta header reaches an unknown id or a model without the check")
    func noHeaderElsewhere() throws {
        for model in ["claude-made-up-9", "claude-sonnet-5", "claude-haiku-4-5-20251001"] {
            #expect(try header(model, Self.direct) == nil, Comment(rawValue: model))
            #expect(try header(model, Self.vertex) == nil, Comment(rawValue: model))
        }
    }

    @Test("the header adds nothing to the body: no thinking object, no block_binding")
    func bodyUnchanged() throws {
        let r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        let body = String(decoding: try AnthropicClient.makeURLRequest(request: r, model: "claude-opus-5-5",
                                                                       transport: Self.direct, stream: true).httpBody ?? Data(),
                          as: UTF8.self)
        #expect(!body.contains("thinking"))
        #expect(!body.contains("block_binding"))
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh AnthropicCapabilitiesTests`. Expected: the build fails with "cannot find 'AnthropicCapabilities' in scope".

- [ ] **Step 3: Implement.** Create `Sources/iris/AnthropicCapabilities.swift`:

```swift
import Foundation

/// #314 decision 3: what each Anthropic model is known to do, keyed on its id with any date
/// dropped. It grows with its readers: each field arrives with the first code that reads it.
struct AnthropicCapabilities: Equatable, Sendable {
    /// The model checks that a replayed thinking block's prefix is unchanged (PTM:7 (292)).
    var runsPrefixCheck: Bool

    static let prefixCheckModels: Set<String> = ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"]
    /// Vertex validates `anthropic-beta` and answers 400 "Unexpected value(s)" for a beta it does
    /// not accept for the model. These two were seen to accept the binding beta there (work's
    /// probe, 2026-10-06); Sonnet 5.5 was not probed.
    static let vertexBindingBetaModels: Set<String> = ["claude-opus-5-5", "claude-fable-5-1"]

    static let bindingBeta = "thinking-binding-controls-2026-08-01"

    init(model: String) {
        runsPrefixCheck = Self.prefixCheckModels.contains(Self.key(model))
    }

    /// The Vertex spelling with its `@date` dropped, so the API's dated id, Vertex's and the bare
    /// alias find the same row. One normaliser with `fix/anthropic-max-tokens`'s `maxTokensKey`:
    /// whichever lands second makes one call the other.
    static func key(_ model: String) -> String {
        let vertex = AnthropicClient.vertexModelID(model.trimmingCharacters(in: .whitespaces))
        guard let at = vertex.firstIndex(of: "@") else { return vertex }
        return String(vertex[..<at])
    }

    /// Whether the binding beta may go to this model on this route (decision 4, plan note 4). A
    /// beta a route rejects is a 400 on every request, so unknown ids never get it.
    static func takesBindingBeta(model: String, transport: AnthropicTransport) -> Bool {
        switch transport {
        case .direct: return prefixCheckModels.contains(key(model))
        case .vertex: return vertexBindingBetaModels.contains(key(model))
        }
    }
}
```

In `makeURLRequest`, right after `urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")` (`:265`):

```swift
        // #314 decisions 4-5: the binding beta, header only, to the models and routes known to
        // take it, on the API and Vertex alike. Without the field it changes no behaviour: an
        // unenforced account lists mismatches in `input_transformations` and keeps the blocks.
        if AnthropicCapabilities.takesBindingBeta(model: model, transport: transport) {
            urlRequest.addValue(AnthropicCapabilities.bindingBeta, forHTTPHeaderField: "anthropic-beta")
        }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 6 tests and 12 argument cases passed. Then run `AnthropicVertexTransportTests` and `RequestByteStabilityTests`. Quote the counts.

- [ ] **Step 5: Mutation checks.**
  - Return `true` from `takesBindingBeta` for every model: `noHeaderElsewhere` fails.
  - Use `prefixCheckModels` for `.vertex` too: `vertexHeader` fails.

- [ ] **Step 6: Commit.** `feat(anthropic): send the thinking-binding beta to models known to take it (#314)`.

### Task 6: `input_transformations` and the diagnosis header, recorded and logged

**Files:**
- Create: `Sources/iris/InputTransformation.swift`
- Modify: `Sources/iris/LLMStream.swift`: two `LLMStreamEvent` cases; `StreamMapper` gains `headers(_:)` (`:63-67`); the assembler; `events(from:)`; and `LLMStreaming.stream` (`:233-268`), which calls `headers`
- Modify: `Sources/iris/AnthropicStreamMapper.swift` (`message_start`, `message_delta`, `headers`)
- Modify: `Sources/iris/AnthropicClient.swift` (`generateOnce`, `parseResponse`)
- Modify: `Sources/iris/Models.swift:204-218` (`GeminiResponse`: two non-encoded fields and `CodingKeys`)
- Modify: `Sources/iris/PerformanceProfiler.swift:46-72` (`ModelCallRecord`)
- Modify: `Sources/iris/iris.swift:2084-2096` (the record and the console line)
- Test: `Tests/irisTests/InputTransformationTests.swift` (new)

**Interfaces:**
- Produces:
  - `public struct InputTransformation: Codable, Sendable, Equatable`, with `type: String`, `path: String?` and `reason: String?`.
  - Its statics: `list(_:)`, `diagnosis(in:)`, `logLine(round:model:entries:diagnosis:)`, `diagnosisHeader`, `knownTypes` and `knownReasons`.
  - `LLMStreamEvent.inputTransformations([InputTransformation])` and `.prefixMismatchDiagnosis(String)`.
  - `GeminiResponse.anthropicInputTransformations: [InputTransformation]?` and `.anthropicPrefixDiagnosis: String?`, neither encoded.
  - `ModelCallRecord.inputTransformations: [InputTransformation]?`.
  - `StreamMapper.headers(_ fields: [AnyHashable: Any]) -> [LLMStreamEvent]`, which defaults to `[]`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

@Suite("input_transformations and the diagnosis header (#314 decision 7)")
struct InputTransformationTests {
    static let entries = #"[{"type":"thinking_dropped","path":"messages.7.content.0","reason":"prefix_binding_mismatch"},{"type":"later_kind","reason":"later_reason"}]"#

    @Test("message_start carries the array on the message object")
    func fromMessageStart() throws {
        var m = AnthropicStreamMapper()
        let events = try m.handle(SSEEvent(event: "message_start", data:
            #"{"type":"message_start","message":{"id":"m","input_transformations":\#(Self.entries),"usage":{"input_tokens":1}}}"#))
        #expect(events.contains(.inputTransformations([
            InputTransformation(type: "thinking_dropped", path: "messages.7.content.0", reason: "prefix_binding_mismatch"),
            InputTransformation(type: "later_kind", path: nil, reason: "later_reason")])))
    }

    @Test("an empty array is kept as empty, distinct from absent")
    func emptyIsNotAbsent() throws {
        var m = AnthropicStreamMapper()
        let with = try m.handle(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{"input_transformations":[]}}"#))
        #expect(with == [.inputTransformations([])])
        var n = AnthropicStreamMapper()
        #expect(try n.handle(SSEEvent(event: "message_start", data: #"{"type":"message_start","message":{}}"#)).isEmpty)
    }

    @Test("a final message_delta's array (after a server-side fallback) replaces the first")
    func fromMessageDelta() {
        var a = StreamAssembler()
        a.apply(.inputTransformations([]), now: 0)
        a.apply(.inputTransformations([InputTransformation(type: "thinking_dropped", path: "messages.1.content.0",
                                                           reason: "model_binding_mismatch")]), now: 1)
        #expect(a.response().anthropicInputTransformations?.first?.reason == "model_binding_mismatch")
    }

    @Test("message_delta is parsed too")
    func messageDeltaParsed() throws {
        var m = AnthropicStreamMapper()
        let events = try m.handle(SSEEvent(event: "message_delta", data:
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"input_transformations":[],"usage":{"output_tokens":1}}"#))
        #expect(events.contains(.inputTransformations([])))
    }

    @Test("the non-stream body carries it at the top level")
    func fromNonStream() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(
            #"{"content":[{"type":"text","text":"ok"}],"input_transformations":\#(Self.entries),"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)) as? [String: Any])
        #expect(try AnthropicClient.parseResponse(json).anthropicInputTransformations?.count == 2)
    }

    @Test("the diagnosis header is read case-insensitively, and the Anthropic mapper turns it into an event")
    func diagnosisHeader() {
        #expect(InputTransformation.diagnosis(in: ["Anthropic-Thinking-Prefix-Mismatch": "pattern=x"]) == "pattern=x")
        #expect(InputTransformation.diagnosis(in: ["other": "y"]) == nil)
        var m = AnthropicStreamMapper()
        #expect(m.headers(["anthropic-thinking-prefix-mismatch": "pattern=x"]) == [.prefixMismatchDiagnosis("pattern=x")])
    }

    @Test("the console line names known entries and the header, ignores unknown ones, and is nil when empty")
    func logLine() {
        let known = InputTransformation(type: "thinking_dropped", path: "messages.7.content.0", reason: "prefix_binding_mismatch")
        let unknown = InputTransformation(type: "later_kind", path: nil, reason: "later_reason")
        #expect(InputTransformation.logLine(round: 2, model: "claude-opus-5-5", entries: [known, unknown], diagnosis: "pattern=x")
                == "Anthropic thinking (claude-opus-5-5, round 2): thinking_dropped/prefix_binding_mismatch at messages.7.content.0; anthropic-thinking-prefix-mismatch: pattern=x")
        #expect(InputTransformation.logLine(round: 0, model: "m", entries: [], diagnosis: nil) == nil)
        #expect(InputTransformation.logLine(round: 0, model: "m", entries: [unknown], diagnosis: nil) == nil)
        #expect(InputTransformation.logLine(round: 0, model: "m", entries: nil, diagnosis: nil) == nil)
    }

    @Test("a perf record written before #314 decodes, with no transformations")
    func oldRecordDecodes() throws {
        let json = #"{"round":0,"model":"m","latencyMs":1,"returnedToolCalls":false}"#
        let r = try JSONDecoder().decode(ModelCallRecord.self, from: Data(json.utf8))
        #expect(r.inputTransformations == nil)
    }

    @Test("the fields are never encoded into the AfterModel payload, and replay as events")
    func notEncodedButReplayed() throws {
        var response = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        response.anthropicInputTransformations = []
        response.anthropicPrefixDiagnosis = "pattern=x"
        #expect(!String(decoding: try JSONEncoder().encode(response), as: UTF8.self).contains("pattern=x"))
        var a = StreamAssembler()
        for e in LLMStreamEvent.events(from: response) { a.apply(e, now: 0) }
        #expect(a.response().anthropicInputTransformations == [])
        #expect(a.response().anthropicPrefixDiagnosis == "pattern=x")
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh InputTransformationTests`. Expected: the build fails with "cannot find 'InputTransformation' in scope".

- [ ] **Step 3: Implement.** Create `Sources/iris/InputTransformation.swift`:

```swift
import Foundation

/// #314 decision 7: one entry of Anthropic's top-level `input_transformations`, present on every
/// response when the binding beta is sent (`[]` when nothing happened). Kept raw: an unknown type
/// or reason is stored and otherwise ignored (PTM:145). Phase 2 counts breaks by signature.
public struct InputTransformation: Codable, Sendable, Equatable {
    public var type: String
    public var path: String?
    public var reason: String?

    public init(type: String, path: String? = nil, reason: String? = nil) {
        self.type = type; self.path = path; self.reason = reason
    }

    static let knownTypes: Set<String> = ["thinking_dropped", "thinking_mismatch_allowed"]
    static let knownReasons: Set<String> = ["prefix_binding_mismatch", "model_binding_mismatch"]
    /// "Use it if present; never depend on it" (PTM:146).
    static let diagnosisHeader = "anthropic-thinking-prefix-mismatch"

    /// The entries of a decoded `input_transformations` value; nil when it is absent or not an array.
    static func list(_ value: Any?) -> [InputTransformation]? {
        guard let array = value as? [[String: Any]] else { return nil }
        return array.compactMap { entry in
            (entry["type"] as? String).map {
                InputTransformation(type: $0, path: entry["path"] as? String, reason: entry["reason"] as? String)
            }
        }
    }

    static func diagnosis(in headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers where (key as? String)?.lowercased() == diagnosisHeader {
            return value as? String
        }
        return nil
    }

    /// One console line for a round, or nil when there is nothing known to report. No pill.
    static func logLine(round: Int, model: String, entries: [InputTransformation]?, diagnosis: String?) -> String? {
        let known = (entries ?? []).filter { knownTypes.contains($0.type) && $0.reason.map(knownReasons.contains) == true }
        guard !known.isEmpty || diagnosis != nil else { return nil }
        var line = "Anthropic thinking (\(model), round \(round)): "
        line += known.isEmpty ? "no transformations"
            : known.map { "\($0.type)/\($0.reason ?? "") at \($0.path ?? "?")" }.joined(separator: ", ")
        if let diagnosis { line += "; \(diagnosisHeader): \(diagnosis)" }
        return line
    }
}
```

In `LLMStream.swift`:

```swift
    /// #314: Anthropic's `input_transformations` for this response. A later one replaces it.
    case inputTransformations([InputTransformation])
    /// #314: the `anthropic-thinking-prefix-mismatch` response header, when present.
    case prefixMismatchDiagnosis(String)
```

```swift
protocol StreamMapper: Sendable {
    mutating func handle(_ sse: SSEEvent) throws -> [LLMStreamEvent]
    /// Called once after the last SSE event. Emits `done` if the provider never did.
    mutating func finish() throws -> [LLMStreamEvent]
    /// Called once with a 200's headers, before any SSE event.
    mutating func headers(_ fields: [AnyHashable: Any]) -> [LLMStreamEvent]
}

extension StreamMapper {
    mutating func headers(_ fields: [AnyHashable: Any]) -> [LLMStreamEvent] { [] }
```

Keep the existing `decodeArguments` in that same extension.

In `LLMStreaming.stream`, move `var mapper = mapper` above the byte loop and add, right after the status check:

```swift
                    var mapper = mapper
                    for event in mapper.headers(http.allHeaderFields) { continuation.yield(event) }
```

Delete the old `var mapper = mapper` line.

Assembler:

```swift
    private(set) var inputTransformations: [InputTransformation]?
    private(set) var prefixMismatchDiagnosis: String?
```

```swift
        case .inputTransformations(let entries):
            inputTransformations = entries
        case .prefixMismatchDiagnosis(let value):
            prefixMismatchDiagnosis = value
```

In `response()`, before `return response`:

```swift
        response.anthropicInputTransformations = inputTransformations
        response.anthropicPrefixDiagnosis = prefixMismatchDiagnosis
```

In `events(from:)`, before the `.done` append:

```swift
        if let entries = response.anthropicInputTransformations { out.append(.inputTransformations(entries)) }
        if let diagnosis = response.anthropicPrefixDiagnosis { out.append(.prefixMismatchDiagnosis(diagnosis)) }
```

In `GeminiResponse`:

```swift
    /// #314 decision 7: Anthropic's `input_transformations` and diagnosis header. Never encoded:
    /// this type is the AfterModel payload and Gemini's response shape.
    var anthropicInputTransformations: [InputTransformation]? = nil
    var anthropicPrefixDiagnosis: String? = nil

    private enum CodingKeys: String, CodingKey { case candidates, usageMetadata, promptFeedback }
```

In `AnthropicStreamMapper`, rebuild `message_start` to collect `out`, and add `headers`:

```swift
        case "message_start":
            var out: [LLMStreamEvent] = []
            let message = json["message"] as? [String: Any]
            if let usage = message?["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int
                let cacheRead = usage["cache_read_input_tokens"] as? Int
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int
                // (the existing 5a F8 comment stays here, unchanged)
                if let prompt = UsageMetadata.anthropicPromptTokenCount(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite) {
                    out.append(.usage(UsageMetadata(promptTokenCount: prompt, candidatesTokenCount: nil, totalTokenCount: nil,
                                                    cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                                                    cacheWrite1hTokens: UsageMetadata.anthropicOneHourWrites(usage))))
                }
            }
            if let entries = InputTransformation.list(message?["input_transformations"]) {
                out.append(.inputTransformations(entries))
            }
            return out
```

In `message_delta`, before `return out`:

```swift
            if let entries = InputTransformation.list(json["input_transformations"]) { out.append(.inputTransformations(entries)) }
```

```swift
    mutating func headers(_ fields: [AnyHashable: Any]) -> [LLMStreamEvent] {
        InputTransformation.diagnosis(in: fields).map { [.prefixMismatchDiagnosis($0)] } ?? []
    }
```

In `parseResponse`, before `return geminiResponse`:

```swift
        geminiResponse.anthropicInputTransformations = InputTransformation.list(json["input_transformations"])
```

In `generateOnce`:

```swift
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var parsed = try parseResponse(json, raw: data)
        parsed.anthropicPrefixDiagnosis = InputTransformation.diagnosis(in: httpResponse.allHeaderFields)
        return parsed
```

In `ModelCallRecord`, add `public var inputTransformations: [InputTransformation]? = nil`, with a doc line: "#314: Anthropic's entries for this call. Nil without the beta header and on records older than #314." Add it to `init` as a trailing `inputTransformations: [InputTransformation]? = nil` parameter.

In `iris.swift:2084-2096`, read the model once, pass the field, and print:

```swift
                let modelName = ConfigManager.shared.getModel(for: modelTier)
                PerformanceProfiler.shared.recordModelCall(
                    turnID: PerformanceProfiler.currentTurnID,
                    ModelCallRecord(
                        round: modelRound,
                        model: modelName,
                        // (the other arguments unchanged)
                        cacheWrite1hTokens: response.usageMetadata?.cacheWrite1hTokens,
                        inputTransformations: response.anthropicInputTransformations))
                if let line = InputTransformation.logLine(round: modelRound, model: modelName,
                                                          entries: response.anthropicInputTransformations,
                                                          diagnosis: response.anthropicPrefixDiagnosis) {
                    print(line)
                }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 9 passed. Then run `AnthropicStreamMapperTests`, `GeminiStreamMapperTests`, `OpenAIStreamMapperTests`, `StreamingClientTests` and `PerfLadderTests`. Quote the counts.

- [ ] **Step 5: Mutation checks.**
  - Return `nil` from `list` when the array is empty: `emptyIsNotAbsent` fails.
  - Let `logLine` count unknown entries: `logLine` fails.

- [ ] **Step 6: Commit.** `feat(anthropic): record input_transformations and the diagnosis header (#314)`.

### Task 7: `AppendOnlyRequestTests`, within a turn

**Files:**
- Test: `Tests/irisTests/AppendOnlyRequestTests.swift` (new)

**Interfaces:**
- Consumes: `ThinkingHarness` and `ThinkingFixtures` (Task 4); the binding header (Task 5).
- Produces: the suite that PR 2's Task 11 extends.

- [ ] **Step 1: Write the tests.** They characterise PR 1's wire, so they pass on first run. That is expected: Task 11 makes them fail, by design, where replay begins.

```swift
import Testing
import Foundation
@testable import iris

/// Spec §2.1, PRs 1-2: within one turn, each request's messages extend the last request's,
/// ignoring `cache_control`. Bodies come from `AnthropicClient.makeURLRequest`, the RequestDump
/// path; replies carry fake signed blocks, which no signature check reads here.
@MainActor
@Suite("Append-only requests within a turn (#314)", .timeLimit(.minutes(1)))
struct AppendOnlyRequestTests {
    private func expectPrefixChain(_ h: ThinkingHarness, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let bodies = try h.client.requests.map { try ThinkingFixtures.messagesIgnoringCacheControl(try ThinkingFixtures.body($0)) }
        for n in bodies.indices.dropLast() {
            #expect(Array(bodies[n + 1].prefix(bodies[n].count)) == bodies[n],
                    "request \(n + 2) does not extend request \(n + 1)", sourceLocation: sourceLocation)
        }
    }

    @Test("each request of a four-round turn extends the one before")
    func prefixChain() async throws {
        let dir = try ThinkingFixtures.tempDirectory("chain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir),
                                         earlierTurn: true)
        await h.run()
        try #require(h.client.requests.count == 4)
        try expectPrefixChain(h)
    }

    @Test("replies that did not think keep the chain too")
    func prefixChainUnthought() async throws {
        let dir = try ThinkingFixtures.tempDirectory("chain-unthought")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = [ThinkingFixtures.unthought(1, toolCall: true), ThinkingFixtures.reply(2, toolCall: true),
                      ThinkingFixtures.unthought(3, toolCall: false)]
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        try #require(h.client.requests.count == 3)
        try expectPrefixChain(h)
    }

    @Test("PR 1 sends no block back: no request carries a thinking block or the stored field")
    func noThinkingOnTheWire() async throws {
        let dir = try ThinkingFixtures.tempDirectory("nowire")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir),
                                         earlierTurn: true)
        await h.run()
        for request in h.client.requests {
            let text = try ThinkingFixtures.bodyText(request)
            #expect(!text.contains("sig-"))
            #expect(!text.contains("anthropicBlocks"))
        }
    }

    @Test("no beta header reaches an unknown id; a check model gets it on every request")
    func headerPerModel() async throws {
        let dir = try ThinkingFixtures.tempDirectory("header")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try ThinkingHarness.make(ThinkingFixtures.fourRounds(), hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        for request in h.client.requests {
            #expect(try ThinkingFixtures.urlRequest(request, model: "claude-made-up-9").value(forHTTPHeaderField: "anthropic-beta") == nil)
            #expect(try ThinkingFixtures.urlRequest(request).value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
        }
    }
}
```

- [ ] **Step 2: Run them.** Run `timeout 300 scripts/test-filter.sh AppendOnlyRequestTests`. Expected: 4 passed. Quote the count.

- [ ] **Step 3: Mutation check.** In `AnthropicClient`, mark each message with a fresh `UUID().uuidString` text part. `prefixChain` must fail. Restore, and run again.

- [ ] **Step 4: Commit.** `test: within-turn append-only request checks (#314)`.

### Task 8: Invariant 9 sweep, and open PR 1

- [ ] **Step 1: Run the greps and read every hit.**
  - `grep -rn "thinking\|signature" Sources/iris/AnthropicStreamMapper.swift Sources/iris/AnthropicClient.swift Sources/iris/LLMStream.swift`. The mapper's old doc comment said thinking deltas are dropped (Task 2 rewrote it). Check that nothing else still says so.
  - `grep -rn "anthropic-beta\|no beta\|sends no" Sources docs/*.md README.md`. `AnthropicClient.cacheControl`'s comment ("no beta header: 5c spec facts") is about `ttl`, and is still true. Any sentence saying Iris sends no beta is now false.
  - `grep -n "Anthropic" README.md`. Read the "LLM Engine" bullet (`:19`) and the "Token Tracking & Diagnostics" bullet (`:26`).
  - `grep -rn "thinking" Sources/iris/assets/SYSTEM.md AGENTS.md`. Expect nothing to change: no agent-facing behaviour changed in PR 1.
- [ ] **Step 2: Fix what you found.** Append this sentence to README's "Token Tracking & Diagnostics" bullet: "On Claude Opus 5.5, Fable 5.1 and Sonnet 5.5 (on Vertex AI, Opus 5.5 and Fable 5.1), Iris sends Anthropic's thinking-binding beta header and records the response's `input_transformations` on each model call, with a console line whenever thinking was dropped or would have been." Then run the full suite (`timeout 900 swift test`); green means all three signals. Commit with `docs: thinking storage and the binding beta, swept (#314)`.
- [ ] **Step 3: Open PR 1.** Title: `feat(anthropic): keep each reply's blocks; binding beta and input_transformations (#314)`. The body lists:
  - that it depends on the spec, PR #384;
  - the Review Focus items it owns (1, 2);
  - plan notes 4, 7, 8, 10 and 11;
  - the `fix/anthropic-max-tokens` rebase note from Global Constraints.

---

## PR 2: Phase 1 replay, the event rule, and the `drop_block` backstop

Branch: `feat/314-thinking-replay`, cut from `main` after PR 1 has merged.

### Task 9: `AnthropicClient` echoes stored blocks verbatim, front-drop only

**Files:**
- Modify: `Sources/iris/AnthropicBlocks.swift` (add `echoable` and `withCacheControl`)
- Modify: `Sources/iris/AnthropicClient.swift:57-123` (the message builder), `:149-174` (the markers) and `:266` (serialisation)
- Test: `Tests/irisTests/AnthropicReplayEncodingTests.swift` (new)

**Interfaces:**
- Consumes: `Content.anthropicBlocks` and `AnthropicBlocks.storable` (PR 1).
- Produces: `AnthropicBlocks.echoable(_ content: Content) -> Bool` and `AnthropicBlocks.withCacheControl(_ raw: String, _ cacheControl: String) -> String`.
  - The client echoes whatever `anthropicBlocks` it is handed. Choosing which ones to hand it is the engine's job (Task 11).

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

@Suite("Anthropic replay encoding (#314)")
struct AnthropicReplayEncodingTests {
    private func toolReply(_ n: Int, callID: String? = nil, blocks: Bool = true) -> Content {
        var c = ThinkingFixtures.reply(n, toolCall: true).candidates![0].content!
        if let callID { c.parts[0].functionCall?.id = callID }
        if !blocks { c.anthropicBlocks = nil }
        return c
    }
    private func result(_ n: Int) -> Content {
        Content(role: "user", parts: [Part(functionResponse: FunctionResponse(name: "search_memory",
                                                                              response: ["result": .string("r\(n)")],
                                                                              id: "toolu_\(n)"))])
    }
    private func request(_ contents: [Content]) -> GeminiRequest {
        GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "Tell me about Seattle")])] + contents,
                      systemInstruction: Content(role: "system", parts: [Part(text: "sys")]), tools: nil)
    }

    @Test("a stored reply goes out exactly as received, tool input bytes included")
    func echoesVerbatim() throws {
        let r = request([toolReply(1), result(1)])
        let text = try ThinkingFixtures.bodyText(r)
        #expect(text.contains(r.contents[1].anthropicBlocks!))
        #expect(text.contains(#"{"query": "Seattle 1"}"#), "the model's own spacing, never re-serialised")
        let body = try ThinkingFixtures.body(r)
        #expect(ThinkingFixtures.signatures(body) == ["sig-1"])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let toolResult = (messages[2]["content"] as? [[String: Any]])?.first
        #expect(toolResult?["tool_use_id"] as? String == "toolu_1")
    }

    @Test("a reply with no blocks is built from parts as before #314, and no splice token leaks")
    func partsWhenNoBlocks() throws {
        let text = try ThinkingFixtures.bodyText(request([toolReply(1, blocks: false), result(1)]))
        #expect(text.contains(#""input":{"query":"Seattle 1"}"#), "built from the call's args, sorted and compact")
        #expect(!text.contains("IRIS_ANTHROPIC_BLOCKS"))
        #expect(!text.contains("sig-1"))
    }

    @Test("a reply whose blocks can't be echoed takes every earlier reply's with it: no middle gap")
    func unechoableTakesEarlierWithIt() throws {
        let r = request([toolReply(1), result(1), toolReply(2, callID: "toolu_rewritten"), result(2),
                         toolReply(3), result(3)])
        #expect(ThinkingFixtures.signatures(try ThinkingFixtures.body(r)) == ["sig-3"])
    }

    @Test("a marker on an echoed reply lands inside its last block when that is not thinking")
    func markerInsideLastBlock() throws {
        let r = request([toolReply(1)])   // the reply is the last message: marker (d)
        let messages = try #require(try ThinkingFixtures.body(r)["messages"] as? [[String: Any]])
        let last = try #require((messages.last?["content"] as? [[String: Any]])?.last)
        #expect(last["type"] as? String == "tool_use")
        #expect(last["cache_control"] != nil)
    }

    @Test("a marker never lands on a thinking block (Review Focus 3)")
    func markerSkipsAThinkingBlock() throws {
        var reply = toolReply(1)
        reply.parts = []
        reply.anthropicBlocks = "[\(ThinkingFixtures.thinkingBlock(1))]"
        let r = request([reply])
        let messages = try #require(try ThinkingFixtures.body(r)["messages"] as? [[String: Any]])
        let blocks = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(blocks.allSatisfy { $0["cache_control"] == nil })
    }

    @Test("echoed bodies are valid JSON and byte-stable across builds")
    func byteStable() throws {
        let r = request([toolReply(1), result(1), toolReply(2), result(2)])
        #expect(try ThinkingFixtures.bodyText(r) == ThinkingFixtures.bodyText(r))
        _ = try ThinkingFixtures.body(r)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh AnthropicReplayEncodingTests`. Expected: `echoesVerbatim`, `unechoableTakesEarlierWithIt` and `markerInsideLastBlock` fail, because no block is echoed yet.

- [ ] **Step 3: Implement.** Append to `AnthropicBlocks`:

```swift
    /// Whether `content`'s stored blocks can go out as received: an assistant reply whose array is
    /// storable and whose tool_use blocks name the same calls, in the same order, as its parts. A
    /// mismatch means something changed the parts after the blocks were stored.
    static func echoable(_ content: Content) -> Bool {
        guard content.role == "model", let raw = content.anthropicBlocks, storable(raw) != nil,
              let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] else { return false }
        let blockCalls = array.filter { $0["type"] as? String == "tool_use" }
            .map { "\($0["id"] as? String ?? "")|\($0["name"] as? String ?? "")" }
        let partCalls = content.parts.compactMap(\.functionCall).map { "\($0.id ?? "")|\($0.name)" }
        return blockCalls == partCalls
    }

    /// `raw` with `cacheControl` (a JSON object's text) merged into its last block, or `raw`
    /// unchanged when that block is a thinking block, which takes no `cache_control`.
    static func withCacheControl(_ raw: String, _ cacheControl: String) -> String {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]],
              let lastType = array.last?["type"] as? String,
              lastType != "thinking", lastType != "redacted_thinking",
              let close = raw.lastIndex(of: "]"),
              let brace = raw[..<close].lastIndex(of: "}") else { return raw }
        // Only whitespace sits between the last block's closing brace and the array's bracket.
        return String(raw[..<brace]) + #","cache_control":"# + cacheControl + String(raw[brace...])
    }
```

In `makeURLRequest`, replace `:64-123` (from `var callIdCounter` to the end of the `for content` loop):

```swift
        var callIdCounter = 0
        var pendingIdsForName: [String: [String]] = [:]
        func register(_ fc: FunctionCall) -> String {
            let id = fc.id ?? "call_\(fc.name)_\(callIdCounter)"
            callIdCounter += 1
            pendingIdsForName[fc.name, default: []].append(id)
            return id
        }

        // #314 decision 2: a reply's stored blocks go out exactly as received. Only a front run is
        // ever dropped: a reply whose blocks cannot be echoed takes every earlier reply's with it,
        // so no gap opens in the middle (PTM §3).
        let lastUnechoable = request.contents.indices.last {
            request.contents[$0].anthropicBlocks != nil && !AnthropicBlocks.echoable(request.contents[$0])
        }
        let echoFrom = (lastUnechoable ?? -1) + 1
        // Spliced in after serialisation, so the blocks are never re-encoded. The token is unique
        // per request, and in its quoted form it cannot occur inside any other JSON string.
        let spliceToken = "IRIS_ANTHROPIC_BLOCKS_\(UUID().uuidString)_"
        var echoed: [Int: String] = [:]

        for (contentIndex, content) in request.contents.enumerated() {
            let role = content.role == "model" ? "assistant" : "user"
            if contentIndex >= echoFrom, let raw = content.anthropicBlocks {
                for part in content.parts { if let fc = part.functionCall { _ = register(fc) } }
                echoed[anthropicMessages.count] = raw
                anthropicMessages.append(["role": role, "content": spliceToken + String(anthropicMessages.count)])
                continue
            }
            var partsArray: [[String: Any]] = []
            for part in content.parts {
                if let text = part.text {
                    partsArray.append(["type": "text", "text": text])
                }
                if let inline = part.inlineData {
                    partsArray.append(["type": "image",
                                       "source": ["type": "base64", "media_type": inline.mimeType, "data": inline.data]])
                }
                if let fc = part.functionCall {
                    let id = register(fc)
                    partsArray.append(["type": "tool_use", "id": id, "name": fc.name,
                                       "input": fc.args.mapValues { $0.anyValue }])
                } else if let fr = part.functionResponse {
                    // (the existing tool_result branch, :96-114, unchanged)
                }
            }
            if !partsArray.isEmpty {
                anthropicMessages.append(["role": role, "content": partsArray])
            }
        }
```

Replace the marker loop at `:172-174`:

```swift
        var markedEchoes = Set<Int>()
        for index in marked.sorted() {
            // An echoed reply's content is still a token here; its marker is merged after the splice.
            if echoed[index] != nil { markedEchoes.insert(index) } else { markLastContentBlock(&anthropicMessages, at: index) }
        }
```

Replace `:266`:

```swift
        var bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        if !echoed.isEmpty {
            let marker = String(decoding: try JSONSerialization.data(withJSONObject: Self.cacheControl(ttl.history),
                                                                     options: [.sortedKeys]), as: UTF8.self)
            var text = String(decoding: bodyData, as: UTF8.self)
            for (index, raw) in echoed {
                let blocks = markedEchoes.contains(index) ? AnthropicBlocks.withCacheControl(raw, marker) : raw
                text = text.replacingOccurrences(of: "\"\(spliceToken)\(index)\"", with: blocks)
            }
            bodyData = Data(text.utf8)
        }
        urlRequest.httpBody = bodyData
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 6 passed. Then run `AnthropicClientTests`, `AnthropicCacheBreakpointTests` and `RequestByteStabilityTests`. Expect `AppendOnlyRequestTests.noThinkingOnTheWire` to fail now: Task 11 replaces it. Quote the counts.

- [ ] **Step 5: Mutation checks.**
  - Echo every echoable reply on its own (drop `echoFrom`, test each reply alone): `unechoableTakesEarlierWithIt` fails.
  - Delete the thinking guard in `withCacheControl`: `markerSkipsAThinkingBlock` fails.

- [ ] **Step 6: Commit.** `feat(anthropic): echo stored blocks verbatim, dropping only a front run (#314)`.

### Task 10: `ThinkingReplay`, the per-turn floor

**Files:**
- Create: `Sources/iris/ThinkingReplay.swift`
- Test: `Tests/irisTests/ThinkingReplayTests.swift` (new)

**Interfaces:**
- Produces: `struct ThinkingReplay: Sendable`, with:
  - `init(floor: Int)` and `private(set) var floor: Int`;
  - `mutating func raiseFloor(to: Int)`;
  - `func applyingFloor(_: [Content]) -> [Content]`;
  - `static func withoutBlocks(_: [Content]) -> [Content]`;
  - `func continues(_: [Content]) -> Bool`;
  - `mutating func recordSent(_: [Content])`;
  - `static func fingerprint(_: Content) -> Data`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

@Suite("ThinkingReplay (#314 decision 2)")
struct ThinkingReplayTests {
    private func user(_ t: String) -> Content { Content(role: "user", parts: [Part(text: t)]) }
    private func model(_ t: String, _ sig: String?) -> Content {
        Content(role: "model", parts: [Part(text: t)],
                anthropicBlocks: sig.map { "[\(ThinkingFixtures.thinkingBlock(Int($0.dropFirst(4))!)),{\"type\":\"text\",\"text\":\"\(t)\"}]" })
    }

    @Test("blocks below the floor are removed; at and above it they stay")
    func floorStrips() {
        let contents = [user("a"), model("b", "sig-0"), user("c"), model("d", "sig-1")]
        let out = ThinkingReplay(floor: 3).applyingFloor(contents)
        #expect(out.map { $0.anthropicBlocks != nil } == [false, false, false, true])
        #expect(out.map(\.parts.first?.text) == contents.map(\.parts.first?.text))
    }

    @Test("the floor only rises: a block left out once stays out")
    func floorIsMonotonic() {
        var r = ThinkingReplay(floor: 3)
        r.raiseFloor(to: 6)
        r.raiseFloor(to: 4)
        #expect(r.floor == 6)
    }

    @Test("an appended request continues the last one; the first request of a turn always does")
    func appendContinues() {
        var r = ThinkingReplay(floor: 0)
        #expect(r.continues([user("a")]))
        r.recordSent([user("a")])
        #expect(r.continues([user("a"), model("b", "sig-1"), user("c")]))
    }

    @Test("an edited, removed or reordered earlier message does not continue it")
    func editBreaks() {
        var r = ThinkingReplay(floor: 0)
        r.recordSent([user("a"), model("b", "sig-1"), user("c")])
        #expect(!r.continues([user("A"), model("b", "sig-1"), user("c")]))
        #expect(!r.continues([user("a"), user("c")]))
        #expect(!r.continues([user("c"), model("b", "sig-1"), user("a")]))
    }

    @Test("stripping blocks from the front is not an edit")
    func stripIsNotAnEdit() {
        var r = ThinkingReplay(floor: 0)
        r.recordSent([user("a"), model("b", "sig-1"), user("c")])
        #expect(r.continues(ThinkingReplay.withoutBlocks([user("a"), model("b", "sig-1"), user("c"), user("d")])))
    }

    @Test("the fingerprint ignores image bytes of the same type and length, never text")
    func fingerprintCheapButExact() {
        let a = Content(role: "user", parts: [Part(text: "x"), Part(inlineData: InlineData(mimeType: "image/png", data: "AAAA"))])
        let b = Content(role: "user", parts: [Part(text: "x"), Part(inlineData: InlineData(mimeType: "image/png", data: "BBBB"))])
        #expect(ThinkingReplay.fingerprint(a) == ThinkingReplay.fingerprint(b))
        #expect(ThinkingReplay.fingerprint(a) != ThinkingReplay.fingerprint(user("y")))
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh ThinkingReplayTests`. Expected: the build fails with "cannot find 'ThinkingReplay' in scope".

- [ ] **Step 3: Implement.** Create `Sources/iris/ThinkingReplay.swift`:

```swift
import Foundation

/// #314 Phase 1 (spec decision 2): which thinking blocks one turn sends back. Only this turn's
/// replies, and only those after the turn's latest prefix edit, so whatever is left out is always
/// a run dropped from the front, the one drop the API accepts (PTM §3). One value per turn, a
/// local of `processInputBody`: never on the engine or `AppState`, where another turn or a
/// subagent would share it (invariant 3).
struct ThinkingReplay: Sendable {
    /// History index (AppState's list) below which no blocks are sent. Only ever rises.
    private(set) var floor: Int
    /// The last request this turn sent, one fingerprint per message, blocks excluded.
    private var lastSent: [Data]?

    init(floor: Int) { self.floor = floor }

    mutating func raiseFloor(to index: Int) { floor = max(floor, index) }

    func applyingFloor(_ contents: [Content]) -> [Content] {
        var out = contents
        for i in out.indices where i < floor { out[i].anthropicBlocks = nil }
        return out
    }

    static func withoutBlocks(_ contents: [Content]) -> [Content] {
        contents.map { var c = $0; c.anthropicBlocks = nil; return c }
    }

    /// Whether the last request this turn sent is still a prefix of `contents`. The check behind
    /// plan notes 1-2: it sees a UI edit (5a's `firstDrop` and the rest), the PreCompress list
    /// giving way to AppState's, and a hook that stopped rewriting. Blocks are left out of the
    /// comparison, because dropping them from the front is not an edit.
    func continues(_ contents: [Content]) -> Bool {
        guard let lastSent else { return true }
        guard contents.count >= lastSent.count else { return false }
        for i in lastSent.indices where Self.fingerprint(contents[i]) != lastSent[i] { return false }
        return true
    }

    mutating func recordSent(_ contents: [Content]) { lastSent = contents.map(Self.fingerprint) }

    /// 5a's anchor bytes with the blocks removed: sorted keys, images stood in for by type and length.
    static func fingerprint(_ content: Content) -> Data {
        var bare = content
        bare.anthropicBlocks = nil
        return TurnContext.anchorBytes(of: bare) ?? Data()
    }
}
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 6 passed. Quote the count.

- [ ] **Step 5: Mutation checks.**
  - Make `raiseFloor` assign (`floor = index`): `floorIsMonotonic` fails.
  - Keep `anthropicBlocks` in `fingerprint`: `stripIsNotAnEdit` fails.

- [ ] **Step 6: Commit.** `feat: ThinkingReplay, the per-turn replay floor (#314)`.

### Task 11: The engine replays this turn's blocks, and raises the floor on every event

**Files:**
- Modify: `Sources/iris/iris.swift`:
  - `:1956-1958`: the floor, and round one with no blocks;
  - `:2035-2057`: before and after the BeforeModel hook;
  - `:2131-2137`: the AfterModel event;
  - a new `stateHistoryCount(_:)` helper beside `requestContents` (`:1160`).
- Test: `Tests/irisTests/AppendOnlyRequestTests.swift`. Replace `noThinkingOnTheWire` and add the cases below.

**Interfaces:**
- Consumes: `ThinkingReplay` (Task 10), `HookRewrite` (PR 1), and the client's echo (Task 9).
- Produces: `IrisEngine.stateHistoryCount(_ conversationId: UUID) async -> Int` (private).

- [ ] **Step 1: Write the failing tests.** In `AppendOnlyRequestTests`, delete `noThinkingOnTheWire` and add the cases below.
  - Request 1 never carries a block. Request N can carry blocks from replies 1 to N-1.
  - A UI edit in `roundStart(1)` is first read when request 3 is built: request 2's contents were taken from history before round two started.

```swift
    private static let produced: [String?] = ["sig-1", "sig-2", "sig-3", "sig-4"]

    /// One harness, one turn per input, every request of the script answered. Hook scripts get the
    /// test's temp dir (for counter files); `roundStart` gets a handle on the harness's history.
    private func run(_ label: String, hooks scripts: [String: (URL) -> String] = [:],
                     script: [GeminiResponse] = ThinkingFixtures.fourRounds(),
                     inputs: [String] = ["Tell me about Seattle"],
                     seedFact: Bool = false, earlierTurn: Bool = true,
                     roundStart: ((ThinkingHarness.Edit) -> @Sendable (Int) async -> Void)? = nil) async throws -> ThinkingHarness {
        let dir = try ThinkingFixtures.tempDirectory(label)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hooks = try ThinkingFixtures.hooks(in: dir, scripts.mapValues { $0(dir) })
        let edit = ThinkingHarness.Edit()
        let h = try ThinkingHarness.make(script, hooks: hooks, seedFact: seedFact, earlierTurn: earlierTurn,
                                         roundStart: roundStart?(edit))
        edit.bind(h)
        for input in inputs { await h.run(input) }
        try #require(h.client.requests.count == script.count)
        return h
    }

    @Test("baseline: each request sends this turn's blocks, oldest first, verbatim; never an older turn's")
    func baselineReplay() async throws {
        let h = try await run("baseline")
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], ["sig-1", "sig-2"], ["sig-1", "sig-2", "sig-3"]])
        #expect(!sent.joined().contains("sig-0"), "the earlier turn's reply never sends its block")
        #expect(try ThinkingFixtures.bodyText(h.client.requests[1]).contains(#"{"query": "Seattle 1"}"#))
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
        try expectPrefixChain(h)
    }

    @Test("a reply that did not think leaves no gap: the window skips it")
    func unthoughtReplyInTheMiddle() async throws {
        let script = [ThinkingFixtures.reply(1, toolCall: true), ThinkingFixtures.unthought(2, toolCall: true),
                      ThinkingFixtures.reply(3, toolCall: true), ThinkingFixtures.reply(4, toolCall: false)]
        let h = try await run("unthought", script: script)
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], ["sig-1"], ["sig-1", "sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: ["sig-1", nil, "sig-3", "sig-4"])
    }

    @Test("pass-through hooks on every event keep the baseline (Review Focus 2)")
    func passThroughHooksKeepReplay() async throws {
        let h = try await run("passthrough", hooks: ["BeforeModel": { _ in "cat" }, "PreCompress": { _ in "cat" },
                                                     "AfterModel": { _ in "cat" }])
        #expect(try h.sentSignatures() == [[], ["sig-1"], ["sig-1", "sig-2"], ["sig-1", "sig-2", "sig-3"]])
    }

    @Test("event: an AfterModel rewrite of round two stops replay through round two")
    func afterModelRewrite() async throws {
        let h = try await run("aftermodel", hooks: ["AfterModel": { dir in
            ThinkingFixtures.onCall(2, sed: "s/Seattle 2/Seattle two/g", counter: dir.appendingPathComponent("n")) }])
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: ["sig-1", nil, "sig-3", "sig-4"])
    }

    @Test("event: a UI edit of the turn's entry (5a's firstDrop) stops replay of everything before it")
    func uiEditOfTheEntry() async throws {
        let h = try await run("firstdrop", seedFact: true, earlierTurn: false, roundStart: { edit in
            { round in if round == 1 { await edit.replaceText(of: 0, with: "Tell me about Portland") } } })
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("event: a UI edit of an older message on a turn with no context (plan note 1)")
    func uiEditWithoutContext() async throws {
        let h = try await run("edit-nocontext", roundStart: { edit in
            { round in if round == 1 { await edit.replaceText(of: 0, with: "earlier question, edited") } } })
        let sent = try h.sentSignatures()
        #expect(sent == [[], ["sig-1"], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("event: a PreCompress hook that modified history; the break falls at round two")
    func preCompressModified() async throws {
        let h = try await run("precompress", hooks: ["PreCompress": { _ in "sed 's/earlier question/EARLIER question/'" }])
        let sent = try h.sentSignatures()
        #expect(sent == [[], [], ["sig-2"], ["sig-2", "sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("a PreCompress hook that prepends never makes round one send an older turn's block (Review Focus 5)")
    func preCompressPrependSendsNoOldBlocks() async throws {
        let prepend = #"sed '1s/^\[/[{"role":"user","parts":[{"text":"s1"}]},{"role":"model","parts":[{"text":"s2"}]},/'"#
        let h = try await run("prepend", hooks: ["PreCompress": { _ in prepend }])
        #expect(try ThinkingFixtures.signatures(ThinkingFixtures.body(h.client.requests[0])).isEmpty)
        #expect(h.client.requests[0].contents.count == 5, "precondition: the hook's list reached round one")
    }

    @Test("event: a BeforeModel rewrite of request two strips its blocks from the hook's output, and the next request too")
    func beforeModelRewriteOnce() async throws {
        let h = try await run("beforemodel-once", hooks: ["BeforeModel": { dir in
            ThinkingFixtures.onCall(2, sed: "s/Tell me about Seattle/TELL me about Seattle/", counter: dir.appendingPathComponent("n")) }])
        let sent = try h.sentSignatures()
        #expect(try ThinkingFixtures.bodyText(h.client.requests[1]).contains("TELL me about Seattle"),
                "precondition: request two is the hook's output")
        #expect(try !ThinkingFixtures.bodyText(h.client.requests[2]).contains("TELL me"),
                "precondition: request three is not")
        #expect(sent[1].isEmpty, "request two itself carries no block (work's note on #384)")
        #expect(sent[2].isEmpty, "request three restores the prefix request two's reply was bound to (plan note 2)")
        #expect(sent == [[], [], [], ["sig-3"]])
        ThinkingFixtures.expectFrontDroppedWindows(sent, produced: Self.produced)
    }

    @Test("event: a BeforeModel hook that returns JSON without anthropicBlocks means no replay that turn")
    func beforeModelDropsBlocks() async throws {
        let strip = #"sed -E -e 's/,"anthropicBlocks":"([^"\\]|\\.)*"//g' -e 's/"anthropicBlocks":"([^"\\]|\\.)*",//g'"#
        let h = try await run("beforemodel-strip", hooks: ["BeforeModel": { _ in strip }])
        #expect(try h.sentSignatures() == [[], [], [], []])
    }

    @Test("the next turn starts again from its own replies")
    func nextTurnStartsFresh() async throws {
        let h = try await run("nextturn",
                              script: ThinkingFixtures.fourRounds() + [ThinkingFixtures.reply(5, toolCall: true),
                                                                       ThinkingFixtures.reply(6, toolCall: false)],
                              inputs: ["Tell me about Seattle", "And Portland?"])
        let sent = try h.sentSignatures()
        #expect(Array(sent.suffix(2)) == [[], ["sig-5"]], "turn two sends none of turn one's blocks")
    }
```

Add `ThinkingHarness.Edit` to `ThinkingTestSupport.swift`. It lets a `roundStart` closure, built before the harness exists, edit that harness's history:

```swift
extension ThinkingHarness {
    /// A late-bound handle on a harness's history, for `roundStart` closures (a UI edit mid-turn).
    final class Edit: @unchecked Sendable {
        private var app: AppState?
        private var id: UUID?
        func bind(_ h: ThinkingHarness) { app = h.app; id = h.id }
        func replaceText(of index: Int, with text: String) async {
            await MainActor.run {
                guard let app, let id, var history = app.conversations.first(where: { $0.id == id })?.history,
                      history.indices.contains(index) else { return }
                history[index].parts = [Part(text: text)]
                app.updateHistory(for: id, history: history)
            }
        }
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh AppendOnlyRequestTests`. Expected: `baselineReplay` fails, because the engine still hands every stored block to the client, `sig-0` included. Every event case fails too.

- [ ] **Step 3: Implement.** Add the helper beside `requestContents`:

```swift
    /// AppState's history length for the conversation: the floor a prefix edit raises to (#314).
    private func stateHistoryCount(_ conversationId: UUID) async -> Int {
        let localState = state
        return await MainActor.run { localState?.conversations.first(where: { $0.id == conversationId })?.history.count ?? 0 }
    }
```

At `:1956-1958`:

```swift
        var turnRequest = TurnRequest(context: turnContext, stateHistory: stateHistory, initialHistory: history)
        // #314 Phase 1: no reply before this turn's entry sends its blocks again, and round one
        // sends none at all, since the PreCompress hook's list can shift an older reply past any
        // index (Review Focus 5).
        var thinkingReplay = ThinkingReplay(floor: stateHistory.count)

        var request = GeminiRequest(contents: ThinkingReplay.withoutBlocks(await requestContents(history, from: .initial, &turnRequest, conversationId: conversationId)), systemInstruction: currentSystemPrompt, tools: [Tool(functionDeclarations: toolsList)])
```

After the drain block at `:2035-2038`, before `fireBeforeModel`:

```swift
                request.contents = thinkingReplay.applyingFloor(request.contents)
```

Replace `:2046-2049`:

```swift
                var activeRequest = request
                var requestRewritten = false
                if case .proceed(let modifiedData) = beforeModelDecision, let data = modifiedData {
                    activeRequest = Self.applyHookRewrite(data, to: request)
                    requestRewritten = HookRewrite.changes(request, activeRequest)
                }
                // #314 decision 2: a BeforeModel rewrite, or anything that changed what this turn's
                // last request sent (a UI edit, the PreCompress list giving way to AppState's, a
                // rewrite the hook stopped making), edits the prefix every block so far was bound
                // to. None of them go out again: not in this request, which is the hook's output,
                // and not later.
                if requestRewritten || !thinkingReplay.continues(activeRequest.contents) {
                    thinkingReplay.raiseFloor(to: await stateHistoryCount(conversationId))
                    activeRequest.contents = ThinkingReplay.withoutBlocks(activeRequest.contents)
                }
                thinkingReplay.recordSent(activeRequest.contents)
```

After the history refresh at `:2135-2137`:

```swift
                // #314 decision 2: replay stops through the round whose reply a hook rewrote.
                if replyRewritten { thinkingReplay.raiseFloor(to: history.count) }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 14 passed (Task 7's three, plus these eleven). Quote the count. Then run `TurnContextEngineTests`, `CachePolicyTests` and `StreamingEngineTests`. Quote the counts.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, and restore.
  - `ThinkingReplay(floor: 0)`: `baselineReplay` fails (`sig-0` is sent).
  - Drop `requestRewritten ||`: `beforeModelRewriteOnce` fails at request two.
  - Strip the blocks from `request` instead of `activeRequest`, so they leave only the next request: `beforeModelRewriteOnce`'s `sent[1].isEmpty` fails.
  - Drop the `continues` clause: `uiEditOfTheEntry`, `uiEditWithoutContext`, `preCompressModified` and `beforeModelRewriteOnce` (`sent[2]`) fail.
  - Delete the AfterModel raise: `afterModelRewrite` fails, because request three sends `sig-1`.
  - Drop the round-one `withoutBlocks`: `preCompressPrependSendsNoOldBlocks` fails.

- [ ] **Step 6: Commit.** `feat(engine): replay this turn's thinking after its latest prefix edit (#314)`.

### Task 12: The binding field, and the `drop_block` retry

**Files:**
- Modify: `Sources/iris/Models.swift`:
  - `PrefixMismatchBehavior` (new);
  - `GeminiRequest`: `prefixMismatchBehavior` and `forceBindingBeta`, neither encoded;
  - `GeminiResponse`: `anthropicBindingFallback`, not encoded.
- Modify: `Sources/iris/LLMStream.swift`: `LLMStreamEvent.prefixMismatchFallback`, the assembler and `events(from:)`
- Modify: `Sources/iris/LLMError.swift:29-48` (`APIError.prefixMismatchDiagnosis`)
- Modify: `Sources/iris/AnthropicClient.swift`: the body field and header, `isBindingRejection`, `withDropBlock`, both retry sites (`:288-307`, `:334-342`) and `logBindingFallback`
- Modify: `Sources/iris/iris.swift:2683-2687` (`applyHookRewrite` keeps the two request fields)
- Test: `Tests/irisTests/AnthropicBindingRetryTests.swift` (new)

**Interfaces:**
- Produces:
  - `enum PrefixMismatchBehavior: String, Codable, Sendable { case dropBlock = "drop_block" }`.
  - `GeminiRequest.prefixMismatchBehavior: PrefixMismatchBehavior?` and `GeminiRequest.forceBindingBeta: Bool`.
  - `GeminiResponse.anthropicBindingFallback: Bool`.
  - `LLMStreamEvent.prefixMismatchFallback`.
  - `AnthropicClient.isBindingRejection(_:request:) -> Bool` and `AnthropicClient.withDropBlock(_:) -> GeminiRequest`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
@testable import iris

/// #314 decision 6: header always, field unset, and on the binding 400 one retry with drop_block.
/// Scoped mock sessions only (invariant 7); `work`'s account is unenforced, so this lane is the
/// only place the retry runs before a paid self-test.
@Suite("The drop_block retry (#314)")
struct AnthropicBindingRetryTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func append(_ r: URLRequest) { lock.withLock { requests.append(r) } }
        var all: [URLRequest] { lock.withLock { requests } }
        var bodies: [String] { all.map { String(decoding: $0.bodyData ?? Data(), as: UTF8.self) } }
    }

    static let bindingRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation. Remove the block, or set `thinking.block_binding.prefix_mismatch_behavior` to \"drop_block\"."}}"#
    static let tamperedRejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block."}}"#
    static let success = #"{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":1}}"#
    static let sse = [
        #"event: message_start"#, #"data: {"type":"message_start","message":{"id":"m","input_transformations":[{"type":"thinking_dropped","path":"messages.1.content.0","reason":"prefix_binding_mismatch"}],"usage":{"input_tokens":5,"output_tokens":1}}}"#, "",
        #"event: content_block_start"#, #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, "",
        #"event: content_block_delta"#, #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#, "",
        #"event: content_block_stop"#, #"data: {"type":"content_block_stop","index":0}"#, "",
        #"event: message_delta"#, #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#, "",
        #"event: message_stop"#, #"data: {"type":"message_stop"}"#, "", ""].joined(separator: "\n")

    private static func session(rejections: [String], stream: Bool, recorder: Recorder) -> (URLSession, () -> Void) {
        MockURLProtocol.scopedSession { request in
            recorder.append(request)
            let n = recorder.all.count
            if n <= rejections.count {
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields:
                            ["anthropic-thinking-prefix-mismatch": "pattern=first_message_rewritten"])!, Data(rejections[n - 1].utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data((stream ? sse : success).utf8))
        }
    }

    private static func request(_ behaviour: PrefixMismatchBehavior? = nil, force: Bool = false) -> GeminiRequest {
        var r = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        r.prefixMismatchBehavior = behaviour
        r.forceBindingBeta = force
        return r
    }
    private static let direct = AnthropicTransport.direct(apiKey: "k", baseURL: "")
    private static let vertex = AnthropicTransport.vertex(project: "iris-test-project", location: "global", accessToken: "t")

    private func built(_ r: GeminiRequest, _ model: String, _ t: AnthropicTransport) throws -> (body: String, beta: String?) {
        let u = try AnthropicClient.makeURLRequest(request: r, model: model, transport: t, stream: true)
        return (String(decoding: u.httpBody ?? Data(), as: UTF8.self), u.value(forHTTPHeaderField: "anthropic-beta"))
    }

    @Test("the field never travels without its header, for any model, route or setting")
    func fieldNeverWithoutHeader() throws {
        for model in ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5", "claude-sonnet-5", "claude-made-up-9"] {
            for t in [Self.direct, Self.vertex] {
                for (b, f) in [(nil, false), (PrefixMismatchBehavior.dropBlock, false), (.dropBlock, true)] {
                    let (body, beta) = try built(Self.request(b, force: f), model, t)
                    if body.contains("block_binding") { #expect(beta == AnthropicCapabilities.bindingBeta, "\(model) \(t)") }
                }
            }
        }
    }

    @Test("the field is the adaptive thinking object the docs give")
    func fieldShape() throws {
        let u = try AnthropicClient.makeURLRequest(request: Self.request(.dropBlock), model: "claude-opus-5-5",
                                                   transport: Self.direct, stream: true)
        let body = try #require(try JSONSerialization.jsonObject(with: u.httpBody ?? Data()) as? [String: Any])
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect((thinking["block_binding"] as? [String: Any])?["prefix_mismatch_behavior"] as? String == "drop_block")
    }

    @Test("a persisted drop_block goes only where the beta is taken (Review Focus 4)")
    func persistedFieldOnlyWhereTheBetaIsTaken() throws {
        #expect(try built(Self.request(.dropBlock), "claude-opus-5-5", Self.direct).body.contains("block_binding"))
        #expect(try built(Self.request(.dropBlock), "claude-opus-5-5", Self.vertex).body.contains("block_binding"))
        for (model, t) in [("claude-sonnet-5", Self.direct), ("claude-haiku-4-5-20251001", Self.direct),
                           ("claude-sonnet-5-5", Self.vertex), ("claude-made-up-9", Self.direct)] {
            let (body, beta) = try built(Self.request(.dropBlock), model, t)
            #expect(!body.contains("block_binding") && !body.contains("\"thinking\""), "\(model)")
            #expect(beta == nil, "\(model)")
        }
    }

    @Test("non-streaming: the binding 400 is retried once with drop_block and the header, and the response says so")
    func generateRetriesOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection], stream: false, recorder: rec)
        defer { remove() }
        let response = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5",
                                                                 transport: Self.direct, session: session)
        #expect(response.anthropicBindingFallback)
        #expect(rec.all.count == 2)
        #expect(!rec.bodies[0].contains("block_binding"))
        #expect(rec.all[0].value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
        #expect(rec.bodies[1].contains(#""prefix_mismatch_behavior":"drop_block""#))
        #expect(rec.all[1].value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
    }

    @Test("streaming: the same retry, before any event, with the fallback event first")
    func streamRetriesOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection], stream: true, recorder: rec)
        defer { remove() }
        var events: [LLMStreamEvent] = []
        for try await e in AnthropicClient.streamContent(request: Self.request(), model: "claude-opus-5-5", session: session,
                                                         transport: { Self.direct }) { events.append(e) }
        #expect(events.first == .prefixMismatchFallback)
        #expect(events.contains(.textDelta("ok")))
        #expect(rec.all.count == 2)
        #expect(rec.bodies[1].contains("drop_block"))
    }

    @Test("an unknown id that answers the binding 400 gets the header and the field on the retry")
    func unknownIdRetryAddsHeader() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection], stream: false, recorder: rec)
        defer { remove() }
        _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-made-up-9",
                                                      transport: Self.direct, session: session)
        #expect(rec.all[0].value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(rec.all[1].value(forHTTPHeaderField: "anthropic-beta") == AnthropicCapabilities.bindingBeta)
        #expect(rec.bodies[1].contains("drop_block"))
    }

    @Test("a second binding 400 is thrown, not retried again")
    func retriesOnlyOnce() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.bindingRejection, Self.bindingRejection], stream: false, recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) {
            _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5",
                                                          transport: Self.direct, session: session)
        }
        #expect(rec.all.count == 2)
    }

    @Test("a tampered signature (no 'bound to a different conversation') is not retried")
    func tamperedNotRetried() async throws {
        let rec = Recorder()
        let (session, remove) = Self.session(rejections: [Self.tamperedRejection], stream: false, recorder: rec)
        defer { remove() }
        await #expect(throws: APIError.self) {
            _ = try await AnthropicClient.generateContent(request: Self.request(), model: "claude-opus-5-5",
                                                          transport: Self.direct, session: session)
        }
        #expect(rec.all.count == 1)
    }

    @Test("the diagnosis header rides the APIError")
    func diagnosisOnTheError() {
        let e = APIError.http(provider: "Anthropic", statusCode: 400, body: Data(Self.bindingRejection.utf8),
                              headers: ["anthropic-thinking-prefix-mismatch": "pattern=x"])
        #expect(e.prefixMismatchDiagnosis == "pattern=x")
    }

    @Test("a BeforeModel rewrite keeps the conversation's binding setting")
    func hookRewriteKeepsBinding() throws {
        let original = Self.request(.dropBlock)
        let rewritten = IrisEngine.applyHookRewrite(try JSONEncoder().encode(original), to: original)
        #expect(rewritten.prefixMismatchBehavior == .dropBlock)
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh AnthropicBindingRetryTests`. Expected: the build fails with "cannot find type 'PrefixMismatchBehavior' in scope".

- [ ] **Step 3: Implement.** In `Models.swift`:

```swift
/// #314 decision 6: `thinking.block_binding.prefix_mismatch_behavior`. Iris only ever sends
/// `drop_block`, and only after a binding 400; `"error"` belongs to the probe's CI runs (plan note 9).
enum PrefixMismatchBehavior: String, Codable, Sendable { case dropBlock = "drop_block" }
```

In `GeminiRequest`, beside `cacheHints`:

```swift
    /// #314 decision 6: the conversation's binding choice. Sent only with its header, and only to
    /// a model and route the table says take the beta (plan note 3). Never encoded.
    var prefixMismatchBehavior: PrefixMismatchBehavior? = nil
    /// #314 decision 4: set only on the client's own retry after a binding 400, which proves the
    /// model checks, so the header and field go out whatever the table says. Never encoded.
    var forceBindingBeta: Bool = false
```

In `GeminiResponse`: `var anthropicBindingFallback: Bool = false`, with a comment: "#314: this reply came from the drop_block retry; the engine persists the choice. Never encoded."

In `LLMStreamEvent`:

```swift
    /// #314: the client retried with drop_block after a binding 400. Not a token.
    case prefixMismatchFallback
```

Assembler: add `private(set) var bindingFallback = false`, `case .prefixMismatchFallback: bindingFallback = true`, and in `response()` `response.anthropicBindingFallback = bindingFallback`. In `events(from:)`, put `if response.anthropicBindingFallback { out.append(.prefixMismatchFallback) }` first.

In `APIError`, add `var prefixMismatchDiagnosis: String? = nil` after `retryAfter`, and in `http(...)` pass `prefixMismatchDiagnosis: InputTransformation.diagnosis(in: headers)`.

In `makeURLRequest`, before `if stream { body["stream"] = true }`:

```swift
        // #314 decisions 4 and 6: the binding field travels only with its header (alone it is a
        // 400, "Extra inputs are not permitted"), and only to a model and route the table says
        // take the beta, unless this is the retry after a binding 400, which proved the model checks.
        let takesBeta = AnthropicCapabilities.takesBindingBeta(model: model, transport: transport)
        let binding = (takesBeta || request.forceBindingBeta) ? request.prefixMismatchBehavior : nil
        if let binding {
            body["thinking"] = ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": binding.rawValue]]
        }
```

Change the PR 1 header condition to `if takesBeta || binding != nil`.

Add beside `isTTLRejection`:

```swift
    /// #314 decision 6: the 400 an enforced account returns for a replayed block whose prefix
    /// changed (MM:1624; the probe confirmed the text). A tampered signature has the same leading
    /// clause without this sentence and is not retried. Never twice: the retry is forced.
    static func isBindingRejection(_ error: Error, request: GeminiRequest) -> Bool {
        guard !request.forceBindingBeta, let error = error as? APIError, error.statusCode == 400 else { return false }
        return (error.message + " " + (error.detail ?? "")).contains("bound to a different conversation")
    }

    static func withDropBlock(_ request: GeminiRequest) -> GeminiRequest {
        var copy = request
        copy.prefixMismatchBehavior = .dropBlock
        copy.forceBindingBeta = true
        return copy
    }

    private static func logBindingFallback(_ error: Error) {
        let diagnosis = (error as? APIError)?.prefixMismatchDiagnosis.map { "; \(InputTransformation.diagnosisHeader): \($0)" } ?? ""
        print("Anthropic rejected a replayed thinking block (bound to a different conversation); retrying once with drop_block, which this conversation keeps from now on\(diagnosis)")
    }
```

In `streamContent`, add a third `catch` after the TTL one:

```swift
                    } catch let error where !yielded && isBindingRejection(error, request: request) {
                        logBindingFallback(error)
                        // First, so the assembled reply tells the engine to keep drop_block.
                        continuation.yield(.prefixMismatchFallback)
                        for try await event in attempt(withDropBlock(request)) { continuation.yield(event) }
                    }
```

In `generateContent`, add:

```swift
        } catch let error where isBindingRejection(error, request: request) {
            logBindingFallback(error)
            var response = try await generateOnce(request: withDropBlock(request), model: model, transport: transport, session: session)
            response.anthropicBindingFallback = true
            return response
        }
```

In `IrisEngine.applyHookRewrite`, after `rewritten.cacheHints = request.cacheHints`:

```swift
        rewritten.prefixMismatchBehavior = request.prefixMismatchBehavior
        rewritten.forceBindingBeta = request.forceBindingBeta
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 10 passed. Then run `AnthropicTTLFallbackTests`, `CachePolicyTests` and `AnthropicCapabilitiesTests`. Quote the counts.

- [ ] **Step 5: Mutation checks.**
  - Drop `!request.forceBindingBeta` from `isBindingRejection`: `retriesOnlyOnce` fails with 3 requests.
  - Drop `|| binding != nil` from the header condition: `unknownIdRetryAddsHeader` and `fieldNeverWithoutHeader` fail.
  - Send the persisted field whatever the table says: `persistedFieldOnlyWhereTheBetaIsTaken` fails.

- [ ] **Step 6: Commit.** `feat(anthropic): retry a binding 400 once with drop_block (#314)`.

### Task 13: Persist `drop_block` on the conversation, and send it from then on

**Files:**
- Modify: `Sources/iris/AppState.swift:175-235` (`Conversation`: the field, `CodingKeys` and `decodeIfPresent`), plus `recordPrefixMismatchFallback(_:)` beside `markConversationTouchedByUnattendedInput` (`:1961`)
- Modify: `Sources/iris/ConversationStore.swift`:
  - `:535-540`: register `v18_prefix_mismatch_behavior` after `v17_job_run_delegated_reads`;
  - `:750-775`: UPDATE and INSERT;
  - `:950`: the read;
  - `:1013-1016`: the decode.
- Modify: `Sources/iris/iris.swift`: after `request.cacheHints` (`:1963-1968`), and after the reply is stored (`:2135-2137`)
- Test: `Tests/irisTests/PrefixMismatchPersistenceTests.swift` (new)

**Interfaces:**
- Consumes: `PrefixMismatchBehavior` and `GeminiResponse.anthropicBindingFallback` (Task 12), and `thinkingReplay` (Task 11).
- Produces: `Conversation.prefixMismatchBehavior: PrefixMismatchBehavior?` and `AppState.recordPrefixMismatchFallback(_ conversationId: UUID)`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
import Foundation
import GRDB
@testable import iris

@MainActor
@Suite("drop_block persists per conversation (#314)", .timeLimit(.minutes(1)))
struct PrefixMismatchPersistenceTests {
    @Test("a conversation JSON written before #314 decodes, unset")
    func oldConversationDecodes() throws {
        let c = try JSONDecoder().decode(Conversation.self, from: Data(#"{"title":"t"}"#.utf8))
        #expect(c.prefixMismatchBehavior == nil)
    }

    @Test("v18 adds the column and keeps a v17 conversation, unset")
    func v18KeepsRows() throws {
        let root = try ThinkingFixtures.tempDirectory("v18")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("conversations.sqlite")
        let id = UUID()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try ConversationStore.migrator.migrate(queue, upTo: "v17_job_run_delegated_reads")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage)
                    VALUES (?, 1, 'old', datetime('now'), datetime('now'), '{}')
                    """, arguments: [id.uuidString])
            }
            try queue.close()
        }
        let store = try ConversationStore.onDisk(at: url)
        let loaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(loaded.prefixMismatchBehavior == nil)
    }

    @Test("the setting survives a reload through INSERT and through UPDATE")
    func survivesReload() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let inserted = app.createNewConversation(title: "insert")
        app.recordPrefixMismatchFallback(inserted)
        let updated = app.createNewConversation(title: "update")
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == updated }?.prefixMismatchBehavior == nil)
        app.recordPrefixMismatchFallback(updated)
        app.flushSave()
        let all = try store.loadAll().conversations
        #expect(all.first { $0.id == inserted }?.prefixMismatchBehavior == .dropBlock)
        #expect(all.first { $0.id == updated }?.prefixMismatchBehavior == .dropBlock)
    }

    @Test("a value this build does not know reads as unset, and the conversation is kept")
    func unknownValueReadsUnset() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        app.conversations.removeAll()
        let id = app.createNewConversation(title: "garbled")
        app.flushSave()
        try store.rawWrite("UPDATE conversations SET prefixMismatchBehavior = 'later_value' WHERE id = ?", arguments: [id.uuidString])
        let loaded = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(loaded.prefixMismatchBehavior == nil)
    }

    @Test("a fallback reply persists drop_block, every later request carries it, and its earlier blocks stay out")
    func fallbackPersistsAndIsSent() async throws {
        let dir = try ThinkingFixtures.tempDirectory("fallback")
        defer { try? FileManager.default.removeItem(at: dir) }
        var script = ThinkingFixtures.fourRounds()
        script[2].anthropicBindingFallback = true
        let store = try ConversationStore.inMemory()
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir), store: store)
        await h.run()
        try #require(h.client.requests.count == 4)
        #expect(h.client.requests.map(\.prefixMismatchBehavior) == [nil, nil, nil, .dropBlock])
        #expect(try h.sentSignatures()[3] == ["sig-3"], "the retry dropped sig-1 and sig-2; they stay out (plan note 6)")
        #expect(try ThinkingFixtures.bodyText(h.client.requests[3]).contains("drop_block"))
        h.app.flushSave()

        let app2 = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let client2 = RecordingClient([ThinkingFixtures.reply(5, toolCall: false)])
        let engine2 = IrisEngine(state: app2, tier: .medium, principal: .main, client: client2, retryDelays: [],
                                 streamResponses: false, factStore: try FactStoreManager(inMemory: true),
                                 protectionEnabled: false, sessionPeerCount: 0, hooks: try ThinkingFixtures.hooks(in: dir))
        await engine2.processInput("again", source: "UI", conversationId: h.id)
        #expect(client2.requests.first?.prefixMismatchBehavior == .dropBlock, "after a restart, the first request sends it")
    }

    @Test("the persisted value follows the model: nothing reaches a model that cannot take it (Review Focus 4)")
    func persistedValueFollowsTheModel() async throws {
        let dir = try ThinkingFixtures.tempDirectory("follows")
        defer { try? FileManager.default.removeItem(at: dir) }
        var script = [ThinkingFixtures.reply(1, toolCall: true), ThinkingFixtures.reply(2, toolCall: false)]
        script[0].anthropicBindingFallback = true
        let h = try ThinkingHarness.make(script, hooks: try ThinkingFixtures.hooks(in: dir))
        await h.run()
        let last = try #require(h.client.requests.last)
        #expect(last.prefixMismatchBehavior == .dropBlock)
        for model in ["claude-haiku-4-5-20251001", "claude-sonnet-5"] {
            let u = try ThinkingFixtures.urlRequest(last, model: model)
            #expect(!String(decoding: u.httpBody ?? Data(), as: UTF8.self).contains("block_binding"), Comment(rawValue: model))
            #expect(u.value(forHTTPHeaderField: "anthropic-beta") == nil, Comment(rawValue: model))
        }
        #expect(!String(decoding: try LLMClient.encodeGeminiBody(last), as: UTF8.self).contains("drop_block"))
    }
}
```

- [ ] **Step 2: Run them and watch them fail.** Run `timeout 300 scripts/test-filter.sh PrefixMismatchPersistenceTests`. Expected: the build fails with "value of type 'Conversation' has no member 'prefixMismatchBehavior'".

- [ ] **Step 3: Implement.** In `Conversation`, after `hasUnattendedInput`:

```swift
    /// #314 decision 6: `drop_block` once a binding 400 forced the retry, so every later request
    /// sends it, across restarts (CAUSES:93). Never cleared. Nil is unset: nothing is sent.
    var prefixMismatchBehavior: PrefixMismatchBehavior? = nil
```

Add `prefixMismatchBehavior` to `CodingKeys`, and in `init(from:)`:

```swift
        // Invariant 1: absent on every conversation persisted before #314, and absent is unset.
        prefixMismatchBehavior = try container.decodeIfPresent(PrefixMismatchBehavior.self, forKey: .prefixMismatchBehavior)
```

In `AppState`:

```swift
    /// #314 decision 6: the conversation sends `drop_block` from now on. A no-op once set.
    func recordPrefixMismatchFallback(_ conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].prefixMismatchBehavior != .dropBlock else { return }
        conversations[idx].prefixMismatchBehavior = .dropBlock
        markChanged(conversationId, .metadata)
    }
```

Migration, after `v17_job_run_delegated_reads`:

```swift
        // #314 decision 6: `drop_block` once a binding 400 forced it. NULL (every earlier row) is
        // unset, which sends nothing, exactly as before.
        m.registerMigration("v18_prefix_mismatch_behavior") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "prefixMismatchBehavior", .text)
            }
        }
```

In `upsertMetadata`:
- UPDATE: add `, prefixMismatchBehavior = ?` after `hasUnattendedInput = ?`, and `c.prefixMismatchBehavior?.rawValue` before `c.id.uuidString`.
- INSERT: add the column after `hasUnattendedInput` and a 24th `?`, with `c.prefixMismatchBehavior?.rawValue` as the last argument.

In `loadAll`, beside `let sandboxGrant = supplementary("sandboxGrant")`:

```swift
                let prefixMismatch = supplementary("prefixMismatchBehavior")
```

After the `sandboxGrant` decode:

```swift
                // #314: a value this build does not know reads as unset. The next binding 400
                // retries and writes it again, so nothing is lost but one retry.
                if let s = prefixMismatch {
                    c.prefixMismatchBehavior = PrefixMismatchBehavior(rawValue: s)
                    if c.prefixMismatchBehavior == nil {
                        print("WARNING: unrecognised prefixMismatchBehavior \"\(s)\" for conversation \(id); reading as unset")
                    }
                }
```

In `iris.swift`, after the `request.cacheHints = …` statement:

```swift
        // #314 decision 6: a conversation that once needed drop_block sends it from then on.
        request.prefixMismatchBehavior = await MainActor.run {
            localState?.conversations.first(where: { $0.id == conversationId })?.prefixMismatchBehavior
        }
```

After Task 11's AfterModel raise:

```swift
                if response.anthropicBindingFallback {
                    // The retry's drop is a strip the API recorded: keep it (decision 2), past
                    // everything the failed request carried; the retry's own reply keeps its blocks.
                    // And keep sending drop_block (decision 6), from this round and across restarts.
                    thinkingReplay.raiseFloor(to: history.count - 1)
                    request.prefixMismatchBehavior = .dropBlock
                    await MainActor.run { localState?.recordPrefixMismatchFallback(conversationId) }
                }
```

- [ ] **Step 4: Run them and watch them pass.** Run the same filter. Expected: 6 passed. Then run `ConversationSearchTests`, `JobToolsTests` (the conversation upsert paths) and `AppendOnlyRequestTests`. Quote the counts.

- [ ] **Step 5: Mutation checks.** Make each change, run the filter, see the named test fail, and restore.
  - Drop the UPDATE column: `survivesReload` fails for `updated`.
  - Drop the `loadAll` read: `survivesReload` and the restart half of `fallbackPersistsAndIsSent` fail.
  - Delete the floor raise: `fallbackPersistsAndIsSent` fails, because request four sends `sig-1` and `sig-2`.
  - Change `decodeIfPresent` to `decode`: `oldConversationDecodes` fails.

- [ ] **Step 6: Commit.** `feat: persist drop_block per conversation after a binding 400 (#314)`.

### Task 14: Invariant 9 sweep, and open PR 2

- [ ] **Step 1: Run the greps and read every hit.**
  - `grep -n "turn k-1\|nothing from turn k-1\|read point\|byte-identical to pre" Sources/iris/AnthropicClient.swift`. The cache-marker comment (`:125-146`) says turn k-1's entry carried a context block that is gone. That is still true, and replay adds no new reason for it. Make sure nothing there says assistant messages are always rebuilt from parts.
  - `grep -rn "parts\b.*rebuil\|built from parts\|from \`parts\`" Sources/iris/*.swift`. Any comment saying the Anthropic body is rebuilt from `parts` is now half-true.
  - `grep -rn "BeforeModel\|AfterModel\|PreCompress" README.md docs/*.md Sources/iris/assets/SYSTEM.md`. A hook author should learn that a rewriting hook turns replay off for the rest of that turn.
  - `grep -n "thinking" README.md Sources/iris/assets/SYSTEM.md AGENTS.md`.
  - No tool `description` or `oracleText` mentions thinking or replay. Confirm with `grep -rn "thinking\|replay" Sources/iris/ToolExecutor.swift Sources/iris/GoalContract*.swift`.
- [ ] **Step 2: Fix what you found.**
  - Append this to README's "LLM Engine" bullet: "On Claude models, Iris keeps each reply's content blocks as they arrived and sends the turn's own thinking blocks back while the turn runs, so the model keeps its reasoning across tool calls. Anything that edits what was already sent stops that for the rest of the turn: a `BeforeModel` or `AfterModel` hook that rewrites, a `PreCompress` hook that changes history, or a history edit mid-turn. Older turns go out without thinking. If Anthropic still rejects a replayed block, Iris retries once with `drop_block` and keeps that setting for the conversation."
  - Add the hook sentence to the hooks documentation, wherever the BeforeModel grep found it.
  - Run the full suite (`timeout 900 swift test`). Green means all three signals.
  - Commit with `docs: thinking replay, swept (#314)`.
- [ ] **Step 3: Open PR 2.** Title: `feat: Phase 1 thinking replay, and the drop_block backstop (#314)`. The body lists:
  - that it depends on PR 1 (merged) and the spec, PR #384;
  - the Review Focus items it owns (3, 4, 5, and 2 for BeforeModel);
  - plan notes 1, 2, 3, 5, 6, 9 and 12, each flagged for the owner;
  - that the paid self-test (spec §2.3) and the arm measurement (§2.4) are not run here and need the owner's approval.

---

## Self-review against the spec

- **Decision 1:**
  - Assembly per block index, verbatim `partial_json`, `redacted_thinking.data`: Task 2.
  - The new event and `StreamAssembler`, including the non-stream path: Task 3.
  - Storage at `iris.swift:2131`: Task 4.
  - The echo: Task 9.
  - No incomplete block: Task 2.
  - `decodeIfPresent` and `CodingKeys`, with no column: Task 1.
  - The Gemini strip: Task 1.
  - Search ignores signatures: Task 1. `read_conversation` reads `messages`, not history, which Task 1 Step 6's grep confirms.
- **Decision 2, Phase 1:**
  - The floor and older turns: Tasks 10 and 11.
  - The events: AfterModel, `firstDrop`, PreCompress at round two, BeforeModel, and BeforeModel without blocks: Task 11, one test each. Two more cases come from plan notes 1 and 2.
  - "Never edit, reorder or thin the middle": the front-drop guard in Task 9, and `expectFrontDroppedWindows` in Task 11.
  - "Send blocks on a model switch": the client never strips by model (Global Constraints).
  - "Once a strip is recorded, keep it stripped": the monotone floor (Task 10) and plan note 6 (Task 13).
- **Decision 3:** `AnthropicCapabilities` with `runsPrefixCheck` only, plus the route fact from plan note 4: Task 5.
- **Decision 4:** the header only to known models, the unknown-id retry, and adaptive only: Tasks 5 and 12.
- **Decision 5:** Vertex and direct send the same header: Task 5. The probe narrowed which models get it on Vertex.
- **Decision 6:** header always, field unset, retry once before any event, persist, never lift the exemption: Tasks 12 and 13. `"error"` is never sent: plan note 9.
- **Decision 7:**
  - Parsed from `message_start`, the final `message_delta` and the non-stream top level: Task 6.
  - Unknown entries ignored, raw entries on `ModelCallRecord`, the console line and the diagnosis header: Task 6.
  - Phase 2 counting is out of scope.
- **§2.1, PRs 1-2:** the prefix chain, byte-for-byte block order, no middle gap, older turns without thinking, one case per event, and no beta header to an unknown id: Tasks 7 and 11.
- **§3:** PR 1 and PR 2 contents match. PR 2 is cut from `main` after PR 1 merges.
- **Placeholders.** None. Three code blocks say "(unchanged)" for existing code they keep in place: the tool_result branch in Task 9, the 5a F8 comment and the other `ModelCallRecord` arguments in Task 6. Each names the lines it keeps.
- **Type consistency.** The names are used the same way in every task:
  - `anthropicBlocks`, `AnthropicBlocks.Streamed`, `render` and `storable`;
  - `echoable` and `withCacheControl`;
  - `RawJSON.topLevelValue`;
  - `InputTransformation.list` and `.diagnosis` and `.logLine`;
  - `AnthropicCapabilities.takesBindingBeta` and `.bindingBeta`;
  - `PrefixMismatchBehavior.dropBlock`, `prefixMismatchBehavior` and `forceBindingBeta`;
  - `anthropicBindingFallback`, `.prefixMismatchFallback` and `recordPrefixMismatchFallback`;
  - `ThinkingReplay` with `applyingFloor`, `withoutBlocks`, `continues`, `recordSent` and `raiseFloor`;
  - `HookRewrite.changes`;
  - `ThinkingHarness` and `ThinkingFixtures`.
- **Review Focus.** Each item has its test in the owning task: 1 in Task 2, 2 in Tasks 4 and 11, 3 in Task 9, 4 in Tasks 12 and 13, 5 in Task 11.
