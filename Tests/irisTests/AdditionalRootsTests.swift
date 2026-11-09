import Foundation
import Testing
@testable import IrisKit

/// #962: a conversation can carry read-write directories beyond its `workspacePath`, the same
/// kind of thing `workspacePath` already is (feeds AGENTS.md pickup and sandbox mounts), not a
/// parallel allow-list and not an auto-approve grant — that's held for #974.
@MainActor
@Suite("Additional roots (#962)")
struct AdditionalRootsTests {
    @Test func addingARootAppendsItsCanonicalForm() {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        app.addAdditionalRoot(for: id, path: "/tmp/../tmp/some-dir")
        #expect(app.conversations.first { $0.id == id }?.additionalRoots == [IrisPaths.canonicalPath("/tmp/some-dir")])
    }

    @Test func addingTheSameRootTwiceDoesNotDuplicate() {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        app.addAdditionalRoot(for: id, path: "/tmp/some-dir")
        app.addAdditionalRoot(for: id, path: "/tmp/some-dir")
        #expect(app.conversations.first { $0.id == id }?.additionalRoots == [IrisPaths.canonicalPath("/tmp/some-dir")])
    }

    @Test func addingTheWorkspaceItselfIsANoOp() {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        app.setWorkspace(for: id, path: "/tmp/ws")
        app.addAdditionalRoot(for: id, path: "/tmp/ws")
        #expect(app.conversations.first { $0.id == id }?.additionalRoots == [])
    }

    @Test func removingARootDropsExactlyIt() {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        app.addAdditionalRoot(for: id, path: "/tmp/a")
        app.addAdditionalRoot(for: id, path: "/tmp/b")
        app.removeAdditionalRoot(for: id, path: IrisPaths.canonicalPath("/tmp/a"))
        #expect(app.conversations.first { $0.id == id }?.additionalRoots == [IrisPaths.canonicalPath("/tmp/b")])
    }

    @Test func survivesAReloadAndANullColumnIsNone() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store)
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == id }?.additionalRoots == [])
        app.addAdditionalRoot(for: id, path: "/tmp/reloaded")
        app.flushSave()
        #expect(try store.loadAll().conversations.first { $0.id == id }?.additionalRoots == [IrisPaths.canonicalPath("/tmp/reloaded")])
        try store.rawWrite("UPDATE conversations SET additionalRoots = NULL WHERE id = ?", arguments: [id.uuidString])
        #expect(try store.loadAll().conversations.first { $0.id == id }?.additionalRoots == [])
        try store.rawWrite("UPDATE conversations SET additionalRoots = 'not json' WHERE id = ?", arguments: [id.uuidString])
        #expect(try store.loadAll().conversations.first { $0.id == id }?.additionalRoots == [],
                "an unreadable list is none, which fails toward asking again")
    }

    // MARK: - #962 review (dev-2): #611's HomeMount guard applies to additionalRoots too

    private let home = NSHomeDirectory()

    @Test("addAdditionalRoot refuses a path HomeMount guards, one per reason class, and does not add it",
          arguments: [
            "", // home itself
            "/.ssh",
            "/.config",
            "/.aws/sub",
          ])
    func addRefusesEachHomeMountReasonClass(_ suffix: String) {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        let path = home + suffix
        let refusal = app.addAdditionalRoot(for: id, path: path)
        #expect(refusal != nil, "expected a refusal for \(path)")
        #expect(refusal?.hasPrefix("Not added:") == true)
        #expect(!(refusal ?? "").contains("Let the Sandbox Write This Folder"),
                "an additional root has no opt-in route, unlike the workspace's own refusal")
        #expect(app.conversations.first { $0.id == id }?.additionalRoots == [])
    }

    @Test("addAdditionalRoot refuses a path containing a colon or a comma, and does not add it")
    func addRefusesUnsafeCharacters() {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        for bad in ["/tmp/x:ro", "/tmp/x,y"] {
            let refusal = app.addAdditionalRoot(for: id, path: bad)
            #expect(refusal?.hasPrefix("Not added:") == true, "expected a refusal for \(bad)")
        }
        #expect(app.conversations.first { $0.id == id }?.additionalRoots == [])
    }

    @Test("a project folder is still added normally — the guard isn't overbroad")
    func addStillAcceptsAnOrdinaryFolder() {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        let refusal = app.addAdditionalRoot(for: id, path: home + "/src/some-project")
        #expect(refusal == nil)
        #expect(app.conversations.first { $0.id == id }?.additionalRoots == [IrisPaths.canonicalPath(home + "/src/some-project")])
    }

    /// #962 review: `addAdditionalRoot` already refuses a guarded path, but a root stored before
    /// that fix (or edited into the store directly) must still be caught at mount time — the
    /// `additionalRoots` array is set directly here, bypassing `addAdditionalRoot` entirely, the
    /// way a stale or hand-edited row would arrive.
    @Test("runCommand refuses a guarded additionalRoot even if it bypassed addAdditionalRoot (stale data)")
    func runCommandCatchesAStaleGuardedRoot() async throws {
        let app = AppState(store: try! ConversationStore.inMemory())
        app.conversations.removeAll()
        let id = app.createNewConversation(select: false)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else {
            Issue.record("conversation not found"); return
        }
        app.conversations[idx].additionalRoots = [home + "/.ssh"]
        var executor = ToolExecutor()
        executor.sandboxSession = { _, _, _, _, _, _ in "Success" }
        let result = await executor.execute(name: "run_command", args: ["command": .string("true")], cwd: "/tmp/ws",
                                             conversationId: id, useSandbox: true,
                                             additionalRoots: app.conversations[idx].additionalRoots)
        #expect(result.hasPrefix("Not run:"), "a guarded additional root must refuse the whole command, like a guarded workspace does")
    }


    /// #962 review: a workspace reached through a symlink must not be mounted twice — once as the
    /// workspace, once as an "additional root" that happens to canonicalize to the same directory.
    @Test("a root that canonicalizes to the symlinked workspace is never double-mounted")
    func canonicalDedupAcrossASymlinkedWorkspace() async throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("iris-962-real-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("iris-962-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: real)
            try? FileManager.default.removeItem(at: link)
        }
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var mounts: [String] = []
            func set(_ m: [String]) { lock.withLock { mounts = m } }
            var value: [String] { lock.withLock { mounts } }
        }
        let captured = Captured()
        var executor = ToolExecutor()
        executor.sandboxSession = { _, _, _, extraMounts, _, _ in captured.set(extraMounts); return "Success" }
        // cwd is the symlink (what a workspace linked through one resolves to); the additional
        // root is the REAL, canonical path — exactly what addAdditionalRoot would have stored
        // had it been added while the workspace happened to already be the real directory.
        _ = await executor.execute(name: "run_command", args: ["command": .string("true")], cwd: link.path,
                                   conversationId: UUID(), useSandbox: true,
                                   additionalRoots: [IrisPaths.canonicalPath(real.path)])
        #expect(captured.value.isEmpty, "the symlinked workspace and its canonical form are one directory, not two mounts")
    }

    /// #962 review: `additionalRoots` is set only by the person in the UI, never by a tool, system
    /// event or job — the same shape `HomeMountTests.humanOnly` pins for `homeWritableOptIn`.
    @Test("only the UI calls addAdditionalRoot/removeAdditionalRoot: no tool, system event or job reaches them")
    func onlyTheUICallsTheSetters() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        var addCallers: Set<String> = [], removeCallers: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                if line.contains("addAdditionalRoot(") && !line.contains("func addAdditionalRoot") { addCallers.insert(file) }
                if line.contains("removeAdditionalRoot(") && !line.contains("func removeAdditionalRoot") { removeCallers.insert(file) }
            }
        }
        #expect(addCallers == ["ChatView.swift"], "\(addCallers)")
        #expect(removeCallers == ["ChatView.swift"], "\(removeCallers)")
    }
}
