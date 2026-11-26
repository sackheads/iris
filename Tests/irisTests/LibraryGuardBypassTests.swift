import Testing
import Foundation
@testable import IrisKit

/// #1397 part 2 (Brian, 11-26): a `local` library's read that no on-device canary can judge blocks, and on a turn
/// the owner is at it offers to read it without tier 3: this read only, or the library until Iris restarts. Jobs,
/// guests, peers and headless runs keep the block; YOLO and Vibecop never answer it. Real `read_file` and
/// `run_command` turns through `IrisEngine`: the global engine is the default llama.cpp, unprovisioned in the test
/// home, and no canary is scoped, so nothing on the Mac can judge.
@MainActor
@Suite("a local library's read with no on-device canary offers the owner a bypass (#1397 part 2)",
       .serialized, .timeLimit(.minutes(1)))
struct LibraryGuardBypassTests {
    private struct PassingTier2: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1397b-\(UUID().uuidString)")
    private var storeFile: URL { dir.appendingPathComponent("library-guard.json") }
    private let marker = "NOTE-1397B-\(UUID().uuidString)"

    private func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// A note in a vault set to `local`, and the store naming it.
    private func vault() throws -> (note: URL, store: LibraryGuardStore) {
        let vault = dir.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let note = vault.appendingPathComponent("n.md")
        try "a note \(marker)\n".write(to: note, atomically: true, encoding: .utf8)
        let store = LibraryGuardStore(file: storeFile)
        store.set(root: vault.path, mode: .local)
        return (note, store)
    }

    private func newApp() throws -> AppState {
        AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                 tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
    }

    private struct Run {
        var result: String
        var asked: [ToolApprovalRequest]
        var tainted: Bool
    }

    /// One turn running `call` in `conversation` of `app`. A responder answers each bypass card with `answer`
    /// (nil: never answers, the test fails on the time limit if one is raised then) and records it.
    private func run(_ call: FunctionCall, app: AppState, conversation: UUID, store: LibraryGuardStore,
                     answer: AppState.ApprovalResolution? = nil) async throws -> Run {
        func reply(_ part: Part) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))], usageMetadata: nil)
        }
        let engine = IrisEngine(state: app, client: FakeLLMClient(responses: [reply(Part(functionCall: call)), reply(Part(text: "done"))]),
                                retryDelays: [], protectionEnabled: true, sessionPeerCount: 0, libraryGuard: store)
        var asked: [ToolApprovalRequest] = []
        let responder = Task { @MainActor in
            while !Task.isCancelled {
                if let request = app.pendingApprovals.first(where: { $0.guardBypass != nil }) {
                    asked.append(request)
                    if let answer { app.resolveApproval(id: request.id, answer) } else { app.resolveApproval(id: request.id, .deny) }
                } else if let request = app.pendingApprovals.first {
                    // The ordinary ask to run the tool (a read outside the workspace): the person approves it.
                    app.resolveApproval(id: request.id, .approve)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let health = GuardTierHealth()
        await GuardTierHealth.$scoped.withValue(health) {
            await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
                await AuxiliaryModelManager.$scopedEngines.withValue([:]) {
                    await engine.processInput("go", source: "UI", conversationId: conversation)
                }
            }
        }
        responder.cancel()
        let conv = try #require(app.conversations.first { $0.id == conversation })
        let result = conv.history.flatMap(\.parts).compactMap { part -> String? in
            guard case .string(let s)? = part.functionResponse?.response["result"] else { return nil }
            return s
        }.last ?? ""
        return Run(result: result, asked: asked, tainted: conv.hasUntrustedToolOutput)
    }

    private func read(_ file: URL) -> FunctionCall { FunctionCall(name: "read_file", args: ["path": .string(file.path)]) }

    @Test("the owner reads once unchecked: shown, still wrapped and tainting, and the next read asks again")
    func readOnce() async throws {
        defer { cleanup() }
        let (note, store) = try vault()
        let app = try newApp()
        let id = app.createNewConversation(isBackground: false, select: true)
        let first = try await run(read(note), app: app, conversation: id, store: store, answer: .approve)
        #expect(first.result.contains(marker), "\(first.result.prefix(400))")
        #expect(first.result.contains("<untrusted_context") && first.tainted)
        let card = try #require(first.asked.first)
        let root = try #require(store.root(for: note.path))
        #expect(card.humanOnly && !card.offersAlwaysAllow && card.guardBypass == .library(root: root))
        #expect(card.details.contains("isn't downloaded"), "the card names the cause: \(card.details)")
        let second = try await run(read(note), app: app, conversation: id, store: store, answer: .approve)
        #expect(second.asked.count == 1, "a read-once bypass isn't remembered, nor its verdict cached")
    }

    @Test("Deny keeps the block, which names the cause")
    func denyKeepsTheBlock() async throws {
        defer { cleanup() }
        let (note, store) = try vault()
        let app = try newApp()
        let id = app.createNewConversation(isBackground: false, select: true)
        let run = try await run(read(note), app: app, conversation: id, store: store, answer: .deny)
        #expect(run.asked.count == 1)
        #expect(!run.result.contains(marker) && run.result.contains("on-device checks only"), "\(run.result.prefix(400))")
    }

    @Test("until restart: the library reads unasked for the rest of the launch, and a relaunch asks again")
    func untilRestart() async throws {
        defer { cleanup() }
        let (note, store) = try vault()
        let app = try newApp()
        let id = app.createNewConversation(isBackground: false, select: true)
        let first = try await run(read(note), app: app, conversation: id, store: store, answer: .bypassGuardUntilRestart)
        #expect(first.result.contains(marker))
        let second = try await run(read(note), app: app, conversation: id, store: store)
        #expect(second.asked.isEmpty && second.result.contains(marker), "\(second.result.prefix(300))")
        let relaunched = try newApp()
        let rid = relaunched.createNewConversation(isBackground: false, select: true)
        let third = try await run(read(note), app: relaunched, conversation: rid, store: store, answer: .deny)
        #expect(third.asked.count == 1 && !third.result.contains(marker), "the scope is memory only")
    }

    @Test("a turn the owner isn't at keeps the block and asks nobody", arguments: ["job", "peer", "guest", "headless"])
    func unattendedTurnsBlock(_ kind: String) async throws {
        defer { cleanup() }
        let (note, store) = try vault()
        let app = try newApp()
        let id = app.createNewConversation(isBackground: kind == "job", select: kind != "job")
        // A job's read outside its workspace is refused before the guard; inside it, the guard is what decides.
        if let i = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[i].workspacePath = dir.path }
        switch kind {
        case "peer": app.notePeerInput(id)
        case "guest": app.markGuestOriginTurn(id)
        case "headless": app.autoApproveTools = true
        default: break
        }
        let run = try await run(read(note), app: app, conversation: id, store: store, answer: .approve)
        #expect(run.asked.isEmpty, "\(kind) was offered the bypass")
        // A job's read_file stops earlier, at the approval nobody is there to give; the rest reach the guard's block.
        #expect(!run.result.contains(marker) && (kind == "job" || run.result.contains("on-device checks only")),
                "\(kind): \(run.result.prefix(300))")
    }

    @Test("a job's turn is never owner-attended, so a bypass ask there answers no at once and shows nobody a card")
    func jobGetsNoCard() async throws {
        let app = try newApp()
        let job = app.createNewConversation(isBackground: true, select: false)
        let attended = app.createNewConversation(isBackground: false, select: true)
        #expect(!app.isOwnerAttended(job) && app.isOwnerAttended(attended))
        #expect(await app.requestGuardBypass(conversationId: job, path: "/v/n.md", cause: "", scope: .library(root: "/v")) == false)
        #expect(app.pendingApprovals.isEmpty)
    }

    @Test("an until-restart bypass serves only a turn the owner is at: a peer's turn on that library stays blocked")
    func bypassDoesNotReachAPeerTurn() async throws {
        defer { cleanup() }
        let (note, store) = try vault()
        let app = try newApp()
        let owner = app.createNewConversation(isBackground: false, select: true)
        _ = try await run(read(note), app: app, conversation: owner, store: store, answer: .bypassGuardUntilRestart)
        let peer = app.createNewConversation(isBackground: false, select: false)
        app.notePeerInput(peer)
        let run = try await run(read(note), app: app, conversation: peer, store: store, answer: .approve)
        #expect(run.asked.isEmpty && !run.result.contains(marker), "\(run.result.prefix(300))")
    }

    @Test("a bypassed read is re-judged at tier 2 only: never tier 3 again, whose global engine may be the cloud")
    func bypassReReadsAtTierTwo() async throws {
        defer { cleanup() }
        let (note, store) = try vault()
        let app = try newApp()
        let id = app.createNewConversation(isBackground: false, select: true)
        _ = try await run(read(note), app: app, conversation: id, store: store, answer: .bypassGuardUntilRestart)
        let engine = IrisEngine(state: app, client: FakeLLMClient(responses: []), retryDelays: [], protectionEnabled: true,
                                sessionPeerCount: 0, libraryGuard: store)
        #expect(await engine.onDeviceBypass(path: note.path, cause: "", unreadableFile: false, conversationId: id) == .tier2_coreML)
    }

    @Test("YOLO doesn't answer it: the owner is still asked")
    func yoloStillAsks() async throws {
        defer { cleanup() }
        let (note, store) = try vault()
        let app = try newApp()
        let id = app.createNewConversation(isBackground: false, select: true)
        app.setYoloMode(true, for: id)
        let run = try await run(read(note), app: app, conversation: id, store: store, answer: .deny)
        #expect(run.asked.count == 1 && !run.result.contains(marker))
    }

    @Test("with the list garbled, a command's output offers a bypass for all outside reads")
    func garbledListScopesAllReads() async throws {
        defer { cleanup() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{garbled".utf8).write(to: storeFile)
        let store = LibraryGuardStore(file: storeFile)
        let app = try newApp()
        let id = app.createNewConversation(isBackground: false, select: true)
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo \(marker)")])
        let first = try await run(call, app: app, conversation: id, store: store, answer: .bypassGuardUntilRestart)
        #expect(first.asked.first?.guardBypass == .allOutsideReads && first.result.contains(marker), "\(first.result.prefix(300))")
        #expect(first.asked.first?.details.contains("library-guard.json") == true)
        let second = try await run(call, app: app, conversation: id, store: store)
        #expect(second.asked.isEmpty && second.result.contains(marker))
    }
}
