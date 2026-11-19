import Testing
import Foundation
@testable import IrisKit

/// #974 Task 7 (C4): the three memory reads and the eight writers consult the active binding's
/// memory axes where the data is read or written. One name per test case, so a forgotten tool fails
/// a test (the #1195 pattern), and `MemoryBindingGate.writerTiers` is pinned complete over
/// `ToolExecutor.memoryWriteTools`.
@MainActor
@Suite("Memory tools consult the binding's memory tier (#974 Task 7)", .timeLimit(.minutes(1)))
struct MemoryBindingGateTests {
    nonisolated static let writers = ["save_fact", "manage_fact", "update_memory", "update_user_profile", "update_soul",
                                      "create_skill", "update_skill", "delete_skill"]
    nonisolated static let sharedWriters = ["save_fact", "manage_fact"]
    nonisolated static let fullWriters = ["update_memory", "update_user_profile", "update_soul",
                                          "create_skill", "update_skill", "delete_skill"]

    private func binding(read: MemoryTier = .none, write: MemoryTier = .none, principal: Principal = .main,
                         owner: Bool = false) -> AccessBinding {
        AccessBinding(profile: AccessProfile(memoryRead: read, memoryWrite: write), principal: principal, isOwner: owner)
    }

    // MARK: the table

    @Test("the writer table is exactly the memory writers: a new writer is decided on purpose")
    func tableIsComplete() {
        #expect(Set(MemoryBindingGate.writerTiers.keys) == ToolExecutor.memoryWriteTools)
        #expect(Set(Self.writers) == ToolExecutor.memoryWriteTools)
        #expect(Set(Self.sharedWriters + Self.fullWriters) == Set(Self.writers))
    }

    @Test("each writer's tier is the plan's: identity, durable and skill stores need .full, the fact tier .shared")
    func tableTiers() {
        for name in Self.fullWriters { #expect(MemoryBindingGate.writerTiers[name] == .full, Comment(rawValue: name)) }
        for name in Self.sharedWriters { #expect(MemoryBindingGate.writerTiers[name] == .shared, Comment(rawValue: name)) }
        #expect(MemoryBindingGate.factsReadTier == .shared)
        #expect(MemoryBindingGate.conversationsReadTier == .conversations)
    }

    // MARK: the pure gate

    @Test("a writer refuses below its tier and runs at it, tier by tier", arguments: MemoryBindingGateTests.writers)
    func writerBoundary(_ name: String) throws {
        let required = try #require(MemoryBindingGate.writerTiers[name], "a writer with no table row")
        for tier in [MemoryTier.none, .task, .shared, .conversations, .full] {
            let refusal = MemoryBindingGate.writeRefusal(tool: name, binding: binding(write: tier))
            if tier >= required {
                #expect(refusal == nil, Comment(rawValue: "\(name) at \(tier)"))
            } else {
                #expect(refusal == MemoryBindingGate.refusal, Comment(rawValue: "\(name) at \(tier)"))
            }
        }
    }

    @Test("the write tier is what matters: a full READ tier does not let a writer run", arguments: MemoryBindingGateTests.writers)
    func readTierDoesNotWrite(_ name: String) {
        #expect(MemoryBindingGate.writeRefusal(tool: name, binding: binding(read: .full, write: .none)) == MemoryBindingGate.refusal)
    }

    @Test("an owner binding is never refused a writer", arguments: MemoryBindingGateTests.writers)
    func ownerWrites(_ name: String) {
        #expect(MemoryBindingGate.writeRefusal(tool: name, binding: AccessBinding(profile: .owner, principal: .main, isOwner: true)) == nil)
        // An owner-inheriting subagent keeps the owner profile (Invariant 1).
        #expect(MemoryBindingGate.writeRefusal(tool: name, binding: AccessBinding(profile: .owner, principal: .subagent, isOwner: true)) == nil)
    }

    @Test("a tool that is not a memory writer is not this gate's business")
    func otherToolsPass() {
        for name in ["run_command", "read_file", "reflect", "search_memory", "send_to_session"] {
            #expect(MemoryBindingGate.writeRefusal(tool: name, binding: binding()) == nil, Comment(rawValue: name))
        }
    }

    @Test("reads: facts need .shared, conversations need .conversations, an owner needs neither")
    func readTiers() {
        let expectations: [(MemoryTier, facts: Bool, conversations: Bool)] = [
            (.none, false, false), (.task, false, false), (.shared, true, false), (.conversations, true, true), (.full, true, true),
        ]
        for (tier, facts, conversations) in expectations {
            #expect(MemoryBindingGate.mayReadFacts(binding(read: tier)) == facts, Comment(rawValue: "facts at \(tier)"))
            #expect(MemoryBindingGate.mayReadConversations(binding(read: tier)) == conversations, Comment(rawValue: "conversations at \(tier)"))
        }
        let owner = AccessBinding(profile: .owner, principal: .main, isOwner: true)
        #expect(MemoryBindingGate.mayReadFacts(owner) && MemoryBindingGate.mayReadConversations(owner))
    }

    // MARK: through a real engine turn

    /// One turn where the model calls `name`, on an engine carrying `binding`, returning what the
    /// dispatcher gave it. Its own stores, so a control call that really writes touches nothing shared.
    private func dispatchResult(for name: String, args: [String: JSONValue] = [:], binding: AccessBinding?,
                                principal: Principal = .main, pinned: Bool = false) async throws -> String {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        if pinned, let idx = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[idx].isPinned = true }
        var callArgs: [String: JSONValue] = ["query": .string("anything"), "content": .string("x"), "id": .string(UUID().uuidString),
                                             "action": .string("list"), "name": .string("s")]
        for (k, v) in args { callArgs[k] = v }
        let call = FunctionCall(name: name, args: callArgs)
        let part = Part(text: nil, functionCall: call, functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
        let client = FakeLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "understood")]))], usageMetadata: nil),
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-t7-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], factStore: try FactStoreManager(inMemory: true), protectionEnabled: false,
                                sessionPeerCount: 0, memory: MemoryManager(paths: IrisPaths(root: root)), declareStateGatedTools: true, binding: binding)
        let turnTask = Task { await engine.processInput("go", source: "UI", conversationId: id) }
        let denyTask = Task {
            while !Task.isCancelled {
                if !app.pendingApprovals.isEmpty { app.denyPendingApprovals(for: id); break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        try await value(of: turnTask)
        denyTask.cancel()
        let responses = app.conversations.first { $0.id == id }?.history.flatMap { $0.parts }.compactMap { $0.functionResponse } ?? []
        return responses.compactMap { $0.response["result"]?.stringValue }.joined(separator: "\n")
    }

    @Test("a forged call to each writer under a below-tier binding is refused", arguments: MemoryBindingGateTests.writers)
    func forgedWriterRefused(_ name: String) async throws {
        // A binding with every OTHER axis wide open, so only the memory write tier can be the reason.
        let b = AccessBinding(profile: AccessProfile(memoryRead: .full, memoryWrite: .task), principal: .main, isOwner: false)
        let result = try await dispatchResult(for: name, binding: b)
        #expect(result.contains(MemoryBindingGate.refusal), Comment(rawValue: "\(name): \(result)"))
    }

    @Test("the control: the same call from an owner engine is not refused by the gate", arguments: MemoryBindingGateTests.writers)
    func ownerWriterNotRefused(_ name: String) async throws {
        let result = try await dispatchResult(for: name, binding: nil)
        #expect(!result.contains(MemoryBindingGate.refusal), Comment(rawValue: "\(name): \(result)"))
    }

    @Test("a writer at exactly its tier runs: .shared writes facts, .full writes the identity store")
    func writerAtTierRuns() async throws {
        let shared = try await dispatchResult(for: "save_fact", binding: binding(write: .shared))
        #expect(!shared.contains(MemoryBindingGate.refusal), Comment(rawValue: shared))
        let fullNeeded = try await dispatchResult(for: "update_soul", binding: binding(write: .shared))
        #expect(fullNeeded.contains(MemoryBindingGate.refusal), "a .shared write tier still cannot write the soul")
    }

    @Test("a subagent binding is tier-scoped too: a .task child reads no facts and writes none")
    func subagentIsTierScoped() async throws {
        let child = AccessBinding(profile: AccessProfile(memoryRead: .task, memoryWrite: .task), principal: .subagent, isOwner: false)
        let read = try await dispatchResult(for: "search_memory", args: ["scope": .string("all")], binding: child, principal: .subagent)
        #expect(read.contains(MemoryBindingGate.refusal), Comment(rawValue: read))
        #expect(!read.contains("No relevant facts found."), "the facts half must not have run")
        let write = try await dispatchResult(for: "save_fact", binding: child, principal: .subagent)
        #expect(write.contains(MemoryBindingGate.refusal), Comment(rawValue: write))
    }

    @Test("an owner-inheriting subagent is unchanged")
    func ownerSubagentUnchanged() async throws {
        let child = AccessBinding(profile: .owner, principal: .subagent, isOwner: true)
        let read = try await dispatchResult(for: "search_memory", args: ["scope": .string("facts")], binding: child, principal: .subagent)
        #expect(!read.contains(MemoryBindingGate.refusal), Comment(rawValue: read))
    }

    // MARK: search_memory scopes

    @Test("search_memory(scope: all) under a .task binding returns neither facts nor conversations")
    func searchAllUnderTask() async throws {
        let result = try await dispatchResult(for: "search_memory", args: ["scope": .string("all")], binding: binding(read: .task))
        #expect(result.contains("Facts:"))
        #expect(result.contains("Conversations:"))
        #expect(result.components(separatedBy: MemoryBindingGate.refusal).count - 1 == 2, "both halves refused: \(result)")
        #expect(!result.contains("No relevant facts found."))
        #expect(!result.contains("No matching conversations."))
    }

    @Test("search_memory under .shared: facts run, conversations are refused")
    func searchAllUnderShared() async throws {
        let result = try await dispatchResult(for: "search_memory", args: ["scope": .string("all")], binding: binding(read: .shared))
        #expect(result.contains("No relevant facts found."), Comment(rawValue: result))
        #expect(result.components(separatedBy: MemoryBindingGate.refusal).count - 1 == 1, "only the conversations half is refused: \(result)")
    }

    @Test("search_memory under .conversations: neither half is refused")
    func searchAllUnderConversations() async throws {
        let result = try await dispatchResult(for: "search_memory", args: ["scope": .string("all")], binding: binding(read: .conversations))
        #expect(!result.contains(MemoryBindingGate.refusal), Comment(rawValue: result))
    }

    @Test("a single-scope search is refused whole when its half is not allowed",
          arguments: [("facts", MemoryTier.none), ("conversations", MemoryTier.shared), ("conversations", MemoryTier.none)])
    func singleScopeRefused(_ scope: String, _ tier: MemoryTier) async throws {
        let result = try await dispatchResult(for: "search_memory", args: ["scope": .string(scope)], binding: binding(read: tier))
        #expect(result.contains(MemoryBindingGate.refusal), Comment(rawValue: "\(scope) at \(tier): \(result)"))
    }

    // MARK: the conversation reads

    @Test("search_conversations and read_conversation are refused below .conversations, even in a pinned conversation",
          arguments: ["search_conversations", "read_conversation"], [MemoryTier.none, .task, .shared])
    func conversationReadsRefused(_ name: String, _ tier: MemoryTier) async throws {
        let result = try await dispatchResult(for: name, binding: binding(read: tier), pinned: true)
        #expect(result == MemoryBindingGate.refusal, Comment(rawValue: "\(name) at \(tier): \(result)"))
    }

    @Test("at .conversations the pinned rule still applies: an unpinned caller is refused (not offered, or the pinned refusal), never run",
          arguments: ["search_conversations", "read_conversation"])
    func pinnedRuleStillApplies(_ name: String) async throws {
        let result = try await dispatchResult(for: name, binding: binding(read: .conversations), pinned: false)
        #expect(result.contains("only available in a pinned conversation") || result.contains("not one of the tools offered"),
                Comment(rawValue: result))
        #expect(!result.contains(MemoryBindingGate.refusal), "the binding was not the reason")
    }

    @Test("at .conversations in a pinned conversation the call passes the gate",
          arguments: ["search_conversations", "read_conversation"])
    func conversationReadsAllowed(_ name: String) async throws {
        let result = try await dispatchResult(for: name, binding: binding(read: .conversations), pinned: true)
        #expect(!result.contains(MemoryBindingGate.refusal), Comment(rawValue: result))
    }

    @Test("an owner engine's reads are unchanged: the default binding refuses nothing")
    func ownerReadsUnchanged() async throws {
        let result = try await dispatchResult(for: "search_memory", args: ["scope": .string("all")], binding: nil)
        #expect(!result.contains(MemoryBindingGate.refusal), Comment(rawValue: result))
        #expect(result.contains("No relevant facts found."))
    }

    // MARK: a save_fact that never passes through the dispatcher

    /// `writeGoalLearnings` builds a synthetic `save_fact` and stores it directly when a goal passes.
    private func storedAfterGoalLearnings(binding: AccessBinding?) async throws -> Bool {
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let facts = try FactStoreManager(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-t7-gl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                                retryDelays: [], factStore: facts, protectionEnabled: false, sessionPeerCount: 0,
                                memory: MemoryManager(paths: IrisPaths(root: root)), binding: binding)
        let marker = "goal-learning-\(UUID().uuidString)"
        await engine.writeGoalLearnings(marker, conversationId: id)
        return !((try? facts.search(query: marker)) ?? []).isEmpty
    }

    @Test("a goal's learnings note is not stored under a binding below the fact-write tier")
    func goalLearningsRefusedBelowTier() async throws {
        #expect(try await storedAfterGoalLearnings(binding: binding(read: .full, write: .none)) == false)
        #expect(try await storedAfterGoalLearnings(binding: binding(write: .task)) == false)
    }

    @Test("a goal's learnings note is stored at .shared and for an owner")
    func goalLearningsStoredAtTier() async throws {
        #expect(try await storedAfterGoalLearnings(binding: binding(write: .shared)) == true)
        #expect(try await storedAfterGoalLearnings(binding: nil) == true)
    }

    // MARK: the seam

    @Test("bindingForCall is the engine's binding until a turn carries its own")
    func seamReturnsTheEnginesBinding() async {
        let b = binding(read: .shared, write: .task)
        let engine = IrisEngine(state: AppState(), tier: .medium, principal: .main, client: FakeLLMClient(responses: []),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0, binding: b)
        let got = await engine.bindingForCall(conversationId: UUID())
        #expect(got == b)
    }
}
