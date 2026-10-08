import Testing
import Foundation
@testable import IrisKit

/// #337 and #339: a grader lists its approved workspace with `read_file` instead of `ls` (which
/// asks), and a pre-approved grader read is opened by the #282 descriptor walk from the approved
/// root — never by path — so a symlink swapped in after the gate cannot redirect it.
///
/// Temp directories only: `proj` is the approved workspace, `other` a sibling outside it holding
/// a secret that must never come back. Isolated `AppState` and `PermissionManager`; nothing
/// touches `ConfigManager.shared` or the real `~/.iris` (invariant 7).
@MainActor
@Suite("Grader reads: directory listings and the descriptor walk (#337, #339)")
struct GraderWorkspaceReadTests {
    nonisolated static let check = "swift test --filter Foo"

    struct Fixture {
        let home: URL
        var proj: URL { home.appendingPathComponent("proj") }
        var other: URL { home.appendingPathComponent("other") }
        func tearDown() { try? FileManager.default.removeItem(at: home) }
    }

    /// `proj/notes.txt`, `proj/sub/inner.txt`, `other/secret.txt`, `other/sub/inner.txt` (the
    /// file a swapped `sub` would expose), and `proj/escape` → `other/secret.txt`.
    private func fixture() throws -> Fixture {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("iris-grader-read-\(UUID().uuidString)", isDirectory: true)
        let f = Fixture(home: home)
        for dir in [f.proj.appendingPathComponent("sub"), f.other.appendingPathComponent("sub"),
                    home.appendingPathComponent("iris")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "notes".write(to: f.proj.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "inner".write(to: f.proj.appendingPathComponent("sub/inner.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: f.other.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "SECRET-INNER".write(to: f.other.appendingPathComponent("sub/inner.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: f.proj.appendingPathComponent("escape"),
                                  withDestinationURL: f.other.appendingPathComponent("secret.txt"))
        return f
    }

    private func lockedContract(in workspace: URL) -> GoalContract {
        var c = GoalContract(objective: "make Foo pass",
                             criteria: [Criterion(text: "passes", kind: .executable, check: Self.check)])
            .humanApproved(workspace: workspace.path)
        c.lock()
        return c
    }

    private func app(_ f: Fixture) throws -> AppState {
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: f.home.appendingPathComponent("iris")))
        return state
    }

    /// Did `details` ask? Bounded: a queued prompt is denied at once, and anything still pending
    /// after ~2s is denied, so a regression fails rather than hangs.
    private func asks(_ details: String, role: VibecopCallerRole = .evaluator, in f: Fixture) async throws -> Bool {
        let state = try app(f)
        let cid = state.createNewConversation(isBackground: false, select: false)
        state.setGoalContract(for: cid, lockedContract(in: f.proj))
        state.setWorkspace(for: cid, path: f.proj.path)
        let finished = Locked(false)
        let call = Task { @MainActor in
            defer { finished.mutate { $0 = true } }
            return await state.requestApproval(toolName: "read_file", details: details, workspace: f.proj.path,
                                               conversationId: cid, callerRole: role, vibecopEnabled: false)
        }
        var queued = false
        for _ in 0..<400 {
            if finished.value { break }
            if state.pendingApprovals.contains(where: { $0.conversationId == cid }) { queued = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if queued { state.resolveApproval(id: state.pendingApprovals[0].id, .deny) } else { state.denyPendingApprovals(for: cid) }
        let approved = await call.value
        #expect(queued || approved, "unasked means approved")
        return queued
    }

    /// What the executor returns for a grader read the dispatcher handed the approved root.
    private func walkedRead(_ path: String, root: URL) async -> String {
        await ToolExecutor().execute(name: "read_file", args: ["path": .string(path)], cwd: root.path,
                                     approvedWorkspaceRoot: IrisPaths.canonicalPath(root.path))
    }

    // MARK: #337 — a listing with no prompt

    @Test("a grader reading the approved workspace directory gets a listing, with no prompt")
    func workspaceListingUnasked() async throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(try await asks(f.proj.path, in: f) == false)
        #expect(try await asks(".", in: f) == false, "relative: the grader's own directory")
        let listing = await walkedRead(".", root: f.proj)
        // Sorted, one level, directories marked; the escape link is listed as itself, not followed.
        let lines = listing.split(separator: "\n").dropFirst().map(String.init)
        #expect(listing.hasPrefix("Directory listing: 3 entries"), "\(listing)")
        #expect(lines == ["escape", "notes.txt", "sub/"])
        #expect(!listing.contains("inner.txt"), "one level only")
    }

    @Test("a subdirectory of the approved workspace lists too, unasked")
    func subdirectoryListing() async throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(try await asks(f.proj.appendingPathComponent("sub").path, in: f) == false)
        #expect(try await asks("sub", in: f) == false)
        let listing = await walkedRead("sub", root: f.proj)
        #expect(listing.hasSuffix("\ninner.txt\n"), "\(listing)")
    }

    @Test("a directory outside the approved workspace asks")
    func outsideDirectoryAsks() async throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(try await asks(f.other.path, in: f))
        #expect(try await asks(f.home.path, in: f), "the workspace's parent is outside it")
        #expect(try await asks("..", in: f))
        #expect(try await asks("/", in: f))
    }

    @Test("an agent-role directory read still goes through normal approval, and gets the listing once approved")
    func agentDirectoryReadAsks() async throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(try await asks(f.proj.path, role: .agent, in: f))
        // No approved root is handed to an agent's read: the ordinary path, which lists too.
        let listing = await ToolExecutor().execute(name: "read_file", args: ["path": .string(f.proj.path)])
        #expect(listing.hasPrefix("Directory listing: 3 entries"), "\(listing)")
        #expect(listing.contains("\nsub/\n"))
    }

    @Test("the listing is byte-capped, and a name with a newline cannot forge an entry")
    func cappedAndFlattened() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let forged = "evil\nnotes.txt"
        try "x".write(to: f.proj.appendingPathComponent(forged), atomically: true, encoding: .utf8)
        let listing = await walkedRead(".", root: f.proj)
        #expect(listing.contains("\nevil\\nnotes.txt\n"), "\(listing)")
        #expect(listing.components(separatedBy: "\n").filter { $0 == "notes.txt" }.count == 1,
                "only the real notes.txt is a line of its own")
        #expect(DirectoryListing.flatten("a\\nb\r\t\u{2028}\u{202E}") == "a\\\\nb\\r\\t\\u{2028}\\u{202e}",
                "a backslash is doubled, so an escape cannot be spelled by a name")

        let many = (0..<5_000).map { DirectoryListing.Entry(name: String(format: "file-%05d.txt", $0), isDirectory: false) }
        let capped = DirectoryListing.format(many)
        let body = capped.split(separator: "\n").dropFirst().filter { $0.hasPrefix("file-") }
        #expect(body.reduce(0) { $0 + $1.utf8.count + 1 } <= DirectoryListing.maxBytes)
        #expect(body.count < 5_000)
        #expect(capped.contains("\(5_000 - body.count) more not shown"), "the cap says how much it hid")
        #expect(capped.hasPrefix("Directory listing: 5000 entries"))
    }

    // MARK: #339 — opened by descriptor, from the approved root

    @Test("a normal in-workspace read works through the walk")
    func normalReadWorks() async throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(await walkedRead("notes.txt", root: f.proj) == "notes")
        #expect(await walkedRead(f.proj.appendingPathComponent("sub/inner.txt").path, root: f.proj) == "inner")
    }

    @Test("a symlink that leads outside is refused: it asks at the gate, and the walk will not follow it")
    func symlinkOutsideRefused() async throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(try await asks("escape", in: f))
        let result = await walkedRead("escape", root: f.proj)
        #expect(result.hasPrefix("Error reading file:") && result.contains("symlink"), "\(result)")
        #expect(!result.contains("secret"))
    }

    @Test("a symlink that stays inside is refused by the walk too (documented: refusing is the safe side)")
    func symlinkInsideRefused() async throws {
        let f = try fixture(); defer { f.tearDown() }
        try FileManager.default.createSymbolicLink(at: f.proj.appendingPathComponent("alias"),
                                                   withDestinationURL: f.proj.appendingPathComponent("notes.txt"))
        let result = await walkedRead("alias", root: f.proj)
        #expect(result.contains("crosses a symlink at `alias`; the grader may not read through symlinks"), "\(result)")
    }

    @Test("a swap between the gate and the open is refused, for a file and for a listing")
    func swapBetweenCheckAndOpenRefused() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let contract = lockedContract(in: f.proj)
        let file = f.proj.appendingPathComponent("sub/inner.txt").path
        let dir = f.proj.appendingPathComponent("sub").path
        // The gate, with `sub` a real directory inside the workspace: pre-approved.
        #expect(contract.isHumanApprovedRead(file))
        #expect(contract.isHumanApprovedRead(dir))
        #expect(contract.approvedReadComponents(of: file) == ["sub", "inner.txt"])
        // Then `sub` is swapped for a link to `other/sub`, as a background command could.
        try FileManager.default.removeItem(at: f.proj.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: f.proj.appendingPathComponent("sub"),
                                                   withDestinationURL: f.other.appendingPathComponent("sub"))
        // The decision the dispatcher makes is by spelling and does not move with the link...
        #expect(contract.approvedReadComponents(of: file) == ["sub", "inner.txt"])
        // ...and the open is the walk, which meets the link rather than following it.
        let read = await walkedRead(file, root: f.proj)
        #expect(read.contains("symlink at `sub`"), "\(read)")
        #expect(!read.contains("SECRET-INNER"))
        let listing = await walkedRead(dir, root: f.proj)
        #expect(listing.contains("symlink"), "\(listing)")
        #expect(!listing.contains("inner.txt"))
    }

    @Test("a path rewritten out of the approved workspace after the decision is refused, not opened by path")
    func rewrittenOutsideRefused() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let result = await walkedRead(f.other.appendingPathComponent("secret.txt").path, root: f.proj)
        #expect(result.hasPrefix("Error: the path is not inside the approved workspace"))
        #expect(!result.contains("secret\n") && result != "secret")
    }

    @Test("a path that only reaches the workspace through a link from outside asks (#339 narrowed it)")
    func linkFromOutsideAsks() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let link = f.home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.proj)
        #expect(try await asks(link.appendingPathComponent("notes.txt").path, in: f))
    }

    @Test("the approved components are by spelling: dot, the /private firmlink, and dot-dot")
    func componentsBySpelling() {
        #expect(GoalContract.workspaceComponents(of: "/tmp/ws/./a//b", under: "/tmp/ws") == ["a", "b"])
        #expect(GoalContract.workspaceComponents(of: "/private/tmp/ws/a", under: "/tmp/ws") == ["a"])
        #expect(GoalContract.workspaceComponents(of: "/tmp/ws", under: "/tmp/ws") == [])
        #expect(GoalContract.workspaceComponents(of: "/tmp/ws/../ws/a", under: "/tmp/ws") == nil)
        #expect(GoalContract.workspaceComponents(of: "/tmp/wsx/a", under: "/tmp/ws") == nil)
        #expect(GoalContract.workspaceComponents(of: "/private/home/a", under: "/home") == nil,
                "only /tmp, /var and /etc live under /private")
        #expect(GoalContract.workspaceComponents(of: "ws/a", under: "/tmp/ws") == nil, "relative is not spelled under anything")
        let unlocked = GoalContract(objective: "o", criteria: []).humanApproved(workspace: "/tmp/ws")
        #expect(unlocked.approvedReadComponents(of: "/tmp/ws/a") == nil, "an unlocked contract pre-approves nothing")
    }

    // MARK: Through the dispatcher

    /// Reads each path in turn, then submits; records every tool result it is handed back.
    private final class ReadingGrader: LLMClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var seen: [String] = []
        let paths: [String]
        let criterionId: UUID
        init(paths: [String], criterionId: UUID) { self.paths = paths; self.criterionId = criterionId }
        var results: [String] { lock.withLock { seen } }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            let n = lock.withLock { () -> Int in
                calls += 1
                if let last = request.contents.last {
                    for part in last.parts {
                        if let response = part.functionResponse { seen.append("\(response.response)") }
                    }
                }
                return calls
            }
            let fc: FunctionCall
            if n <= paths.count {
                fc = FunctionCall(name: "read_file", args: ["path": .string(paths[n - 1])],
                                  id: nil, thought_signature: nil, thoughtSignature: nil)
            } else {
                fc = FunctionCall(name: "submit_evaluation", args: ["evaluations": .array([
                    .object(["criterion_id": .string(criterionId.uuidString),
                             "verdict": .string("met"), "evidence": .string("read it")])
                ])], id: nil, thought_signature: nil, thoughtSignature: nil)
            }
            let part = Part(text: nil, functionCall: fc, functionResponse: nil,
                            thought_signature: nil, thoughtSignature: nil)
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                                  usageMetadata: nil)
        }
    }

    @Test("a workspace reached through a symlinked prefix: approve, then grade, and the grader's reads ask nothing (#359 review)")
    func symlinkedPrefixWorkspaceReadsUnasked() async throws {
        let f = try fixture(); defer { f.tearDown() }
        // `src` → `home`, as `~/src` → `/Volumes/…`: the owner's workspace is `src/proj`.
        let src = f.home.appendingPathComponent("src")
        try FileManager.default.createSymbolicLink(at: src, withDestinationURL: f.home)
        let spelled = src.appendingPathComponent("proj").path
        try ".".write(to: f.proj.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        let state = try app(f)
        let originId = state.createNewConversation(isBackground: false, select: false)
        var contract = GoalContract(objective: "o", criteria: [Criterion(text: "c", kind: .executable, check: Self.check)])
            .humanApproved(workspace: spelled)
        contract.lock()
        #expect(contract.approvedWorkspace == IrisPaths.canonicalPath(f.proj.path))
        #expect(GoalEvaluator.gradingDirectory(spelled, contract: contract) == contract.approvedWorkspace)
        #expect(GoalEvaluator.gradingDirectory(f.other.path, contract: contract) == f.other.path,
                "a workspace moved elsewhere keeps its own spelling, and so still asks")
        let qualitative = Criterion(text: "reads well", kind: .qualitative)
        contract.criteria.append(qualitative)
        // Every prompt is denied and counted: a read that asks fails here instead of hanging.
        let asked = Locked(0)
        let done = Locked(false)
        let watcher = Task { @MainActor in
            while !done.value {
                if let pending = state.pendingApprovals.first {
                    asked.mutate { $0 += 1 }
                    state.resolveApproval(id: pending.id, .deny)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        // The third read spells the directory as the grader is now told it (the approved spelling);
        // an absolute path through the link still asks, as any path reaching in through a link does.
        let told = try #require(contract.approvedWorkspace)
        let grader = ReadingGrader(paths: [".", "notes.txt", told + "/sub/inner.txt"], criterionId: qualitative.id)
        _ = await GoalEvaluator.shared.evaluate(contract: contract, workspace: spelled,
                                                originatingConversationId: originId, app: state, client: grader)
        done.mutate { $0 = true }
        await watcher.value
        #expect(asked.value == 0, "a read of the approved workspace asked")
        let results = grader.results
        #expect(results.count == 3, "\(results)")
        guard results.count == 3 else { return }
        #expect(results[0].contains("Directory listing: 4 entries") && results[0].contains(".hidden"), "\(results[0])")
        #expect(results[1].contains("notes"))
        #expect(results[2].contains("inner") && !results[2].contains("Error"), "\(results[2])")
    }

    @Test("the grader's dispatcher walks its workspace reads: a listing comes back, and a swapped link is not followed")
    func dispatcherWalksGraderReads() async throws {
        let f = try fixture(); defer { f.tearDown() }
        // `sub` is a link out before the grader ever runs; even with every approval granted
        // (headless auto-approve), a read spelled inside the workspace is walked, never opened by path.
        try FileManager.default.removeItem(at: f.proj.appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: f.proj.appendingPathComponent("sub"),
                                                   withDestinationURL: f.other.appendingPathComponent("sub"))
        let state = try app(f)
        state.autoApproveTools = true
        let originId = state.createNewConversation(isBackground: false, select: false)
        var contract = lockedContract(in: f.proj)
        let qualitative = Criterion(text: "reads well", kind: .qualitative)
        contract.criteria.append(qualitative)
        let grader = ReadingGrader(paths: [".", "notes.txt", "sub/inner.txt"], criterionId: qualitative.id)
        _ = await GoalEvaluator.shared.evaluate(contract: contract, workspace: f.proj.path,
                                                originatingConversationId: originId, app: state, client: grader)
        let results = grader.results
        #expect(results.count == 3, "\(results)")
        guard results.count == 3 else { return }
        #expect(results[0].contains("Directory listing: 3 entries"), "\(results[0])")
        #expect(results[1].contains("notes"))
        #expect(results[2].contains("symlink at `sub`"), "\(results[2])")
        #expect(!results.joined().contains("SECRET-INNER"))
    }
}
