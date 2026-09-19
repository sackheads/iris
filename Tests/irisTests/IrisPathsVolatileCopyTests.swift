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

    @Test("the test process never runs on a volatile copy and resolves the real home")
    func notVolatileUnderTest() {
        #expect(!IrisPaths.isVolatileCopy)
        #expect(IrisPaths.default.root.path == ("~/.iris" as NSString).expandingTildeInPath)
    }
}
