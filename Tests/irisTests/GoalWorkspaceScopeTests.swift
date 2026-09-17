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
