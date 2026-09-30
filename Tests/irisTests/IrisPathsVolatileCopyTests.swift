import Testing
import Foundation
@testable import iris

/// Real-lane perf runs wrote to the user's real memory (USER.md, the fact store) through
/// `IrisPaths.default`, which the sandbox and the scratch workspace do not cover. A headless run
/// now routes every path at a copy of ~/.iris under its scratch directory: reads see the same
/// context, writes land in the copy, and the copy dies with the run.
@Suite("IrisPaths volatile copy")
struct IrisPathsVolatileCopyTests {
    private func makeSource() throws -> IrisPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-src-\(UUID().uuidString)")
        let src = IrisPaths(root: root)
        try src.ensureDirectories()
        try "profile-before".write(to: src.userMd, atomically: true, encoding: .utf8)
        let skill = src.skillsDir.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "skill body".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: src.settingsJSON, atomically: true, encoding: .utf8)
        try Data(count: 1024).write(to: src.modelsDir.appendingPathComponent("big.bin"))
        return src
    }

    @Test("the copy carries memory, rules and config; models are a symlink, not a copy")
    func copyLayout() throws {
        let src = try makeSource()
        defer { try? FileManager.default.removeItem(at: src.root) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("iris-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let copy = try IrisPaths.makeVolatileCopy(of: src, at: dest)
        #expect(copy.root == dest)
        #expect(try String(contentsOf: copy.userMd, encoding: .utf8) == "profile-before")
        #expect(try String(contentsOf: copy.skillsDir.appendingPathComponent("demo/SKILL.md"), encoding: .utf8) == "skill body")
        #expect(FileManager.default.fileExists(atPath: copy.settingsJSON.path))
        let modelsLink = try FileManager.default.destinationOfSymbolicLink(atPath: copy.modelsDir.path)
        #expect(URL(fileURLWithPath: modelsLink).standardizedFileURL.path == src.modelsDir.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: copy.modelsDir.appendingPathComponent("big.bin").path))
    }

    @Test("writing into the copy leaves the source untouched")
    func writesStayInCopy() throws {
        let src = try makeSource()
        defer { try? FileManager.default.removeItem(at: src.root) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("iris-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let copy = try IrisPaths.makeVolatileCopy(of: src, at: dest)
        try "profile-after".write(to: copy.userMd, atomically: true, encoding: .utf8)
        try "fact".write(to: copy.factStoreDB, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: src.userMd, encoding: .utf8) == "profile-before")
        #expect(!FileManager.default.fileExists(atPath: src.factStoreDB.path))
    }

    @Test("a memory fingerprint is stable across reads and changes on a write")
    func fingerprint() throws {
        let src = try makeSource()
        defer { try? FileManager.default.removeItem(at: src.root) }
        let a = IrisPaths.fingerprint(of: src.memoryDir)
        _ = try String(contentsOf: src.userMd, encoding: .utf8)
        let b = IrisPaths.fingerprint(of: src.memoryDir)
        #expect(a == b)
        try "changed".write(to: src.userMd, atomically: true, encoding: .utf8)
        #expect(IrisPaths.fingerprint(of: src.memoryDir) != a)
        try "new".write(to: src.memoryDir.appendingPathComponent("extra.md"), atomically: true, encoding: .utf8)
        #expect(IrisPaths.fingerprint(of: src.memoryDir) != b)
    }

    /// #304. This used to assert the opposite — that the test process resolves the real home —
    /// which is what let `SubagentManagerTests` write an allow rule into the developer's real
    /// `permissions.json` on every run (#290). `standard` is still the real home, because the
    /// isolation tests compare file existence there.
    @Test("under test the default home is a per-process temp root, and standard is still the real one")
    func defaultIsNotTheRealHomeUnderTest() {
        #expect(!IrisPaths.isVolatileCopy)
        #expect(IrisPaths.standard.root.path == ("~/.iris" as NSString).expandingTildeInPath)
        #expect(IrisPaths.default.root.path != IrisPaths.standard.root.path)
        #expect(IrisPaths.default.root.lastPathComponent == "iris-tests-home-\(ProcessInfo.processInfo.processIdentifier)")
        #expect(FileManager.default.fileExists(atPath: IrisPaths.default.configDir.path),
                "the test home has the real layout, so a manager's first write does not fail on a missing directory")
    }

    /// The sweep takes homes whose process is gone and nothing else: not a live run's, not this
    /// process's, and not an unrelated directory that shares the prefix.
    @Test("stale test homes are the dead pids' only")
    func staleTestHomes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-304-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = ProcessInfo.processInfo.processIdentifier
        for name in ["iris-tests-home-111", "iris-tests-home-222", "iris-tests-home-\(me)",
                     "iris-tests-home-notapid", "iris-tests-other-333"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let stale = IrisPaths.staleTestHomes(in: dir, isAlive: { $0 == 222 }).map(\.lastPathComponent)
        #expect(stale == ["iris-tests-home-111"])
    }

    /// `kill(0, 0)` probes our own process group and a negative pid probes a group: neither is a
    /// process that could own a test file, so neither may read as alive forever.
    @Test("a pid of zero or below is never alive")
    func nonPositivePidsAreNotAlive() {
        #expect(!IrisDefaults.isProcessAlive(0))
        #expect(!IrisDefaults.isProcessAlive(-1))
        #expect(IrisDefaults.isProcessAlive(ProcessInfo.processInfo.processIdentifier))
    }
}
