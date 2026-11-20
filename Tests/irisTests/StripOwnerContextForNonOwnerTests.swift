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

    /// dev-3 review of #1243: `directCallDistinguishesTiers` above only exercises the bare-id
    /// `.main && !isUnattended` branch -- the hash branch (every unattended run, a subagent, an
    /// evaluator; #1238's stamped job runs go through here) never got its own owner-vs-non-owner,
    /// tier-vs-tier check.
    @Test("promptCacheKey's hash branch (isUnattended/non-.main) also distinguishes owner, and two non-owner tiers, from each other")
    func hashBranchDistinguishesBindingsToo() {
        let id = UUID()
        let owner = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        let ownerUnattended = IrisEngine.promptCacheKey(conversationId: id, isUnattended: true, principal: .main,
                                                        jobProfile: nil, toolNames: [], binding: owner)
        let noneUnattended = IrisEngine.promptCacheKey(conversationId: id, isUnattended: true, principal: .main,
                                                       jobProfile: nil, toolNames: [], binding: nonOwner(memoryRead: .none))
        let fullUnattended = IrisEngine.promptCacheKey(conversationId: id, isUnattended: true, principal: .main,
                                                       jobProfile: nil, toolNames: [], binding: nonOwner(memoryRead: .full))
        #expect(noneUnattended != ownerUnattended, "an unattended (job-run) non-owner key must not collide with the owner's")
        #expect(fullUnattended != ownerUnattended)
        #expect(noneUnattended != fullUnattended, "two non-owner tiers must not share an unattended key either")

        let subagentOwner = IrisEngine.promptCacheKey(conversationId: id, isUnattended: false, principal: .subagent,
                                                       jobProfile: nil, toolNames: [], binding: owner)
        let subagentNonOwner = IrisEngine.promptCacheKey(conversationId: id, isUnattended: false, principal: .subagent,
                                                          jobProfile: nil, toolNames: [], binding: nonOwner(memoryRead: .none))
        #expect(subagentOwner != subagentNonOwner, "a subagent's key must distinguish an owner-shaped from a non-owner-shaped parent too")
    }

    /// dev-3 review of #1243: the non-owner stripped base (steering + custom rules) has its own
    /// cache (`ensureNonOwnerSystemPrompt`), separate from `systemPrompt`, and nothing pinned that
    /// it is dropped alongside `systemPrompt`'s own invalidation -- a stale stripped base would
    /// keep serving pre-edit custom rules to every non-owner turn after an edit. `update_soul`'s
    /// handler is the one production trigger that invalidates `systemPrompt`
    /// (`IrisEngine.processFunctionCalls`), so driving it through `dispatchForTesting` is the real
    /// trigger, not a direct private-property poke. `IrisPaths.default.rulesDir` is the established
    /// pattern other suites already use for a custom-rules probe (e.g. `ContextHoldsTests`); a
    /// uniquely-named file plus `defer` keeps this test's footprint out of any other suite's way.
    @Test("the non-owner stripped base is invalidated alongside systemPrompt, not stale after a rules edit")
    func nonOwnerBaseInvalidatesWithSystemPrompt() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ruleFile = IrisPaths.default.rulesDir.appendingPathComponent("iris-974-task13-\(UUID().uuidString).md")
        try FileManager.default.createDirectory(at: IrisPaths.default.rulesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ruleFile) }
        let ruleV1 = "SENTINEL-RULE-V1-\(UUID().uuidString)"
        let ruleV2 = "SENTINEL-RULE-V2-\(UUID().uuidString)"
        try Data(ruleV1.utf8).write(to: ruleFile)

        let id = f.app.createNewConversation(select: false)
        f.app.markGuestSteeredBinding(nonOwner(), for: id)
        // A separate OWNER conversation on the SAME engine: `update_soul` needs an owner-level
        // memoryWrite to run at all (MemoryBindingGate.writeRefusal), so the invalidation trigger
        // itself must come from an owner turn -- exactly how production reaches it (the owner's
        // own session invalidates the engine-level cache that every OTHER conversation on it,
        // owner and non-owner alike, shares).
        let ownerId = f.app.createNewConversation(select: false)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)

        await engine.processInput("hi", source: "UI", conversationId: id)
        let first = client.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(first.contains(ruleV1), "the non-owner base picks up the rule on its first build")

        try Data(ruleV2.utf8).write(to: ruleFile)
        // The one production trigger that invalidates `systemPrompt` (and must invalidate the
        // non-owner base alongside it): `update_soul`'s handler in IrisEngine.
        let dispatchResult = await engine.dispatchForTesting(FunctionCall(name: "update_soul", args: ["content": .string("new soul")], id: "c1"),
                                                             conversationId: ownerId, offered: ["update_soul"])
        #expect(!dispatchResult.contains(MemoryBindingGate.refusal), "update_soul must actually succeed on the owner's conversation for this test to mean anything: \(dispatchResult)")

        // `guestSteeredBindings` is one-turn-scoped (cleared when a turn ends, #974 Task 15/#1119):
        // the stamp from the first turn above is already gone, so the second turn needs its own.
        f.app.markGuestSteeredBinding(nonOwner(), for: id)
        await engine.processInput("hi again", source: "UI", conversationId: id)
        let second = client.requests.last?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(second.contains(ruleV2), "the non-owner base must rebuild with the new rule, not keep serving the stale one")
        #expect(!second.contains(ruleV1))
    }

    /// dev-3 review of #1243: `ensureNonOwnerSystemPrompt`'s `customBasePrompt` branch (a
    /// subagent's own role prompt) is untested -- if disabled, a non-owner subagent would lose its
    /// role prompt entirely rather than keeping it unchanged.
    @Test("a non-owner subagent with its own custom base prompt keeps that prompt, not the stripped default")
    func nonOwnerSubagentKeepsItsOwnCustomBasePrompt() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let roleSentinel = "SENTINEL-ROLE-13w1"
        let id = f.app.createNewConversation(select: false)
        f.app.markGuestSteeredBinding(nonOwner(), for: id)
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)
        await engine.setSystemPrompt(text: roleSentinel)
        await engine.processInput("hi", source: "UI", conversationId: id)
        let system = client.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
        #expect(system.contains(roleSentinel), "a custom base prompt is the engine's own role, not SOUL-derived -- kept for a non-owner binding too")
        #expect(!system.contains(userSentinel), "USER.md is still stripped on top of the custom base")
    }
}
