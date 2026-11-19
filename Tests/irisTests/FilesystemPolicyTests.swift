import Testing
import Foundation
@testable import IrisKit

/// #974 Task 8 (C5): the owner's `read_file`/`write_file` keep today's unrestricted host access;
/// a non-owner binding is confined to its `fsRoots` grant (empty grant = confined to nothing) and,
/// on top of that, is always denied a fixed set of credential/config stores on the host -- even
/// one of its granted roots cannot reach into them, and neither can a symlink or a `..` that
/// resolves there.
@Suite("FilesystemPolicy (#974 Task 8, C5)")
struct FilesystemPolicyTests {
    private func owner() -> AccessBinding { AccessBinding(profile: .owner, principal: .main, isOwner: true) }
    private func nonOwner(fsRoots: Set<String> = []) -> AccessBinding {
        AccessBinding(profile: AccessProfile(fsRoots: fsRoots), principal: .main, isOwner: false)
    }

    // MARK: resolve

    @Test("an owner binding is always unrestricted, whatever grant is passed")
    func ownerIsUnrestricted() {
        #expect(FilesystemPolicy.resolve(binding: owner(), grant: nil) == .unrestrictedOwner)
        #expect(FilesystemPolicy.resolve(binding: owner(), grant: JobGrant(mounts: [ContainerMount(source: "/tmp", target: "/tmp", readOnly: false)])) == .unrestrictedOwner)
    }

    @Test("a non-owner binding is confined, even with no grant at all (empty grant = confined to nothing)")
    func nonOwnerIsConfined() {
        #expect(FilesystemPolicy.resolve(binding: nonOwner(), grant: nil) == .confined(JobGrant()))
        let grant = JobGrant(mounts: [ContainerMount(source: "/tmp/work", target: "/tmp/work", readOnly: false)])
        #expect(FilesystemPolicy.resolve(binding: nonOwner(), grant: grant) == .confined(grant))
    }

    // MARK: grant(fromFsRoots:) -- dev-3 review of #1217, round 2

    /// `grant(fromFsRoots:)` must route each root through `JobGrant.resolve`'s own validation, not
    /// build a mount from the raw string -- a mutant doing the latter survived every prior test,
    /// since none of them named a root `resolve` itself would refuse.
    @Test("a too-broad root (the real home) is dropped from the grant, not mounted as-is")
    func tooBroadRootIsDropped() {
        let grant = FilesystemPolicy.grant(fromFsRoots: ["~"])
        #expect(grant.mounts.isEmpty, "the home directory must never become a confinement mount")
    }

    @Test("a startup-location root (~/Library/LaunchAgents) is dropped from the grant")
    func startupLocationRootIsDropped() {
        let grant = FilesystemPolicy.grant(fromFsRoots: ["~/Library/LaunchAgents"])
        #expect(grant.mounts.isEmpty)
    }

    @Test("a credential-store root (~/.ssh) is dropped from the grant too, not only denied at read time")
    func credentialStoreRootIsDropped() {
        let grant = FilesystemPolicy.grant(fromFsRoots: ["~/.ssh"])
        #expect(grant.mounts.isEmpty)
    }

    @Test("a valid root alongside a too-broad one: the valid one still mounts, the invalid one is dropped")
    func validRootSurvivesBesideAnInvalidOne() throws {
        try withHome { home in
            let ok = home + "/workdir"
            try FileManager.default.createDirectory(atPath: ok, withIntermediateDirectories: true)
            let grant = FilesystemPolicy.grant(fromFsRoots: ["~", ok])
            #expect(grant.mounts.count == 1, "\(grant.mounts)")
            #expect(grant.mounts.first?.source == ok)
        }
    }

    // MARK: the non-owner host-read denial set -- Review Focus 4

    private func withHome(_ body: (String) throws -> Void) rethrows {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-fs-policy-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try body(home)
    }

    @Test("a non-owner host read of a denied store is refused", arguments: [
        "/.git-credentials", "/.netrc", "/.ssh", "/.ssh/id_rsa", "/.config/gh", "/.config/gh/hosts.yml", "/.config", "/.iris", "/.iris-dev",
    ])
    func deniedStoresAreRefused(_ suffix: String) {
        withHome { home in
            #expect(FilesystemPolicy.deniesNonOwnerHostRead(home + suffix, home: home))
        }
    }

    /// dev-3 review of #1217, round 2: the superset claim pinned against the real list, not a
    /// hand-picked subset -- a mutant that dropped `JobGrant.isCredentialStore` from the check
    /// survived every prior test because none of them happened to touch `.aws`/`.gnupg`/`.kube`/
    /// `.docker`/`.password-store`/Keychains, which only `credentialStores` names.
    @Test("every entry JobGrant.credentialStores names is also denied here", arguments: JobGrant.credentialStores)
    func everyJobGrantCredentialStoreIsDenied(_ entry: String) {
        withHome { home in
            let suffix = String(entry.dropFirst())   // "~/.aws" -> "/.aws"
            #expect(FilesystemPolicy.deniesNonOwnerHostRead(home + suffix, home: home), Comment(rawValue: entry))
        }
    }

    @Test("an ordinary path outside every denied store is not refused by this rule")
    func ordinaryPathIsNotDenied() {
        withHome { home in
            #expect(!FilesystemPolicy.deniesNonOwnerHostRead(home + "/Documents/notes.txt", home: home))
            #expect(!FilesystemPolicy.deniesNonOwnerHostRead("/tmp/work/file.txt", home: home))
        }
    }

    /// Review Focus 4, the security-critical case: a symlink that LOOKS like an ordinary path but
    /// resolves into a denied store must be caught -- the denial compares resolved (canonical)
    /// paths, never the raw spelling.
    @Test("a symlink into a denied store is refused, not just the store's own spelling")
    func symlinkIntoDeniedStoreIsRefused() throws {
        try withHome { home in
            let credStore = home + "/.config/gh"
            try FileManager.default.createDirectory(atPath: credStore, withIntermediateDirectories: true)
            try "token: secret".write(toFile: credStore + "/hosts.yml", atomically: true, encoding: .utf8)
            let decoy = home + "/Documents"
            try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: true)
            let link = decoy + "/notes.txt"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: credStore + "/hosts.yml")

            #expect(FilesystemPolicy.deniesNonOwnerHostRead(link, home: home),
                    "a symlink that resolves into the denied store must be refused, not treated as an ordinary file under Documents")
        }
    }

    /// Review Focus 4, the second case the planner named: a `..`-containing path that walks out of
    /// an apparently-safe directory and into a denied store.
    @Test("a `..`-containing path that walks into a denied store is refused")
    func dotDotIntoDeniedStoreIsRefused() throws {
        try withHome { home in
            let credStore = home + "/.ssh"
            try FileManager.default.createDirectory(atPath: credStore, withIntermediateDirectories: true)
            try "key material".write(toFile: credStore + "/id_rsa", atomically: true, encoding: .utf8)
            let viaDotDot = home + "/Documents/../.ssh/id_rsa"

            #expect(FilesystemPolicy.deniesNonOwnerHostRead(viaDotDot, home: home))
        }
    }

    @Test("the denial is case-insensitive, matching the rest of this codebase's path comparisons")
    func caseInsensitive() {
        withHome { home in
            #expect(FilesystemPolicy.deniesNonOwnerHostRead(home + "/.SSH/id_rsa", home: home))
        }
    }

    // MARK: wired into ToolExecutor.execute (the "today it is host-always" fix)

    private func tree() throws -> (base: URL, allowed: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-fs-policy-exec-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (base, allowed, outside)
    }

    @Test("read_file is confined to the fsRoots grant for a non-owner, with no sandboxGrant and !isBackground -- today it is host-always")
    func readFileConfinedForNonOwner() async throws {
        let (base, allowed, outside) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "inside".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try "outside".write(to: outside.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: JobGrant(mounts: [ContainerMount(source: allowed.path)]))

        let insideResult = await ToolExecutor().execute(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], filesystemPolicy: policy)
        #expect(insideResult.contains("inside"))

        let outsideResult = await ToolExecutor().execute(name: "read_file", args: ["path": .string(outside.appendingPathComponent("y.txt").path)], filesystemPolicy: policy)
        #expect(!outsideResult.contains("outside"), "a non-owner must not read outside its fsRoots grant: \(outsideResult)")
    }

    @Test("read_file is refused outright for a non-owner with an empty fsRoots grant")
    func readFileRefusedWithEmptyGrant() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "secret".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: nil)

        let result = await ToolExecutor().execute(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], filesystemPolicy: policy)
        #expect(!result.contains("secret"))
    }

    @Test("read_file is unaffected for an owner binding, same path, same policy resolution")
    func readFileUnaffectedForOwner() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "owner content".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: owner(), grant: nil)

        let result = await ToolExecutor().execute(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], filesystemPolicy: policy)
        #expect(result.contains("owner content"))
    }

    @Test("a non-owner's read_file is denied for a credential store even if it sits inside the fsRoots grant")
    func deniedStoreWinsEvenInsideTheGrant() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        let ghDir = allowed.appendingPathComponent(".config/gh")
        try FileManager.default.createDirectory(at: ghDir, withIntermediateDirectories: true)
        try "token".write(to: ghDir.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: JobGrant(mounts: [ContainerMount(source: allowed.path)]))

        let result = await ToolExecutor().execute(name: "read_file", args: ["path": .string(ghDir.appendingPathComponent("hosts.yml").path)],
                                                    filesystemPolicy: policy, home: allowed.path)
        #expect(!result.contains("token"))
    }

    @Test("write_file is confined to the fsRoots grant for a non-owner, and denied for a credential store")
    func writeFileConfinedForNonOwner() async throws {
        let (base, allowed, outside) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        let policy = FilesystemPolicy.resolve(binding: nonOwner(), grant: JobGrant(mounts: [ContainerMount(source: allowed.path)]))

        let insideResult = await ToolExecutor().execute(name: "write_file",
                                                          args: ["path": .string(allowed.appendingPathComponent("x.txt").path), "content": .string("hi")],
                                                          filesystemPolicy: policy)
        #expect(insideResult.contains("Successfully wrote"), Comment(rawValue: insideResult))

        let outsideResult = await ToolExecutor().execute(name: "write_file",
                                                           args: ["path": .string(outside.appendingPathComponent("y.txt").path), "content": .string("hi")],
                                                           filesystemPolicy: policy)
        #expect(!outsideResult.contains("Successfully wrote"), Comment(rawValue: outsideResult))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("y.txt").path))
    }
}

/// #974 Task 8 (C5), dev-2/dev-3 review finding 1: the real dispatcher (`executeFunctionCall` ->
/// `executeToolWithHooks`) sets `decidedPath` for every ordinary host read/write, which served
/// BEFORE `FilesystemPolicy`'s `.confined` fallback ever ran -- a test calling
/// `ToolExecutor.execute` directly with `decidedPath` nil (as `FilesystemPolicyTests` above does)
/// cannot see that, because production never takes that path. These tests drive a real engine
/// turn instead, the path a non-owner binding's call actually takes.
@MainActor
@Suite("FilesystemPolicy is enforced on the real dispatch path, not only ToolExecutor.execute directly (#974 Task 8)", .timeLimit(.minutes(1)))
struct FilesystemPolicyDispatchTests {
    private func nonOwner(fsRoots: Set<String> = []) -> AccessBinding {
        AccessBinding(profile: AccessProfile(fsRoots: fsRoots), principal: .main, isOwner: false)
    }

    private func session(_ call: FunctionCall, binding: AccessBinding) -> (AppState, IrisEngine, UUID) {
        let script: [[ScriptedStreamClient.Step]] = [
            [.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))],
            [.event(.textDelta("done")), .event(.done(finishReason: nil))],
        ]
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        app.selectedConversationId = id
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: ScriptedStreamClient(script),
                                retryDelays: [], streamResponses: true, protectionEnabled: false, sessionPeerCount: 0,
                                binding: binding)
        app.installEngine(engine)
        return (app, engine, id)
    }

    private func finished(_ app: AppState, _ id: UUID) -> Bool {
        (app.conversations.first { $0.id == id }?.history ?? []).contains { $0.role == "model" && $0.parts.contains { $0.text == "done" } }
    }

    private func toolResultText(_ app: AppState, _ id: UUID, callId: String) -> String? {
        for content in app.conversations.first(where: { $0.id == id })?.history ?? [] {
            for part in content.parts {
                if part.functionResponse?.id == callId { return part.functionResponse?.response["result"]?.stringValue }
            }
        }
        return nil
    }

    private func eventually(_ ms: Int = 5000, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<(ms / 25) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    private func tree() throws -> (base: URL, allowed: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-fs-policy-dispatch-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (base, allowed, outside)
    }

    @Test("a non-owner with an empty fsRoots grant cannot read_file through a real turn")
    func emptyGrantRefusesThroughRealTurn() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "secret content".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let call = FunctionCall(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], id: "c1")
        let (app, _, id) = session(call, binding: nonOwner())
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        let result = try #require(toolResultText(app, id, callId: "c1"))
        #expect(!result.contains("secret content"), Comment(rawValue: result))
    }

    /// dev-3 review of #1217, round 2: a too-broad fsRoot (the real home) must be dropped by
    /// `JobGrant.resolve`'s own validation along the real dispatch path too, not just when
    /// `grant(fromFsRoots:)` is called directly -- this is the "plus a real-turn test" half of
    /// finding 2.
    @Test("a non-owner whose fsRoots names a too-broad root (home) cannot read_file through a real turn")
    func tooBroadRootRefusesThroughRealTurn() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "secret content".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let call = FunctionCall(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], id: "c1")
        let (app, _, id) = session(call, binding: nonOwner(fsRoots: ["~"]))
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        let result = try #require(toolResultText(app, id, callId: "c1"))
        #expect(!result.contains("secret content"), Comment(rawValue: result))
    }

    @Test("a non-owner with an fsRoots grant elsewhere cannot read_file outside it through a real turn")
    func grantElsewhereRefusesThroughRealTurn() async throws {
        let (base, allowed, outside) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "secret content".write(to: outside.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        let call = FunctionCall(name: "read_file", args: ["path": .string(outside.appendingPathComponent("y.txt").path)], id: "c1")
        let (app, _, id) = session(call, binding: nonOwner(fsRoots: [allowed.path]))
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        let result = try #require(toolResultText(app, id, callId: "c1"))
        #expect(!result.contains("secret content"), Comment(rawValue: result))
    }

    @Test("a non-owner CAN read_file inside its own fsRoots grant through a real turn")
    func insideTheGrantWorksThroughRealTurn() async throws {
        let (base, allowed, _) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "readable content".write(to: allowed.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let call = FunctionCall(name: "read_file", args: ["path": .string(allowed.appendingPathComponent("x.txt").path)], id: "c1")
        let (app, _, id) = session(call, binding: nonOwner(fsRoots: [allowed.path]))
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        let result = try #require(toolResultText(app, id, callId: "c1"))
        #expect(result.contains("readable content"), Comment(rawValue: result))
    }

    @Test("a non-owner cannot write_file outside its fsRoots grant through a real turn")
    func writeOutsideGrantRefusedThroughRealTurn() async throws {
        let (base, allowed, outside) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = outside.appendingPathComponent("y.txt")
        let call = FunctionCall(name: "write_file", args: ["path": .string(target.path), "content": .string("hi")], id: "c1")
        let (app, _, id) = session(call, binding: nonOwner(fsRoots: [allowed.path]))
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        let result = try #require(toolResultText(app, id, callId: "c1"))
        #expect(!result.contains("Successfully wrote"), Comment(rawValue: result))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("an owner's read_file through a real turn is unaffected -- reads anywhere, as today")
    func ownerUnaffectedThroughRealTurn() async throws {
        let (base, _, outside) = try tree()
        defer { try? FileManager.default.removeItem(at: base) }
        try "owner content".write(to: outside.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        let call = FunctionCall(name: "read_file", args: ["path": .string(outside.appendingPathComponent("y.txt").path)], id: "c1")
        let (app, _, id) = session(call, binding: AccessBinding(profile: .owner, principal: .main, isOwner: true))
        app.sendMessage("go")
        #expect(await eventually { self.finished(app, id) })
        let result = try #require(toolResultText(app, id, callId: "c1"))
        #expect(result.contains("owner content"), Comment(rawValue: result))
    }
}

/// #974 Task 8 (C5), dev-3 review round 2: `requestApprovalSource`'s `isOwner` parameter still
/// defaults to `true`, so a new production call site that forgets to pass it would silently read
/// as owner rather than failing to build. This scan is the backstop until that default is removed
/// (tracked separately): every `requestApprovalSource(` call in `Sources/` must itself pass
/// `isOwner:` explicitly, one way or another.
@Suite("Every production call of requestApprovalSource passes isOwner explicitly (#974 Task 8)")
struct RequestApprovalSourceIsOwnerScanTests {
    /// Finds each balanced `requestApprovalSource(...)` call (not its definition) and checks
    /// `isOwner:` appears somewhere inside it. Call-site text, not line-by-line: the argument list
    /// spans several lines at every site in `iris.swift` today.
    @Test("every call of requestApprovalSource in Sources/ names isOwner:")
    func everyCallPassesIsOwnerExplicitly() throws {
        let sourcesDir = PerfPaths.repoRoot().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        var missing: [String] = []
        var total = 0
        for url in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            var searchFrom = text.startIndex
            while let callRange = text.range(of: "requestApprovalSource(", range: searchFrom..<text.endIndex) {
                // Skip the function's own definition (`func requestApprovalSource(`).
                let precedingText = text[text.startIndex..<callRange.lowerBound]
                if precedingText.hasSuffix("func ") { searchFrom = callRange.upperBound; continue }
                total += 1
                var depth = 1
                var i = callRange.upperBound
                while depth > 0, i < text.endIndex {
                    if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                    i = text.index(after: i)
                }
                let call = text[callRange.lowerBound..<i]
                if !call.contains("isOwner:") {
                    let line = text[text.startIndex..<callRange.lowerBound].components(separatedBy: "\n").count
                    missing.append("\(url.lastPathComponent):\(line)")
                }
                searchFrom = i
            }
        }
        #expect(total > 0, "the scan must find the real call sites, not run over nothing")
        #expect(missing.isEmpty, Comment(rawValue: missing.joined(separator: ", ")))
    }
}
