import Testing
import Foundation
@testable import IrisKit

/// #1263: a bound profile's own `profiles/<id>/memory.md` is read back into that SAME profile's
/// later turns — the read-back half of #1245's write-only loop. Driven through real turns, reading
/// the actual `systemInstruction` the model would see (not calling the composing function
/// directly), so the injection is proven to reach the model, not just the helper.
///
/// Reading tier (Brian's ruling): `memoryRead >= ProfileMemoryStore.minimumWriteTier` (`.task`),
/// symmetric with the write side -- a profile that can write its own notes must also be able to
/// read them back, or the loop the feature exists for never closes for the profiles it is for.
///
/// Untrusted framing: this file can hold content a guest-steered turn reflected (#1286:
/// `runProfileReflection` has no `!hasGuestInput` gate), strictly less trusted than owner-authored
/// USER.md. It goes through the SAME mechanism USER.md/AGENTS.md already use --
/// `InjectionGuard.sanitizeUntrustedCacheable`, whose own `wrapped()` step always wraps the result
/// in `<untrusted_context source="...">`, under its own `profile_memory` tag, at `.tier3_canary`
/// (the strictest of the three tiers, same ceiling USER.md/AGENTS.md use) -- never weaker than
/// USER.md, never presented as unwrapped prose.
@MainActor
@Suite("a bound profile reads its own memory back into later turns (#1263)", .serialized, .timeLimit(.minutes(2)))
struct ProfileMemoryReadbackTests {
    private struct Harness {
        let root: URL
        let paths: IrisPaths
        let state: AppState
        let client: CapturingLLMClient
        let source: UUID
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    /// `profileId` is nil for an owner (unbound) conversation. `memoryRead` sets the profile's own
    /// tier; `0` ("none") is skipped from the JSON file (its own default).
    private func harness(profileId: String?, memoryRead: Int, preexistingNote: String? = nil,
                         secondProfileId: String? = nil, secondMemoryRead: Int = 1,
                         secondNote: String? = nil) throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1263-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        if let profileId {
            try #"{"memoryRead":\#(memoryRead)}"#.write(to: paths.profilesDir.appendingPathComponent("\(profileId).json"), atomically: true, encoding: .utf8)
        }
        if let secondProfileId {
            try #"{"memoryRead":\#(secondMemoryRead)}"#.write(to: paths.profilesDir.appendingPathComponent("\(secondProfileId).json"), atomically: true, encoding: .utf8)
        }
        for file in [paths.userMd, paths.soulMd, paths.memoryMd] {
            try "owner's own text".write(to: file, atomically: true, encoding: .utf8)
        }
        if let profileId, let preexistingNote, let store = ProfileMemoryStore(paths: paths, profileId: profileId) {
            #expect(store.replace(content: preexistingNote) == "Profile memory updated.")
        }
        if let secondProfileId, let secondNote, let store = ProfileMemoryStore(paths: paths, profileId: secondProfileId) {
            #expect(store.replace(content: secondNote) == "Profile memory updated.")
        }
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        let source = state.createNewConversation(title: "bound", select: true)
        if let profileId, let idx = state.conversations.firstIndex(where: { $0.id == source }) {
            state.conversations[idx].accessProfileId = profileId
        }
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: false, protectionEnabled: false, sessionPeerCount: 0,
                                memory: MemoryManager(paths: paths), accessProfileStore: AccessProfileStore(paths: paths))
        state.installEngine(engine)
        return Harness(root: root, paths: paths, state: state, client: client, source: source)
    }

    private func systemText(_ r: GeminiRequest) -> String {
        r.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
    }

    @Test("a profile at the read threshold (.task) sees its own reflected note, wrapped as untrusted")
    func readThresholdSeesItsOwnNote() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1, preexistingNote: "Prefers terse replies.")
        defer { h.tearDown() }
        await h.state.engine.processInput("hello", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        #expect(text.contains("Prefers terse replies."))
        #expect(text.contains("<untrusted_context source=\"profile_memory\">"))
        #expect(!text.contains("USER_MARKER") && !text.contains("owner's own text"), "USER.md must not leak to a profile below .full")
    }

    @Test("a profile below the read threshold does not see its own note")
    func belowThresholdSeesNothing() async throws {
        let h = try harness(profileId: "p1", memoryRead: 0, preexistingNote: "Prefers terse replies.")
        defer { h.tearDown() }
        await h.state.engine.processInput("hello", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        #expect(!text.contains("Prefers terse replies."))
        #expect(!text.contains("profile_memory"))
    }

    @Test("the owner's own turn never injects a profile memory section")
    func ownerSeesNothing() async throws {
        let h = try harness(profileId: nil, memoryRead: 0)
        defer { h.tearDown() }
        await h.state.engine.processInput("hello", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        #expect(!text.contains("profile_memory"))
        #expect(!text.contains("# Profile Memory"))
    }

    /// dev-3 review / planner's ruling (the stamped-non-owner-.main-turn pattern): a guest-steered
    /// turn on a profile-bound `.main` conversation resolves `bindingForCall` to a
    /// `.mcpGuest`-principal binding whose `memoryRead` floor is fixed at exactly `.task` --
    /// satisfying the tier gate even though this turn is a guest's, not the bound profile's own.
    /// Both stamps a real guest delivery sets together (`AppState.drainPendingUserMessages`/
    /// `takePendingSteers`): `markGuestOriginTurn` (what the gate actually reads, via
    /// `isGuestOriginTurn`) and `markGuestSteeredBinding` (what narrows `bindingForCall`'s answer
    /// to a `.mcpGuest`-principal binding in the first place -- without it this test's turn would
    /// resolve to the owner's own binding and prove nothing).
    @Test("a guest-steered turn on a profile-bound conversation never sees the profile's own memory")
    func guestSteeredTurnSeesNothing() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1, preexistingNote: "Alpha's own note.")
        defer { h.tearDown() }
        h.state.markGuestOriginTurn(h.source)
        h.state.markGuestSteeredBinding(
            AccessBinding(profile: AccessProfile(memoryRead: .task), principal: .mcpGuest, isOwner: false),
            for: h.source)
        await h.state.engine.processInput("hello from a guest", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        #expect(!text.contains("Alpha's own note."))
        #expect(!text.contains("# Profile Memory"))
    }

    /// The reverse direction (planner's ruling, both directions required): a profile-bound `.main`
    /// turn that is NOT guest-origin still reads its own memory -- the gate above must not have
    /// over-corrected into refusing the feature entirely for every non-owner binding.
    @Test("a profile-bound turn that is NOT guest-origin still reads its own memory")
    func nonGuestOriginProfileBoundTurnStillReadsItsMemory() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1, preexistingNote: "Alpha's own note.")
        defer { h.tearDown() }
        #expect(!h.state.isGuestOriginTurn(h.source))
        await h.state.engine.processInput("hello", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        #expect(text.contains("Alpha's own note."))
    }

    @Test("a profile with no memory.md yet injects nothing, not an empty section")
    func noFileYetInjectsNothing() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1)
        defer { h.tearDown() }
        await h.state.engine.processInput("hello", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        #expect(!text.contains("# Profile Memory"))
    }

    @Test("a hand-edited file over the size cap is refused, not fed in partially")
    func overCapFileIsRefused() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1)
        defer { h.tearDown() }
        let store = try #require(ProfileMemoryStore(paths: h.paths, profileId: "p1"))
        try FileManager.default.createDirectory(at: h.paths.profilesDir.appendingPathComponent("p1"), withIntermediateDirectories: true)
        // `replace` itself refuses over the cap; write past it directly, the way a hand edit would.
        try String(repeating: "x", count: ProfileMemoryStore.maxBytes + 1).write(to: store.fileURL, atomically: true, encoding: .utf8)
        await h.state.engine.processInput("hello", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        #expect(!text.contains("# Profile Memory"))
        #expect(!text.contains("xxxxxxxxxx"))
    }

    @Test("two different bound profiles in the same workspace never share a cache entry or see each other's memory")
    func cacheKeyIncludesProfileId() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1, preexistingNote: "Alpha's own note.",
                            secondProfileId: "p2", secondMemoryRead: 1, secondNote: "Beta's own note.")
        defer { h.tearDown() }
        await h.state.engine.processInput("hello from alpha", source: "UI", conversationId: h.source)
        let firstText = systemText(try #require(h.client.requests.first))
        #expect(firstText.contains("Alpha's own note."))
        #expect(!firstText.contains("Beta's own note."))

        // Rebind the SAME conversation to the second profile and turn again. Correctness here does
        // NOT depend on the cache key alone: `composedSystemPrompt`'s hit check re-fetches
        // base/profile/profileMemory/agents/agentProfile text FRESH every call and compares the
        // full tuple before ever returning a cached `Content`, so a key collision alone could
        // never have served p1's content for p2's turn (confirmed by mutation-testing the key
        // away: every test here, including this one, still passed). This test still matters as a
        // correctness pin on the live mechanism — p2's turn must see p2's own note — it just isn't
        // a gate-removal proof of the key fix specifically; that fix is a cache-hit-rate
        // improvement across alternating-profile turns, not the thing preventing cross-profile
        // leakage (the content-equality check is).
        if let idx = h.state.conversations.firstIndex(where: { $0.id == h.source }) {
            h.state.conversations[idx].accessProfileId = "p2"
        }
        await h.state.engine.processInput("hello from beta", source: "UI", conversationId: h.source)
        let secondText = systemText(try #require(h.client.requests.last))
        #expect(secondText.contains("Beta's own note."))
        #expect(!secondText.contains("Alpha's own note."), "p1's cached composition must not leak to p2's turn")
    }

    /// The ACTUAL gate-removal proof for the cached-tuple equality check (the planner's named
    /// review pin): same conversation, same profile id, same workspace -- so `composedSystemPrompt`
    /// hits the SAME cache key on both turns -- but the profile's memory.md changes between them.
    /// If `profileMemoryText` were left out of the cache-hit's equality comparison (only the key
    /// matters, nothing re-validates the content it keys), the second turn would wrongly get back
    /// the first turn's STALE composed `Content`, serving the ORIGINAL note after it was already
    /// overwritten. The two-profiles test above cannot catch this: it changes the key (profile id)
    /// on every call, so a same-key collision is never exercised there.
    @Test("a profile memory change between two turns on the SAME profile is never served stale from the cache")
    func sameProfileMemoryChangeBetweenTurnsIsNotServedStale() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1, preexistingNote: "Original note.")
        defer { h.tearDown() }
        await h.state.engine.processInput("first turn", source: "UI", conversationId: h.source)
        let firstText = systemText(try #require(h.client.requests.first))
        #expect(firstText.contains("Original note."))

        let store = try #require(ProfileMemoryStore(paths: h.paths, profileId: "p1"))
        #expect(store.replace(content: "Updated note.") == "Profile memory updated.")
        // Force a detectable mtime change rather than relying on real wall-clock granularity
        // between the two writes (TurnContextTests' own technique: `setResourceValues` round-trips
        // exactly, unlike `FileManager.setAttributes`, which loses the sub-second precision that
        // would otherwise make this restore compare equal to the original stamp).
        var mutableURL = store.fileURL
        var values = URLResourceValues()
        values.contentModificationDate = Date().addingTimeInterval(60)
        try mutableURL.setResourceValues(values)

        await h.state.engine.processInput("second turn", source: "UI", conversationId: h.source)
        let secondText = systemText(try #require(h.client.requests.last))
        #expect(secondText.contains("Updated note."))
        #expect(!secondText.contains("Original note."), "the cache must not serve the first turn's composition after the file changed")
    }

    /// The gate-removal proof for the untrusted framing: a wrapper this test cannot see would be
    /// indistinguishable from a wrapper that silently stopped being applied. Pinned by checking the
    /// exact tag AND that it brackets the note (not merely present somewhere in a longer prompt),
    /// so a mutant that drops the wrap call (leaving the raw note injected as plain prose) fails
    /// this test, not just a weaker "contains the note" check.
    @Test("the note is never injected without its untrusted wrapper, and the wrapper brackets exactly it")
    func noteIsAlwaysWrappedNeverRawProse() async throws {
        let h = try harness(profileId: "p1", memoryRead: 1, preexistingNote: "Alpha's own note.")
        defer { h.tearDown() }
        await h.state.engine.processInput("hello", source: "UI", conversationId: h.source)
        let text = systemText(try #require(h.client.requests.first))
        let opening = try #require(text.range(of: "<untrusted_context source=\"profile_memory\">"))
        let note = try #require(text.range(of: "Alpha's own note."))
        let closing = try #require(text.range(of: "</untrusted_context>", range: note.upperBound..<text.endIndex))
        #expect(opening.upperBound < note.lowerBound, "the note must appear inside the wrapper, not before it")
        #expect(note.upperBound <= closing.lowerBound, "the note must close before the wrapper does")
    }
}
