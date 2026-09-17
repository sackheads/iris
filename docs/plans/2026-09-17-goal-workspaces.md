# Goal Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A contracted goal runs in its own workspace — proposed by the model in the draft, editable by the user, created at lock — instead of the process cwd (the Iris source repo).

**Architecture:** One pure resolver decides the workspace from (existing binding, proposal, objective). It is side-effect free, so the draft panel can display the result without creating anything. `approveAndLock` re-resolves and creates the directory. Creation is only ever under `~/.iris/workspaces`, which makes a bad proposal structurally unable to conjure a directory anywhere else.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`). No new dependencies.

**Spec:** [docs/specs/2026-09-17-goal-workspaces.md](../specs/2026-09-17-goal-workspaces.md)

## Global Constraints

- **Every new field on a persisted `Codable` type must decode leniently.** `GoalContract` has a custom `init(from:)` using `decodeIfPresent` — add there. A missing key must not throw, or the whole `[Conversation]` decode fails and drops every conversation.
- **Never create a directory outside `~/.iris/workspaces`.** This is the slice's security property (spec §4), not a nicety. The resolver may *name* an existing directory anywhere; it may only ever *create* under that one parent.
- **The resolver is pure.** No `FileManager` calls inside it — existence is injected. A directory must never be created for a draft the user edits away.
- **Tests never touch the real `~/.iris`.** Inject an `IrisPaths(root:)` pointing at a temp directory, per #121's isolation principle. Never `IrisPaths.default` in a test.
- **Swift Testing only** (`@Suite`/`@Test`/`#expect`), never XCTest. **Never mutate `ConfigManager.shared` in a test** (#109).
- **Run `swift test` before every commit** and read the result — never chain it behind a `grep` with `&&`. Baseline on `main`: **430 tests in 96 suites**, parallel, ~0.86s.
- **Conventional commits**, no emoji, co-credit the model in the trailer.

---

### Task 1: The resolver and the slug (pure)

No filesystem, no view, no engine. This task is the whole decision rule.

**Files:**
- Create: `Sources/iris/GoalWorkspace.swift`
- Test: `Tests/irisTests/GoalWorkspaceResolverTests.swift`

**Interfaces:**
- Produces: `enum WorkspaceResolution`, `GoalWorkspace.resolve(proposed:objective:existingBinding:workspacesRoot:directoryExists:)`, `GoalWorkspace.slug(for:)`, `GoalWorkspace.isSensitive(_:homeDirectory:processCwd:)`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/GoalWorkspaceResolverTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// The decision rule for where a contracted goal runs (spec §4). Pure: existence is injected, so
/// none of this touches a real filesystem.
@Suite("Goal workspace resolver (#68)")
struct GoalWorkspaceResolverTests {
    private let root = "/tmp/iris-test-root/workspaces"

    /// Only the paths named here "exist".
    private func exists(_ present: Set<String>) -> (String) -> Bool {
        { present.contains($0) }
    }

    // MARK: Resolution order

    @Test("an existing binding is kept — the slice never second-guesses set_workspace")
    func existingBindingWins() {
        let r = GoalWorkspace.resolve(proposed: "/somewhere/else", objective: "ship it",
                                      existingBinding: "/already/bound", workspacesRoot: root,
                                      directoryExists: exists(["/somewhere/else", "/already/bound"]))
        #expect(r == .keptExisting("/already/bound"))
    }

    @Test("a proposal that exists is bound as-is")
    func existingProposalIsBound() {
        let r = GoalWorkspace.resolve(proposed: "/src/foo", objective: "fix the parser",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists(["/src/foo"]))
        #expect(r == .existing("/src/foo"))
    }

    @Test("a proposal that does not exist falls back to a fresh workspace, not an error")
    func missingProposalFallsBack() {
        let r = GoalWorkspace.resolve(proposed: "/src/nope", objective: "fix the parser",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/fix-the-parser"))
    }

    @Test("no proposal at all yields a fresh workspace named from the objective")
    func noProposalCreates() {
        let r = GoalWorkspace.resolve(proposed: nil, objective: "Write a hangman game",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/write-a-hangman-game"))
    }

    @Test("a proposal naming a FILE is treated as non-existent")
    func fileProposalFallsBack() {
        // `directoryExists` answers for directories only; a file path answers false.
        let r = GoalWorkspace.resolve(proposed: "/src/foo.txt", objective: "ship",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/ship"))
    }

    @Test("a tilde in the proposal is expanded before the existence check")
    func tildeIsExpanded() {
        let home = NSHomeDirectory()
        let r = GoalWorkspace.resolve(proposed: "~/src/foo", objective: "ship",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists(["\(home)/src/foo"]))
        #expect(r == .existing("\(home)/src/foo"))
    }

    @Test("a blank proposal is treated as no proposal")
    func blankProposalIsNoProposal() {
        let r = GoalWorkspace.resolve(proposed: "   ", objective: "ship",
                                      existingBinding: nil, workspacesRoot: root,
                                      directoryExists: exists([]))
        #expect(r == .created("\(root)/ship"))
    }

    // MARK: Collisions

    @Test("a name already in use gets a numeric suffix — goals never share a home")
    func collisionsGetSuffixes() {
        let taken = exists(["\(root)/ship", "\(root)/ship-2"])
        let r = GoalWorkspace.resolve(proposed: nil, objective: "ship", existingBinding: nil,
                                      workspacesRoot: root, directoryExists: taken)
        #expect(r == .created("\(root)/ship-3"))
    }

    // MARK: Slug

    @Test("slug lowercases, collapses punctuation, and trims separators")
    func slugNormalizes() {
        #expect(GoalWorkspace.slug(for: "Write a Hangman Game!") == "write-a-hangman-game")
        #expect(GoalWorkspace.slug(for: "  fix:  the //parser//  ") == "fix-the-parser")
    }

    @Test("slug truncates long objectives without a trailing separator")
    func slugTruncates() {
        let s = GoalWorkspace.slug(for: String(repeating: "abcde ", count: 40))
        #expect(s.count <= 40)
        #expect(!s.hasSuffix("-"))
    }

    @Test("an objective with no usable characters yields 'goal'")
    func slugFallsBack() {
        #expect(GoalWorkspace.slug(for: "🎉🎉🎉") == "goal")
        #expect(GoalWorkspace.slug(for: "") == "goal")
    }

    // MARK: Sensitive paths

    @Test("the Iris tree, home, and dotfile directories are flagged as sensitive")
    func sensitivePathsAreFlagged() {
        let home = "/Users/someone"
        let cwd = "/Users/someone/src/iris"
        #expect(GoalWorkspace.isSensitive(cwd, homeDirectory: home, processCwd: cwd))
        #expect(GoalWorkspace.isSensitive(home, homeDirectory: home, processCwd: cwd))
        #expect(GoalWorkspace.isSensitive("\(home)/.ssh", homeDirectory: home, processCwd: cwd))
    }

    @Test("an ordinary project directory is not flagged")
    func ordinaryPathIsNotFlagged() {
        let home = "/Users/someone"
        #expect(!GoalWorkspace.isSensitive("\(home)/src/myproject", homeDirectory: home,
                                           processCwd: "\(home)/src/iris"))
        #expect(!GoalWorkspace.isSensitive("\(home)/.iris/workspaces/ship", homeDirectory: home,
                                           processCwd: "\(home)/src/iris"))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter GoalWorkspaceResolverTests`
Expected: compile failure — `cannot find 'GoalWorkspace' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/iris/GoalWorkspace.swift`:

```swift
import Foundation

/// Where a contracted goal runs (#68).
enum WorkspaceResolution: Equatable {
    case existing(String)      // a directory that is already there
    case created(String)       // a fresh one to be made under ~/.iris/workspaces
    case keptExisting(String)  // the conversation was already bound; nothing changes
}

/// The decision rule for a goal's workspace, and the naming around it.
///
/// Everything here is pure — directory existence is injected — so the draft panel can display a
/// resolution without touching the filesystem. `.created` NAMES a path; it does not make one.
/// Creation happens once, at lock (spec §4.1).
enum GoalWorkspace {
    /// Resolve in order: an existing binding wins; then a proposal that exists; otherwise a fresh
    /// workspace under `workspacesRoot`.
    ///
    /// A proposal that does not exist is deliberately NOT an error — it falls back, and the panel
    /// shows the resolved path before the user approves, so the fallback is visible rather than
    /// silent. Creation is confined to `workspacesRoot` so a bad proposal can at worst name a
    /// directory the user already has; it can never cause one to appear somewhere new (spec §4).
    static func resolve(proposed: String?, objective: String, existingBinding: String?,
                        workspacesRoot: String,
                        directoryExists: (String) -> Bool) -> WorkspaceResolution {
        if let existingBinding, !existingBinding.isEmpty {
            return .keptExisting(existingBinding)
        }
        if let proposed, !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (proposed.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .expandingTildeInPath
            if directoryExists(expanded) { return .existing(expanded) }
        }
        let base = slug(for: objective)
        var candidate = "\(workspacesRoot)/\(base)"
        var n = 2
        while directoryExists(candidate) {
            candidate = "\(workspacesRoot)/\(base)-\(n)"
            n += 1
        }
        return .created(candidate)
    }

    /// A filesystem-safe directory name from a goal's objective.
    static func slug(for objective: String) -> String {
        var out = ""
        var lastWasSeparator = true   // suppresses a leading separator
        for ch in objective.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append("-")
                lastWasSeparator = true
            }
            if out.count >= 40 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "goal" : out
    }

    /// True for workspaces worth warning about before the user approves: the Iris source tree
    /// itself (the literal complaint in #68), the home directory, and dotfile directories. This
    /// never blocks — working on Iris is legitimate; doing it silently is the bug (spec §5).
    static func isSensitive(_ path: String, homeDirectory: String, processCwd: String) -> Bool {
        let p = (path as NSString).standardizingPath
        if p == (processCwd as NSString).standardizingPath { return true }
        if p == (homeDirectory as NSString).standardizingPath { return true }
        let name = (p as NSString).lastPathComponent
        return name.hasPrefix(".")
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter GoalWorkspaceResolverTests`
Expected: PASS, 13 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 443 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/iris/GoalWorkspace.swift Tests/irisTests/GoalWorkspaceResolverTests.swift
git commit -m "feat(goal): pure resolver for a contracted goal's workspace

Existence is injected so the draft panel can display a resolution without
creating anything. Creation is confined to one parent, so a bad proposal can at
worst name a directory the user already has.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The contract carries a workspace

**Files:**
- Modify: `Sources/iris/GoalContract.swift` (one stored property, memberwise init, one `decodeIfPresent` line)
- Modify: `Sources/iris/GoalContractParsing.swift` (parse `workspace`)
- Modify: `Sources/iris/iris.swift` (`propose_goal_contract` schema, ~L516)
- Test: `Tests/irisTests/GoalWorkspaceContractTests.swift` (create)

**Interfaces:**
- Produces: `GoalContract.workspace: String?`, parsed from the tool's `workspace` argument

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/GoalWorkspaceContractTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

@Suite("Goal workspace on the contract (#68)")
struct GoalWorkspaceContractTests {
    @Test("a contract round-trips its workspace")
    func roundTrip() throws {
        var c = GoalContract(objective: "ship", criteria: [])
        c.workspace = "/src/foo"
        let back = try JSONDecoder().decode(GoalContract.self, from: JSONEncoder().encode(c))
        #expect(back.workspace == "/src/foo")
    }

    @Test("a pre-#68 contract decodes with workspace nil, not a throw")
    func legacyDecodes() throws {
        // The failure mode this guards: one missing key fails the WHOLE [Conversation] decode.
        let legacy: [String: Any] = [
            "objective": "ship",
            "criteria": [["id": UUID().uuidString, "text": "builds", "kind": "qualitative"]],
            "state": "locked"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let back = try JSONDecoder().decode(GoalContract.self, from: data)
        #expect(back.workspace == nil)
        #expect(back.objective == "ship")
    }

    @Test("a Conversation carrying a pre-#68 contract still decodes")
    func legacyConversationDecodes() throws {
        var conv = Conversation(title: "old")
        conv.goalContract = GoalContract(objective: "ship", criteria: [])
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.goalContract?.workspace == nil)
        #expect(back.title == "old")
    }

    @Test("propose_goal_contract's workspace argument reaches the contract")
    func parsesWorkspace() throws {
        let contract = try #require(GoalContractParsing.contract(from: [
            "objective": .string("fix the parser"),
            "criteria": .array([.object(["text": .string("builds"), "kind": .string("qualitative")])]),
            "workspace": .string("~/src/foo")
        ]))
        #expect(contract.workspace == "~/src/foo")
    }

    @Test("an omitted workspace parses to nil rather than an empty string")
    func absentWorkspaceIsNil() throws {
        let contract = try #require(GoalContractParsing.contract(from: [
            "objective": .string("ship"),
            "criteria": .array([.object(["text": .string("builds"), "kind": .string("qualitative")])])
        ]))
        #expect(contract.workspace == nil)
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter GoalWorkspaceContractTests`
Expected: compile failure — `value of type 'GoalContract' has no member 'workspace'`.

- [ ] **Step 3: Add the field**

In `Sources/iris/GoalContract.swift`, add a stored property after `state`:

```swift
    /// Where this goal runs (#68). Proposed by the model in the draft, editable by the user, and
    /// resolved to an absolute path at lock. Nil on a contract from before #68, and on one whose
    /// conversation was already bound by `set_workspace`.
    var workspace: String?
```

Add it to the memberwise `init` (defaulting to nil) and to the custom `init(from:)`:

```swift
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
```

- [ ] **Step 4: Parse it**

In `Sources/iris/GoalContractParsing.swift`, inside `contract(from:)`, before the `return GoalContract(...)`:

```swift
        // Trimmed, and empty means absent — an empty string would resolve differently from nil.
        let workspace = args["workspace"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
```

and pass `workspace` to the constructed contract. Add the helper at the end of the file if it does not already exist:

```swift
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 5: Offer it on the tool**

In `Sources/iris/iris.swift`, in the `propose_goal_contract` schema's `properties`, add:

```swift
                    "workspace": Schema(type: "STRING", description: "Optional. The directory this goal should run in. If the goal works on existing code, give that directory's path — it must already exist. If the goal creates something new, omit this and Iris will make a dedicated workspace for it. Never propose the Iris source tree unless the goal is about Iris itself."),
```

Leave `required` unchanged — `workspace` is optional.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter GoalWorkspaceContractTests`
Expected: PASS, 5 tests.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 448 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/GoalContract.swift Sources/iris/GoalContractParsing.swift Sources/iris/iris.swift Tests/irisTests/GoalWorkspaceContractTests.swift
git commit -m "feat(goal): contracts carry a proposed workspace

decodeIfPresent-defaulted, so a contract persisted before this decodes with it
nil rather than taking every conversation down with it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Bind and create at lock

**Files:**
- Modify: `Sources/iris/AppState.swift` (`bindGoalWorkspace`)
- Modify: `Sources/iris/GoalContractPanel.swift` (`approveAndLock`, ~L220)
- Test: `Tests/irisTests/GoalWorkspaceBindingTests.swift` (create)

**Interfaces:**
- Consumes: `GoalWorkspace.resolve` (Task 1), `GoalContract.workspace` (Task 2)
- Produces: `AppState.bindGoalWorkspace(for:contract:paths:) -> String?` — returns the bound path, or nil when nothing was bound

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/GoalWorkspaceBindingTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// Binding at lock. Every case runs against a temp IrisPaths root — never the real ~/.iris (#121).
@MainActor
@Suite("Goal workspace binding (#68)")
struct GoalWorkspaceBindingTests {
    private func tempPaths() -> IrisPaths {
        IrisPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-ws-test-\(UUID().uuidString)"))
    }

    @Test("no proposal creates a workspace under the root and binds it")
    func createsAndBinds() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)

        let bound = try #require(app.bindGoalWorkspace(
            for: id, contract: GoalContract(objective: "Write a hangman game", criteria: []),
            paths: paths))

        #expect(bound.hasPrefix(paths.root.appendingPathComponent("workspaces").path))
        #expect(bound.hasSuffix("write-a-hangman-game"))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: bound, isDirectory: &isDir))
        #expect(isDir.boolValue, "the directory must actually exist after binding")
        #expect(app.conversations.first { $0.id == id }?.workspacePath == bound)
    }

    @Test("a proposal naming an existing directory is bound, and nothing is created")
    func bindsExistingWithoutCreating() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let existing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-ws-existing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }

        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        var contract = GoalContract(objective: "fix the parser", criteria: [])
        contract.workspace = existing.path

        let bound = try #require(app.bindGoalWorkspace(for: id, contract: contract, paths: paths))

        #expect(bound == existing.path)
        #expect(!FileManager.default.fileExists(atPath: paths.root.path),
                "binding an existing directory must not create anything under the workspaces root")
    }

    @Test("a conversation that is already bound is left alone")
    func existingBindingIsUntouched() {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.setWorkspace(for: id, path: "/already/bound")

        let bound = app.bindGoalWorkspace(
            for: id, contract: GoalContract(objective: "ship", criteria: []), paths: paths)

        #expect(bound == "/already/bound")
        #expect(app.conversations.first { $0.id == id }?.workspacePath == "/already/bound")
        #expect(!FileManager.default.fileExists(atPath: paths.root.path))
    }

    @Test("two goals with the same objective get different homes")
    func collisionsDoNotShare() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        let first = UUID(), second = UUID()
        app.createNewConversation(id: first)
        app.createNewConversation(id: second)

        let a = try #require(app.bindGoalWorkspace(
            for: first, contract: GoalContract(objective: "ship", criteria: []), paths: paths))
        let b = try #require(app.bindGoalWorkspace(
            for: second, contract: GoalContract(objective: "ship", criteria: []), paths: paths))

        #expect(a != b, "a stale artifact from an earlier goal is exactly what makes a verdict wrong")
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter GoalWorkspaceBindingTests`
Expected: compile failure — `value of type 'AppState' has no member 'bindGoalWorkspace'`.

- [ ] **Step 3: Implement the binding**

In `Sources/iris/AppState.swift`, beside `setWorkspace`:

```swift
    /// Bind a contracted goal's workspace at lock (#68), creating it when it does not exist.
    ///
    /// Returns the bound path, or nil when nothing could be bound — creation failing is not fatal:
    /// the goal proceeds unbound, which is exactly today's behaviour and therefore not worse.
    /// `paths` is injected so tests run against a temp root rather than the real ~/.iris.
    @discardableResult
    func bindGoalWorkspace(for conversationId: UUID, contract: GoalContract,
                           paths: IrisPaths = .default) -> String? {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return nil }
        let fm = FileManager.default
        let workspacesRoot = paths.root.appendingPathComponent("workspaces").path

        let resolution = GoalWorkspace.resolve(
            proposed: contract.workspace,
            objective: contract.objective,
            existingBinding: conversations[idx].workspacePath,
            workspacesRoot: workspacesRoot,
            directoryExists: { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            })

        switch resolution {
        case .keptExisting(let path):
            return path
        case .existing(let path):
            setWorkspace(for: conversationId, path: path)
            return path
        case .created(let path):
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            } catch {
                appendMessage(role: .system,
                              content: "Could not create a workspace at \(path) (\(error.localizedDescription)). The goal will run in the current directory.",
                              to: conversationId)
                return nil
            }
            setWorkspace(for: conversationId, path: path)
            appendMessage(role: .system, content: "Goal workspace: \(path)", to: conversationId)
            return path
        }
    }
```

- [ ] **Step 4: Call it from the lock point**

In `Sources/iris/GoalContractPanel.swift`, in `approveAndLock`, carry the model's proposal onto the edited contract — `workspace: draftedContract.workspace` — and bind **before** setting the contract, so the kickoff turn already has the right directory.

(Task 4 replaces `draftedContract.workspace` with the user-editable `@State` value. Do **not** reach for that state variable here; it does not exist yet and this task must compile on its own.)

```swift
        state.bindGoalWorkspace(for: conversation.id, contract: edited)
        state.setGoalContract(for: conversation.id, edited)
        state.sendGoalKickoff(for: conversation.id)
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter GoalWorkspaceBindingTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 452 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/iris/AppState.swift Sources/iris/GoalContractPanel.swift Tests/irisTests/GoalWorkspaceBindingTests.swift
git commit -m "feat(goal): bind and create a goal's workspace at contract lock

Creation failing is not fatal — the goal runs unbound, which is today's
behaviour and therefore not worse.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Show it in the panels

**Files:**
- Modify: `Sources/iris/GoalContractPanel.swift` (draft editor state + row; locked chip row)
- Test: `Tests/irisTests/GoalWorkspaceWarningTests.swift` (create)

**Interfaces:**
- Consumes: `GoalWorkspace.resolve`, `GoalWorkspace.isSensitive` (Task 1)
- Produces: `GoalWorkspace.warningText(for:homeDirectory:processCwd:) -> String?`

- [ ] **Step 1: Write the failing test**

Create `Tests/irisTests/GoalWorkspaceWarningTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// The warning shown beside the workspace row before the user approves (spec §5). Text lives out
/// of the view so it is testable without a SwiftUI harness.
@Suite("Goal workspace warning (#68)")
struct GoalWorkspaceWarningTests {
    private let home = "/Users/someone"
    private let cwd = "/Users/someone/src/iris"

    @Test("the Iris source tree is called out by name — it is the literal complaint in #68")
    func irisTreeWarns() {
        let text = GoalWorkspace.warningText(for: cwd, homeDirectory: home, processCwd: cwd)
        #expect(text != nil)
        #expect(text?.contains("Iris") == true)
    }

    @Test("the home directory warns")
    func homeWarns() {
        #expect(GoalWorkspace.warningText(for: home, homeDirectory: home, processCwd: cwd) != nil)
    }

    @Test("a dotfile directory warns")
    func dotfileWarns() {
        #expect(GoalWorkspace.warningText(for: "\(home)/.ssh", homeDirectory: home, processCwd: cwd) != nil)
    }

    @Test("an ordinary directory and a fresh iris workspace are quiet")
    func ordinaryIsQuiet() {
        #expect(GoalWorkspace.warningText(for: "\(home)/src/proj", homeDirectory: home, processCwd: cwd) == nil)
        #expect(GoalWorkspace.warningText(for: "\(home)/.iris/workspaces/ship",
                                          homeDirectory: home, processCwd: cwd) == nil)
    }
}
```

Note the last case: `~/.iris/workspaces/ship`'s last component is not a dotfile, so it must stay quiet — otherwise every goal Iris creates would warn about itself.

- [ ] **Step 2: Run and watch it fail**

Run: `swift test --filter GoalWorkspaceWarningTests`
Expected: compile failure — `type 'GoalWorkspace' has no member 'warningText'`.

- [ ] **Step 3: Implement the warning text**

Append to `Sources/iris/GoalWorkspace.swift`:

```swift
extension GoalWorkspace {
    /// A one-line warning for a workspace worth a second look, or nil. Never blocks (spec §5).
    static func warningText(for path: String, homeDirectory: String, processCwd: String) -> String? {
        guard isSensitive(path, homeDirectory: homeDirectory, processCwd: processCwd) else { return nil }
        let p = (path as NSString).standardizingPath
        if p == (processCwd as NSString).standardizingPath {
            return "This is the Iris source tree. The goal's files will land in Iris's own repository, and checks will run against it."
        }
        if p == (homeDirectory as NSString).standardizingPath {
            return "This is your home directory. The goal will be able to read and write anything in it."
        }
        return "This is a hidden configuration directory. Make sure the goal is meant to change it."
    }
}
```

- [ ] **Step 4: Add the draft row**

In `Sources/iris/GoalContractPanel.swift`, add state beside the other draft fields:

```swift
    @State private var workspace: String
```

initialise it in the view's `init` from `draftedContract.workspace ?? ""`, and render a row above the criteria list:

```swift
            VStack(alignment: .leading, spacing: 4) {
                Text("WORKSPACE")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                TextField("A fresh workspace will be created", text: $workspace)
                    .textFieldStyle(.plain)
                    .font(.caption.monospaced())
                    .padding(6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(resolvedWorkspaceDisplay)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let warning = resolvedWorkspaceWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
```

with two computed properties that call the pure resolver — **no filesystem writes, only existence checks**:

```swift
    private var resolvedWorkspacePath: String {
        let fm = FileManager.default
        switch GoalWorkspace.resolve(
            proposed: workspace.isEmpty ? nil : workspace,
            objective: objective,
            existingBinding: conversation.workspacePath,
            workspacesRoot: IrisPaths.default.root.appendingPathComponent("workspaces").path,
            directoryExists: { path in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }) {
        case .existing(let p), .created(let p), .keptExisting(let p): return p
        }
    }

    private var resolvedWorkspaceDisplay: String {
        conversation.workspacePath != nil
            ? "Already bound to this conversation: \(resolvedWorkspacePath)"
            : "Will run in: \(resolvedWorkspacePath)"
    }

    private var resolvedWorkspaceWarning: String? {
        GoalWorkspace.warningText(for: resolvedWorkspacePath,
                                  homeDirectory: NSHomeDirectory(),
                                  processCwd: FileManager.default.currentDirectoryPath)
    }
```

Pass `workspace: workspace.isEmpty ? nil : workspace` into the `GoalContract(...)` built by `approveAndLock`.

- [ ] **Step 5: Show it on the locked chip**

In `LockedContractChip`, render the bound workspace read-only when present, so the user can see mid-run where artifacts are landing:

```swift
                if let ws = conversation.workspacePath {
                    Label(ws, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
```

- [ ] **Step 6: Run the tests**

Run: `swift test --filter GoalWorkspaceWarningTests`
Expected: PASS, 4 tests.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 456 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/iris/GoalWorkspace.swift Sources/iris/GoalContractPanel.swift Tests/irisTests/GoalWorkspaceWarningTests.swift
git commit -m "feat(ui): show and warn about a goal's workspace before it locks

The warning converts an invisible default into a visible choice; it never blocks.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Scope guards and documentation

**Files:**
- Test: `Tests/irisTests/GoalWorkspaceScopeTests.swift` (create)
- Modify: `README.md`, `docs/specs/2026-09-17-goal-workspaces.md`

- [ ] **Step 1: Write the scope guards**

Create `Tests/irisTests/GoalWorkspaceScopeTests.swift`:

```swift
import Testing
import Foundation
@testable import iris

/// #68 binds a workspace for CONTRACTED goals at lock, and nothing else. These are the guards for
/// that claim (spec §2).
@MainActor
@Suite("Goal workspace scope (#68)", .serialized)
struct GoalWorkspaceScopeTests {
    private func tempPaths() -> IrisPaths {
        IrisPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-ws-scope-\(UUID().uuidString)"))
    }

    @Test("a contract-less goal binds nothing")
    func contractlessBindsNothing() {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.setGoal(for: id, goal: "do the thing")

        #expect(app.conversations.first { $0.id == id }?.workspacePath == nil,
                "setGoal must not bind a workspace — only a contract lock does")
    }

    @Test("set_workspace still wins over a contract's proposal")
    func setWorkspaceWins() {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        app.setWorkspace(for: id, path: "/bound/by/the/user")
        var contract = GoalContract(objective: "ship", criteria: [])
        contract.workspace = "/somewhere/else"

        app.bindGoalWorkspace(for: id, contract: contract, paths: paths)

        #expect(app.conversations.first { $0.id == id }?.workspacePath == "/bound/by/the/user")
    }

    @Test("a workspace that cannot be created leaves the goal running, unbound")
    func creationFailureIsNotFatal() throws {
        // Root the paths UNDER a regular file, so createDirectory cannot succeed. A goal that
        // cannot get a workspace must still run — falling back to today's behaviour is not worse
        // than today (spec §7).
        let blocker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-ws-blocker-\(UUID().uuidString)")
        try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let bound = app.bindGoalWorkspace(
            for: id, contract: GoalContract(objective: "ship", criteria: []),
            paths: IrisPaths(root: blocker.appendingPathComponent("under-a-file")))

        #expect(bound == nil)
        #expect(app.conversations.first { $0.id == id }?.workspacePath == nil)
        let said = app.conversations.first { $0.id == id }?.messages
            .contains { $0.content.contains("Could not create a workspace") } ?? false
        #expect(said, "the user must be told, not left guessing why artifacts went to the cwd")
    }

    @Test("nothing is ever created outside the workspaces root")
    func creationIsConfined() throws {
        // The slice's security property: a proposal naming a path that does not exist must fall
        // back, never cause that path to appear.
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let forbidden = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-must-not-exist-\(UUID().uuidString)")
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        var contract = GoalContract(objective: "ship", criteria: [])
        contract.workspace = forbidden.path

        let bound = try #require(app.bindGoalWorkspace(for: id, contract: contract, paths: paths))

        #expect(!FileManager.default.fileExists(atPath: forbidden.path),
                "a proposal must never cause a directory to appear at an arbitrary path")
        #expect(bound.hasPrefix(paths.root.appendingPathComponent("workspaces").path))
    }
}
```

The remaining §9 regression — a subagent still inherits its parent's workspace — is already covered by `SubagentGradingTests."a delegated unit is graded in the parent's workspace, not the process cwd"` (slice B3). Binding happens only in `approveAndLock`, which a subagent never reaches, so there is nothing new to assert; do not duplicate that test.

- [ ] **Step 2: Run them**

Run: `swift test --filter GoalWorkspaceScopeTests`
Expected: PASS, 4 tests. If `creationIsConfined` fails, the resolver is creating outside its one permitted parent — fix the source, never the test.

- [ ] **Step 3: Update the README**

Find the `**Deterministic Done-Gates:**` bullet and add immediately before it:

```markdown
*   **Goal Workspaces:** A goal with a contract gets its own directory instead of running wherever Iris happens to be. Iris proposes one when you start a goal — the project's own path if the goal is about existing code, or a fresh directory under `~/.iris/workspaces/` if it is building something new — and shows it for you to edit before you approve. Artifacts land somewhere you chose, and the independent grader checks the goal's own files rather than whatever was in the current directory.
```

- [ ] **Step 4: Mark the spec as-built**

Change the status line to:

```markdown
* **Status**: Implemented (2026-09-17). The design below is as-built; deviations are noted in §11.
```

Append a §11 recording any deviation found during execution. If there were none, say so explicitly rather than omitting the section.

- [ ] **Step 5: Run the full suite twice**

Run: `swift test` (twice)
Expected: PASS, 460 tests, both runs.

- [ ] **Step 6: Commit**

```bash
git add Tests/irisTests/GoalWorkspaceScopeTests.swift README.md docs/specs/2026-09-17-goal-workspaces.md
git commit -m "test(goal): scope guards for goal workspaces, plus docs

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes for the implementer

**The security property is one line of code and one test.** Creation only ever happens in the `.created` branch, whose path comes from `workspacesRoot`. If you find yourself creating a directory anywhere else — to make a proposal work, to be helpful — stop: that is the property this slice exists to establish, and `creationIsConfined` is its guard.

**The resolver must stay pure.** It takes `directoryExists` as a closure precisely so the draft panel can call it on every keystroke without touching the filesystem beyond a stat. Never move a `FileManager` call inside it.

**Watch the dotfile warning's blast radius.** `isSensitive` flags a path whose last component starts with `.` — so `~/.iris/workspaces/ship` must NOT warn (its last component is `ship`), or every goal Iris creates would warn about itself. Task 4's `ordinaryIsQuiet` covers it.

**Tests never use `IrisPaths.default`.** Every filesystem test injects a temp root and removes it in a `defer`. A test that writes to the real `~/.iris` is the bug #121 just finished removing.
