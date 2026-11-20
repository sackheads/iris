import Testing
import Foundation
@testable import IrisKit

/// #974 Task 13 (W1): a non-owner binding's turn must not carry USER.md in its assembled prompt,
/// and must not share a `promptCacheKey` with the owner's (or another tier's). Driven through real
/// engine turns, including a STAMPED non-owner `.main` turn sharing a conversation id with the
/// owner's own turns (the planner's flag: the attended `.main` key used to be the bare conversation
/// id, so a guest-steered/job-stamped turn on the SAME conversation would otherwise collide with
/// the owner's cache entry).
@MainActor
@Suite("USER.md and the prompt cache key are owner-scoped (#974 Task 13, W1)", .timeLimit(.minutes(1)))
struct StripOwnerContextForNonOwnerTests {
    private let userSentinel = "SENTINEL-USER-13w1"
    private let soulSentinel = "SENTINEL-SOUL-13w1"

    private struct Fixture {
        let app: AppState
        let memory: MemoryManager
        let root: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-task13-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try Data("owner profile \(userSentinel)".utf8).write(to: paths.userMd)
        try Data("owner soul \(soulSentinel)".utf8).write(to: paths.soulMd)
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        return Fixture(app: app, memory: MemoryManager(paths: paths), root: root)
    }

    private func nonOwner(memoryRead: MemoryTier = .none) -> AccessBinding {
        AccessBinding(profile: AccessProfile(memoryRead: memoryRead), principal: .main, isOwner: false)
    }

    @Test("an owner-bound .main turn's prompt still carries USER.md")
    func ownerTurnCarriesUserMd() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.app.createNewConversation(select: false)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)
        await engine.processInput("hi", source: "UI", conversationId: id)
        let system = client.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(system.contains(userSentinel))
        #expect(system.contains("# User Profile"))
        #expect(system.contains(soulSentinel), "SOUL.md unaffected for an owner turn")
        #expect(system.contains("# Available Skills"), "the skills catalogue unaffected for an owner turn")
    }

    @Test("a guest-steered non-owner stamp on a .main turn strips USER.md, sharing the conversation with an owner turn that still carries it")
    func stampedTurnStripsUserMd() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.app.createNewConversation(select: false)
        f.app.markGuestSteeredBinding(nonOwner(), for: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)
        await engine.processInput("hi", source: "UI", conversationId: id)
        let system = client.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(!system.contains(userSentinel), "a non-owner stamp must not see USER.md")
        #expect(!system.contains("# User Profile"), "the section itself is omitted, not just emptied")
        #expect(!system.contains(soulSentinel), "SOUL.md is owner persona, stripped for a non-owner stamp")
        #expect(!system.contains("# Available Skills"), "the skills catalogue is owner tooling, stripped too")
    }

    @Test("a non-owner profile with memoryRead == .full still carries USER.md, the same tier its own write requires")
    func fullMemoryReadTierStillCarriesUserMd() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.app.createNewConversation(select: false)
        f.app.markGuestSteeredBinding(nonOwner(memoryRead: .full), for: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)
        await engine.processInput("hi", source: "UI", conversationId: id)
        let system = client.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(system.contains(userSentinel))
        #expect(system.contains(soulSentinel))
        #expect(system.contains("# Available Skills"))
    }

    @Test("a guest-steered non-owner stamp's promptCacheKey differs from the owner's own turn on the SAME conversation")
    func stampedTurnGetsADifferentCacheKeyOnTheSameConversation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = f.app.createNewConversation(select: false)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)

        await engine.processInput("hi", source: "UI", conversationId: id)
        let ownerKey = try #require(client.requests.first?.cacheHints?.promptCacheKey)
        #expect(ownerKey == id.uuidString, "the owner's own attended key is unchanged: the bare conversation id")

        f.app.markGuestSteeredBinding(nonOwner(), for: id)
        await engine.processInput("hi again", source: "UI", conversationId: id)
        let stampedKey = try #require(client.requests.last?.cacheHints?.promptCacheKey)
        #expect(stampedKey != ownerKey, "a stamped non-owner turn on the SAME conversation must not share the owner's cache key")
    }

    @Test("promptCacheKey called directly: owner is the bare id, two different non-owner memory tiers differ from each other and from the owner")
    func directCallDistinguishesTiers() {
        let id = UUID()
        let owner = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        let ownerKey = IrisEngine.promptCacheKey(conversationId: id, isUnattended: false, principal: .main,
                                                 jobProfile: nil, toolNames: [], binding: owner)
        #expect(ownerKey == id.uuidString)

        let none = IrisEngine.promptCacheKey(conversationId: id, isUnattended: false, principal: .main,
                                             jobProfile: nil, toolNames: [], binding: nonOwner(memoryRead: .none))
        let full = IrisEngine.promptCacheKey(conversationId: id, isUnattended: false, principal: .main,
                                             jobProfile: nil, toolNames: [], binding: nonOwner(memoryRead: .full))
        #expect(none != ownerKey)
        #expect(full != ownerKey)
        #expect(none != full, "two non-owner profiles at different memory tiers must not share a cache key")
    }
}
