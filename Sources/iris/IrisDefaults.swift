import Foundation

/// The single `UserDefaults` every persisted setting and store goes through.
///
/// Under `swift test` this is a volatile, per-process suite rather than the user's real defaults.
/// Without it, anything a test persists survives the test process: conversations accumulate run
/// after run (344 of them on one machine before this existed), a test can flip
/// `HAS_COMPLETED_SETUP` and change whether the real app shows its setup wizard, and any assertion
/// about a count is measured against a baseline that grows forever. #109 established this pattern
/// for `ConfigManager`; #121 extended it to everything else that persists.
///
/// XCTest is only linked into the test bundle, never the shipping app, so its presence is a
/// reliable "running under tests" signal — the same test `KeychainManager` uses for its in-memory
/// secret store.
enum IrisDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: UserDefaults?
    nonisolated(unsafe) private static var volatileSuiteName: String?

    /// The store everything persists through. A volatile override (set by --bench/--perf before
    /// anything touches `ConfigManager.shared`) wins over the per-process default.
    static var store: UserDefaults {
        lock.withLock { override } ?? processStore
    }

    /// True only under --bench/--perf. Gates every code path that mutates ConfigManager for a run.
    static var isVolatileCopy: Bool { lock.withLock { override != nil } }

    /// The domain the shipping app persists to: the bundle id in a .app, the process name under
    /// `swift run` (which is why the dev plist is `iris.plist`).
    static var appDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    nonisolated(unsafe) private static let processStore: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        let suiteName = "iris-tests-\(ProcessInfo.processInfo.processIdentifier)"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName)   // every test process starts from defaults
        // ...and takes out the plists earlier test processes left behind. Off this initializer:
        // the folder holds hundreds of per-test plists inside the hour, and listing and stat-ing
        // them under `swift_once` parked every thread that touched the store, the main actor
        // included, for ~200 ms at the start of a run (#366). Nothing here depends on the sweep.
        DispatchQueue.global(qos: .utility).async { sweepStaleTestSuites() }

        // Point the model-backed guard tiers at a path that cannot exist. `promptGuardCoreMLModel`
        // falls back to a real DeBERTa ONNX URL when unset. Before #304 that resolved the ~704MB
        // model in the developer's real ~/.iris/models, and whichever happened first in a run — a
        // test installing a mock, or any engine test calling `sanitize` — decided for the whole
        // process whether the real model loaded, so runs swung between 0.9s and 11s and the Tier
        // 2/3 tests failed in both directions. The test home has no models now, but the name stays
        // pinned so the tier's state is decided here, not by what a models directory holds.
        suite.set("iris-tests-no-model", forKey: "PROMPT_GUARD_COREML_MODEL")
        return suite
    }()

    /// Seed a throwaway suite from the user's real domain and route the store to it. Call it before
    /// `ConfigManager.shared` is first touched so the run's initial values come from the copy; even
    /// if that ordering slips, a `ConfigManager` built without an injected store (which is every
    /// production one, `shared` included) computes `store` from here on each write, so every later
    /// write still lands in the copy and never in the real domain.
    static func useVolatileCopyOfStandard() {
        // Also clears plists left by earlier bench/perf/test processes that crashed or were
        // killed before their own atexit handler ran; live pids and this process are skipped.
        sweepStaleTestSuites()
        let seed = perfSeed(from: UserDefaults.standard.persistentDomain(forName: appDomain) ?? [:])
        let name = "iris-bench-\(ProcessInfo.processInfo.processIdentifier)"
        let copy = makeVolatileCopy(of: seed, suiteName: name)
        lock.withLock { override = copy; volatileSuiteName = name }
        atexit {
            // Read under the same lock useVolatileCopyOfStandard() writes with — atexit runs on
            // whatever thread calls exit(), so this is a genuine cross-thread read.
            if let n = IrisDefaults.lock.withLock({ IrisDefaults.volatileSuiteName }) {
                UserDefaults(suiteName: n)?.removePersistentDomain(forName: n)
                // removePersistentDomain does not delete the backing plist on current macOS.
                IrisDefaults.removeSuiteFile(named: n, in: IrisDefaults.preferencesDirectory)
            }
        }
    }

    /// Drop the legacy conversation blob (live, parked and backup keys) from a domain. A headless
    /// perf run gets a fresh in-memory conversation store per repetition, so a seeded blob would
    /// make every repetition decode it and import it into that store on `AppState()` — on the
    /// author's machine 472 KB of JSON plus the row inserts, inside the measured window. The
    /// store itself never reaches a volatile copy (spec §1), so there is nothing else to strip.
    ///
    /// Pulled out of `perfSeed` so `ReleaseDefaultsImport.importOnce` can drop the blob without
    /// also picking up `perfSeed`'s `IRIS_PERF_SEED_JSON` environment override — the release
    /// launch path must never read a perf-only env var (see `perfSeed`'s doc).
    static func stripConversationBlob(from domain: [String: Any]) -> [String: Any] {
        domain.filter { key, _ in
            key != "iris_conversations" && key != "iris_conversations_legacy" && !key.hasPrefix("iris_conversations_backup_")
        }
    }

    /// `stripConversationBlob`, then `IRIS_PERF_SEED_JSON`, if present in `environment`, overrides
    /// keys in the result — any `ConfigManager` key, by its raw `UserDefaults` name, not a fixed
    /// set. The #314 Phase 1 measurement (PR #405) used this, as a one-off patch to this function,
    /// to target Anthropic on Vertex without writing the real domain; it is a standing feature of
    /// the seed path now, which is how a later perf run sets `REPLAY_THINKING_WITHIN_TURN` (or any
    /// other key) too. `environment` defaults to the real process environment, as every
    /// production caller wants, but takes a fake dict in a test so the real environment is never
    /// mutated (invariant 7). Malformed or absent JSON leaves the domain's own values untouched.
    /// Perf/bench callers only — `ReleaseDefaultsImport.importOnce` calls `stripConversationBlob`
    /// directly so the release launch path never applies this override.
    static func perfSeed(from domain: [String: Any], environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: Any] {
        var seed = stripConversationBlob(from: domain)
        if let raw = environment["IRIS_PERF_SEED_JSON"],
           let extra = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            seed.merge(extra) { _, new in new }
        }
        return seed
    }

    static func makeVolatileCopy(of seed: [String: Any], suiteName: String) -> UserDefaults {
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName)
        suite.setPersistentDomain(seed, forName: suiteName)
        return suite
    }

    /// Where `UserDefaults(suiteName:)` plists actually live on disk.
    static let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences")

    /// Delete `<name>.plist` from `directory` directly, since `removePersistentDomain` won't.
    /// A missing file is not an error.
    /// Note this is best-effort, not a guarantee: `cfprefsd` still holds the domain and writes an
    /// empty 42-byte plist back after the delete, so a suite whose test cleaned up properly can
    /// still leave a file behind — measured at one file per suite on macOS 25.6, which is how
    /// `iris-legacy-blob-<UUID>` reached 164 files despite doing everything right (#178).
    /// `CFPreferencesAppSynchronize` before the delete does not change that. The age-based half of
    /// `staleTestSuiteFiles` is the backstop.
    static func removeSuiteFile(named name: String, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).plist"))
    }

    /// How long a pid-less test suite plist must have gone untouched before the sweep takes it.
    /// Long enough that a concurrently running test process's own suites are never pulled out from
    /// under it; short enough that the files do not accumulate across a day's work.
    static let volatileSuiteMaxAge: TimeInterval = 3600

    /// Test-only suite plists in `directory` that nothing can still be using:
    /// - `iris-tests-<pid>.plist` / `iris-bench-<pid>.plist` whose process is gone. The current
    ///   process's own file is never included.
    /// - `iris-volatile-*.plist`, and any `iris-*-<UUID>.plist`, last modified more than
    ///   `volatileSuiteMaxAge` before `now`. A per-test suite is named with a UUID rather than a
    ///   pid, so age is the only liveness signal there is — and it needs one, because a test that
    ///   deletes its own plist in a `defer` still gets it recreated by `cfprefsd` (see
    ///   `removeSuiteFile`). This machine had 108 `iris-volatile-*` and 164 `iris-legacy-blob-*`
    ///   of them, each one kept resident by `cfprefsd` (#178).
    static func staleTestSuiteFiles(in directory: URL, isAlive: (pid_t) -> Bool, now: Date = Date()) -> [URL] {
        let me = ProcessInfo.processInfo.processIdentifier
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".plist") else { return nil }
            let url = directory.appendingPathComponent(name)
            let stem = name.dropLast(".plist".count)
            let isPidless = name.hasPrefix("iris-volatile-")
                || (name.hasPrefix("iris-") && UUID(uuidString: String(stem.suffix(36))) != nil)
            if isPidless {
                guard let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) > volatileSuiteMaxAge else { return nil }
                return url
            }
            guard let prefix = ["iris-tests-", "iris-bench-"].first(where: name.hasPrefix),
                  let pid = pid_t(name.dropFirst(prefix.count).dropLast(".plist".count)),
                  pid != me, !isAlive(pid) else { return nil }
            return url
        }
    }

    static func sweepStaleTestSuites(in directory: URL, isAlive: (pid_t) -> Bool, now: Date = Date()) {
        for url in staleTestSuiteFiles(in: directory, isAlive: isAlive, now: now) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Sweep the real preferences folder. A concurrent test process (XCTest and swift-testing
    /// run as separate processes) is still alive, so its suite is left alone — and any
    /// `iris-volatile-*` suite it is using right now was written within the hour, so that is left
    /// alone too.
    private static func sweepStaleTestSuites() {
        sweepStaleTestSuites(in: preferencesDirectory, isAlive: isProcessAlive)
    }

    /// Whether a test process named by a file is still running. `pid > 0` first: `kill(0, 0)`
    /// probes our own process group and a negative pid probes a group, so either would read as
    /// alive forever. EPERM means the process exists but belongs to someone else.
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
