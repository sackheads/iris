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

        let outcome = try app.deleteWorkspace(entry, trash: moveAside)
        #expect(outcome == .refusedActiveGoal(title: "Working goal"))
        #expect(FileManager.default.fileExists(atPath: workspace.path), "the directory must not be touched on refusal")
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

        let outcome = try app.deleteWorkspace(entry, trash: moveAside)
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

        let outcome = try app.deleteWorkspace(entry, trash: moveAside)
        #expect(outcome == .trashed(workspace))
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }
}
