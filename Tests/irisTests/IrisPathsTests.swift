import Testing
import Foundation
@testable import iris

@Suite("IrisPaths Tests")
struct IrisPathsTests {

    @Test("accessors compose paths under the injected root")
    func testAccessorsComposeUnderRoot() {
        let root = URL(fileURLWithPath: "/tmp/iris-test-root")
        let p = IrisPaths(root: root)
        #expect(p.memoryDir.path == "/tmp/iris-test-root/memory")
        #expect(p.soulMd.path == "/tmp/iris-test-root/memory/SOUL.md")
        #expect(p.userMd.path == "/tmp/iris-test-root/memory/USER.md")
        #expect(p.memoryMd.path == "/tmp/iris-test-root/memory/memory.md")
        #expect(p.skillsDir.path == "/tmp/iris-test-root/memory/skills")
        #expect(p.artifactsDir.path == "/tmp/iris-test-root/memory/artifacts")
        #expect(p.libraryDir.path == "/tmp/iris-test-root/memory/library")
        #expect(p.holographicDB.path == "/tmp/iris-test-root/memory/holographic_memory.sqlite")
        #expect(p.configDir.path == "/tmp/iris-test-root/config")
        #expect(p.settingsJSON.path == "/tmp/iris-test-root/config/settings.json")
        #expect(p.permissionsJSON.path == "/tmp/iris-test-root/config/permissions.json")
        #expect(p.mcpServersJSON.path == "/tmp/iris-test-root/config/mcp_servers.json")
        #expect(p.modelsDir.path == "/tmp/iris-test-root/models")
    }

    @Test("isUnderMemory: true for first-party memory paths, false for escapes/outside")
    func testIsUnderMemory() {
        let p = IrisPaths(root: URL(fileURLWithPath: "/tmp/iris-x"))
        // inside memory/
        #expect(p.isUnderMemory("/tmp/iris-x/memory/library/note.md"))
        #expect(p.isUnderMemory("/tmp/iris-x/memory/SOUL.md"))
        #expect(p.isUnderMemory("/tmp/iris-x/memory"))
        // `..` traversal that escapes memory/ must NOT be trusted
        #expect(!p.isUnderMemory("/tmp/iris-x/memory/../models/secret"))
        #expect(!p.isUnderMemory("/tmp/iris-x/memory/../../etc/passwd"))
        // outside memory/
        #expect(!p.isUnderMemory("/tmp/iris-x/models/m.gguf"))
        #expect(!p.isUnderMemory("/tmp/iris-x/config/settings.json"))
        // sibling with shared prefix must not match
        #expect(!p.isUnderMemory("/tmp/iris-x/memory-evil/x"))
        // relative paths are not trusted
        #expect(!p.isUnderMemory("note.md"))
    }

    @Test("isUnderIrisDir: true for paths inside root, false for escapes/outside")
    func testIsUnderIrisDir() {
        let p = IrisPaths(root: URL(fileURLWithPath: "/tmp/iris-x"))
        #expect(p.isUnderIrisDir("/tmp/iris-x/memory/library/note.md"))
        #expect(p.isUnderIrisDir("/tmp/iris-x/config/settings.json"))
        #expect(p.isUnderIrisDir("/tmp/iris-x/models/m.gguf"))
        #expect(p.isUnderIrisDir("/tmp/iris-x"))
        // traversal that escapes root
        #expect(!p.isUnderIrisDir("/tmp/iris-x/../etc/passwd"))
        // outside root
        #expect(!p.isUnderIrisDir("/tmp/other/file"))
        // sibling with shared prefix
        #expect(!p.isUnderIrisDir("/tmp/iris-x-evil/file"))
    }


    @Test("ensureDirectories creates the bucket directories")
    func testEnsureDirectoriesCreatesBuckets() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-ensure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let p = IrisPaths(root: root)
        try p.ensureDirectories()
        for dir in [p.memoryDir, p.skillsDir, p.artifactsDir, p.libraryDir, p.configDir, p.modelsDir] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    /// A temp tree: mount/ with mount/link → iris/ (a fake ~/.iris holding config/), and mount/proj/.
    private func linkTree() throws -> (base: URL, mount: URL, iris: URL, link: URL) {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-realpath-\(UUID().uuidString)")
        let mount = base.appendingPathComponent("mount"), iris = base.appendingPathComponent("iris")
        try fm.createDirectory(at: mount.appendingPathComponent("proj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: iris.appendingPathComponent("config"), withIntermediateDirectories: true)
        let link = mount.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: iris)
        return (base, mount, iris, link)
    }

    private func real(_ url: URL) -> String {
        let p = realpath(url.path, nil)!; defer { free(p) }; return String(cString: p)
    }

    @Test("realPath follows a symlink before the .. that follows it, as the kernel does (§0.9)")
    func realPathIsComponentWise() throws {
        let t = try linkTree(); defer { try? FileManager.default.removeItem(at: t.base) }
        // canonicalPath collapses lexically and lands inside the mount; realPath lands where the write would.
        // `x` must NOT exist (§0.9, measured): when the final component exists, `standardizedFileURL`
        // resolves the link first and agrees with the kernel, so an existing-file case would pass
        // against the unfixed code. The new-file case is exactly `write_file`'s.
        #expect(!FileManager.default.fileExists(atPath: t.link.path + "/../x"))
        #expect(IrisPaths.canonicalPath(t.link.path + "/../x") == IrisPaths.canonicalPath(t.mount.path) + "/x")
        #expect(IrisPaths.realPath(t.link.path + "/../x") == real(t.base) + "/x")
        #expect(IrisPaths.realPath(t.link.path + "/config/permissions.json") == real(t.iris) + "/config/permissions.json")
        // A missing tail is appended; a `..` inside the missing tail pops lexically.
        #expect(IrisPaths.realPath(t.mount.path + "/proj/new/dir/f") == real(t.mount) + "/proj/new/dir/f")
        #expect(IrisPaths.realPath(t.mount.path + "/proj/new/../f") == real(t.mount) + "/proj/f")
        // /private is the real spelling of /tmp; both sides of every comparison go through here.
        #expect(IrisPaths.realPath("/tmp/x").hasPrefix("/private/tmp/"))
    }

    @Test("realPathForAllow refuses .. and relative paths, and otherwise equals realPath")
    func realPathForAllowRefuses() throws {
        let t = try linkTree(); defer { try? FileManager.default.removeItem(at: t.base) }
        #expect(IrisPaths.realPathForAllow(t.link.path + "/../x") == nil)
        #expect(IrisPaths.realPathForAllow(t.mount.path + "/proj/../proj/f") == nil, "any .., not only one after a link")
        #expect(IrisPaths.realPathForAllow("relative/f") == nil)
        #expect(IrisPaths.realPathForAllow("~/../x") == nil)
        #expect(IrisPaths.realPathForAllow(t.link.path + "/config/x") == IrisPaths.realPath(t.link.path + "/config/x"))
        #expect(IrisPaths.realPathForAllow(t.mount.path + "/proj/./f") == real(t.mount) + "/proj/f", "a . is not a ..")
    }

    @Test("realPathForAllow is nil when the deepest existing entry will not resolve; realPath still answers the deny side")
    func realPathForAllowFailsClosedOnAnUnresolvableEntry() throws {
        let t = try linkTree(); defer { try? FileManager.default.removeItem(at: t.base) }
        // A loop (ELOOP) and a dangling link (ENOENT): `stat` says neither is there, `lstat` says both
        // are, and `realpath(3)` fails on each. The allow side must not paper over that by stepping
        // back to the parent and appending the link's name as if it were a plain missing directory.
        let loop = t.mount.appendingPathComponent("loop"), dangle = t.mount.appendingPathComponent("dangle")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")
        try FileManager.default.createSymbolicLink(atPath: dangle.path, withDestinationPath: "nowhere")
        #expect(IrisPaths.realPathForAllow(loop.path + "/x") == nil)
        #expect(IrisPaths.realPathForAllow(loop.path) == nil)
        #expect(IrisPaths.realPathForAllow(dangle.path) == nil, "a dangling final link is the one case open(O_CREAT) would follow")
        // The deny side keeps a lexical answer, resolved as far as the parent, so R10 can still say no.
        #expect(IrisPaths.realPath(loop.path + "/x") == real(t.mount) + "/loop/x")
        #expect(IrisPaths.realPath(dangle.path) == real(t.mount) + "/dangle")
    }

    @Test("canonicalPath expands a tilde without PATH_MAX truncation (#275, third site)")
    func canonicalPathDoesNotTruncateATilde() {
        // The same pin `WatchMigrationTests` keeps for `WatchRoot.canonical`: `expandingTildeInPath`
        // hands back a plausible, truncated path past PATH_MAX; `IrisEngine.expandTilde` keeps every byte.
        let overLong = "~/" + String(repeating: "a", count: 2_000)
        #expect(IrisPaths.canonicalPath(overLong).utf8.count > 2_000, "the tilde expansion must not truncate")
        #expect(IrisPaths.canonicalPath("~/x") == IrisPaths.canonicalPath(NSHomeDirectory() + "/x"), "and an ordinary tilde still expands")
    }

    @Test("isUnderProtectedWriteDir sees through link/.. and through the link itself (R10 hardened)")
    func protectedWriteDirSeesThroughLinks() throws {
        let t = try linkTree(); defer { try? FileManager.default.removeItem(at: t.base) }
        let paths = IrisPaths(root: t.iris)
        #expect(paths.isUnderProtectedWriteDir(t.link.path + "/config/permissions.json"))
        #expect(paths.isUnderProtectedWriteDir(t.link.path + "/../iris/config/permissions.json"),
                "the reproduced escape: lexically inside the mount, really inside config")
        #expect(!paths.isUnderProtectedWriteDir(t.mount.path + "/proj/permissions.json"))
        #expect(paths.isUnderProtectedWriteDir(t.iris.path.uppercased() + "/config/x") == paths.isUnderProtectedWriteDir(t.iris.path + "/config/x"),
                "still case-insensitive on the deny side")
    }
}
