import Testing
import AVFoundation
import Foundation
@testable import IrisKit

@MainActor
@Suite("YOLO mode (#1099)", .timeLimit(.minutes(1)))
struct YoloModeTests {

    private final class ExplodingVibecop: AuxiliaryInferenceEngine, @unchecked Sendable {
        var calls = 0
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            calls += 1
            return #"{"decision":"DENY","reason":"should never have been consulted in yolo mode"}"#
        }
    }

    private func home() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1099-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(_ root: URL) throws -> AppState {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: root.appendingPathComponent("iris-home")))
        return state
    }

    @Test("/yolo command shows status, toggles on and off, and plays jingles")
    func slashCommandTogglesAndPlaysJingles() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)

        var vengabusPlays = 0
        var powerDownPlays = 0
        state.yoloAudio = YoloAudioHooks(
            playOn: { vengabusPlays += 1 },
            playOff: { powerDownPlays += 1 }
        )

        #expect(!state.isYoloMode(cid))

        state.sendMessage("/yolo")
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is off.")
        #expect(vengabusPlays == 0)
        #expect(powerDownPlays == 0)

        state.sendMessage("/yolo on")
        #expect(state.isYoloMode(cid))
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is on.")
        #expect(vengabusPlays == 1)
        #expect(powerDownPlays == 0)

        state.sendMessage("/yolo")
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is on.")

        state.sendMessage("/yolo off")
        #expect(!state.isYoloMode(cid))
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Yolo mode is off.")
        #expect(vengabusPlays == 1)
        #expect(powerDownPlays == 1)

        state.sendMessage("/yolo maybe")
        #expect(state.conversations.first { $0.id == cid }?.messages.last?.content == "Usage: `/yolo [on|off]`")
    }

    @Test("SlashCommandItem includes /yolo")
    func slashCommandItemIncludesYolo() {
        let matches = SlashCommandItem.matches(for: "/yo")
        #expect(matches.count == 1)
        #expect(matches.first?.command == "/yolo")
        #expect(matches.first?.usage == "/yolo [on|off]")
    }

    @Test("YOLO mode is per-conversation and inherited by delegates")
    func perSessionAndInheritedByDelegates() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let c1 = state.createNewConversation(isBackground: false, select: true)
        let c2 = state.createNewConversation(isBackground: false, select: false)
        let sub = state.createNewConversation(isSubagent: true, isBackground: false, select: false)
        state.linkDelegate(sub, of: c1)

        state.sendMessage("/yolo on")
        #expect(state.isYoloMode(c1))
        #expect(state.isYoloMode(sub))
        #expect(!state.isYoloMode(c2))
    }

    @Test("YOLO mode approves commands, writes, .iris/ writes, and humanOnly calls without Vibecop or user prompt")
    func approvesAllAttendedCallsWithoutVibecop() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: root.path)
        state.sendMessage("/yolo on")

        let vibecop = ExplodingVibecop()
        let cmdSource = await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            await state.requestApprovalSource(toolName: "run_command", details: "rm -rf build && make",
                                              workspace: root.path, conversationId: cid, vibecopEnabled: true)
        }
        #expect(cmdSource == .yolo)
        #expect(vibecop.calls == 0)
        #expect(state.pendingApprovals.isEmpty)
        #expect(ToolApproval(try #require(cmdSource)).line == "Approved (YOLO mode).")

        // Workspace .iris/ write (normally humanOnly)
        let irisFile = root.appendingPathComponent(".iris/vibecop.md").path
        let irisWriteSource = await state.requestApprovalSource(toolName: "write_file", details: irisFile,
                                                                workspace: root.path, conversationId: cid, vibecopEnabled: false)
        #expect(irisWriteSource == .yolo)

        // Explicit humanOnly (e.g. job creation, outbound tool)
        let humanOnlySource = await state.requestApprovalSource(toolName: "schedule_job", details: "name: test",
                                                                workspace: root.path, conversationId: cid, humanOnly: true)
        #expect(humanOnlySource == .yolo)
    }

    @Test("Background job runs and MCP guests never get YOLO mode")
    func backgroundAndGuestNeverYolo() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let bg = state.createNewConversation(isBackground: true, select: false)
        let guest = state.createNewConversation(isGuest: true, guestClientId: "c1", select: false)

        // Even if someone calls setYoloMode directly on a background or guest conversation, it refuses
        state.setYoloMode(true, for: bg)
        state.setYoloMode(true, for: guest)
        #expect(!state.isYoloMode(bg))
        #expect(!state.isYoloMode(guest))

        let bgSource = await state.requestApprovalSource(toolName: "run_command", details: "ls",
                                                         workspace: root.path, conversationId: bg)
        #expect(bgSource == nil)
        #expect(state.takeBackgroundDenials(for: bg).count == 1)

        let guestSource = await state.requestApprovalSource(toolName: "run_command", details: "ls",
                                                            workspace: root.path, conversationId: guest)
        #expect(guestSource == nil)
    }

    @Test("Turning /yolo on resolves any pending approvals for that conversation and its delegates")
    func turningOnFlushesPendingApprovals() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        let sub = state.createNewConversation(isSubagent: true, isBackground: false, select: false)
        state.linkDelegate(sub, of: cid)
        let other = state.createNewConversation(isBackground: false, select: false)

        let mainTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "run_command", details: "echo 1", workspace: nil,
                                            conversationId: cid, origin: "Main agent")
        }
        let subTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "write_file", details: "/tmp/a", workspace: nil,
                                            conversationId: sub, origin: "Subagent")
        }
        let otherTask = Task { @MainActor in
            await state.enqueueUserApproval(toolName: "run_command", details: "echo 2", workspace: nil,
                                            conversationId: other, origin: "Main agent")
        }

        for _ in 0..<200 where state.pendingApprovals.count < 3 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(state.pendingApprovals.count == 3)

        state.sendMessage("/yolo on")
        #expect(try await value(of: mainTask) == true)
        #expect(try await value(of: subTask) == true)
        #expect(state.pendingApprovals.count == 1)
        #expect(state.pendingApprovals.first?.conversationId == other)

        state.denyPendingApprovals(for: other)
        _ = try await value(of: otherTask)
    }

    @Test("YOLO mode bypasses outboundGate and ContextHolds in tainted attended conversations")
    func bypassesOutboundGateAndContextHolds() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.markConversationReadUntrusted(cid)
        state.sendMessage("/yolo on")

        let factStore = try FactStoreManager(inMemory: true)
        let callSaveFact = GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: "save_fact", args: ["content": .string("yolo fact")]))]))], usageMetadata: nil)
        let doneText = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [callSaveFact, doneText]),
                                retryDelays: [], factStore: factStore, protectionEnabled: false, sessionPeerCount: 0)

        // Outbound gate approves immediately with .yolo
        let outboundDecision = await engine.outboundGate(
            FunctionCall(name: "gmail_send_email", args: ["to": .string("a@b.com"), "subject": .string("hi"), "body": .string("yo")]),
            conversationId: cid, workspacePath: nil, isUnattended: false)
        #expect(outboundDecision == .approved(ToolApproval(layer: .yolo)))

        // ContextHolds does not hold save_fact in YOLO mode
        await engine.processInput("save it", source: "UI", conversationId: cid)
        #expect(state.pendingContextWrites.isEmpty)
        let saved = try factStore.search(query: "yolo")
        #expect(saved.count == 1)
    }

    @Test("GateScriptReview auto-approves in YOLO mode")
    func gateScriptReviewAutoApprovesInYolo() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try makeState(root)
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.sendMessage("/yolo on")

        let reviewer = IrisEngine.gateScriptReview(state: state, conversationId: cid, vibecopEnabled: false)
        let outcome = await reviewer.review(script: "echo CHANGED", mounts: [], timeoutSeconds: 10, network: false)
        switch outcome {
        case .success:
            #expect(state.pendingApprovals.isEmpty)
        case .failure(let msg):
            Issue.record("Expected gate script review to auto-approve in YOLO mode, got: \(msg.text)")
        }
    }

    @Test("YoloSynth generates valid PCM buffers for Vengabus and power-down")
    func synthGeneratesValidBuffers() {
        let vengabus = YoloSynth.makeVengabusBuffer()
        #expect(vengabus != nil)
        if let buffer = vengabus, let data = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            #expect(count > 44100 * 3)
            var maxAmp: Float = 0
            var allFinite = true
            for i in 0..<count {
                let sample = data[i]
                if !sample.isFinite { allFinite = false }
                maxAmp = max(maxAmp, abs(sample))
            }
            #expect(allFinite)
            #expect(maxAmp > 0.05 && maxAmp <= 0.26)
        }

        let powerDown = YoloSynth.makePowerDownBuffer()
        #expect(powerDown != nil)
        if let buffer = powerDown, let data = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            #expect(count == Int(1.6 * 44100.0))
            var maxAmp: Float = 0
            var allFinite = true
            for i in 0..<count {
                let sample = data[i]
                if !sample.isFinite { allFinite = false }
                maxAmp = max(maxAmp, abs(sample))
            }
            #expect(allFinite)
            #expect(maxAmp > 0.05 && maxAmp <= 0.36)
        }
    }
}
