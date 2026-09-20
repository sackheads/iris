import Testing
import Foundation
@testable import iris

@Suite("SubagentResult")
struct SubagentResultTests {
    private func sample(status: SubagentTerminalStatus = .completed,
                        calledGoalComplete: Bool = true,
                        files: [String] = ["Sources/A.swift", "Sources/B.swift"]) -> SubagentResult {
        SubagentResult(role: "engineer", status: status, calledGoalComplete: calledGoalComplete,
                       summary: "did the thing", filesWritten: files,
                       startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 5))
    }

    @Test("SubagentResult round-trips through Codable")
    func codableRoundTrip() throws {
        let r = sample()
        let back = try JSONDecoder().decode(SubagentResult.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(back.schemaVersion == 1)
    }

    @Test("a completed result renders status, goal_complete note, summary, and files")
    func renderCompleted() {
        let s = sample().renderedForParent()
        #expect(s.contains("status: completed"))
        #expect(s.contains("goal_complete called"))
        #expect(s.contains("did the thing"))
        #expect(s.contains("Files written (2)"))
        #expect(s.contains("Sources/A.swift"))
    }

    @Test("a failed result with no files renders 'failed' and omits the files line")
    func renderFailedNoFiles() {
        let s = sample(status: .failed, calledGoalComplete: false, files: []).renderedForParent()
        #expect(s.contains("status: failed"))
        #expect(s.contains("goal_complete not called"))
        #expect(!s.contains("Files written"))
    }

    @Test("timed-out and cancelled render human-readable status text")
    func renderOtherStatuses() {
        #expect(sample(status: .timedOut, calledGoalComplete: false, files: []).renderedForParent().contains("status: timed out"))
        #expect(sample(status: .cancelled, calledGoalComplete: false, files: []).renderedForParent().contains("status: cancelled"))
    }

    @Test("a Conversation with no subagentResult key decodes to nil (no wipe)")
    func legacyConversationDecodesToNil() throws {
        let conv = Conversation(title: "legacy")
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conv))
        #expect(back.subagentResult == nil)
    }

    // #204: SubagentResult had no hand-written `init(from:)` at all, so every one of its
    // non-Optional fields threw `keyNotFound` if absent -- and that throw is caught at the
    // conversation-row level in ConversationStore.loadAll, taking the whole conversation with it
    // (invariant 1).
    @Test("a SubagentResult JSON object missing every field decodes to safe defaults instead of throwing")
    func missingAllFieldsDefaults() throws {
        let r = try JSONDecoder().decode(SubagentResult.self, from: Data("{}".utf8))
        #expect(r.schemaVersion == 1)
        #expect(r.role == "")
        #expect(r.status == .failed)
        #expect(r.calledGoalComplete == false)
        #expect(r.summary == "")
        #expect(r.filesWritten == [])
        #expect(r.unitContract == nil)
        #expect(r.verdict == nil)
    }

    @Test("a SubagentResult JSON object missing the newest field (schemaVersion) defaults just that field")
    func missingSchemaVersionDefaults() throws {
        let json = """
        {"role":"engineer","status":"completed","calledGoalComplete":true,"summary":"did the thing",
         "filesWritten":["a.swift"],"startedAt":0,"endedAt":5}
        """
        let r = try JSONDecoder().decode(SubagentResult.self, from: Data(json.utf8))
        #expect(r.schemaVersion == 1)
        #expect(r.role == "engineer")
        #expect(r.filesWritten == ["a.swift"])
    }
}
