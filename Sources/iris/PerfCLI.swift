import Foundation

enum PerfCommand: Equatable {
    case run(suite: String, reps: Int?, out: String, fakeOnly: Bool, dumpRequestsDir: String? = nil)
    case report(path: String)
    case compare(baseline: String, current: String, threshold: Double)
}

enum PerfCLIError: Error, Equatable, LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let m) = self { return m } ; return nil }
}

/// `iris --perf run|report|compare`. Parsed before SwiftUI starts (see main.swift).
enum PerfCLI {
    static let usage = """
    usage:
      iris --perf run     <suite.json> [--reps N] [--out DIR] [--fake-only] [--dump-requests DIR]
      iris --perf report  <run.json>
      iris --perf compare <baseline.json> <run.json> [--threshold 0.20]
    """

    static func parse(_ args: [String]) -> Result<PerfCommand, PerfCLIError>? {
        guard let i = args.firstIndex(of: "--perf") else { return nil }
        var rest = Array(args[(i + 1)...])
        guard !rest.isEmpty else { return .failure(.usage("missing subcommand")) }
        let sub = rest.removeFirst()
        func flag(_ name: String) -> Bool {
            if let j = rest.firstIndex(of: name) { rest.remove(at: j); return true }
            return false
        }
        func value(_ name: String) -> String?? {   // .some(nil) means flag present without value
            guard let j = rest.firstIndex(of: name) else { return nil }
            rest.remove(at: j)
            guard j < rest.count, !rest[j].hasPrefix("--") else { return .some(nil) }
            return .some(rest.remove(at: j))
        }
        switch sub {
        case "run":
            let fakeOnly = flag("--fake-only")
            var reps: Int?
            if let v = value("--reps") {
                guard let s = v, let n = Int(s) else { return .failure(.usage("--reps needs an integer")) }
                reps = n
            }
            var out = "perf/runs"
            if let v = value("--out") {
                guard let s = v else { return .failure(.usage("--out needs a directory")) }
                out = s
            }
            var dumpRequestsDir: String?
            if let v = value("--dump-requests") {
                guard let s = v else { return .failure(.usage("--dump-requests needs a directory")) }
                dumpRequestsDir = s
            }
            guard let suite = rest.first, !suite.hasPrefix("--") else { return .failure(.usage("run needs a suite path")) }
            if rest.count > 1 { return .failure(.usage("unexpected argument \(rest[1])")) }
            return .success(.run(suite: suite, reps: reps, out: out, fakeOnly: fakeOnly, dumpRequestsDir: dumpRequestsDir))
        case "report":
            guard let path = rest.first else { return .failure(.usage("report needs a run record path")) }
            if rest.count > 1 { return .failure(.usage("unexpected argument \(rest[1])")) }
            return .success(.report(path: path))
        case "compare":
            var threshold = 0.2
            if let v = value("--threshold") {
                guard let s = v, let t = Double(s) else { return .failure(.usage("--threshold needs a number")) }
                threshold = t
            }
            guard rest.count >= 2 else { return .failure(.usage("compare needs a baseline and a current record")) }
            if rest.count > 2 { return .failure(.usage("unexpected argument \(rest[2])")) }
            return .success(.compare(baseline: rest[0], current: rest[1], threshold: threshold))
        default:
            return .failure(.usage("unknown subcommand \(sub)"))
        }
    }

    /// Fixed location for a real-lane run's cwd, workspace and volatile `~/.iris` copy — not a
    /// per-run UUID. A per-run location put a different absolute path in the skills list's
    /// `**Path:**` lines on every run (the real `skillFilePath`, unchanged since #151), which
    /// cache-busted the system prompt on every run's turn 1 and confounded cross-run cache
    /// comparisons (#321: an earlier placeholder-based fix for the path itself opened a permission
    /// hole instead — an attended `write_file` to it slipped past the protected-write-dir check —
    /// so the fix is here, at the one thing that actually varied). `base` is injectable so a test
    /// exercises this against its own directory instead of the real `$TMPDIR`, where a concurrent
    /// perf run or another test could collide with it; the app always calls this with the default,
    /// and `$TMPDIR` is per-user and stable across reboots and rebuilds on macOS.
    static func scratchWorkspaceURL(base: URL = FileManager.default.temporaryDirectory) -> URL {
        // `isDirectory: true` explicitly: without it, `appendingPathComponent` stats the path and
        // only appends a trailing slash once the directory actually exists on disk, so the same
        // call made before and after `claimScratchWorkspace` creates it returns two URLs that
        // compare unequal despite naming the same place.
        base.standardizedFileURL.appendingPathComponent("iris-perf", isDirectory: true)
    }

    /// The lock guarding exclusive use of `scratchWorkspaceURL`, beside it rather than inside it:
    /// `claimScratchWorkspace` wipes the directory at the start of every run, and a lock file
    /// living inside it would vanish with it out from under whoever is holding it.
    static func scratchLockURL(base: URL = FileManager.default.temporaryDirectory) -> URL {
        let dir = scratchWorkspaceURL(base: base)
        return dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".lock")
    }

    /// Claims the fixed scratch workspace exclusively and resets it to empty.
    ///
    /// Still "a fresh, empty directory" for the run's cwd and workspace, as promised when this was
    /// a per-run UUID (#151) — but reset rather than freshly named, now that the location is fixed
    /// (#321): a copy left behind by a run that crashed or was interrupted (SIGINT skips
    /// `PerfCLI.execute`'s cleanup `defer`, and `IrisPaths.makeVolatileCopy`'s `copyItem` throws
    /// into a destination that already exists) must never leak into the next run.
    ///
    /// Reuses `GUILock`'s pid-file protocol rather than inventing a second one: a lock naming a
    /// dead pid is stale and taken over exactly as the GUI lock is, and a live holder is refused
    /// rather than raced, so two perf runs started at once cannot clobber the same workspace.
    static func claimScratchWorkspace(base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = scratchWorkspaceURL(base: base)
        let lockURL = scratchLockURL(base: base)
        switch GUILock.acquireExclusively(at: lockURL) {
        case .acquired:
            break
        case .held(let pid):
            throw PerfCLIError.usage(
                "perf: another run (pid \(pid)) already holds the scratch workspace at \(url.path) — wait for it to finish, or stop it")
        case .blocked(let detail):
            throw PerfCLIError.usage(
                "perf: could not claim the scratch workspace lock at \(lockURL.path)" + (detail.map { ": \($0)" } ?? ""))
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Gives back the lock `claimScratchWorkspace` took. Safe to call even when the claim never
    /// succeeded: `GUILock.release` is itself a no-op unless this process is the holder.
    static func releaseScratchWorkspace(base: URL = FileManager.default.temporaryDirectory) {
        GUILock.release(at: scratchLockURL(base: base))
    }

    /// True when a real-lane run can skip the Keychain entirely: Gemini over ADC and Anthropic on
    /// Vertex AI (#181) are the configurations whose credentials live outside it.
    static func shouldBypassKeychain(provider: String?, geminiAuthMode: String?,
                                     anthropicAuthMode: String? = nil) -> Bool {
        if provider == "Gemini" { return geminiAuthMode == GeminiAuthMode.adc.rawValue }
        if provider == "Anthropic" { return anthropicAuthMode == AnthropicAuthMode.vertex.rawValue }
        return false
    }

    /// Runs `suite`, entering `HeadlessMode`'s scope first when the lane is fake. Separated from
    /// `execute` so a test can exercise exactly this decision — does a fake-lane suite actually
    /// enter the scope — without calling `IrisDefaults.useVolatileCopyOfStandard()`, which is its
    /// own process-wide latch (#324) and not this seam's concern. `client` exists only for that
    /// test seam (forwarded to `PerfRunner.run`, which forwards it to `ScenarioRunner.run`'s
    /// `clientOverride`); production never passes it. Scoped to this call's task tree (#318) — see
    /// `HeadlessMode`. For the real `iris --perf run` CLI this is the process's outermost task and
    /// `main.swift` exits right after, so the scope in practice covers the whole remaining run; a
    /// test calling this directly sees it end right here, leaving the process as it found it.
    @MainActor
    static func runSuiteRespectingLane(_ suite: PerfSuite, repetitionsOverride: Int?, out: String,
                                       dumpRequestsDir: String?,
                                       client: (any LLMClientProtocol)? = nil) async throws -> Int32 {
        let runSuite: () async throws -> Int32 = {
            let root = PerfPaths.repoRoot()   // before any cwd change
            let previousCwd = FileManager.default.currentDirectoryPath
            var scratch: URL?
            var memoryBefore: String?
            let realMemory = IrisPaths.default.memoryDir   // the real home, before any override
            if suite.lane == .real {
                // If anything between this claim and `scratch = dir` throws, the defer below
                // never sees `scratch`: the lock and the half-built directory are left for the
                // next run's claim, which reclaims a dead pid's lock and resets the directory.
                // That relies on the process exiting after `execute` returns (main.swift); a
                // long-lived host calling `execute` repeatedly would keep the lock instead.
                let dir = try claimScratchWorkspace()
                FileManager.default.changeCurrentDirectoryPath(dir.path)
                // Memory tools write through IrisPaths.default: route the whole home at a
                // copy under the scratch directory so USER.md, the fact store and skills
                // stay untouched. Reads see the same context.
                try IrisPaths.useVolatileCopy(at: dir.appendingPathComponent(".iris"))
                memoryBefore = IrisPaths.fingerprint(of: realMemory)
                print("perf: real-lane file tools, cwd and ~/.iris confined to \(dir.path)")
                scratch = dir
            }
            defer {
                // Restore the cwd before deleting the directory it pointed at, so nothing that
                // runs after this (today: exit) inherits a dangling working directory. The lock
                // is released last, after the directory is gone, so a waiting run's claim finds
                // nothing left to reset.
                if let scratch {
                    FileManager.default.changeCurrentDirectoryPath(previousCwd)
                    try? FileManager.default.removeItem(at: scratch)
                    releaseScratchWorkspace()
                }
            }
            let dumpDir = dumpRequestsDir.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0) }
            // 5a's tool-list experiment: read here, at the entry point, and passed down; never a global.
            let declareStateTools = ProcessInfo.processInfo.environment["IRIS_PERF_DECLARE_STATE_TOOLS"] == "1"
            if declareStateTools { print("perf: EXPERIMENT — declaring state-gated tools (manage_fact, peer tools) on every turn") }
            let record = try await PerfRunner.run(suite: suite, repetitionsOverride: repetitionsOverride, repoRoot: root,
                                                  client: client, headless: suite.lane == .fake, workspacePath: scratch?.path,
                                                  dumpRequestsDir: dumpDir, declareStateGatedTools: declareStateTools)
            print(PerfReport.render(record))
            let dir = out.hasPrefix("/") ? URL(fileURLWithPath: out) : root.appendingPathComponent(out)
            let url = try record.write(toDirectory: dir)
            print("perf: wrote \(url.path)")
            if let before = memoryBefore, IrisPaths.fingerprint(of: realMemory) != before {
                print("perf: WARNING the real \(realMemory.path) changed during the run; something wrote outside the volatile copy")
                return 3
            }
            return 0
        }
        if suite.lane == .fake {
            return try await HeadlessMode.withEnabled(runSuite)
        }
        return try await runSuite()
    }

    @MainActor
    static func execute(_ cmd: PerfCommand) async -> Int32 {
        do {
            switch cmd {
            case .run(let suitePath, let reps, let out, let fakeOnly, let dumpRequestsDir):
                let suite = try PerfSuite.load(at: suitePath)
                if fakeOnly, suite.lane == .real {
                    print("perf: skipping real-lane suite \(suite.name) (--fake-only)")
                    return 0
                }
                // Settings come from a volatile copy so guard toggles never persist. Must precede
                // the first touch of ConfigManager.shared (inside the runner).
                IrisDefaults.useVolatileCopyOfStandard()
                if suite.lane != .fake {
                    // A rebuilt binary prompts for Keychain access on its first secret read, which
                    // blocks an unattended run. Skip the Keychain when the provider never needs it.
                    let provider = IrisDefaults.store.string(forKey: "PRIMARY_PROVIDER") ?? "Gemini"
                    let authMode = IrisDefaults.store.string(forKey: "GEMINI_AUTH_MODE") ?? GeminiAuthMode.apiKey.rawValue
                    let anthropicMode = IrisDefaults.store.string(forKey: "ANTHROPIC_AUTH_MODE") ?? AnthropicAuthMode.apiKey.rawValue
                    if shouldBypassKeychain(provider: provider, geminiAuthMode: authMode, anthropicAuthMode: anthropicMode) {
                        KeychainManager.requestHeadlessBypass()
                    } else {
                        print("perf: provider secrets come from the Keychain; a rebuilt binary prompts once before the run can start")
                    }
                }
                return try await Self.runSuiteRespectingLane(suite, repetitionsOverride: reps, out: out,
                                                              dumpRequestsDir: dumpRequestsDir)
            case .report(let path):
                print(PerfReport.render(try PerfRunRecord.load(at: path)))
                return 0
            case .compare(let a, let b, let threshold):
                let c = PerfCompare.compare(baseline: try PerfRunRecord.load(at: a), current: try PerfRunRecord.load(at: b), threshold: threshold)
                print(PerfCompare.render(c, threshold: threshold))
                return PerfCompare.exitCode(c)
            }
        } catch {
            FileHandle.standardError.write(Data("iris --perf: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
