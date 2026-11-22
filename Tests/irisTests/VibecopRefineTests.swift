import Testing
import Foundation
@testable import IrisKit

/// #1278: `/vibecop refine` proposes appended `.iris/vibecop.md` lines from the person's own approvals in
/// the workspace, and writes them only on the person's click.
@MainActor
@Suite("/vibecop refine proposes rules from your own approvals (#1278)", .serialized, .timeLimit(.minutes(1)))
struct VibecopRefineTests {
    private struct World {
        let root: URL
        let ws: String
        let state: AppState
        let cid: UUID
        var file: URL { URL(fileURLWithPath: ws).appendingPathComponent(".iris/vibecop.md") }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func world(existing: String? = nil) throws -> World {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1278-\(UUID().uuidString)")
        let ws = root.appendingPathComponent("ws").path
        try FileManager.default.createDirectory(atPath: ws + "/.iris", withIntermediateDirectories: true)
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: root.appendingPathComponent("iris-home")))
        if let existing {
            let data = Data(existing.utf8)
            try data.write(to: URL(fileURLWithPath: ws + "/.iris/vibecop.md"))
            WorkspaceIrisTrust(paths: state.permissions.paths).recordWritten("vibecop.md", workspace: ws, written: data)
        }
        let cid = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: cid, path: ws)
        return World(root: root, ws: ws, state: state, cid: cid)
    }

    private static func pill(_ command: String, _ layer: ToolApproval.Layer?) -> ChatMessage {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["name": "run_command", "args": ["command": command]]),
                          as: UTF8.self)
        var m = ChatMessage(role: .system, content: ToolCallParser.prefix + json)
        m.approval = layer.map { ToolApproval(layer: $0) }
        return m
    }

    private func add(_ pills: [ChatMessage], to id: UUID, in state: AppState) {
        let i = state.conversations.firstIndex { $0.id == id }!
        state.conversations[i].messages += pills
    }

    private func said(_ w: World) -> [String] {
        w.state.conversations.first { $0.id == w.cid }?.messages.filter { $0.role == .command }
            .map(\.content) ?? []
    }

    private func waitForCard(_ w: World) async throws {
        let deadline = TestClock.deadline(5)
        while w.state.pendingApprovals.isEmpty, TestClock.now() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test("a real /vibecop refine shows the lines, asks, writes nothing unasked, and appends with the existing bytes kept")
    func refineAsksThenAppends() async throws {
        let existing = "# my rules\n- never touch prod\n"
        let w = try world(existing: existing); defer { w.tearDown() }
        add(Array(repeating: Self.pill("swift test --filter X", .person), count: 4), to: w.cid, in: w.state)
        // Through the stored pills: approvals that were not the person's never count.
        for layer: ToolApproval.Layer in [.yolo, .autoApprove, .allowlist, .vibecop, .vibecopRestricted] {
            add(Array(repeating: Self.pill("ls -la", layer), count: 3), to: w.cid, in: w.state)
        }
        w.state.sendMessage("/vibecop refine")
        try await waitForCard(w)
        let request = try #require(w.state.pendingApprovals.first, "the write reaches the person")
        #expect(request.humanOnly && !request.offersAlwaysAllow, "the #617 ask: the person's alone, no standing rule")
        #expect(try String(contentsOf: w.file, encoding: .utf8) == existing, "nothing is written before the click")
        #expect(said(w).contains { $0.contains("- Routine here: `swift test` (approved 4×)") }, "the proposal is shown first: \(said(w))")
        w.state.resolveApproval(id: request.id, .approve)
        let deadline = TestClock.deadline(5)
        while (try? String(contentsOf: w.file, encoding: .utf8)) == existing, TestClock.now() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let written = try String(contentsOf: w.file, encoding: .utf8)
        #expect(written == existing + "- Routine here: `swift test` (approved 4×)\n", "only the person's shape: \(written)")
        #expect(WorkspaceIrisTrust(paths: w.state.permissions.paths).isTrusted("vibecop.md", workspace: w.ws, data: Data(written.utf8)),
                "recorded as Iris's own write, so its rules apply")
    }

    @Test("a denied card writes nothing")
    func deniedWritesNothing() async throws {
        let w = try world(); defer { w.tearDown() }
        add(Array(repeating: Self.pill("make build", .person), count: 3), to: w.cid, in: w.state)
        w.state.sendMessage("/vibecop refine")
        try await waitForCard(w)
        let request = try #require(w.state.pendingApprovals.first)
        w.state.resolveApproval(id: request.id, .deny)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!FileManager.default.fileExists(atPath: w.file.path))
    }

    @Test("only the person's own approvals count, and a shape ever left unapproved is never proposed")
    func onlyPersonApprovalsAndNeverDenied() {
        let calls: [(command: String, byPerson: Bool, approved: Bool)] =
            Array(repeating: ("swift build", true, true), count: 3)
            + Array(repeating: ("git status", true, true), count: 5) + [("git status --short", false, false)]   // denied once
            + Array(repeating: ("ls -la", false, true), count: 9)          // allowlist, YOLO, Vibecop, auto-approve
            + Array(repeating: ("cd x && npm test", true, true), count: 4) // compound: never counts for a shape
            + Array(repeating: ("cargo check", true, true), count: 2)      // below the minimum
        let proposals = VibecopRefine.proposals(calls, existing: "")
        #expect(proposals.map(\.shape) == ["swift build"], "\(proposals)")
    }

    @Test("a shape the file already names is not proposed again")
    func existingShapeNotRepeated() {
        let calls = Array(repeating: (command: "swift test", byPerson: true, approved: true), count: 5)
        #expect(VibecopRefine.proposals(calls, existing: "- Routine here: `swift test` (approved 3×)\n").isEmpty)
    }

    @Test("a job run, a guest's session, and one a guest, peer or unattended arrival reached are not evidence")
    func evidenceExcludes() throws {
        let w = try world(); defer { w.tearDown() }
        var others: [UUID] = []
        for mark in 0..<5 {
            let id = w.state.createNewConversation(isBackground: mark == 0, select: false)
            w.state.setWorkspace(for: id, path: w.ws)
            let i = w.state.conversations.firstIndex { $0.id == id }!
            switch mark {
            case 1: w.state.conversations[i].isGuest = true
            case 2: w.state.conversations[i].hasGuestInput = true
            case 3: w.state.conversations[i].hasPeerInput = true
            case 4: w.state.conversations[i].hasUnattendedInput = true
            default: break
            }
            add(Array(repeating: Self.pill("cargo build", .person), count: 5), to: id, in: w.state)
            others.append(id)
        }
        // The same workspace by another spelling still counts.
        let link = w.root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: w.ws)
        let viaLink = w.state.createNewConversation(isBackground: false, select: false)
        w.state.setWorkspace(for: viaLink, path: link)
        let evidence = VibecopRefine.evidence(w.state.conversations, workspace: w.ws).map(\.id)
        #expect(Set(evidence) == [w.cid, viaLink], "\(evidence)")
        #expect(VibecopRefine.proposals(VibecopRefine.recentCommands(VibecopRefine.evidence(w.state.conversations, workspace: w.ws)),
                                        existing: "").isEmpty)
    }

    @Test("refine without a workspace, or with unreviewed rules, says why and asks nothing")
    func refusals() throws {
        let w = try world(); defer { w.tearDown() }
        try Data("- planted\n".utf8).write(to: w.file)   // not recorded as trusted
        add(Array(repeating: Self.pill("swift test", .person), count: 3), to: w.cid, in: w.state)
        w.state.sendMessage("/vibecop refine")
        #expect(w.state.pendingApprovals.isEmpty)
        #expect(said(w).contains { $0.contains("unreviewed Vibecop rules") }, "\(said(w))")
        let bare = w.state.createNewConversation(isBackground: false, select: true)
        w.state.sendMessage("/vibecop refine")
        #expect(w.state.conversations.first { $0.id == bare }?.messages.contains { $0.content.contains("needs a workspace") } == true)
    }
}
