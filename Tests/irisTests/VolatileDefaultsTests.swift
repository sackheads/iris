import Testing
import Foundation
@testable import iris

/// `removePersistentDomain(forName:)` clears the in-memory domain but does not delete the backing
/// plist on current macOS, so the volatile bench/perf suite's atexit cleanup left a
/// `iris-bench-<pid>.plist` behind on every run. `removeSuiteFile` is the explicit filesystem
/// delete that actually gets rid of it.
@Suite("IrisDefaults volatile suite file removal")
struct VolatileDefaultsTests {
    private func makeDir(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-volatile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names { try Data().write(to: dir.appendingPathComponent(n)) }
        return dir
    }

    @Test("removeSuiteFile deletes exactly the named plist")
    func removeSuiteFileDeletesExactlyTheNamedPlist() throws {
        let dir = try makeDir(["iris-bench-4242.plist", "iris.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        IrisDefaults.removeSuiteFile(named: "iris-bench-4242", in: dir)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["iris.plist"])
        // A missing name must not throw or crash.
        IrisDefaults.removeSuiteFile(named: "iris-bench-not-there", in: dir)
    }

    @Test("the preferences directory is the user's Library/Preferences")
    func preferencesDirectoryIsLibraryPreferences() {
        #expect(IrisDefaults.preferencesDirectory.path.hasSuffix("/Library/Preferences"))
    }
}
