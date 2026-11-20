import Testing
import Foundation
@testable import IrisKit

/// #1241 (W1b): a custom rule marked `audience: owner` stays off every turn that is not the owner's;
/// an unmarked rule keeps applying (the default is held in `SkillManager.unmarkedAppliesToNonOwner`
/// pending the owner's ruling, so no test below pins it beyond that constant). The proof is a real engine turn on a stamped non-owner binding (gated on `bindingForCall`, not the
/// engine's own), against an owner turn on the same rules, plus the loader on its own for the
/// plugin rule files the engine cannot be handed.
@MainActor
@Suite("A rule marked audience: owner stays off non-owner turns (#1241, W1b)", .timeLimit(.minutes(1)))
struct RuleAudienceTests {
    private let unmarked = "RULE-UNMARKED-1241"
    private let everyone = "RULE-ALL-1241"
    private let ownerOnly = "RULE-OWNER-1241"

    private struct Fixture {
        let app: AppState
        let memory: MemoryManager
        let paths: IrisPaths
        let root: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1241-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.memoryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.rulesDir, withIntermediateDirectories: true)
        try "I prefer \(unmarked) always".write(to: paths.rulesDir.appendingPathComponent("01_unmarked.md"), atomically: true, encoding: .utf8)
        try "---\naudience: all\n---\nBe polite: \(everyone)".write(to: paths.rulesDir.appendingPathComponent("02_all.md"), atomically: true, encoding: .utf8)
        try "---\naudience: owner\n---\nMy own habit: \(ownerOnly)".write(to: paths.rulesDir.appendingPathComponent("03_owner.md"), atomically: true, encoding: .utf8)
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        return Fixture(app: app, memory: MemoryManager(paths: paths), paths: paths, root: root)
    }

    private func nonOwner(memoryRead: MemoryTier = .none) -> AccessBinding {
        AccessBinding(profile: AccessProfile(memoryRead: memoryRead), principal: .main, isOwner: false)
    }

    private func systemText(_ f: Fixture, binding: AccessBinding?) async -> String {
        let id = f.app.createNewConversation(select: false)
        if let binding { f.app.markGuestSteeredBinding(binding, for: id) }
        let client = CapturingLLMClient(reply: "ok")
        let engine = IrisEngine(state: f.app, client: client, retryDelays: [], protectionEnabled: false,
                                sessionPeerCount: 0, memory: f.memory)
        await engine.processInput("hi", source: "UI", conversationId: id)
        return client.requests.first?.systemInstruction?.parts.compactMap(\.text).joined() ?? ""
    }

    @Test("an owner turn carries every rule: unmarked, audience: all and audience: owner")
    func ownerCarriesAll() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let system = await systemText(f, binding: nil)
        #expect(system.contains(unmarked) && system.contains(everyone) && system.contains(ownerOnly))
    }

    @Test("a stamped non-owner turn drops the rule marked audience: owner and keeps the rest")
    func nonOwnerDropsOnlyOwnerMarked() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let system = await systemText(f, binding: nonOwner())
        #expect(!system.contains(ownerOnly), "an owner-marked rule is owner context")
        #expect(system.contains(everyone), "audience: all is delivered")
        #expect(system.contains(unmarked) == SkillManager.unmarkedAppliesToNonOwner, "an unmarked rule follows the held default")
    }

    @Test("a non-owner at the full memory tier keeps the owner's prompt, rules included (as USER.md is)")
    func fullTierKeepsEverything() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let system = await systemText(f, binding: nonOwner(memoryRead: .full))
        #expect(system.contains(unmarked) && system.contains(everyone) && system.contains(ownerOnly))
    }

    // MARK: the marking itself

    @Test("the declared audience: all and owner are read; a failed marking restricts; no marking is nil")
    func declaredAudience() {
        typealias A = SkillManager.RuleAudience
        #expect(A.declared(by: "---\naudience: all\n---\nbody") == .all)
        #expect(A.declared(by: "---\nname: x\naudience:   ALL  \n---\nbody") == .all, "spacing and case of the value")
        #expect(A.declared(by: "---\naudience: owner\n---\nbody") == .owner)
        #expect(A.declared(by: "no front matter, mentions audience: owner in prose") == nil)
        #expect(A.declared(by: "body\n---\naudience: owner\n---\n") == nil, "the block must open the file")
        #expect(A.declared(by: "---\nname: x\n---\nbody") == nil, "a block with no audience key declares nothing")
        #expect(A.declared(by: "---\n---\naudience: owner\n") == nil, "an empty block declares nothing")
        #expect(A.declared(by: "---\naudience: all\nbody never closes") == .owner, "an unclosed block is a failed marking: restricts")
        #expect(A.declared(by: "---\naudience: everyone\n---\n") == .owner, "an unknown value restricts, it does not widen")
        #expect(A.declared(by: "") == nil)
        #expect(SkillManager.ruleAppliesToNonOwner("---\naudience: owner\n---\nx") == false)
        #expect(SkillManager.ruleAppliesToNonOwner("---\naudience: all\n---\nx") == true)
        #expect(SkillManager.ruleAppliesToNonOwner("plain") == SkillManager.unmarkedAppliesToNonOwner)
    }

    @Test("the loader: user rules and plugin rule files both honour the scope; .everything is unchanged")
    func loaderScopes() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pluginDir = f.root.appendingPathComponent("plugin-rules")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let pluginOwner = pluginDir.appendingPathComponent("p1.md")
        let pluginAll = pluginDir.appendingPathComponent("p2.md")
        try "---\naudience: owner\n---\nplugin habit PLUGIN-OWNER-1241".write(to: pluginOwner, atomically: true, encoding: .utf8)
        try "---\naudience: all\n---\nplugin courtesy PLUGIN-ALL-1241".write(to: pluginAll, atomically: true, encoding: .utf8)

        let all = await SkillManager.shared.loadCustomRules(paths: f.paths, extraRuleFiles: [pluginOwner, pluginAll],
                                                            protectionEnabled: false, scope: .everything)
        for marker in [unmarked, everyone, ownerOnly, "PLUGIN-OWNER-1241", "PLUGIN-ALL-1241"] { #expect(all.contains(marker), "\(marker)") }

        let wide = await SkillManager.shared.loadCustomRules(paths: f.paths, extraRuleFiles: [pluginOwner, pluginAll],
                                                             protectionEnabled: false, scope: .nonOwner)
        #expect(wide.contains(everyone) && wide.contains("PLUGIN-ALL-1241"))
        #expect(!wide.contains(ownerOnly) && !wide.contains("PLUGIN-OWNER-1241"), "owner-marked rules, plugin ones included, are dropped")
    }
}
