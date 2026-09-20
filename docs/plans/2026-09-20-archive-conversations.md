# Archive Conversations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A conversation can be archived out of the main sidebar list into a collapsed Archived section, stays searchable, and comes back automatically the moment anything sends work to it.

**Architecture:** One persisted `Bool` on `Conversation`, plus a SQLite column. The behavioural core is a single rule with two directions — *archived means idle*: a conversation doing work cannot be archived, and a conversation receiving work is un-archived. The second direction is enforced at two choke points, never per caller.

**Tech Stack:** Swift 6, SwiftUI, GRDB (SQLite), Swift Testing (`@Suite`/`@Test`/`#expect`).

**Spec:** `docs/specs/2026-09-20-archive-conversations.md`

**As-shipped correction (this plan is a historical artifact; the two points below are wrong as written):** Task 1 Step 8's `loadAll` snippet reads `isArchived` through GRDB's typed subscript (`if let archived: Bool = row["isArchived"]`), which force-tries the conversion and crashes the whole load on a garbled, non-NULL, non-0/1 value instead of defaulting to visible — an implementer who followed it as written shipped exactly that crash. The real code reads through a `readBool`-style helper that distinguishes null / unconvertible / value and only warns (never throws) on the unconvertible case; see `ConversationStore.readBool` and its call site in `loadAll`. And Task 4 Step 4's snippet adds `else { markChanged(id, .metadata) }` to `deleteConversation`, framed as "preserve whatever the existing `else` branch does" — the base had no such branch; it is new, and inert, since `markChanged(id, .deleted)` is already called unconditionally just above and the store checks `.deleted` first and returns. It was removed from the shipped code. The task bodies below are left as originally written; do not read either snippet as the current shape of the code.

## Global Constraints

- **Tests use Swift Testing** (`@Suite`, `@Test`, `#expect`). Never XCTest for new tests.
- **Invariant 1 — persisting a field takes TWO changes, not one.** `decodeIfPresent(...) ?? default` in the custom `init(from:)` **and** a real column in `ConversationStore` (schema, *both* `upsertMetadata` branches, `loadAll`). The store hand-enumerates its columns; a field absent from them is silently dropped on every load while its JSON round-trip test passes. That is the bug slice D3 shipped.
- **Invariant 2:** `AppState` is `@Observable`. Never add `@Published`.
- **Invariant 7:** never mutate `ConfigManager.shared` in a test.
- **Invariant 9:** a change fixes what it makes untrue. Task 8 is not optional.
- Persistence goes through `markChanged(_:_:)`; `saveConversations()` no longer exists.
- House style: short comments explaining *why*, not *what*. No emoji in code or commit messages. Conventional commits.
- **Run `swift test` and READ the output before committing.** Do NOT chain it behind a `grep` with `&&` — a matching grep makes a red suite exit 0.
- **Staging:** an untracked `docs/agency/` directory belongs to the repo owner. Never `git add -A`. Stage by explicit path.

---

### Task 1: Persist `isArchived`

**Files:**
- Modify: `Sources/iris/AppState.swift` (the `Conversation` struct, its `CodingKeys`, its `init(from:)`)
- Modify: `Sources/iris/ConversationStore.swift` (migrator, `upsertMetadata` both branches, `loadAll`)
- Test: `Tests/irisTests/ConversationStoreTests.swift` (extend `roundTrip`, add a decode test)

**Interfaces:**
- Produces: `Conversation.isArchived: Bool` — every later task reads or writes it.

- [ ] **Step 1: Determine the migration number**

The spec names the migration **by purpose**, not by number, because #191 is open with its own migration and whichever lands second must renumber.

Run: `grep -n "registerMigration" Sources/iris/ConversationStore.swift`
Take the highest `vN` present on your branch and use `N+1`. At the time of writing `main` ends at `v5_quarantine_ordinal_nullable`, so this is likely `v6_archive` — but **verify, do not assume**. If a `v6` already exists, use `v7_archive`.

- [ ] **Step 2: Write the failing store round-trip assertions**

In `Tests/irisTests/ConversationStoreTests.swift`, find `sample()` and set the flag on it, then add to `roundTrip()` right after the `checkpointHistory` assertions:

```swift
        // #182: archived state is a stored column, not just a Codable field. A JSON round-trip
        // test would pass while the column did not exist and the flag was dropped on every load.
        #expect(back.isArchived == true)
```

In `sample()`, add `c.isArchived = true` beside the other field assignments.

- [ ] **Step 3: Add a legacy-decode test**

Append to the same file:

```swift
    @Test("a conversation with no isArchived key decodes as active")
    func legacyConversationDecodesActive() throws {
        // Invariant 1: a synthesized decoder throws on a missing key and drops every conversation.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"old"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Conversation.self, from: legacy)
        #expect(decoded.isArchived == false)
    }
```

- [ ] **Step 4: Run both to verify they fail**

Run: `swift test --filter ConversationStoreTests`
Expected: FAIL to compile — `value of type 'Conversation' has no member 'isArchived'`.

- [ ] **Step 5: Add the field**

In `Sources/iris/AppState.swift`, in `struct Conversation`, beside `isSubagent`:

```swift
    /// #182 — archived conversations leave the main sidebar list for a collapsed section. Durable,
    /// unlike `isSubagent`, which has no column because subagent conversations are filtered out of
    /// persistence entirely.
    var isArchived: Bool = false
```

Add `isArchived` to the `CodingKeys` enum, and in `init(from:)` beside the `isSubagent` line:

```swift
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
```

- [ ] **Step 6: Add the column**

In `Sources/iris/ConversationStore.swift`, after the last `registerMigration` (use the number from Step 1):

```swift
        // #182. A new nullable column rather than a table rebuild: NULL reads back as `false`,
        // so every existing conversation loads active, which is the desired migration.
        m.registerMigration("v6_archive") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "isArchived", .boolean)
            }
        }
```

- [ ] **Step 7: Write it in both upsert branches**

In `upsertMetadata`, add `isArchived = ?` to the UPDATE's SET list and `c.isArchived` to its arguments (before `c.id.uuidString`, matching column order); add `isArchived` to the INSERT's column list, one more `?` to its VALUES, and `c.isArchived` to its arguments.

**Both branches.** Missing one means the flag persists on create but never on update, or vice versa — a bug the round-trip test alone may not catch depending on which path it exercises.

- [ ] **Step 8: Read it in `loadAll`**

In `loadAll`, beside the other column reads, and using the **counter** policy (warn and default) rather than the whole-conversation skip.

**Do not read this column through GRDB's typed subscript** (`row["isArchived"] as Bool?` or `if let archived: Bool = row["isArchived"]`) — it force-tries the conversion and crashes the *entire load* on a garbled, non-NULL, non-0/1 value instead of defaulting to visible. Route it through a `readBool`-style helper that returns null / unconvertible / value as distinct cases, matching the existing `readInt` pattern, and only warn (never throw) on `unconvertible`. See the shipped `ConversationStore.readBool` and its call site in `loadAll` for the exact shape.

- [ ] **Step 9: Run the tests**

Run: `swift test --filter ConversationStoreTests`
Expected: PASS.

Then `swift test` and READ it. Expected: all green.

- [ ] **Step 10: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/ConversationStore.swift Tests/irisTests/ConversationStoreTests.swift
git commit -m "feat(archive): persist isArchived as a stored column"
```

---

### Task 2: Archive and unarchive transitions

**Files:**
- Modify: `Sources/iris/AppState.swift`
- Test: `Tests/irisTests/ArchiveConversationTests.swift` (create)

**Interfaces:**
- Consumes: `Conversation.isArchived` (Task 1); existing `hasTurnInFlight(for:)`.
- Produces:
  - `enum ArchiveRefusal: Equatable { case turnInFlight, goalActive; var reason: String }`
  - `func archiveRefusal(for id: UUID) -> ArchiveRefusal?` — nil means it may be archived. The UI calls this to disable its menu item.
  - `@discardableResult func archiveConversation(_ id: UUID) -> ArchiveRefusal?`
  - `func unarchiveConversation(_ id: UUID)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/ArchiveConversationTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// #182. Archiving is a list-management gesture: it must never change what the agent is doing,
/// and must never leave the user without somewhere to type.
@MainActor
@Suite("Archive conversations")
struct ArchiveConversationTests {

    @Test("archiving is refused while a goal is active")
    func refusedWithActiveGoal() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.setGoal(for: a, goal: "ship it")

        #expect(app.archiveRefusal(for: a) == .goalActive)
        #expect(app.archiveConversation(a) == .goalActive)
        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
    }

    @Test("archiving moves the conversation and leaves selection alone when others remain")
    func archivesAndKeepsSelection() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.selectedConversationId = a

        #expect(app.archiveConversation(a) == nil)
        #expect(app.conversations.first { $0.id == a }?.isArchived == true)
        #expect(app.selectedConversationId == a, "an archived conversation is still rendered, so it stays valid")
    }

    @Test("archiving the last active conversation creates one and selects it")
    func lastActiveGetsReplacement() {
        let app = AppState(); app.conversations.removeAll()
        let only = UUID()
        app.createNewConversation(id: only)
        app.selectedConversationId = only

        #expect(app.archiveConversation(only) == nil)
        let active = app.conversations.filter { !$0.isSubagent && !$0.isArchived }
        #expect(active.count == 1, "the user needs somewhere to type")
        #expect(active.first?.id != only)
        #expect(app.selectedConversationId == active.first?.id, "selection follows the replacement")
    }

    @Test("unarchiving returns it to the active set")
    func unarchiveRestores() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        _ = app.archiveConversation(a)

        app.unarchiveConversation(a)
        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
    }
}
```

Note the refusal test uses `setGoal`, which sets `activeGoal` without a contract — the simplest way to make `activeGoal != nil`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ArchiveConversationTests`
Expected: FAIL to compile — no member `archiveRefusal`.

- [ ] **Step 3: Implement**

In `Sources/iris/AppState.swift`, near `deleteConversation`:

```swift
    /// Why a conversation may not be archived. Archiving is list management, not control: it must
    /// not quietly stop an agent, and a goal loop running inside a collapsed section is work
    /// happening where nobody is looking (#182 §6.1).
    enum ArchiveRefusal: Equatable {
        case turnInFlight
        case goalActive

        var reason: String {
            switch self {
            case .turnInFlight: return "a turn is still running"
            case .goalActive: return "a goal is active — /stop it first"
            }
        }
    }

    /// nil means the conversation may be archived. The sidebar calls this to disable its menu item
    /// with the reason, since a context-menu click has no channel for a system message.
    func archiveRefusal(for conversationId: UUID) -> ArchiveRefusal? {
        guard let conv = conversations.first(where: { $0.id == conversationId }) else { return nil }
        if hasTurnInFlight(for: conversationId) { return .turnInFlight }
        if conv.activeGoal != nil { return .goalActive }
        return nil
    }

    @discardableResult
    func archiveConversation(_ conversationId: UUID) -> ArchiveRefusal? {
        if let refusal = archiveRefusal(for: conversationId) { return refusal }
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              !conversations[idx].isArchived else { return nil }
        conversations[idx].isArchived = true
        markChanged(conversationId, .metadata)

        // Archiving your only active conversation would leave nowhere to type. §6.1's refusal is
        // what makes this safe: the replacement can never inherit a running goal, because a
        // conversation with one cannot be archived at all.
        if !conversations.contains(where: { !$0.isSubagent && !$0.isArchived }) {
            createNewConversation()   // selects itself
        }
        return nil
    }

    func unarchiveConversation(_ conversationId: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }),
              conversations[idx].isArchived else { return }
        conversations[idx].isArchived = false
        markChanged(conversationId, .metadata)
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter ArchiveConversationTests`
Expected: PASS, all four.

Then `swift test` and READ it.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/AppState.swift Tests/irisTests/ArchiveConversationTests.swift
git commit -m "feat(archive): archive and unarchive transitions, refused while work is in flight"
```

---

### Task 3: Work arriving un-archives — the two choke points

**Files:**
- Modify: `Sources/iris/iris.swift` (`handleSystemEvent`)
- Modify: `Sources/iris/AppState.swift` (`sendMessage`)
- Test: `Tests/irisTests/ArchiveUnarchiveOnWorkTests.swift` (create)

**Interfaces:**
- Consumes: `unarchiveConversation(_:)` (Task 2).
- Produces: no new API — two existing entry points gain one call each.

**This is the task that makes Task 2's refusal mean anything.** Gating only the archive gesture leaves three routes that start a turn in an archived conversation. Do NOT enumerate callers; the rule belongs at the choke points:

1. `IrisEngine.handleSystemEvent(_:source:conversationId:)` — the scheduler, background subagent post-backs, and the file watcher all arrive through it. It resolves its target as `conversationId ?? selectedConversationId`, and the **watcher passes no id**, so it targets whatever is selected — which §8 deliberately leaves on a just-archived conversation.
2. The **turn-starting path** of `AppState.sendMessage` — scoped deliberately: `sendMessage` also dispatches slash commands that start no turn, and `/tokens` must not un-archive anything.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/ArchiveUnarchiveOnWorkTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// #182 §6.2 — "archived means idle" has two directions. Work arriving is the second one.
@MainActor
@Suite("Un-archive on arriving work")
struct ArchiveUnarchiveOnWorkTests {

    private func archived(_ app: AppState) -> UUID {
        let id = UUID()
        app.createNewConversation(id: id)
        app.createNewConversation(id: UUID())   // so archiving does not trigger the replacement
        _ = app.archiveConversation(id)
        return id
    }

    @Test("sending a message un-archives the target before the turn starts")
    func sendUnarchives() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id

        app.sendMessage("hello")

        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
    }

    @Test("a slash command that starts no turn does not un-archive")
    func slashCommandDoesNotUnarchive() {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id

        app.sendMessage("/tokens")

        #expect(app.conversations.first { $0.id == id }?.isArchived == true,
                "only the turn-starting path un-archives")
    }

    @Test("a system event un-archives its target conversation")
    func systemEventUnarchives() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient())

        await engine.handleSystemEvent("Scheduled Job Triggered: do the thing",
                                       source: "Scheduler", conversationId: id)

        #expect(app.conversations.first { $0.id == id }?.isArchived == false)
    }

    @Test("a system event with no conversation id un-archives the selected one")
    func systemEventWithoutIdUnarchivesSelection() async {
        let app = AppState(); app.conversations.removeAll()
        let id = archived(app)
        app.selectedConversationId = id      // the watcher's case: no id, falls back to selection
        let engine = IrisEngine(state: app, tier: .medium, client: FakeLLMClient())

        await engine.handleSystemEvent("File changed: notes.md", source: "Watcher")

        #expect(app.conversations.first { $0.id == id }?.isArchived == false,
                "the watcher passes no id, which is why the rule lives at the choke point")
    }
}
```

Use whatever fake client the existing engine tests use — check `Tests/irisTests/DelegateMilestoneTests.swift` or `GoalCompleteTests.swift` for the constructor in current use and mirror it.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter ArchiveUnarchiveOnWorkTests`
Expected: FAIL — `isArchived` is still `true` in the un-archiving cases.

- [ ] **Step 3: Un-archive in `handleSystemEvent`**

In `Sources/iris/iris.swift`, in `handleSystemEvent`, immediately after `guard let activeId = targetId else { return }`:

```swift
        // #182 §6.2: every non-user arrival lands here — the scheduler, subagent post-backs, and
        // the watcher (which passes no id and so targets whatever is selected). Stating the rule
        // at this choke point covers all of them and cannot go stale when a fourth is added.
        await MainActor.run { localState?.unarchiveConversation(activeId) }
```

- [ ] **Step 4: Un-archive on the turn-starting path of `sendMessage`**

In `Sources/iris/AppState.swift`, in `sendMessage`, after slash-command dispatch has been ruled out and immediately before the turn is started, add:

```swift
        // #182 §6.2: typing into an archived conversation is how the user says they want it back.
        // Deliberately not at the top of the method: `/tokens` and friends start no turn.
        unarchiveConversation(convId)
```

Read the method first and place it on the path that actually begins a turn — if slash commands return early, immediately after that block is correct.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ArchiveUnarchiveOnWorkTests`
Expected: PASS, all four.

Then `swift test` and READ it.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/iris.swift Sources/iris/AppState.swift Tests/irisTests/ArchiveUnarchiveOnWorkTests.swift
git commit -m "feat(archive): arriving work un-archives its target at both choke points"
```

---

### Task 4: Selection paths

**Files:**
- Modify: `Sources/iris/AppState.swift` (`loadConversations`, `deleteConversation`)
- Test: `Tests/irisTests/ArchiveSelectionTests.swift` (create)

**Interfaces:**
- Consumes: `Conversation.isArchived` (Task 1).

Four paths set `selectedConversationId`. Keeping archived conversations in the same list means a delete re-point or a search reveal always lands on something rendered. **The launch path is the exception**: it picks by `position`, assigned at INSERT and never changed, so archiving your newest conversation would make every launch open onto it inside the collapsed section.

- [ ] **Step 1: Write the failing tests**

Create `Tests/irisTests/ArchiveSelectionTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// #182 §5 — the same-list design dissolves the "selected but not rendered" class for delete and
/// search. The launch path picks by `position`, not by what the user touched, so it needs a rule.
@MainActor
@Suite("Archive and selection")
struct ArchiveSelectionTests {

    @Test("delete re-points to an active conversation, never an archived one")
    func deletePrefersActive() {
        let app = AppState(); app.conversations.removeAll()
        let keep = UUID(), archivedOne = UUID(), doomed = UUID()
        app.createNewConversation(id: keep)
        app.createNewConversation(id: archivedOne)
        app.createNewConversation(id: doomed)
        _ = app.archiveConversation(archivedOne)
        app.selectedConversationId = doomed

        app.deleteConversation(doomed)

        #expect(app.selectedConversationId == keep)
        #expect(app.selectedConversationId != archivedOne)
    }

    @Test("deleting the last active conversation creates a new one rather than landing in the archive")
    func deleteLastActiveCreates() {
        let app = AppState(); app.conversations.removeAll()
        let archivedOne = UUID(), doomed = UUID()
        app.createNewConversation(id: archivedOne)
        app.createNewConversation(id: doomed)
        _ = app.archiveConversation(archivedOne)
        app.selectedConversationId = doomed

        app.deleteConversation(doomed)

        let active = app.conversations.filter { !$0.isSubagent && !$0.isArchived }
        #expect(active.count == 1)
        #expect(active.first?.id != archivedOne)
        #expect(app.selectedConversationId == active.first?.id)
    }
}
```

The launch-path rule is exercised by Task 1's store tests plus a direct assertion; add this one too:

```swift
    @Test("launch selection prefers the last non-archived conversation")
    func launchPrefersActive() {
        // `selectLaunchConversation` is the extracted rule; `loadConversations` calls it.
        let active = Conversation(id: UUID(), title: "active")
        var archivedOne = Conversation(id: UUID(), title: "archived")
        archivedOne.isArchived = true
        #expect(AppState.selectLaunchConversation([active, archivedOne])?.id == active.id)
        #expect(AppState.selectLaunchConversation([archivedOne])?.id == archivedOne.id,
                "falls back only when there is nothing else")
        #expect(AppState.selectLaunchConversation([]) == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ArchiveSelectionTests`
Expected: FAIL — no member `selectLaunchConversation`; the delete tests may pass or fail depending on ordering, which is why the rule is made explicit.

- [ ] **Step 3: Extract and apply the launch rule**

In `Sources/iris/AppState.swift`, add a pure static helper (testable without constructing `AppState`):

```swift
    /// #182 §5. `position` is assigned at INSERT and never changed, so the last row may well be an
    /// archived one — which would open every launch inside the collapsed section. Prefer the last
    /// active conversation; fall back to an archived one only when there is nothing else, in which
    /// case §6.2 un-archives it on the first thing sent.
    nonisolated static func selectLaunchConversation(_ loaded: [Conversation]) -> Conversation? {
        loaded.last(where: { !$0.isArchived }) ?? loaded.last
    }
```

In `loadConversations`, replace `self.selectedConversationId = loaded.last?.id` with:

```swift
                self.selectedConversationId = Self.selectLaunchConversation(loaded)?.id
```

- [ ] **Step 4: Apply the delete rule**

In `deleteConversation`, change the re-point and the creation check so both count **active** conversations only:

```swift
        if selectedConversationId == id {
            selectedConversationId = conversations.last(where: { !$0.isSubagent && !$0.isArchived })?.id
        }
        // Counts active only: deleting your last active conversation puts the user in a new empty
        // one, not in the archive. There is deliberately no archived fallback above — this check
        // would immediately supersede it (#182 §5).
        if !conversations.contains(where: { !$0.isSubagent && !$0.isArchived }) {
            createNewConversation()
        }
```

Only the two predicates change; do not add an `else` branch here. `markChanged(id, .deleted)` is already called unconditionally above this block, and the store checks `.deleted` first and returns — an `else { markChanged(id, .metadata) }` would be new, dead code.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ArchiveSelectionTests`
Expected: PASS.

Then `swift test` and READ it. Watch the existing `DeleteConversationSelectionTests` — it must stay green.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/AppState.swift Tests/irisTests/ArchiveSelectionTests.swift
git commit -m "feat(archive): selection paths prefer active conversations"
```

---

### Task 5: The sidebar

**Files:**
- Modify: `Sources/iris/ChatView.swift`

**Interfaces:**
- Consumes: `isArchived`, `archiveRefusal(for:)`, `archiveConversation(_:)`, `unarchiveConversation(_:)`.

SwiftUI layout is not unit-tested in this repo; this task is verified by build and inspection. Everything testable was pushed into Tasks 2-4 deliberately.

- [ ] **Step 1: Filter the existing section**

The Conversations `ForEach` is currently `state.conversations.filter { !$0.isSubagent }`. Add the archive clause:

```swift
ForEach(state.conversations.filter { !$0.isSubagent && !$0.isArchived }) { conv in
```

- [ ] **Step 2: Add the Archived section**

Below the Conversations section, inside the same `List`:

```swift
                    let archived = state.conversations.filter { !$0.isSubagent && $0.isArchived }
                    if !archived.isEmpty {
                        // Expanded whenever the selection is in here, so a search reveal or the
                        // launch fallback can never leave a selected row invisible (#182 §9).
                        DisclosureGroup(isExpanded: Binding(
                            get: {
                                archivedExpanded || archived.contains { $0.id == state.selectedConversationId }
                            },
                            set: { archivedExpanded = $0 }
                        )) {
                            ForEach(archived) { conv in
                                conversationRow(conv)
                            }
                        } label: {
                            Text("Archived").font(.caption.weight(.bold)).foregroundColor(.secondary)
                        }
                    }
```

Add `@State private var archivedExpanded = false` to the view.

Extract the existing row body (the `HStack` with title, workspace path, `.tag`, and `.contextMenu`) into a `@ViewBuilder private func conversationRow(_ conv: Conversation) -> some View` so both sections render identical rows. Do this as a pure extraction first and confirm the build is clean before adding the section.

- [ ] **Step 3: Archive/Unarchive in the context menu**

In `conversationRow`'s `.contextMenu`, beside the existing items:

```swift
                                if conv.isArchived {
                                    Button("Unarchive") { state.unarchiveConversation(conv.id) }
                                } else {
                                    // A context-menu click has no channel for a system message, so
                                    // the refusal lives in the disabled title rather than failing
                                    // silently (#182 §9.1).
                                    let refusal = state.archiveRefusal(for: conv.id)
                                    Button(refusal == nil ? "Archive" : "Archive (\(refusal!.reason))") {
                                        state.archiveConversation(conv.id)
                                    }
                                    .disabled(refusal != nil)
                                }
```

- [ ] **Step 4: Build and inspect**

Run: `swift build` — expected clean.
Run: `swift test` and READ it — expected all green (no test touches this file).

Launch the app (`scripts/run-dev.sh`) and confirm: archiving from the context menu moves the row into a collapsed Archived group; the group auto-expands when the archived conversation is selected; Unarchive returns it; and Archive is disabled with a reason on a conversation running a goal.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/ChatView.swift
git commit -m "feat(archive): archived sidebar section with auto-expand and context menu"
```

---

### Task 6: `/archive` and `/unarchive`

**Files:**
- Modify: `Sources/iris/AppState.swift` (slash-command chain)
- Modify: `Sources/iris/SlashCommandItem.swift`
- Test: `Tests/irisTests/ArchiveConversationTests.swift` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `ArchiveConversationTests`:

```swift
    @Test("/archive archives the current conversation")
    func slashArchive() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.selectedConversationId = a

        app.sendMessage("/archive")

        #expect(app.conversations.first { $0.id == a }?.isArchived == true)
    }

    @Test("/archive reports the refusal rather than archiving")
    func slashArchiveRefused() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.setGoal(for: a, goal: "ship it")
        app.selectedConversationId = a

        app.sendMessage("/archive")

        #expect(app.conversations.first { $0.id == a }?.isArchived == false)
        let messages = app.conversations.first { $0.id == a }?.messages ?? []
        #expect(messages.contains { $0.content.contains("goal is active") })
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ArchiveConversationTests`
Expected: FAIL — `/archive` is treated as ordinary text.

- [ ] **Step 3: Add the commands**

In the slash-command chain in `sendMessage` (beside `/stop`, `/tokens` and friends), matching the surrounding style:

```swift
        } else if trimmed == "/archive" {
            if let refusal = archiveConversation(convId) {
                appendMessage(role: .system, content: "Cannot archive: \(refusal.reason).", to: convId)
            }
            return
        } else if trimmed == "/unarchive" {
            unarchiveConversation(convId)
            return
        }
```

Place these **before** the un-archive call added in Task 3, so `/archive` is not immediately undone by it. Verify by reading the method: the slash-command block must return before the turn-starting path.

- [ ] **Step 4: Register them for autocomplete**

In `Sources/iris/SlashCommandItem.swift`, in `allCommands`, beside `/new` and `/clear`:

```swift
        SlashCommandItem(id: "archive", command: "/archive", usage: "/archive", description: "Move this conversation to the archive"),
        SlashCommandItem(id: "unarchive", command: "/unarchive", usage: "/unarchive", description: "Return this conversation to the active list"),
```

Omitting these makes the commands work but stay undiscoverable.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ArchiveConversationTests`
Expected: PASS.

Then `swift test` and READ it.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/SlashCommandItem.swift Tests/irisTests/ArchiveConversationTests.swift
git commit -m "feat(archive): add /archive and /unarchive"
```

---

### Task 7: Mark archived hits in search results

**Files:**
- Modify: `Sources/iris/ChatView.swift` (the #212 Results section)

While a query is active, #212 replaces the Conversations section entirely, so neither archive state is visible. Results are grouped by conversation — **the marker belongs on the group header**, not repeated on every hit row.

- [ ] **Step 1: Add the marker**

In the Results section's group header, beside the conversation title:

```swift
                                if state.conversations.first(where: { $0.id == group.conversationId })?.isArchived == true {
                                    Text("Archived")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
```

Read the existing header construction and match its layout; the point is that the user knows where clicking will take them.

- [ ] **Step 2: Build and inspect**

Run: `swift build` — clean.
Run: `swift test` and READ it — green.

Launch, archive a conversation with distinctive text, search for it, and confirm the group header is marked and clicking still reveals it (the Archived group auto-expands per Task 5).

- [ ] **Step 3: Commit**

```bash
git add Sources/iris/ChatView.swift
git commit -m "feat(archive): mark archived conversations in search results"
```

---

### Task 8: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/slash_commands.md`

Invariant 9: fix what this makes untrue, not only describe what it adds.

- [ ] **Step 1: README**

Four places, each currently describing a single conversation list:

- `:18` and `:31` — the sidebar and search descriptions. Add the archive section, and note archived conversations stay searchable.
- `:40` — the context-menu list. Add Archive / Unarchive.
- `:118` — the conversation-list feature bullet.
- `:119` ("Session Control") — add `/archive` and `/unarchive` beside `/new` and `/clear`.

Verify the line numbers before editing; they drift.

Be accurate about the behaviour, in the README's voice: archiving is refused while work is in flight, and anything sent to an archived conversation brings it back.

- [ ] **Step 2: `docs/slash_commands.md`**

Add `/archive` and `/unarchive` entries matching the file's existing format.

- [ ] **Step 3: Verify and commit**

Run: `swift test` and READ it — green (docs-only; this is a guard against an accidental edit).

```bash
git add README.md docs/slash_commands.md
git commit -m "docs: archive conversations"
```

---

## Self-Review

**1. Spec coverage**

| Spec section | Task |
|---|---|
| §3 state and persistence | Task 1 |
| §3 unreadable column | Task 1 Step 8 |
| §3 migration numbering | Task 1 Step 1 |
| §4 sidebar sections | Task 5 |
| §5 launch path | Task 4 |
| §5 delete, both halves | Task 4 |
| §6.1 refusal | Task 2 |
| §6.2 both choke points | Task 3 |
| §7 restoring | Tasks 2, 5, 6 |
| §8 last-active replacement | Task 2 |
| §9 search marker + auto-expand | Tasks 7, 5 |
| §9.1 ordering | nothing to build — `position` is already preserved |
| §9.1 context menu, disabled refusal | Task 5 |
| §10 docs | Task 8 |
| §11 testing | Tasks 1-4, 6 |

No gaps. §9.1's ordering claim needs no work: archived rows keep their `position` by doing nothing.

**2. Placeholder scan** — every code step carries real code. Task 3 Step 1 points at existing engine tests for the fake-client constructor rather than guessing at a name that may have changed; Task 5 Step 2 requires the row extraction be confirmed building before the section is added.

**3. Type consistency** — `ArchiveRefusal`, `archiveRefusal(for:)`, `archiveConversation(_:)`, `unarchiveConversation(_:)` and `selectLaunchConversation(_:)` are spelled identically in every task that uses them. `isArchived` throughout.

**One ordering hazard flagged in the plan itself:** Task 6's `/archive` must return before Task 3's un-archive call on the turn-starting path, or archiving via the command would be undone in the same call. Task 6 Step 3 says so explicitly and tells the implementer to verify by reading the method.
