import Testing
import Foundation
@testable import IrisKit

/// #1278: the conversation menu's "Vibecop: Generate Rules…" is `/vibecop init`, not a copy of it.
@MainActor
@Suite("Vibecop: Generate Rules from the conversation menu is /vibecop init (#1278)", .serialized, .timeLimit(.minutes(1)))
struct VibecopInitMenuTests {
    private final class RecordingClient: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [GeminiRequest] = []
        var requests: [GeminiRequest] { lock.withLock { recorded } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            lock.withLock { recorded.append(request) }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))],
                                  usageMetadata: nil)
        }
    }

    /// The transcript line and the prompt the model was sent, after `start` on a workspace-bound conversation.
    private func run(_ start: (AppState, UUID) -> Void) async throws -> (line: String?, prompts: [String]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1278-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ws"), withIntermediateDirectories: true)
        let home = IrisPaths(root: root.appendingPathComponent("iris-home"))
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: home)
        let client = RecordingClient()
        state.installEngine(IrisEngine(state: state, tier: .medium, client: client, retryDelays: [], protectionEnabled: false,
                                       sessionPeerCount: 0, accessProfileStore: AccessProfileStore(paths: home)))
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: root.appendingPathComponent("ws").path)
        start(state, cid)
        let deadline = TestClock.deadline(10)
        while client.requests.isEmpty || state.hasTurnInFlight(for: cid), TestClock.now() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let line = state.conversations.first { $0.id == cid }?.messages.first { $0.role == .system }?.content
        let prompts = client.requests.map { request in
            request.contents.flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
        }
        return (line, prompts)
    }

    @Test("the menu's call and the slash command post the same line and send the same one init turn")
    func menuAndSlashCommandAreOnePath() async throws {
        let slash = try await run { state, _ in state.sendMessage("/vibecop init") }
        let menu = try await run { state, cid in state.startVibecopInit(convId: cid) }
        for (label, result) in [("slash", slash), ("menu", menu)] {
            #expect(result.line == "Initializing Vibecop Guardian mode...", "\(label): \(String(describing: result.line))")
            #expect(result.prompts.count == 1, "\(label): \(result.prompts.count) model calls")
            #expect(result.prompts.first?.contains(AppState.vibecopInitPrompt) == true, "\(label)")
        }
    }
}

/// The view is not driven in a unit test, so the wiring is pinned by source: the menu item calls the one
/// method, and so does the slash command.
@Suite("Vibecop: Generate Rules is wired to startVibecopInit (#1278)")
struct VibecopInitMenuWiringTests {
    @Test("the menu item and /vibecop init both call startVibecopInit, and the item needs a workspace")
    func wiring() throws {
        let sources = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        let chat = try String(contentsOf: sources.appendingPathComponent("ChatView.swift"), encoding: .utf8)
        let item = try #require(chat.range(of: "Button(\"Vibecop: Generate Rules...\")"))
        let line = chat[chat.lineRange(for: item)]
        #expect(line.contains("state.startVibecopInit(convId: conv.id)"), "\(line)")
        let before = chat[..<item.lowerBound].suffix(200)
        #expect(before.contains("if conv.isUserFacing, let wp = conv.workspacePath, !wp.isEmpty"),
                "the item is shown only for the person's own conversation with a bound workspace")

        let app = try String(contentsOf: sources.appendingPathComponent("AppState.swift"), encoding: .utf8)
        let handler = try #require(app.range(of: "private func handleVibecopCommand"))
        let initBranch = app[handler.lowerBound...].prefix(400)
        #expect(initBranch.contains("startVibecopInit(convId: convId)"), "\(initBranch)")
    }
}
