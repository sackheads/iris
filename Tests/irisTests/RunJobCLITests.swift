import Testing
import Foundation
@testable import iris

/// `iris --run-job <id-or-name> [--dry-run] [--json]` (#187 spec §8, ruling R35): one job, run once
/// from a terminal, against a store this process opened itself.
///
/// Everything here goes through the injected seams — an in-memory store, a `FakeLLMClient`, a lock
/// path under the temp directory — so the suite never opens `~/.iris`, never reaches the network
/// and never writes a process global (AGENTS invariant 7). The two flags a headless run must NOT
/// touch (`HeadlessMode`, the volatile defaults) are asserted rather than assumed: they are what
/// keeps a CLI run's approvals as fail-closed as an unattended one's.
@MainActor
@Suite("iris --run-job (#187 §8)")
struct RunJobCLITests {

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
    private func lockPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-runjob-\(UUID().uuidString).lock")
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

    // MARK: The GUI lock (ruling R35, spec §8)

    @Test("the CLI refuses while another Iris process holds the lock, and says which it might be")
    func aLiveGUIRefusesTheRun() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job()
        try store.ledger.upsert(job)
        let path = lockPath()
        // This process is alive by definition, so its own pid is the one lock state that is
        // unambiguously held.
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let err = Output()
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "pr-sweep"), store: store,
                                       client: FakeLLMClient(responses: []),
                                       lockPath: path, protectionEnabled: false,
                                       out: { _ in }, err: { err.write($0) })
        #expect(code == RunJobCLI.Exit.usage)
        // The file holds a bare pid, so the holder may be the app or a second `--run-job`. The
        // refusal must not send the user off to quit an app that is not running.
        #expect(err.text.contains("another Iris process holds the store"))
        #expect(err.text.contains("--run-job"))
        #expect(err.text.contains("\(ProcessInfo.processInfo.processIdentifier)"))
        // And the file, because a pid the kernel has since handed to something unrelated leaves
        // nothing to wait for and no app to quit — only a file to delete.
        #expect(err.text.contains(path.path), "the refusal has to name the lock file")
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).isEmpty, "and nothing was run")
    }

    /// Releases every racer at once, so the claims below really do collide rather than queueing.
    private final class StartLine: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var arrived = 0
        private let racers: Int
        init(racers: Int) { self.racers = racers }
        func arrive() {
            lock.lock(); arrived += 1; let last = arrived == racers; lock.unlock()
            if last { for _ in 0..<racers { gate.signal() } }
            gate.wait()
        }
    }

    private final class Claims: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [GUILock.Claim] = []
        func add(_ claim: GUILock.Claim) { lock.withLock { all.append(claim) } }
        var value: [GUILock.Claim] { lock.withLock { all } }
    }

    /// Runs `racers` claims against one path, all released together.
    private func race(racers: Int, at path: URL) -> [GUILock.Claim] {
        let startLine = StartLine(racers: racers)
        let claims = Claims()
        let finished = DispatchGroup()
        for _ in 0..<racers {
            DispatchQueue.global().async(group: finished) {
                startLine.arrive()
                claims.add(GUILock.acquireExclusively(at: path))
            }
        }
        #expect(finished.wait(timeout: .now() + 30) == .success)
        return claims.value
    }

    /// A lock path in a directory of this test's own, so "what is beside the lock afterwards" is
    /// answerable without walking the whole of `/tmp`.
    private func lockPathInOwnDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-runjob-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("conversations.sqlite.lock")
    }

    /// Anything the claim staged beside the lock and did not clean up.
    private func leftovers(beside path: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
            .filter { $0 != path.lastPathComponent }
    }

    @Test("two CLI runs starting at the same instant: exactly one takes the lock")
    func simultaneousAcquiresHaveOneWinner() throws {
        // The scenario the command is documented *for*: an eval harness that launches several
        // `--run-job` at once. A check-then-write lock passes them all — both read "free", both
        // write, both open the store — so the claim has to be the check. And the claim has to
        // create the file *with the pid already in it*: an `O_CREAT | O_EXCL` create followed by a
        // write leaves a window in which the file exists and says nothing, and a loser reading it
        // then would be told to delete a lock that is about to be perfectly valid. `link(2)` of a
        // staged file closes that window, so both assertions below hold every time rather than
        // almost every time.
        let path = try lockPathInOwnDirectory()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let all = race(racers: 2, at: path)
        #expect(all.filter { $0 == .acquired }.count == 1, "exactly one claim, whoever gets there first")
        // Both racers are this test process, so the pid the loser is told about is this one — it
        // is the winner's pid, which is the fact the message has to carry.
        #expect(all.filter { $0 == .held(pid: ProcessInfo.processInfo.processIdentifier) }.count == 1,
                "and the loser is told who has it, never an empty file: \(all)")
        #expect(GUILock.state(at: path) == .held(pid: ProcessInfo.processInfo.processIdentifier))
        #expect(try leftovers(beside: path).isEmpty, "and nothing is staged beside it afterwards")
    }

    @Test("two runs taking over one crashed process's lock: still exactly one winner")
    func simultaneousTakeoversHaveOneWinner() throws {
        // Crash recovery is the other half of the claim, and the place a careless one hands out
        // the double claim it exists to prevent: both racers read the stale pid, and whichever
        // removes "the stale file" second by path removes the live lock the first has just linked
        // in its place — a rename aside does that as surely as an unlink (#390). Takeovers are
        // serialized and look again first; the pinned interleaving is the next test.
        let path = try lockPathInOwnDirectory()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        // Above any pid macOS will hand out, so the file names nothing that exists.
        try Data("999999\n".utf8).write(to: path)

        let all = race(racers: 2, at: path)
        #expect(all.filter { $0 == .acquired }.count == 1,
                "a crashed holder must not let two runs at the store: \(all)")
        #expect(all.filter { $0 == .held(pid: ProcessInfo.processInfo.processIdentifier) }.count == 1,
                "and the loser is told the taker-over has it: \(all)")
        // The winner's lock is still there and still names it — the loser's takeover must not have
        // removed a live file on its way past.
        #expect(GUILock.state(at: path) == .held(pid: ProcessInfo.processInfo.processIdentifier))
        #expect(try leftovers(beside: path).isEmpty,
                "and the stale file was moved aside and deleted, not left lying about")
    }

    @Test("a claimant that read the stale pid before another took over leaves the new lock alone")
    func aLateTakeoverDoesNotMoveTheLiveLock() throws {
        // The interleaving behind #390, pinned rather than raced for: B reads the dead pid, then A
        // takes over and links its live lock before B acts. Removing "the stale file" by path then
        // removes A's lock, and B links its own: two claims. B has to look again before it moves
        // anything, and find A there.
        let path = try lockPathInOwnDirectory()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data("999999\n".utf8).write(to: path)

        let bReadStale = DispatchSemaphore(value: 0)
        let aFinished = DispatchSemaphore(value: 0)
        let claims = Claims()
        let finished = DispatchGroup()
        DispatchQueue.global().async(group: finished) {
            claims.add(GUILock.acquireExclusively(at: path, afterReadingStale: {
                bReadStale.signal()
                _ = aFinished.wait(timeout: .now() + 30)
            }))
        }
        #expect(bReadStale.wait(timeout: .now() + 30) == .success)
        let a = GUILock.acquireExclusively(at: path)
        aFinished.signal()
        #expect(finished.wait(timeout: .now() + 30) == .success)

        let me = ProcessInfo.processInfo.processIdentifier
        #expect(a == .acquired)
        #expect(claims.value == [.held(pid: me)], "the late taker-over is told A has it")
        #expect(GUILock.state(at: path) == .held(pid: me))
        #expect(try leftovers(beside: path).isEmpty)
    }

    @Test("the app launching mid-takeover keeps its lock")
    func anAppAcquireDuringATakeoverSurvives() throws {
        // The takeover has read a dead pid and is about to move the file aside when the app
        // launches and writes its lock — an atomic write, so a rename over the path. Unserialized,
        // the takeover then moves the *app's* lock aside and claims the store under a live app.
        // The app's write waits on the same directory lock, so it lands after the takeover. It
        // then races the claim's next link: the app first, and the claim is told the app holds
        // it; the link first, and the app overwrites the run's lock — the documented direction,
        // the app keeping the store. Either way the app's lock is the one left. pid 1 stands in
        // for the app, because it is alive and is not this process.
        let path = try lockPathInOwnDirectory()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data("999999\n".utf8).write(to: path)

        let appWrote = DispatchSemaphore(value: 0)
        let landedMidTakeover = Claims()
        let claim = GUILock.acquireExclusively(at: path, duringTakeover: {
            DispatchQueue.global().async {
                GUILock.acquire(at: path, pid: 1)
                appWrote.signal()
            }
            // Unserialized, the app's write lands well inside this; serialized, it cannot.
            if appWrote.wait(timeout: .now() + 0.5) == .success { landedMidTakeover.add(.acquired) }
        })
        #expect(landedMidTakeover.value.isEmpty, "the app's write waits for the takeover")
        if landedMidTakeover.value.isEmpty {
            #expect(appWrote.wait(timeout: .now() + 30) == .success)
        }
        #expect(claim == .held(pid: 1) || claim == .acquired, "\(claim)")
        #expect(GUILock.state(at: path) == .held(pid: 1),
                "the app's lock is never moved aside by a takeover that read the dead pid first")
        #expect(try leftovers(beside: path).isEmpty)
    }

    @Test("the app launching before the takeover looks again: the claim is told the app has it")
    func anAppAcquireBeforeTheTakeoverIsHeld() throws {
        let path = try lockPathInOwnDirectory()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data("999999\n".utf8).write(to: path)
        let claim = GUILock.acquireExclusively(at: path, afterReadingStale: {
            GUILock.acquire(at: path, pid: 1)
        })
        #expect(claim == .held(pid: 1))
        #expect(GUILock.state(at: path) == .held(pid: 1))
    }

    @Test("a holder releasing between a failed link and the read is retried, not refused")
    func aReleaseMidClaimIsRetried() throws {
        // The holder is there at each link and gone by the read, twice: the claim sees the path
        // change hands and tries again rather than refusing with no holder to name.
        let path = try lockPathInOwnDirectory()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let me = ProcessInfo.processInfo.processIdentifier
        let claim = GUILock.acquireExclusively(at: path, beforeLink: { attempt in
            if attempt < 2 { try? Data("\(me)\n".utf8).write(to: path) }
        }, afterLinkFailed: {
            try? FileManager.default.removeItem(at: path)
        })
        #expect(claim == .acquired)
        #expect(GUILock.state(at: path) == .held(pid: me))
        #expect(try leftovers(beside: path).isEmpty)
    }

    @Test("a lock that never stops changing hands is refused with a reason, after a bounded wait")
    func endlessChurnIsRefusedWithADetail() throws {
        let path = try lockPathInOwnDirectory()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let me = ProcessInfo.processInfo.processIdentifier
        let attempts = Claims()
        let claim = GUILock.acquireExclusively(at: path, beforeLink: { _ in
            attempts.add(.acquired)
            try? Data("\(me)\n".utf8).write(to: path)
        }, afterLinkFailed: {
            try? FileManager.default.removeItem(at: path)
        })
        #expect(claim == .blocked(detail: GUILock.churnDetail))
        #expect(attempts.value.count == GUILock.maxClaimAttempts)
        #expect(try leftovers(beside: path).isEmpty)
    }

    @Test("release only takes a lock this process holds")
    func releaseIsPidGuarded() throws {
        // pid 1 is launchd: alive, and not us. A release that went by "the file is there" would
        // let a CLI run ending at the wrong moment delete the app's lock.
        let path = lockPath()
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("1\n".utf8).write(to: path)
        GUILock.release(at: path)
        #expect(FileManager.default.fileExists(atPath: path.path),
                "somebody else's lock is not ours to give back")
        #expect(GUILock.acquireExclusively(at: path) == .held(pid: 1))
    }

    @Test("a lock file left by a crashed process is taken over, once")
    func aStaleLockIsTakenOver() throws {
        let path = lockPath()
        defer { try? FileManager.default.removeItem(at: path) }
        // Above any pid macOS will hand out, so the file names nothing that exists.
        try Data("999999\n".utf8).write(to: path)

        #expect(GUILock.acquireExclusively(at: path) == .acquired,
                "a crash must not brick the command until somebody finds the file")
        #expect(GUILock.state(at: path) == .held(pid: ProcessInfo.processInfo.processIdentifier))
        // And having taken it over, this process holds it against itself too: a second claim is
        // refused rather than quietly overwriting the first.
        #expect(GUILock.acquireExclusively(at: path)
                == .held(pid: ProcessInfo.processInfo.processIdentifier))
        GUILock.release(at: path)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("a lock file that says nothing usable is not taken over")
    func garbageIsNotTakenOver() throws {
        let path = lockPath()
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("not a pid".utf8).write(to: path)
        #expect(GUILock.acquireExclusively(at: path) == .blocked(detail: GUILock.unreadableDetail))
        #expect(try String(contentsOf: path, encoding: .utf8) == "not a pid",
                "refusing is recoverable; overwriting somebody else's file is not")
    }

    @Test("a lock left behind by a crashed GUI is stale, not a refusal")
    func aDeadPIDIsStale() throws {
        let path = lockPath()
        // Above any pid macOS will hand out, so it cannot be a live process.
        try Data("999999\n".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(GUILock.state(at: path) == .free)

        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: path)
        #expect(GUILock.state(at: path) == .held(pid: ProcessInfo.processInfo.processIdentifier))

        // A lock file nobody can read is held, not free: refusing is recoverable (delete it), and
        // racing two writers at the store is not.
        try Data("not a pid".utf8).write(to: path)
        #expect(GUILock.state(at: path) == .unreadable(path: path.path))
    }

    @Test("acquire writes this process's pid and release takes it away again")
    func acquireAndRelease() throws {
        let path = lockPath()
        defer { try? FileManager.default.removeItem(at: path) }
        #expect(GUILock.state(at: path) == .free, "nothing there yet")
        GUILock.acquire(at: path)
        #expect(GUILock.state(at: path) == .held(pid: ProcessInfo.processInfo.processIdentifier))
        GUILock.release(at: path)
        #expect(!FileManager.default.fileExists(atPath: path.path))
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

    @Test("a lock file that cannot be read at all is held, not free")
    func anUnreadableLockFileIsHeld() throws {
        let path = lockPath()
        defer { try? FileManager.default.removeItem(at: path) }
        // Not valid UTF-8: `try? String(contentsOf:)` answers nil for this exactly as it does for
        // a file that is not there, and only one of those two is free.
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: path)
        #expect(GUILock.state(at: path) == .unreadable(path: path.path))
    }

    @Test("a run takes the lock for its own length, so a second CLI run is refused")
    func aRunHoldsTheLockWhileItRuns() async throws {
        let store = try ConversationStore.inMemory()
        let job = self.job(name: "holder")
        try store.ledger.upsert(job)
        let path = lockPath()
        defer { try? FileManager.default.removeItem(at: path) }
        let seen = Output()

        // The fake client is asked mid-run, which is the only moment a second invocation could
        // arrive: the lock has to be held *then*, not merely checked at the start.
        let client = ProbingLLMClient(reply: "done") { seen.write("\(GUILock.state(at: path))") }
        let code = await RunJobCLI.run(RunJobCLI.Invocation(target: "holder"), store: store,
                                       client: client, lockPath: path, protectionEnabled: false,
                                       out: { _ in }, err: { _ in })

        #expect(code == RunJobCLI.Exit.completed)
        #expect(seen.text.contains("held(pid: \(ProcessInfo.processInfo.processIdentifier))"),
                "the run must hold the lock while it runs, not only check it")
        #expect(!FileManager.default.fileExists(atPath: path.path),
                "and give it back when it is over")
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
