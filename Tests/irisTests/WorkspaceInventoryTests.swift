import Testing
import Foundation
@testable import iris

/// #126 — list, mark orphaned, and delete goal workspaces. Every test runs against a temp
/// directory; none may touch `~/.iris` (invariant 7).
@Suite("WorkspaceInventory")
struct WorkspaceInventoryTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-workspace-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("scan lists only immediate subdirectories, ignoring files at the root")
    func scanListsOnlyImmediateSubdirectories() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta"), withIntermediateDirectories: true)
        // Nested directory two levels down must not appear as a top-level entry.
        try fm.createDirectory(at: root.appendingPathComponent("alpha/nested"), withIntermediateDirectories: true)
        // A stray file at the root must be ignored.
        try "not a workspace".write(to: root.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)

        let entries = WorkspaceInventory.scan(root: root, conversations: [])
        #expect(Set(entries.map(\.name)) == ["alpha", "beta"])
    }

    @Test("an owner is matched by a plain, tilde-expanded, and trailing-slash path variant")
    func scanMatchesOwnerAcrossPathVariants() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let plain = root.appendingPathComponent("plain")
        let tildeStyle = root.appendingPathComponent("tilde")
        let trailingSlash = root.appendingPathComponent("trailing")
        for dir in [plain, tildeStyle, trailingSlash] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let home = NSHomeDirectory()
        // Build a tilde-form path only when the temp root really is under the home directory;
        // otherwise fall back to the plain path so the test still exercises the other variants.
        let tildePath: String
        if tildeStyle.path.hasPrefix(home) {
            tildePath = "~" + tildeStyle.path.dropFirst(home.count)
        } else {
            tildePath = tildeStyle.path
        }

        let ownerA = UUID(), ownerB = UUID(), ownerC = UUID()
        let conversations: [(id: UUID, title: String, workspacePath: String?, activeGoal: String?)] = [
            (ownerA, "Plain", plain.path, nil),
            (ownerB, "Tilde", tildePath, nil),
            (ownerC, "Trailing", trailingSlash.path + "/", nil),
        ]

        let entries = WorkspaceInventory.scan(root: root, conversations: conversations)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName["plain"]?.ownerConversationId == ownerA)
        #expect(byName["tilde"]?.ownerConversationId == ownerB)
        #expect(byName["trailing"]?.ownerConversationId == ownerC)
    }

    @Test("a workspace with no owning conversation is an orphan")
    func scanMarksOrphans() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("orphaned"), withIntermediateDirectories: true)

        let entries = WorkspaceInventory.scan(root: root, conversations: [])
        let entry = try #require(entries.first)
        #expect(entry.isOrphan)
        #expect(entry.ownerConversationId == nil)
    }

    @Test("re-scanning after a workspace is adopted removes it from the orphan set")
    func rescanExcludesAdoptedWorkspaceFromOrphans() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("will-be-adopted")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // First scan: no conversation points at it yet, so it's an orphan.
        let initial = WorkspaceInventory.scan(root: root, conversations: [])
        #expect(initial.first(where: { $0.name == "will-be-adopted" })?.isOrphan == true)

        // A conversation adopts the workspace between the first scan and a re-scan (e.g. the user
        // started a new goal and it bound here). `deleteAllOrphans` re-scans live immediately
        // before deleting for exactly this reason (review finding, round 1).
        let ownerId = UUID()
        let liveConversations: [(id: UUID, title: String, workspacePath: String?, activeGoal: String?)] = [
            (ownerId, "Adopter", workspace.path, nil)
        ]
        let rescanned = WorkspaceInventory.scan(root: root, conversations: liveConversations)
        let orphanNames = Set(rescanned.filter(\.isOrphan).map(\.name))
        #expect(!orphanNames.contains("will-be-adopted"))
        #expect(rescanned.first(where: { $0.name == "will-be-adopted" })?.ownerConversationId == ownerId)
    }

    @Test("directorySize sums a small tree")
    func directorySizeSumsTree() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1000).write(to: root.appendingPathComponent("a.txt"))
        try Data(repeating: 0x42, count: 2000).write(to: sub.appendingPathComponent("b.txt"))

        let size = WorkspaceInventory.directorySize(root)
        #expect(size >= 3000, "expected at least the raw byte count of both files (allocation can round up, never down)")
    }
}

/// #126 review finding, round 1: the temp roots used above are never under `$HOME`, so the
/// tilde-path assertion in `scanMatchesOwnerAcrossPathVariants` silently skips itself. Exercise
/// `standardizedPath` directly instead, independent of where the test happens to run.
@Suite("WorkspaceInventory.standardizedPath")
struct StandardizedPathTests {
    @Test("tilde-expands, strips a trailing slash, and resolves .. segments to the same path")
    func normalizesEquivalentVariants() {
        let home = NSHomeDirectory()
        let canonical = "\(home)/.iris/workspaces/foo"
        let tildeForm = "~/.iris/workspaces/foo"
        let trailingSlash = "\(home)/.iris/workspaces/foo/"
        let dotDotForm = "\(home)/.iris/workspaces/bar/../foo"

        let expected = WorkspaceInventory.standardizedPath(canonical)
        #expect(WorkspaceInventory.standardizedPath(tildeForm) == expected)
        #expect(WorkspaceInventory.standardizedPath(trailingSlash) == expected)
        #expect(WorkspaceInventory.standardizedPath(dotDotForm) == expected)
    }
}

@MainActor
@Suite("AppState.deleteWorkspace")
struct AppStateDeleteWorkspaceTests {
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-delete-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeApp() throws -> AppState {
        AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
    }

    /// A `trash:` substitute for sandboxes where the real Trash is unreachable: moves the item
    /// aside instead, which is enough to prove the directory left its original location.
    private func moveAside(_ url: URL) throws {
        let dest = url.deletingLastPathComponent().appendingPathComponent("trashed-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
    }

    @Test("deletion is refused while the owning conversation has an active goal")
    func refusesWhenOwnerHasActiveGoal() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("goal-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let app = try makeApp()
        let convId = UUID()
        app.createNewConversation(id: convId)
        if let idx = app.conversations.firstIndex(where: { $0.id == convId }) {
            app.conversations[idx].title = "Working goal"
            app.conversations[idx].workspacePath = workspace.path
            app.conversations[idx].activeGoal = "ship the feature"
        }

        let entry = WorkspaceEntry(url: workspace, name: workspace.lastPathComponent, modifiedAt: nil,
                                    sizeBytes: nil, ownerConversationId: convId, ownerTitle: "Working goal",
                                    ownerHasActiveGoal: true)

        let outcome = try app.deleteWorkspace(entry, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .refusedActiveGoal(title: "Working goal"))
        #expect(FileManager.default.fileExists(atPath: workspace.path), "the directory must not be touched on refusal")
    }

    @Test("a goal started after the snapshot still blocks deletion (live re-check, not the stale entry)")
    func refusesWhenGoalStartsAfterSnapshot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("became-active")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let app = try makeApp()
        let convId = UUID()
        app.createNewConversation(id: convId)
        if let idx = app.conversations.firstIndex(where: { $0.id == convId }) {
            app.conversations[idx].title = "Newly working"
            app.conversations[idx].workspacePath = workspace.path
        }

        // A snapshot taken while no goal was active yet — exactly what a Settings row rendered
        // before the goal started would carry.
        let staleEntry = WorkspaceEntry(url: workspace, name: workspace.lastPathComponent, modifiedAt: nil,
                                         sizeBytes: nil, ownerConversationId: convId, ownerTitle: "Newly working",
                                         ownerHasActiveGoal: false)

        // A goal starts on that conversation AFTER the snapshot, before the delete call arrives.
        if let idx = app.conversations.firstIndex(where: { $0.id == convId }) {
            app.conversations[idx].activeGoal = "ship it"
        }

        let outcome = try app.deleteWorkspace(staleEntry, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .refusedActiveGoal(title: "Newly working"))
        #expect(FileManager.default.fileExists(atPath: workspace.path), "must not be deleted once the goal is live-active, regardless of the stale snapshot")
    }

    @Test("a workspace adopted after the snapshot still gets owner bookkeeping, even though the snapshot said orphan")
    func adoptedWorkspaceGetsBookkeepingDespiteStaleOrphanSnapshot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("adopted")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let app = try makeApp()
        let convId = UUID()
        app.createNewConversation(id: convId)
        // No workspacePath yet at snapshot time — this entry legitimately scanned as an orphan.
        let orphanSnapshot = WorkspaceEntry(url: workspace, name: workspace.lastPathComponent, modifiedAt: nil,
                                             sizeBytes: nil, ownerConversationId: nil, ownerTitle: nil,
                                             ownerHasActiveGoal: false)

        // A conversation adopts the workspace after the snapshot but before delete is called.
        if let idx = app.conversations.firstIndex(where: { $0.id == convId }) {
            app.conversations[idx].title = "Adopter"
            app.conversations[idx].workspacePath = workspace.path
        }

        let outcome = try app.deleteWorkspace(orphanSnapshot, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .trashed(workspace))
        let owner = app.conversations.first(where: { $0.id == convId })
        #expect(owner?.workspacePath == nil)
        #expect(owner?.messages.last?.content == "Workspace \(workspace.path) was deleted from Settings")
    }

    @Test("a successful delete trashes the directory, clears workspacePath, and appends a system line")
    func successfulDeleteClearsOwner() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("finished-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let app = try makeApp()
        let convId = UUID()
        app.createNewConversation(id: convId)
        if let idx = app.conversations.firstIndex(where: { $0.id == convId }) {
            app.conversations[idx].title = "Done goal"
            app.conversations[idx].workspacePath = workspace.path
            app.conversations[idx].activeGoal = nil
        }

        let entry = WorkspaceEntry(url: workspace, name: workspace.lastPathComponent, modifiedAt: nil,
                                    sizeBytes: nil, ownerConversationId: convId, ownerTitle: "Done goal",
                                    ownerHasActiveGoal: false)

        let outcome = try app.deleteWorkspace(entry, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .trashed(workspace))
        #expect(!FileManager.default.fileExists(atPath: workspace.path), "the directory must be gone from its original location")

        let owner = app.conversations.first(where: { $0.id == convId })
        #expect(owner?.workspacePath == nil)
        #expect(owner?.messages.last?.content == "Workspace \(workspace.path) was deleted from Settings")

        app.flushSave()
        let reloaded = try app.store.loadAll().conversations.first(where: { $0.id == convId })
        #expect(reloaded?.workspacePath == nil, "the cleared workspacePath must survive a flush + reload")
    }

    @Test("an orphaned workspace (no owner) is deleted with no conversation bookkeeping")
    func orphanDeleteSkipsBookkeeping() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("orphan-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let app = try makeApp()
        let entry = WorkspaceEntry(url: workspace, name: workspace.lastPathComponent, modifiedAt: nil,
                                    sizeBytes: nil, ownerConversationId: nil, ownerTitle: nil,
                                    ownerHasActiveGoal: false)

        let outcome = try app.deleteWorkspace(entry, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .trashed(workspace))
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test("deletion is refused when the entry's parent is not the workspaces root")
    func refusesOutsideRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideParent = root.appendingPathComponent("not-the-root")
        try FileManager.default.createDirectory(at: outsideParent, withIntermediateDirectories: true)
        let elsewhere = outsideParent.appendingPathComponent("elsewhere-workspace")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let app = try makeApp()
        let entry = WorkspaceEntry(url: elsewhere, name: elsewhere.lastPathComponent, modifiedAt: nil,
                                    sizeBytes: nil, ownerConversationId: nil, ownerTitle: nil, ownerHasActiveGoal: false)

        // workspacesRoot is `root`, but `elsewhere`'s parent is `outsideParent`, not `root`: a
        // hand-built or stale entry must not be able to trash a path outside the boundary.
        let outcome = try app.deleteWorkspace(entry, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .refusedOutsideRoot)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test("deletion is refused when the entry IS the workspaces root itself, not a child of it")
    func refusesTheRootItself() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp()
        let entry = WorkspaceEntry(url: root, name: root.lastPathComponent, modifiedAt: nil,
                                    sizeBytes: nil, ownerConversationId: nil, ownerTitle: nil, ownerHasActiveGoal: false)

        let outcome = try app.deleteWorkspace(entry, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .refusedOutsideRoot)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a workspace directly under the given root deletes normally")
    func deletesWhenDirectlyUnderRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("directly-under-root")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let app = try makeApp()
        let entry = WorkspaceEntry(url: workspace, name: workspace.lastPathComponent, modifiedAt: nil,
                                    sizeBytes: nil, ownerConversationId: nil, ownerTitle: nil, ownerHasActiveGoal: false)

        let outcome = try app.deleteWorkspace(entry, workspacesRoot: root, trash: moveAside)
        #expect(outcome == .trashed(workspace))
    }
}
