import Testing
import Foundation
@testable import IrisKit

/// #600, end to end through `AppState.requestApproval`: with Vibecop answering APPROVE to
/// everything, a host command runs unprompted only when it is read-only, and after the person
/// denies a command in a conversation, nothing there runs unprompted again.
///
/// Every call passes `vibecopEnabled: true` and the verdict comes from a task-scoped engine, and
/// each test injects its own `PermissionManager` (Invariant 7).
@MainActor
@Suite("Host Vibecop approvals are read-only, and a Deny ends them (#600)", .timeLimit(.minutes(1)))
struct HostReadOnlyApprovalTests {

    private final class Approver: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var prompts: [String] = []
        var calls: Int { lock.withLock { count } }
        var lastPrompt: String { lock.withLock { prompts.last ?? "" } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { count += 1; prompts.append(prompt) }
            return #"{"decision":"APPROVE","reason":"routine"}"#
        }
    }

    private func app() throws -> (AppState, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-600-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: home))
        // A fixed host, so the developer's own PATH decides nothing here.
        state.hostLookupOverride = {
            ReadOnlyCommand.HostLookup(path: "/bin:/usr/bin", cwd: "/tmp", home: home.path,
                                       isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        }
        return (state, home)
    }

    enum Outcome: Equatable { case silent(Bool), asked }

    @MainActor private final class Done { var value = false }

    /// Runs one call with Vibecop approving. If it reaches the prompt it is answered with `answer`
    /// and reported `.asked`; if it returns first, its own result is reported as `.silent`. Bounded:
    /// a call that does neither within 2 s is denied, so a regression fails rather than hangs.
    private func call(_ state: AppState, _ details: String, tool: String = "run_command", in cid: UUID,
                      inSandbox: Bool = false, answer: AppState.ApprovalResolution = .deny,
                      engine: Approver) async throws -> Outcome {
        let done = Done()
        let task = Task { @MainActor in
            let approved = await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
                await state.requestApproval(toolName: tool, details: details, workspace: nil, conversationId: cid,
                                            inSandbox: inSandbox, vibecopEnabled: true)
            }
            done.value = true
            return approved
        }
        for _ in 0..<400 {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == cid }) {
                state.resolveApproval(id: request.id, answer)
                _ = try await value(of: task)
                return .asked
            }
            if done.value { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        state.denyPendingApprovals(for: cid)
        return .silent(try await value(of: task))
    }

    @Test("the #600 sequence: a touch is asked and denied; the next touch and the rm -f are asked too")
    func the600Sequence() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let vibecop = Approver()

        #expect(try await call(state, "touch ~/rm562-probe.txt", in: cid, engine: vibecop) == .asked)
        #expect(try await call(state, "touch ~/rm562-probe2.txt", in: cid, engine: vibecop) == .asked)
        #expect(try await call(state, "rm -f ~/rm562-probe2.txt", in: cid, engine: vibecop) == .asked)
        #expect(vibecop.calls == 3, "Vibecop is still consulted; its APPROVE is what no longer runs these")
    }

    @Test("before any Deny, Vibecop's APPROVE runs a host read unprompted, but not a host write")
    func readsOnlyOnTheHost() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let vibecop = Approver()

        #expect(try await call(state, "ls -la", in: cid, engine: vibecop) == .silent(true))
        #expect(try await call(state, "cat /etc/hosts", in: cid, engine: vibecop) == .silent(true))
        #expect(try await call(state, "/etc/hosts", tool: "read_file", in: cid, engine: vibecop) == .silent(true))
        // Approved by the person, so no Deny is remembered: the next read is still unprompted.
        #expect(try await call(state, "touch x", in: cid, answer: .approve, engine: vibecop) == .asked)
        #expect(try await call(state, "/tmp/x", tool: "write_file", in: cid, answer: .approve, engine: vibecop) == .asked)
        #expect(try await call(state, "ls", in: cid, engine: vibecop) == .silent(true))
    }

    @Test("Vibecop is told its host APPROVE only runs reads, and is not told so in the VM")
    func promptSaysSo() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let vibecop = Approver()
        _ = try await call(state, "ls", in: cid, engine: vibecop)
        #expect(vibecop.lastPrompt.contains(VibecopService.hostLayerText))
        _ = try await call(state, "ls", in: cid, inSandbox: true, engine: vibecop)
        #expect(!vibecop.lastPrompt.contains(VibecopService.hostLayerText))
        #expect(vibecop.lastPrompt.contains("disposable, network-capable Linux VM"))
    }

    @Test("in the VM, Vibecop's APPROVE still runs a write unprompted")
    func inVMUnchanged() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        #expect(try await call(state, "rm -f x", in: cid, inSandbox: true, engine: Approver()) == .silent(true))
    }

    @Test("after a Deny, no command in that conversation runs unprompted, read or in-VM; other conversations are untouched")
    func denyEndsSilentApprovals() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let other = state.createNewConversation(isBackground: false, select: false)
        let vibecop = Approver()

        #expect(try await call(state, "touch x", in: cid, engine: vibecop) == .asked)
        #expect(state.commandDenied(in: cid))
        #expect(try await call(state, "ls", in: cid, engine: vibecop) == .asked)
        #expect(try await call(state, "rm -f x", in: cid, inSandbox: true, engine: vibecop) == .asked)
        #expect(try await call(state, "ls", in: other, engine: vibecop) == .silent(true))
        // A file read is not a command: the memory is about run_command.
        #expect(try await call(state, "/etc/hosts", tool: "read_file", in: cid, engine: vibecop) == .silent(true))
    }

    @Test("the allowlist still approves after a Deny, since the person set it")
    func allowlistSurvivesDeny() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let vibecop = Approver()
        #expect(try await call(state, "touch x", in: cid, engine: vibecop) == .asked)
        let command = "make --allowed-\(UUID().uuidString)"
        state.permissions.allowGlobally(toolName: "run_command", details: command)
        #expect(try await call(state, command, in: cid, engine: vibecop) == .silent(true))
    }

    @Test("a subagent's Deny counts for the conversation it works for, and the other way round")
    func denyRollsUpToTheRoot() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = state.createNewConversation(isBackground: false, select: false)
        let child = state.createNewConversation(isSubagent: true, select: false)
        state.linkDelegate(child, of: root)
        let vibecop = Approver()
        #expect(try await call(state, "ls", in: root, engine: vibecop) == .silent(true))
        #expect(try await call(state, "touch x", in: child, engine: vibecop) == .asked)
        #expect(try await call(state, "ls", in: root, engine: vibecop) == .asked)
    }

    @Test("Stop resolving a request false is not a Deny, so nothing is remembered")
    func stopIsNotADeny() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let vibecop = Approver()
        let task = Task { @MainActor in
            await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
                await state.requestApproval(toolName: "run_command", details: "touch x", workspace: nil,
                                            conversationId: cid, vibecopEnabled: true)
            }
        }
        for _ in 0..<400 where !state.pendingApprovals.contains(where: { $0.conversationId == cid }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        state.denyPendingApprovals(for: cid)
        #expect(try await value(of: task) == false)
        #expect(!state.commandDenied(in: cid))
        #expect(try await call(state, "ls", in: cid, engine: vibecop) == .silent(true))
    }

    @Test("a damaged writable-roots record turns the silent restricted read off: the person is asked, and told once (#616)")
    func damagedRecordAsks() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        state.writableRoots = WritableRootsRecord(paths: IrisPaths(root: home))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("\"/ok\"\n\"/torn".utf8).write(to: state.writableRoots.url)   // a write cut short
        let cid = state.createNewConversation(isBackground: false, select: true)
        #expect(try await call(state, "ls", in: cid, engine: Approver()) == .asked)
        _ = state.writableRootsDamaged()
        let notice = AppState.writableRootsDamagedNotice(state.writableRoots.url.path)
        #expect(state.conversations.first { $0.id == cid }?.messages.filter { $0.content == notice }.count == 1)
    }

    @Test("the approval names its source: a host read is restricted to the judged PATH, the person's click is the person's")
    func sources() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let vibecop = Approver()
        let read = await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            await state.requestApprovalSource(toolName: "run_command", details: "ls -la", workspace: nil,
                                              conversationId: cid, vibecopEnabled: true)
        }
        #expect(read == .vibecopRestricted(path: ["/bin", "/usr/bin"], reason: "routine"))
        let inVM = await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": vibecop]) {
            await state.requestApprovalSource(toolName: "run_command", details: "make", workspace: nil,
                                              conversationId: cid, inSandbox: true, vibecopEnabled: true)
        }
        #expect(inVM == .vibecop(reason: "routine"))
        let command = "make --allowed-\(UUID().uuidString)"
        state.permissions.allowGlobally(toolName: "run_command", details: command)
        let allowed = await state.requestApprovalSource(toolName: "run_command", details: command, workspace: nil,
                                                        conversationId: cid, vibecopEnabled: true)
        #expect(allowed == .allowlist(AllowMatch(scope: .global, rule: PermissionRule(toolName: "run_command", details: command))))
        let task = Task { @MainActor in
            await state.requestApprovalSource(toolName: "run_command", details: "make", workspace: nil,
                                              conversationId: cid, vibecopEnabled: false)
        }
        for _ in 0..<400 where !state.pendingApprovals.contains(where: { $0.conversationId == cid }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if let request = state.pendingApprovals.first { state.resolveApproval(id: request.id, .approve) }
        #expect(try await value(of: task) == .person)
    }

    @Test("every conversation's workspace and every grant's read-write mount count as sandbox-writable")
    func writableRoots() throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let a = state.createNewConversation(isBackground: false, select: false)
        state.setWorkspace(for: a, path: "/tmp/ws-a")
        let b = state.createNewConversation(isBackground: true, select: false)
        let index = try #require(state.conversations.firstIndex { $0.id == b })
        state.conversations[index].sandboxGrant = JobGrant(mounts: [ContainerMount(source: "/tmp/rw"),
                                                                    ContainerMount(source: "/tmp/ro", readOnly: true)],
                                                           network: false)
        let roots = Set(state.sandboxWritableRoots())
        #expect(roots.isSuperset(of: ["/tmp/ws-a", "/tmp/rw"]))
        #expect(!roots.contains("/tmp/ro"))
    }

    @Test("through the engine: a read Vibecop approves runs with the judged PATH, and a person's approval runs as usual")
    func restrictedThroughTheEngine() async throws {
        // The judged PATH is /usr/bin alone, so a restricted `which ls` (a zsh builtin) cannot find
        // /bin/ls, and a usual run can. Only the dispatcher and executor carrying the PATH tell them apart.
        func run(vibecop: Bool) async throws -> String {
            let (state, home) = try app()
            defer { try? FileManager.default.removeItem(at: home) }
            state.hostLookupOverride = {
                ReadOnlyCommand.HostLookup(path: "/usr/bin", cwd: "/tmp", home: home.path,
                                           isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
            }
            state.vibecopEnabledOverride = vibecop
            let cid = state.createNewConversation(isBackground: false, select: false)
            let call = FunctionCall(name: "run_command", args: ["command": .string("which ls")], id: "c1")
            let client = ScriptedStreamClient([[.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))],
                                               [.event(.textDelta("done")), .event(.done(finishReason: "STOP"))]])
            let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, streamResponses: true)
            let turn = Task { @MainActor in
                await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": Approver()]) {
                    await engine.processInput("run it", source: "User", conversationId: cid)
                }
            }
            if !vibecop {
                for _ in 0..<400 where !state.pendingApprovals.contains(where: { $0.conversationId == cid }) {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                if let request = state.pendingApprovals.first { state.resolveApproval(id: request.id, .approve) }
            }
            _ = try await value(of: turn, within: 30)
            let sent = try #require(client.requests.last)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: try encoder.encode(sent), as: UTF8.self)
        }
        let restricted = try await run(vibecop: true)
        #expect(restricted.contains("ls not found"), "the gate's approval ran unrestricted")
        let usual = try await run(vibecop: false)
        #expect(usual.contains("/bin/ls"), "a person's approval ran restricted")
    }
}
