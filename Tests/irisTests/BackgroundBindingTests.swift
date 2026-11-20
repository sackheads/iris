import Testing
import Foundation
@testable import IrisKit

/// #974 Task 12 (C8): a background conversation carries the binding it was bound to, and a profile
/// that omits a grant key denies that axis. Driven through `engine.processInput` on a hidden
/// background conversation, reading the tool result out of history: a direct `bindingForCall` read
/// would only show the function is wired, not that a real turn is refused (#1217).
@MainActor
@Suite("a background turn keeps its binding (#974 Task 12, C8)", .serialized, .timeLimit(.minutes(2)))
struct BackgroundBindingTests {
    private struct World {
        let root: URL
        let paths: IrisPaths
        let store: AccessProfileStore
    }

    private func world() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-t12-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        return World(root: root, paths: paths, store: AccessProfileStore(paths: paths))
    }

    private func writeProfile(_ w: World, id: String, json: String) throws {
        try json.write(to: w.paths.profilesDir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }

    /// One scripted tool call on a hidden background conversation whose persisted profile id is
    /// `profileId`, on the one `.main` engine: what a job run is. Returns the tool result text.
    private func backgroundResult(tool: String, args: [String: JSONValue], profileId: String?, in w: World) async throws -> String {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id, isBackground: true)
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[idx].accessProfileId = profileId }
        let call = FunctionCall(name: tool, args: args)
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, client: client, retryDelays: [],
                                factStore: try FactStoreManager(inMemory: true), protectionEnabled: false,
                                sessionPeerCount: 0, memory: MemoryManager(paths: w.paths), declareStateGatedTools: true,
                                accessProfileStore: w.store)
        let turn = Task { await engine.processInput("go", source: "job:test", conversationId: id) }
        let deny = Task {
            while !Task.isCancelled {
                if !app.pendingApprovals.isEmpty { app.denyPendingApprovals(for: id); break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        try await value(of: turn)
        deny.cancel()
        let responses = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse } ?? []
        return responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n")
    }

    private static let saveFact: [String: JSONValue] = ["content": .string("the sky is blue"), "category": .string("note")]

    @Test("control: a background turn with no persisted profile is the owner's, so a shared fact is saved")
    func noProfileIsOwner() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let result = try await backgroundResult(tool: "save_fact", args: Self.saveFact, profileId: nil, in: w)
        #expect(!result.contains(MemoryBindingGate.refusal), Comment(rawValue: result))
    }

    @Test("a background turn bound to a profile with no memory-write grant is refused a memory write, not run as owner")
    func nonOwnerProfileRefused() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        try writeProfile(w, id: "reader", json: #"{"memoryRead":2,"memoryWrite":0}"#)
        let result = try await backgroundResult(tool: "save_fact", args: Self.saveFact, profileId: "reader", in: w)
        #expect(result.contains(MemoryBindingGate.refusal), Comment(rawValue: result))
    }

    @Test("an omitted memoryWrite key denies that axis end to end, while a granted one is allowed")
    func omittedKeyDeniesTheAxis() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        // memoryWrite is OMITTED here (tiers are integers: 0 none ... 2 shared ... 4 full); memoryRead is wide open.
        try writeProfile(w, id: "omitted", json: #"{"memoryRead":4}"#)
        try writeProfile(w, id: "granted", json: #"{"memoryRead":4,"memoryWrite":2}"#)
        let omitted = try await backgroundResult(tool: "save_fact", args: Self.saveFact, profileId: "omitted", in: w)
        #expect(omitted.contains(MemoryBindingGate.refusal), Comment(rawValue: omitted))
        let granted = try await backgroundResult(tool: "save_fact", args: Self.saveFact, profileId: "granted", in: w)
        #expect(!granted.contains(MemoryBindingGate.refusal), "the same call with the key granted runs: \(granted)")
    }

    @Test("a persisted profile that no longer exists fails closed: refused, never owner")
    func missingProfileFailsClosed() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        let result = try await backgroundResult(tool: "save_fact", args: Self.saveFact, profileId: "deleted-profile", in: w)
        #expect(result.contains(MemoryBindingGate.refusal), Comment(rawValue: result))
    }

    @Test("the reserved owner id and a traversal id are not a way to the owner binding")
    func reservedIdsFailClosed() async throws {
        let w = try world(); defer { try? FileManager.default.removeItem(at: w.root) }
        // `owner` resolves to the owner for `.main` only by the on-load path, and that IS the owner
        // default; a traversal spelling must not read a file outside `profiles/`.
        try "{\"memoryRead\":4,\"memoryWrite\":4}".write(to: w.root.appendingPathComponent("outside.json"), atomically: true, encoding: .utf8)
        let result = try await backgroundResult(tool: "save_fact", args: Self.saveFact, profileId: "../outside", in: w)
        #expect(result.contains(MemoryBindingGate.refusal), Comment(rawValue: result))
    }
}
