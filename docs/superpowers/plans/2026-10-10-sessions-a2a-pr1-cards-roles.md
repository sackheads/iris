# Sessions Part 2, PR 1: Cards, Roles, Names, Addressing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give sessions user-assigned unique roles, unique names, worker lanes, A2A 0.3 skills for role-holders, harness-derived project facts, a richer `list_sessions`, a `describe_session` tool, and `send_to_session` addressing by `role:` / `name:` / `iris`.

**Architecture:** Role and name rules live in a new pure `SessionRoles` helper plus `AppState` mutators on the MainActor (the single writer, so uniqueness needs no database index). The card gains optional A2A-shaped fields with a custom `init(from:)`. `SessionDirectory` grows a resolver and a richer `SessionPeer`; a new `GitHead` reads repo and branch from `.git` files without spawning a process. The engine's existing session-tool block gains `describe_session` and new parameters.

**Tech Stack:** Swift 6, SwiftUI app target, GRDB-backed `ConversationStore`, Swift Testing.

**Spec:** `docs/specs/2026-10-10-sessions-a2a-messaging.md` (§4, §5.2's `to` addressing, §8's `role` column, §12's role framing). PRs 2 (messages, correlation, ledger, limits) and 3 (artifacts) get their own plans after this merges.

## Global Constraints

- Base the branch on `main`; never stack on another PR.
- Every new persisted field: `decodeIfPresent` in `init(from:)` **and** a store column read back in `loadAll` (Invariant 1). The round-trip test in `ConversationStoreTests.roundTrip` is the one that catches a missing column.
- No test mutates `ConfigManager.shared` or any other process-global (Invariant 7).
- Every session-authored string reaching the model goes through `IrisEngine.flattenCardField` (render) and `capCardField` (store).
- Every `ARRAY` `Schema` sets `items`, or Gemini returns HTTP 400.
- New tools join the gating sets: `unattendedNeverDeclared`, `mainOnlyDeclared`, `StickyTools.eligible`, `inlineDeclaredToolNames` (Invariant 6).
- Role names: lowercase `[a-z0-9-]`, 1–32 characters, starting alphanumeric; `clear` and `iris` reserved.
- Bounds: lane 64 chars; at most 5 skills; per skill: id 32, name 64, description 200, at most 5 tags of 24, at most 3 examples of 160.
- The second brain pays nothing: a session with no role, no peers and no card gets exactly the declarations and turn context it gets today.
- `scripts/test-filter.sh <TypeName>` for focused runs (the filter takes the suite's **type** name; quote the test count when citing a run). `swift test` and `scripts/check-warnings.sh` must pass before the PR.
- Conventional commits, no emoji, trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Duplicate names already on disk.** Cards written before this PR can share a name. `name:<x>` matching two sessions must refuse as ambiguous and point at `session_id`, never pick one. (Test in Task 7.)
2. **A role-holder unarchived or restored from an old database alongside a newer holder.** Load-time normalization must leave exactly one holder: the most recently updated one keeps it. (Test in Task 2.)
3. **Updating a card without restating skills or lane.** A role-holder that re-cards just to change its description must keep its skills; absent means unchanged, an empty value clears. (Test in Task 4.)
4. **A worktree or a workspace that is a subdirectory of a repo.** The project shown must be the repo's own name and the worktree's branch, not "unknown" and not the worktree directory's name. (Test in Task 5.)
5. **The pinned Iris addressed by role or given a role.** `/role` in Iris refuses; `to: iris` reaches Iris; `role:iris` is refused as reserved. (Tests in Tasks 3 and 7.)

---

### Task 1: A2A-shaped card fields

**Files:**
- Modify: `Sources/IrisKit/AppState.swift:99-107` (`SessionCard`)
- Test: `Tests/irisTests/SessionCardFieldsTests.swift` (create)

**Interfaces:**
- Produces: `struct AgentSkill: Codable, Equatable, Sendable { var id, name, description: String; var tags: [String]; var examples: [String] }`; `SessionCard.lane: String?`, `SessionCard.skills: [AgentSkill]` (default `[]`); memberwise init `SessionCard(name:description:updatedAt:lane:skills:)` with defaults for the last three.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import IrisKit

@Suite("Session card A2A fields")
struct SessionCardFieldsTests {
    @Test("a card stored before part 2 decodes with no lane and no skills")
    func legacyCardDecodes() throws {
        let json = #"{"name":"spec-writer","description":"drafting","updatedAt":0}"#
        let card = try JSONDecoder().decode(SessionCard.self, from: Data(json.utf8))
        #expect(card.name == "spec-writer")
        #expect(card.lane == nil)
        #expect(card.skills.isEmpty)
    }

    @Test("lane and skills round-trip")
    func roundTrip() throws {
        let skill = AgentSkill(id: "review-pr", name: "Review a PR", description: "Reviews one PR",
                               tags: ["github"], examples: ["review PR 12"])
        let card = SessionCard(name: "pr-minder", description: "watching PRs", lane: "github", skills: [skill])
        let back = try JSONDecoder().decode(SessionCard.self, from: JSONEncoder().encode(card))
        #expect(back.lane == "github")
        #expect(back.skills == [skill])
    }

    @Test("a skill missing tags or examples decodes with empty lists")
    func sparseSkillDecodes() throws {
        let json = #"{"id":"a","name":"A","description":"d"}"#
        let skill = try JSONDecoder().decode(AgentSkill.self, from: Data(json.utf8))
        #expect(skill.tags.isEmpty && skill.examples.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test-filter.sh SessionCardFieldsTests`
Expected: compile failure, `AgentSkill` and `lane` undefined.

- [ ] **Step 3: Implement**

Replace the `SessionCard` struct:

```swift
/// A2A 0.3 `AgentSkill` (#469 §4.4): something a role-holder will do on request.
struct AgentSkill: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var description: String
    var tags: [String] = []
    var examples: [String] = []

    init(id: String, name: String, description: String, tags: [String] = [], examples: [String] = []) {
        self.id = id; self.name = name; self.description = description
        self.tags = tags; self.examples = examples
    }

    enum CodingKeys: String, CodingKey { case id, name, description, tags, examples }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        examples = try c.decodeIfPresent([String].self, forKey: .examples) ?? []
    }
}

/// A2A-shaped identity a session advertises to its peers (#185 §4, #469 §4). Distinct from
/// `title`, which is the user's name for the chat: the card is what the agent is doing *now*.
/// `name`, `description` and `skills` are A2A 0.3 `AgentCard` fields; `lane` is iris's own.
struct SessionCard: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var updatedAt: Date = Date()
    /// #469 §4.1: a worker's topical lane, free text.
    var lane: String? = nil
    /// #469 §4.4: role-holders only; the `set_session_card` handler refuses them elsewhere.
    var skills: [AgentSkill] = []

    init(name: String, description: String, updatedAt: Date = Date(), lane: String? = nil,
         skills: [AgentSkill] = []) {
        self.name = name; self.description = description; self.updatedAt = updatedAt
        self.lane = lane; self.skills = skills
    }

    enum CodingKeys: String, CodingKey { case name, description, updatedAt, lane, skills }

    // Invariant 1: every card stored before #469 lacks lane and skills.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        lane = try c.decodeIfPresent(String.self, forKey: .lane)
        skills = try c.decodeIfPresent([AgentSkill].self, forKey: .skills) ?? []
    }
}
```

- [ ] **Step 4: Run tests**

Run: `scripts/test-filter.sh SessionCardFieldsTests` — expect 3 tests pass. Then `scripts/test-filter.sh ConversationStoreTests` — still green (the card column is JSON, so no migration).

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/AppState.swift Tests/irisTests/SessionCardFieldsTests.swift
git commit -m "feat(sessions): A2A-shaped lane and skills on the session card (#469)"
```

---

### Task 2: Roles — model, persistence, uniqueness, archive

**Files:**
- Create: `Sources/IrisKit/SessionRoles.swift`
- Modify: `Sources/IrisKit/AppState.swift` (`Conversation` near `:153`, its `CodingKeys` and `init(from:)`; `ArchiveRefusal` `:1812`; `archiveRefusal(for:)` `:1836`; new mutators beside `setSessionCard` `:1531`; `sanitizeLoaded` `:3391`)
- Modify: `Sources/IrisKit/ConversationStore.swift` (new migration after `v18_prefix_mismatch_behavior` `:581`; `upsertMetadata` `:777`; `loadAll` beside the `sessionCard` read `:1163`)
- Test: `Tests/irisTests/SessionRolesTests.swift` (create), `Tests/irisTests/ConversationStoreTests.swift` (extend `roundTrip`)

**Interfaces:**
- Produces:
  - `Conversation.role: String?`
  - `enum SessionRoles { static func normalizedName(_ raw: String) -> String?; static let reserved: Set<String>; static func holder(of role: String, in: [Conversation]) -> UUID?; static func normalize(_ conversations: inout [Conversation]) }`
  - `AppState.assignRole(_ raw: String, to id: UUID) -> RoleAssignment` where `enum RoleAssignment: Equatable { case assigned(role: String, movedFrom: UUID?); case refused(String) }`
  - `AppState.clearRole(for id: UUID) -> String?` (the released role, or nil)
  - `ArchiveRefusal.holdsRole(String)`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Session roles", .timeLimit(.minutes(1)))
struct SessionRolesTests {
    private func app(_ ids: [UUID]) -> AppState {
        let app = AppState(); app.conversations.removeAll()
        for id in ids { app.createNewConversation(id: id) }
        return app
    }

    @Test("role names are lowercased and restricted; reserved names refused")
    func names() {
        #expect(SessionRoles.normalizedName("PR-Minder") == "pr-minder")
        #expect(SessionRoles.normalizedName("  planner ") == "planner")
        #expect(SessionRoles.normalizedName("pr minder") == nil)
        #expect(SessionRoles.normalizedName("-x") == nil)
        #expect(SessionRoles.normalizedName(String(repeating: "a", count: 33)) == nil)
        #expect(SessionRoles.normalizedName("iris") == nil)
        #expect(SessionRoles.normalizedName("clear") == nil)
    }

    @Test("assigning a held role moves it, clears the old holder's skills, and tells it")
    func moveRole() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        #expect(app.assignRole("planner", to: a) == .assigned(role: "planner", movedFrom: nil))
        app.setSessionCard(for: a, SessionCard(name: "p", description: "d",
                                               skills: [AgentSkill(id: "s", name: "S", description: "")]))
        #expect(app.assignRole("planner", to: b) == .assigned(role: "planner", movedFrom: a))
        let old = app.conversations.first { $0.id == a }!
        #expect(old.role == nil)
        #expect(old.sessionCard?.skills.isEmpty == true)
        #expect(app.conversations.first { $0.id == b }?.role == "planner")
        #expect(app.takePendingEventLines(for: a).contains { $0.contains("planner") && $0.contains("no longer") })
    }

    @Test("the pinned Iris cannot hold a role")
    func pinnedRefused() {
        let a = UUID()
        let app = app([a])
        app.conversations[0].isPinned = true
        guard case .refused = app.assignRole("planner", to: a) else { Issue.record("expected refusal"); return }
        #expect(app.conversations[0].role == nil)
    }

    @Test("archiving a role-holder is refused until the role is released")
    func archiveRefused() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        _ = app.assignRole("overseer", to: a)
        #expect(app.archiveConversation(a) == .holdsRole("overseer"))
        #expect(app.clearRole(for: a) == "overseer")
        #expect(app.archiveConversation(a) == nil)
    }

    @Test("load-time normalization keeps one holder per role, the most recently updated")
    func normalize() {
        var older = Conversation(title: "old"); older.role = "planner"; older.updatedAt = Date(timeIntervalSince1970: 1)
        var newer = Conversation(title: "new"); newer.role = "planner"; newer.updatedAt = Date(timeIntervalSince1970: 2)
        var archived = Conversation(title: "arch"); archived.role = "bug-minder"; archived.isArchived = true
        var pinned = Conversation(title: "Iris"); pinned.role = "x"; pinned.isPinned = true
        var all = [older, newer, archived, pinned]
        SessionRoles.normalize(&all)
        #expect(all[0].role == nil && all[1].role == "planner")
        #expect(all[2].role == nil && all[3].role == nil)
    }
}
```

Extend `ConversationStoreTests.roundTrip`: after the `sessionCard` line add `c.role = "pr-minder"`, and after the card expectations add:

```swift
        // #469: the role is a stored column, not just a Codable field.
        #expect(back.role == "pr-minder")
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test-filter.sh SessionRolesTests` — compile failure (`SessionRoles`, `role`, `assignRole` undefined).

- [ ] **Step 3: Implement `SessionRoles.swift`**

```swift
import Foundation

/// #469 §4.3: roles are user-assigned standing responsibilities, unique among active sessions.
/// Uniqueness is enforced here and in `AppState`'s mutators, on the MainActor, which is the only
/// writer. Not a store index: each conversation is written in its own transaction, so a move
/// (clear the old holder, set the new one) would fail half-applied under a unique index.
enum SessionRoles {
    static let reserved: Set<String> = ["iris", "clear"]
    static let maxLength = 32

    /// Lowercased, trimmed; `[a-z0-9-]`, starting alphanumeric, at most 32. Nil when invalid or
    /// reserved, so `role:<name>` is always unambiguous to type.
    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...maxLength).contains(name.count), !reserved.contains(name),
              let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { return nil }
        return name
    }

    /// Who holds `role` among sessions that may hold one.
    static func holder(of role: String, in conversations: [Conversation]) -> UUID? {
        conversations.first { $0.role == role && mayHoldRole($0) }?.id
    }

    static func mayHoldRole(_ c: Conversation) -> Bool {
        !c.isArchived && !c.isPinned && c.isUserFacing
    }

    /// Restores the invariant after load: only a session that may hold a role has one, and each
    /// role has at most one holder — the most recently updated keeps it.
    static func normalize(_ conversations: inout [Conversation]) {
        var keeper: [String: Int] = [:]
        for i in conversations.indices {
            guard let role = conversations[i].role else { continue }
            guard mayHoldRole(conversations[i]) else { conversations[i].role = nil; continue }
            if let j = keeper[role] {
                if conversations[i].updatedAt > conversations[j].updatedAt {
                    conversations[j].role = nil; keeper[role] = i
                } else {
                    conversations[i].role = nil
                }
            } else {
                keeper[role] = i
            }
        }
    }
}
```

- [ ] **Step 4: Implement the `Conversation` field**

In `Conversation`, after `sessionCard`:

```swift
    /// #469 §4.3 — the standing role the USER assigned (`/role`). Never set by a tool. Unique
    /// among active sessions; `SessionRoles.normalize` restores that on load.
    var role: String?
```

Add `role` to `CodingKeys`, and in `init(from:)` after the `sessionCard` line:

```swift
        // Invariant 1: absent on every conversation persisted before #469, and absent is no role.
        role = try container.decodeIfPresent(String.self, forKey: .role)
```

- [ ] **Step 5: Implement persistence**

Migration, after `v18_prefix_mismatch_behavior`:

```swift
        // #469. Nullable: NULL reads back as no role. No unique index — see `SessionRoles`.
        m.registerMigration("v19_session_role") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "role", .text)
            }
        }
```

In `upsertMetadata`, add `role = ?` to the `UPDATE` column list (after `prefixMismatchBehavior = ?`) with `c.role` in the arguments before `c.id.uuidString`; add `role` to the `INSERT` column list, one more `?` in `VALUES`, and `c.role` as the last argument.

In `loadAll`, immediately after the `sessionCard` switch:

```swift
                // #469: like the card, an unreadable role degrades to "no role" plus a reported loss.
                switch Self.readTextValue(row, "role") {
                case .null: break
                case .invalid: localSoftLosses.append(("role", "invalid text encoding"))
                case .text(let s): c.role = s
                }
```

In `AppState.sanitizeLoaded`, after `var loaded = durableConversations(decoded)`:

```swift
        SessionRoles.normalize(&loaded)
```

- [ ] **Step 6: Implement the mutators and archive refusal**

Add to `ArchiveRefusal`: `case holdsRole(String)` with reason `"it holds role `\(role)` — release it with /role clear first"`. In `archiveRefusal(for:)`, after the `.goalActive` check: `if let role = conv.role { return .holdsRole(role) }`.

Beside `setSessionCard`:

```swift
    enum RoleAssignment: Equatable {
        case assigned(role: String, movedFrom: UUID?)
        case refused(String)
    }

    /// #469 §4.3. The user's `/role`; no tool reaches this.
    func assignRole(_ raw: String, to id: UUID) -> RoleAssignment {
        guard let role = SessionRoles.normalizedName(raw) else {
            return .refused("Role names are 1–\(SessionRoles.maxLength) characters of a-z, 0-9 and -, not `iris` or `clear`.")
        }
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else {
            return .refused("That conversation no longer exists.")
        }
        guard SessionRoles.mayHoldRole(conversations[idx]) else {
            return .refused(conversations[idx].isPinned ? "Iris holds no factory role." : "Only an active session can hold a role.")
        }
        if conversations[idx].role == role { return .assigned(role: role, movedFrom: nil) }
        let previous = SessionRoles.holder(of: role, in: conversations)
        if let previous, let p = conversations.firstIndex(where: { $0.id == previous }) {
            conversations[p].role = nil
            conversations[p].sessionCard?.skills = []
            markChanged(previous, .metadata)
            let newName = conversations[idx].sessionCard?.name ?? conversations[idx].title
            enqueueEventLine("[Event] Role `\(role)` moved to session \(id.uuidString) (\(IrisEngine.flattenCardField(newName, cap: IrisEngine.cardNameCap))); you no longer hold it, and your skills were cleared.", for: previous)
        }
        conversations[idx].role = role
        markChanged(id, .metadata)
        return .assigned(role: role, movedFrom: previous)
    }

    /// Releases this session's role, returning it; nil when it held none.
    @discardableResult
    func clearRole(for id: UUID) -> String? {
        guard let idx = conversations.firstIndex(where: { $0.id == id }),
              let role = conversations[idx].role else { return nil }
        conversations[idx].role = nil
        conversations[idx].sessionCard?.skills = []
        markChanged(id, .metadata)
        return role
    }
```

- [ ] **Step 7: Run tests**

Run: `scripts/test-filter.sh SessionRolesTests` (5 tests) and `scripts/test-filter.sh ConversationStoreTests`. Both green. Fix any exhaustive-`switch` compile errors over `ArchiveRefusal` elsewhere (the sidebar uses `.reason`; nothing else should need a new case).

- [ ] **Step 8: Commit**

```bash
git add Sources/IrisKit/SessionRoles.swift Sources/IrisKit/AppState.swift Sources/IrisKit/ConversationStore.swift Tests/irisTests/SessionRolesTests.swift Tests/irisTests/ConversationStoreTests.swift
git commit -m "feat(sessions): user-assigned unique roles, persisted and normalized on load (#469)"
```

---

### Task 3: The `/role` command

**Files:**
- Modify: `Sources/IrisKit/AppState.swift` (the command chain, beside `/archive` around `:2015`)
- Modify: `Sources/IrisKit/SlashCommandItem.swift:23-31`
- Test: `Tests/irisTests/SessionRolesTests.swift` (extend)

**Interfaces:**
- Consumes: `assignRole`, `clearRole` (Task 2).
- Produces: `/role`, `/role <name>`, `/role clear`.

- [ ] **Step 1: Read the entry point**

Slash commands are handled in `AppState.sendMessage(_:attachments:)` (`:1881`), synchronously, on the selected conversation. Tests drive them the way `ArchiveConversationTests` does: set `selectedConversationId`, then call `sendMessage`.

- [ ] **Step 2: Write the failing tests**

```swift
    private func lastSystemLine(_ app: AppState, _ id: UUID) -> String {
        app.conversations.first { $0.id == id }?.messages.last?.content ?? ""
    }

    @Test("/role assigns, reports, and clears")
    func roleCommand() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        app.selectedConversationId = a
        app.sendMessage("/role")
        #expect(lastSystemLine(app, a).contains("No role"))
        app.sendMessage("/role Planner")
        #expect(app.conversations.first { $0.id == a }?.role == "planner")
        #expect(lastSystemLine(app, a).contains("planner"))
        app.selectedConversationId = b
        app.sendMessage("/role planner")
        #expect(lastSystemLine(app, b).contains("moved from"))
        app.sendMessage("/role clear")
        #expect(app.conversations.first { $0.id == b }?.role == nil)
    }

    @Test("/role in Iris refuses")
    func roleInIris() {
        let a = UUID()
        let app = app([a])
        app.conversations[0].isPinned = true
        app.selectedConversationId = a
        app.sendMessage("/role planner")
        #expect(app.conversations[0].role == nil)
        #expect(lastSystemLine(app, a).contains("Iris holds no factory role"))
    }
```

- [ ] **Step 3: Run to verify failure**

Run: `scripts/test-filter.sh SessionRolesTests` — the two new tests fail.

- [ ] **Step 4: Implement**

Beside the `/archive` branch:

```swift
        } else if trimmed == "/role" || trimmed.hasPrefix("/role ") {
            // #469 §4.3: roles are the user's to assign; no tool sets one.
            let arg = trimmed.dropFirst("/role".count).trimmingCharacters(in: .whitespaces)
            if arg.isEmpty {
                let role = conversations.first { $0.id == convId }?.role
                appendMessage(role: .system, content: role.map { "This session holds role `\($0)`." }
                              ?? "No role. Assign one with /role <name>; /role clear releases it.", to: convId)
            } else if arg.lowercased() == "clear" {
                let released = clearRole(for: convId)
                appendMessage(role: .system, content: released.map { "Released role `\($0)`." } ?? "No role to release.", to: convId)
            } else {
                switch assignRole(arg, to: convId) {
                case .assigned(let role, let movedFrom):
                    let from = movedFrom.map { id in
                        " (moved from \(conversations.first { $0.id == id }?.title ?? id.uuidString))"
                    } ?? ""
                    appendMessage(role: .system, content: "Role `\(role)` assigned\(from).", to: convId)
                case .refused(let reason):
                    appendMessage(role: .system, content: reason, to: convId)
                }
            }
            return
```

Add to `SlashCommandItem.all` after `unarchive`:

```swift
        SlashCommandItem(id: "role", command: "/role", usage: "/role [<name>|clear]", description: "Show, assign or release this session's role"),
```

- [ ] **Step 5: Run tests** — `scripts/test-filter.sh SessionRolesTests` (7 tests) green; `scripts/test-filter.sh SlashCommandItemTests` if that suite exists (`ls Tests/irisTests | grep -i slash`).

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/AppState.swift Sources/IrisKit/SlashCommandItem.swift Tests/irisTests/SessionRolesTests.swift
git commit -m "feat(sessions): /role assigns, shows and releases a session's role (#469)"
```

---

### Task 4: `set_session_card` — unique names, lane, skills

**Files:**
- Modify: `Sources/IrisKit/iris.swift` (declaration `:2065-2075`; handler `:3726-3760`; caps near `:910`)
- Modify: `Sources/IrisKit/SessionRoles.swift` (name lookup)
- Test: `Tests/irisTests/SessionCardToolTests.swift` (create)

**Interfaces:**
- Consumes: `SessionCard.lane/skills` (Task 1), `Conversation.role` (Task 2).
- Produces: `SessionRoles.sessions(named: String, in: [Conversation], excluding: UUID?) -> [UUID]` (case-insensitive, active user-facing only); caps `IrisEngine.cardLaneCap = 64`, `skillsMax = 5`, `skillIdCap = 32`, `skillTagsMax = 5`, `skillTagCap = 24`, `skillExamplesMax = 3`, `skillExampleCap = 160`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("set_session_card part 2", .timeLimit(.minutes(1)))
struct SessionCardToolTests {
    private func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    private func run(_ args: [String: JSONValue], on app: AppState, as id: UUID) async -> String {
        let call = FunctionCall(name: "set_session_card", args: args, id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResultText(app, conversationId: id)
    }

    private func skill(_ id: String) -> JSONValue {
        .object(["id": .string(id), "name": .string(id), "description": .string("d"),
                 "tags": .array([.string("t")]), "examples": .array([.string("e")])])
    }

    @Test("a name another active session holds is refused, case-insensitively, listing taken names")
    func nameCollision() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a); app.createNewConversation(id: b)
        app.setSessionCard(for: b, SessionCard(name: "Swift-Worker", description: "x"))
        let out = await run(["name": .string("swift-worker"), "description": .string("y")], on: app, as: a)
        #expect(out.contains("taken") && out.contains("Swift-Worker"))
        #expect(app.conversations.first { $0.id == a }?.sessionCard == nil)
    }

    @Test("an archived session's name is free")
    func archivedNameFree() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID(), c = UUID()
        for id in [a, b, c] { app.createNewConversation(id: id) }
        app.setSessionCard(for: b, SessionCard(name: "w", description: "x"))
        _ = app.archiveConversation(b)
        _ = await run(["name": .string("w"), "description": .string("y")], on: app, as: a)
        #expect(app.conversations.first { $0.id == a }?.sessionCard?.name == "w")
    }

    @Test("skills are refused without a role")
    func skillsNeedRole() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(); app.createNewConversation(id: a); app.createNewConversation(id: UUID())
        let out = await run(["name": .string("n"), "description": .string("d"), "skills": .array([skill("s")])], on: app, as: a)
        #expect(out.contains("role"))
        #expect(app.conversations.first { $0.id == a }?.sessionCard == nil)
    }

    @Test("a role-holder's skills are stored, bounded, and kept when a later call omits them")
    func skillsKept() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(); app.createNewConversation(id: a); app.createNewConversation(id: UUID())
        _ = app.assignRole("pr-minder", to: a)
        let six = (1...6).map { skill("s\($0)") }
        _ = await run(["name": .string("n"), "description": .string("d"), "lane": .string("github"),
                       "skills": .array(six)], on: app, as: a)
        #expect(app.conversations.first { $0.id == a }?.sessionCard?.skills.count == IrisEngine.skillsMax)
        _ = await run(["name": .string("n"), "description": .string("new")], on: app, as: a)
        let card = app.conversations.first { $0.id == a }?.sessionCard
        #expect(card?.description == "new")
        #expect(card?.skills.count == IrisEngine.skillsMax)
        #expect(card?.lane == "github")
    }

    @Test("an empty skills list or empty lane clears them")
    func emptyClears() async {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(); app.createNewConversation(id: a); app.createNewConversation(id: UUID())
        _ = app.assignRole("pr-minder", to: a)
        _ = await run(["name": .string("n"), "description": .string("d"), "lane": .string("x"), "skills": .array([skill("s")])], on: app, as: a)
        _ = await run(["name": .string("n"), "description": .string("d"), "lane": .string(""), "skills": .array([])], on: app, as: a)
        let card = app.conversations.first { $0.id == a }?.sessionCard
        #expect(card?.lane == nil && card?.skills.isEmpty == true)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `scripts/test-filter.sh SessionCardToolTests`: the collision, skills and lane tests fail.

- [ ] **Step 3: Implement the name lookup**

In `SessionRoles`:

```swift
    /// #469 §4.2: names are identifiers among active sessions, compared case-insensitively.
    static func sessions(named name: String, in conversations: [Conversation], excluding: UUID?) -> [UUID] {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return conversations.filter {
            $0.id != excluding && !$0.isArchived && $0.isUserFacing
                && $0.sessionCard?.name.trimmingCharacters(in: .whitespaces).lowercased() == key
        }.map(\.id)
    }
```

- [ ] **Step 4: Implement the declaration**

Replace the `set_session_card` declaration's description and parameters:

```swift
            toolsList.append(FunctionDeclaration(
                name: "set_session_card",
                description: "Describe this session to its peers: a short stable name, unique among active sessions, and what you are working on right now. Update it when the work changes. A worker may add its topical lane. A session holding a role (assigned by the user) may advertise skills: what it will do on request, with example requests. Omitted lane or skills keep their current values; an empty one clears it. Replies with what peers now see.",
                parameters: Schema(type: "OBJECT", properties: [
                    "name": Schema(type: "STRING", description: "Short handle, 1-3 words, unique among active sessions. Truncated past \(Self.cardNameCap) characters."),
                    "description": Schema(type: "STRING", description: "One line: what this session is doing now. Truncated past \(Self.cardDescriptionCap) characters."),
                    "lane": Schema(type: "STRING", description: "Optional topical lane, e.g. \"swift UI\". Truncated past \(Self.cardLaneCap) characters."),
                    "skills": Schema(type: "ARRAY", description: "Role-holders only. At most \(Self.skillsMax).", items: Schema(type: "OBJECT", properties: [
                        "id": Schema(type: "STRING", description: "Short kebab-case id."),
                        "name": Schema(type: "STRING", description: "Human-readable name."),
                        "description": Schema(type: "STRING", description: "What it does."),
                        "tags": Schema(type: "ARRAY", description: "Keywords.", items: Schema(type: "STRING")),
                        "examples": Schema(type: "ARRAY", description: "Example requests, at most \(Self.skillExamplesMax).", items: Schema(type: "STRING"))
                    ], required: ["id", "name", "description"]))
                ], required: ["name", "description"])
            ))
```

Add the caps beside `cardNameCap`:

```swift
    nonisolated static let cardLaneCap = 64
    nonisolated static let skillsMax = 5
    nonisolated static let skillIdCap = 32
    nonisolated static let skillTagsMax = 5
    nonisolated static let skillTagCap = 24
    nonisolated static let skillExamplesMax = 3
    nonisolated static let skillExampleCap = 160
```

- [ ] **Step 5: Implement the handler**

In the `set_session_card` branch, after the empty-name guard and before `boundedName` is stored, replace the store-and-echo section with:

```swift
            let boundedName = Self.capCardField(name, cap: Self.cardNameCap)
            let boundedDescription = Self.capCardField(description, cap: Self.cardDescriptionCap)
            let (existing, role, taken) = await MainActor.run { () -> (SessionCard?, String?, [String]) in
                guard let s = localState else { return (nil, nil, []) }
                let me = s.conversations.first { $0.id == conversationId }
                let clash = SessionRoles.sessions(named: boundedName, in: s.conversations, excluding: conversationId)
                let names = clash.isEmpty ? [] : s.conversations
                    .filter { $0.id != conversationId && !$0.isArchived && $0.isUserFacing }
                    .compactMap { $0.sessionCard?.name }.prefix(20).map { $0 }
                return (me?.sessionCard, me?.role, names)
            }
            guard taken.isEmpty else {
                result = "Name taken — another active session uses it. Names in use: "
                    + taken.map { "\"\(Self.flattenCardField($0, cap: Self.cardNameCap))\"" }.joined(separator: ", ")
                    + ". Pick a different name."
                return result
            }
            var lane = existing?.lane
            if let raw = functionCall.args["lane"]?.stringValue {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                lane = trimmed.isEmpty ? nil : Self.capCardField(trimmed, cap: Self.cardLaneCap)
            }
            var skills = existing?.skills ?? []
            if case .array(let items)? = functionCall.args["skills"] {
                guard role != nil || items.isEmpty else {
                    result = "Skills are for sessions holding a role, which the user assigns. Not stored; set name, description and lane only."
                    return result
                }
                skills = items.prefix(Self.skillsMax).compactMap(Self.boundedSkill)
            }
            await MainActor.run {
                localState?.setSessionCard(for: conversationId,
                                           SessionCard(name: boundedName, description: boundedDescription,
                                                       lane: lane, skills: skills))
            }
            let truncated = boundedName != name || boundedDescription != description
            var shown = "Peers see: name: \"\(Self.flattenCardField(boundedName, cap: Self.cardNameCap))\" | doing: \"\(Self.flattenCardField(boundedDescription, cap: Self.cardDescriptionCap))\""
            if let lane { shown += " | lane: \"\(Self.flattenCardField(lane, cap: Self.cardLaneCap))\"" }
            if !skills.isEmpty { shown += " | skills: \(skills.map(\.id).joined(separator: ", "))" }
            result = (truncated
                ? "Card updated — over-long fields were truncated to what the peer listing shows. "
                : "Card updated. ") + shown
```

Add the skill parser beside `capCardField`:

```swift
    /// One model-supplied skill object, bounded at the write (#246's rule). Nil when it lacks an
    /// id or name — a skill a peer cannot name is not one it can ask for.
    nonisolated static func boundedSkill(_ value: JSONValue) -> AgentSkill? {
        guard case .object(let o) = value,
              case .string(let id)? = o["id"], case .string(let name)? = o["name"],
              !id.trimmingCharacters(in: .whitespaces).isEmpty,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        func strings(_ key: String, max: Int, cap: Int) -> [String] {
            guard case .array(let a)? = o[key] else { return [] }
            return a.prefix(max).compactMap { if case .string(let s) = $0 { return capCardField(s, cap: cap) }; return nil }
        }
        let description: String
        if case .string(let d)? = o["description"] { description = capCardField(d, cap: cardDescriptionCap) } else { description = "" }
        return AgentSkill(id: capCardField(id, cap: skillIdCap), name: capCardField(name, cap: cardNameCap),
                          description: description,
                          tags: strings("tags", max: skillTagsMax, cap: skillTagCap),
                          examples: strings("examples", max: skillExamplesMax, cap: skillExampleCap))
    }
```

- [ ] **Step 6: Run tests** — `scripts/test-filter.sh SessionCardToolTests` (5 tests) and `scripts/test-filter.sh SessionToolsTests` green. If an existing test asserts the old `set_session_card` description text verbatim, update it to the new text.

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/iris.swift Sources/IrisKit/SessionRoles.swift Tests/irisTests/SessionCardToolTests.swift
git commit -m "feat(sessions): unique card names, worker lanes, and skills for role-holders (#469)"
```

---

### Task 5: Project facts from `.git`

**Files:**
- Create: `Sources/IrisKit/GitHead.swift`
- Test: `Tests/irisTests/GitHeadTests.swift` (create)

**Interfaces:**
- Produces: `struct GitProject: Equatable, Sendable { let repo: String; let branch: String? }`; `enum GitHead { static func read(workspace: String, fileManager: FileManager = .default) -> GitProject? }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import IrisKit

@Suite("GitHead")
struct GitHeadTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("githead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ s: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a plain repo: its directory name and branch")
    func plainRepo() throws {
        let root = try tempDir().appendingPathComponent("iris")
        try write("ref: refs/heads/main\n", root.appendingPathComponent(".git/HEAD"))
        #expect(GitHead.read(workspace: root.path) == GitProject(repo: "iris", branch: "main"))
    }

    @Test("a subdirectory of a repo resolves to the repo")
    func subdirectory() throws {
        let root = try tempDir().appendingPathComponent("iris")
        try write("ref: refs/heads/feat/x\n", root.appendingPathComponent(".git/HEAD"))
        let sub = root.appendingPathComponent("Sources/IrisKit")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(GitHead.read(workspace: sub.path) == GitProject(repo: "iris", branch: "feat/x"))
    }

    @Test("a worktree: the main repo's name and the worktree's branch")
    func worktree() throws {
        let base = try tempDir()
        let main = base.appendingPathComponent("iris")
        let wtGit = main.appendingPathComponent(".git/worktrees/iris-469")
        try write("ref: refs/heads/docs/469\n", wtGit.appendingPathComponent("HEAD"))
        let wt = base.appendingPathComponent("iris-469")
        try write("gitdir: \(wtGit.path)\n", wt.appendingPathComponent(".git"))
        #expect(GitHead.read(workspace: wt.path) == GitProject(repo: "iris", branch: "docs/469"))
    }

    @Test("a detached HEAD shows the short sha")
    func detached() throws {
        let root = try tempDir().appendingPathComponent("r")
        try write("0123456789abcdef0123456789abcdef01234567\n", root.appendingPathComponent(".git/HEAD"))
        #expect(GitHead.read(workspace: root.path) == GitProject(repo: "r", branch: "detached@0123456"))
    }

    @Test("no repo is nil")
    func noRepo() throws {
        #expect(GitHead.read(workspace: try tempDir().path) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `scripts/test-filter.sh GitHeadTests`: compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation

struct GitProject: Equatable, Sendable {
    let repo: String
    let branch: String?
}

/// #469 §4.1: the repo and branch a session's workspace sits in, read from `.git` files at list
/// time. No `git` process: a listing reads one of these per peer, and a spawn per row would cost
/// more than the listing itself.
enum GitHead {
    static let maxDepth = 32

    static func read(workspace: String, fileManager: FileManager = .default) -> GitProject? {
        var dir = URL(fileURLWithPath: workspace).standardizedFileURL
        for _ in 0..<maxDepth {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return GitProject(repo: dir.lastPathComponent, branch: branch(gitDir: dotGit))
                }
                // A worktree: `.git` is a file naming its git dir, `<main>/.git/worktrees/<name>`.
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                let parts = gitDir.pathComponents
                let repo = parts.lastIndex(of: ".git").flatMap { $0 > 0 ? parts[$0 - 1] : nil } ?? dir.lastPathComponent
                return GitProject(repo: repo, branch: branch(gitDir: gitDir))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    private static func branch(gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        if head.count >= 7, head.allSatisfy(\.isHexDigit) { return "detached@" + head.prefix(7) }
        return nil
    }
}
```

- [ ] **Step 4: Run tests** — `scripts/test-filter.sh GitHeadTests` (5 tests) green.

- [ ] **Step 5: Commit**

```bash
git add Sources/IrisKit/GitHead.swift Tests/irisTests/GitHeadTests.swift
git commit -m "feat(sessions): read a workspace's repo and branch from .git without a process (#469)"
```

---

### Task 6: The richer listing and `describe_session`

**Files:**
- Modify: `Sources/IrisKit/SessionDirectory.swift` (`SessionPeer`, `peers(in:…)`)
- Modify: `Sources/IrisKit/iris.swift` (`renderPeerList` `:940`; the session-tool declaration block `:2051`; dispatcher beside `list_sessions` `:3630`; `unattendedNeverDeclared` `:3066`; `mainOnlyDeclared` `:3089`; `inlineDeclaredToolNames` `:4629`)
- Modify: `Sources/IrisKit/StickyTools.swift:10`
- Test: `Tests/irisTests/SessionDirectoryTests.swift` (extend), `Tests/irisTests/SessionAddressingTests.swift` (create; shared with Task 7)

**Interfaces:**
- Consumes: `Conversation.role`, `SessionCard.lane/skills`, `GitHead.read`.
- Produces:
  - `enum SessionKind: String, Sendable { case iris, role, worker }`
  - `SessionPeer` gains `kind: SessionKind`, `role: String?`, `lane: String?`, `skills: [AgentSkill]`, `project: GitProject?` (all with defaults in its init so existing call sites compile).
  - `IrisEngine.renderSessionCard(_ peer: SessionPeer, now: Date) -> String` (full card for `describe_session`).

- [ ] **Step 1: Write the failing tests**

In `SessionDirectoryTests`:

```swift
    @Test("role-holders list first and are exempt from the cap")
    func rolesFirstAndUncapped() {
        var convs: [Conversation] = []
        let me = Conversation(title: "me")
        convs.append(me)
        for i in 0..<(SessionDirectory.listCap + 3) {
            var c = Conversation(title: "w\(i)"); c.updatedAt = Date(timeIntervalSince1970: Double(1000 + i)); convs.append(c)
        }
        var overseer = Conversation(title: "o"); overseer.role = "overseer"; overseer.updatedAt = Date(timeIntervalSince1970: 1)
        convs.append(overseer)
        let (peers, total) = SessionDirectory.peers(in: convs, excluding: me.id, now: Date(), status: { _ in .idle })
        #expect(peers.first?.role == "overseer")
        #expect(peers.first?.kind == .role)
        #expect(peers.count == SessionDirectory.listCap + 1)
        #expect(total == SessionDirectory.listCap + 4)
    }

    @Test("the pinned conversation is kind iris; others are workers")
    func kinds() {
        let me = Conversation(title: "me")
        var iris = Conversation(title: "Iris"); iris.isPinned = true
        let w = Conversation(title: "w")
        let (peers, _) = SessionDirectory.peers(in: [me, iris, w], excluding: me.id, now: Date(), status: { _ in .idle })
        #expect(peers.first { $0.id == iris.id }?.kind == .iris)
        #expect(peers.first { $0.id == w.id }?.kind == .worker)
    }
```

Create `SessionAddressingTests.swift` with the shared harness and the listing tests:

```swift
import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("Session addressing and listing", .timeLimit(.minutes(1)))
struct SessionAddressingTests {
    func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    func runToolCall(_ call: FunctionCall, on app: AppState, as id: UUID) async -> String {
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResultText(app, conversationId: id)
    }

    @Test("list_sessions shows role, lane and skills; describe_session shows examples")
    func listingAndDescribe() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), pr = UUID(), w = UUID()
        for id in [me, pr, w] { app.createNewConversation(id: id) }
        _ = app.assignRole("pr-minder", to: pr)
        app.setSessionCard(for: pr, SessionCard(name: "prm", description: "watching PRs", skills: [
            AgentSkill(id: "review-pr", name: "Review a PR", description: "d", tags: ["github"], examples: ["review PR 12"])]))
        app.setSessionCard(for: w, SessionCard(name: "sw", description: "ui work", lane: "swift UI"))

        let list = await runToolCall(FunctionCall(name: "list_sessions", args: [:], id: "c1"), on: app, as: me)
        #expect(list.contains("role: pr-minder"))
        #expect(list.contains("lane: \"swift UI\""))
        #expect(list.contains("review-pr"))
        #expect(!list.contains("review PR 12"), "examples only in describe_session")

        let card = await runToolCall(FunctionCall(name: "describe_session", args: ["to": .string("role:pr-minder")], id: "c2"), on: app, as: me)
        #expect(card.contains("review PR 12"))
        #expect(card.contains(pr.uuidString))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `scripts/test-filter.sh SessionDirectoryTests` and `scripts/test-filter.sh SessionAddressingTests` fail to compile (`kind`, `role` on `SessionPeer`).

- [ ] **Step 3: Implement `SessionDirectory`**

```swift
/// #469 §4.1: harness-derived, never claimed.
enum SessionKind: String, Sendable { case iris, role, worker }
```

Extend `SessionPeer` with the new stored properties and an explicit init whose new parameters default (`kind: SessionKind = .worker, role: String? = nil, lane: String? = nil, skills: [AgentSkill] = [], project: GitProject? = nil`) so existing initializations still compile.

Replace the body of `peers(in:excluding:now:status:)` after `let active = …`:

```swift
        let all = active.map { c -> SessionPeer in
            let s = status(c)
            let kind: SessionKind = c.isPinned ? .iris : (c.role != nil ? .role : .worker)
            return SessionPeer(id: c.id, name: c.sessionCard?.name, description: c.sessionCard?.description,
                               workspace: c.workspacePath, status: s,
                               lastActive: s == .busy ? now : c.updatedAt,
                               kind: kind, role: c.role, lane: c.sessionCard?.lane,
                               skills: c.role != nil ? (c.sessionCard?.skills ?? []) : [],
                               project: c.workspacePath.flatMap { GitHead.read(workspace: $0) })
        }
        let byActivity: (SessionPeer, SessionPeer) -> Bool = {
            $0.lastActive != $1.lastActive ? $0.lastActive > $1.lastActive : $0.id.uuidString < $1.id.uuidString
        }
        // #469 §4.6: role-holders first and outside the cap — a large worker pool never
        // truncates a role out of view. The rest keep #418's live-ahead-of-idle cut.
        let roles = all.filter { $0.kind == .role }.sorted(by: byActivity)
        let rest = all.filter { $0.kind != .role }
        let kept = (rest.filter { $0.status.isLive }.sorted(by: byActivity)
                    + rest.filter { !$0.status.isLive }.sorted(by: byActivity)).prefix(listCap)
        let ordered = kept.sorted { a, b in
            a.kind != b.kind ? (a.kind == .worker) : byActivity(a, b)   // workers before iris
        }
        return (roles + ordered, active.count)
```

- [ ] **Step 4: Implement rendering**

In `renderPeerList`, change the per-peer line to:

```swift
            var prefix = "session_id: \(peer.id)"
            switch peer.kind {
            case .iris: prefix += " | iris"
            case .role: prefix += " | role: \(peer.role ?? "")"
            case .worker: break
            }
            var line = "\(prefix) | name: \"\(name)\" | status: \(status) | workspace: \"\(workspace)\""
            if let project = peer.project {
                let repo = flattenCardField(project.repo, cap: cardNameCap)
                line += " | repo: \"\(repo)\(project.branch.map { "@" + flattenCardField($0, cap: cardNameCap) } ?? "")\""
            }
            if let lane = peer.lane { line += " | lane: \"\(flattenCardField(lane, cap: cardLaneCap))\"" }
            line += " | doing: \"\(description)\""
            if !peer.skills.isEmpty {
                line += "\n  skills: " + peer.skills.map { skill in
                    let tags = skill.tags.map { flattenCardField($0, cap: skillTagCap) }.joined(separator: ", ")
                    return "\(flattenCardField(skill.id, cap: skillIdCap)) \"\(flattenCardField(skill.name, cap: cardNameCap))\"" + (tags.isEmpty ? "" : " [\(tags)]")
                }.joined(separator: "; ")
            }
            return line
```

Role names need no flattening: `SessionRoles.normalizedName` already restricts them to `[a-z0-9-]`.

Add `renderSessionCard`:

```swift
    /// `describe_session`'s body: one peer in full, examples included (#469 §4.6).
    nonisolated static func renderSessionCard(_ peer: SessionPeer, now: Date = Date()) -> String {
        var out = renderPeerList([peer], total: 1, now: now)
        for skill in peer.skills {
            out += "\n  \(flattenCardField(skill.id, cap: skillIdCap)): \(flattenCardField(skill.description, cap: cardDescriptionCap))"
            for example in skill.examples {
                out += "\n    e.g. \"\(flattenCardField(example, cap: skillExampleCap))\""
            }
        }
        return out
    }
```

- [ ] **Step 5: Declare and dispatch `describe_session`**

In the session-tool declaration block, after `list_sessions`:

```swift
            toolsList.append(FunctionDeclaration(
                name: "describe_session",
                description: "Show one peer's full card: role, name, status, project, lane, and for a role-holder each skill with example requests. Use it before asking a role-holder for something, to phrase the request the way it advertises.",
                parameters: Schema(type: "OBJECT", properties: [
                    "to": Schema(type: "STRING", description: "A session_id, role:<name>, name:<name>, or iris.")
                ], required: ["to"])
            ))
```

Add `"describe_session"` to `unattendedNeverDeclared`, `mainOnlyDeclared`, `StickyTools.eligible` and `inlineDeclaredToolNames`.

Dispatcher, after the `list_sessions` branch (it uses Task 7's resolver; write Task 7's `SessionDirectory.resolve` first if implementing out of order):

```swift
        } else if functionCall.name == "describe_session", let to = functionCall.args["to"]?.stringValue {
            guard principal == .main else { result = "Refused — a subagent is not a session."; return result }
            guard !isUnattended else { result = Self.unattendedSessionListRefusal; return result }
            guard await sessionPeerCount(excluding: conversationId) > 0 else { result = Self.noPeersRefusal; return result }
            let now = Date()
            result = await MainActor.run { () -> String in
                guard let s = localState else { return "No session matches that." }
                switch SessionDirectory.resolve(to, in: s.conversations, excluding: conversationId) {
                case .failure(let reason): return reason.message
                case .success(let id):
                    let (peers, _) = SessionDirectory.peers(in: s.conversations, excluding: conversationId, now: now,
                                                            status: { s.sessionStatus(for: $0) })
                    guard let peer = peers.first(where: { $0.id == id }) else { return "That session is no longer active." }
                    return Self.renderSessionCard(peer, now: now)
                }
            }
```

`peers(...)` caps non-role sessions at 20, so a worker beyond the cap would read as inactive. Build the one peer directly instead if that matters: extract the `Conversation -> SessionPeer` closure in `peers` into `static func peer(for c: Conversation, now: Date, status: SessionStatus) -> SessionPeer` and call it here. Do that extraction in Step 3, and use it in both places.

- [ ] **Step 6: Run tests** — `scripts/test-filter.sh SessionDirectoryTests`, `SessionAddressingTests` (after Task 7's resolver exists), `SessionToolsTests`, `ToolSurfaceTrimTests`. Existing `renderPeerList` expectations that pinned the old line format exactly need updating to the new one; adjust them, and keep every hostile-input assertion (no forged rows, quotes, pipes) intact.

- [ ] **Step 7: Commit**

```bash
git add Sources/IrisKit/SessionDirectory.swift Sources/IrisKit/iris.swift Sources/IrisKit/StickyTools.swift Tests/irisTests/SessionDirectoryTests.swift Tests/irisTests/SessionAddressingTests.swift
git commit -m "feat(sessions): roles first in list_sessions, project and lane, and describe_session (#469)"
```

---

### Task 7: Addressing by `role:`, `name:` and `iris`

**Files:**
- Modify: `Sources/IrisKit/SessionDirectory.swift` (resolver)
- Modify: `Sources/IrisKit/iris.swift` (`send_to_session` declaration `:2058`, handler `:3658-3725`, `framePeerMessage` `:745`, `peerLabel` `:916`, `deliverPeerMessage` `:666`)
- Test: `Tests/irisTests/SessionAddressingTests.swift` (extend)

**Interfaces:**
- Produces:
  - `enum SessionAddressError: Error, Equatable { case notFound, ambiguous(Int), inactive, isSelf, malformed; var message: String }`
  - `SessionDirectory.resolve(_ to: String, in: [Conversation], excluding: UUID) -> Result<UUID, SessionAddressError>`
  - `IrisEngine.framePeerMessage(_ message: String, senderName: String?, senderId: UUID, senderRole: String? = nil) -> String`
  - `deliverPeerMessage(_:from:senderName:senderRole:to:)` (new `senderRole: String? = nil` parameter)

- [ ] **Step 1: Write the failing tests**

```swift
    private func send(to: String, _ message: String = "hello") -> FunctionCall {
        FunctionCall(name: "send_to_session", args: ["to": .string(to), "message": .string(message)], id: "c1")
    }

    @Test("role:, name:, iris and a bare id all resolve, and the result names the target")
    func resolves() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), pr = UUID(), w = UUID(), iris = UUID()
        for id in [me, pr, w, iris] { app.createNewConversation(id: id) }
        if let i = app.conversations.firstIndex(where: { $0.id == iris }) { app.conversations[i].isPinned = true }
        _ = app.assignRole("pr-minder", to: pr)
        app.setSessionCard(for: w, SessionCard(name: "Swift Worker", description: "x"))

        #expect(SessionDirectory.resolve("role:pr-minder", in: app.conversations, excluding: me) == .success(pr))
        #expect(SessionDirectory.resolve("name:swift worker", in: app.conversations, excluding: me) == .success(w))
        #expect(SessionDirectory.resolve("iris", in: app.conversations, excluding: me) == .success(iris))
        #expect(SessionDirectory.resolve(w.uuidString, in: app.conversations, excluding: me) == .success(w))
        #expect(SessionDirectory.resolve("role:nobody", in: app.conversations, excluding: me) == .failure(.notFound))
        #expect(SessionDirectory.resolve("role:iris", in: app.conversations, excluding: me) == .failure(.malformed))
        #expect(SessionDirectory.resolve("swift worker", in: app.conversations, excluding: me) == .failure(.malformed))

        let out = await runToolCall(send(to: "role:pr-minder"), on: app, as: me)
        #expect(out.contains(pr.uuidString.prefix(8)))
    }

    @Test("two sessions sharing a legacy name make name: ambiguous, never a pick")
    func ambiguousName() {
        let me = Conversation(title: "me")
        var a = Conversation(title: "a"); a.sessionCard = SessionCard(name: "dup", description: "")
        var b = Conversation(title: "b"); b.sessionCard = SessionCard(name: "DUP", description: "")
        #expect(SessionDirectory.resolve("name:dup", in: [me, a, b], excluding: me.id) == .failure(.ambiguous(2)))
    }

    @Test("the receiver's framing names the sender's role as user-assigned")
    func roleInFraming() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), w = UUID()
        for id in [me, w] { app.createNewConversation(id: id) }
        _ = app.assignRole("overseer", to: me)
        _ = await runToolCall(send(to: w.uuidString, "please triage"), on: app, as: me)
        let text = app.conversations.first { $0.id == w }?.history.flatMap(\.parts).compactMap(\.text).joined() ?? ""
        #expect(text.contains("role overseer (assigned by the user)"))
    }

    @Test("the legacy session_id argument still works")
    func legacyArgument() async {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), w = UUID()
        for id in [me, w] { app.createNewConversation(id: id) }
        let call = FunctionCall(name: "send_to_session", args: ["session_id": .string(w.uuidString), "message": .string("hi")], id: "c1")
        let out = await runToolCall(call, on: app, as: me)
        #expect(out.contains("Accepted"))
    }
```

- [ ] **Step 2: Run to verify failure** — `scripts/test-filter.sh SessionAddressingTests`: compile failure (`resolve` undefined).

- [ ] **Step 3: Implement the resolver**

```swift
enum SessionAddressError: Error, Equatable {
    case notFound, ambiguous(Int), inactive, isSelf, malformed

    var message: String {
        switch self {
        case .notFound: return "No active session matches that."
        case .ambiguous(let n): return "\(n) sessions share that name; use a session_id from list_sessions."
        case .inactive: return "That session is no longer active."
        case .isSelf: return "That is this session — refused."
        case .malformed: return "Address a session as a session_id, role:<name>, name:<name>, or iris."
        }
    }
}

extension SessionDirectory {
    /// #469 §5.2: resolved at delivery time, so a role that moved since the sender last listed
    /// reaches its current holder.
    static func resolve(_ to: String, in conversations: [Conversation], excluding selfId: UUID) -> Result<UUID, SessionAddressError> {
        let raw = to.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = { (c: Conversation) in !c.isArchived && c.isUserFacing }
        let target: UUID
        if raw.lowercased() == "iris" {
            guard let c = conversations.first(where: { $0.isPinned && active($0) }) else { return .failure(.notFound) }
            target = c.id
        } else if raw.lowercased().hasPrefix("role:") {
            guard let role = SessionRoles.normalizedName(String(raw.dropFirst(5))) else { return .failure(.malformed) }
            guard let id = SessionRoles.holder(of: role, in: conversations) else { return .failure(.notFound) }
            target = id
        } else if raw.lowercased().hasPrefix("name:") {
            let ids = SessionRoles.sessions(named: String(raw.dropFirst(5)), in: conversations, excluding: nil)
            guard !ids.isEmpty else { return .failure(.notFound) }
            guard ids.count == 1 else { return .failure(.ambiguous(ids.count)) }
            target = ids[0]
        } else if let id = UUID(uuidString: raw) {
            guard let c = conversations.first(where: { $0.id == id }) else { return .failure(.notFound) }
            guard active(c), !c.isSubagent else { return .failure(.inactive) }
            target = id
        } else {
            return .failure(.malformed)
        }
        return target == selfId ? .failure(.isSelf) : .success(target)
    }
}
```

- [ ] **Step 4: Implement the handler, declaration and framing**

Declaration: rename the `session_id` property to `to` with description `"A session_id from list_sessions, role:<name> for whoever holds that role now, name:<name>, or iris for the pinned Iris conversation."`; `required: ["to", "message"]`. Add to the tool description: `"Address it by role when you mean whoever holds the role, so a moved role still reaches the right session."`

Handler: change the `if` binding to accept either argument —

```swift
        } else if functionCall.name == "send_to_session",
                  let to = (functionCall.args["to"] ?? functionCall.args["session_id"])?.stringValue,
                  let message = functionCall.args["message"]?.stringValue {
```

— and replace the `UUID(uuidString:)` / self / exists / archived guards (`:3684-3711`) with:

```swift
            let resolved = await MainActor.run { () -> Result<UUID, SessionAddressError> in
                guard let s = localState else { return .failure(.notFound) }
                return SessionDirectory.resolve(to, in: s.conversations, excluding: conversationId)
            }
            let targetId: UUID
            switch resolved {
            case .failure(let e): result = e.message; return result
            case .success(let id): targetId = id
            }
```

Keep the cascade check and delivery as they are. Read the sender's role with its name:

```swift
            let (senderName, senderRole, targetLabel) = await MainActor.run { () -> (String?, String?, String) in
                let me = localState?.conversations.first(where: { $0.id == conversationId })
                let target = localState?.conversations.first(where: { $0.id == targetId })
                let label = (target?.sessionCard?.name).map { "\"\(Self.flattenCardField($0, cap: Self.cardNameCap))\"" } ?? "a session"
                return (me?.sessionCard?.name, me?.role, "\(label) (\(targetId.uuidString.prefix(8)))")
            }
            let queued = await deliverPeerMessage(message, from: conversationId, senderName: senderName,
                                                  senderRole: senderRole, to: targetId)
            result = queued
                ? "Accepted — sent to \(targetLabel); it is busy and will see this at its next turn."
                : "Accepted — sent to \(targetLabel), delivered in the background. You will not be notified when it completes."
```

`deliverPeerMessage` gains `senderRole: String? = nil` and passes it to `framePeerMessage`. `framePeerMessage` and `peerLabel` gain `senderRole: String? = nil`:

```swift
    private nonisolated static func peerLabel(senderName: String?, senderId: UUID, senderRole: String? = nil) -> String {
        // #469 §12: the role is harness-written (user-assigned, charset-restricted), so it is
        // stated plainly; it names the sender and grants nothing.
        let role = senderRole.map { "role \($0) (assigned by the user), " } ?? ""
        guard let senderName else { return role + senderId.uuidString }
        let shortId = senderId.uuidString.prefix(8)
        return role + "\"\(flattenCardField(senderName, cap: cardNameCap))\" (\(shortId))"
    }
```

- [ ] **Step 5: Run tests** — `scripts/test-filter.sh SessionAddressingTests` (all, including Task 6's), `SessionToolsTests`, `PeerDeliveryTests`. Existing tests sending with `session_id` keep passing through the legacy argument; tests asserting `"No session with that id."` change to `SessionAddressError.notFound.message` or `.malformed.message` as appropriate.

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/SessionDirectory.swift Sources/IrisKit/iris.swift Tests/irisTests/SessionAddressingTests.swift Tests/irisTests/SessionToolsTests.swift Tests/irisTests/PeerDeliveryTests.swift
git commit -m "feat(sessions): address peers by role, name or iris, resolved at delivery (#469)"
```

---

### Task 8: Standing context, the no-tax check, and documentation

**Files:**
- Modify: `Sources/IrisKit/iris.swift` (`sessionIdentitySection` `:928`; its call site `:1780`)
- Modify: `README.md` (Sessions bullet `:63`; Session Control `:166`)
- Test: `Tests/irisTests/SessionToolsTests.swift` (extend)

**Interfaces:**
- Consumes: everything above.
- Produces: `sessionIdentitySection(id:title:card:role:)` (new `role: String? = nil`).

- [ ] **Step 1: Write the failing tests** (in `SessionToolsTests`, which has `systemPromptText` and `toolNames`)

```swift
    @Test("a role-holder is told its role every turn, and prompted for skills while it has none")
    func roleLine() async {
        let text = await systemPromptText(sessionPeerCount: 1) { app, id in
            app.createNewConversation(id: UUID())
            _ = app.assignRole("pr-minder", to: id)
        }
        #expect(text.contains("You hold role `pr-minder`"))
        #expect(text.contains("skills"))
    }

    @Test("the second brain pays nothing: a lone, uncarded, roleless session gets no session tools or lines")
    func noTax() async {
        let tools = await toolNames(sessionPeerCount: 0)
        for name in ["list_sessions", "send_to_session", "set_session_card", "describe_session"] {
            #expect(!tools.contains(name))
        }
        let text = await systemPromptText(sessionPeerCount: 0)
        #expect(!text.contains("This Session"))
        #expect(!text.contains("hold role"))
    }
```

- [ ] **Step 2: Run to verify failure** — `scripts/test-filter.sh SessionToolsTests`: `roleLine` fails (`noTax` may already pass; it pins the property).

- [ ] **Step 3: Implement**

```swift
    nonisolated static func sessionIdentitySection(id: UUID, title: String, card: SessionCard?, role: String? = nil) -> TurnContext.Section {
        var body = "You are session \(id.uuidString), titled \(Briefing.quoted(title))."
        if let card {
            body += " Peers see your card as \(Briefing.quoted(card.name)), doing \(Briefing.quoted(card.description, maxBytes: cardDescriptionMaxBytes))."
        } else {
            body += " You have no session card yet, so peers see no name for you."
        }
        if let role {
            body += " You hold role `\(role)`, assigned by the user; peers can reach you as role:\(role)."
            if card?.skills.isEmpty ?? true {
                body += " Advertise what you will do on request with set_session_card's skills."
            }
        }
        return .init(heading: sessionIdentityHeading, body: body)
    }
```

At the call site: the preamble tuple at `iris.swift:1731` reads `ownCard` in one `MainActor.run`. Add `ownRole` (`String?`, from the same conversation's `role`) as a ninth element there, rather than paying a second hop. At `:1780` change the gate to `peerCount > 0 || ownCard != nil || ownRole != nil`, and pass `role: ownRole`.

- [ ] **Step 4: Invariant 9 — search for what this made untrue**

Run each and fix what it finds:

```bash
grep -n "session_id" Sources/IrisKit/iris.swift README.md
grep -n "No session with that id" Sources Tests -r
grep -n -i "no slash commands of their own" README.md
grep -rn -i "send_to_session\|list_sessions\|set_session_card" Sources/IrisKit/assets docs/agency 2>/dev/null
```

README changes:
- **Sessions bullet (`:63`):** add roles (`/role`, unique, user-assigned, peers address `role:<name>`, a role-holder can't be archived until released, its skills); unique names; lanes; `describe_session`; the listing now puts role-holders first and never cuts them; `send_to_session` takes `to` (session id, `role:`, `name:` or `iris`). Keep the existing sentences about status, archiving and the cascade budget, which this PR does not change.
- **Session Control (`:166`):** "Peer session discovery and messaging … have no slash commands of their own" is now false. Replace with: `/role [<name>|clear]` shows, assigns or releases this session's role; the rest is still the agent's tools.

- [ ] **Step 5: Full verification**

```bash
swift test 2>&1 | tail -30
scripts/check-warnings.sh
```

Expected: Swift Testing reports all tests passed with no failures; XCTest reports `Executed N tests, with 0 failures`; `check-warnings.sh` exits 0. Quote both counts in the PR description.

- [ ] **Step 6: Commit**

```bash
git add Sources/IrisKit/iris.swift README.md Tests/irisTests/SessionToolsTests.swift
git commit -m "feat(sessions): role line in turn context; docs for roles and addressing (#469)"
```

---

## After the PR merges

Remove the worktree and branch (AGENTS.md, Worktrees). Then write the PR 2 plan (spec §5, §6) against the merged code.
