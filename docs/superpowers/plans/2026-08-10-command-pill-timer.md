# Command Pill Timer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show elapsed time on `run_command` pills — ticking live while the command runs, frozen at the final duration when it finishes.

**Architecture:** Two transient `[UUID: Date/TimeInterval]` dicts on `AppState` track start times and final durations keyed by message ID. The engine supplies a pre-generated UUID when emitting a `run_command` TOOL_CALL message so it can key timing against that exact message. The pill view reads these dicts and uses `TimelineView` for per-second ticking.

**Tech Stack:** Swift, SwiftUI (`TimelineView`), Swift Testing (`@Suite` / `#expect`)

## Global Constraints

- Only `run_command` pills get timers — other tool types are unchanged.
- Timing dicts are transient (not persisted, not in `Conversation`).
- Duration format: `12s` / `1m 23s` / `1h 2m` — no sub-second precision.
- All existing `appendMessage` and `pushToUI` call sites must compile unchanged (use default parameter values).
- Follow the Swift Testing style already in the test suite: `@Suite`, `@Test`, `#expect`.

---

### Task 1: Add timing dicts to AppState and accept a caller-supplied message ID

**Files:**
- Modify: `Sources/iris/AppState.swift:143` (add timing dicts near `isThinking`)
- Modify: `Sources/iris/AppState.swift:584` (update `appendMessage` signature)
- Create: `Tests/irisTests/CommandPillTimerTests.swift`

**Interfaces:**
- Produces:
  - `AppState.commandStartTimes: [UUID: Date]` — writable from any actor via `@MainActor`
  - `AppState.commandDurations: [UUID: TimeInterval]` — writable from any actor via `@MainActor`
  - `AppState.appendMessage(role:content:attachments:id:to:)` — `id` defaults to `UUID()`, all existing call sites unaffected

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/CommandPillTimerTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("CommandPillTimer")
struct CommandPillTimerTests {

    // MARK: formatDuration

    @Test("under one minute shows seconds only")
    func underOneMinute() {
        #expect(formatDuration(0)  == "0s")
        #expect(formatDuration(42) == "42s")
        #expect(formatDuration(59) == "59s")
    }

    @Test("one minute to one hour shows minutes and seconds")
    func minuteRange() {
        #expect(formatDuration(60)   == "1m 0s")
        #expect(formatDuration(83)   == "1m 23s")
        #expect(formatDuration(3599) == "59m 59s")
    }

    @Test("one hour and above shows hours and minutes")
    func hourRange() {
        #expect(formatDuration(3600) == "1h 0m")
        #expect(formatDuration(3723) == "1h 2m")
    }

    // MARK: AppState timing dicts

    @Test("commandStartTimes and commandDurations are initially empty")
    @MainActor func timingDictsStartEmpty() {
        let state = AppState()
        #expect(state.commandStartTimes.isEmpty)
        #expect(state.commandDurations.isEmpty)
    }

    @Test("appendMessage uses supplied id")
    @MainActor func appendMessageUsesSuppliedId() {
        let state = AppState()
        let convId = UUID()
        state.createNewConversation(id: convId)
        let msgId = UUID()
        state.appendMessage(role: .system, content: "hello", id: msgId, to: convId)
        let conv = state.conversations.first { $0.id == convId }
        #expect(conv?.messages.last?.id == msgId)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --filter CommandPillTimerTests 2>&1 | tail -20
```

Expected: compile errors — `formatDuration` undefined, `commandStartTimes` undefined, `id` param not on `appendMessage`.

- [ ] **Step 3: Add timing dicts to AppState**

In `Sources/iris/AppState.swift`, after line 143 (`private(set) var isThinking = false`), add:

```swift
    var commandStartTimes: [UUID: Date] = [:]
    var commandDurations: [UUID: TimeInterval] = [:]
```

- [ ] **Step 4: Update appendMessage to accept an optional id**

Replace the existing `appendMessage` signature at line 584:

```swift
// BEFORE:
func appendMessage(role: ChatRole, content: String, attachments: [FileAttachment] = [], to conversationId: UUID) {
    if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
        conversations[idx].messages.append(ChatMessage(role: role, content: content, attachments: attachments))
```

```swift
// AFTER:
func appendMessage(role: ChatRole, content: String, attachments: [FileAttachment] = [], id: UUID = UUID(), to conversationId: UUID) {
    if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
        conversations[idx].messages.append(ChatMessage(id: id, role: role, content: content, attachments: attachments))
```

Everything after that line in the function body is unchanged.

- [ ] **Step 5: Add formatDuration as an internal free function in ChatView.swift**

Add this anywhere in `Sources/iris/ChatView.swift` at file scope (not inside a struct):

```swift
func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60   { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
```

- [ ] **Step 6: Run tests to confirm they pass**

```bash
swift test --filter CommandPillTimerTests 2>&1 | tail -20
```

Expected: all 5 tests pass.

- [ ] **Step 7: Build to confirm no regressions**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/ChatView.swift Tests/irisTests/CommandPillTimerTests.swift
git commit -m "feat: add timing dicts to AppState and formatDuration helper for command pill timer"
```

---

### Task 2: Record timing in the engine for run_command calls

**Files:**
- Modify: `Sources/iris/iris.swift:1044` (`pushToUI` — add optional `id` param)
- Modify: `Sources/iris/iris.swift:620–628` (tool dispatch loop — supply ID and record timing)

**Interfaces:**
- Consumes: `AppState.commandStartTimes`, `AppState.commandDurations`, `AppState.appendMessage(role:content:attachments:id:to:)` from Task 1
- Produces: for every `run_command` TOOL_CALL message emitted, `commandStartTimes[msgId]` is set before execution and `commandDurations[msgId]` is set after

- [ ] **Step 1: Update pushToUI to accept an optional message id**

Replace the `pushToUI` function at line 1044:

```swift
// BEFORE:
func pushToUI(role: ChatRole, text: String, conversationId: UUID) async {
    let localState = state
    await MainActor.run {
        localState?.appendMessage(role: role, content: text, to: conversationId)
    }
}
```

```swift
// AFTER:
func pushToUI(role: ChatRole, text: String, conversationId: UUID, id: UUID? = nil) async {
    let localState = state
    await MainActor.run {
        if let id {
            localState?.appendMessage(role: role, content: text, id: id, to: conversationId)
        } else {
            localState?.appendMessage(role: role, content: text, to: conversationId)
        }
    }
}
```

- [ ] **Step 2: Build to confirm no regressions at existing call sites**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Record timing in the tool dispatch loop**

In `iris.swift`, replace the block at lines 616–628 (the section inside the `group.addTask` closure that emits the TOOL_CALL message and calls `executeFunctionCall`) with:

```swift
                                    let toolCallDict: [String: Any] = [
                                        "name": call.name,
                                        "args": call.args.mapValues { $0.anyValue }
                                    ]
                                    // For run_command, supply a stable UUID so the UI can key
                                    // elapsed-time display against this exact message.
                                    let timingId: UUID? = call.name == "run_command" ? UUID() : nil
                                    if let jsonData = try? JSONSerialization.data(withJSONObject: toolCallDict, options: .prettyPrinted),
                                       let jsonString = String(data: jsonData, encoding: .utf8) {
                                        await self.pushToUI(role: .system, text: "[TOOL_CALL]\n\(jsonString)", conversationId: conversationId, id: timingId)
                                    } else {
                                        await self.pushToUI(role: .system, text: "Running tool: \(call.name)", conversationId: conversationId, id: timingId)
                                    }
                                    if let id = timingId {
                                        let localState = self.state
                                        await MainActor.run { localState?.commandStartTimes[id] = Date() }
                                    }

                                    let cmdStart = Date()
                                    let result = await self.executeFunctionCall(call, conversationId: conversationId, workspacePath: workspacePath, restrictToGoalComplete: restrictToGoalComplete)
                                    if let id = timingId {
                                        let elapsed = Date().timeIntervalSince(cmdStart)
                                        let localState = self.state
                                        await MainActor.run { localState?.commandDurations[id] = elapsed }
                                    }
                                    return (index, result)
```

- [ ] **Step 4: Build to confirm no regressions**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/iris.swift
git commit -m "feat: record run_command start time and duration in AppState for pill timer"
```

---

### Task 3: Display the timer in the run_command pill

**Files:**
- Modify: `Sources/iris/ChatView.swift` — `SystemGroupView`, `SystemMessageContent`, `toolCallRow`

**Interfaces:**
- Consumes: `AppState.commandStartTimes`, `AppState.commandDurations` (Task 1); `formatDuration` (Task 1)
- Produces: `run_command` pills show a right-aligned elapsed-time label — ticking via `TimelineView` while active, frozen as plain `Text` when finished

- [ ] **Step 1: Add appState parameter to SystemGroupView and look up timing per message**

`SystemGroupView` currently at line 729. Add `let appState: AppState` and thread timing into `SystemMessageContent`:

```swift
// BEFORE:
struct SystemGroupView: View {
    let messages: [ChatMessage]
    @State private var isExpanded = false
```

```swift
// AFTER:
struct SystemGroupView: View {
    let messages: [ChatMessage]
    let appState: AppState
    @State private var isExpanded = false
```

In the `ForEach(messages)` body (currently at line 776), replace:

```swift
// BEFORE:
ForEach(messages) { msg in
    SystemMessageContent(text: msg.content)
        .textSelection(.enabled)
}
```

```swift
// AFTER:
ForEach(messages) { msg in
    SystemMessageContent(
        text: msg.content,
        commandStartTime: appState.commandStartTimes[msg.id],
        commandDuration: appState.commandDurations[msg.id]
    )
    .textSelection(.enabled)
}
```

- [ ] **Step 2: Update the SystemGroupView call site in ChatView**

At line 99, replace:

```swift
// BEFORE:
SystemGroupView(messages: messages)
```

```swift
// AFTER:
SystemGroupView(messages: messages, appState: state)
```

- [ ] **Step 3: Add timing parameters to SystemMessageContent**

`SystemMessageContent` currently at line 796:

```swift
// BEFORE:
struct SystemMessageContent: View {
    let text: String

    var body: some View {
```

```swift
// AFTER:
struct SystemMessageContent: View {
    let text: String
    var commandStartTime: Date? = nil
    var commandDuration: TimeInterval? = nil

    var body: some View {
```

In `SystemMessageContent.body`, the call to `toolCallRow` (line 800–801) becomes:

```swift
// BEFORE:
if let call = ToolCallParser.parse(text) {
    toolCallRow(call)
```

```swift
// AFTER:
if let call = ToolCallParser.parse(text) {
    toolCallRow(call, startTime: commandStartTime, duration: commandDuration)
```

- [ ] **Step 4: Add the timer to toolCallRow**

`toolCallRow` currently at line 808. Replace the entire function:

```swift
@ViewBuilder
private func toolCallRow(_ call: ToolCallDisplay, startTime: Date? = nil, duration: TimeInterval? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        if let command = call.command {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("$").foregroundColor(.secondary)
                    Text(command).foregroundColor(.primary)
                }
                Spacer()
                timerLabel(startTime: startTime, duration: duration)
            }
            .font(.caption.monospaced())
        } else {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundColor(.blue).font(.caption2)
                Text(call.name).font(.caption.bold()).foregroundColor(.primary)
            }
        }
        if let intent = call.intent {
            Text(intent)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.leading, call.command != nil ? 14 : 0)
        }
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
    .cornerRadius(8)
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
}

@ViewBuilder
private func timerLabel(startTime: Date?, duration: TimeInterval?) -> some View {
    if let duration {
        Text(formatDuration(duration))
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.55))
    } else if let startTime {
        TimelineView(.periodic(from: startTime, by: 1)) { context in
            Text(formatDuration(context.date.timeIntervalSince(startTime)))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.55))
        }
    }
}
```

- [ ] **Step 5: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 6: Run full test suite**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass.

- [ ] **Step 7: Manual verification**

Launch the app and run a slow command (e.g. `sleep 5`). Verify:
- Timer appears on the right side of the `$ sleep 5` pill in a small faint font
- Ticks once per second: `0s`, `1s`, `2s`, …
- Freezes at `5s` (or near it) once the command returns
- Fast commands (e.g. `ls`) show a frozen `0s` immediately after completing
- Non-run_command pills (`read_file`, `write_file`) show no timer
- Old pills from previous sessions show no timer

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/ChatView.swift
git commit -m "feat: show elapsed timer on run_command pills in chat UI"
```
