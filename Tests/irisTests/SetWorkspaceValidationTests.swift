import Testing
import Foundation
@testable import iris

/// #273. `set_workspace` stored whatever the model sent: no length bound, no shape check, and the
/// value is persisted to `workspacePath`, decoded on every launch, and advertised to peers.
///
/// The bound here is a **refusal**, not the truncation #246 applied to the session card. A
/// truncated card name is still a name; a truncated path is a *different path*, and storing one
/// silently points the workspace somewhere else or nowhere — worse than leaving it unbounded.
@MainActor
@Suite("set_workspace validates the path it is given")
struct SetWorkspaceValidationTests {

    private func toolResultText(_ app: AppState, conversationId: UUID) -> String {
        let history = app.conversations.first { $0.id == conversationId }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.joined(separator: "\n")
    }

    private func setWorkspace(_ path: String, on app: AppState, as id: UUID) async -> String {
        let call = FunctionCall(name: "set_workspace", args: ["path": .string(path)], id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))],
                                   usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                                   usageMetadata: nil)
        let client = FakeLLMClient(responses: [first, final])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], protectionEnabled: false)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResultText(app, conversationId: id)
    }

    private func fresh() -> (AppState, UUID) {
        let app = AppState(); app.conversations.removeAll()
        let id = UUID(); app.createNewConversation(id: id)
        return (app, id)
    }

    @Test("a path longer than the platform maximum is refused, not stored truncated")
    func overLongPathRefused() async {
        let (app, id) = fresh()
        let result = await setWorkspace("/" + String(repeating: "a", count: 2_000), on: app, as: id)
        #expect(result.contains("Refused"))
        #expect(app.conversations.first { $0.id == id }?.workspacePath == nil,
                "a refused path must leave the previous workspace alone, not store a truncation")
    }

    /// The one that matters most. `URL(fileURLWithPath: "src/iris")` resolves against the PROCESS
    /// working directory, which this repo forbids depending on (#242, #160) — so a relative
    /// workspace silently means a different directory depending on how Iris was launched.
    @Test("a relative path is refused rather than resolved against the process working directory")
    func relativePathRefused() async {
        let (app, id) = fresh()
        let result = await setWorkspace("src/iris", on: app, as: id)
        #expect(result.contains("Refused"))
        #expect(app.conversations.first { $0.id == id }?.workspacePath == nil)
    }

    /// Regression guard on the refusal above: `~/…` is not absolute by `hasPrefix("/")`, and
    /// refusing it would break the spelling models reach for most. It must still be accepted.
    @Test("a tilde path is still accepted — the refusal must not catch the common spelling")
    func tildePathAccepted() async {
        let (app, id) = fresh()
        let result = await setWorkspace("~/src", on: app, as: id)
        #expect(!result.contains("Refused"))
        #expect(app.conversations.first { $0.id == id }?.workspacePath != nil)
    }

    @Test("a path containing a NUL is refused — no such path can exist")
    func nulPathRefused() async {
        let (app, id) = fresh()
        let result = await setWorkspace("/tmp/a\u{0}b", on: app, as: id)
        #expect(result.contains("Refused"))
        #expect(app.conversations.first { $0.id == id }?.workspacePath == nil)
    }

    @Test("an absolute path that exists is accepted and stored verbatim")
    func absolutePathAccepted() async {
        let (app, id) = fresh()
        let dir = NSTemporaryDirectory()
        let result = await setWorkspace(dir, on: app, as: id)
        #expect(!result.contains("Refused"))
        #expect(app.conversations.first { $0.id == id }?.workspacePath == dir)
    }

    /// Set, but say so. A model that names a directory it is about to create is plausible, so
    /// refusing would be a behaviour change; reporting "successfully set" for a path that is not
    /// there is simply untrue.
    @Test("a path that does not exist is still set, and the result says it is not there")
    func missingDirectoryReported() async {
        let (app, id) = fresh()
        let result = await setWorkspace("/tmp/iris-273-definitely-not-here", on: app, as: id)
        #expect(!result.contains("Refused"))
        #expect(app.conversations.first { $0.id == id }?.workspacePath == "/tmp/iris-273-definitely-not-here")
        #expect(result.lowercased().contains("does not exist") || result.lowercased().contains("no such"),
                "the model must learn the directory is not there")
    }
}

@Suite("workspaceRefusal in isolation")
struct WorkspaceRefusalUnitTests {
    @Test("the length rule fires on a path longer than PATH_MAX")
    func lengthRule() {
        let long = "/" + String(repeating: "a", count: 2_000)
        #expect(long.count == 2_001)
        #expect(IrisEngine.workspaceRefusal(for: long) != nil)
    }
}

/// The Foundation quirk this validation had to route around, pinned so a future simplification
/// back to `expandingTildeInPath` fails here rather than silently disabling the length rule.
@Suite("expandingTildeInPath truncates at PATH_MAX")
struct TildeExpansionTruncationTests {
    @Test("Foundation truncates an over-long path to exactly PATH_MAX, silently")
    func foundationTruncates() {
        let long = "/" + String(repeating: "a", count: 2_000)
        #expect((long as NSString).expandingTildeInPath.count == IrisEngine.maxWorkspacePathLength)
        #expect(IrisEngine.expandTilde(long).count == 2_001, "ours must not truncate")
    }

    @Test("expandTilde matches Foundation for the shapes that fit")
    func agreesWhenShort() {
        for p in ["~", "~/src/iris", "/abs/path", "relative/path"] {
            #expect(IrisEngine.expandTilde(p) == (p as NSString).expandingTildeInPath, "\(p)")
        }
    }
}
