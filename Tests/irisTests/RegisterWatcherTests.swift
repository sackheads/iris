import Testing
import Foundation
@testable import iris

/// `register_directory_watcher`'s arguments, refusals and the per-conversation registration rule
/// (#187 deliverable 4, spec §5). An in-memory store, a temp directory the test removes, a volatile
/// `IrisPaths` root and an injected home: nothing reaches `~/.iris` or a shared singleton.
@Suite("register_directory_watcher")
struct RegisterWatcherTests {
    struct Fixture {
        let store: ConversationStore
        let executor: ToolExecutor
        let base: URL
        /// A directory named `notes`, so the job it creates is named `notes`.
        let notes: URL

        func register(_ extra: [String: JSONValue] = [:], path: String? = nil,
                      instructions: String = "summarise", conversationId: UUID = UUID()) async -> String {
            var args: [String: JSONValue] = ["path": .string(path ?? notes.path), "instructions": .string(instructions)]
            for (key, value) in extra { args[key] = value }
            return await executor.execute(name: "register_directory_watcher", args: args, conversationId: conversationId)
        }

        func watch() throws -> (job: Job, watch: FSWatch) {
            let job = try #require(try store.ledger.jobs().first)
            guard case .fsEvent(let watch) = job.trigger else {
                throw TestError("expected a watch trigger")
            }
            return (job, watch)
        }

        func tearDown() { try? FileManager.default.removeItem(at: base) }
    }

    struct TestError: Error { let text: String; init(_ text: String) { self.text = text } }

    private func fixture(mutatingJobsAvailable: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iris-regwatch-\(UUID().uuidString)")
        let notes = base.appendingPathComponent("notes")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        let irisRoot = base.appendingPathComponent("dot-iris")
        try fm.createDirectory(at: irisRoot.appendingPathComponent("config"), withIntermediateDirectories: true)
        let store = try ConversationStore.inMemory()
        var executor = ToolExecutor()
        executor.jobToolsProvider = { JobTools(ledger: store.ledger) }
        executor.irisPaths = IrisPaths(root: irisRoot)
        executor.homeDirectory = base.appendingPathComponent("home").path
        executor.mutatingJobsAvailable = { mutatingJobsAvailable }
        return Fixture(store: store, executor: executor, base: base, notes: notes)
    }

    @Test("the three optional arguments decode and the window is clamped to 300 with a note")
    func argumentsDecodeAndClamp() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let result = await f.register(["quiet_window_seconds": .int(900), "ignore": .array([.string("*.log")]),
                                       "overlap": .string("skip")])
        let stored = try f.watch()
        #expect(stored.watch.quietWindowSeconds == 300)
        #expect(stored.watch.ignore == ["*.log"])
        #expect(stored.job.policy.overlap == .skip)
        #expect(result.contains("The window was clamped to 300 s."))
        #expect(result.contains("quiet for 300 s (3000 s when changes never stop)"))
        #expect(result.contains("plus your 1 pattern"))

        // A window that needs no clamping earns no note; a numeric string is read like a number.
        let plain = await f.register(["quiet_window_seconds": .string("10")], conversationId: UUID())
        #expect(!plain.contains("clamped"))
        #expect(plain.contains("quiet for 10 s (100 s when changes never stop)"))
    }

    @Test("a non-array ignore or an unknown overlap is an error naming the argument; nothing is stored")
    func malformedArgumentsAreErrors() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let ignore = await f.register(["ignore": .string("*.log")])
        #expect(ignore.hasPrefix("Error"))
        #expect(ignore.contains("ignore"))
        let overlap = await f.register(["overlap": .string("sometimes")])
        #expect(overlap.hasPrefix("Error"))
        #expect(overlap.contains("overlap"))
        let window = await f.register(["quiet_window_seconds": .string("soon")])
        #expect(window.hasPrefix("Error"))
        #expect(window.contains("quiet_window_seconds"))
        #expect(try f.store.ledger.jobs().isEmpty)
    }

    @Test("an ignore list that absorbs every probe is refused; one that merely looks broad is not")
    func ignoreProbeRefusal() async throws {
        let f = try fixture(); defer { f.tearDown() }
        for pattern in ["*", "**/*", "?*"] {
            let result = await f.register(["ignore": .array([.string(pattern)])])
            #expect(result.contains(ToolExecutor.allIgnoredRefusal), "\(pattern) should be refused")
        }
        #expect(try f.store.ledger.jobs().isEmpty)
        for pattern in ["*.*", "*.log"] {
            let result = await f.register(["ignore": .array([.string(pattern)])], conversationId: UUID())
            #expect(!result.contains(ToolExecutor.allIgnoredRefusal), "\(pattern) should be accepted")
        }
        #expect(try f.store.ledger.jobs().count == 2)
    }

    @Test("a path that is not a directory is refused by name")
    func aMissingDirectoryIsRefused() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let missing = f.base.appendingPathComponent("nowhere").path
        let result = await f.register(path: missing)
        #expect(result == "That path does not exist or is not a directory: \(missing)")
        let file = f.notes.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let onFile = await f.register(path: file.path)
        #expect(onFile == "That path does not exist or is not a directory: \(file.path)")
        #expect(try f.store.ledger.jobs().isEmpty)
    }

    @Test("too-broad and protected roots are refused through the tool")
    func refusedRootsThroughTheTool() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let broad = await f.register(path: "/")
        #expect(broad.contains(WatchRoot.tooBroadRefusal))
        let protected = await f.register(path: f.executor.irisPaths!.configDir.path)
        #expect(protected.contains(WatchRoot.protectedRefusal))
        #expect(try f.store.ledger.jobs().isEmpty)
    }

    @Test("re-registering from the same conversation updates in place and keeps what was not re-said")
    func sameConversationUpdatesAndPreservesOmittedArguments() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let conversation = UUID()
        _ = await f.register(["quiet_window_seconds": .int(10), "ignore": .array([.string("*.log")]),
                              "overlap": .string("skip")],
                             instructions: "first", conversationId: conversation)
        var paused = try f.watch().job
        paused.enabled = false
        paused.pausedReason = "watched directory is gone"
        try f.store.ledger.upsert(paused)

        let result = await f.register(instructions: "second", conversationId: conversation)
        let jobs = try f.store.ledger.jobs()
        #expect(jobs.count == 1)
        let stored = try f.watch()
        #expect(stored.job.id == paused.id)
        #expect(stored.job.prompt == "second")
        #expect(stored.watch.quietWindowSeconds == 10)
        #expect(stored.watch.ignore == ["*.log"])
        #expect(stored.job.policy.overlap == .skip)
        #expect(stored.job.enabled)
        #expect(stored.job.pausedReason == nil)
        #expect(result.contains("updated your watch `notes`"))
        #expect(!result.contains("now has"))

        // Matching is by canonical path, case-insensitively (R-D4-8): the upper-cased spelling of
        // the same directory is the same watch on the default volume.
        let upper = f.notes.deletingLastPathComponent().appendingPathComponent("NOTES").path
        if FileManager.default.fileExists(atPath: upper) {
            _ = await f.register(path: upper, instructions: "third", conversationId: conversation)
            #expect(try f.store.ledger.jobs().count == 1)
            #expect(try f.watch().job.prompt == "third")
        }
    }

    @Test("another conversation on the same path gets its own suffixed watch and hears the count")
    func anotherConversationGetsASuffixedWatch() async throws {
        let f = try fixture(); defer { f.tearDown() }
        _ = await f.register(instructions: "first")
        let result = await f.register(instructions: "second")
        let jobs = try f.store.ledger.jobs().sorted { $0.name < $1.name }
        #expect(jobs.map(\.name) == ["notes", "notes-2"])
        #expect(jobs.map(\.prompt) == ["first", "second"])
        #expect(result.contains("created `notes-2`"))
        #expect(result.contains("`notes` belongs to another conversation"))
        #expect(result.contains("this folder now has 2 watches, each of which runs on every change"))
    }

    @Test("overlap defaults to queue on a new watch and skip is honoured when asked for")
    func overlapDefaultsToQueueAndSkipIsHonoured() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let conversation = UUID()
        let created = await f.register(conversationId: conversation)
        #expect(try f.watch().job.policy.overlap == .queue)
        #expect(created.contains("never alongside its own previous run"))
        #expect(created.contains("it ignores .git/, .DS_Store, node_modules/"))
        #expect(!created.contains("plus your"))
        _ = await f.register(["overlap": .string("skip")], conversationId: conversation)
        #expect(try f.watch().job.policy.overlap == .skip)
        // Omitted again: the choice made last time stands.
        _ = await f.register(conversationId: conversation)
        #expect(try f.watch().job.policy.overlap == .skip)
    }

    @Test("a watch takes profile, mounts and network; a grant on a read-only watch is refused; the watched folder is not implicitly granted")
    func watchGrant() async throws {
        let f = try fixture(); defer { f.tearDown() }
        let out = f.base.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let refused = await f.register(["mounts": .string(out.path)])
        #expect(refused == "Not watching \(IrisPaths.canonicalPath(f.notes.path)): mounts: \(JobGrant.grantNeedsMutating)")
        #expect(try f.store.ledger.jobs().isEmpty)

        let conversation = UUID()
        let result = await f.register(["profile": .string("mutating"), "mounts": .string(out.path), "network": .bool(true)],
                                      conversationId: conversation)
        let (job, _) = try f.watch()
        #expect(job.profile == .mutating)
        #expect(job.policy.grants == JobGrant(mounts: [ContainerMount(source: IrisPaths.canonicalPath(out.path))], network: true))
        #expect(job.policy.grants?.mounts.map(\.source).contains(IrisPaths.canonicalPath(f.notes.path)) == false,
                "the watched folder is not in the grant unless named")
        #expect(result.hasSuffix(" Grant: read-write \(IrisPaths.canonicalPath(out.path)) (working directory) · network on."))

        // Re-registering from the same conversation without mounts removes the grant and keeps the profile.
        _ = await f.register([:], conversationId: conversation)
        let again = try f.watch().job
        #expect(again.id == job.id && again.profile == .mutating && again.policy.grants == nil)
    }

    @Test("a mutating watch needs the VM, exactly as a mutating job does")
    func mutatingWatchNeedsSandbox() async throws {
        let f = try fixture(mutatingJobsAvailable: false); defer { f.tearDown() }
        let result = await f.register(["profile": .string("mutating")])
        #expect(result == ToolExecutor.watchProfileNeedsSandbox)
        #expect(try f.store.ledger.jobs().isEmpty)
    }
}
