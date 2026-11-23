import Testing
import Foundation
@testable import IrisKit

/// #1329: `Fixtures/peer-structure-1329/` is the real-canary run of the suites' own texts
/// (`iris --guard-probe --fixtures …`), so it may hold nothing they don't: no new payloads, and none dropped.
@Suite("the #1329 probe fixtures are the suites' texts, judged as a peer message")
struct PeerStructureFixturesTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/peer-structure-1329")

    @Test func fixturesAreTheSuitesTexts() throws {
        let items = try GuardProbeFixtures.load(Self.dir).items
        let attacks = Set(StructureCarryRoleNeighbourTests.splitHeaders + [PeerArrivalStructureTests.splitHeader])
        let benign = Set(StructureCarryRoleNeighbourTests.carried.map(\.0) + [PeerArrivalStructureTests.report])
        #expect(Set(items.filter { $0.label == "attack" }.map(\.text)) == attacks)
        #expect(Set(items.filter { $0.label == "benign" }.map(\.text)) == benign)
        #expect(items.allSatisfy { $0.contextTag == "system_event_peer_session" }, "judged under a peer arrival's tag")
    }

    @Test func aRowWithoutATagIsARunCommandResult() throws {
        let row = #"{"id":"a","category":"c","text":"t","payload":null}"#
        let s = try JSONDecoder().decode(GuardProbeFixtures.Sample.self, from: Data(row.utf8))
        #expect(s.contextTag == nil)
        #expect(GuardProbeFixtures.defaultContextTag == "tool_output_run_command")
    }

    /// The tag decides the canary's prompt: a peer arrival's is the instruction-channel one (#906), so a row
    /// judged under the default would be scored as tool output, and the run would answer the wrong question.
    @Test func aRowsTagReachesTheCanaryPrompt() async {
        final class Prompts: @unchecked Sendable { var seen: [String] = []; let lock = NSLock() }
        struct Recorder: AuxiliaryInferenceEngine {
            let prompts: Prompts
            func loadModel(config: AuxiliaryModelConfig) async throws {}
            func unloadModel() async {}
            func generate(prompt: String, jsonSchema: String?) async throws -> String {
                prompts.lock.withLock { prompts.seen.append(prompt) }
                return "SAFE"
            }
        }
        let prompts = Prompts()
        _ = await GuardProbeFixtures.judge("peer 1329 row", engine: Recorder(prompts: prompts), contextTag: "system_event_peer_session")
        _ = await GuardProbeFixtures.judge("tool 1329 row", engine: Recorder(prompts: prompts))
        let seen = prompts.lock.withLock { prompts.seen }
        #expect(seen.contains { $0.contains("peer 1329 row") && $0.contains("another session") }, "the peer row gets the instruction-channel prompt")
        #expect(seen.contains { $0.contains("tool 1329 row") && $0.contains("is tool output") }, "an untagged row keeps the external prompt")
    }
}
