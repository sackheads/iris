import Testing
import Foundation
import GRDB
@testable import IrisKit

/// `iris --run-job <id-or-name> [--dry-run] [--json]` (#187 spec §8, ruling R35): one job, run once
/// from a terminal, against a store this process opened itself.
///
/// Everything here goes through the injected seams — an in-memory store, a `FakeLLMClient`, a lock
/// path under the temp directory — so the suite never opens `~/.iris`, never reaches the network
/// and never writes a process global (AGENTS invariant 7). The two flags a headless run must NOT
/// touch (`HeadlessMode`, the volatile defaults) are asserted rather than assumed: they are what
/// keeps a CLI run's approvals as fail-closed as an unattended one's.
@MainActor
@Suite("iris --run-job (#187 §8)", .timeLimit(.minutes(1)))
final class RunJobCLITests {

    // MARK: Fixtures

    /// A sink the test can read back, standing in for stdout/stderr.
    final class Output: @unchecked Sendable {
        private(set) var lines: [String] = []
        func write(_ text: String) { lines.append(text) }
        var text: String { lines.joined(separator: "\n") }
    }

    private func job(name: String = "pr-sweep",
                     prompt: String = "Reply with just the word tick.",
                     trigger: Trigger = .schedule(.interval(seconds: 60))) -> Job {
        Job(name: name, prompt: prompt, trigger: trigger)
    }

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    /// Samples `HeadlessMode.isEnabled` from inside the live model call — the only place a
    /// task-local scope is actually visible. Reading `isEnabled` after `RunJobCLI.run` returns (as
    /// this suite used to) can never catch a regression: `HeadlessMode.withEnabled`'s scope closes
    /// the moment its body returns, which is before `run` hands control back to its caller, so a
    /// `run` that wrapped itself in `withEnabled` would still read `false` afterward. Sampling
    /// during the call is the only way to tell the two apart (#318 fix round 1).
    final class HeadlessProbingLLMClient: LLMClientProtocol, @unchecked Sendable {
        private let inner: FakeLLMClient
        private(set) var sawHeadlessDuringCall = false
        init(responses: [GeminiResponse]) { inner = FakeLLMClient(responses: responses) }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            if HeadlessMode.isEnabled { sawHeadlessDuringCall = true }
            return try await inner.generateContent(request: request, tier: tier)
        }
    }

    private func callResponse(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: name, args: args))]))],
                       usageMetadata: nil)
    }

    /// A client that reports what it saw the instant it is asked — the one moment that is
    /// unambiguously "during the run".
    final class ProbingLLMClient: LLMClientProtocol, @unchecked Sendable {
        private let reply: String
        private let probe: @Sendable () -> Void
        init(reply: String, probe: @escaping @Sendable () -> Void) {
            self.reply = reply
            self.probe = probe
        }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            probe()
            return GeminiResponse(candidates: [Candidate(content: Content(
                role: "model", parts: [Part(text: reply)]))], usageMetadata: nil)
        }
    }

    /// A lock path of this test's own, under the temp directory — never beside the real store.
    /// Every lock path this instance hands out lives under `base`, which `deinit` removes: lock
    /// files now outlive a run (decision 2), and a crowded `TMPDIR` slows Foundation's listings to
    /// seconds (#309). The held descriptors stay open on the unlinked files, which is harmless.
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent("iris-runjob-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: base) }

    private func lockPath() -> URL {
        base.appendingPathComponent(UUID().uuidString).appendingPathComponent("conversations.sqlite.lock")
    }

    // MARK: Parsing

    @Test("no --run-job at all is a normal app launch, not an invocation")
    func parseReturnsNilWithoutTheFlag() {
        #expect(RunJobCLI.parse(arguments: ["iris"]) == nil)
        #expect(RunJobCLI.parse(arguments: ["iris", "--bench", "--json"]) == nil)
    }

    @Test("a name, an id, and both flags in either order")
    func parseAcceptsATargetAndItsFlags() throws {
        let byName = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job", "pr-sweep"]))
        #expect(byName.target == "pr-sweep")
        #expect(byName.dryRun == false)
        #expect(byName.json == false)
        #expect(byName.problem == nil)

        let id = UUID().uuidString
        let byId = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job", id, "--json", "--dry-run"]))
        #expect(byId.target == id)
        #expect(byId.dryRun)
        #expect(byId.json)

        let flagsFirst = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job", "--dry-run", "pr-sweep"]))
        #expect(flagsFirst.target == "pr-sweep")
        #expect(flagsFirst.dryRun)
    }

    @Test("bad input parses into a problem rather than a guess")
    func parseRejectsBadInput() throws {
        let missing = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job"]))
        #expect(missing.target == nil)
        #expect(missing.problem != nil)

        let flagOnly = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job", "--json"]))
        #expect(flagOnly.target == nil)
        #expect(flagOnly.problem != nil)

        let unknown = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job", "pr-sweep", "--wat"]))
        #expect(unknown.problem != nil)

        // A job name may contain spaces, so it has to arrive as one argument: two bare words are a
        // quoting mistake, and picking the first would run a job the caller did not name.
        let twoWords = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job", "pr", "sweep"]))
        #expect(twoWords.problem != nil)
    }

    @Test("a usage problem exits 1 and prints the usage line")
    func usageProblemExitsOne() async throws {
        let store = try ConversationStore.inMemory()
        let err = Output()
        let invocation = try #require(RunJobCLI.parse(arguments: ["iris", "--run-job"]))
        let code = await RunJobCLI.run(invocation, store: store,
                                       client: FakeLLMClient(responses: []),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains(RunJobCLI.usage))
    }

    @Test("the exit codes are the numbers, not whatever the constants happen to say")
    func exitCodesArePinnedToTheirLiterals() {
        // R35 and the docs promise 0/1/2/3 to scripts, and every other assertion in this file
        // compares the implementation against its own constants — so all of them still pass with
        // `notCompleted` set to 55. These four literals are the contract.
        #expect(RunJobCLI.Exit.completed == 0)
        #expect(RunJobCLI.Exit.usage == 1)
        #expect(RunJobCLI.Exit.notCompleted == 2)
        #expect(RunJobCLI.Exit.gateUnchanged == 3)
    }

    @Test("the state a CLI run fires through never auto-approves, and is not a launch")
    func theCLIStateFailsClosedAndLeavesNothingBehind() throws {
        let store = try ConversationStore.inMemory()
        let state = RunJobCLI.makeState(store: store)
        // §8: approvals fail closed exactly as unattended. Set in `makeState`, read back here,
        // because a flag that is only ever written is a flag whose default can change underneath.
        #expect(state.autoApproveTools == false)
        // And an empty store is left empty: a measurement command must not commit a "New
        // Conversation" (or a launch notice) to somebody's real database on its way past.
        #expect(state.conversations.isEmpty)
        #expect(state.selectedConversationId == nil)
    }

    @Test("a CLI run over an empty store leaves only the run's own conversations behind")
    func aRunAddsNoLaunchConversation() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "tidy")
        try store.ledger.upsert(job)
        _ = await RunJobCLI.run(RunJobCLI.Invocation(target: "tidy"), store: store,
                                client: FakeLLMClient(responses: [textResponse("done")]),
                                lockPath: lockPath(), protectionEnabled: false,
                                out: { _ in }, err: { _ in })

        let reloaded = try store.loadAll().conversations
        // Exactly two, both the run's: its hidden transcript and the pinned conversation (Iris) the
        // card was delivered to. No "New Conversation", no launch notice.
        #expect(reloaded.count == 2, "found: \(reloaded.map(\.title))")
        #expect(reloaded.contains { $0.isBackground })
        #expect(reloaded.contains { $0.title == AppState.activityConversationTitle })
    }

    @Test("a run holds the lock while it runs, with its own payload, and keeps both until IrisMain exits")
    func aRunHoldsTheLockWhileItRuns() async throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(self.job(name: "holder"))
        let path = lockPath()
        let seen = LockedCell<StoreLock.Holder?>(nil)
        let client = ProbingLLMClient(reply: "done") { seen.value = StoreLock.readHolder(at: path) }
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "holder"), store: store,
                                       client: client, lockPath: path, protectionEnabled: false,
                                       out: { _ in }, err: { _ in })
        #expect(code == RunJobCLI.Exit.completed)
        #expect(seen.value == .init(pid: ProcessInfo.processInfo.processIdentifier, kind: .runJob, job: "holder"))
        #expect(StoreLock.readHolder(at: path) == seen.value,
                "not vacated in `run`: IrisMain vacates just before `_exit`, so no empty payload sits under a held lock")
        #expect(StoreLock.holds(path), "and still held: the process exits next (decision 2)")
    }

    // MARK: The store lock (#463 decision 7)

    /// One integer from the database file at `url`. Synchronous on purpose: inside an async test
    /// GRDB's `read` resolves to its async overload.
    private func sqlInt(_ url: URL, _ sql: String, _ arguments: StatementArguments = []) throws -> Int? {
        try DatabaseQueue(path: url.path).read { try Int.fetchOne($0, sql: sql, arguments: arguments) }
    }

    @Test("a stub --run-job holding the lock: exit 1 naming it, and the store is never opened")
    func refusedRunNeverOpensTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-runjob-\(UUID().uuidString)")
        let db = dir.appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try ConversationStore.onDisk(at: db)   // a real, migrated store, closed again
        // The count first: closing a reader can checkpoint the WAL into the file, so the mtime is
        // taken after it, and compared before the second read.
        let migrations = try sqlInt(db, "SELECT count(*) FROM grdb_migrations")
        let mtime = try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date
        let lock = db.appendingPathExtension("lock")
        let stub = try LockStub.start(holding: lock, payload: #"{"job":"nightly","kind":"run-job","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        let opened = LockedCell(0)
        func openStore() throws -> ConversationStore {
            opened.value += 1
            return try ConversationStore.onDisk(at: db)
        }

        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try openStore(),
                                       client: FakeLLMClient(responses: []), lockPath: lock,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })

        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("another --run-job (pid \(stub.pid), job nightly)"))
        #expect(opened.value == 0, "the store factory never ran")
        #expect(try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date == mtime)
        #expect(try sqlInt(db, "SELECT count(*) FROM grdb_migrations") == migrations)
    }

    @Test("the app holding the lock is named as the app")
    func appHolderIsNamed() async throws {
        let lock = lockPath()
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: lock, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try ConversationStore.inMemory(),
                                       client: FakeLLMClient(responses: []), lockPath: lock,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("the Iris app (pid \(stub.pid))"))
    }

    @Test("--dry-run claims too")
    func dryRunClaims() async throws {
        let lock = lockPath()
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: lock, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        // A job that exists and has a gate, so the only thing that can refuse is the lock.
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(self.job(name: "polled",
                                         trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                                                 gate: .pathChanged(path: "/tmp/whatever")))))
        let opened = LockedCell(0)
        func openStore() throws -> ConversationStore { opened.value += 1; return store }
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "polled", dryRun: true),
                                       store: try openStore(), client: FakeLLMClient(responses: []),
                                       lockPath: lock, protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("the Iris app (pid \(stub.pid))"))
        #expect(opened.value == 0)
    }

    @Test("a lock that cannot be taken is exit 1 naming the path and errno, and the store is never opened")
    func failedLockRefuses() async throws {
        let lock = lockPath()
        var calls = StoreLock.Syscalls.live
        calls.flock = { _, _ in errno = ENOLCK; return -1 }
        let opened = LockedCell(0)
        func openStore() throws -> ConversationStore { opened.value += 1; return try ConversationStore.inMemory() }
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try openStore(),
                                       client: FakeLLMClient(responses: []), lockPath: lock, lockSyscalls: calls,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains(lock.path))
        #expect(err.text.contains("errno \(ENOLCK)"))
        #expect(opened.value == 0)
    }

    @Test("a pre-#463 holder (a bare live pid) refuses")
    func legacyHolderRefuses() async throws {
        let lock = lockPath()
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parent = getppid()   // alive, this user's, not us, started before the file was written
        try Data("\(parent)\n".utf8).write(to: lock)
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: try ConversationStore.inMemory(),
                                       client: FakeLLMClient(responses: []), lockPath: lock,
                                       protectionEnabled: false, out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("an older Iris build (pid \(parent))"))
        // A bare pid may have been reused by something that is not Iris, and only then is
        // deleting the file the way out; the refusal names the file so the user can.
        #expect(err.text.contains(lock.path))
    }

    @Test("no refusal for a JSON-payload holder ever tells the user to delete the lock file")
    func refusalsNeverAdviseDeletingALiveLock() {
        let path = URL(fileURLWithPath: "/tmp/x/conversations.sqlite.lock")
        let claims: [StoreLock.Claim] = [
            .held(.init(pid: 42, kind: .app, job: nil)),
            .held(.init(pid: 42, kind: .runJob, job: "nightly")),
            .held(.init(pid: 42, kind: .seedDevHome, job: nil)),
            .held(.init(pid: 42, kind: .perf, job: nil)),
            .held(nil),
            .failed(detail: "flock \(path.path): No locks available (errno 77)"),
        ]
        for claim in claims {
            let text = RunJobCLI.refusal(for: claim, path: path) ?? ""
            #expect(!text.isEmpty, "\(claim) refuses")
            #expect(!text.lowercased().contains("delete"), "\(claim): \(text)")
        }
        #expect(RunJobCLI.refusal(for: .acquired, path: path) == nil)
    }

    // A regression pin for the CLI's half of #463, not the repro: the two runs here are sequential.
    // The interleaved one (an app launched during a CLI run) is LaunchGateTests'.
    @Test("regression pin (#463): behind a holder the CLI never opens the store; after it dies a run's card is at its ordinal")
    func refusedRunOpensNothingAndTheNextCardLandsAtItsOrdinal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-runjob-\(UUID().uuidString)")
        let db = dir.appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A first run puts a card in Iris (the pinned conversation), so the second card has an
        // ordinal to land after. Its own lock path: a lock this process holds is never released.
        let seed = try ConversationStore.onDisk(at: db)
        let job = self.job(name: "nightly")
        try seed.ledger.upsert(job)
        let first = await RunJobCLI.run(RunJobCLI.Invocation(target: "nightly"), store: seed,
                                        client: FakeLLMClient(responses: [textResponse("first")]),
                                        lockPath: lockPath(), protectionEnabled: false,
                                        out: { _ in }, err: { _ in })
        #expect(first == RunJobCLI.Exit.completed)
        let firstRun = try #require(try seed.ledger.runs(jobId: job.id, limit: 1).first)

        let lock = lockPath()
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stub = try LockStub.start(holding: lock, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        let opened = LockedCell(0)
        func openStore() throws -> ConversationStore {
            opened.value += 1
            return try ConversationStore.onDisk(at: db)
        }
        let refused = await RunJobCLI.run(RunJobCLI.Invocation(target: "nightly"), store: try openStore(),
                                          client: FakeLLMClient(responses: [textResponse("never")]),
                                          lockPath: lock, protectionEnabled: false,
                                          out: { _ in }, err: { _ in })
        #expect(refused == RunJobCLI.Exit.usage)
        #expect(opened.value == 0, "nothing opens the store while the stub holds the lock")

        stub.kill()
        let second = await RunJobCLI.run(RunJobCLI.Invocation(target: "nightly"), store: try openStore(),
                                         client: FakeLLMClient(responses: [textResponse("second")]),
                                         lockPath: lock, protectionEnabled: false,
                                         out: { _ in }, err: { _ in })
        #expect(second == RunJobCLI.Exit.completed)
        #expect(opened.value == 1)

        let runs = try ConversationStore.onDisk(at: db).ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 2, "the refused run wrote no row")
        let iris = try #require(try ConversationStore.onDisk(at: db).loadAll().conversations
            .first { $0.title == AppState.activityConversationTitle })
        let cardIndices = iris.messages.indices.filter { EventCard.decode(iris.messages[$0].content) != nil }
        #expect(cardIndices.count == 2, "both runs' cards are in Iris")
        let last = try #require(cardIndices.last)
        #expect(last == iris.messages.count - 1, "the second card is the last message")
        let secondRun = try #require(runs.first { $0.id != firstRun.id })
        #expect(EventCard.decode(iris.messages[last].content)?.runId == secondRun.id)
        // And on disk at that same ordinal, not merely in the loaded array.
        let ordinal = try sqlInt(db, "SELECT ordinal FROM messages WHERE conversationId = ? AND id = ?",
                                 [iris.id.uuidString, iris.messages[last].id.uuidString])
        #expect(ordinal == last)
    }

    // MARK: Lookup

    @Test("a name nobody has is a lookup error, not a run")
    func unknownJobExitsOne() async throws {
        let store = try ConversationStore.inMemory()
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "no-such-job"), store: store,
                                       client: FakeLLMClient(responses: []),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("no-such-job"))
    }

    @Test("a lookup failure under --json is one error object, not a sentence a script cannot read")
    func unknownJobUnderJSONIsAnErrorObject() async throws {
        let store = try ConversationStore.inMemory()
        let out = Output()
        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "no-such-job", json: true),
                                       store: store, client: FakeLLMClient(responses: []),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { out.write($0) }, err: { err.write($0) })

        #expect(code == RunJobCLI.Exit.usage)
        // Both, on purpose: the sentence goes to stderr where a person reads it, and the same
        // failure goes to stdout as an object, because a `--json` run is something `jq` is
        // pointed at and a bare sentence there is a parse error rather than a result.
        #expect(err.text.contains("no-such-job"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any])
        #expect((object["error"] as? String)?.contains("no-such-job") == true)
        #expect(object["exitCode"] as? Int == Int(RunJobCLI.Exit.usage))
        #expect(object["dryRun"] as? Bool == false)
    }

    @Test("a ledger that cannot be read before the fire suppresses the row rather than printing an older one")
    func anUnreadableLedgerPrintsNoRow() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "unreadable")
        try store.ledger.upsert(job)
        // An earlier run of the same job: exactly the row that would be reported as this fire's
        // if a failed "what was newest before?" read were swallowed to nil.
        let earlier = JobRun(jobId: job.id, jobName: job.name, triggerKind: "schedule",
                             startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.ledger.begin(run: earlier)
        try store.ledger.finish(runId: earlier.id, status: .completed, outcome: "an older run",
                                failureReason: nil, blockedTool: nil, tokens: TokenUsage(),
                                finishedAt: Date(timeIntervalSince1970: 1_700_000_060))
        // The only honest way to make the read fail: take the table away. Every `job_runs` read
        // and write then throws, which is what a corrupt or locked database looks like from here.
        try await store.writer.write { db in try db.execute(sql: "DROP TABLE job_runs") }

        let out = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: job.name), store: store,
                                       client: FakeLLMClient(responses: [textResponse("tick")]),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(out.text.contains("the ledger could not be read before the fire"))
        #expect(!out.text.contains("an older run"),
                "the earlier run is not this fire's, and must not be printed as if it were")
        #expect(!out.text.contains(earlier.id.uuidString.lowercased().prefix(8)))
    }

    // MARK: A real run

    @Test("a completed run exits 0, prints its ledger row, and leaves the card behind")
    func completedRunExitsZeroAndPrintsTheRow() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job()
        try store.ledger.upsert(job)
        let out = Output()
        let client = FakeLLMClient(responses: [textResponse("swept 3 PRs")])

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: job.name), store: store,
                                       client: client, lockPath: lockPath(), protectionEnabled: false,
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.completed)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .completed)
        #expect(run.triggerKind == "manual", "a CLI run is a hand-started fire, like /jobs run")
        #expect(out.text.contains("status: completed"))
        #expect(out.text.contains("swept 3 PRs"))
        #expect(out.text.contains(run.id.uuidString.lowercased().prefix(8)))
        #expect(out.text.contains("tokens:"))
        #expect(out.text.contains("duration:"))

        // §8: the card is delivered like any run, so Iris, the pinned conversation, shows it the
        // next time the app opens — which means it has to be ON DISK when the CLI exits, not only in
        // the app state the CLI threw away.
        let reloaded = try store.loadAll().conversations
        let cards = reloaded.flatMap { $0.messages.compactMap { EventCard.decode($0.content) } }
        #expect(cards.contains { $0.runId == run.id && $0.status == .completed })
    }

    @Test("a CLI run never executes inside a headless scope, and touches no volatile defaults")
    func aRunLeavesTheProcessGlobalsAlone() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "quiet")
        try store.ledger.upsert(job)
        let client = HeadlessProbingLLMClient(responses: [textResponse("ok")])
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "quiet"), store: store,
                                       client: client,
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { _ in }, err: { _ in })
        #expect(code == RunJobCLI.Exit.completed)
        // Sampled from inside the model call (see `HeadlessProbingLLMClient`), not after `run`
        // returns: `HeadlessMode` is now a task-local scope rather than a flag that flips and stays
        // flipped, so the only reliable witness is a reader still inside the call tree while the
        // scope would be active. This is the switch that keeps a `--run-job` fire's approvals
        // fail-closed exactly as they are unattended (§8).
        #expect(!client.sawHeadlessDuringCall, "a --run-job call must never execute inside a headless scope")
        #expect(!IrisDefaults.isVolatileCopy)
        #expect(!IrisPaths.isVolatileCopy)
    }

    @Test("a run blocked on an approval nobody gave exits 2")
    func blockedRunExitsTwo() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "wants-to-write")
        try store.ledger.upsert(job)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-runjob-\(UUID().uuidString).txt").path
        let client = FakeLLMClient(responses: [
            callResponse("write_file", ["path": .string(path), "content": .string("nope")]),
            textResponse("I could not do that."),
        ])
        let out = Output()

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "wants-to-write"), store: store,
                                       client: client, lockPath: lockPath(), protectionEnabled: false,
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(!FileManager.default.fileExists(atPath: path), "the denied call must not have run")
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .blockedOnApproval)
        #expect(out.text.contains("status: blocked on approval"))
        #expect(out.text.contains("write_file"))
    }

    @Test("a job admission refuses is reported as the refusal it is, and exits 2")
    func aRefusedFireExitsTwo() async throws {
        let store = try ConversationStore.inMemory()
        var job = self.job(name: "napping")
        job.pausedReason = "paused by user"
        try store.ledger.upsert(job)
        let out = Output()

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "napping"), store: store,
                                       client: FakeLLMClient(responses: []),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(out.text.contains("was not started"))
        #expect(out.text.contains("it is paused"))
    }

    @Test("--json prints one parseable object with the row's own fields")
    func jsonShape() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "json-job")
        try store.ledger.upsert(job)
        let out = Output()

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "json-job", json: true),
                                       store: store,
                                       client: FakeLLMClient(responses: [textResponse("done")]),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.completed)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(out.text.utf8)) as? [String: Any])
        #expect(object["job"] as? String == "json-job")
        #expect(object["runId"] as? String == run.id.uuidString)
        #expect(object["status"] as? String == "completed")
        #expect(object["outcome"] as? String == "done")
        #expect(object["dryRun"] as? Bool == false)
        #expect(object["totalTokens"] != nil)
        #expect(object["durationSeconds"] != nil)
        #expect(object.keys.contains("gateSignal"))
        #expect(object.keys.contains("failureReason"))
    }

    // MARK: --dry-run

    @Test("--dry-run asks only the gate: unchanged exits 3 and writes no row")
    func dryRunUnchangedExitsThree() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "polled",
                           trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                                   gate: .pathChanged(path: "/tmp/whatever"))))
        try store.ledger.upsert(job)
        let out = Output()
        let client = FakeLLMClient(responses: [textResponse("must not be called")])

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "polled", dryRun: true),
                                       store: store, client: client, lockPath: lockPath(),
                                       protectionEnabled: false,
                                       gate: { _, _ in .unchanged(signal: "mtime:1") },
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.gateUnchanged)
        #expect(out.text.contains("unchanged"))
        #expect(out.text.contains("mtime:1"))
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty,
                "a dry run measures the gate; it does not record a run")
        #expect(client.callCount == 0, "and it never reaches the model")
    }

    @Test("--dry-run on a gate that says changed exits 0, still without a row")
    func dryRunChangedExitsZero() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "polled",
                           trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                                   gate: .urlChanged(url: "https://example.invalid/x"))))
        try store.ledger.upsert(job)
        let out = Output()

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: job.id.uuidString, dryRun: true,
                                                            json: true),
                                       store: store, client: FakeLLMClient(responses: []),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       gate: { _, _ in .changed(signal: "etag:2", payload: nil) },
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.completed)
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(out.text.utf8)) as? [String: Any])
        #expect(object["dryRun"] as? Bool == true)
        #expect(object["verdict"] as? String == "changed")
        #expect(object["signal"] as? String == "etag:2")
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("--dry-run on a gate that could not answer exits 2")
    func dryRunErrorExitsTwo() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "polled",
                           trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                                   gate: .pathChanged(path: "/tmp/whatever"))))
        try store.ledger.upsert(job)
        let out = Output()

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "polled", dryRun: true),
                                       store: store, client: FakeLLMClient(responses: []),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       gate: { _, _ in .error("no such file") },
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.notCompleted)
        #expect(out.text.contains("no such file"))
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("--dry-run on a job with no gate says so instead of running it")
    func dryRunWithoutAGateIsAUsageError() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "ungated")
        try store.ledger.upsert(job)
        let err = Output()
        let client = FakeLLMClient(responses: [textResponse("must not be called")])

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "ungated", dryRun: true),
                                       store: store, client: client, lockPath: lockPath(),
                                       protectionEnabled: false,
                                       out: { _ in }, err: { err.write($0) })

        #expect(code == RunJobCLI.Exit.usage)
        #expect(err.text.contains("no gate"))
        #expect(client.callCount == 0)
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("--dry-run with nothing injected asks the real evaluator, on the real host")
    func dryRunUsesTheProductionEvaluator() async throws {
        // The one dry-run test that does NOT inject `gate:`. Every other one does, which left
        // `gate ?? JobRunner.liveGateEvaluator(...)` — the branch every real invocation takes —
        // dead under `swift test`: an injectable default needs at least one test that does not
        // inject. A `pathChanged` gate answers on the host with no container and no network, and
        // with no previous signal the first look is a change by definition.
        let store = try ConversationStore.inMemory()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-runjob-gate-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let job = self.job(name: "real-gate",
                           trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                                   gate: .pathChanged(path: file.path))))
        try store.ledger.upsert(job)
        let out = Output()

        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "real-gate", dryRun: true),
                                       store: store, client: FakeLLMClient(responses: []),
                                       lockPath: lockPath(), protectionEnabled: false,
                                       out: { out.write($0) }, err: { out.write($0) })

        #expect(code == RunJobCLI.Exit.completed)
        #expect(out.text.contains("verdict: changed"))
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty)
    }

    @Test("the gate a dry run asks is compared against the last signal the ledger holds")
    func dryRunPassesThePreviousSignal() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "polled",
                           trigger: .poll(PollSpec(schedule: .interval(seconds: 60),
                                                   gate: .pathChanged(path: "/tmp/whatever"))))
        try store.ledger.upsert(job)
        let run = JobRun(jobId: job.id, jobName: job.name, triggerKind: "poll", startedAt: Date())
        try store.ledger.begin(run: run)
        try store.ledger.setGateSignal(runId: run.id, "mtime:earlier")

        let seen = Output()
        _ = await RunJobCLI.run(RunJobCLI.Invocation(target: "polled", dryRun: true),
                                store: store, client: FakeLLMClient(responses: []),
                                lockPath: lockPath(), protectionEnabled: false,
                                gate: { _, previous in
                                    seen.write(previous ?? "nil")
                                    return .unchanged(signal: "mtime:earlier")
                                },
                                out: { _ in }, err: { _ in })
        #expect(seen.text == "mtime:earlier")
    }
}
