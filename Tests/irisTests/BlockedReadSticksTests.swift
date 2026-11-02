import Testing
import Foundation
@testable import IrisKit

/// #874: a read the guard withheld whole stays withheld for the conversation, whatever range the
/// model asks for next, and the block counts like a Deny for Vibecop's host APPROVE.
@MainActor
@Suite("A withheld read stays withheld (#874)", .timeLimit(.minutes(1)))
struct BlockedReadSticksTests {
    /// A canary that counts the checks it is asked for.
    final class CountingCanary: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        let verdict: String
        /// A canary that fails (a timeout, a quota limit) rather than answering.
        let fails: Bool
        init(_ verdict: String, fails: Bool = false) { self.verdict = verdict; self.fails = fails }
        var calls: Int { lock.withLock { n } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { n += 1 }
            if fails { struct Unreachable: Error {}; throw Unreachable() }
            return verdict
        }
    }

    private func temp(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-874-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ path: String, _ start: Int? = nil, id: String) -> FunctionCall {
        var args: [String: JSONValue] = ["path": .string(path)]
        if let start { args["start_line"] = .double(Double(start)); args["line_count"] = .double(1) }
        return FunctionCall(name: "read_file", args: args, id: id)
    }

    /// Runs `calls` in one turn under a canary answering `canary`; returns each tool result in order.
    private func run(_ calls: [FunctionCall], canary: CountingCanary) async -> (AppState, UUID, [String]) {
        var script: [[ScriptedStreamClient.Step]] = calls.map { [.event(.functionCall($0)), .event(.done(finishReason: "tool_use"))] }
        script.append([.event(.textDelta("done")), .event(.done(finishReason: nil))])
        script.append([.event(.textDelta("spare")), .event(.done(finishReason: nil))])
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: true, sessionPeerCount: 0)
        app.installEngine(engine)
        await CoreMLEvaluator.$scopedModel.withValue(.init(nil)) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": canary]) {
                app.sendMessage("go")
                for _ in 0..<1000 {
                    let history = app.conversations.first { $0.id == id }?.history ?? []
                    if history.contains(where: { $0.role == "model" && $0.parts.contains { $0.text == "done" } }) { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
        let history = app.conversations.first { $0.id == id }?.history ?? []
        let results = history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }
        return (app, id, results)
    }

    /// The canary is also asked about other text in a turn (the user's message), so a read's checks are
    /// counted against a run of one read.
    private func baseline(_ file: URL, verdict: String) async -> Int {
        let canary = CountingCanary(verdict)
        _ = await run([read(file.path, id: "c0")], canary: canary)
        return canary.calls
    }

    @Test("a blocked read is refused on the next read of the same file, whatever range, with no guard call")
    func rereadIsRefused() async throws {
        let file = try temp("a.txt", "line one\nline two\nline three\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let one = await baseline(file, verdict: "MALICIOUS")
        let canary = CountingCanary("MALICIOUS")
        let (_, _, results) = await run([read(file.path, id: "c1"), read(file.path, 2, id: "c2")], canary: canary)
        #expect(results.count == 2)
        #expect(results.first?.contains("CONTENT BLOCKED BY TIER 3") == true)
        #expect(results.last?.contains(IrisEngine.withheldReadRefusal) == true, "\(results.last ?? "")")
        #expect(canary.calls == one, "the second read made no guard call: \(canary.calls) calls against \(one)")
    }

    @Test("a read through a symlink to the withheld file is refused too")
    func symlinkIsRefused() async throws {
        let file = try temp("b.txt", "secret\n")
        let link = file.deletingLastPathComponent().appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let one = await baseline(file, verdict: "MALICIOUS")
        let canary = CountingCanary("MALICIOUS")
        let (_, _, results) = await run([read(file.path, id: "c1"), read(link.path, id: "c2")], canary: canary)
        #expect(results.last?.contains(IrisEngine.withheldReadRefusal) == true, "\(results.last ?? "")")
        #expect(canary.calls == one)
    }

    @Test("a different file is judged as usual")
    func otherFileIsRead() async throws {
        let a = try temp("c.txt", "one\n"), b = try temp("d.txt", "two\n")
        defer { for u in [a, b] { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) } }
        let one = await baseline(a, verdict: "MALICIOUS")
        let canary = CountingCanary("MALICIOUS")
        let (_, _, results) = await run([read(a.path, id: "c1"), read(b.path, id: "c2")], canary: canary)
        #expect(canary.calls == one + 1, "the other file was judged: \(canary.calls) against \(one)")
        #expect(results.last?.contains(IrisEngine.withheldReadRefusal) == false)
    }

    @Test("a read the guard passed is read again; a file that merely quotes the marker is not a block")
    func passedAndQuotingFilesAreNotRecorded() async throws {
        let quoting = try temp("e.txt", "the guard says [CONTENT BLOCKED BY TIER 3 CANARY GUARD]\n")
        defer { try? FileManager.default.removeItem(at: quoting.deletingLastPathComponent()) }
        let one = await baseline(quoting, verdict: "SAFE")
        let canary = CountingCanary("SAFE")
        let (app, id, results) = await run([read(quoting.path, id: "c1"), read(quoting.path, 1, id: "c2")], canary: canary)
        #expect(canary.calls == one + 1, "the second read was judged, not refused: \(canary.calls) against \(one)")
        #expect(results.last?.contains(IrisEngine.withheldReadRefusal) == false)
        #expect(!app.commandDenied(in: id), "a pass is not a block")
    }

    @Test("a tier that errored and failed closed says nothing about the file: it is read again, and no Deny is counted")
    func erroredTierIsNotRemembered() async throws {
        let file = try temp("g.txt", "plain\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let canary = CountingCanary("SAFE", fails: true)
        let (app, id, results) = await run([read(file.path, id: "c1"), read(file.path, 1, id: "c2")], canary: canary)
        #expect(results.first?.contains("CONTENT BLOCKED BY TIER 3") == true, "the failed check blocked, as ever")
        #expect(results.last?.contains(IrisEngine.withheldReadRefusal) == false, "\(results.last ?? "")")
        #expect(!app.commandDenied(in: id))
    }

    @Test("a block counts like a Deny; a command's blocked output does too")
    func blockCountsAsDeny() async throws {
        let file = try temp("f.txt", "x\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let (app, id, _) = await run([read(file.path, id: "c1")], canary: CountingCanary("MALICIOUS"))
        #expect(app.commandDenied(in: id))
        let (app2, id2, _) = await run([FunctionCall(name: "run_command", args: ["command": .string("echo hello")], id: "c1")],
                                       canary: CountingCanary("MALICIOUS"))
        #expect(app2.commandDenied(in: id2))
        let (app3, id3, _) = await run([read(file.path, id: "c1")], canary: CountingCanary("SAFE"))
        #expect(!app3.commandDenied(in: id3))
    }

    @Test("only read_file and run_command blocks count: a blocked search or MCP result does not")
    func otherToolsDoNotCount() async {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient([]),
                                retryDelays: [], streamResponses: true, protectionEnabled: true, sessionPeerCount: 0)
        for tool in ["search_web", "someserver___fetch", "gmail_list_unread", "read_conversation"] {
            await engine.recordGuardBlock(id, tool: tool, path: "/tmp/x")
            #expect(!app.commandDenied(in: id), "\(tool)")
        }
        await engine.recordGuardBlock(id, tool: "run_command", path: nil)
        #expect(app.commandDenied(in: id))
    }

    @Test("the record is per conversation, and a subagent's roll up to the conversation it works for")
    func perRoot() {
        let app = AppState()
        let parent = UUID(), child = UUID(), other = UUID()
        for u in [parent, child, other] { app.createNewConversation(id: u) }
        app.linkDelegate(child, of: parent)
        app.recordGuardBlock(conversationId: child, realPath: "/tmp/p")
        #expect(app.isWithheldRead(conversationId: parent, realPath: "/tmp/p"))
        #expect(app.isWithheldRead(conversationId: child, realPath: "/tmp/p"))
        #expect(!app.isWithheldRead(conversationId: other, realPath: "/tmp/p"))
        #expect(!app.isWithheldRead(conversationId: parent, realPath: "/tmp/q"))
    }
}
