import Testing
import Foundation
@testable import IrisKit

@Suite("IrisMigrator Tests")
struct IrisMigratorTests {

    /// Fresh temp root with an optional old-flat-layout seed.
    private func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-migrate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ url: URL, _ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test("fresh install: creates buckets, moves nothing")
    func testFreshInstall() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        IrisMigrator.migrate(p)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: p.memoryDir.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: p.configDir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test("old flat layout: files land at new paths")
    func testMovesOldLayout() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        write(root.appendingPathComponent("USER.md"), "user")
        write(root.appendingPathComponent("memory.md"), "mem")
        write(root.appendingPathComponent("skills/a/SKILL.md"), "skill")
        write(root.appendingPathComponent("library/proj/specs/x.md"), "spec")
        write(root.appendingPathComponent("settings.json"), "{}")
        write(root.appendingPathComponent("permissions.json"), "[]")
        write(root.appendingPathComponent("mcp_servers.json"), "{}")
        write(root.appendingPathComponent("prompts/SOUL.md"), "canonical-soul")

        IrisMigrator.migrate(p)

        #expect(read(p.userMd) == "user")
        #expect(read(p.memoryMd) == "mem")
        #expect(read(p.skillsDir.appendingPathComponent("a/SKILL.md")) == "skill")
        #expect(read(p.artifactsDir.appendingPathComponent("proj/specs/x.md")) == "spec")
        #expect(read(p.settingsJSON) == "{}")
        #expect(read(p.permissionsJSON) == "[]")
        #expect(read(p.mcpServersJSON) == "{}")
        #expect(read(p.soulMd) == "canonical-soul")
        // old locations gone
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("USER.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("prompts/SOUL.md").path))
    }

    @Test("SOUL dedup: read-copy is canonical, stray root SOUL.md deleted")
    func testSoulDedup() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        write(root.appendingPathComponent("prompts/SOUL.md"), "canonical")
        write(root.appendingPathComponent("SOUL.md"), "stray-newer")
        IrisMigrator.migrate(p)
        #expect(read(p.soulMd) == "canonical")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SOUL.md").path))
    }

    @Test("idempotent + non-destructive: re-run does not overwrite migrated files")
    func testIdempotentNonDestructive() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        write(p.userMd, "already-migrated")           // destination already exists
        write(root.appendingPathComponent("USER.md"), "old-flat")  // stale source lingering
        IrisMigrator.migrate(p)
        #expect(read(p.userMd) == "already-migrated")  // NOT overwritten
        IrisMigrator.migrate(p)                        // second run is a no-op
        #expect(read(p.userMd) == "already-migrated")
    }

    @Test("directory merge into pre-created destination that already has a different file")
    func testDirectoryMergeIntoPreCreatedDest() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        // Pre-create destination (simulating ensureDirectories) with an existing file.
        write(p.skillsDir.appendingPathComponent("keep.md"), "kept")
        // Old skills/ source has a different file.
        write(root.appendingPathComponent("skills/new.md"), "new")
        IrisMigrator.migrate(p)
        // Both files must exist under skillsDir.
        #expect(read(p.skillsDir.appendingPathComponent("keep.md")) == "kept")
        #expect(read(p.skillsDir.appendingPathComponent("new.md")) == "new")
        // Old source directory must be gone (fully drained).
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("skills").path))
    }

    @Test("non-destructive collision: destination file wins, source item left behind")
    func testNonDestructiveCollision() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        // Destination already has dup.md.
        write(p.skillsDir.appendingPathComponent("dup.md"), "dest")
        // Old skills/ has a same-named file with different content.
        write(root.appendingPathComponent("skills/dup.md"), "src")
        IrisMigrator.migrate(p)
        // Destination must NOT be overwritten.
        #expect(read(p.skillsDir.appendingPathComponent("dup.md")) == "dest")
        // Source item must still exist (collision left it behind).
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/dup.md").path))
    }

    @Test("re-run idempotency for directories: second migrate call is a no-op")
    func testReRunIdempotencyForDirectories() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        write(root.appendingPathComponent("skills/a.md"), "alpha")
        // First run.
        IrisMigrator.migrate(p)
        #expect(read(p.skillsDir.appendingPathComponent("a.md")) == "alpha")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("skills").path))
        // Second run — source is gone, destination untouched.
        IrisMigrator.migrate(p)
        #expect(read(p.skillsDir.appendingPathComponent("a.md")) == "alpha")
    }

    @Test("holographic DB moves with its WAL sidecars")
    func testHolographicSidecars() {
        let root = makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        write(root.appendingPathComponent("holographic_memory.sqlite"), "db")
        write(root.appendingPathComponent("holographic_memory.sqlite-shm"), "shm")
        write(root.appendingPathComponent("holographic_memory.sqlite-wal"), "wal")
        IrisMigrator.migrate(p)
        #expect(read(p.holographicDB) == "db")
        #expect(read(p.memoryDir.appendingPathComponent("holographic_memory.sqlite-shm")) == "shm")
        #expect(read(p.memoryDir.appendingPathComponent("holographic_memory.sqlite-wal")) == "wal")
    }
}
