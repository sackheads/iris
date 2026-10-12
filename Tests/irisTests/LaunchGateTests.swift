import Testing
import Foundation
@testable import IrisKit

/// #463 decisions 6-13: the app's launch decision and the gate that waits. Everything the gate
/// does to the world goes through `Seams`, so nothing here opens a store, a window or a timer.
@MainActor
@Suite("LaunchGate (#463)", .timeLimit(.minutes(1)))
struct LaunchGateTests {
    private static let cli = StoreLock.Holder(pid: 4242, kind: .runJob, job: "nightly")
    private static let seeder = StoreLock.Holder(pid: 4343, kind: .seedDevHome, job: nil)
    private static let app = StoreLock.Holder(pid: 4444, kind: .app, job: nil)

    // MARK: The decision

    @Test("the table of holders: a CLI or the seeder waits; an app, a legacy holder or a failure refuses")
    func decisionTable() {
        #expect(LaunchDecision.decide(.acquired, unknownFor: 0) == .open)
        #expect(LaunchDecision.decide(.held(Self.cli), unknownFor: 0) == .wait(Self.cli))
        #expect(LaunchDecision.decide(.held(Self.seeder), unknownFor: 0) == .wait(Self.seeder))
        #expect(LaunchDecision.decide(.held(Self.app), unknownFor: 0) == .refuse(.otherApp(pid: 4444)))
        #expect(LaunchDecision.decide(.held(.init(pid: 9, kind: .perf, job: nil)), unknownFor: 0) == .refuse(.otherApp(pid: 9)))
        #expect(LaunchDecision.decide(.legacy(pid: 77), unknownFor: 0) == .refuse(.legacy(pid: 77)))
        #expect(LaunchDecision.decide(.failed(detail: "flock: ENOTSUP"), unknownFor: 0) == .refuse(.failed(detail: "flock: ENOTSUP")))
    }

    @Test("an unnamed holder is waited on for under a second, then treated as a GUI")
    func unknownHolderBecomesAGUI() {
        #expect(LaunchDecision.decide(.held(nil), unknownFor: 0.99) == .wait(nil))
        #expect(LaunchDecision.decide(.held(nil), unknownFor: 1) == .refuse(.otherApp(pid: nil)))
    }

    @Test("the refusal's words: the title, and the link note only when a link came with the launch")
    func refusalWords() {
        let refusal = LaunchRefusal.otherApp(pid: 12)
        #expect(refusal.title == "Iris is already running on this home")
        #expect(!refusal.message(hadLinks: false).contains(LaunchRefusal.linkNotRun))
        #expect(refusal.message(hadLinks: true).contains("The link you opened was not run."))
        #expect(LaunchRefusal.legacy(pid: 3).title == "Iris is already running on this home")
        #expect(LaunchRefusal.failed(detail: "flock /x: Operation not supported (errno 45)").message(hadLinks: false)
            .contains("errno 45"))
    }

    @Test("the waiting sentence names the run, flattened and capped")
    func waitingSentence() {
        #expect(LaunchGate.waitingSentence(Self.cli)
            == "An iris --run-job is using this home (pid 4242, job nightly). Iris will open when it finishes.")
        let long = StoreLock.Holder(pid: 1, kind: .runJob, job: "a\nb" + String(repeating: "x", count: 200))
        let sentence = LaunchGate.waitingSentence(long)
        #expect(!sentence.contains("\n"))
        #expect(sentence.count < 200)
    }

    @Test("the job name loses tabs, ESC, bidi overrides and zero-width marks before it is shown")
    func waitingSentenceDropsInvisibleScalars() {
        let job = "a\tb\u{1B}[31mc\u{202E}d\u{200B}e\u{2066}f\u{00AD}g\r\nh"
        let sentence = LaunchGate.waitingSentence(.init(pid: 1, kind: .runJob, job: job))
        #expect(sentence.contains("job a b[31mcdefg  h)"))
        for scalar in sentence.unicodeScalars {
            #expect(scalar.properties.generalCategory != .control, "control U+\(String(scalar.value, radix: 16))")
            #expect(scalar.properties.generalCategory != .format, "format U+\(String(scalar.value, radix: 16))")
            #expect(!scalar.properties.isDefaultIgnorableCodePoint)
        }
    }

    @Test("an app or perf holder, which the gate never waits on, gets the unnamed sentence")
    func refusedKindsHaveNoWaitingWords() {
        #expect(LaunchGate.waitingSentence(Self.app) == LaunchGate.waitingSentence(nil))
        #expect(LaunchGate.waitingSentence(.init(pid: 9, kind: .perf, job: "x")) == LaunchGate.waitingSentence(nil))
    }

    @Test("the gate's default clock is monotonic uptime, not the wall clock")
    func defaultClockIsMonotonic() {
        let seams = LaunchGate.Seams(
            claim: { .acquired }, openStore: {}, finishLaunch: { _, _ in }, deliver: { _ in },
            refuse: { _, _ in }, startPolling: { _, _ in }, stopPolling: {},
            showWaitingNotice: {}, hideWaitingNotice: {}, activate: {})
        let before = ProcessInfo.processInfo.systemUptime
        let now = seams.now()
        let after = ProcessInfo.processInfo.systemUptime
        #expect(now >= before && now <= after)
    }

    // MARK: The gate

    @MainActor
    final class Harness {
        var claims: [StoreLock.Claim]
        var opened = 0
        var finishes: [[URL?]] = []
        var droppedReported: [Int] = []
        var delivered: [URL?] = []
        var refusals: [(LaunchRefusal, Bool)] = []
        var tick: (@MainActor () -> Void)?
        var intervals: [TimeInterval] = []
        var stops = 0
        var notices = 0
        var hides = 0
        var activations = 0
        var clock: TimeInterval = 1_000

        /// A real claim, when set: `StoreLock.claim` on a temp file another process may hold.
        var claimer: (() -> StoreLock.Claim)?
        /// What the app does at `openStore` and `finishLaunch`, when a test gives it a real store.
        var onOpen: (() -> Void)?
        var onFinish: (() -> Void)?

        init(_ claims: [StoreLock.Claim]) { self.claims = claims }
        init(claim: @escaping () -> StoreLock.Claim) { self.claims = []; self.claimer = claim }

        lazy var gate = LaunchGate(seams: .init(
            claim: { [unowned self] in
                if let claimer = self.claimer { return claimer() }
                return self.claims.count > 1 ? self.claims.removeFirst() : self.claims[0]
            },
            openStore: { [unowned self] in self.opened += 1; self.onOpen?() },
            finishLaunch: { [unowned self] links, dropped in
                self.finishes.append(links); self.droppedReported.append(dropped); self.onFinish?()
            },
            deliver: { [unowned self] in self.delivered.append($0) },
            refuse: { [unowned self] refusal, hadLinks in self.refusals.append((refusal, hadLinks)) },
            startPolling: { [unowned self] interval, tick in self.intervals.append(interval); self.tick = tick },
            stopPolling: { [unowned self] in self.stops += 1; self.tick = nil },
            showWaitingNotice: { [unowned self] in self.notices += 1 },
            hideWaitingNotice: { [unowned self] in self.hides += 1 },
            activate: { [unowned self] in self.activations += 1 },
            now: { [unowned self] in self.clock }))

        func advance(_ seconds: TimeInterval) { clock += seconds; tick?() }
    }

    @Test("a free lock opens the store at begin and finishes at did-finish, as today")
    func freeLockKeepsTodaysOrder() {
        let h = Harness([.acquired])
        h.gate.begin()
        #expect(h.opened == 1)
        #expect(h.gate.isOpen)
        #expect(h.finishes.isEmpty, "startOnce waits for did-finish")
        #expect(h.tick == nil, "no poll")
        h.gate.didFinishLaunching()
        #expect(h.finishes.count == 1)
        #expect(h.activations == 1, "did-finish activates, as today")
    }

    @Test("while a CLI holds the store, openStore is never called; when it lets go, the launch completes")
    func waitsThenOpens() {
        let h = Harness([.held(Self.cli), .held(Self.cli), .acquired])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.gate.state == .waiting(Self.cli))
        #expect(h.opened == 0)
        h.advance(1)
        #expect(h.opened == 0)
        h.advance(1)
        #expect(h.opened == 1)
        #expect(h.gate.isOpen)
        #expect(h.stops == 1)
        #expect(h.finishes.count == 1)
    }

    @Test("finishLaunch runs exactly once, after both the store and did-finish, in either order")
    func finishOnceEitherOrder() {
        let early = Harness([.held(Self.cli), .acquired])
        early.gate.begin()
        early.gate.didFinishLaunching()
        early.advance(1)
        early.gate.didFinishLaunching()
        #expect(early.finishes.count == 1)

        let late = Harness([.acquired])
        late.gate.begin()
        late.gate.didFinishLaunching()
        late.gate.poll()
        #expect(late.finishes.count == 1)
    }

    @Test("links that arrive while waiting are held in order up to capacity, counted past it, and handed over at finish")
    func linksAreHeldThenDrained() throws {
        let h = Harness([.held(Self.cli), .acquired])
        h.gate.begin()
        let urls = (0..<(RunJobURLIntake.capacity + 3)).map { URL(string: "iris-dev://run-job/t\($0)") }
        for url in urls { h.gate.receive(url) }
        #expect(h.gate.heldLinkCount == RunJobURLIntake.capacity)
        #expect(h.delivered.isEmpty, "nothing reaches AppState while waiting")
        h.gate.didFinishLaunching()
        h.advance(1)
        #expect(h.finishes == [Array(urls.prefix(RunJobURLIntake.capacity))])
        #expect(h.droppedReported == [3])
        h.gate.receive(URL(string: "iris-dev://run-job/after"))
        #expect(h.delivered == [URL(string: "iris-dev://run-job/after")], "after launch a link goes straight through")
    }

    @Test("with the store open before did-finish, links go to AppState's own intake at once")
    func openGateDeliversDirectly() {
        let h = Harness([.acquired])
        h.gate.begin()
        h.gate.receive(URL(string: "iris-dev://run-job/x"))
        #expect(h.delivered.count == 1)
        h.gate.didFinishLaunching()
        #expect(h.finishes == [[]])
    }

    @Test("a link after the store opens but before did-finish queues behind the links already held")
    func openBeforeFinishKeepsLinkOrder() {
        let h = Harness([.held(Self.cli), .acquired])
        h.gate.begin()
        let first = URL(string: "iris-dev://run-job/first")
        let second = URL(string: "iris-dev://run-job/second")
        h.gate.receive(first)
        h.advance(1)   // the poll opens the store before did-finish has run
        #expect(h.gate.isOpen)
        h.gate.receive(second)
        #expect(h.delivered.isEmpty, "delivered now, it would reach the intake ahead of the held link")
        h.gate.didFinishLaunching()
        #expect(h.finishes == [[first, second]])
        let third = URL(string: "iris-dev://run-job/third")
        h.gate.receive(third)
        #expect(h.delivered == [third])
    }

    @Test("a cold start from a link shows the notice without activating, and hides it when Iris opens")
    func coldStartShowsTheNotice() {
        let h = Harness([.held(Self.cli), .acquired])
        h.gate.begin()
        h.gate.receive(URL(string: "iris-dev://run-job/x"))
        #expect(h.notices == 0, "not before did-finish")
        h.gate.didFinishLaunching()
        #expect(h.notices == 1)
        #expect(h.activations == 0, "decision 13: the notice is shown without activating Iris")
        h.advance(1)
        #expect(h.gate.isOpen)
        #expect(h.hides == 1)
        #expect(h.activations == 0)
    }

    @Test("a Dock launch while waiting activates as today and shows no extra notice")
    func dockLaunchHasNoNotice() {
        let h = Harness([.held(Self.cli)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.notices == 0)
        #expect(h.activations == 1)
    }

    @Test("a GUI holder at launch is refused at did-finish, and the alert knows about a link")
    func secondGUIRefuses() {
        let h = Harness([.held(Self.app)])
        h.gate.begin()
        #expect(h.refusals.isEmpty, "no alert before the app has finished launching")
        h.gate.receive(URL(string: "iris-dev://run-job/x"))
        h.gate.didFinishLaunching()
        #expect(h.refusals.count == 1)
        #expect(h.refusals.first?.0 == .otherApp(pid: 4444))
        #expect(h.refusals.first?.1 == true)
        #expect(h.opened == 0)
        #expect(h.delivered.isEmpty)
    }

    @Test("a waiting GUI that finds a GUI holder on a poll quits the same way")
    func waiterLosesToAGUI() {
        let h = Harness([.held(Self.cli), .held(Self.app)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        h.advance(1)
        #expect(h.refusals.map(\.0) == [.otherApp(pid: 4444)])
        #expect(h.tick == nil)
        #expect(h.opened == 0)
    }

    @Test(".legacy and .failed refuse, and never open")
    func legacyAndFailedRefuse() {
        for claim in [StoreLock.Claim.legacy(pid: 5), .failed(detail: "flock: ENOLCK")] {
            let h = Harness([claim])
            h.gate.begin()
            h.gate.didFinishLaunching()
            #expect(h.opened == 0)
            #expect(h.refusals.count == 1)
        }
    }

    @Test("an unnamed holder still unnamed after a second refuses as a GUI")
    func unnamedHolderRefusesAfterASecond() {
        let h = Harness([.held(nil)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.intervals == [LaunchGate.unknownPollInterval], "an unnamed holder is re-read fast")
        for _ in 0..<4 { h.advance(0.2) }
        #expect(h.refusals.isEmpty, "four re-reads inside the second, none refused")
        h.advance(0.2)
        #expect(h.refusals.map(\.0) == [.otherApp(pid: nil)])
    }

    @Test("a named holder is polled once a second, and the poll speeds up while the holder is unnamed")
    func pollRateFollowsTheHolder() {
        let h = Harness([.held(Self.cli), .held(nil), .held(Self.cli)])
        h.gate.begin()
        h.advance(1)
        h.advance(0.2)
        #expect(h.intervals == [LaunchGate.knownPollInterval, LaunchGate.unknownPollInterval, LaunchGate.knownPollInterval])
    }

    @Test("Review Focus 3: the waiting state tracks whichever run holds the store now")
    func waitingTracksTheCurrentHolder() {
        let next = StoreLock.Holder(pid: 5151, kind: .runJob, job: "second")
        let h = Harness([.held(Self.cli), .held(nil), .held(next), .held(Self.app)])
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.gate.state == .waiting(Self.cli))
        h.advance(0.2)   // between runs, before the next has written its payload
        #expect(h.gate.state == .waiting(nil))
        h.advance(0.2)
        #expect(h.gate.state == .waiting(next))
        #expect(h.gate.sentence.contains("pid 5151, job second"))
        h.advance(1)
        #expect(h.refusals.map(\.0) == [.otherApp(pid: 4444)])
    }

    @Test("Review Focus 2: quitting while waiting flushes nothing")
    func quitWhileWaitingFlushesNothing() {
        let h = Harness([.held(Self.cli)])
        h.gate.begin()
        var flushed = 0
        h.gate.willTerminate { flushed += 1 }
        #expect(flushed == 0)
        let open = Harness([.acquired])
        open.gate.begin()
        open.gate.willTerminate { flushed += 1 }
        #expect(flushed == 1)
    }

    // MARK: Real flocks

    private static func tempLock() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.sqlite.lock")
    }

    @Test("a real --run-job holder is waited on by name, and its death opens the store under this process's lock")
    func realRunJobHolderThenOpens() throws {
        let url = try Self.tempLock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stub = try LockStub.start(holding: url, payload: #"{"job":"nap","kind":"run-job","pid":%PID%}"# + "\n")
        defer { stub.kill() }   // idempotent: the test kills it on purpose below
        let h = Harness(claim: { StoreLock.claim(at: url, kind: .app) })
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.gate.state == .waiting(.init(pid: stub.pid, kind: .runJob, job: "nap")))
        #expect(h.opened == 0)
        h.advance(1)
        #expect(h.opened == 0, "still held")
        stub.kill()
        h.advance(1)
        #expect(h.gate.isOpen)
        #expect(h.opened == 1)
        #expect(h.finishes.count == 1)
        #expect(LockStub.tryLock(url) == 3, "the gate's claim holds the lock now")
        let payload = try String(contentsOf: url, encoding: .utf8)
        #expect(payload.contains(#""kind":"app""#))
    }

    @Test("a real holder advertising an app refuses at did-finish and never opens")
    func realAppHolderRefuses() throws {
        let url = try Self.tempLock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stub = try LockStub.start(holding: url, payload: #"{"kind":"app","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        let h = Harness(claim: { StoreLock.claim(at: url, kind: .app) })
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.refusals.map(\.0) == [.otherApp(pid: stub.pid)])
        #expect(h.opened == 0)
        #expect(h.tick == nil)
    }

    @Test("a real holder that never writes a payload is re-read for a second, then refused as a GUI")
    func realSilentHolderRefusesAfterASecond() throws {
        let url = try Self.tempLock()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stub = try LockStub.start(holding: url)
        defer { stub.kill() }
        let h = Harness(claim: { StoreLock.claim(at: url, kind: .app) })
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.gate.state == .waiting(nil))
        for _ in 0..<4 { h.advance(0.2) }
        #expect(h.refusals.isEmpty)
        h.advance(0.2)
        #expect(h.refusals.map(\.0) == [.otherApp(pid: nil)])
        #expect(h.opened == 0)
    }

    /// Every message of the one conversation, as the disk has it.
    private static func messagesOnDisk(_ db: URL, _ id: UUID) throws -> [String] {
        try ConversationStore.onDisk(at: db).loadAll().conversations.first { $0.id == id }?.messages.map(\.content) ?? []
    }

    /// A whole-copy save, the shape that let the later writer win before #463.
    private static func save(_ conversation: Conversation, to store: ConversationStore, created: Bool = false) throws {
        var changes = ChangeSet()
        if created { changes.add(.created) }
        changes.add(.messagesReplaced)
        try store.apply([ConversationWrite(id: conversation.id, snapshot: conversation, changes: changes)])
    }

    @Test("#463 repro: an app launched while a --run-job writes never opens the store until it exits, so neither write is lost")
    func appLaunchedDuringACLIRunLosesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("conversations.sqlite")
        let lock = dir.appendingPathComponent("conversations.sqlite.lock")

        // The CLI: it holds the lock, loaded its copy of the conversation at its start, and saves
        // that copy as it goes. Its lock is a real flock in another process.
        let stub = try LockStub.start(holding: lock, payload: #"{"job":"nightly","kind":"run-job","pid":%PID%}"# + "\n")
        defer { stub.kill() }
        let cliStore = try ConversationStore.onDisk(at: db)
        var cliCopy = Conversation(id: UUID(), title: "Iris", workspacePath: dir.path)
        cliCopy.messages = [ChatMessage(role: .system, content: "cli one")]
        try Self.save(cliCopy, to: cliStore, created: true)

        // The app, launched mid-run. Its store half loads its in-memory copy; its launch then
        // writes a line into that copy and saves it, as `AppState` does.
        var appCopy: Conversation?
        let h = Harness(claim: { StoreLock.claim(at: lock, kind: .app) })
        h.onOpen = { appCopy = try? ConversationStore.onDisk(at: db).loadAll().conversations.first { $0.id == cliCopy.id } }
        h.onFinish = {
            guard var copy = appCopy, let store = try? ConversationStore.onDisk(at: db) else { return }
            copy.messages.append(ChatMessage(role: .system, content: "app"))
            try? Self.save(copy, to: store)
        }
        h.gate.begin()
        h.gate.didFinishLaunching()
        #expect(h.gate.state == .waiting(.init(pid: stub.pid, kind: .runJob, job: "nightly")))
        #expect(h.opened == 0, "the app never opens the store while the CLI holds it")
        #expect(try Self.messagesOnDisk(db, cliCopy.id) == ["cli one"], "and has written nothing")

        // The CLI's next save, from its own copy, while the app waits.
        cliCopy.messages.append(ChatMessage(role: .system, content: "cli two"))
        try Self.save(cliCopy, to: cliStore)
        h.advance(1)
        #expect(h.opened == 0, "still held")

        stub.kill()   // the CLI exits
        h.advance(1)
        #expect(h.gate.isOpen)
        #expect(h.opened == 1)
        #expect(h.finishes.count == 1)
        #expect(try Self.messagesOnDisk(db, cliCopy.id) == ["cli one", "cli two", "app"],
                "the app loaded after the CLI's last write, and nothing it wrote was written over")
    }
}
