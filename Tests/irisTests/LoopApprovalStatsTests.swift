import Testing
import Foundation
@testable import IrisKit

/// #1425 step 0: every gated call in a looping conversation leaves one record (tick or not, owner's turn or not, the
/// call's shape, taint, the deciding layer, and the dialog's wait), and the decision itself is unchanged.
@MainActor
@Suite("Loop approval stats record what each call cost a loop (#1425 step 0)", .serialized, .timeLimit(.minutes(1)))
struct LoopApprovalStatsTests {
    private final class Sink {
        var records: [LoopApprovalRecord] = []
    }

    private func setUp() throws -> (AppState, Sink, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1425-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: root.appendingPathComponent("iris-home")))
        let sink = Sink()
        state.loopApprovalSink = { sink.records.append($0) }
        return (state, sink, root)
    }

    private func looping(_ state: AppState, tainted: Bool = false) -> UUID {
        let id = state.createNewConversation(isBackground: false, select: false)
        let idx = state.conversations.firstIndex { $0.id == id }!
        state.conversations[idx].loop = ConversationLoop(prompt: "check the board", intervalSeconds: 60, cap: 5)
        state.conversations[idx].hasUntrustedToolOutput = tainted
        return id
    }

    @Test("a tick's call a prefix rule allows is recorded by shape, never its arguments, with the layer and taint")
    func prefixRuleOnATick() async throws {
        let (state, sink, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        state.permissions.allowGlobally([PermissionRule(toolName: "run_command", details: "swift test", match: .prefix)])
        let id = looping(state, tainted: true)
        let source = await LoopApprovalProbe.$inLoopTick.withValue(true) {
            await state.requestApprovalSource(toolName: "run_command", details: "swift test --filter SecretSauce12345",
                                              workspace: root.path, conversationId: id, vibecopEnabled: false, isOwner: true)
        }
        guard case .allowlist? = source else { Issue.record("expected the prefix rule to allow it, got \(String(describing: source))"); return }
        let r = try #require(sink.records.first)
        #expect(sink.records.count == 1)
        #expect(r.tick && r.ownerTurn && r.tainted && r.approved && !r.asked && r.waitSeconds == nil)
        #expect(r.layer == "allowlist-prefix" && r.shape == "swift test" && r.tool == "run_command")
        let encoded = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!encoded.contains("SecretSauce"), "the record carries the shape, never the arguments")
    }

    @Test("a call that reaches the dialog records that the person was asked, the wait, and the answer")
    func dialogWaitIsRecorded() async throws {
        let (state, sink, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        let id = looping(state)
        async let source = state.requestApprovalSource(toolName: "run_command", details: "git push origin pilot/x",
                                                       workspace: root.path, conversationId: id, vibecopEnabled: false, isOwner: false)
        for _ in 0..<80 where state.pendingApprovals.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
        #expect(state.pendingApprovals.count == 1)
        if let request = state.pendingApprovals.first { state.resolveApproval(id: request.id, .deny) }
        #expect(await source == nil)
        let r = try #require(sink.records.first)
        #expect(!r.tick && !r.ownerTurn && !r.tainted && r.asked && !r.approved && r.layer == "person-denied")
        #expect((r.waitSeconds ?? -1) >= 0)
        #expect(r.shape == "exact", "git push has no Always-allow prefix")
    }

    @Test("nothing is recorded for a conversation with no loop, or a background one")
    func onlyLoopingConversations() async throws {
        let (state, sink, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        state.permissions.allowGlobally([PermissionRule(toolName: "run_command", details: "swift build", match: .prefix)])
        let plain = state.createNewConversation(isBackground: false, select: false)
        let background = state.createNewConversation(isBackground: true, select: false)
        // A loop on it too (dev-1's #1439 review), so only the background guard keeps it out of the log.
        let bIdx = state.conversations.firstIndex { $0.id == background }!
        state.conversations[bIdx].loop = ConversationLoop(prompt: "x", intervalSeconds: 60, cap: 5)
        for id in [plain, background] {
            _ = await state.requestApprovalSource(toolName: "run_command", details: "swift build", workspace: root.path,
                                                  conversationId: id, vibecopEnabled: false, isOwner: true)
        }
        #expect(sink.records.isEmpty)
    }

    /// The planner's #1425 check: the log never carries a path, an argument or a credential-shaped string.
    @Test("shape never carries a path, an argument or a credential, for any tool", arguments: [
        ("run_command", "swift test --filter Probe --token ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"),
        ("run_command", "cat /Users/someone/.ssh/id_ed25519"),
        ("run_command", "ghp_0123456789abcdefghijklmnopqrstuvwxyzAB --help"),
        ("run_command", "/Users/someone/bin/deploy --prod"),
        ("run_command", "AWS_SECRET_ACCESS_KEY=abc123 ./deploy.sh"),
        // These two keep a token in their Always-allow prefix (`npm run <script>`, an unknown program's second word),
        // so only the secret-shape check keeps it out of the log.
        ("run_command", "npm run ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"),
        ("run_command", "sk-proj-0123456789abcdefghij0123456789 status"),
        ("read_file", "/Users/someone/.ssh/id_ed25519"),
        ("write_file", "/Users/someone/Documents/taxes-2026.pdf"),
        ("mcp__drive__read", #"{"fileId":"1AbCdEf","token":"ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"}"#),
    ])
    func shapeCarriesNoArguments(tool: String, details: String) {
        let shape = LoopApprovalRecord.shape(tool: tool, details: details)
        for marker in ["ghp_", "sk-proj", "someone", ".ssh", "taxes", "fileId", "AWS_SECRET", "abc123", "--prod", "Probe"] {
            #expect(!shape.contains(marker), "\(tool) \(details) logged shape \(shape)")
        }
        #expect(shape == tool || tool == "run_command", "a non-command tool is logged by its name alone")
    }

    @Test("past its cap the log moves to loop-approvals.1.jsonl, replacing an older one, and starts afresh")
    func logRotates() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1425-rot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        let record = LoopApprovalRecord(at: Date(), conversationId: UUID(), loopId: UUID(), tick: true, ownerTurn: true,
                                        tool: "run_command", shape: "swift test", tainted: false, layer: "allowlist-prefix",
                                        asked: false, waitSeconds: nil, approved: true)
        let logs = root.appendingPathComponent("logs")
        // A 1-byte cap: every append after the first finds the log over it, so it rotates each time.
        for _ in 0..<5 { LoopApprovalProbe.appendToLog(record, paths: paths, maxBytes: 1) }
        let current = try String(contentsOf: logs.appendingPathComponent("loop-approvals.jsonl"), encoding: .utf8)
        let old = try String(contentsOf: logs.appendingPathComponent("loop-approvals.1.jsonl"), encoding: .utf8)
        #expect(current.split(separator: "\n").count == 1 && old.split(separator: "\n").count == 1,
                "the newest line in the log, the one before it kept, and the three older dropped")
        let names = try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
        #expect(names == ["loop-approvals.1.jsonl", "loop-approvals.jsonl"], "one old file kept, never more")
    }

    @Test("a tick's line is what the conversation's counters moved by: input, output, cache read, and both cache writes")
    func tickSpend() throws {
        let (state, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        var ticks: [LoopTickRecord] = []
        state.loopTickSink = { ticks.append($0) }
        let id = looping(state)
        let idx = state.conversations.firstIndex { $0.id == id }!
        let loopId = try #require(state.conversations[idx].loop?.id)
        state.conversations[idx].tokenUsage = TokenUsage(promptTokenCount: 9_000, candidatesTokenCount: 300, totalTokenCount: 9_300,
                                                         cacheReadTokenCount: 8_000, cacheWriteTokenCount: 1_000, cacheWrite1hTokenCount: 600)
        let before = state.conversations[idx].tokenUsage
        state.conversations[idx].tokenUsage = TokenUsage(promptTokenCount: 18_630, candidatesTokenCount: 500, totalTokenCount: 19_130,
                                                         cacheReadTokenCount: 17_000, cacheWriteTokenCount: 1_400, cacheWrite1hTokenCount: 900)
        state.recordLoopTick(conversationId: id, loopId: loopId, before: before, seconds: 4.5)
        let t = try #require(ticks.first)
        #expect(ticks.count == 1 && t.kind == "tick" && t.loopId == loopId && t.seconds == 4.5)
        #expect(t.inputTokens == 9_630 && t.outputTokens == 200 && t.cacheReadTokens == 9_000)
        #expect(t.cacheWrite1hTokens == 300 && t.cacheWrite5mTokens == 100, "the 5-minute write is the write less its 1-hour share")
    }

    @Test("a provider that never reported a cache count logs none (unknown, not zero), and a background run logs no tick")
    func tickUnknownCacheAndBackground() throws {
        let (state, _, root) = try setUp(); defer { try? FileManager.default.removeItem(at: root) }
        var ticks: [LoopTickRecord] = []
        state.loopTickSink = { ticks.append($0) }
        let id = looping(state)
        let idx = state.conversations.firstIndex { $0.id == id }!
        state.conversations[idx].tokenUsage = TokenUsage(promptTokenCount: 500, candidatesTokenCount: 50, totalTokenCount: 550)
        state.recordLoopTick(conversationId: id, loopId: UUID(), before: TokenUsage(), seconds: 1)
        #expect(ticks.first?.cacheReadTokens == nil && ticks.first?.cacheWrite5mTokens == nil && ticks.first?.cacheWrite1hTokens == nil)
        let background = state.createNewConversation(isBackground: true, select: false)
        let bIdx = state.conversations.firstIndex { $0.id == background }!
        state.conversations[bIdx].loop = ConversationLoop(prompt: "x", intervalSeconds: 60, cap: 5)
        state.recordLoopTick(conversationId: background, loopId: UUID(), before: nil, seconds: 1)
        #expect(ticks.count == 1)
    }

    /// The tick is the one call site, so this pins that it's wired there and nowhere else decides on it.
    @Test("runLoopTick records each tick it runs")
    func tickIsWired() throws {
        let source = try String(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/iris.swift"), encoding: .utf8)
        let body = try #require(source.components(separatedBy: "func runLoopTick(").dropFirst().first)
        let runCase = try #require(body.components(separatedBy: "case .run(let tick):").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        #expect(runCase.contains("$inLoopTick.withValue(true)"))
        #expect(runCase.contains("recordLoopTick(conversationId: conversationId"))
        #expect(source.components(separatedBy: "recordLoopTick(").count - 1 == 1, "one caller")
    }

    @Test("the default sink appends one JSON line per record to logs/loop-approvals.jsonl")
    func appendsJSONLines() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1425-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        let record = LoopApprovalRecord(at: Date(), conversationId: UUID(), loopId: UUID(), tick: true, ownerTurn: true,
                                        tool: "run_command", shape: "swift test", tainted: false, layer: "allowlist-prefix",
                                        asked: false, waitSeconds: nil, approved: true)
        LoopApprovalProbe.appendToLog(record, paths: paths)
        LoopApprovalProbe.appendToLog(record, paths: paths)
        let text = try String(contentsOf: root.appendingPathComponent("logs/loop-approvals.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(LoopApprovalRecord.self, from: Data(lines[0].utf8)).shape == "swift test")
    }
}
