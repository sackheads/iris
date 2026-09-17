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
