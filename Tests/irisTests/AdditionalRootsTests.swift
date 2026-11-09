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
}
