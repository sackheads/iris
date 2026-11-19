import Testing
import Foundation
@testable import IrisKit

/// #974 Task 9b (F6 / Invariant 6): the policy stores (`profiles/`, `config/a2a-peers/`) are not
/// model-writable. Task 3 gives the model no write API; a host `run_command` can still write them,
/// so a host command that names one is a person's call alone (never an allowlist rule or Vibecop's
/// APPROVE), and the dialog names it as Iris's own access policy. `write_file` is already a
/// protected write (`IrisPaths.protectedWriteDirs`).
@Suite("The policy stores are the person's to change: names, the human-only gate, the warning (#974 Task 9b)")
struct PolicyStoreNamesTests {
    private let home = "/Users/someone"
    private func paths() -> IrisPaths { IrisPaths(root: URL(fileURLWithPath: "\(home)/.iris")) }
    private func release() -> IrisPaths { IrisPaths(root: URL(fileURLWithPath: "\(home)/.iris")) }

    // MARK: the dialog's warning (a hint on the text)

    @Test("a command or path naming a policy store raises the access-policy warning, in every spelling", arguments: [
        "echo '{}' > ~/.iris/profiles/guest.json",
        "echo '{}' > ~/.iris-dev/profiles/guest.json",
        "tee $HOME/.iris/profiles/mappings.json",
        "cp x ${HOME}/.iris-dev/profiles/guest.json",
        "echo x > '/Users/someone/.iris/profiles/a.json'",
        "echo x > /Users/someone/.iris-dev/config/a2a-peers/peer.pub",
        "mv key ~/.iris/config/a2a-peers/key",
        "cd ~/.iris && echo x > profiles/guest.json",
        "echo x > ~/.IRIS/Profiles/guest.json",
        "echo x > ~/.iris/pro\\files/guest.json".replacingOccurrences(of: "pro\\files", with: "profiles"),
        "/Users/someone/.iris-dev/profiles/guest.json",
    ])
    func warns(_ text: String) {
        let warning = GuardedSettings.approvalWarning(for: text)
        #expect(warning != nil, Comment(rawValue: text))
        #expect(warning?.contains("access policy") == true, Comment(rawValue: text))
    }

    @Test("an unrelated command or path raises no policy-store warning", arguments: [
        "ls -la ~/src",
        "echo hi > ~/notes.txt",
        "cat ~/profiles/x.txt",
        "echo x > ~/.iris/memory/memory.md",
        "echo x > ~/.iris/profiles-old/a.json",
        "git log --oneline",
        "mkdir ~/work/user_profiles",
    ])
    func quiet(_ text: String) {
        #expect(GuardedSettings.approvalWarning(for: text) == nil, Comment(rawValue: text))
    }

    @Test("the settings warning keeps its own wording and wins when both are named")
    func settingsWarningUnchanged() {
        let w = GuardedSettings.approvalWarning(for: "defaults write com.bnaylor.iris.dev X 1; echo x > ~/.iris/profiles/a.json")
        #expect(w?.contains("Iris's own settings") == true)
    }

    // MARK: the human-only gate on a host command

    private func writes(_ command: String, workspace: String? = nil, inSandbox: Bool = false, tool: String = "run_command") -> Bool {
        PermissionManager(paths: paths(), identity: .dev, release: release())
            .writesPolicyStore(toolName: tool, details: command, workspace: workspace, inSandbox: inSandbox)
    }

    @Test("a host command that writes a policy store is flagged", arguments: [
        "echo '{}' > ~/.iris/profiles/guest.json",
        "tee ~/.iris-dev/profiles/guest.json < x",
        "sed -i '' 's/a/b/' $HOME/.iris/profiles/guest.json",
        "cp x /Users/someone/.iris/profiles/guest.json",
        "rm ~/.iris/config/a2a-peers/old.pub",
        "cd ~/.iris && echo x > profiles/guest.json",
        "echo x > ~/.iris/config/a2a-peers/peer.pub",
    ])
    func hostWritesFlagged(_ command: String) {
        #expect(writes(command), Comment(rawValue: command))
    }

    @Test("a read-only command that names a store is not flagged: reading is not the hazard")
    func readsNotFlagged() {
        #expect(!writes("cat ~/.iris/profiles/guest.json"))
        #expect(!writes("ls ~/.iris/profiles"))
        #expect(!writes("grep -r owner ~/.iris/profiles"))
    }

    @Test("a command run from inside a store directory is flagged, a read-only one is not")
    func insideTheStore() {
        let dir = "\(home)/.iris/profiles"
        #expect(writes("echo x > guest.json", workspace: dir))
        #expect(writes("touch mappings.json", workspace: "\(home)/.iris/config/a2a-peers"))
        #expect(!writes("ls", workspace: dir))
    }

    @Test("from the Iris home or its config/, a bare store name is the store (relative spellings, dev-2's probes)")
    func relativeFromTheIrisHome() {
        let irisHome = "\(home)/.iris"
        #expect(writes("echo x > profiles/y", workspace: irisHome))
        #expect(writes("cd profiles && tee y", workspace: irisHome))
        #expect(writes("echo x > ../profiles/y", workspace: "\(irisHome)/config"))
        #expect(writes("cp k a2a-peers/k.json", workspace: "\(irisHome)/config"))
        // Near-misses stay unflagged, and so does a read-only command and a workspace elsewhere.
        #expect(!writes("echo x > profiles-old/y", workspace: irisHome))
        #expect(!writes("echo x > memory/memory.md", workspace: irisHome))
        #expect(!writes("cat profiles/y", workspace: irisHome))
        #expect(!writes("echo x > profiles/y", workspace: "\(home)/work"))
    }

    @Test("an unrelated host command is not flagged")
    func unrelatedNotFlagged() {
        for c in ["echo hi > ~/notes.txt", "swift build", "git commit -m x", "echo x > ~/.iris/memory/memory.md", "mkdir ~/profiles"] {
            #expect(!writes(c), Comment(rawValue: c))
        }
    }

    @Test("a sandboxed command is not flagged: ~/.iris is not mounted in the VM, and the file tools are protected writes")
    func sandboxAndFileToolsNotThisRule() {
        #expect(!writes("echo x > ~/.iris/profiles/guest.json", inSandbox: true))
        #expect(!writes("~/.iris/profiles/guest.json", tool: "write_file"))
    }

    // MARK: write_file is already a protected write (the half that needs no new code)

    @Test("a write_file into profiles/ or config/a2a-peers/ is a protected write, and raises the warning")
    func fileToolsAreProtected() {
        let p = PermissionManager(paths: paths(), identity: .dev, release: release())
        for path in ["\(home)/.iris/profiles/guest.json", "\(home)/.iris/profiles/mappings.json",
                     "\(home)/.iris/config/a2a-peers/peer.pub"] {
            #expect(p.isProtectedWrite(toolName: "write_file", path: path), Comment(rawValue: path))
            #expect(GuardedSettings.approvalWarning(for: path) != nil, Comment(rawValue: path))
        }
        #expect(!p.isProtectedWrite(toolName: "write_file", path: "\(home)/.iris/memory/memory.md"))
    }

    @Test("the policy-store directories are the ones IrisPaths protects (the names cannot drift from the check)")
    func namesFollowIrisPaths() {
        let names = IrisPaths(root: URL(fileURLWithPath: "\(home)/.iris")).protectedWriteDirs.map(\.lastPathComponent)
        #expect(names.contains("profiles") && names.contains("config"))
        #expect(PolicyStores.directoryNames == ["profiles", "a2a-peers"])
    }
}

/// The always-ask rule end to end through `AppState.requestApproval`, with Vibecop approving
/// everything and an allowlist rule on the exact command (Invariant 7: own PermissionManager).
@MainActor
@Suite("A host command naming a policy store always asks (#974 Task 9b)", .timeLimit(.minutes(1)))
struct PolicyStoreApprovalTests {
    private final class Approver: AuxiliaryInferenceEngine, @unchecked Sendable {
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            #"{"decision":"APPROVE","reason":"routine"}"#
        }
    }

    @MainActor private final class Done { var value = false }

    private func app() throws -> (AppState, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-9b-home-\(UUID().uuidString)")
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: home.appendingPathComponent(".iris")), identity: .dev,
                                              release: IrisPaths(root: home.appendingPathComponent(".iris")))
        return (state, home)
    }

    enum Outcome: Equatable { case silent(Bool), asked }

    private func call(_ state: AppState, _ details: String, in cid: UUID,
                      answer: AppState.ApprovalResolution = .deny) async throws -> Outcome {
        let done = Done()
        let task = Task { @MainActor in
            let approved = await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": Approver()]) {
                await state.requestApproval(toolName: "run_command", details: details, workspace: nil,
                                            conversationId: cid, vibecopEnabled: true)
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

    @Test("a host command that writes a policy store asks though Vibecop approves and an allowlist rule covers it")
    func asksDespiteRules() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: false, select: false)
        let command = "echo '{}' > ~/.iris/profiles/guest.json"
        state.permissions.allowGlobally(toolName: "run_command", details: command)
        #expect(try await call(state, command, in: cid) == .asked)
        // The control: an unrelated command under the same kind of rule and verdict runs unasked.
        let other = "echo hi > /tmp/iris-9b-control.txt"
        state.permissions.allowGlobally(toolName: "run_command", details: other)
        #expect(try await call(state, other, in: cid) == .silent(true))
    }

    @Test("an unattended run's command naming a policy store is refused, whatever its rules say")
    func backgroundRefused() async throws {
        let (state, home) = try app()
        defer { try? FileManager.default.removeItem(at: home) }
        let cid = state.createNewConversation(isBackground: true, select: false)
        let command = "echo '{}' > ~/.iris/profiles/guest.json"
        state.permissions.allowGlobally(toolName: "run_command", details: command)
        #expect(try await call(state, command, in: cid) == .silent(false))
    }
}

/// A home that is not spelled `.iris`: the text forms cannot see it, so only the absolute path of the
/// store (and its real path) can.
@Suite("A policy store is recognized by its absolute path too (#974 Task 9b)")
struct PolicyStoreAbsolutePathTests {
    @Test("a command naming a store by its absolute path under a custom home is flagged; the same words elsewhere are not")
    func absolutePath() {
        let root = "/tmp/iris-9b-custom-root-\(UUID().uuidString)/state"
        let paths = IrisPaths(root: URL(fileURLWithPath: root))
        let p = PermissionManager(paths: paths, identity: .dev, release: paths)
        #expect(p.writesPolicyStore(toolName: "run_command", details: "echo x > \(root)/profiles/guest.json", workspace: nil, inSandbox: false))
        #expect(p.writesPolicyStore(toolName: "run_command", details: "echo x > '\(root)/config/a2a-peers/k.pub'", workspace: nil, inSandbox: false))
        #expect(!p.writesPolicyStore(toolName: "run_command", details: "echo x > \(root)/profiles-old/a.json", workspace: nil, inSandbox: false))
        #expect(!p.writesPolicyStore(toolName: "run_command", details: "echo x > \(root)/memory/memory.md", workspace: nil, inSandbox: false))
        #expect(!p.writesPolicyStore(toolName: "run_command", details: "echo x > /tmp/elsewhere/profiles/a.json", workspace: nil, inSandbox: false))
    }
}
