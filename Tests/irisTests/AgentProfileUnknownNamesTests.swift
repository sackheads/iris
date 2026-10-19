import Foundation
import Testing
@testable import IrisKit

/// #465's leftover: a `tools:` or `skills:` name that matches nothing is ignored, and said in the
/// picker and when the conversation starts. Files go in a temp home of the test's own.
@MainActor
@Suite("Agent profile unknown names (#465)", .timeLimit(.minutes(1)))
struct AgentProfileUnknownNamesTests {
    private let known = KnownCapabilities(tools: ["read_file", "run_command", "github___list_prs"],
                                          mcpServers: ["github"], skills: ["code-review", "review-folder"])

    private func profile(tools: [String]?, skills: [String]?) -> AgentProfile {
        AgentProfile(name: "p", role: nil, tier: nil, skills: skills, tools: tools, prompt: "x", contentHash: "h")
    }

    @Test("known tools, MCP servers, MCP tools, and skills by name or folder are not listed")
    func knownNamesPass() {
        let p = profile(tools: ["read_file", "mcp:github", "github___list_prs"], skills: ["Code-Review", "review-folder"])
        #expect(known.unknown(in: p).tools.isEmpty && known.unknown(in: p).skills.isEmpty)
        #expect(known.unknownLine(for: p) == nil)
        #expect(known.unknownLine(for: profile(tools: nil, skills: nil)) == nil)
    }

    @Test("a typo or a missing server or skill is listed, in the profile's order")
    func unknownNamesListed() {
        let p = profile(tools: ["read_fil", "mcp:slack", "read_file"], skills: ["code-reveiw"])
        #expect(known.unknown(in: p).tools == ["read_fil", "mcp:slack"])
        #expect(known.unknown(in: p).skills == ["code-reveiw"])
        #expect(known.unknownLine(for: p) == "Names tools Iris doesn't have: read_fil, mcp:slack; skills it can't find: code-reveiw. They are ignored.")
    }

    @Test("a conversation started on a profile with unknown names says so once; with none, says nothing")
    func startNotice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-465u-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentProfileStore(paths: IrisPaths(root: root))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("---\ntools: [read_fil]\n---\nYou review.".utf8).write(to: store.directory.appendingPathComponent("typo.md"))
        try Data("---\ntools: [read_file]\n---\nYou review.".utf8).write(to: store.directory.appendingPathComponent("fine.md"))
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        app.agentProfiles = store
        app.knownCapabilities = known
        let typo = app.createNewConversation(select: false, agentProfile: "typo")
        let fine = app.createNewConversation(select: false, agentProfile: "fine")
        func notes(_ id: UUID) -> [String] {
            app.conversations.first { $0.id == id }?.messages.map(\.content).filter { $0.hasPrefix("[agent profile]") } ?? []
        }
        #expect(notes(typo) == ["[agent profile] `typo` names tools Iris doesn't have: read_fil. They are ignored."])
        #expect(notes(fine).isEmpty)
    }

    @Test("a configured server's tool isn't unknown before it connects; another server's is")
    func configuredServerTools() {
        let p = profile(tools: ["github___open_issue", "slack___post"], skills: nil)
        #expect(known.unknown(in: p).tools == ["slack___post"])
    }

    @Test("before the first refresh, nothing is listed as unknown")
    func noGuessBeforeRefresh() throws {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        #expect(app.knownCapabilities == nil)
    }
}
