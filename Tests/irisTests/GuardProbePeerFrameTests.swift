import Testing
import Foundation
@testable import IrisKit

/// #1365: `iris --guard-probe --fixtures DIR --frame-peer` judges a peer-session row as the product delivers it,
/// framed by `IrisEngine.framePeerMessage`, not by a copy of the frame written into the fixture. Pinned against a
/// real `deliverPeerMessage`: the canary is asked the same prompt, byte for byte, either way.
@MainActor
@Suite("guard-probe frames peer rows as delivered (#1365)", .serialized, .timeLimit(.minutes(1)))
struct GuardProbePeerFrameTests {
    /// Keeps every prompt that carries `marker`, and answers SAFE.
    private final class PromptLog: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String] = []
        let marker: String
        init(_ marker: String) { self.marker = marker }
        var prompts: [String] { lock.withLock { kept } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            if prompt.contains(marker) { lock.withLock { kept.append(prompt) } }
            return "SAFE"
        }
    }

    private struct PassingTier2: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    private static func fixtures(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    /// The canary's tag is a fresh random 8 hex digits per call; everything else in the prompt is compared.
    private static func untagged(_ prompt: String) -> String {
        guard let open = prompt.range(of: #"<[0-9A-F]{8}>"#, options: .regularExpression) else { return prompt }
        let tag = String(prompt[open].dropFirst().dropLast())
        return prompt.replacingOccurrences(of: tag, with: "TAG")
    }

    /// What the canary is asked when `body` is delivered to an idle session the way a peer's send delivers it.
    private func deliveredPrompts(_ body: String, marker: String) async throws -> [String] {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let target = state.createNewConversation(isBackground: false, select: true)
        let reply = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                                   usageMetadata: nil)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: [reply]), retryDelays: [],
                                protectionEnabled: true, sessionPeerCount: 0)
        let log = PromptLog(marker)
        await AuxiliaryModelManager.$scopedEngines.withValue(["canary": log]) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
                _ = await engine.deliverPeerMessage(body, from: GuardProbeFixtures.framedSender.id,
                                                    senderName: GuardProbeFixtures.framedSender.name, to: target,
                                                    envelope: GuardProbeFixtures.framedEnvelope)
            }
        }
        return log.prompts
    }

    @Test("a framed peer row asks the canary exactly what deliverPeerMessage asks it", arguments: ["benign.jsonl", "attacks.jsonl"])
    func framedRowIsWhatDeliveryJudges(file: String) async throws {
        let rows = try GuardProbeFixtures.load(Self.fixtures("peer-structure-1329")).items
        let row = try #require(rows.first { $0.contextTag == GuardProbeFixtures.peerContextTag && ($0.payload == nil) == (file == "benign.jsonl") })
        // The body is an existing fixture's text; a fresh marker only picks this call's prompt out of the turn's others.
        let marker = "ROW-1365-\(UUID().uuidString)"
        let body = row.text + "\n" + marker
        var item = row
        item.text = body

        let framed = try #require(try GuardProbeFixtures.framed([item]).first)
        #expect(framed.text != body && framed.text.contains(body), "the row was framed")
        let probe = PromptLog(marker)
        _ = await GuardProbeFixtures.judge(framed.text, engine: probe, contextTag: try #require(framed.contextTag))
        let delivered = try await deliveredPrompts(body, marker: marker)

        #expect(probe.prompts.count == 1 && delivered.count == 1, "probe \(probe.prompts.count), delivered \(delivered.count)")
        #expect(probe.prompts.map(Self.untagged) == delivered.map(Self.untagged))
    }

    @Test("a hand-framed set is refused under --frame-peer, and its hand copy still matches the product's frame")
    func handFramedSetsAreRefusedAndStillMatch() throws {
        for set in ["peer-ack-1356", "role-shapes-1361"] {
            let rows = try GuardProbeFixtures.load(Self.fixtures(set)).items
            #expect(throws: GuardProbeFixtures.AlreadyFramed.self, "\(set) would be framed twice") {
                try GuardProbeFixtures.framed(rows)
            }
        }
        // The hand copy (#1356) drifts silently if the frame changes: rebuild its requests from their bodies.
        let requests = try GuardProbeFixtures.load(Self.fixtures("peer-ack-1356")).items.filter {
            $0.contextTag == GuardProbeFixtures.peerContextTag && $0.text.hasPrefix("Request from another session")
        }
        #expect(!requests.isEmpty)
        for row in requests {
            let head = try #require(row.text.range(of: "\n\n")), tail = try #require(row.text.range(of: "\n\nThe text above", options: .backwards))
            let body = String(row.text[head.upperBound..<tail.lowerBound])
            let product = IrisEngine.framePeerMessage(body, senderName: GuardProbeFixtures.framedSender.name,
                                                      senderId: GuardProbeFixtures.framedSender.id,
                                                      envelope: GuardProbeFixtures.framedEnvelope)
            #expect(product == row.text, "\(row.id): the fixture's frame no longer matches framePeerMessage")
        }
    }

    @Test("only peer-session rows are framed: topic, inbox and tool-output rows are judged as written")
    func onlyPeerRowsAreFramed() throws {
        let rows = try GuardProbeFixtures.load(Self.fixtures("peer-ack-1356")).items.filter { $0.contextTag != GuardProbeFixtures.peerContextTag }
        #expect(rows.contains { $0.contextTag == "peer_topic" } && rows.contains { $0.contextTag == "inbox_emit" })
        #expect(try GuardProbeFixtures.framed(rows).map(\.text) == rows.map(\.text))
        let bare = try GuardProbeFixtures.load(Self.fixtures("peer-structure-1329")).items
        #expect(try GuardProbeFixtures.framed(bare).allSatisfy { $0.text.hasPrefix("Request from another session, \"iris-dev-2\" (1A2B3C4D), msg m-1:") })
    }

    @Test("--frame-peer parses, and is off by default")
    func parsesFramePeer() throws {
        let base = ["iris", "--guard-probe", "--fixtures", "fx", "--model", "ollama:gemma4:12b", "--arm", "a", "--out", "o"]
        #expect(try #require(try GuardProbeCLI.parse(base)?.get().fixtures).framePeer == false)
        #expect(try #require(try GuardProbeCLI.parse(base + ["--frame-peer"])?.get().fixtures).framePeer)
    }
}
