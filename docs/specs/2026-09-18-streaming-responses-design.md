# Streaming Responses (#131, second half)

* **Status**: design, awaiting review
* **Issue**: #131 ("Iris feels slow": the timeout/retry half landed in PR #140; this is the streaming half)
* **Measured motivation**: `docs/reviews/2026-09-18-perf-rebaseline.md`. After #130–#136 the deterministic harness cost of a model-only turn is single-digit milliseconds. What is left of "slow" is the provider: 1.9–5.7 s medians, 5–8 s p90s, one bare call generating for 14 s. Today the user sees nothing for that whole span and then a finished paragraph. Streaming does not change total latency; it changes when the first word appears, which is what the user perceives.
* **Decision already taken**: Approach A, a streaming client protocol returning an event stream; the engine assembles; the UI updates one message in place. (Alternatives considered and rejected in conversation: B, streaming only inside the client with a progress callback, which leaves the engine unable to attribute time-to-first-token; C, a separate streaming engine path, which duplicates the tool loop.)

## Goals

1. Text the model produces appears in the chat as it is produced, for all three providers (Gemini, Anthropic, OpenAI) and for the Vertex path of Gemini.
2. Everything downstream of the model call behaves exactly as today: hooks, history, token accounting, guards, tool calls, retries on transport errors, the error pill (#124), the empty-content pill (#136).
3. Time-to-first-token is measured at the engine seam and recorded in the perf record, so the perf suite can report it per rung.
4. Streaming can be switched off (settings, and always in the fake lane) and the non-streaming path stays the reference behaviour.

## Non-goals

- Streaming tool-call arguments into the UI before the call is complete. Tool calls are buffered until the stream ends and dispatched exactly as today.
- Rendering thinking/reasoning blocks. Anthropic `thinking` deltas and Gemini `thought` parts are dropped, as the non-streaming path drops them today.
- Streaming for subagents' internal calls, the summariser, Vibecop, or the title/rename calls. Only the primary conversation turn streams. (The protocol permits it later; nothing here depends on it.)
- Changing MarkdownUI or the message row layout.

## 1. Event model

One provider-neutral event enum, in a new file `Sources/iris/LLMStream.swift`:

```swift
enum LLMStreamEvent: Sendable, Equatable {
    /// A fragment of visible assistant text. Fragments concatenate in order.
    case textDelta(String)
    /// A provider thought signature that belongs to the text part (Gemini requires it echoed back).
    case thoughtSignature(String)
    /// A complete function call. Providers that stream arguments (Anthropic, OpenAI)
    /// accumulate inside the client and emit one event per call once its JSON is whole.
    case functionCall(FunctionCall)
    /// Token counts, possibly emitted more than once; the last one wins.
    case usage(UsageMetadata)
    /// The provider ended the turn. `finishReason` is the provider's own string
    /// ("STOP", "end_turn", "tool_calls", "MAX_TOKENS", ...), passed through for the
    /// empty-content pill; `emptyReason` is derived from it by the assembler. `blockReason`
    /// is Gemini's prompt-level block, kept separate so the #136 pill reads exactly as before.
    case done(finishReason: String?, blockReason: String? = nil)
}
```

Design points:

- **`functionCall` is whole, never partial.** The engine's tool loop consumes `FunctionCall` values; streaming partial JSON gains nothing here and would add a tolerant-parser dependency. The client owns argument accumulation (Section 3).
- **`usage` is repeatable.** Gemini sends `usageMetadata` on several chunks with running counts; Anthropic sends `input_tokens` in `message_start` and `output_tokens` in `message_delta`; OpenAI sends one usage chunk at the end. "Last wins, merged field-wise" covers all three: the assembler keeps the max of each count it has seen, because Anthropic's two usage events carry disjoint fields.
- **No `error` case.** Failures are thrown from the stream, so the engine's existing `catch` and `LLMRetry` see the same `Error` values as today.
- **`thoughtSignature` is a separate event, not a field on `textDelta`.** A provider thought signature belongs to the text part (Gemini requires it echoed back on the next turn), but arrives independently of the text fragments themselves, so the assembler attaches whichever one it last saw to the whole text part rather than to any one delta.
- **`blockReason` rides on `done`, not its own case.** It is Gemini's prompt-level block (`promptFeedback.blockReason`), never a provider `finishReason`; keeping it a separate parameter on the terminal event (rather than folding it into `finishReason`) lets the assembler reproduce the #136 empty-content pill's exact wording for both causes.

## 2. Client protocol

`LLMClientProtocol` gains one requirement with a default implementation:

```swift
protocol LLMClientProtocol: Sendable {
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse
    /// Streams the same call. Default: one `generateContent` call replayed as events.
    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// True only when `streamContent` reads the provider's stream natively. Default false.
    var supportsStreaming: Bool { get }
}
```

The default extension calls `generateContent` and emits `textDelta` per text part, `functionCall` per call part, one `usage`, then `done`, and reports `supportsStreaming == false`. This means:

- `CapturingLLMClient`, `FakeLLMClient` (the headless fake lane), the ad-hoc clients in tests, and any future client all work unchanged, and the engine can tell that their events arrived all at once (Section 7 uses this to leave `firstTokenMs` nil).
- The engine has a single code path (Section 4). "Streaming off" is not a second engine path; it is the engine choosing `generateContent` and feeding it through the same assembler (Section 4.3).

Each real client implements `streamContent` natively. `generateContent` stays as it is; it is still the right call for the ladder's rungs 1–3, for the summariser, and for anything that wants one response object.

### 2.1 SSE parser

One shared helper, `SSEParser`, in `LLMStream.swift`:

```swift
struct SSEParser {
    /// Feed one line at a time (without the line terminator); returns an event on the blank
    /// line that ends one, else nil. Ignores comments (`:` prefix) and unknown fields (`id`,
    /// `retry`).
    mutating func feed(_ line: String) -> SSEEvent?
    /// Flushes an event the stream ended without a trailing blank line.
    mutating func finish() -> SSEEvent?
}
```

`SSEParser` is synchronous and holds no I/O of its own; each client's streaming task feeds it one line at a time from `URLSession.shared.bytes(for:).lines`, so the multi-line-`data:`-joining and comment/field-skipping logic is written and tested once and shared across providers. Cancelling the consuming task cancels the URLSession task; that is the whole cancellation story at the transport layer (Section 6).

HTTP status is checked once, on the `URLResponse` returned by `bytes(for:)`, before any line is read. A non-2xx response is read to completion into `Data` and thrown through the same per-provider error decoder that the non-streaming path uses today, so a 429 during streaming produces the identical `LLMError` (and identical retry-after handling) as a 429 during a plain call.

## 3. Provider wire shapes and assembly

Each client maps its provider's SSE to `LLMStreamEvent`. The request bodies are the ones built today plus the provider's streaming switch; nothing about tools, system prompt, caching or auth changes.

### 3.1 Gemini (`LLMClient`)

- **Endpoint**: replace `:generateContent` with `:streamGenerateContent?alt=sse` in `resolveGeminiRequestURL` (a `streaming: Bool` parameter; both the Generative Language and the Vertex `aiplatform` URL forms take the same suffix and the same query item). The existing `?key=` query item is kept when present.
- **Chunk shape**: every `data:` line is a complete `GeminiResponse` JSON object. Decode each with the existing `GeminiResponse` decoder.
- **Mapping**: for each chunk, for each part of `candidates[0].content.parts`: `text` becomes `textDelta` (Gemini sends text incrementally; a chunk's text is a fragment, not the whole so far); `functionCall` becomes `functionCall` (Gemini sends each call complete in one chunk). `usageMetadata` present becomes `usage`. A chunk whose candidate carries `finishReason` produces `done(finishReason:)` after its parts; if the stream ends without one, the client emits `done(finishReason: nil)`.
- **Empty content**: a chunk with no parts and a `finishReason` (safety, recitation) yields `done` with that reason; a `promptFeedback.blockReason` on the first chunk yields `done(finishReason: "BLOCK_" + reason)` so `emptyReason` (Section 4.2) reports it exactly as #136 does today.

### 3.2 Anthropic (`AnthropicClient`)

- **Request**: `"stream": true` added to the body. Everything else is the current body.
- **Events** (named `event:` lines, JSON `data:`):
  - `message_start`: `message.usage.input_tokens` becomes `usage(promptTokenCount:)`.
  - `content_block_start` with `content_block.type == "text"`: open a text block at `index`.
  - `content_block_start` with `type == "tool_use"`: open a tool block at `index`, remembering `id` and `name`, with an empty JSON buffer.
  - `content_block_delta` with `delta.type == "text_delta"`: emit `textDelta(delta.text)`.
  - `content_block_delta` with `delta.type == "input_json_delta"`: append `delta.partial_json` to that index's buffer. Nothing is emitted.
  - `content_block_delta` with `delta.type == "thinking_delta"` or `signature_delta`: ignored.
  - `content_block_stop`: if the block at `index` is a tool block, parse the buffer (empty buffer means `{}`) into `[String: Any]` and emit `functionCall(FunctionCall(name:, args:))` using the same `id`-to-call mapping the non-streaming decoder uses today, so the follow-up `tool_result` round trip is byte-identical.
  - `message_delta`: `usage.output_tokens` becomes `usage(candidatesTokenCount:)`; `delta.stop_reason` is remembered.
  - `message_stop`: emit `done(finishReason: rememberedStopReason)`.
  - `ping`: ignored.
  - `error`: decode `error.type` and `error.message` and throw the same `LLMError` the non-streaming path builds from an error body. (This is the mid-stream overload case; Section 6 says how the engine treats it.)
- A `stop_reason` of `refusal` or `max_tokens` with no text and no tool blocks reaches the engine as `done` with that reason and produces the empty-content pill.

### 3.3 OpenAI (`OpenAIClient`)

- **Request**: `"stream": true` and `"stream_options": {"include_usage": true}` added; without the latter the stream carries no token counts.
- **Chunks**: unnamed `data:` lines, each a `chat.completion.chunk`; the terminal line is the literal `[DONE]`.
  - `choices[0].delta.content` (string) becomes `textDelta`.
  - `choices[0].delta.tool_calls[]`: each entry carries `index`; the first fragment for an index also carries `id` and `function.name`; every fragment may carry `function.arguments`, a JSON string fragment. Accumulate per `index`.
  - `choices[0].finish_reason` non-null: remember it; when it is `tool_calls` (or the stream ends with buffered calls), parse each accumulated argument string and emit one `functionCall` per index in index order, preserving the `id` the way the non-streaming decoder does for the `tool` role reply.
  - A chunk with empty `choices` and a `usage` object becomes `usage`.
  - `[DONE]` emits `done(finishReason: rememberedFinishReason)`.

### 3.4 Shared invariants

- Clients never emit `functionCall` before the arguments parse. A malformed argument buffer is thrown as a decode error, which is what the non-streaming path does when the whole body fails to decode.
- Clients emit `done` exactly once, always last, unless they throw.
- Clients do not coalesce or buffer text; the UI layer does (Section 5).

## 4. Engine integration

The seam is the block in `IrisEngine` around the `LLMRetry.run { measure(.primaryLLM) { client.generateContent } }` call, currently `Sources/iris/iris.swift` near line 697. It becomes one call to a new engine-local assembler, and everything after it consumes a `GeminiResponse` exactly as before.

### 4.1 `StreamAssembler`

A small value type, also in `LLMStream.swift`, unit-testable without the engine:

```swift
struct StreamAssembler {
    private(set) var text = ""
    private(set) var calls: [FunctionCall] = []
    private(set) var usage: UsageMetadata?
    private(set) var finishReason: String?
    private(set) var firstTokenAt: Double?   // MonotonicClock ms, set on the first textDelta or functionCall

    mutating func apply(_ event: LLMStreamEvent, now: Double)
    /// The response the rest of the turn consumes. Text (if any) is one part, followed by
    /// one part per function call, matching the shape the non-streaming decoders produce.
    func response() -> GeminiResponse
}
```

`response()` builds a `GeminiResponse` with a single candidate whose `content.parts` is `[text part] + call parts`, `finishReason` set, and `usageMetadata` merged field-wise (max of each count seen). If there was no text and no call, `emptyReason` on the built response reports `finishReason`, which keeps the #136 pill working unchanged.

### 4.2 The turn

```
open stream (or default replay)            ← inside LLMRetry.run, inside measure(.primaryLLM)
for await event in stream:
    assembler.apply(event)
    if case .textDelta = event: streamer.append(delta)     ← Section 5
response = assembler.response()
```

Then the existing code, unchanged in order: `recordModelCall` (now with `firstTokenMs`), `fireAfterModel(response:)`, `emptyReason` pill, `appendContentToHistory`, `updateTokenUsage`, the per-part loop that pushes text and fires `fireAfterAgent`, and the tool loop.

One change in the per-part loop: the text part is no longer pushed with `pushToUI` (which appends a new message). Instead the streamer (Section 5) has already been creating and growing the agent message; the loop calls `streamer.finish(finalText:)`, which writes the assembled text as the message's final content. If `fireAfterModel` returned modified data (a hook rewrote the response), the final content is the hook's text, so the hook still has the last word; the user briefly saw the pre-hook text, which is the accepted cost of streaming and is noted in `docs/tool_hooks.md`.

If `fireAfterModel` blocks, or the response is empty, the streamer's message is removed if it never received text, or left as is (with the block pill appended after it) if it did.

### 4.3 Choosing the source

```swift
let streamed = streamingEnabled && client.supportsStreaming
let stream: AsyncThrowingStream<LLMStreamEvent, Error> = streamed
    ? client.streamContent(request: requestToSend, tier: modelTier)
    : LLMStreamEvent.replay { try await self.client.generateContent(request: requestToSend, tier: modelTier) }
```

`streamingEnabled` reads a new settings key (Section 7). The headless fake lane therefore never streams (its client replays); the headless real lane follows the setting like the app does, so the perf suite measures what the user gets. `streamed` is also what decides whether `firstTokenMs` is recorded.

### 4.4 Retries

`LLMRetry.run` wraps the whole consume loop. A failure before the first `textDelta`/`functionCall` (429, 5xx, transport error, timeout) retries exactly as today: nothing has been shown, so a retry is invisible apart from the existing `[retry]` system line. A failure after the first delta is **not retried**: the consume loop catches the error, sees that the assembler's `firstTokenAt` is set, and rethrows it wrapped in a new `StreamInterruptedError(underlying:)` (in `LLMError.swift`). `LLMRetry.run` retries only `APIError` values whose `isRetryable` is true, so the wrapper passes straight through without any change to `LLMRetry`; the engine's existing error handling unwraps it to render the standard error pill, appended after the partial message. Retrying would either duplicate the text or require deleting text the user has already read; neither is acceptable, and partial text plus a clear error is what other clients do.

The 180 s request timeout from #131 applies to the whole stream. A stalled stream (no bytes for the timeout) fails through the same `URLError.timedOut` path.

## 5. UI update path

### 5.1 AppState

One new method, next to `appendMessage`:

```swift
/// Replaces the content of an existing message in place. No title generation, no save;
/// the caller saves once when the message is final.
func updateMessageContent(id: UUID, content: String, in conversationId: UUID)
```

It finds the conversation and message by id and assigns `content`. Because `ChatMessage` is a value in an `@Observable` array, SwiftUI re-renders that row only. `groupedMessages(for:)` in `ChatView` is recomputed on each change; it is O(messages) and already runs on every append, so no new cost class is introduced.

### 5.2 `MessageStreamer`

An actor-free helper owned by the engine turn (a small `final class` confined to the engine actor is fine; it never escapes the turn):

- `append(delta)`: appends to a buffer. On the first delta it calls `pushToUI(role: .agent, text: "", id: messageId)` so the row exists, then schedules a flush.
- Flushes run at most every **50 ms** (a `Task.sleep` gate, not a timer): each flush calls `updateMessageContent` on the main actor with the whole accumulated text. 50 ms is 20 renders per second, well under what MarkdownUI can parse for a few-kilobyte message and above the rate at which any provider produces visually distinct chunks. The constant lives in one place and the plan's test exercises it with an injected clock.
- `finish(finalText)`: cancels any pending flush, writes `finalText` once, and calls `saveConversations()` once. Persistence during the stream is not performed; if the app quits mid-stream the partial message is lost, which matches today's behaviour (nothing was saved until the reply arrived).
- The streamer mints the message id once and passes it to `pushToUI(role:text:conversationId:id:)` on the first delta, then reuses it for every `updateMessageContent` call, so anything keyed on message ids (selection, copy, the command pill timers) sees one stable message.

### 5.3 Visuals

- The row shows the growing text through the normal `Markdown(message.content)` view. No cursor, no typing indicator; the text arriving is the indicator.
- The "Thinking..." subagent status set just before the call is cleared on the first delta rather than after the whole call, so the status line and the text do not contradict each other.
- Auto-scroll: `ChatView` already has an `onChange(of: conv.messages.last?.content)` that scrolls to the bottom anchor, so in-place growth pins the view to the bottom with no new code, at most once per flush. It also means a user who scrolls up during a long answer is pulled back down on the next flush, which is what happens today when a tool result lands. Keeping the pin only when the user is already at the bottom is a separate UX change and is filed as a follow-up, not built here.

## 6. Errors and cancellation

| situation | what happens |
|---|---|
| HTTP error before any event (429, 401, 5xx) | Same `LLMError` as today; `LLMRetry` retries the retryable ones; error pill otherwise. No message row was created. |
| transport error / timeout before first delta | Retried as today (#131 first half). |
| mid-stream `event: error` (Anthropic), malformed chunk, connection drop, timeout | Not retried. Partial message kept as is; error pill appended after it with the provider's message; turn ends. History gets the partial text as the model turn so the next user message has coherent context. |
| provider ends with no text and no call | `done(finishReason:)` only; empty-content pill via `emptyReason`, no agent row. |
| user presses Stop | The turn's `Task` is cancelled; `for await` throws `CancellationError`; URLSession aborts the connection. Partial message kept; no error pill (the existing `URLError.cancelled && Task.isCancelled` check already suppresses it). Partial text is committed to history. |
| hook `fireAfterModel` blocks | Row removed if empty, otherwise kept; block pill appended. |
| hook rewrites the text | Final flush shows the rewritten text. |

Partial text going into history on Stop or mid-stream error is a change from today (where nothing reached history because nothing was received). It is the right behaviour: the user saw it, so the model should know it said it. The plan includes a test for it.

## 7. Settings and perf instrumentation

- **Setting**: `IrisDefaults` key `streamResponses`, `Bool`, default `true`, exposed in Settings as "Stream responses as they are generated". New persisted field, so it is read with a default and never assumed present (AGENTS.md rule on persisted fields).
- **`ModelCallRecord.firstTokenMs: Double?`**: ms from request start to the first `textDelta`/`functionCall`, recorded only when `streamed` was true (Section 4.3); nil for replayed calls, for calls that produced nothing, and for all pre-existing records. Optional and `decodeIfPresent`, so older perf records still load and `PerfCompare` still accepts them.
- **`PerfEnvironment.streaming: Bool?`**: recorded so a report says whether rungs 4–5 streamed. `PerfCompare` does **not** refuse on a mismatch (total latency is comparable either way); it prints the flag in the header.
- **`PerfScenarioSummary.medianFirstTokenMs: Double?`** and a `first token ms` column in the ladder report for rungs where it is non-nil. This is the number the second write-up said was "not measured here".

## 8. Test plan

All Swift Testing, no XCTest, no mutation of `ConfigManager.shared`.

**`SSEReader`**
- Splits `event:`/`data:` pairs, joins multi-line `data:`, skips comments and blank lines, handles a final event without a trailing blank line.
- Propagates cancellation: cancelling the consumer ends the stream.

**Per-provider mappers** (each fed a fixture transcript as bytes, asserted as a `[LLMStreamEvent]`)
- Gemini: text over three chunks, then a function-call chunk, then a usage chunk with `finishReason`; a blocked-prompt first chunk; a parts-less safety stop.
- Anthropic: text block, then a `tool_use` block whose `input_json_delta` arrives in four fragments (including an empty first fragment); two tool blocks interleaved with text; `message_start` + `message_delta` usage merge; `event: error` mid-stream throws the same `LLMError` type as the non-streaming 529 body; `stop_reason: refusal` with no content.
- OpenAI: text deltas; two parallel tool calls whose argument fragments interleave by `index`; usage chunk with empty `choices`; `[DONE]`; `finish_reason: length` with partial text.

**`StreamAssembler`**
- Builds the same `GeminiResponse` (parts, finishReason, usage) as the non-streaming decoder does for an equivalent fixture; `emptyReason` matches for the empty cases; `firstTokenAt` is set on the first text or call and not on usage.

**Default `streamContent`**
- A `FakeLLMClient` returning a two-part response replays as `textDelta`, `functionCall`, `usage`, `done` in that order, and reports `supportsStreaming == false`.

**`MessageStreamer`** (injected clock and a recording `AppState` stand-in through the existing test seams)
- Creates the row on the first delta, flushes at most once per 50 ms window, final flush carries the full text, saves exactly once.

**Engine** (through `ScenarioRunner` with a streaming `CapturingLLMClient` variant that emits a scripted event list)
- A streamed text turn produces one agent message whose content equals the assembled text, history contains one model turn, token usage updated, `firstTokenMs` recorded.
- A streamed tool-call turn dispatches the tool exactly once with the parsed arguments and continues the loop; no partial-argument execution.
- Error after the first delta: partial message kept, error pill after it, `LLMRetry` did not retry (attempt count 1), history has the partial text.
- Error before the first delta: retried per `retryDelays`, no agent row created until success.
- Cancellation mid-stream: partial message kept, no error pill, history has the partial text.
- Streaming off (setting false), and streaming on with a client whose `supportsStreaming` is false: identical final state to native streaming for the same scripted events; `firstTokenMs` nil in both.

**Perf records**
- A record with `firstTokenMs` round-trips; a pre-streaming record without it still decodes; `PerfCompare` does not refuse on a `streaming` mismatch.

**Manual**
- Real Gemini, Anthropic and OpenAI keys: a long answer streams visibly; a tool-using prompt behaves as before; Stop mid-answer leaves the partial text; a deliberately bad key still produces the #124 pill.

## 9. File map

| file | change |
|---|---|
| `Sources/iris/LLMStream.swift` (new) | `LLMStreamEvent`, `SSEReader`, `StreamAssembler`, `LLMStreamEvent.replay`, default `streamContent` / `supportsStreaming` extension |
| `Sources/iris/LLMClient.swift` | `streamGenerateContent?alt=sse` URL form; native `streamContent`; `LLMClientProtocol` requirement |
| `Sources/iris/AnthropicClient.swift` | `stream: true`; event mapper |
| `Sources/iris/OpenAIClient.swift` | `stream: true` + `stream_options`; chunk mapper |
| `Sources/iris/LLMError.swift` | `StreamInterruptedError`; `LLMRetry` unchanged |
| `Sources/iris/iris.swift` | seam rewritten around `StreamAssembler` + `MessageStreamer`; text part handling; status clearing |
| `Sources/iris/MessageStreamer.swift` (new) | coalescing flusher |
| `Sources/iris/AppState.swift` | `updateMessageContent(id:content:in:)` |
| `Sources/iris/IrisDefaults.swift`, `Sources/iris/SettingsView.swift` | `streamResponses` |
| `Sources/iris/PerformanceProfiler.swift`, `PerfRecord.swift`, `PerfSummarizer.swift`, `PerfCLI.swift` report | `firstTokenMs`, `streaming`, `medianFirstTokenMs`, ladder column |
| `perf/README.md`, `docs/tool_hooks.md` | streaming semantics: the first-token column; what a hook sees; partial text on Stop |
| Tests as in Section 8 | |

## 10. Risks

- **Provider drift**: streaming shapes are stable for all three, but the fixtures in the tests are the contract; a live-key manual check is part of the plan's final task.
- **MarkdownUI cost on very long messages**: 20 flushes/s of a 20 KB message could stutter. Mitigation if it shows up: back off the flush interval as content grows (for example 50 ms up to 4 KB, then 150 ms). Not built until measured.
- **Behavioural change to hooks and history** (Sections 4.2, 6): documented, tested, and small; called out in the PR description.
