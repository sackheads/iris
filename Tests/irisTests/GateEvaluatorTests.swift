import Testing
import Foundation
@testable import iris

/// A `ContainerRuntime` that records what a gate asked for and answers with a scripted result.
/// Separate from `MockRuntime` (SandboxSessionManagerTests) because a gate needs two things that
/// one does not offer: a create that can fail, and the image and workdir each call was made with.
final class GateRuntime: ContainerRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var creates: [(name: String, image: String, mounts: [String], workdir: String)] = []
    private(set) var execs: [(name: String, workdir: String, command: String, timeoutSeconds: Int?)] = []
    private(set) var removed: [String] = []
    var createError: Error?
    var execError: Error?
    var execResult: (stdout: String, stderr: String, exitCode: Int32) = ("CHANGED", "", 0)

    func createDetached(name: String, image: String, mounts: [String], workdir: String) async throws {
        lock.withLock { creates.append((name, image, mounts, workdir)) }
        if let createError { throw createError }
    }

    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        lock.withLock { execs.append((name, workdir, command, timeoutSeconds)) }
        if let execError { throw execError }
        return lock.withLock { execResult }
    }

    func remove(name: String) async { lock.withLock { removed.append(name) } }
    func list(prefix: String) async -> [String] { [] }

    var createdMounts: [String] { lock.withLock { creates.last?.mounts ?? [] } }
    var lastExecTimeout: Int? { lock.withLock { execs.last?.timeoutSeconds ?? nil } }
    var removedNames: [String] { lock.withLock { removed } }
    var execCount: Int { lock.withLock { execs.count } }
}

/// #187 deliverable 3, spec §7 — the three gates, each asked "has anything changed since the
/// signal you last recorded?".
///
/// Every case here is offline by construction (AGENTS invariant 7): the URL gate answers through a
/// `URLProtocol` stub bound to its own session, the path gate reads temp files this suite made,
/// and the script gate never leaves `GateRuntime`.
@Suite("Gate evaluation (#187 §7)")
struct GateEvaluatorTests {

    // MARK: Fixtures

    /// A session whose every request is answered with `status` and `headers`, plus the requests it
    /// saw — the gate must send HEAD, not GET.
    private func stub(_ status: Int, _ headers: [String: String])
        -> (session: URLSession, remove: () -> Void, methods: MethodLog) {
        let log = MethodLog()
        let (session, remove) = MockURLProtocol.scopedSession { request in
            log.append(request.httpMethod ?? "")
            let url = request.url ?? URL(string: "https://example.invalid")!
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                    headerFields: headers)!, Data())
        }
        return (session, remove, log)
    }

    final class MethodLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func signal(_ result: GateResult) -> String? {
        switch result {
        case .changed(let signal, _): return signal
        case .unchanged(let signal): return signal
        case .error: return nil
        }
    }

    // MARK: urlChanged

    @Test("a changed ETag is a change; the same one is not")
    func urlETag() async throws {
        let first = stub(200, ["ETag": "\"aaa\"", "Content-Length": "10"])
        defer { first.remove() }
        let baseline = await GateEvaluator.evaluate(.urlChanged(url: "https://example.invalid/f"),
                                                    previous: nil, runtime: nil, http: first.session)
        // Nothing to compare against: the first look runs the job once and records the baseline.
        guard case .changed(let recorded, let payload) = baseline else {
            Issue.record("the first look is a change, got \(baseline)"); return
        }
        #expect(payload == nil, "a built-in gate has no payload to hand the run")
        #expect(first.methods.all == ["HEAD"], "a gate reads headers, never a body")

        let same = await GateEvaluator.evaluate(.urlChanged(url: "https://example.invalid/f"),
                                                previous: recorded, runtime: nil, http: first.session)
        #expect(same == .unchanged(signal: recorded))

        let moved = stub(200, ["ETag": "\"bbb\"", "Content-Length": "10"])
        defer { moved.remove() }
        let changed = await GateEvaluator.evaluate(.urlChanged(url: "https://example.invalid/f"),
                                                   previous: recorded, runtime: nil, http: moved.session)
        #expect(signal(changed) != recorded)
        guard case .changed = changed else { Issue.record("a new ETag is a change, got \(changed)"); return }
    }

    @Test("Last-Modified and Content-Length are compared too")
    func urlOtherValidators() async throws {
        let first = stub(200, ["Last-Modified": "Mon, 01 Sep 2025 10:00:00 GMT", "Content-Length": "10"])
        defer { first.remove() }
        let baseline = try #require(signal(await GateEvaluator.evaluate(
            .urlChanged(url: "https://example.invalid/f"), previous: nil, runtime: nil, http: first.session)))

        let touched = stub(200, ["Last-Modified": "Tue, 02 Sep 2025 10:00:00 GMT", "Content-Length": "10"])
        defer { touched.remove() }
        guard case .changed = await GateEvaluator.evaluate(.urlChanged(url: "https://example.invalid/f"),
                                                           previous: baseline, runtime: nil,
                                                           http: touched.session) else {
            Issue.record("a newer Last-Modified is a change"); return
        }

        let grew = stub(200, ["Last-Modified": "Mon, 01 Sep 2025 10:00:00 GMT", "Content-Length": "11"])
        defer { grew.remove() }
        guard case .changed = await GateEvaluator.evaluate(.urlChanged(url: "https://example.invalid/f"),
                                                           previous: baseline, runtime: nil,
                                                           http: grew.session) else {
            Issue.record("a different Content-Length is a change"); return
        }
    }

    @Test("a 404 or a 500 is a gate error, not a verdict")
    func urlFailureStatuses() async throws {
        for status in [404, 500, 503] {
            let stubbed = stub(status, ["ETag": "\"aaa\""])
            defer { stubbed.remove() }
            let result = await GateEvaluator.evaluate(.urlChanged(url: "https://example.invalid/f"),
                                                      previous: "etag=\"aaa\"", runtime: nil,
                                                      http: stubbed.session)
            guard case .error(let detail) = result else {
                Issue.record("\(status) must be an error, got \(result)"); return
            }
            #expect(detail.contains("\(status)"), "the error names the status: \(detail)")
        }
    }

    @Test("a response with nothing to compare is an error rather than permanent silence")
    func urlWithoutValidators() async throws {
        let stubbed = stub(200, [:])
        defer { stubbed.remove() }
        let result = await GateEvaluator.evaluate(.urlChanged(url: "https://example.invalid/f"),
                                                  previous: nil, runtime: nil, http: stubbed.session)
        guard case .error = result else {
            Issue.record("no ETag, Last-Modified or Content-Length is an error, got \(result)"); return
        }
    }

    @Test("a URL that is not http(s) is refused without a request")
    func urlScheme() async throws {
        let stubbed = stub(200, ["ETag": "\"a\""])
        defer { stubbed.remove() }
        let result = await GateEvaluator.evaluate(.urlChanged(url: "file:///etc/passwd"),
                                                  previous: nil, runtime: nil, http: stubbed.session)
        guard case .error = result else { Issue.record("only http(s) is a gate, got \(result)"); return }
        #expect(stubbed.methods.all.isEmpty)
    }

    // MARK: pathChanged

    @Test("a file's mtime, and its content at the same mtime, are both changes")
    func pathFile() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("watched.txt")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try "one".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)

        let baseline = try #require(signal(await GateEvaluator.evaluate(.pathChanged(path: file.path),
                                                                       previous: nil, runtime: nil)))
        #expect(await GateEvaluator.evaluate(.pathChanged(path: file.path), previous: baseline,
                                             runtime: nil) == .unchanged(signal: baseline))

        // Same mtime, different contents: the hash is what catches this one.
        try "two!".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        let rewritten = await GateEvaluator.evaluate(.pathChanged(path: file.path), previous: baseline,
                                                     runtime: nil)
        guard case .changed(let afterRewrite, _) = rewritten else {
            Issue.record("new contents at the same mtime is a change, got \(rewritten)"); return
        }

        // Same contents, newer mtime: the mtime is what catches this one.
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(60)],
                                              ofItemAtPath: file.path)
        guard case .changed = await GateEvaluator.evaluate(.pathChanged(path: file.path),
                                                           previous: afterRewrite, runtime: nil) else {
            Issue.record("a touched file is a change"); return
        }
    }

    @Test("a directory changes when the newest thing under it does")
    func pathDirectory() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        // The whole tree stamped to one known instant, so "the newest thing under it" is a fact
        // about this test rather than about how recently the directory was created.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for path in [file.path, nested.path, dir.path] {
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: path)
        }

        let baseline = try #require(signal(await GateEvaluator.evaluate(.pathChanged(path: dir.path),
                                                                       previous: nil, runtime: nil)))
        #expect(await GateEvaluator.evaluate(.pathChanged(path: dir.path), previous: baseline,
                                             runtime: nil) == .unchanged(signal: baseline))

        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(3_600)],
                                              ofItemAtPath: file.path)
        guard case .changed(let afterTouch, _) = await GateEvaluator.evaluate(
            .pathChanged(path: dir.path), previous: baseline, runtime: nil) else {
            Issue.record("a newer file deep in the tree is a change"); return
        }

        // And a new file the parent's own mtime would not tell you about either way.
        try "b".write(to: nested.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        guard case .changed = await GateEvaluator.evaluate(.pathChanged(path: dir.path),
                                                           previous: afterTouch, runtime: nil) else {
            Issue.record("a new file under the directory is a change"); return
        }
    }

    @Test("a path that is not there is an error, not 'nothing changed'")
    func pathMissing() async throws {
        let result = await GateEvaluator.evaluate(.pathChanged(path: "/nope/\(UUID().uuidString)"),
                                                  previous: "mtime=1", runtime: nil)
        guard case .error(let detail) = result else {
            Issue.record("a missing path is an error, got \(result)"); return
        }
        #expect(detail.contains("/nope/"))
    }

    // MARK: script

    @Test("the verdict is the last line of stdout, and the rest is the payload")
    func scriptTokens() async throws {
        let runtime = GateRuntime()
        runtime.execResult = ("3 new PRs\nCHANGED\n", "", 0)
        let changed = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: ["/tmp/in"], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "ubuntu:latest")
        guard case .changed(_, let payload) = changed else {
            Issue.record("CHANGED is a change, got \(changed)"); return
        }
        #expect(payload == "3 new PRs")

        runtime.execResult = ("nothing doing\nUNCHANGED", "", 0)
        guard case .unchanged = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "ubuntu:latest") else {
            Issue.record("UNCHANGED is not a change"); return
        }

        runtime.execResult = ("maybe?", "", 0)
        guard case .error(let detail) = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "ubuntu:latest") else {
            Issue.record("any other last line is an error"); return
        }
        #expect(detail.contains("CHANGED"), "the error says what the script should have printed: \(detail)")
    }

    @Test("a non-zero exit and a timeout are errors, whatever the script printed")
    func scriptFailures() async throws {
        let runtime = GateRuntime()
        runtime.execResult = ("CHANGED", "boom", 2)
        guard case .error(let exitDetail) = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "ubuntu:latest") else {
            Issue.record("a non-zero exit is an error even with the token printed"); return
        }
        #expect(exitDetail.contains("2"))

        runtime.execError = ContainerRuntimeError.timedOut(elapsedSeconds: 31.4)
        guard case .error(let timeoutDetail) = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "ubuntu:latest") else {
            Issue.record("a timeout is an error"); return
        }
        #expect(timeoutDetail.contains("timed out"))
        #expect(timeoutDetail.contains("30"), "reported as the allowance, not the elapsed time")
    }

    @Test("the declared mounts are made read-only and the timeout is forwarded verbatim")
    func scriptMountsAndTimeout() async throws {
        let runtime = GateRuntime()
        runtime.execResult = ("UNCHANGED", "", 0)
        _ = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: ["/tmp/a", "/tmp/b:/inputs", "/tmp/c:/c:ro"],
                    timeoutSeconds: 45),
            previous: nil, runtime: runtime, image: "alpine:3")

        #expect(runtime.createdMounts == ["/tmp/a:ro", "/tmp/b:/inputs:ro", "/tmp/c:/c:ro"],
                "R28: nothing in the runtime forces read-only, so the gate does")
        #expect(runtime.creates.last?.image == "alpine:3")
        #expect(runtime.lastExecTimeout == 45)
        #expect(runtime.removedNames.count == 1, "the gate's container does not outlive the evaluation")
        #expect(runtime.creates.last?.name.hasPrefix(SandboxSessionManager.namePrefix) == true,
                "so a container a crash left behind is swept by reapOrphans")
    }

    @Test("the payload is capped at 4,000 characters")
    func scriptPayloadTruncation() async throws {
        let runtime = GateRuntime()
        runtime.execResult = (String(repeating: "x", count: 5_000) + "\nCHANGED", "", 0)
        let result = await GateEvaluator.evaluate(.script(command: "s", mounts: [], timeoutSeconds: 10),
                                                  previous: nil, runtime: runtime, image: "i")
        guard case .changed(_, let payload) = result else { Issue.record("expected a change"); return }
        #expect(payload?.count == GateEvaluator.payloadLimit)
    }

    @Test("R28: no runtime means a gate error, never a run on the host")
    func scriptWithoutARuntime() async throws {
        let result = await GateEvaluator.evaluate(.script(command: "rm -rf /", mounts: [], timeoutSeconds: 10),
                                                  previous: nil, runtime: nil)
        guard case .error(let detail) = result else {
            Issue.record("without the VM a script gate cannot be evaluated, got \(result)"); return
        }
        #expect(detail.lowercased().contains("sandbox") || detail.lowercased().contains("container"))
    }

    @Test("a container that will not start is an error, and nothing is executed")
    func scriptCreateFailure() async throws {
        let runtime = GateRuntime()
        runtime.createError = ContainerRuntimeError.createFailed("no such image")
        let result = await GateEvaluator.evaluate(.script(command: "s", mounts: [], timeoutSeconds: 10),
                                                  previous: nil, runtime: runtime, image: "i")
        guard case .error = result else { Issue.record("a failed create is an error"); return }
        #expect(runtime.execCount == 0)
        #expect(runtime.removedNames.count == 1, "and the half-made container is cleaned up")
    }

    // MARK: mount validation

    @Test("a mount is checked before a job is created, not trusted")
    func mountValidation() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)

        #expect(GateEvaluator.mountRefusal(dir.path) == nil)
        #expect(GateEvaluator.mountRefusal("\(dir.path):/inputs") == nil)
        #expect(GateEvaluator.mountRefusal("\(dir.path):/in=puts") == nil, "an = is safe in a mount")
        #expect(GateEvaluator.mountRefusal(file.path) != nil, "a single file cannot be bind-mounted")
        #expect(GateEvaluator.mountRefusal("relative/dir") != nil, "a relative source is a volume name")
        #expect(GateEvaluator.mountRefusal("/tmp/\(UUID().uuidString)") != nil, "the source must exist")
        #expect(GateEvaluator.mountRefusal("\(dir.path):/in,puts") != nil, "a comma has no escape")
    }
}

/// #187 §4 step 5 — what the gate's answer does to a fire. The evaluation itself is injected, so
/// these drive the runner's half: the row an "unchanged" leaves, the signal a "changed" stamps,
/// the payload it puts in the prompt, and the pause three errors in a row buy.
@MainActor
@Suite("Gates decide whether a fire runs (#187 §4)")
struct JobGateAdmissionTests {

    private func harness(_ responses: [GeminiResponse])
        throws -> (ConversationStore, AppState, IrisEngine, FakeLLMClient) {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true
        let userConversation = UUID()
        state.createNewConversation(id: userConversation)
        state.selectedConversationId = userConversation
        let client = FakeLLMClient(responses: responses)
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)
        return (store, state, engine, client)
    }

    private func isolatedConfig() -> (ConfigManager, () -> Void) {
        let name = "iris-gates-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        return (ConfigManager(store: store), {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    private func textResponse(_ text: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: text)]))],
                       usageMetadata: nil)
    }

    private func polled(gate: Gate = .urlChanged(url: "https://example.invalid/f")) -> Job {
        Job(name: "poller", prompt: "Reply with just the word tick.",
            trigger: .poll(PollSpec(schedule: .interval(seconds: 60), gate: gate)))
    }

    private func cards(_ state: AppState) -> [EventCard] {
        state.conversations.first { $0.id == state.activityConversationId() }?
            .messages.compactMap { EventCard.decode($0.content) } ?? []
    }

    @Test("a gate that saw no change writes a completed row, runs nothing, and posts no card")
    func unchangedWritesARowAndNoCard() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in .unchanged(signal: "etag=aaa") })

        let admission = await runner.fire(job: job, origin: .cadence(kind: "poll"))

        #expect(admission == .gateUnchanged)
        #expect(client.callCount == 0, "no turn: the gate said there was nothing to do")
        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 1)
        #expect(runs.first?.status == .completed)
        #expect(runs.first?.outcome == JobRunner.gateUnchangedOutcome)
        #expect(runs.first?.gateSignal == "etag=aaa")
        #expect(runs.first?.transcriptConversationId == nil, "and the breaker does not count it")
        #expect(cards(state).isEmpty, "cards are for things that happened")
        #expect(state.conversations.contains { $0.isBackground } == false)
    }

    @Test("a gate that saw a change runs the turn, stamps the signal and hands over its output")
    func changedRunsTheTurn() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled(gate: .script(command: "check.sh", mounts: [], timeoutSeconds: 30))
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in .changed(signal: "script=CHANGED", payload: "3 new PRs") })

        await runner.fire(job: job, origin: .cadence(kind: "poll"))

        #expect(client.callCount == 1)
        let run = try #require(try store.ledger.runs(jobId: job.id, limit: 1).first)
        #expect(run.status == .completed)
        #expect(run.gateSignal == "script=CHANGED")
        let background = try #require(state.conversations.first { $0.isBackground })
        let prompt = background.history.first?.parts.compactMap(\.text).joined() ?? ""
        #expect(prompt.contains("3 new PRs"))
        #expect(prompt.contains("source=\"gate_output\""), "untrusted, and labelled as such")
        #expect(cards(state).count == 1)
    }

    @Test("the previous signal is what the gate is asked to compare against")
    func previousSignalIsHandedToTheGate() async throws {
        let (store, state, engine, _) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let seen = Locked<[String?]>([])
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, previous in
                                   seen.mutate { $0.append(previous) }
                                   return .unchanged(signal: "etag=bbb")
                               })

        await runner.fire(job: job, origin: .cadence(kind: "poll"))
        await runner.fire(job: job, origin: .cadence(kind: "poll"))

        #expect(seen.value == [nil, "etag=bbb"])
    }

    @Test("three gate errors in a row pause the job with a card; the first two are quiet rows")
    func threeErrorsPause() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in .error("HEAD answered 500") })

        let first = await runner.fire(job: job, origin: .cadence(kind: "poll"))
        #expect(first == .gateError(detail: "HEAD answered 500", paused: false))
        await runner.fire(job: job, origin: .cadence(kind: "poll"))
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil, "two is not three")
        #expect(cards(state).isEmpty)

        let third = await runner.fire(job: job, origin: .cadence(kind: "poll"))

        #expect(third == .gateError(detail: "HEAD answered 500", paused: true))
        #expect(try store.ledger.job(id: job.id)?.pausedReason == JobRunner.gateFailingReason)
        #expect(cards(state).count == 1, "the pause is the one thing worth telling someone about")
        #expect(client.callCount == 0)
        let reasons = try store.ledger.runs(jobId: job.id, limit: 10).compactMap(\.failureReason)
        #expect(reasons.filter { $0.hasPrefix(JobRunner.gateErrorPrefix) }.count == 2)
        #expect(reasons.contains(JobRunner.gateFailingReason))
    }

    @Test("a run between two errors resets the count")
    func aGoodEvaluationResetsTheStreak() async throws {
        let (store, state, engine, _) = try harness([textResponse("tick"), textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let answers = Locked<[GateResult]>([
            .error("one"), .error("two"), .changed(signal: "s", payload: nil), .error("three"),
        ])
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in answers.mutate { $0.removeFirst() } })

        for _ in 0..<4 { await runner.fire(job: job, origin: .cadence(kind: "poll")) }

        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil,
                "three errors, but not three in a row")
    }

    @Test("an ungated job never asks a gate anything")
    func ungatedJobsAreUntouched() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = Job(name: "plain", prompt: "Reply with just the word tick.",
                      trigger: .schedule(.interval(seconds: 60)))
        try store.ledger.upsert(job)
        let asked = Locked(0)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in asked.mutate { $0 += 1 }; return .unchanged(signal: "x") })

        await runner.fire(job: job, origin: .schedule)

        #expect(asked.value == 0)
        #expect(client.callCount == 1)
    }
}

/// A value two tasks can share in a test without an actor hop.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    @discardableResult
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}
