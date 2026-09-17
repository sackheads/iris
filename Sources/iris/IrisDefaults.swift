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
    nonisolated(unsafe) static let store: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        let suiteName = "iris-tests-\(ProcessInfo.processInfo.processIdentifier)"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName)   // every test process starts from defaults
        sweepStaleTestSuites()   // ...and takes out the plists earlier test processes left behind

        // Point the model-backed guard tiers at a path that cannot exist. `promptGuardCoreMLModel`
        // falls back to a real DeBERTa ONNX URL when unset, so a test process otherwise resolves
        // the ~704MB model in the DEVELOPER's ~/.iris/models and runs real inference: whichever
        // happens first in a run — a test installing a mock, or any engine test calling
        // `sanitize` — decided for the whole process whether the real model loaded. That made runs
        // swing between 0.9s and 11s and the Tier 2/3 tests fail in both directions. A unit run
        // must not touch the machine's model files.
        suite.set("iris-tests-no-model", forKey: "PROMPT_GUARD_COREML_MODEL")
        return suite
    }()

    /// `iris-tests-<pid>.plist` files in `directory` whose process is gone. The current process's
    /// own file is never included.
    static func staleTestSuiteFiles(in directory: URL, isAlive: (pid_t) -> Bool) -> [URL] {
        let me = ProcessInfo.processInfo.processIdentifier
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasPrefix("iris-tests-"), name.hasSuffix(".plist"),
                  let pid = pid_t(name.dropFirst("iris-tests-".count).dropLast(".plist".count)),
                  pid != me, !isAlive(pid) else { return nil }
            return directory.appendingPathComponent(name)
        }
    }

    static func sweepStaleTestSuites(in directory: URL, isAlive: (pid_t) -> Bool) {
        for url in staleTestSuiteFiles(in: directory, isAlive: isAlive) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Sweep the real preferences folder. A concurrent test process (XCTest and swift-testing
    /// run as separate processes) is still alive, so its suite is left alone.
    private static func sweepStaleTestSuites() {
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        sweepStaleTestSuites(in: prefs, isAlive: { pid in kill(pid, 0) == 0 || errno == EPERM })
    }
}
