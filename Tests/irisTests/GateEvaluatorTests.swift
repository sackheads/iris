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
    /// How long `createDetached` takes before it answers. Cancellation-aware, like the real one's
    /// kill ladder, so a caller that gives up on it is not waited out.
    var createDelaySeconds: Double?
    var execError: Error?
    var execResult: (stdout: String, stderr: String, exitCode: Int32) = ("CHANGED", "", 0)
    /// When set, `exec` waits to be cancelled and then throws, the way a real `container exec`
    /// answers a cancelled call: through the kill ladder, with the caller's task already cancelled
    /// by the time the cleanup runs.
    var execAwaitsCancellation = false

    func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws {
        lock.withLock { creates.append((name, image, mounts, workdir)) }
        if let createDelaySeconds {
            try await Task.sleep(nanoseconds: UInt64(createDelaySeconds * 1_000_000_000))
        }
        if let createError { throw createError }
    }

    /// A gate never asks for the isolated network.
    func ensureIsolatedNetwork(named name: String) async throws {}

    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws
        -> (stdout: String, stderr: String, exitCode: Int32) {
        lock.withLock { execs.append((name, workdir, command, timeoutSeconds)) }
        if lock.withLock({ execAwaitsCancellation }) {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        if let execError { throw execError }
        return lock.withLock { execResult }
    }

    /// Refuses on a cancelled task, exactly as `CLIProcessRunner.run` does — it will not launch a
    /// child for a caller that has already given up, so a cleanup taken down the ordinary path
    /// from a cancelled evaluation spawns neither `stop` nor `delete`. Modelled here so the test
    /// of that can fail when it is wrong.
    func remove(name: String) async {
        guard !Task.isCancelled else { return }
        lock.withLock { removed.append(name) }
    }
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
        // The header VALUES are a remote server's text and this signal is read back into a model's
        // context by `get_job_run`; it carries a hash of them, not the text.
        #expect(!recorded.contains("aaa"))
        #expect(recorded.contains("validators=etag,content-length"), "which ones were there is ours to say")

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

    /// M2: a `gate_path` of a home folder or `/` is a plausible ask, and the walk behind it stats
    /// every entry on every tick. Past the cap the gate says so — an error, which counts towards
    /// the three-error pause — rather than quietly spending minutes of a thread each time.
    @Test("a directory with more entries than the cap is a gate error, not a long walk")
    func pathDirectoryTooLarge() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<4 {
            try "\(i)".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }

        let result = await GateEvaluator.evaluate(.pathChanged(path: dir.path), previous: nil,
                                                  runtime: nil, directoryEntryLimit: 3)
        guard case .error(let detail) = result else {
            Issue.record("a tree past the cap is an error, got \(result)"); return
        }
        #expect(detail.contains(dir.path))
        #expect(detail.contains("gate_script"), "and it says what to do instead")

        // Just inside the cap it is an ordinary gate again.
        guard case .changed = await GateEvaluator.evaluate(.pathChanged(path: dir.path), previous: nil,
                                                           runtime: nil, directoryEntryLimit: 4) else {
            Issue.record("four entries under a cap of four is fine"); return
        }
    }

    @Test("the walk stops at the cap rather than counting the rest")
    func walkStopsAtTheCap() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<20 {
            try "\(i)".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        let walked = GateEvaluator.walk(dir.path, fileManager: .default, limit: 5)
        #expect(walked.overLimit)
        #expect(walked.entries == 6, "one past the cap is enough to know")
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

    /// L8: a legacy row with no gate decodes to a script gate with an empty command. It is a gate
    /// error either way, but it need not cost three container create/remove cycles to find out.
    @Test("a script gate with no script says so without starting a container")
    func emptyScriptStartsNothing() async {
        let runtime = GateRuntime()
        let result = await GateEvaluator.evaluate(.script(command: "  ", mounts: [], timeoutSeconds: 60),
                                                  previous: nil, runtime: runtime, image: "img")
        guard case .error = result else { Issue.record("expected an error, got \(result)"); return }
        #expect(runtime.creates.isEmpty)
    }

    @Test("the verdict is the last line of stdout, and the rest is the payload")
    func scriptTokens() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = GateRuntime()
        runtime.execResult = ("3 new PRs\nCHANGED\n", "", 0)
        let changed = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [IrisPaths.canonicalPath(dir.path)], timeoutSeconds: 30),
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
        // Real directories, because a stored mount is checked against what is on disk at every
        // evaluation now (R33) — a gate whose source is not there is an error, not a create.
        let a = try temporaryDirectory(), b = try temporaryDirectory(), c = try temporaryDirectory()
        defer { for d in [a, b, c] { try? FileManager.default.removeItem(at: d) } }
        let (pa, pb, pc) = (IrisPaths.canonicalPath(a.path), IrisPaths.canonicalPath(b.path),
                            IrisPaths.canonicalPath(c.path))
        let runtime = GateRuntime()
        runtime.execResult = ("UNCHANGED", "", 0)
        _ = await GateEvaluator.evaluate(
            .script(command: "check.sh", mounts: [pa, "\(pb):/inputs", "\(pc):/c:ro"],
                    timeoutSeconds: 45),
            previous: nil, runtime: runtime, image: "alpine:3")

        #expect(runtime.createdMounts == ["\(pa):ro", "\(pb):/inputs:ro", "\(pc):/c:ro"],
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

    @Test("a server that refuses HEAD, or sends nothing to compare, says what to do instead")
    func urlErrorsAreActionable() async throws {
        let refusesHead = stub(405, [:])
        defer { refusesHead.remove() }
        guard case .error(let notAllowed) = await GateEvaluator.evaluate(
            .urlChanged(url: "https://example.invalid/f"), previous: nil, runtime: nil,
            http: refusesHead.session) else { Issue.record("405 is an error"); return }
        #expect(notAllowed.contains(GateEvaluator.tryAnotherGate))

        let bare = stub(200, [:])
        defer { bare.remove() }
        guard case .error(let nothing) = await GateEvaluator.evaluate(
            .urlChanged(url: "https://example.invalid/f"), previous: nil, runtime: nil,
            http: bare.session) else { Issue.record("no validators is an error"); return }
        #expect(nothing.contains(GateEvaluator.tryAnotherGate))
    }

    @Test("a create that never answers is bounded, and nothing is left running")
    func scriptCreateCeiling() async throws {
        let runtime = GateRuntime()
        runtime.createDelaySeconds = 30      // longer than any test would wait for
        let started = Date()
        let result = await GateEvaluator.evaluate(.script(command: "s", mounts: [], timeoutSeconds: 10),
                                                  previous: nil, runtime: runtime, image: "i",
                                                  createCeilingSeconds: 1)

        guard case .error(let detail) = result else {
            Issue.record("a wedged create is a gate error, not a wedged job: \(result)"); return
        }
        #expect(detail.contains("could not be started within"))
        #expect(Date().timeIntervalSince(started) < 10, "and it answered at the ceiling, not at the create")
        #expect(runtime.execCount == 0)
        #expect(runtime.removedNames.count == 1, "the half-started container is swept")
    }

    @Test("a mount whose target is called /ro is still given the read-only flag")
    func readOnlyIsNotASuffixMatch() {
        #expect(GateEvaluator.readOnly(["/host/dir:/ro"]) == ["/host/dir:/ro:ro"])
        #expect(GateEvaluator.readOnly(["/host/dir:ro"]) == ["/host/dir:ro"], "already flagged")
        #expect(ContainerMount.hasReadOnlyFlag("/host/dir:/ro") == false)
        #expect(ContainerMount.hasReadOnlyFlag("/host/dir:ro"))
    }

    /// R33: the mounts are a standing read capability, granted once by a review, so what is bound
    /// at every later tick must still be what was reviewed. A source that now resolves elsewhere —
    /// deleted and replaced by a link, which takes one command — is a gate error, and nothing is
    /// started.
    @Test("a mount source swapped after creation is a gate error, and no container is made")
    func mountDriftIsAGateError() async throws {
        let watched = try temporaryDirectory()
        let elsewhere = try temporaryDirectory()
        defer { for d in [watched, elsewhere] { try? FileManager.default.removeItem(at: d) } }
        let stored = "\(IrisPaths.canonicalPath(watched.path)):/in:ro"
        let gate = Gate.script(command: "ls /in; echo UNCHANGED", mounts: [stored], timeoutSeconds: 30)

        let runtime = GateRuntime()
        runtime.execResult = ("UNCHANGED", "", 0)
        guard case .unchanged = await GateEvaluator.evaluate(gate, previous: nil, runtime: runtime,
                                                             image: "i") else {
            Issue.record("the directory is still the one that was approved"); return
        }

        // The same path, pointed somewhere else.
        try FileManager.default.removeItem(at: watched)
        try FileManager.default.createSymbolicLink(at: watched, withDestinationURL: elsewhere)

        let result = await GateEvaluator.evaluate(gate, previous: nil, runtime: runtime, image: "i")

        guard case .error(let detail) = result else {
            Issue.record("a mount that moved is a gate error, got \(result)"); return
        }
        #expect(detail.contains("now resolves to"))
        #expect(detail.contains(IrisPaths.canonicalPath(elsewhere.path)))
        #expect(runtime.creates.count == 1, "the second evaluation started nothing")
    }

    @Test("a mount source that is no longer a directory is a gate error")
    func mountThatIsNoLongerADirectory() async throws {
        let watched = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: watched) }
        let stored = "\(IrisPaths.canonicalPath(watched.path)):/in:ro"
        try FileManager.default.removeItem(at: watched)
        try "not a directory".write(to: watched, atomically: true, encoding: .utf8)

        let runtime = GateRuntime()
        let result = await GateEvaluator.evaluate(
            .script(command: "echo UNCHANGED", mounts: [stored], timeoutSeconds: 30),
            previous: nil, runtime: runtime, image: "i")

        guard case .error(let detail) = result else {
            Issue.record("expected a gate error, got \(result)"); return
        }
        #expect(detail.contains("no longer a directory"))
        #expect(runtime.creates.isEmpty)
    }

    /// R34: cancellation is exactly when a container most needs removing, and exactly when the
    /// ordinary route will not do it — the CLI refuses to launch on a cancelled task, so a plain
    /// `remove` spawns neither `stop` nor `delete` and the container lives until something sweeps
    /// it. `GateRuntime.remove` refuses the same way, so this fails when the cleanup does.
    @Test("a cancelled evaluation still removes the container it started", .timeLimit(.minutes(1)))
    func cancelledEvaluationStillRemoves() async throws {
        let runtime = GateRuntime()
        runtime.execAwaitsCancellation = true
        let evaluation = Task {
            await GateEvaluator.evaluate(.script(command: "sleep 600", mounts: [], timeoutSeconds: 600),
                                         previous: nil, runtime: runtime, image: "i")
        }
        while runtime.execCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        evaluation.cancel()
        let result = await evaluation.value

        guard case .error = result else { Issue.record("a cancelled gate answers no verdict"); return }
        let name = try #require(runtime.creates.last?.name)
        #expect(runtime.removedNames == [name], "the gate's container does not outlive a cancelled tick")
        #expect(!(await GateContainerRegistry.shared.current().contains(name)),
                "and it is out of the in-flight set, so a later sweep is free to take it")
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

        // R33: the whole disk, and Iris's own configuration, are refused by where they resolve to
        // rather than by how they are written. The home here is a stand-in, so nothing in this
        // test goes near the real `~/.iris` (invariant 7).
        let home = IrisPaths(root: try temporaryDirectory())
        try FileManager.default.createDirectory(at: home.configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.pluginsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home.root) }
        #expect(GateEvaluator.mountRefusal("/", paths: home) != nil, "a gate may not mount /")
        #expect(GateEvaluator.mountRefusal(home.configDir.path, paths: home) != nil)
        #expect(GateEvaluator.mountRefusal(home.pluginsDir.path, paths: home) != nil)
        #expect(GateEvaluator.mountRefusal(dir.path, paths: home) == nil, "and anything else is fine")
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
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
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
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
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
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
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
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
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

    /// R34: a gate whose *ledger* cannot be read is a gate that cannot answer, and it is counted
    /// as one. Before, the row it wrote carried no gate-error prefix, so the streak never saw it:
    /// an unreadable ledger left the job writing a row every tick for ever — never running, never
    /// pausing, never carded, which is the exact failure the three-error pause exists to end.
    @Test("three ledger reads that fail pause the job, like any other gate that cannot answer")
    func unreadableLedgerPausesToo() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        struct Unreadable: Error {}
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in
                                   Issue.record("the gate is never asked when its signal cannot be read")
                                   return .unchanged(signal: "x")
                               },
                               lastGateSignal: { _ in throw Unreadable() })

        for _ in 0..<2 { await runner.fire(job: job, origin: .cadence(kind: "poll")) }
        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil, "two is not three")
        #expect(cards(state).isEmpty, "the first two are quiet rows, like any other gate error")

        let third = await runner.fire(job: job, origin: .cadence(kind: "poll"))

        guard case .gateError(_, let paused) = third else {
            Issue.record("an unreadable ledger is a gate error, got \(third)"); return
        }
        #expect(paused)
        #expect(try store.ledger.job(id: job.id)?.pausedReason == JobRunner.gateFailingReason)
        #expect(cards(state).count == 1, "and somebody is told, once")
        #expect(client.callCount == 0, "no turn was ever spent")
        let reasons = try store.ledger.runs(jobId: job.id, limit: 10).compactMap(\.failureReason)
        #expect(reasons.filter { $0.hasPrefix(JobRunner.gateErrorPrefix) }.count == 2,
                "the rows the streak counts are the rows it wrote")
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
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in answers.mutate { $0.removeFirst() } })

        for _ in 0..<4 { await runner.fire(job: job, origin: .cadence(kind: "poll")) }

        #expect(try store.ledger.job(id: job.id)?.pausedReason == nil,
                "three errors, but not three in a row")
    }

    // MARK: Which fires the gate decides (R29)

    @Test("a cadence fire that is not a retry is the gate's to decide, held or not")
    func gateApplicability() {
        let fresh = polled()
        var retrying = polled(); retrying.retryAttempt = 1
        #expect(JobRunner.gateApplies(origin: .cadence(kind: "poll"), job: fresh))
        #expect(!JobRunner.gateApplies(origin: .cadence(kind: "poll"), job: retrying),
                "a retry re-runs work the gate already authorised")
        #expect(!JobRunner.gateApplies(origin: .manual, job: fresh), "a person asked for this one")
        #expect(JobRunner.gateApplies(origin: .queued(from: .cadence(kind: "poll")), job: fresh),
                "a held cadence fire is one whose gate was never asked")
        #expect(!JobRunner.gateApplies(origin: .queued(from: .manual), job: fresh),
                "but a held hand-started fire is still the person's")
        #expect(!JobRunner.gateApplies(origin: .watcher(paths: ["/tmp/a"]), job: fresh))
    }

    /// R29 as amended: the fire the `queue` policy held is a cadence fire whose gate was never
    /// asked — it was held before the question could be put, or held *because* the gate had just
    /// said nothing had changed. Re-entering without asking spends the whole model turn the gate
    /// exists to avoid, immediately after the gate said not to.
    @Test("a fire the queue policy held is still the gate's to decide")
    func queuedCadenceFireAsksTheGate() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let asked = Locked(0)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in
                                   asked.mutate { $0 += 1 }
                                   return .unchanged(signal: "etag=one")
                               })

        await runner.fire(job: job, origin: .queued(from: .cadence(kind: "poll")))

        #expect(asked.value == 1, "the held fire's gate is asked, exactly once")
        #expect(client.callCount == 0, "and nothing had changed, so no turn was spent")
        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.first?.outcome == JobRunner.gateUnchangedOutcome)
    }

    @Test("a gated run that fails is retried, and the retry does the work")
    func retryOfAGatedRunIsNotGated() async throws {
        // The regression: the failed run stamps its signal, so a retry a minute later would ask
        // the gate, hear "nothing has changed since the run that failed", write a `completed`
        // "gate: no change" row and leave the ladder stuck at attempt 1 for ever.
        let (store, state, engine, client) = try harness([textResponse(""), textResponse("done")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let asked = Locked(0)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in
                                   asked.mutate { $0 += 1 }
                                   return asked.value == 1 ? .changed(signal: "etag=one", payload: nil)
                                                           : .unchanged(signal: "etag=one")
                               })

        await runner.fire(job: job, origin: .cadence(kind: "poll"))
        #expect(try store.ledger.job(id: job.id)?.retryAttempt == 1, "the failure is on the ladder")

        await runner.fire(job: job, origin: .cadence(kind: "poll"))   // the retry tick

        #expect(asked.value == 1, "the retry does not ask the gate again")
        #expect(client.callCount == 2, "the work the failed run was gated for actually happens")
        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.count == 2)
        #expect(runs.map(\.status) == [.completed, .failed], "newest first")
        #expect(!runs.contains { $0.outcome == JobRunner.gateUnchangedOutcome })
        #expect(try store.ledger.job(id: job.id)?.retryAttempt == 0, "and the ladder is cleared")
    }

    @Test("a hand-started fire runs whatever the gate would have said")
    func manualFireSkipsTheGate() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let asked = Locked(0)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, _ in
                                   asked.mutate { $0 += 1 }
                                   return .unchanged(signal: "etag=one")
                               })

        let admission = await runner.fire(job: job, origin: .manual)

        #expect(admission == .run)
        #expect(asked.value == 0, "`/jobs run` is a person saying run it now")
        #expect(client.callCount == 1)
        #expect(try store.ledger.runs(jobId: job.id, limit: 5).first?.outcome == "tick")
    }

    @Test("the next fresh cadence fire after a run asks the gate again")
    func gateIsAskedAgainOnTheNextTick() async throws {
        let (store, state, engine, client) = try harness([textResponse("tick")])
        let (config, teardown) = isolatedConfig()
        defer { teardown() }
        let job = polled()
        try store.ledger.upsert(job)
        let asked = Locked(0)
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
                               protectionEnabled: false,
                               gateEvaluator: { _, previous in
                                   asked.mutate { $0 += 1 }
                                   return previous == nil ? .changed(signal: "etag=one", payload: nil)
                                                          : .unchanged(signal: "etag=one")
                               })

        await runner.fire(job: job, origin: .cadence(kind: "poll"))
        await runner.fire(job: job, origin: .cadence(kind: "poll"))

        #expect(asked.value == 2)
        #expect(client.callCount == 1, "the second tick found nothing to do")
        let runs = try store.ledger.runs(jobId: job.id, limit: 10)
        #expect(runs.first?.outcome == JobRunner.gateUnchangedOutcome)
        #expect(runs.count == 2)
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
        let runner = JobRunner(state: state, engine: engine, ledger: store.ledger, endSandboxSession: { _ in }, config: config,
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
