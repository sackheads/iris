import Testing
import Foundation
@testable import IrisKit

/// #1297 (verify-first): a job or watch is stamped, at CREATION, with the conversation's persisted access-profile
/// id (`AppState.persistedAccessProfileId`, which also walks a delegate up to its root), and the run resolves that
/// profile's binding (`JobBindingTests`). Only the run side was pinned; these pin the creation side, through the
/// engine's own `scheduleJob` and its own `executor` (the production wiring of `JobTools.accessProfileId`), for
/// both job-creation tools:
///   - an owner conversation has no persisted id, so its job is unstamped and runs as the owner;
///   - a profile-bound conversation stamps its profile, and so does a delegate of it;
///   - a stamp is never changed once set, and an unstamped job takes the stamp of the conversation that re-schedules it;
///   - a guest-STEERED `.main` turn has a stamped binding but no persisted id, so a job made through this function
///     is unstamped. That is not a license: such a creation is refused upstream (the guest-origin denylist, #1294),
///     and a confined guest-authored job would need the turn's binding snapshotted onto the job (an owner decision).
@MainActor
@Suite("a job or watch is stamped with the creating conversation's profile (#1297)", .serialized, .timeLimit(.minutes(2)))
struct JobCreationStampTests {
    @MainActor private struct World {
        let store: ConversationStore
        let state: AppState
        let engine: IrisEngine
        let base: URL
        func bind(_ conversation: UUID, to profile: String?) {
            state.conversations[state.conversations.firstIndex { $0.id == conversation }!].accessProfileId = profile
        }
        func conversation() -> UUID { let id = UUID(); state.createNewConversation(id: id); return id }
        func schedule(_ name: String, in conversation: UUID) async throws -> Job {
            let args = ScheduleJobArguments.parse(["prompt": .string("tidy \(name)"), "intervalSeconds": .int(600), "name": .string(name)])
            _ = await engine.scheduleJob(args, conversationId: conversation, sandboxAvailable: true, decidedProfile: .readOnly)
            return try #require(try store.ledger.jobs().first { $0.name == name && $0.createdInConversationId == conversation })
        }
        func watch(_ directory: String, in conversation: UUID) async throws -> Job {
            let dir = base.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var executor = await engine.executor
            executor.irisPaths = IrisPaths(root: base.appendingPathComponent("dot-iris"))
            executor.homeDirectory = base.appendingPathComponent("home").path
            _ = await executor.execute(name: "register_directory_watcher",
                                       args: ["path": .string(dir.path), "instructions": .string("summarise")], conversationId: conversation)
            return try #require(try store.ledger.jobs().first { $0.name == directory && $0.createdInConversationId == conversation })
        }
        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    private func world() throws -> World {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: []), protectionEnabled: false, sessionPeerCount: 0)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1297-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("dot-iris/config"), withIntermediateDirectories: true)
        return World(store: store, state: state, engine: engine, base: base)
    }

    @Test("an owner conversation's job and watch are unstamped; a profile-bound conversation's carry its profile")
    func ownerNilBoundProfile() async throws {
        let w = try world(); defer { w.tearDown() }
        let owner = w.conversation(), bound = w.conversation()
        w.bind(bound, to: "reviewer")
        #expect(try await w.schedule("owner-job", in: owner).accessProfileId == nil)
        #expect(try await w.schedule("bound-job", in: bound).accessProfileId == "reviewer")
        #expect(try await w.watch("owner-watch", in: owner).accessProfileId == nil)
        #expect(try await w.watch("bound-watch", in: bound).accessProfileId == "reviewer")
    }

    @Test("a delegate of a bound conversation inherits the root's profile, for both creation tools")
    func delegateInherits() async throws {
        let w = try world(); defer { w.tearDown() }
        let bound = w.conversation()
        w.bind(bound, to: "reviewer")
        let sub = w.state.createNewConversation(id: UUID(), isSubagent: true, title: "sub", select: false)
        w.state.linkDelegate(sub, of: bound)
        #expect(try await w.schedule("sub-job", in: sub).accessProfileId == "reviewer")
        #expect(try await w.watch("sub-watch", in: sub).accessProfileId == "reviewer")
    }

    @Test("a stamp is never changed once set; an unstamped job takes the re-scheduling conversation's stamp")
    func updateNeverChangesAStamp() async throws {
        let w = try world(); defer { w.tearDown() }
        let c = w.conversation()
        w.bind(c, to: "reviewer")
        #expect(try await w.schedule("keep", in: c).accessProfileId == "reviewer")
        w.bind(c, to: "other")
        #expect(try await w.schedule("keep", in: c).accessProfileId == "reviewer", "a re-schedule must not re-stamp")
        #expect(try await w.watch("keep-watch", in: c).accessProfileId == "other", "a fresh watch takes the conversation's profile now")
        w.bind(c, to: "reviewer")
        #expect(try await w.watch("keep-watch", in: c).accessProfileId == "other", "a re-registered watch keeps its stamp")

        let late = w.conversation()
        #expect(try await w.schedule("late", in: late).accessProfileId == nil)
        w.bind(late, to: "reviewer")
        #expect(try await w.schedule("late", in: late).accessProfileId == "reviewer", "an unstamped job takes the stamp on re-schedule (narrowing, never widening)")
    }

    @Test("a guest-steered conversation has no persisted id, so a job made through this function is unstamped (refused upstream, #1294)")
    func guestSteeredIsUnstamped() async throws {
        let w = try world(); defer { w.tearDown() }
        let steered = w.conversation()
        w.state.markGuestOriginTurn(steered)
        let guest = AccessBinding(profile: AccessProfile(), principal: .mcpGuest, isOwner: false).capped(by: PrincipalFloor.floor(for: .mcpGuest))
        w.state.markGuestSteeredBinding(guest, for: steered)
        #expect(try await w.schedule("steered-job", in: steered).accessProfileId == nil)
        #expect(try await w.watch("steered-watch", in: steered).accessProfileId == nil)
    }
}
