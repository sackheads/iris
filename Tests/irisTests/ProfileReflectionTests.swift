import Testing
import Foundation
@testable import IrisKit

/// #1245 (#974 C7, the narrowed local reflection): a session bound to a profile whose `memoryWrite`
/// reaches `ProfileMemoryStore.minimumWriteTier` reflects into `profiles/<id>/memory.md` only. Driven
/// through the real triggers (`/reflect`, and the every-30-messages path in `sendMessage`) on the one
/// `.main` engine, with the binding coming from the conversation's persisted `accessProfileId`. What is
/// asserted: the file's bytes, the tool list the reflection turn was offered, the owner's stores and
/// the cards in Iris.
@MainActor
@Suite("a bound session reflects into its own profile memory file only (#1245)", .serialized, .timeLimit(.minutes(2)))
struct ProfileReflectionTests {
    private struct Harness {
        let root: URL
        let paths: IrisPaths
        let state: AppState
        let client: ScriptedStreamClient
        let iris: UUID
        let source: UUID
        func tearDown() { try? FileManager.default.removeItem(at: root) }
        var profileFile: URL { paths.profilesDir.appendingPathComponent("writer/memory.md") }
    }

    private static let note = "Prefers short answers; project Atlas ships Friday."

    private static func writeCall(_ content: String) -> [ScriptedStreamClient.Step] {
        let call = FunctionCall(name: "update_profile_memory", args: ["content": .string(content)], id: "c1")
        return [.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))]
    }

    private static func text(_ s: String) -> [ScriptedStreamClient.Step] {
        [.event(.textDelta(s)), .event(.done(finishReason: nil))]
    }

    /// `profileId` is the source conversation's persisted profile. The store holds `writer`
    /// (memoryWrite `.task`) and `reader` (no memoryWrite).
    private func harness(profileId: String?, script: [[ScriptedStreamClient.Step]], guestInput: Bool = false) throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1245-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try #"{"memoryWrite":1}"#.write(to: paths.profilesDir.appendingPathComponent("writer.json"), atomically: true, encoding: .utf8)
        try #"{"memoryWrite":1}"#.write(to: paths.profilesDir.appendingPathComponent("writer2.json"), atomically: true, encoding: .utf8)
        try #"{"memoryRead":2}"#.write(to: paths.profilesDir.appendingPathComponent("reader.json"), atomically: true, encoding: .utf8)
        for file in [paths.userMd, paths.soulMd, paths.memoryMd] {
            try "owner's own text".write(to: file, atomically: true, encoding: .utf8)
        }
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        let iris = state.activityConversationId()
        let source = state.createNewConversation(title: "Launch plan", select: true)
        state.appendMessage(role: .user, content: "plan the launch", to: source)
        state.appendMessage(role: .agent, content: "Launch is Friday.", to: source)
        if let idx = state.conversations.firstIndex(where: { $0.id == source }) {
            state.conversations[idx].title = "Launch plan"
            state.conversations[idx].accessProfileId = profileId
            state.conversations[idx].hasGuestInput = guestInput
        }
        let client = ScriptedStreamClient(script)
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                memory: MemoryManager(paths: paths), accessProfileStore: AccessProfileStore(paths: paths))
        state.installEngine(engine)
        return Harness(root: root, paths: paths, state: state, client: client, iris: iris, source: source)
    }

    private func cards(_ h: Harness) -> [EventCard] {
        (h.state.conversations.first { $0.id == h.iris }?.messages ?? []).filter { $0.role == .event }.compactMap { EventCard.decode($0.content) }
    }

    private func waitForTurn(_ h: Harness) async throws {
        for _ in 0..<400 where h.state.hasTurnInFlight(for: h.source) { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(!h.state.hasTurnInFlight(for: h.source), "turn did not finish within the bounded wait")
    }

    private func ownerFiles(_ h: Harness) -> [String?] {
        [h.paths.userMd, h.paths.soulMd, h.paths.memoryMd].map { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private func profileFile(_ h: Harness) -> String? { try? String(contentsOf: h.profileFile, encoding: .utf8) }

    @Test("/reflect in a session bound to a writing profile writes that profile's file, offered only that tool, and touches no owner store or Iris")
    func manualReflectWritesOnlyTheProfileFile() async throws {
        let h = try harness(profileId: "writer", script: [Self.writeCall(Self.note), Self.text("Saved.")]); defer { h.tearDown() }
        let before = ownerFiles(h)
        h.state.sendMessage("/reflect")
        try await waitForTurn(h)
        #expect(profileFile(h) == Self.note)
        #expect(IrisEngine.offeredToolNames(try #require(h.client.requests.first)) == [IrisEngine.profileMemoryTool])
        #expect(ownerFiles(h) == before, "no owner store changed")
        #expect(cards(h).isEmpty, "no card reached Iris")
    }

    /// #1286 (folded into #1263/#1289): unlike the automatic trigger, `/reflect` on the OWNER's
    /// own path runs regardless of guest input by design ("asked for, so it runs"). The profile
    /// path had no equivalent gate at all before this -- a live gap, not merely untested, since
    /// `/reflect` never checked `hasGuestInput` for a bound session either. #1290: the handler now
    /// says why nothing ran instead of printing "Triggering" and doing nothing; the gate inside
    /// `runProfileReflection` stays, and the next test pins it on its own.
    @Test("/reflect on a session with guest input in its history does not reflect into the profile file, and says why")
    func manualReflectSkipsWhenGuestTouched() async throws {
        let h = try harness(profileId: "writer", script: [Self.writeCall(Self.note), Self.text("Saved.")], guestInput: true)
        defer { h.tearDown() }
        h.state.sendMessage("/reflect")
        try await waitForTurn(h)
        #expect(h.client.calls == 0, "the model is never called for a guest-touched bound session's manual reflect")
        #expect(profileFile(h) == nil)
        let system = (h.state.conversations.first { $0.id == h.source }?.messages ?? []).filter { $0.role == .system }.map(\.content)
        #expect(system.contains(AppState.reflectionNotRunForGuestInput), "\(system)")
        #expect(!system.contains { $0.hasPrefix("Triggering") }, "\(system)")
    }

    @Test("runProfileReflection refuses a session with guest input in its history on its own, whatever its caller checked")
    func profileReflectionGateHoldsWithoutHandler() async throws {
        let h = try harness(profileId: "writer", script: [Self.writeCall(Self.note), Self.text("Saved.")], guestInput: true)
        defer { h.tearDown() }
        await h.state.runProfileReflection(profileId: "writer", in: h.source)
        #expect(h.client.calls == 0)
        #expect(profileFile(h) == nil)
    }

    @Test("the automatic every-30-messages trigger reflects into the profile file; a session with guest input in its history does not")
    func automaticTrigger() async throws {
        let h = try harness(profileId: "writer", script: [Self.text("Noted."), Self.writeCall(Self.note), Self.text("Saved.")]); defer { h.tearDown() }
        let idx = try #require(h.state.conversations.firstIndex { $0.id == h.source })
        h.state.conversations[idx].messageCountSinceReflection = 29
        h.state.sendMessage("and one more thing")
        try await waitForTurn(h)
        #expect(h.client.calls == 3, "the user's turn, then the reflection turn and its follow-up")
        #expect(profileFile(h) == Self.note)
        #expect(cards(h).isEmpty)

        let g = try harness(profileId: "writer", script: [Self.text("Noted."), Self.writeCall(Self.note), Self.text("Saved.")], guestInput: true); defer { g.tearDown() }
        let gidx = try #require(g.state.conversations.firstIndex { $0.id == g.source })
        g.state.conversations[gidx].messageCountSinceReflection = 29
        g.state.sendMessage("and one more thing")
        try await waitForTurn(g)
        #expect(g.client.calls == 1, "guest text in the history: no automatic reflection")
        #expect(profileFile(g) == nil)
    }

    @Test("a profile whose memoryWrite is below the threshold, or that does not exist, reflects nowhere")
    func narrowProfilesDoNotReflect() async throws {
        for id in ["reader", "deleted"] {
            let h = try harness(profileId: id, script: [Self.writeCall(Self.note), Self.text("Saved.")]); defer { h.tearDown() }
            let before = ownerFiles(h)
            h.state.sendMessage("/reflect")
            try await waitForTurn(h)
            #expect(h.client.calls == 0, "\(id): no model turn")
            #expect(ownerFiles(h) == before)
            #expect(!FileManager.default.fileExists(atPath: h.paths.profilesDir.appendingPathComponent("\(id)/memory.md").path))
        }
    }

    @Test("control: the owner's /reflect still runs the owner's reflection, not the profile writer")
    func ownerStillReflects() async throws {
        let h = try harness(profileId: nil, script: [Self.text("No memory consolidation needed at this time.")]); defer { h.tearDown() }
        h.state.sendMessage("/reflect")
        try await waitForTurn(h)
        #expect(h.client.calls == 1)
        let offered = IrisEngine.offeredToolNames(try #require(h.client.requests.first))
        #expect(offered.contains("update_memory") && !offered.contains(IrisEngine.profileMemoryTool), "\(offered)")
    }

    /// The write re-reads the binding when it runs, not when the reflection started: a profile narrowed, or a
    /// conversation re-bound, while the turn is in flight is refused by what it is now.
    @Test("a profile narrowed or a conversation re-bound after the reflection started: the write is refused")
    func bindingChangedMidReflection() async throws {
        for change in ["narrowed", "rebound"] {
            let h = try harness(profileId: "writer", script: [])
            defer { h.tearDown() }
            let state = h.state, source = h.source, paths = h.paths
            let mutate: @Sendable () async -> Void = {
                if change == "narrowed" {
                    try? #"{"memoryWrite":0}"#.write(to: paths.profilesDir.appendingPathComponent("writer.json"), atomically: true, encoding: .utf8)
                } else {
                    await MainActor.run {
                        if let idx = state.conversations.firstIndex(where: { $0.id == source }) { state.conversations[idx].accessProfileId = "writer2" }
                    }
                }
            }
            let client = ScriptedStreamClient([[.block(mutate)] + Self.writeCall(Self.note), Self.text("ok")])
            let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                    streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                    memory: MemoryManager(paths: paths), accessProfileStore: AccessProfileStore(paths: paths))
            state.installEngine(engine)
            state.sendMessage("/reflect")
            try await waitForTurn(h)
            #expect(client.calls >= 1, "\(change): the reflection turn ran")
            #expect(profileFile(h) == nil, "\(change): nothing written")
            #expect(!FileManager.default.fileExists(atPath: paths.profilesDir.appendingPathComponent("writer2/memory.md").path), "\(change)")
        }
    }

    @Test("the writer is not offered, and a call to it does nothing, outside a reflection turn")
    func notOfferedOnPlainTurn() async throws {
        let h = try harness(profileId: "writer", script: [Self.writeCall(Self.note), Self.text("done")]); defer { h.tearDown() }
        h.state.sendMessage("save a note")
        try await waitForTurn(h)
        #expect(!IrisEngine.offeredToolNames(try #require(h.client.requests.first)).contains(IrisEngine.profileMemoryTool))
        #expect(profileFile(h) == nil)
    }

    @Test("a reflection over the size cap writes nothing")
    func oversizeWritesNothing() async throws {
        let h = try harness(profileId: "writer", script: [Self.writeCall(String(repeating: "x", count: ProfileMemoryStore.maxBytes + 1)), Self.text("ok")]); defer { h.tearDown() }
        h.state.sendMessage("/reflect")
        try await waitForTurn(h)
        #expect(profileFile(h) == nil)
    }

    @Test("the store takes only a valid profile id, and never writes through a link")
    func storeValidatesAndRefusesLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1245-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        for bad in ["", "..", "../x", "a/b", "a.b", "mappings", "Mappings", "owner", "a\u{0}b"] {
            #expect(ProfileMemoryStore(paths: paths, profileId: bad) == nil, "\(bad.debugDescription)")
        }
        let store = try #require(ProfileMemoryStore(paths: paths, profileId: "alpha"))
        #expect(store.replace(content: "one") == "Profile memory updated.")
        #expect(store.read() == "one")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linked = try #require(ProfileMemoryStore(paths: paths, profileId: "beta"))
        try FileManager.default.createSymbolicLink(at: paths.profilesDir.appendingPathComponent("beta"), withDestinationURL: outside)
        #expect(linked.replace(content: "two").contains("link"))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("memory.md").path))
    }
}
