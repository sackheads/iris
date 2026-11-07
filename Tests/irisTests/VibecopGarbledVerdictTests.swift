import Testing
import Foundation
@testable import IrisKit

/// #914: a garbled verdict word ("APPRORE") used to fail closed to a person prompt on ~4-5% of a
/// local model's replies. The fix asks the engine for the real schema and re-asks once; neither
/// loosens the parse. Every row here ends in the answer production acts on. Engines are
/// task-scoped and every call passes `vibecopEnabled: true` (Invariant 7).
@Suite("Vibecop garbled verdicts (#914)", .timeLimit(.minutes(1)))
struct VibecopGarbledVerdictTests {
    private final class Scripted: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private var schemas: [String?] = []
        init(_ replies: [String]) { self.replies = replies }
        var calls: Int { lock.withLock { schemas.count } }
        var seenSchemas: [String?] { lock.withLock { schemas } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock {
                schemas.append(jsonSchema)
                return replies.isEmpty ? "" : replies.removeFirst()
            }
        }
    }

    private func decide(_ replies: [String]) async throws -> (String?, Int, [String?]) {
        let engine = Scripted(replies)
        let d = try await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
            try await VibecopService.shared.evaluateAction(toolName: "run_command", details: "ls", workspace: nil,
                                                           vibecopEnabled: true)
        }
        return (d?.decision, engine.calls, engine.seenSchemas)
    }

    private static func reply(_ word: String) -> String { #"{"decision":"\#(word)","reason":"x"}"# }

    @Test("a clean verdict is asked once, with the real schema")
    func cleanVerdictOneCall() async throws {
        for word in ["APPROVE", "ESCALATE", "DENY"] {
            let (d, calls, schemas) = try await decide([Self.reply(word)])
            #expect(d == word)
            #expect(calls == 1, "no re-ask for \(word)")
            #expect(schemas == [VibecopService.verdictSchema])
        }
    }

    @Test("the schema is valid JSON and pins decision to the three words")
    func schemaPinsTheEnum() throws {
        let obj = try #require(JSONSerialization.jsonObject(with: Data(VibecopService.verdictSchema.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        let decision = try #require(props["decision"] as? [String: Any])
        #expect(decision["enum"] as? [String] == ["APPROVE", "ESCALATE", "DENY"])
    }

    @Test("a garble then a clean APPROVE is approved: that is the prompt this saves")
    func garbleThenApprove() async throws {
        let (d, calls, _) = try await decide([Self.reply("APPRORE"), Self.reply("APPROVE")])
        #expect(d == "APPROVE")
        #expect(calls == 2)
    }

    // Fail-closed table: whatever the replies, the result is exactly "APPROVE" only when a reply
    // said exactly that, and a second non-verdict is never one.
    @Test("a garble twice stays a non-APPROVE", arguments: [
        ["APPRORE", "APPROBLE"], ["APPROY", "APPROY"], ["APPROVE ", "approve"], ["approve", "Approve"],
        ["APPROVED", "APPROVE."], ["", ""], ["not json", "{}"], ["APPRORE", "not json"],
    ])
    func twiceGarbledNeverApproves(_ pair: [String]) async throws {
        let replies = pair.map { $0.hasPrefix("not") || $0.isEmpty || $0 == "{}" ? $0 : Self.reply($0) }
        let (d, calls, _) = try await decide(replies)
        #expect(d != "APPROVE")
        #expect(calls == 2, "exactly one re-ask")
    }

    @Test("an unparseable reply twice falls to ESCALATE, as before")
    func unparseableTwice() async throws {
        let (d, _, _) = try await decide(["nope", "still nope"])
        #expect(d == "ESCALATE")
    }

    @Test("a real DENY or ESCALATE is never re-asked, so a second draw cannot overturn it")
    func realVerdictsNotReasked() async throws {
        for word in ["DENY", "ESCALATE"] {
            let (d, calls, _) = try await decide([Self.reply(word), Self.reply("APPROVE")])
            #expect(d == word)
            #expect(calls == 1)
        }
    }

    @Test("a garble then a DENY is the DENY")
    func garbleThenDeny() async throws {
        let (d, _, _) = try await decide([Self.reply("DENIY"), Self.reply("DENY")])
        #expect(d == "DENY")
    }
}
