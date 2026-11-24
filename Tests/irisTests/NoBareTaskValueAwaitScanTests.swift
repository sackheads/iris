import Testing
import Foundation

/// #1162 / #428 / #1340: a test never waits where `.timeLimit` cannot reach it. Three shapes do:
/// - `await task.value` (or `.result`) on an unstructured task ignores the waiter's cancellation: `await t.value`,
///   `await self.t.value`, `await tasks[0].value`, `await t!.value`, `await Task.detached { … }.value`, or a
///   `}.value` on the line after the closure. Await it through `value(of:within:)` (`BoundedWait.swift`).
/// - a bare `withChecked`/`withUnsafe` (`Throwing`) `Continuation` waits for whatever resumes it, and nothing else.
/// - a blocking `.wait()` with no timeout, or one of `.distantFuture` (a semaphore, a group, a condition), parks a thread for good.
/// This scan reads every test source, subfolders included (`MCPProvider/`), and fails on any such line that
/// is not on the list below. The list is keyed by file and the line itself, with how many such lines that
/// file may hold, so a new wait is caught even in a listed file, and a copy of a listed line is too. A line
/// is allowed because it is bounded (named how), or because it is a gate the test releases itself, which
/// hangs only a test that already failed (#1343 tracks a cancel-aware gate for those). Not `@MainActor`: a
/// scan of every test file is heavy synchronous work (#642).
@Suite("Tests never wait where .timeLimit can't end them (#1162, #1340)", .timeLimit(.minutes(1)))
struct NoBareTaskValueAwaitScanTests {
    /// `"<path under irisTests>: <trimmed line>"`: how many such lines the file may hold, and why each is safe.
    static let allowed: [String: (count: Int, why: String)] = [
        #"BlockingSpawnTests.swift: await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in"#: (1, #"[bounded] resumed after done.wait(), which BlockingSpawn.detached(timeoutSeconds: 10) signals"#),
        #"BlockingSpawnTests.swift: DispatchQueue(label: "iris.test.wait").async { done.wait(); c.resume() }"#: (1, #"[bounded] done is signalled by BlockingSpawn.detached(timeoutSeconds: 10) completion"#),
        #"BoundedWait.swift: let outcome = await firstOf(seconds) { await task.value }"#: (1, #"[bounded] inside firstOf's race"#),
        #"BoundedWait.swift: let outcome = await firstOf(seconds) { await task.result }"#: (1, #"[bounded] inside firstOf's race (the throwing form)"#),
        #"BoundedWait.swift: await withCheckedContinuation { first.install($0) }"#: (1, #"[bounded] firstOf: onCancel and the SuspendingClock timer both resolve"#),
        #"BoundedWait.swift: await withCheckedContinuation { c in"#: (1, #"[bounded] MainActorSignal.wait: inside a Task raced by firstOf, and resumed with nil once the race ends"#),
        #"BoundedWait.swift: let result = await firstOf(seconds) { await task.value }"#: (1, #"[bounded] MainActorSignal.wait: inside firstOf's race"#),
        #"BoundedWait.swift: await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in"#: (1, #"[bounded] TestGate.park: a release, the cancel handler or the uptime deadline (DispatchQueue asyncAfter) resumes it (#1343)"#),
        #"BoundedWait.swift: await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in"#: (1, #"[bounded] TestGate.arrivalsReached: only reached inside waitForArrivals' firstOf race, whose end cancels it (#1343)"#),
        #"BoundedWait.swift: await withCheckedContinuation { continuation in"#: (1, #"[bounded] offPool: resumed after `blocking`, which its contract requires be bounded"#),
        #"CLISignalTests.swift: static func park(_ gate: DispatchSemaphore) { gate.wait() }"#: (1, #"[exit-test child] never signalled by design; used only inside a `processExitsWith` child, which `_exit()`s"#),
        #"CatchUpTests.swift: await withCheckedContinuation { openWaiters.append($0) }"#: (1, #"[gate #1343] test-released gate, #1343: Gate.arriveAndWait: resumed only by open(); no deadline or cancel path"#),
        #"CatchUpTests.swift: await withCheckedContinuation { entryWaiters.append($0) }"#: (1, #"[bounded] Gate.entry() is only reached via waitForEntry's value(of:within:)"#),
        #"ChangeTrackingTests.swift: await withCheckedContinuation { waiters.append($0) }"#: (1, #"[bounded] inside withTaskCancellationHandler whose onCancel resumes (via MainActor hop)"#),
        #"ContainerExecGroupKillTests.swift: await withCheckedContinuation { done in"#: (1, #"[bounded] resumed after BlockingSpawn.run(timeoutSeconds:) on its own queue"#),
        #"ConversationRotationTests.swift: try await bounded("rotation to finish") { await task.value }"#: (1, #"[bounded] inside bounded(), raced against a timer"#),
        #"DirectoryReadRuleTests.swift: _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in"#: (1, #"[synchronous] resumed synchronously in the same closure"#),
        #"ExitNowRealVMTests.swift: let outcome = await driver.value"#: (1, #"[bounded] drive() is bounded polling loops (600/600/300 iterations)"#),
        #"GitHubIdentityMonitorTests.swift: await Task.detached { held.awaitStarted() }.value"#: (1, #"[bounded] `awaitStarted()` is bounded by `started.wait(timeout: 20)` (#1340)"#),
        #"HeadlessModeTests.swift: sawInsideDetached = await Task.detached { HeadlessMode.isEnabled }.value"#: (1, #"[synchronous] detached body is a synchronous property read"#),
        #"JobRetryTests.swift: return await withCheckedContinuation { continuation in"#: (1, #"[bounded] Signal.reach: detached timer resumes with false after `seconds`"#),
        #"JobRetryTests.swift: await withCheckedContinuation { continuation in"#: (2, #"[gate #1343] `finished()`'s `FirstAnswer`, raced against a detached sleep timer; and the stub stream that parks until `releaseAll()`, deaf on purpose (the test waits through `finished(within:)`)"#),
        #"JobRetryTests.swift: Task { answer.resolve(await task.value) }"#: (1, #"[bounded] inside finished()'s race; the timer resolves the outer wait"#),
        #"JobSchedulerTests.swift: await withCheckedContinuation { openWaiters.append($0) }"#: (1, #"[gate #1343] test-released gate, #1343: Gate.arriveAndWait: resumed only by open()"#),
        #"JobSchedulerTests.swift: await withCheckedContinuation { entryWaiters.append($0) }"#: (1, #"[bounded] Gate.entry() is only reached via waitForEntry's value(of:within:)"#),
        #"KillEscalationPoolStarvationTests.swift: gate.wait()"#: (1, #"[bounded] PoolHold: `release()` signals on every exit of its time-bounded body"#),
        #"LLMRetryTests.swift: #expect(await counter.value == 1)"#: (1, #"[not a task] actor Int property, not a Task"#),
        #"LedgerAttentionTests.swift: await withCheckedContinuation { held = $0; isRunning = true }"#: (1, #"[gate #1343] test-released gate, #1343: HeldCall.run parks until release() (test releases; defer Task release)"#),
        #"LedgerAttentionTests.swift: if reads == 1 { await withCheckedContinuation { held = $0; firstIsHeld = true } }"#: (1, #"[gate #1343] test-released gate, #1343: CountedRead first read parks until release() (defer Task release)"#),
        #"NotificationInstallTests.swift: if holdRequest { await withCheckedContinuation { heldRequest = $0 } }"#: (1, #"[gate #1343] test-released gate, #1343: FakeCenter holdRequest: resumed only when test resumes heldRequest"#),
        #"NotificationInstallTests.swift: if holdAdd { await withCheckedContinuation { heldAdd = $0 } }"#: (1, #"[gate #1343] test-released gate, #1343: FakeCenter holdAdd: resumed only when test resumes heldAdd"#),
        #"NotificationInstallTests.swift: if calls.holdRequest { await withCheckedContinuation { calls.held = $0 } }"#: (1, #"[gate #1343] test-released gate, #1343: holdRequest: resumed only when test resumes calls.held"#),
        #"RawHTMLSanitizerTests.swift: let task = Task<Void, Never> { await withCheckedContinuation { self.continuation = $0 } }"#: (1, #"[bounded] inside a Task awaited with value(of:within: 10)"#),
        #"RunDelegateCloseTests.swift: await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in"#: (1, #"[gate #1343] test-released gate, #1343: deliberately deaf: onCancel only counts, does not resume; released by test"#),
        #"RunJobURLTests.swift: await withCheckedContinuation { parked[n] = $0 }"#: (1, #"[gate #1343] test-released gate, #1343: Turnstile.arrive parks until release()"#),
        #"RunJobURLTests.swift: await withCheckedContinuation { arrivalWaiters.append((n, $0)) }"#: (1, #"[bounded] arrivals() only reached via waitForArrivals' value(of:)"#),
        #"SandboxTimeoutTests.swift: await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in"#: (1, #"[bounded] resumed after CLIProcessRunner.enforce (fixed-grace synchronous ladder) on a dispatch thread"#),
        #"SandboxTimeoutTests.swift: await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in"#: (2, #"[gate #1343] `untilParked`, reached only through `waitUntilParked`'s `value(of:within: 20)` (#1340); and the barrier create, a test-released gate, #1343"#),
        #"SecretsUpdateTests.swift: group.wait()"#: (1, #"[bounded] group members are finite loops of local writes; no external event"#),
        #"SessionStatusTests.swift: let watcher = Task { @MainActor in resumed.value = await ask.value }"#: (1, #"[bounded] the watcher is awaited through `value(of:)`, and the deny resumes `ask`"#),
        #"StoreLockTests.swift: let reclaimed = await withCheckedContinuation { (c: CheckedContinuation<StoreLock.Claim?, Never>) in"#: (1, #"[bounded] resumed unconditionally after done.wait(timeout: 5) on a dispatch thread"#),
        #"SyncCoalescerTests.swift: if hold { await withCheckedContinuation { parked.append($0) } }"#: (1, #"[gate #1343] test-released gate, #1343: Probe.run parks until releaseOne/releaseAll; no deadline or cancel path"#),
        #"TimeoutTests.swift: let result = await caller.result"#: (4, #"[bounded] withTimeout returns on the caller's cancel, which each test sends (two before the body starts); the body is at most a 30 s sleep"#),
        #"TimeoutTests.swift: await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in"#: (1, #"[bounded] resumed by DispatchQueue.asyncAfter(seconds) timer"#),
        #"ViewerContentRulesTests.swift: try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in"#: (1, #"[completion] resumed by compileContentRuleList's completion, which WebKit calls with the list or an error"#),
        #"ViewerZeroLookupTests.swift: let task = Task<Void, Never> { await withCheckedContinuation { self.continuation = $0 } }"#: (2, #"[bounded] inside a Task awaited with value(of:within: 10)"#),
        #"WatchCoordinatorTests.swift: await withCheckedContinuation { openWaiters.append($0) }"#: (1, #"[gate #1343] test-released gate, #1343: Gate.arriveAndWait: resumed only by open()"#),
        #"MCPProvider/GuestSessionDriverTests.swift: await withCheckedContinuation { waiters.append($0) }"#: (1, #"[gate #1343] Latch.wait, resumed by the test's open()"#),
        #"MCPProvider/IrisMCPProviderServerTests.swift: try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in"#: (2, #"[completion] rawConnect's is inside a Task awaited with value(of:within: 10); send's is resumed by .contentProcessed, which Network calls once the bytes are taken or the connection fails"#),
        #"MCPProvider/IrisMCPProviderServerTests.swift: await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in"#: (1, #"[bounded] OneShotResumer raced against asyncAfter(timeout)"#),
        #"MCPProvider/LoopbackHTTPListenerTests.swift: let connected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in"#: (1, #"[bounded] OneShotResumer raced against asyncAfter(3)"#),
        #"MCPProvider/LoopbackHTTPListenerTests.swift: let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in"#: (1, #"[bounded] OneShotResumer raced against asyncAfter(3)"#),
        #"MCPProvider/LoopbackHTTPListenerTests.swift: try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in"#: (2, #"[completion] rawConnect's is inside a Task awaited with value(of:within: 10); send's is resumed by .contentProcessed, which Network calls once the bytes are taken or the connection fails"#),
        #"MCPProvider/LoopbackHTTPListenerTests.swift: await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in"#: (1, #"[bounded] OneShotResumer raced against asyncAfter(timeout)"#),
        #"MCPProvider/LoopbackHTTPListenerTests.swift: await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in"#: (1, #"[bounded] OneShotResumer raced against asyncAfter(timeout)"#),
    ]

    /// Every allowlisted row says which kind of safe it is, so a reviewer can check each against its tag: `[bounded]`
    /// names the timer, race or bounded wait that ends it; `[gate #1343]` is a test-released gate tracked by #1343;
    /// `[completion]` is a system completion handler that is called with a result or an error; `[not a task]`, `[synchronous]`
    /// and `[exit-test child]` say why no wait exists. A row covering same-text lines of different kinds carries the weaker tag.
    static let reasonTags = ["[bounded] ", "[gate #1343] ", "[completion] ", "[not a task] ", "[synchronous] ", "[exit-test child] "]

    private static let continuation = try! NSRegularExpression(pattern: #"\bwith(Checked|Unsafe)(Throwing)?Continuation\b"#)
    private static let blockingWait = try! NSRegularExpression(pattern: #"\.wait\(\s*\)|\.wait\([^)]*\bdistantFuture\b"#)
    /// `await` applied straight to a task's `.value`/`.result`: a plain chain (`t`, `self.t`, `t!`, `ts[0]`) or a
    /// `Task { … }` / `Task.detached { … }` closure. Not `.value(…)`, a call, and not a `.value` that is only an
    /// argument inside the awaited call (`await waitFor { ready.value != nil }`).
    private static let taskValue = try! NSRegularExpression(
        pattern: #"await\s+(?:try[?!]?\s+)?(?:[A-Za-z_][\w.!\[\]]*|Task(?:\.detached)?\s*(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*\{.*\})\s*\.(value|result)\b(?!\s*\()"#)
    /// A closure's `.value` on the line after it: `}.value`, or a line that is only `.value`.
    private static let leadingValue = try! NSRegularExpression(pattern: #"^\}?\s*\.(value|result)\b(?!\s*\()"#)

    /// What the line does that `.timeLimit` can't end, or nil.
    static func kinds(of line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return [] }
        func hit(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
            r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        }
        var out: [String] = []
        if hit(continuation, line) != nil { out.append("bare continuation") }
        // An `await gate.wait()` is the gate's own async wait, caught at its continuation; only a blocking one counts.
        let range = NSRange(line.startIndex..., in: line)
        if blockingWait.matches(in: line, range: range).contains(where: { m in
            guard let r = Range(m.range, in: line) else { return false }
            return !line[..<r.lowerBound].contains("await")
        }) { out.append("blocking .wait() with no timeout") }
        if hit(leadingValue, trimmed) != nil || hit(taskValue, line) != nil { out.append("bare await of a task's value") }
        return out
    }

    /// Every flagged line in `text`, as `(key, report)`; `file` is the path under `irisTests`.
    static func flagged(in text: String, file: String) -> [(key: String, report: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { n, raw in
            let line = String(raw)
            let kinds = kinds(of: line)
            guard !kinds.isEmpty else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return ("\(file): \(trimmed)", "\(file):\(n + 1): \(kinds.joined(separator: ", ")): \(trimmed)")
        }
    }

    /// The offences across `files` (path under `irisTests` → contents): any line not on `allowed`, and any
    /// listed line that occurs more often than its count.
    static func offences(_ files: [(path: String, text: String)], allowed: [String: (count: Int, why: String)] = allowed) -> [String] {
        var seen: [String: [String]] = [:]
        for file in files {
            for f in flagged(in: file.text, file: file.path) { seen[f.key, default: []].append(f.report) }
        }
        return seen.keys.sorted().flatMap { key -> [String] in
            let reports = seen[key]!
            guard let entry = allowed[key] else { return reports }
            return reports.count > entry.count ? ["\(reports.count) such lines, \(entry.count) allowed: \(reports[0])"] : []
        }
    }

    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    static func testSources() throws -> [(path: String, text: String)] {
        let base = dir.standardizedFileURL.path + "/"
        let walk = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var out: [(path: String, text: String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" && url.lastPathComponent != "NoBareTaskValueAwaitScanTests.swift" {
            let path = url.standardizedFileURL.path
            out.append((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

    @Test("no test waits where .timeLimit can't end it, outside the listed lines")
    func noUnboundedWait() throws {
        let files = try Self.testSources()
        #expect(files.count > 100, "the scan found the test sources")
        #expect(files.contains { $0.path.hasPrefix("MCPProvider/") }, "the scan reached a subfolder")
        let found = Self.offences(files)
        #expect(found.isEmpty, "a wait .timeLimit can't end (bound it, e.g. `value(of:within:)`, or list it with why, #428): \(found)")
    }

    @Test("every listed line still exists, so the list can't quietly grow stale")
    func noStaleEntries() throws {
        var seen: [String: Int] = [:]
        for file in try Self.testSources() {
            for f in Self.flagged(in: file.text, file: file.path) { seen[f.key, default: 0] += 1 }
        }
        let stale = Self.allowed.filter { seen[$0.key] != $0.value.count }.map { "\($0.key) (listed \($0.value.count), found \(seen[$0.key] ?? 0))" }
        #expect(stale.isEmpty, "allowlist rows whose line count no longer matches: \(stale.sorted())")
    }

    /// Planner's review: an exemption says which kind of safe it is, never only that it was already there.
    @Test("every listed line carries a reason tag")
    func everyRowIsTagged() {
        for (key, entry) in Self.allowed {
            #expect(Self.reasonTags.contains { entry.why.hasPrefix($0) }, "\(key) has no reason tag: \(entry.why)")
        }
    }

    @Test("the scan sees each shape, and ignores a bounded wait, an argument's .value and a comment")
    func scanSelfCheck() {
        for line in ["await fire.value", "#expect(await child.value.status == .x)", "await self.t.value", "await tasks[0].value",
                     "await t!.value", "x = await Task.detached { 1 }.value", "}.value", "let r = await caller.result",
                     "await withCheckedContinuation { c in", "try await withCheckedThrowingContinuation { c in",
                     "await withUnsafeContinuation { c in", "sema.wait()", "group.wait( )", "_ = sema.wait(timeout: .distantFuture)", "cond.wait(until: Date.distantFuture)"] {
            #expect(!Self.kinds(of: line).isEmpty, "\(line)")
        }
        for line in ["try await value(of: fire)", "// await fire.value is the thing to avoid", "await gate.wait()",
                     "_ = sema.wait(timeout: .now() + 5)", "#expect(await waitFor { ready.value != nil })",
                     "rec.value(forHTTPHeaderField: \"x\")", "await dispatch(call).result", "x.result.contains(\"y\")"] {
            #expect(Self.kinds(of: line).isEmpty, "\(line)")
        }
    }

    @Test("a listed line is counted: one more copy of it fails, and so does an unlisted one")
    func countsAndKeys() {
        let allowed: [String: (count: Int, why: String)] = ["A.swift: sema.wait()": (1, "x")]
        #expect(Self.offences([("A.swift", "sema.wait()\n")], allowed: allowed).isEmpty)
        #expect(Self.offences([("A.swift", "sema.wait()\nsema.wait()\n")], allowed: allowed).count == 1)
        #expect(Self.offences([("B.swift", "sema.wait()\n")], allowed: allowed).count == 1, "keyed by file too")
        #expect(Self.offences([("A.swift", "other.wait()\n")], allowed: allowed).count == 1, "and by the line")
    }
}
