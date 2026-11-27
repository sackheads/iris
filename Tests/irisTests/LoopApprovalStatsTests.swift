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
        for id in [plain, background] {
            _ = await state.requestApprovalSource(toolName: "run_command", details: "swift build", workspace: root.path,
                                                  conversationId: id, vibecopEnabled: false, isOwner: true)
        }
        #expect(sink.records.isEmpty)
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
