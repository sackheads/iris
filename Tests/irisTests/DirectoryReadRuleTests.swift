import Testing
import Foundation
@testable import IrisKit

/// #1136: a directory-scoped Always Allow for `read_file`. One rule says "reads under this folder",
/// instead of one exact rule per file. It is a standing allow, so these tests pin what it must NOT do
/// as hard as what it does: reads only, attended only, component boundary, nothing too broad, nothing
/// near a credential store, nothing named like a secret, and a hand-edited file cannot widen it.
@MainActor
@Suite("Directory-scoped Always Allow for read_file (#1136)", .timeLimit(.minutes(1)))
struct DirectoryReadRuleTests {
    private struct Fixture {
        let root: URL
        var home: String { root.appendingPathComponent("home").path }       // a stand-in for the user's home
        var project: String { home + "/work/proj" }
        var iris: IrisPaths { IrisPaths(root: root.appendingPathComponent("iris-home")) }
        func real(_ path: String) -> String { IrisPaths.realPath(path) }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() throws -> Fixture {
        let f = Fixture(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-1136-\(UUID().uuidString)"))
        for dir in [f.project + "/sub", f.project + "bc", f.home + "/.ssh", f.home + "/.aws", f.root.appendingPathComponent("iris-home").path] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        for file in ["/a.txt", "/sub/b.txt", "/.env", "/server.pem", "/id_rsa"] {
            try "x".write(toFile: f.project + file, atomically: true, encoding: .utf8)
        }
        try "x".write(toFile: f.project + "bc/c.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: f.home + "/.ssh/config", atomically: true, encoding: .utf8)
        try "x".write(toFile: f.home + "/.aws/credentials", atomically: true, encoding: .utf8)
        return f
    }

    // MARK: the rule's shape

    @Test("a rule saved before #1136 decodes, a directory rule round-trips, and an unknown kind matches nothing")
    func codable() throws {
        let old = try JSONDecoder().decode(PermissionRule.self, from: Data(#"{"toolName":"read_file","details":"/a/b"}"#.utf8))
        #expect(old.isExact && !old.isDirectory)
        let dir = PermissionRule(toolName: "read_file", details: "/a/b", match: .directory)
        let again = try JSONDecoder().decode(PermissionRule.self, from: JSONEncoder().encode(dir))
        #expect(again == dir && again.isDirectory)
        let future = try JSONDecoder().decode(PermissionRule.self, from: Data(#"{"toolName":"read_file","details":"/a","match":"glob"}"#.utf8))
        #expect(!future.isExact && !future.isDirectory && !future.isPrefix)
    }

    // MARK: what may be offered

    @Test("a read offers the folder it is in; a write or any other tool offers none")
    func offered() throws {
        let f = try fixture(); defer { f.tearDown() }
        let file = f.real(f.project + "/a.txt")
        let rule = PermissionRule.forAlwaysAllowDirectory(toolName: "read_file", details: file, home: f.home, paths: f.iris)
        #expect(rule == PermissionRule(toolName: "read_file", details: f.real(f.project), match: .directory))
        #expect(PermissionRule.forAlwaysAllowDirectory(toolName: "write_file", details: file, home: f.home, paths: f.iris) == nil)
        #expect(PermissionRule.forAlwaysAllowDirectory(toolName: "run_command", details: file, home: f.home, paths: f.iris) == nil)
        #expect(PermissionRule.forAlwaysAllowDirectory(toolName: "read_file", details: "relative.txt", home: f.home, paths: f.iris) == nil)
    }

    @Test("too broad or too sensitive a folder is never offered", arguments: [
        "/etc/hosts", "/Users/x", "/tmp/a.txt", "/private/etc/passwd",
    ])
    func tooBroad(_ file: String) throws {
        let f = try fixture(); defer { f.tearDown() }
        #expect(DirectoryReadRule.directory(forReadOf: file, home: f.home, paths: f.iris) == nil, Comment(rawValue: file))
    }

    @Test("the home directory, a folder above it, a credential store and anything in one are not offered")
    func homeAndStores() throws {
        let f = try fixture(); defer { f.tearDown() }
        try "x".write(toFile: f.home + "/notes.txt", atomically: true, encoding: .utf8)
        #expect(DirectoryReadRule.directory(forReadOf: f.real(f.home + "/notes.txt"), home: f.home, paths: f.iris) == nil, "the home itself")
        #expect(DirectoryReadRule.directory(forReadOf: f.real(f.root.path + "/x.txt"), home: f.home, paths: f.iris) == nil, "above the home")
        #expect(DirectoryReadRule.directory(forReadOf: f.real(f.home + "/.ssh/config"), home: f.home, paths: f.iris) == nil, ".ssh")
        #expect(DirectoryReadRule.directory(forReadOf: f.real(f.home + "/.aws/credentials"), home: f.home, paths: f.iris) == nil, ".aws")
    }

    @Test("a file named like a secret is not offered a folder rule", arguments: [".env", ".env.local", "server.pem", "id_rsa", "id_ed25519", ".netrc", "token", "prod.key", "a.kdbx"])
    func secretNames(_ name: String) {
        #expect(DirectoryReadRule.isSecretFileName(name), Comment(rawValue: name))
    }

    @Test("ordinary names are not secret names", arguments: ["a.txt", "environment.md", "keyboard.md", "notes.pem.md", "README"])
    func ordinaryNames(_ name: String) {
        #expect(!DirectoryReadRule.isSecretFileName(name), Comment(rawValue: name))
    }

    @Test("a folder whose path looks like a credential is not offered")
    func credentialLookingPath() throws {
        let f = try fixture(); defer { f.tearDown() }
        let dir = f.home + "/work/ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        #expect(DirectoryReadRule.directory(forReadOf: f.real(dir + "/a.txt"), home: f.home, paths: f.iris) == nil)
    }

    // MARK: matching

    private func covers(_ f: Fixture, rule dir: String, read path: String) -> Bool {
        DirectoryReadRule.covers(directory: dir, read: f.real(path), home: f.home, paths: f.iris)
    }

    @Test("a rule covers files in the folder and below, on a component boundary only")
    func boundary() throws {
        let f = try fixture(); defer { f.tearDown() }
        let dir = f.real(f.project)
        #expect(covers(f, rule: dir, read: f.project + "/a.txt"))
        #expect(covers(f, rule: dir, read: f.project + "/sub/b.txt"))
        #expect(!covers(f, rule: dir, read: f.project + "bc/c.txt"), "/a/b must not cover /a/bc")
        #expect(!covers(f, rule: dir, read: f.project), "the folder itself is not a file read")
        #expect(!covers(f, rule: dir, read: f.home + "/work/other.txt"))
    }

    @Test("a symlink out of the folder is judged where it resolves, and a folder rule spelled through a link still matches")
    func symlinks() throws {
        let f = try fixture(); defer { f.tearDown() }
        let outside = f.root.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "x".write(toFile: outside + "/o.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: f.project + "/link.txt", withDestinationPath: outside + "/o.txt")
        #expect(!covers(f, rule: f.real(f.project), read: f.project + "/link.txt"), "the link's target is outside the folder")
        try FileManager.default.createSymbolicLink(atPath: f.home + "/work/projlink", withDestinationPath: f.project)
        #expect(covers(f, rule: f.home + "/work/projlink", read: f.project + "/a.txt"), "a rule saved through a link is the folder it points at")
    }

    @Test("a file named like a secret, or in a credential store, is still asked about under a folder rule")
    func exceptions() throws {
        let f = try fixture(); defer { f.tearDown() }
        let dir = f.real(f.project)
        for name in [".env", "server.pem", "id_rsa"] {
            #expect(!covers(f, rule: dir, read: f.project + "/" + name), Comment(rawValue: name))
        }
        #expect(!covers(f, rule: f.real(f.home + "/.ssh"), read: f.home + "/.ssh/config"), "a hand-edited rule over a store grants nothing")
        #expect(!covers(f, rule: f.real(f.home), read: f.home + "/work/proj/a.txt"), "a hand-edited rule over the home grants nothing")
        #expect(!covers(f, rule: "/", read: f.project + "/a.txt"))
        #expect(!covers(f, rule: "relative/dir", read: f.project + "/a.txt"))
    }

    // MARK: through the permission manager

    private func manager(_ f: Fixture, saving rule: PermissionRule) -> PermissionManager {
        let pm = PermissionManager(paths: f.iris)
        pm.allowGlobally([rule])
        return pm
    }

    @Test("an attended read under the folder is allowed by the rule; everything else is not")
    func manager_attended() throws {
        let f = try fixture(); defer { f.tearDown() }
        let rule = PermissionRule(toolName: "read_file", details: f.real(f.project), match: .directory)
        let pm = manager(f, saving: rule)
        let inside = f.real(f.project + "/sub/b.txt")
        #expect(pm.match(toolName: "read_file", details: inside, workspace: nil)?.rule == rule)
        #expect(pm.match(toolName: "read_file", details: inside, workspace: nil)?.scope == .global)
        #expect(!pm.isAllowed(toolName: "write_file", details: inside, workspace: nil), "reads only")
        #expect(!pm.isAllowed(toolName: "run_command", details: inside, workspace: nil))
        #expect(!pm.isAllowed(toolName: "read_file", details: f.real(f.project + "bc/c.txt"), workspace: nil))
        #expect(!pm.isAllowed(toolName: "read_file", details: f.real(f.project + "/.env"), workspace: nil))
    }

    @Test("an unattended run and a guest-origin turn are not waved through by a folder rule")
    func manager_attendedOnly() throws {
        let f = try fixture(); defer { f.tearDown() }
        let pm = manager(f, saving: PermissionRule(toolName: "read_file", details: f.real(f.project), match: .directory))
        let inside = f.real(f.project + "/a.txt")
        #expect(pm.isAllowed(toolName: "read_file", details: inside, workspace: nil))
        #expect(!pm.isAllowed(toolName: "read_file", details: inside, workspace: nil, isBackground: true))
        #expect(!pm.isAllowed(toolName: "read_file", details: inside, workspace: nil, isGuestOrigin: true))
    }

    @Test("a folder rule in a project allowlist matches the same way, and reports the project scope")
    func manager_project() throws {
        let f = try fixture(); defer { f.tearDown() }
        let workspace = f.real(f.home + "/work")
        let rule = PermissionRule(toolName: "read_file", details: f.real(f.project), match: .directory)
        let pm = PermissionManager(paths: f.iris)
        pm.allowInProject([rule], workspace: workspace)
        let hit = pm.match(toolName: "read_file", details: f.real(f.project + "/a.txt"), workspace: workspace)
        #expect(hit?.scope == .project && hit?.rule == rule)
    }

    // MARK: the dialog, and a real turn

    private func callResponse(_ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: FunctionCall(name: "read_file", args: args))]))], usageMetadata: nil)
    }
    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))], usageMetadata: nil)
    }

    /// One attended `read_file` turn on a fresh engine over `state`: the prompt is answered with
    /// `answer` (nil = not asked, fail if it is), and what the dialog carried is returned.
    private func readTurn(_ state: AppState, path: String, answer: AppState.ApprovalResolution?) async throws -> ToolApprovalRequest? {
        let engine = IrisEngine(state: state, tier: .medium,
                                client: FakeLLMClient(responses: [callResponse(["path": .string(path)]), textResponse("done.")]),
                                retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        let id = state.createNewConversation(select: false)
        let finished = Locked(false)
        let turn = Task { @MainActor in
            await engine.processInput("go", source: "UI", conversationId: id)
            finished.mutate { $0 = true }
        }
        var asked: ToolApprovalRequest?
        for _ in 0..<1000 where !finished.value {
            if let request = state.pendingApprovals.first(where: { $0.conversationId == id }) {
                asked = request
                state.resolveApproval(id: request.id, answer ?? .deny)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        if asked == nil { state.denyPendingApprovals(for: id) }
        try await value(of: turn)
        return asked
    }

    private func state(_ f: Fixture) throws -> AppState {
        let s = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned,
                         createIfEmpty: false, emitLaunchNotices: false)
        s.permissions = PermissionManager(paths: f.iris)
        return s
    }

    @Test("the read_file dialog carries the folder rule; clicking it saves it and the next read in the folder is not asked")
    func endToEnd() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let s = try state(f)
        let first = try await readTurn(s, path: f.project + "/a.txt", answer: .alwaysAllowDirectory)
        #expect(first?.directoryRule == PermissionRule(toolName: "read_file", details: f.real(f.project), match: .directory),
                "the dialog offered the folder the file is in")
        let saved = s.permissions.match(toolName: "read_file", details: f.real(f.project + "/sub/b.txt"), workspace: nil)
        #expect(saved?.rule?.isDirectory == true, "the click wrote the folder rule")
        let second = try await readTurn(s, path: f.project + "/sub/b.txt", answer: nil)
        #expect(second == nil, "a read under the folder runs without a prompt")
        let secret = try await readTurn(s, path: f.project + "/.env", answer: .deny)
        #expect(secret != nil, "a secret-named file in the folder still asks")
        let sibling = try await readTurn(s, path: f.project + "bc/c.txt", answer: .deny)
        #expect(sibling != nil, "a sibling folder that shares the prefix still asks")
    }

    @Test("a card with no folder rule writes nothing when the folder button is forced")
    func noRuleNoWrite() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let s = try state(f)
        // A read in a credential store: no folder rule is offered.
        let asked = try await readTurn(s, path: f.home + "/.ssh/config", answer: .alwaysAllowDirectory)
        #expect(asked?.directoryRule == nil)
        #expect(!s.permissions.isAllowed(toolName: "read_file", details: f.real(f.home + "/.ssh/config"), workspace: nil))
        #expect(!s.permissions.isAllowed(toolName: "read_file", details: f.real(f.home + "/.ssh/other"), workspace: nil))
    }

    /// A request built the way `enqueueUserApproval` builds one: inside the continuation body, which is
    /// resumed straight away because nothing here waits on the answer.
    private func request(_ tool: String, details: String, humanOnly: Bool = false, offersAlwaysAllow: Bool = true) async -> ToolApprovalRequest {
        var made: ToolApprovalRequest?
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            made = ToolApprovalRequest(id: UUID(), toolName: tool, details: details, workspace: nil, conversationId: nil, origin: "Iris",
                                       humanOnly: humanOnly, offersAlwaysAllow: offersAlwaysAllow, continuation: continuation)
            continuation.resume(returning: false)
        }
        return made!
    }

    @Test("no folder rule is offered for a write, or when Always Allow is off, but a read offers one")
    func notOffered() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let file = f.real(f.project + "/a.txt")
        #expect(await request("write_file", details: file).directoryRule == nil)
        #expect(await request("read_file", details: file, humanOnly: true).directoryRule == nil)
        #expect(await request("read_file", details: file, offersAlwaysAllow: false).directoryRule == nil)
        // The positive control: the same read with Always Allow on carries the rule (its folder is not
        // under the real home in a test, so the home guard does not apply).
        #expect(await request("read_file", details: file).directoryRule?.isDirectory == true)
    }
}
