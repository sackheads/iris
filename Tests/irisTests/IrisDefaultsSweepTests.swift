import Testing
import Foundation
@testable import iris

/// Every test process gets its own `iris-tests-<pid>` defaults suite (#121) but nothing removed
/// the plist afterwards, so ~/Library/Preferences accumulated one file per run (about a thousand
/// on one machine). Files whose pid is gone are swept on the next test start.
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
}
