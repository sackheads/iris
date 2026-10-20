import Testing
import Foundation
@testable import IrisKit

/// #616: every folder a sandbox could ever write stays off the `PATH` a silent host read runs
/// with, after the conversation, grant or job that made it writable is gone. Each test has its own
/// home (`IrisPaths(root:)`), so none writes the process's test home's record (invariant 7).
@MainActor
@Suite("Writable roots are recorded and never forgotten (#616)", .timeLimit(.minutes(1)))
struct WritableRootsTests {
    private func tempDir(_ name: String = "d") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iris616-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func state() throws -> (AppState, WritableRootsRecord) {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let record = WritableRootsRecord(paths: IrisPaths(root: try tempDir("home")))
        state.writableRoots = record
        return (state, record)
    }

    @Test("a root is recorded once, as its real path, and a path with a newline can't break the file")
    func recordShape() throws {
        let record = WritableRootsRecord(paths: IrisPaths(root: try tempDir("home")))
        let real = try tempDir("real")
        let link = real.deletingLastPathComponent().appendingPathComponent("iris616-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let odd = try tempDir("a\nb")
        #expect(record.record([link.path, real.path, odd.path]))
        #expect(record.record([real.path]))
        let all = record.all()
        #expect(all.filter { $0 == IrisPaths.canonicalPath(real.path) }.count == 1, "the link and the folder are one root")
        #expect(all.contains(IrisPaths.canonicalPath(odd.path)))
        #expect(all.count == 2)
    }

    @Test("concurrent recorders: every root lands, each on a line of its own")
    nonisolated func concurrentRecorders() async throws {
        let record = WritableRootsRecord(paths: IrisPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("iris616-conc-\(UUID().uuidString)")))
        let roots = (0..<64).map { "/iris616-concurrent/\($0)-" + String(repeating: "x", count: 200) }
        await withTaskGroup(of: Bool.self) { group in
            for root in roots { group.addTask { record.record([root]) } }
            for await ok in group { #expect(ok) }
        }
        #expect(record.contents() == .roots(record.all()), "every line parses")
        #expect(Set(record.all()) == Set(roots.map { IrisPaths.canonicalPath($0) }))
    }

    @Test("a torn last line, or any line that won't parse, is damaged; a file not there yet is empty")
    func damaged() throws {
        let record = WritableRootsRecord(paths: IrisPaths(root: try tempDir("home")))
        #expect(record.contents() == .roots([]))
        #expect(record.record(["/iris616/a"]))
        let good = try Data(contentsOf: record.url)
        try (good + Data("\"/iris616/b".utf8)).write(to: record.url)
        #expect(record.contents() == .damaged, "torn last line")
        try (good + Data("\"/iris616/b\"".utf8)).write(to: record.url)
        #expect(record.contents() == .damaged, "a last line that parses but never got its newline")
        try (good + Data("not json\n".utf8)).write(to: record.url)
        #expect(record.contents() == .damaged, "unparseable line")
        try good.write(to: record.url)
        #expect(record.contents() == .roots([IrisPaths.canonicalPath("/iris616/a")]))

        // A root recorded after a torn line lands on a line of its own: deleting the broken line repairs it.
        try (good + Data("\"/iris616/torn".utf8)).write(to: record.url)
        #expect(record.record(["/iris616/c"]))
        let lines = try String(contentsOf: record.url, encoding: .utf8).split(separator: "\n").map(String.init)
        let lastRoot = try lines.last.map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        #expect(lastRoot == IrisPaths.canonicalPath("/iris616/c"), "its own line, which decodes")
        try (lines.filter { !$0.contains("torn") }.joined(separator: "\n") + "\n").write(to: record.url, atomically: true, encoding: .utf8)
        #expect(record.contents() == .roots([IrisPaths.canonicalPath("/iris616/a"), IrisPaths.canonicalPath("/iris616/c")]))
    }

    @Test("a workspace bind is recorded, and its folder stays writable after the conversation is deleted")
    func workspaceOutlivesConversation() throws {
        let (state, record) = try state()
        let ws = try tempDir("ws")
        let id = state.createNewConversation(isBackground: false, select: true)
        state.setWorkspace(for: id, path: ws.path)
        #expect(record.all().contains(IrisPaths.canonicalPath(ws.path)))
        state.deleteConversation(id)
        #expect(!state.liveWritableRoots().contains(ws.path))
        #expect(state.sandboxWritableRoots().contains(IrisPaths.canonicalPath(ws.path)))
    }

    @Test("a conversation's grant records its read-write mounts only, and a home opt-in is recorded")
    func grantAndOptIn() throws {
        let (state, record) = try state()
        let rw = try tempDir("rw"), ro = try tempDir("ro"), home = try tempDir("opt")
        let id = state.createNewConversation(isBackground: false, select: true)
        state.setSandboxGrant(for: id, JobGrant(mounts: [ContainerMount(source: rw.path, target: rw.path, readOnly: false),
                                                     ContainerMount(source: ro.path, target: ro.path, readOnly: true)],
                                            network: false))
        state.setHomeWritableOptIn(for: id, path: home.path)
        let all = record.all()
        #expect(all.contains(IrisPaths.canonicalPath(rw.path)))
        #expect(!all.contains(IrisPaths.canonicalPath(ro.path)))
        #expect(all.contains(IrisPaths.canonicalPath(home.path)))
    }

    @Test("a job's grant is recorded when it's resolved, before it's stored")
    func jobGrantRecorded() throws {
        let paths = IrisPaths(root: try tempDir("home"))
        let rw = try tempDir("job")
        let resolved = JobGrant.resolve(mounts: [rw.path], network: false, profile: .mutating, paths: paths, loginPath: [])
        guard case .success(let grant?) = resolved else { Issue.record("\(resolved)"); return }
        #expect(grant.mounts.first?.readOnly == false)
        #expect(WritableRootsRecord(paths: paths).all().contains(IrisPaths.canonicalPath(rw.path)))
    }

    @Test("launch seeds the record from the loaded conversations and every ledger job's grant")
    func launchSeed() throws {
        let (state, record) = try state()
        let rw = try tempDir("seed"), ws = try tempDir("seedws")
        var job = Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 600)), profile: .mutating)
        job.policy.grants = JobGrant(mounts: [ContainerMount(source: rw.path, target: rw.path, readOnly: false)], network: false)
        try state.store.ledger.upsert(job)
        let id = state.createNewConversation(isBackground: false, select: true)
        state.conversations[state.conversations.firstIndex { $0.id == id }!].workspacePath = ws.path   // as loaded, not bound
        #expect(!record.all().contains(IrisPaths.canonicalPath(rw.path)))
        state.seedWritableRoots()
        #expect(record.all().contains(IrisPaths.canonicalPath(rw.path)))
        #expect(record.all().contains(IrisPaths.canonicalPath(ws.path)))
    }

    @Test("the session manager records a mount before it creates the container, and refuses when it can't")
    func sessionRecordsFirst() async throws {
        let home = try tempDir("home")
        let ws = try tempDir("sess")
        let runtime = MockRuntime()
        let manager = SandboxSessionManager(runtime: runtime, image: { "ubuntu:latest" }, paths: IrisPaths(root: home))
        _ = await manager.run(command: "true", conversationId: UUID(),
                              workspace: ContainerMount(source: ws.path, target: ws.path, readOnly: false))
        #expect(WritableRootsRecord(paths: IrisPaths(root: home)).all().contains(IrisPaths.canonicalPath(ws.path)))
        #expect(runtime.created.count == 1)

        // A config folder that can't be written: no container.
        let blocked = try tempDir("blocked")
        try Data().write(to: blocked.appendingPathComponent("config"))   // a file where the folder goes
        let refused = MockRuntime()
        let strict = SandboxSessionManager(runtime: refused, image: { "ubuntu:latest" }, paths: IrisPaths(root: blocked))
        let out = await strict.run(command: "true", conversationId: UUID(),
                                   workspace: ContainerMount(source: ws.path, target: ws.path, readOnly: false))
        #expect(out.contains(WritableRootsRecord.refusal))
        #expect(refused.created.isEmpty)
    }

    @Test("a read-write grant on a login-PATH folder, under one, holding one, or through a link, is refused; read-only is fine")
    func loginPathRefused() throws {
        let paths = IrisPaths(root: try tempDir("home"))
        let prefix = try tempDir("brew")
        let bin = prefix.appendingPathComponent("bin")
        let sub = bin.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = prefix.deletingLastPathComponent().appendingPathComponent("iris616-binlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin)
        let loginPath = [bin.path]
        for source in [bin.path, sub.path, prefix.path, link.path] {
            let r = JobGrant.resolve(mounts: [source], network: false, profile: .mutating, paths: paths, loginPath: loginPath)
            guard case .failure(let why) = r else { Issue.record("\(source) was granted"); continue }
            #expect(why.text.contains("login PATH"), "\(source)")
        }
        let ro = JobGrant.resolve(mounts: [try tempDir("cwd").path, bin.path + ":" + bin.path + ":ro"], network: false,
                                  profile: .mutating, paths: paths, loginPath: loginPath)
        guard case .success = ro else { Issue.record("read-only refused: \(ro)"); return }

        // The real Homebrew bin, where this Mac has one.
        let brew = "/opt/homebrew/bin"
        if FileManager.default.fileExists(atPath: brew) {
            let r = JobGrant.resolve(mounts: [brew], network: false, profile: .mutating, paths: paths, loginPath: [brew])
            guard case .failure(let why) = r else { Issue.record("/opt/homebrew/bin was granted"); return }
            #expect(why.text.contains("login PATH"))
        }
    }

    @Test("a sandbox workspace at, inside or holding a login-PATH folder needs the opt-in, like home (#616 review)")
    func workspaceOnLoginPath() throws {
        let prefix = try tempDir("wsbrew")
        let bin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("x"), withIntermediateDirectories: true)
        for path in [bin.path, bin.appendingPathComponent("x").path, prefix.path] {
            #expect(HomeMount.reason(for: path, loginPath: [bin.path])?.contains("login PATH") == true, "\(path)")
        }
        #expect(HomeMount.reason(for: try tempDir("plain").path, loginPath: [bin.path]) == nil)
    }

    @Test("at fire, a stored read-write grant on a login-PATH folder is refused")
    func loginPathAtFire() throws {
        let bin = try tempDir("firebin")
        let grant = JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(bin.path), target: "/w", readOnly: false)], network: false)
        let reason = JobGrant.drift(grant, loginPath: [bin.path])
        #expect(reason == JobGrant.loginPathReason(IrisPaths.canonicalPath(bin.path), entry: bin.path))
        #expect(JobGrant.drift(grant, loginPath: []) == nil)
    }

    @Test("a recorded root stays off a silent read's PATH once nothing loaded names it")
    func restrictedPathHonoursRecord() throws {
        let (state, record) = try state()
        let bin = try tempDir("planted")
        #expect(record.record([bin.path]))
        let lookup = ReadOnlyCommand.HostLookup(path: bin.path + ":/usr/bin", cwd: "/tmp", home: NSHomeDirectory(),
                                                writableRoots: state.sandboxWritableRoots(), isExecutable: { _ in true })
        let path = ReadOnlyCommand.restrictedPath(program: "ls", cwd: "/tmp", lookup: lookup)
        #expect(path == ["/usr/bin"])
    }
}
