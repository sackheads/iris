import Testing
import Foundation
@testable import IrisKit

/// #256: a file tool is approved, allowlisted and run by one path — the one it touches. The
/// approval used to see the model's raw spelling while the executor resolved it against the
/// workspace, so a person could approve one path while the tool acted on another, and a rule
/// matching the literal relative string could approve a write that landed anywhere.
///
/// Every test works under a temp directory of its own and injects `PermissionManager(paths:)`
/// over an `IrisPaths(root:)` there (invariant 7): no global is written, and nothing reaches the
/// real allowlist or `~/.iris`. Temp directories sit under `/var`, a link to `/private/var`, so
/// the spelling a test writes is not the real path — which is exactly what these tests need.
@MainActor
@Suite("Approval judges the resolved path (#256)")
struct ApprovalResolvedPathTests {

    // MARK: fixtures

    private struct Fixture {
        let root: URL       // spelled through /var, as NSTemporaryDirectory gives it
        var workspace: URL { root.appendingPathComponent("ws") }
        var outside: URL { root.appendingPathComponent("outside") }
        var home: URL { root.appendingPathComponent("iris-home") }
        /// What the decider sees for `url`: its real path.
        func real(_ url: URL) -> String { IrisPaths.realPath(url.path) }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-256-\(UUID().uuidString)")
        let f = Fixture(root: root)
        for dir in [f.workspace, f.outside, f.home] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return f
    }

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func callResponse(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    /// An engine over an `AppState` of the test's own, the conversation bound to the fixture's
    /// workspace, and the model making exactly `call` once.
    private func harness(_ f: Fixture, call: GeminiResponse, background: Bool)
        throws -> (AppState, IrisEngine, UUID) {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: f.home))
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [call, textResponse("done.")]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let id = state.createNewConversation(isBackground: background, select: false)
        state.setWorkspace(for: id, path: f.workspace.path)
        return (state, engine, id)
    }

    private func write(_ path: String, _ content: String = "hello") -> GeminiResponse {
        callResponse("write_file", ["path": .string(path), "content": .string(content)])
    }

    /// One attended turn: waits (bounded) for the prompt, records what it showed, answers it.
    private func attendedTurn(_ f: Fixture, call: GeminiResponse, answer: AppState.ApprovalResolution)
        async throws -> (shown: String?, state: AppState, id: UUID) {
        let (state, engine, id) = try harness(f, call: call, background: false)
        let finished = Locked(false)
        let turn = Task { @MainActor in
            await engine.processInput("go", source: "UI", conversationId: id)
            finished.mutate { $0 = true }
        }
        var shown: String?
        for _ in 0..<1000 where !finished.value {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                shown = request.details
                state.resolveApproval(id: request.id, answer)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if shown == nil { state.denyPendingApprovals(for: id) }
        await turn.value
        return (shown, state, id)
    }

    // MARK: what the approval shows and the allowlist judges

    @Test("a relative path's approval shows the resolved absolute path, and the write lands there")
    func relativeApprovalShowsResolvedPath() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let target = f.workspace.appendingPathComponent("out.txt")

        let (shown, _, _) = try await attendedTurn(f, call: write("out.txt"), answer: .approve)

        #expect(shown == f.real(target), "the person is shown the file the tool will write")
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("Always allow saves the resolved path, so the rule names the file that was written")
    func alwaysAllowSavesResolvedPath() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let target = f.workspace.appendingPathComponent("out.txt")

        let (_, state, _) = try await attendedTurn(f, call: write("out.txt"), answer: .alwaysAllowGlobal)

        #expect(state.permissions.isAllowed(toolName: "write_file", details: f.real(target), workspace: nil))
        #expect(!state.permissions.isAllowed(toolName: "write_file", details: "out.txt", workspace: nil),
                "no rule for the bare relative spelling, which names no file")
    }

    @Test("an allowlisted absolute path is matched when the model sends it relative")
    func absoluteRuleMatchesRelativeCall() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let target = f.workspace.appendingPathComponent("out.txt")
        // Background: no human to ask, so only the allowlist can let the write through. The rule
        // is spelled through `/var`, as the user's dialog would have saved it before this fix.
        let (state, engine, id) = try harness(f, call: write("out.txt"), background: true)
        state.permissions.allowGlobally(toolName: "write_file", details: target.path)

        await engine.processInput("go", source: "job:test", conversationId: id)

        #expect(state.takeBackgroundDenials(for: id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("a rule matching the literal relative string no longer approves a write")
    func relativeRuleDoesNotApprove() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let (state, engine, id) = try harness(f, call: write("out.txt"), background: true)
        state.permissions.allowGlobally(toolName: "write_file", details: "out.txt")

        await engine.processInput("go", source: "job:test", conversationId: id)

        let denials = state.takeBackgroundDenials(for: id)
        #expect(denials.count == 1)
        #expect(denials.first?.args["path"]?.stringValue == f.real(f.workspace.appendingPathComponent("out.txt")),
                "the card records the path the call would have written")
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("out.txt").path))
    }

    @Test("a .. escape is judged at its resolved target, on the card and against the allowlist")
    func dotDotEscapeJudgedAtTarget() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let escape = "../outside/x.txt"
        let target = f.outside.appendingPathComponent("x.txt")

        // No rule: the denial names the real target, never the `..` spelling.
        let (state, engine, id) = try harness(f, call: write(escape), background: true)
        await engine.processInput("go", source: "job:test", conversationId: id)
        #expect(state.takeBackgroundDenials(for: id).first?.args["path"]?.stringValue == f.real(target))
        #expect(!FileManager.default.fileExists(atPath: target.path))

        // A rule for the target itself covers the escape, because that is the file it writes.
        let (state2, engine2, id2) = try harness(f, call: write(escape), background: true)
        state2.permissions.allowGlobally(toolName: "write_file", details: target.path)
        await engine2.processInput("go", source: "job:test", conversationId: id2)
        #expect(state2.takeBackgroundDenials(for: id2).isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("an attended .. escape shows the target outside the workspace")
    func dotDotEscapeShownAtTarget() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let (shown, _, _) = try await attendedTurn(f, call: write("../outside/x.txt"), answer: .deny)
        #expect(shown == f.real(f.outside.appendingPathComponent("x.txt")))
    }

    // MARK: execution uses the approved path

    @Test("a link in the workspace is shown at its target, and the write goes where the person approved")
    func symlinkExecutesApprovedPath() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let target = f.outside.appendingPathComponent("target.txt")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        let link = f.workspace.appendingPathComponent("ln.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let (shown, _, _) = try await attendedTurn(f, call: write("ln.txt", "approved"), answer: .approve)

        #expect(shown == f.real(target), "the approval names the file outside the workspace")
        // Run by its raw spelling, Foundation's atomic save would have replaced the link and left
        // the target alone: the approved file is the one that changed.
        #expect(try String(contentsOf: target, encoding: .utf8) == "approved")
        let linkAttributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(linkAttributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    // MARK: the probe cases

    @Test("a path containing NUL is refused before approval, and by the executor after a hook")
    func nulPathRefused() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let (shown, _, _) = try await attendedTurn(f, call: write("out.txt\u{0}../../x"), answer: .approve)
        #expect(shown == nil, "nobody is asked to approve a path the kernel would read differently")
        #expect(!FileManager.default.fileExists(atPath: f.workspace.appendingPathComponent("out.txt").path))
        let direct = await ToolExecutor().execute(name: "write_file",
                                                  args: ["path": .string(f.workspace.path + "/a\u{0}"), "content": .string("x")])
        #expect(direct == ToolExecutor.nulPathRefusal("write_file"))
    }

    @Test("a .. after a link is resolved as the kernel does: through the link first")
    func dotDotAfterLink() throws {
        let f = try fixture(); defer { f.tearDown() }
        let deep = f.outside.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.workspace.appendingPathComponent("link"), withDestinationURL: deep)
        // Lexically `link/../x.txt` is `ws/x.txt`; the kernel goes to `outside/x.txt`.
        #expect(IrisEngine.decidedPath("link/../x.txt", cwd: f.workspace.path, walked: false)
                == f.real(f.outside) + "/x.txt")
    }

    @Test("a dangling link as a write target is shown as the link, and the write is refused, not followed")
    func danglingLinkWrite() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let missing = f.outside.appendingPathComponent("missing.txt")
        let link = f.workspace.appendingPathComponent("d")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        let (shown, _, _) = try await attendedTurn(f, call: write("d", "here"), answer: .approve)

        #expect(shown == f.real(f.workspace) + "/d", "there is no target to show; the link is what is named")
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink, "the link is left alone")
        #expect(!FileManager.default.fileExists(atPath: missing.path), "nothing was created outside")
    }

    @Test("execution refuses a hook's rewrite, and a link swapped into the decided path")
    func executionRechecksDecidedPath() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let sub = f.workspace.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let decided = IrisEngine.decidedPath("sub/f.txt", cwd: f.workspace.path, walked: false)
        #expect(ToolExecutor.decidedPathRefusal("write_file", path: decided, cwd: nil, decided: decided) == nil)
        #expect(ToolExecutor.decidedPathRefusal("write_file", path: "sub/f.txt", cwd: f.real(f.workspace), decided: decided) == nil,
                "the same file, spelled relative to the same workspace")
        #expect(ToolExecutor.decidedPathRefusal("write_file", path: decided + ".other", cwd: nil, decided: decided) != nil,
                "a hook's rewrite is not what was approved")

        let executor = ToolExecutor()
        let wrote = await executor.execute(name: "write_file", args: ["path": .string(decided), "content": .string("ok")],
                                           decidedPath: decided)
        #expect(wrote == "Successfully wrote to \(decided)")
        #expect(await executor.execute(name: "read_file", args: ["path": .string(decided)], decidedPath: decided) == "ok")

        // The swap: `sub` becomes a link out after the decision.
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: f.outside)
        try "secret".write(to: f.outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let write = await executor.execute(name: "write_file", args: ["path": .string(decided), "content": .string("x")],
                                           decidedPath: decided)
        #expect(write.hasPrefix("Error writing file:") && write.contains("is a symlink now"), "\(write)")
        let read = await executor.execute(name: "read_file", args: ["path": .string(decided)], decidedPath: decided)
        #expect(read.hasPrefix("Error reading file:") && !read.contains("secret"), "\(read)")
        #expect(try String(contentsOf: f.outside.appendingPathComponent("f.txt"), encoding: .utf8) == "secret")
    }

    @Test("a writer racing a directory/link swap never lands outside (1500 attempts)")
    func raceWithSwapNeverEscapes() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let real = f.workspace.appendingPathComponent("real")
        let swap = f.workspace.appendingPathComponent("swap")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: swap, withDestinationURL: f.outside)
        let decided = IrisEngine.decidedPath("real/f.txt", cwd: f.workspace.path, walked: false)

        // What a sandboxed command with the workspace mounted can do: swap the two names, flat out.
        let stop = Locked(false)
        let swaps = Locked(0)
        let flipper = Thread {
            while !stop.value {
                if renamex_np(real.path, swap.path, UInt32(RENAME_SWAP)) == 0 { swaps.mutate { $0 += 1 } }
            }
        }
        flipper.start()
        let executor = ToolExecutor()
        var succeeded = 0
        for i in 0..<1500 {
            let result = await executor.execute(name: "write_file",
                                                args: ["path": .string(decided), "content": .string("\(i)")],
                                                decidedPath: decided)
            if result.hasPrefix("Successfully") { succeeded += 1 }
            #expect(!FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("f.txt").path),
                    "attempt \(i) wrote outside")
            if FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("f.txt").path) { break }
        }
        stop.mutate { $0 = true }
        while !flipper.isFinished { try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(swaps.value > 100, "the race was actually run (\(swaps.value) swaps)")
        let outside = try FileManager.default.contentsOfDirectory(atPath: f.outside.path)
        #expect(outside.isEmpty, "\(outside)")
        _ = succeeded   // some land in the real directory, under whichever name it has; none outside
    }

    @Test("Approve and run refuses a link swapped in between the card and the click")
    func approvedCardRefusesLateSwap() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let real = f.workspace.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        // A background run is denied; its card records the decided path.
        let (state, engine, id) = try harness(f, call: write("real/notes.md", "from the card"), background: true)
        await engine.processInput("go", source: "job:test", conversationId: id)
        let call = try #require(state.takeBackgroundDenials(for: id).first)
        let recorded = try #require(call.args["path"]?.stringValue)
        #expect(recorded == f.real(real) + "/notes.md")

        // Days later, before the click, `real` becomes a link somewhere else.
        try FileManager.default.removeItem(at: real)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: f.outside)

        let clickId = state.createNewConversation(isBackground: true, select: false)
        let result = await engine.executeApprovedCall(call, conversationId: clickId)

        #expect(result.hasPrefix("Error writing file:") && result.contains("is a symlink now"), "\(result)")
        #expect(!FileManager.default.fileExists(atPath: f.outside.appendingPathComponent("notes.md").path))
    }

    @Test("Approve and run still writes the approved path, including one recorded through /var")
    func approvedCardWritesApprovedPath() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let target = f.workspace.appendingPathComponent("card.md")
        let (state, engine, _) = try harness(f, call: textResponse("unused"), background: true)
        let clickId = state.createNewConversation(isBackground: true, select: false)
        // Spelled through `/var`, as a card recorded before #256 would have it.
        let call = BlockedCall(toolName: "write_file",
                               args: ["path": .string(target.path), "content": .string("clicked")],
                               cwd: f.workspace.path)
        let result = await engine.executeApprovedCall(call, conversationId: clickId)
        #expect(result.hasPrefix("Successfully wrote to "), "\(result)")
        #expect(try String(contentsOf: target, encoding: .utf8) == "clicked")
    }

    @Test("case: a protected directory and an allowlist rule match whatever the case, on a case-insensitive volume")
    func caseVariants() throws {
        let f = try fixture(); defer { f.tearDown() }
        let paths = IrisPaths(root: f.home)
        try paths.ensureDirectories()
        let permissions = PermissionManager(paths: paths)
        let shouted = IrisEngine.decidedPath(f.home.path + "/CONFIG/permissions.json", cwd: nil, walked: false)
        #expect(permissions.isProtectedWrite(toolName: "write_file", path: shouted))
        #expect(!permissions.isAllowed(toolName: "write_file", details: shouted, workspace: nil, isBackground: true))

        let caseSensitive = try f.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        let insensitive = try #require(caseSensitive as Bool?).isFalse
        permissions.allowGlobally(toolName: "write_file", details: f.workspace.path + "/NOTES.md")
        let lower = IrisEngine.decidedPath("notes.md", cwd: f.workspace.path, walked: false)
        #expect(permissions.isAllowed(toolName: "write_file", details: lower, workspace: nil) == insensitive,
                "one file on a case-insensitive volume, two on a case-sensitive one")
        // The existing part is already the on-disk case: `WS` is `ws`.
        #expect(IrisEngine.decidedPath(f.root.path + "/WS/a", cwd: nil, walked: false)
                == (insensitive ? f.real(f.workspace) + "/a" : IrisPaths.realPath(f.root.path) + "/WS/a"))
    }

    @Test("~ and the absolute home spelling resolve to one path, and a ~ rule matches it")
    func tildeAndAbsoluteAgree() throws {
        let f = try fixture(); defer { f.tearDown() }
        let name = "iris-256-never-\(UUID().uuidString).md"   // never created: nothing touches the home
        let tilde = IrisEngine.decidedPath("~/" + name, cwd: f.workspace.path, walked: false)
        let absolute = IrisEngine.decidedPath(NSHomeDirectory() + "/" + name, cwd: f.workspace.path, walked: false)
        #expect(tilde == absolute)
        #expect(tilde.hasPrefix("/"))
        let permissions = PermissionManager(paths: IrisPaths(root: f.home))
        permissions.allowGlobally(toolName: "read_file", details: "~/" + name)
        #expect(permissions.isAllowed(toolName: "read_file", details: absolute, workspace: nil))
    }

    @Test("a grader read that reaches its workspace only once resolved still asks: the walk decision is the spelling's")
    func graderPreApprovalNeedsTheWalk() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let notes = f.workspace.appendingPathComponent("notes.txt")
        try "n".write(to: notes, atomically: true, encoding: .utf8)
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: f.home))
        let cid = state.createNewConversation(isBackground: false, select: false)
        var contract = GoalContract(objective: "o", criteria: [Criterion(text: "c", kind: .qualitative)])
            .humanApproved(workspace: f.real(f.workspace))
        contract.lock()
        state.setGoalContract(for: cid, contract)
        state.setWorkspace(for: cid, path: f.real(f.workspace))

        func asks(walked: Bool) async -> Bool {
            let finished = Locked(false)
            let call = Task { @MainActor in
                defer { finished.mutate { $0 = true } }
                return await state.requestApproval(toolName: "read_file", details: f.real(notes),
                                                   workspace: f.real(f.workspace), conversationId: cid,
                                                   callerRole: .evaluator, vibecopEnabled: false,
                                                   graderReadWalked: walked)
            }
            var queued = false
            for _ in 0..<400 where !finished.value {
                if let r = state.pendingApprovals.first(where: { $0.conversationId == cid }) {
                    queued = true; state.resolveApproval(id: r.id, .deny); break
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if !queued { state.denyPendingApprovals(for: cid) }
            _ = await call.value
            return queued
        }
        // The same resolved path either way: spelled inside, the dispatcher walks it and it is
        // pre-approved; spelled `../ws/notes.txt` or through an outside link, it is not walked and asks.
        #expect(await asks(walked: true) == false)
        #expect(await asks(walked: false) == true)
    }

    // MARK: the pure pieces

    @Test("decidedPath: relative, tilde-free absolute, no workspace, and a walked call")
    func decidedPathCases() throws {
        let f = try fixture(); defer { f.tearDown() }
        let ws = f.workspace.path
        #expect(IrisEngine.decidedPath("a/b.txt", cwd: ws, walked: false) == f.real(f.workspace) + "/a/b.txt")
        #expect(IrisEngine.decidedPath("../outside/c", cwd: ws, walked: false) == f.real(f.outside) + "/c")
        // A walked call (a grant, a grader's approved workspace) keeps its spelling: the walk
        // follows no link and refuses `..` on its own.
        #expect(IrisEngine.decidedPath("../outside/c", cwd: ws, walked: true) == ws + "/../outside/c")
        // No workspace: the process directory, as Foundation would have opened it — absolute.
        let bare = IrisEngine.decidedPath("nowhere-\(UUID().uuidString)", cwd: nil, walked: false)
        #expect(bare.hasPrefix("/"))
        #expect(bare == IrisPaths.realPath(FileManager.default.currentDirectoryPath) + "/" + (bare as NSString).lastPathComponent)
    }

    @Test("decidedWatchPath resolves a relative watch against the workspace, to the directory stored")
    func decidedWatchPathCases() throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(IrisEngine.decidedWatchPath("../outside", cwd: f.workspace.path)
                == WatchRoot.canonical(f.outside.path))
        let missing = IrisEngine.decidedWatchPath("gone", cwd: f.workspace.path)
        #expect(missing == f.workspace.appendingPathComponent("gone").path)
    }

    @Test("rules in another spelling of the same file match; a relative global rule does not")
    func ruleSpellings() throws {
        let f = try fixture(); defer { f.tearDown() }
        let permissions = PermissionManager(paths: IrisPaths(root: f.home))
        let file = f.workspace.appendingPathComponent("notes.md")
        let resolved = f.real(file)

        permissions.allowGlobally(toolName: "read_file", details: file.path)   // through /var
        #expect(permissions.isAllowed(toolName: "read_file", details: resolved, workspace: nil))
        #expect(!permissions.isAllowed(toolName: "write_file", details: resolved, workspace: nil),
                "a rule is still per tool")

        permissions.allowInProject(toolName: "write_file", details: "notes.md", workspace: f.workspace.path)
        #expect(permissions.isAllowed(toolName: "write_file", details: resolved, workspace: f.workspace.path),
                "a project rule is relative to its own workspace")

        permissions.allowGlobally(toolName: "write_file", details: "other.md")
        #expect(!permissions.isAllowed(toolName: "write_file",
                                       details: f.real(f.workspace.appendingPathComponent("other.md")),
                                       workspace: nil),
                "a relative global rule names no directory")
    }

    @Test("the ~/.iris carve-out holds for a resolved path when the home is reached through a link")
    func irisDirMatchesRealPath() throws {
        let f = try fixture(); defer { f.tearDown() }
        let paths = IrisPaths(root: f.home)   // spelled through /var
        let note = f.home.appendingPathComponent("memory/note.md")
        #expect(paths.isUnderIrisDir(note.path))
        #expect(paths.isUnderIrisDir(f.real(note)), "the same file by its real path")
        #expect(!paths.isUnderIrisDir(f.real(f.workspace.appendingPathComponent("x"))))
    }
}

private extension Bool {
    var isFalse: Bool { !self }
}
