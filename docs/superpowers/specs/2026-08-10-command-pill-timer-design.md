# Command Pill Timer

**Date:** 2026-08-10  
**Scope:** `run_command` pills in the chat UI

## Goal

Show elapsed time on the right side of `run_command` pills: ticking live while the command runs, frozen at final duration when it finishes. Other tool types (read_file, write_file, etc.) are unchanged.

## Data Layer — `AppState`

Two transient dictionaries added to `AppState` (not persisted, not part of `Conversation`):

```swift
var commandStartTimes: [UUID: Date] = [:]
var commandDurations: [UUID: TimeInterval] = [:]
```

`appendMessage` gets an optional `id: UUID = UUID()` parameter. When a caller supplies an ID, the created `ChatMessage` uses it; otherwise a new UUID is generated (all existing call sites are unaffected).

`pushToUI` in `IrisEngine` gets the same optional `id` parameter and threads it to `appendMessage`.

## Engine Layer — `iris.swift`

In the `TaskGroup` tool dispatch loop, for `run_command` calls only:

1. Generate `let msgId = UUID()` before emitting the TOOL_CALL message.
2. Pass `msgId` to `pushToUI`; after the message is appended, record:
   ```swift
   await MainActor.run { localState?.commandStartTimes[msgId] = Date() }
   ```
3. Capture `let cmdStart = Date()` immediately before `executeFunctionCall`.
4. After `executeFunctionCall` returns, record:
   ```swift
   await MainActor.run { localState?.commandDurations[msgId] = Date().timeIntervalSince(cmdStart) }
   ```

Non-`run_command` tool calls are dispatched exactly as before, with no timing recorded.

## View Layer — `ChatView.swift`

### `SystemGroupView`

Add `let appState: AppState` parameter. The single call site in `ChatView` passes the existing `state` value — no other changes at the call site.

In the `ForEach(messages)` loop, look up timing for each message before constructing `SystemMessageContent`:

```swift
let startTime = appState.commandStartTimes[msg.id]
let duration  = appState.commandDurations[msg.id]
SystemMessageContent(text: msg.content, commandStartTime: startTime, commandDuration: duration)
```

Because `AppState` is `@Observable`, accessing `commandStartTimes` and `commandDurations` in the view body registers automatic re-render tracking — no extra `@State` or `@ObservedObject` needed.

### `SystemMessageContent`

Add two optional parameters:

```swift
var commandStartTime: Date? = nil
var commandDuration: TimeInterval? = nil
```

Pass both through to `toolCallRow`.

### `toolCallRow`

The timer is added only when `call.command != nil` (run_command pills). The existing command `HStack` is wrapped in an outer `HStack` with a `Spacer()` and the timer on the trailing edge:

```
[ $ docker build ...          42s ]
  intent text
```

Timer rendering logic:

| State | Condition | Rendering |
|---|---|---|
| Active | `startTime` set, `duration` nil | `TimelineView(.periodic(from: startTime, by: 1))` computing `context.date.timeIntervalSince(startTime)` |
| Finished | `duration` set | Plain `Text(formatDuration(duration))` |
| None | Neither set | Empty (no timer shown) |

At most 1 second of lag between command completion and the timer freezing — acceptable.

### Duration Format

```swift
func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60  { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
```

### Timer Style

`.caption2` font, `.secondary.opacity(0.55)` color. Sits flush right inside the pill's existing horizontal padding.

## Files Changed

| File | Change |
|---|---|
| `AppState.swift` | Add `commandStartTimes`, `commandDurations`; add `id` param to `appendMessage` |
| `iris.swift` | Record start/duration for `run_command` calls; add `id` param to `pushToUI` |
| `ChatView.swift` | Add `appState` to `SystemGroupView`; add timing params to `SystemMessageContent`; add timer to `toolCallRow` |

## Non-Goals

- Timing for non-`run_command` tools
- Persisting timing data across app restarts
- Sub-second precision
