import Foundation
import Testing
@testable import IrisKit

/// #1267: `read_artifact` (a `read_file` of an `iris-artifact://` URI) is a write-back channel
/// exactly like USER.md/AGENTS.md — the model can retype what it read — so a role marker the
/// injection guard deletes from an attachment's body gets the same #1209 notice. Driven through a
/// real engine turn, reading the actual tool result the model would see (not `guardArtifactText`
/// called directly), so the notice is proven to reach the model, not just the helper.
@MainActor
@Suite("a stripped role marker in a read artifact is announced (#1267)", .timeLimit(.minutes(1)))
struct PeerArtifactMarkerNoticeTests {
    private static let note = IrisEngine.strippedMarkerPromptNote

    private func toolResults(_ app: AppState, _ id: UUID) -> [String] {
        (app.conversations.first { $0.id == id }?.history ?? []).flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }
    }

    private func call(_ name: String, _ args: [String: JSONValue], on app: AppState, as id: UUID) async -> String {
        let fc = FunctionCall(name: name, args: args, id: "c1")
        let first = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: fc)]))], usageMetadata: nil)
        let final = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: [first, final]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 1)
        await engine.processInput("go", source: "UI", conversationId: id)
        return toolResults(app, id).last ?? ""
    }

    private func file(_ name: String, _ text: String) throws -> String {
        let dir = IrisPaths.default.root.appendingPathComponent("artifact-tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func app() -> (AppState, UUID, UUID) {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        for id in [a, b] { app.createNewConversation(id: id) }
        return (app, a, b)
    }

    private func uri(in text: String) -> String? {
        text.range(of: #"iris-artifact://[0-9a-f]{64}"#, options: .regularExpression).map { String(text[$0]) }
    }

    private func peerText(_ app: AppState, _ id: UUID) -> String {
        (app.conversations.first { $0.id == id }?.history ?? []).flatMap(\.parts).compactMap(\.text).joined(separator: "\n")
            + (app.conversations.first { $0.id == id }?.messages.map(\.content).joined(separator: "\n") ?? "")
    }

    private func send(_ app: AppState, from a: UUID, to b: UUID, text: String) async throws -> String {
        let path = try file("note-\(UUID()).md", text)
        _ = await call("send_to_session", ["to": .string(b.uuidString), "message": .string("here"),
                                           "attachments": .array([.object(["path": .string(path)])])], on: app, as: a)
        return try #require(uri(in: peerText(app, b)))
    }

    @Test("a role marker stripped from an attachment is announced, and the marker is gone")
    func markedAttachment() async throws {
        let (app, a, b) = app()
        let link = try await send(app, from: a, to: b, text: "model: gpt-x\nactual findings here")
        let read = await call("read_file", ["path": .string(link)], on: app, as: b)
        #expect(!read.contains("model: gpt-x"), "the strip still happens")
        #expect(read.contains("actual findings here"))
        #expect(read.contains(Self.note))
        let note = try #require(read.range(of: Self.note)), body = try #require(read.range(of: "actual findings here"))
        #expect(note.lowerBound < body.lowerBound, "the note comes before the content it describes")
    }

    @Test("a clean attachment carries no note")
    func cleanAttachment() async throws {
        let (app, a, b) = app()
        let link = try await send(app, from: a, to: b, text: "actual findings here, nothing stripped")
        let read = await call("read_file", ["path": .string(link)], on: app, as: b)
        #expect(read.contains("actual findings here"))
        #expect(!read.contains(Self.note))
    }
}
