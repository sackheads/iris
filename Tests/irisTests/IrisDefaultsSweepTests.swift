import Testing
import Foundation
@testable import iris

/// Every test process gets its own `iris-tests-<pid>` defaults suite (#121) but nothing removed
/// the plist afterwards, so ~/Library/Preferences accumulated one file per run (about a thousand
/// on one machine). Files whose pid is gone are swept on the next test start — as are the
/// UUID-named `iris-volatile-*` suites the volatile-copy tests create, once they are an hour old
/// (#178): they carry no pid, so nothing else would ever classify them as dead.
@Suite("IrisDefaults stale suite sweep")
struct IrisDefaultsSweepTests {
    private func makeDir(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in names { try Data().write(to: dir.appendingPathComponent(n)) }
        return dir
    }

    @Test("only iris-tests plists whose pid is dead are selected")
    func selectsDeadPidsOnly() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let dir = try makeDir(["iris-tests-1.plist", "iris-tests-99999.plist", "iris-tests-\(me).plist",
                               "iris.plist", "iris-tests-notapid.plist", "other-99999.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = IrisDefaults.staleTestSuiteFiles(in: dir, isAlive: { $0 == 1 })
        #expect(stale.map(\.lastPathComponent) == ["iris-tests-99999.plist"])
    }

    @Test("the current process's own suite is never selected even if isAlive says otherwise")
    func neverSelectsSelf() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let dir = try makeDir(["iris-tests-\(me).plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(IrisDefaults.staleTestSuiteFiles(in: dir, isAlive: { _ in false }).isEmpty)
    }

    @Test("sweep removes the stale files and leaves the rest")
    func sweepRemoves() throws {
        let dir = try makeDir(["iris-tests-99998.plist", "iris-tests-99999.plist", "iris.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        IrisDefaults.sweepStaleTestSuites(in: dir, isAlive: { _ in false })
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["iris.plist"])
    }

    @Test("bench suites are swept too")
    func benchSuitesAreSwept() throws {
        let dir = try makeDir(["iris-bench-99999.plist", "iris-tests-99998.plist", "iris.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = IrisDefaults.staleTestSuiteFiles(in: dir, isAlive: { _ in false })
        #expect(stale.map(\.lastPathComponent) == ["iris-bench-99999.plist", "iris-tests-99998.plist"])
    }

    private func touch(_ dir: URL, _ name: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: dir.appendingPathComponent(name).path)
    }

    /// The volatile-copy suites carry a UUID, not a pid, so no liveness check can classify them;
    /// age is the only signal. 108 of them had piled up in ~/Library/Preferences by #178.
    @Test("volatile suites older than an hour are selected and fresh ones are left alone")
    func oldVolatileSuitesOnly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = try makeDir(["iris-volatile-copy-old.plist", "iris-volatile-copy-fresh.plist",
                               "iris-volatile-seed-old.plist", "iris-volatile.plist", "iris.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(dir, "iris-volatile-copy-old.plist", now.addingTimeInterval(-2 * 3600))
        try touch(dir, "iris-volatile-seed-old.plist", now.addingTimeInterval(-25 * 3600))
        try touch(dir, "iris-volatile-copy-fresh.plist", now.addingTimeInterval(-60))
        try touch(dir, "iris-volatile.plist", now.addingTimeInterval(-2 * 3600))
        try touch(dir, "iris.plist", now.addingTimeInterval(-99 * 3600))

        let stale = IrisDefaults.staleTestSuiteFiles(in: dir, isAlive: { _ in false }, now: now)
        #expect(stale.map(\.lastPathComponent) == ["iris-volatile-copy-old.plist", "iris-volatile-seed-old.plist"])
    }

    /// Every per-test suite is `iris-<something>-<UUID>`: `iris-legacy-blob-*` had 164 files on
    /// the same machine, and the isolated `ConfigManager` suites added by #193 are the same shape.
    /// Their `defer` cleanup does not stick because cfprefsd rewrites the plist after the delete.
    @Test("UUID-named iris suites older than an hour are selected, whatever the middle name")
    func oldUUIDNamedSuites() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = UUID().uuidString, fresh = UUID().uuidString
        let dir = try makeDir(["iris-legacy-blob-\(old).plist", "iris-emoji-\(fresh).plist",
                               "other-\(old).plist", "iris.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(dir, "iris-legacy-blob-\(old).plist", now.addingTimeInterval(-3601))
        try touch(dir, "iris-emoji-\(fresh).plist", now.addingTimeInterval(-3599))
        try touch(dir, "other-\(old).plist", now.addingTimeInterval(-99 * 3600))
        try touch(dir, "iris.plist", now.addingTimeInterval(-99 * 3600))

        let stale = IrisDefaults.staleTestSuiteFiles(in: dir, isAlive: { _ in false }, now: now)
        #expect(stale.map(\.lastPathComponent) == ["iris-legacy-blob-\(old).plist"])
    }

    @Test("a volatile suite still in use by a running process is not swept")
    func freshVolatileSuiteSurvivesTheSweep() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = try makeDir(["iris-volatile-copy-live.plist", "iris-volatile-copy-old.plist"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(dir, "iris-volatile-copy-live.plist", now)
        try touch(dir, "iris-volatile-copy-old.plist", now.addingTimeInterval(-3601))

        IrisDefaults.sweepStaleTestSuites(in: dir, isAlive: { _ in false }, now: now)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(left == ["iris-volatile-copy-live.plist"])
    }
}
