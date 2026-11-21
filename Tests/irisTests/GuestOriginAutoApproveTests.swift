import Foundation
import Testing
@testable import IrisKit

/// #1150, #1151: a guest-origin turn is never auto-approved by the `~/.iris` carve-out or by Vibecop,
/// and an ordinary turn still is. The ladder is driven through `AppState.requestApprovalSource`, so
/// the call site that reads the flag is pinned, not only the helper (#1139's lesson).
@MainActor
@Suite("A guest-origin turn disables the remaining auto-approvals (#1150, #1151)", .timeLimit(.minutes(1)))
struct GuestOriginAutoApproveTests {
    private final class Engine: AuxiliaryInferenceEngine, @unchecked Sendable {
        let decision: String
        init(_ decision: String) { self.decision = decision }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            #"{"decision":"\#(decision)","reason":"routine"}"#
        }
    }

    private struct World {
        var state: AppState
        var paths: IrisPaths
        var ordinary: UUID
        var guest: UUID
        var root: URL
    }

    private func world() throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-1150-\(UUID().uuidString)")
        let paths = IrisPaths(root: root.appendingPathComponent("iris-home"))
        try paths.ensureDirectories()
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: paths)
        // A fixed host, so the developer's own PATH decides nothing here.
        state.hostLookupOverride = {
            ReadOnlyCommand.HostLookup(path: "/bin:/usr/bin", cwd: "/tmp", home: root.path,
                                       isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        }
        let ordinary = state.createNewConversation(isBackground: false, select: false)
        let guest = state.createNewConversation(isBackground: false, select: false)
        state.markGuestOriginTurn(guest)
        return World(state: state, paths: paths, ordinary: ordinary, guest: guest, root: root)
    }

    /// The ladder's answer; a prompt, if one appears, is approved so the call returns `.person`.
    private func ask(_ w: World, _ conversation: UUID, tool: String, details: String, inSandbox: Bool = false,
                     vibecop: String? = nil) async throws -> (source: AppState.ApprovalSource?, prompted: Bool) {
        let state = w.state
        final class Done { var value = false }
        let done = Done()
        let task = Task { @MainActor in
            let source = await AuxiliaryModelManager.$scopedEngines.withValue(vibecop.map { ["vibecop": Engine($0)] } ?? [:]) {
                await state.requestApprovalSource(toolName: tool, details: details, conversationId: conversation,
                                                  inSandbox: inSandbox, vibecopEnabled: vibecop != nil, isOwner: true)
            }
            done.value = true
            return source
        }
        var prompted = false
        for _ in 0..<1_000 where !done.value {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == conversation }) {
                prompted = true
                state.resolveApproval(id: request.id, .approve)
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return (try await value(of: task), prompted)
    }

    // MARK: #1150

    @Test("the ~/.iris carve-out still allows an ordinary turn and asks a guest-origin one, for reads and attended writes")
    func carveOut() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        for (tool, path) in [("write_file", w.paths.memoryMd.path), ("read_file", w.paths.memoryMd.path)] {
            let ordinary = try await ask(w, w.ordinary, tool: tool, details: path)
            #expect(ordinary.source == .allowlist(AllowMatch(scope: .irisHome, rule: nil)) && !ordinary.prompted, "\(tool): ordinary")
            let guest = try await ask(w, w.guest, tool: tool, details: path)
            #expect(guest.source == .person && guest.prompted, "\(tool): a guest-origin turn asks")
        }
    }

    @Test("PermissionManager.match skips the carve-out for a guest-origin turn only")
    func carveOutManager() throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let path = w.paths.memoryMd.path
        #expect(w.state.permissions.match(toolName: "write_file", details: path, workspace: nil, isOwner: true) != nil)
        #expect(w.state.permissions.match(toolName: "write_file", details: path, workspace: nil, isGuestOrigin: true, isOwner: true) == nil)
        #expect(w.state.permissions.match(toolName: "read_file", details: path, workspace: nil, isGuestOrigin: true, isOwner: true) == nil)
    }

    // MARK: #1151

    @Test("Vibecop's APPROVE runs a host read for an ordinary turn and asks on a guest-origin one")
    func vibecopHostRead() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let ordinary = try await ask(w, w.ordinary, tool: "run_command", details: "ls -la", vibecop: "APPROVE")
        guard case .vibecopRestricted = ordinary.source else {
            Issue.record("ordinary turn: expected a restricted Vibecop read, got \(String(describing: ordinary.source))")
            return
        }
        #expect(!ordinary.prompted)
        let guest = try await ask(w, w.guest, tool: "run_command", details: "ls -la", vibecop: "APPROVE")
        #expect(guest.source == .person && guest.prompted)
    }

    @Test("Vibecop's APPROVE in the VM runs for an ordinary turn and asks on a guest-origin one")
    func vibecopInVM() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let ordinary = try await ask(w, w.ordinary, tool: "run_command", details: "make", inSandbox: true, vibecop: "APPROVE")
        #expect(ordinary.source == .vibecop(reason: "routine") && !ordinary.prompted)
        let guest = try await ask(w, w.guest, tool: "run_command", details: "make", inSandbox: true, vibecop: "APPROVE")
        #expect(guest.source == .person && guest.prompted)
    }

    @Test("Vibecop can still DENY a guest-origin turn")
    func vibecopDenyStands() async throws {
        let w = try world()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let guest = try await ask(w, w.guest, tool: "run_command", details: "ls -la", vibecop: "DENY")
        #expect(guest.source == nil && !guest.prompted, "a DENY refuses with no prompt, as for an ordinary turn")
    }
}
