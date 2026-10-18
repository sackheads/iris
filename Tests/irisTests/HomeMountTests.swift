import Testing
import Foundation
@testable import IrisKit

/// #611 option c: a sandboxed workspace at home or above it, or holding a startup or credential
/// folder, is refused unless the person allowed it for that conversation; with that opt-in on,
/// Vibecop's APPROVE in the VM runs only a read-only command (the owner's "1: a").
@MainActor
@Suite("Home-writable sandbox mounts need the person's opt-in (#611)", .timeLimit(.minutes(1)))
struct HomeMountTests {
    let home = "/Users/me"
    let paths = IrisPaths(root: URL(fileURLWithPath: "/Users/me/.iris"))

    @Test("the rule: home or above, startup and credential folders either way, Iris's own settings; project folders pass")
    func reasons() {
        func refused(_ p: String) -> Bool { HomeMount.reason(for: p, home: home, paths: paths) != nil }
        for p in ["/", "/Users", "/Users/me", "/Users/me/", "/Users/me/Library", "/Users/me/Library/LaunchAgents",
                  "/Users/me/Library/LaunchAgents/x", "/Users/me/.config", "/Users/me/.config/fish", "/Users/me/bin",
                  "/Users/me/.local", "/Users/me/.local/bin", "/Users/me/.ssh", "/Users/me/.aws/sub",
                  "/Users/me/.iris", "/Users/me/.iris/config", "/Users/me/.iris/plugins/p"] {
            #expect(refused(p), "\(p)")
        }
        for p in ["/Users/me/src/p", "/Users/me/.iris/workspaces/ship", "/Users/me/Documents/notes", "/tmp/x",
                  "/Users/me/.local/share/thing"] {
            #expect(!refused(p), "\(p)")
        }
    }

    @Test("an opt-in covers exactly the folder it was given for")
    func coverage() {
        #expect(HomeMount.isCovered("/Users/me", by: "/Users/me"))
        #expect(HomeMount.isCovered("/Users/me/", by: "/Users/me"))
        #expect(!HomeMount.isCovered("/Users/me", by: nil))
        #expect(!HomeMount.isCovered("/", by: "/Users/me"), "moving the workspace up is not covered")
        #expect(!HomeMount.isCovered("/Users/me/Library", by: "/Users/me"))
    }

    @Test("a job or watch grant may not mount a startup folder, in either direction")
    func grantRefusesStartupFolders() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iris-611-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        for sub in ["Library/LaunchAgents", ".config/fish", "bin", ".local/bin", "proj"] {
            try fm.createDirectory(at: home.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let paths = IrisPaths(root: base.appendingPathComponent("dot-iris"))
        func resolve(_ sub: String) -> Result<JobGrant?, ToolMessage> {
            JobGrant.resolve(mounts: [home.appendingPathComponent(sub).path], network: nil, profile: .mutating,
                             paths: paths, home: home.path, isVolume: { _ in false })
        }
        for sub in ["Library/LaunchAgents", ".config", ".config/fish", "bin", ".local/bin", "Library"] {
            guard case .failure(let message) = resolve(sub) else { Issue.record("granted \(sub)"); continue }
            #expect(message.text.contains("credential store") || message.text.contains("runs programs or settings from"), "\(sub): \(message.text)")
        }
        guard case .success = resolve("proj") else { Issue.record("a project folder was refused"); return }
    }

    private func app() throws -> (AppState, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-611-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(store: try ConversationStore.inMemory(),
                             tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                             createIfEmpty: false, emitLaunchNotices: false)
        state.permissions = PermissionManager(paths: IrisPaths(root: dir))
        return (state, dir)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    @Test("the mount site refuses a home workspace without the opt-in, runs it with one, and passes a project folder")
    func mountSiteRefusal() async {
        let calls = Calls()
        var executor = ToolExecutor()
        executor.sandboxSession = { _, _, _, _, _, _ in calls.hit(); return "Success" }
        let home = NSHomeDirectory()
        func run(_ cwd: String, optIn: String?) async -> String {
            await executor.execute(name: "run_command", args: ["command": .string("true")], cwd: cwd,
                                   conversationId: UUID(), useSandbox: true, homeWritableOptIn: optIn)
        }
        let refused = await run(home, optIn: nil)
        #expect(refused.hasPrefix("Not run: the sandbox would mount \(home) read-write"))
        #expect(calls.count == 0, "nothing ran")
        #expect(await run("/", optIn: home).hasPrefix("Not run:"), "an opt-in covers only its own folder")
        #expect(calls.count == 0)
        #expect(await run(home, optIn: home) == "Success")
        #expect(await run(home + "/src/some-project", optIn: nil) == "Success")
        #expect(calls.count == 2)
        // A grant's mounts were judged when granted: the rule does not re-judge them here.
        let grant = JobGrant(mounts: [ContainerMount(source: "/tmp/granted")])
        #expect(await executor.execute(name: "run_command", args: ["command": .string("true")], cwd: home,
                                       conversationId: UUID(), useSandbox: true, grant: grant) == "Success")
    }

    @Test("with no conversation, the one-off container refuses a home folder too: there is no one to have opted in")
    func ephemeralRefusal() async {
        var executor = ToolExecutor()
        executor.containerBinaryPath = { "/usr/bin/true" }   // stands in for `container`; nothing reaches it
        let refused = await executor.execute(name: "run_command", args: ["command": .string("true")],
                                             cwd: NSHomeDirectory(), conversationId: nil, useSandbox: true)
        #expect(refused.hasPrefix("Not run: the sandbox would mount"), "\(refused)")
    }

    private final class Ended: @unchecked Sendable {
        private let lock = NSLock(); private var ids: [UUID] = []
        func add(_ id: UUID) { lock.withLock { ids.append(id) } }
        var all: Set<UUID> { lock.withLock { Set(ids) } }
    }

    @Test("withdrawing the opt-in ends the sessions made under it, the conversation's and its delegates'")
    func withdrawalEndsSessions() async throws {
        let (state, dir) = try app()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ended = Ended()
        state.endSandboxSession = { ended.add($0) }
        let root = state.createNewConversation(isBackground: false, select: false)
        let child = state.createNewConversation(isSubagent: true, select: false)
        let other = state.createNewConversation(isBackground: false, select: false)
        state.linkDelegate(child, of: root)
        #expect(state.setHomeWritableOptIn(for: root, path: "/Users/me") == nil, "turning it on ends nothing")
        let withdrawal = try #require(state.setHomeWritableOptIn(for: root, path: nil))
        _ = try await value(of: withdrawal)
        #expect(ended.all == [root, child])
        #expect(!ended.all.contains(other))
        // Moving it to another folder ends them too; setting the same folder again does not.
        state.setHomeWritableOptIn(for: root, path: "/Users/me")
        #expect(state.setHomeWritableOptIn(for: root, path: "/Users/me") == nil)
        #expect(state.setHomeWritableOptIn(for: root, path: "/Users/other") != nil)
    }

    @Test("the engine hands the executor its delegation root's opt-in")
    func rootOptIn() async throws {
        let (state, dir) = try app()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = IrisEngine(state: state)
        let root = state.createNewConversation(isBackground: false, select: false)
        let child = state.createNewConversation(isSubagent: true, select: false)
        state.linkDelegate(child, of: root)
        #expect(await engine.homeWritableOptIn(for: child) == nil)
        state.setHomeWritableOptIn(for: root, path: "/Users/me")
        #expect(await engine.homeWritableOptIn(for: root) == "/Users/me")
        #expect(await engine.homeWritableOptIn(for: child) == "/Users/me", "a subagent shares its root's opt-in")
        state.setHomeWritableOptIn(for: root, path: nil)
        #expect(await engine.homeWritableOptIn(for: child) == nil)
    }

    private final class Approver: AuxiliaryInferenceEngine, @unchecked Sendable {
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            #"{"decision":"APPROVE","reason":"routine"}"#
        }
    }

    @Test("opted in, an in-VM write asks even on Vibecop's APPROVE, and a read still runs (1: a)")
    func optedInVMIsTreatedLikeTheHost() async throws {
        let (state, dir) = try app()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realHome = NSHomeDirectory()
        let cid = state.createNewConversation(isBackground: false, select: false)
        func source(_ command: String) async -> AppState.ApprovalSource? {
            let task = Task { @MainActor in
                await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": Approver()]) {
                    await state.requestApprovalSource(toolName: "run_command", details: command, workspace: realHome,
                                                      conversationId: cid, inSandbox: true, vibecopEnabled: true)
                }
            }
            for _ in 0..<400 {
                if let request = state.pendingApprovals.first(where: { $0.conversationId == cid }) {
                    state.resolveApproval(id: request.id, .approve)
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
                if state.pendingApprovals.isEmpty, state.homeWritable(cid, workspace: realHome) == false { break }
            }
            return try? await value(of: task)
        }
        // Without the opt-in the VM is the safe box it was: the write runs on the APPROVE.
        #expect(await source("rm -f x") == .vibecop)
        state.setHomeWritableOptIn(for: cid, path: realHome)
        #expect(state.homeWritable(cid, workspace: realHome))
        #expect(await source("ls -la") == .vibecop, "a read still runs in the VM")
        #expect(await source("rm -f x") == .person, "a write asked the person")
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "rm -f x", inSandbox: true,
                                            homeWritable: true, lookup: ReadOnlyCommand.HostLookup(
                                                path: "", cwd: "/tmp", home: "/x", isExecutable: { _ in false })) == .ask)
    }

    @Test("the opt-in persists with the conversation, and a row from before #611 reads as none")
    func persists() throws {
        let store = try ConversationStore.inMemory()
        let first = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let cid = first.createNewConversation(isBackground: false, select: false)
        first.setHomeWritableOptIn(for: cid, path: "/Users/me")
        first.flushSave()
        let again = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        #expect(again.conversations.first { $0.id == cid }?.homeWritableOptIn == "/Users/me")
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"t","messages":[]}"#
        let decoded = try JSONDecoder().decode(Conversation.self, from: Data(legacy.utf8))
        #expect(decoded.homeWritableOptIn == nil)
    }

    @Test("only the UI sets the opt-in: no tool, system event or job reaches the setter or the field")
    func humanOnly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/IrisKit")
        var setterCallers: Set<String> = [], fieldWriters: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                if line.contains("setHomeWritableOptIn(") && !line.contains("func setHomeWritableOptIn") { setterCallers.insert(file) }
                if line.range(of: #"\.homeWritableOptIn\s*=[^=]"#, options: .regularExpression) != nil
                    || line.range(of: #"^\s*homeWritableOptIn\s*=[^=]"#, options: .regularExpression) != nil {
                    fieldWriters.insert(file)
                }
            }
        }
        #expect(setterCallers == ["ChatView.swift"], "\(setterCallers)")
        // The setter itself, the store's read and the Codable decode.
        #expect(fieldWriters == ["AppState.swift", "ConversationStore.swift"], "\(fieldWriters)")
    }
}
