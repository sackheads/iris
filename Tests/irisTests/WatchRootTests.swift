import Testing
import Foundation
@testable import iris

/// The roots a watch is turned down on (#187 deliverable 4, spec §5). A volatile `IrisPaths` root
/// and an injected home: nothing here reads or writes `~/.iris`.
@Suite("WatchRoot refusals")
struct WatchRootTests {
    private func fixture() throws -> (paths: IrisPaths, home: String, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-watchroot-\(UUID().uuidString)")
        let irisRoot = base.appendingPathComponent("dot-iris")
        try FileManager.default.createDirectory(at: irisRoot.appendingPathComponent("config"),
                                                withIntermediateDirectories: true)
        return (IrisPaths(root: irisRoot), base.appendingPathComponent("home").path, base)
    }

    @Test("the listed roots, the home directory, a volume root and a resolved alias are too broad")
    func tooBroadRootsAreRefused() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        // `/System/Volumes/Data` is the data volume on every supported macOS: it is a mount point
        // Foundation leaves unchanged, and it is the real container of `~/.iris`.
        for root in WatchRoot.tooBroad + [f.home, "/Volumes/Data", "/private/var", "/System/Volumes/Data"] {
            #expect(WatchRoot.refusal(for: root, paths: f.paths, home: f.home) == WatchRoot.tooBroadRefusal,
                    "\(root) should be too broad")
        }
        // Being under a broad root is not the same as being one: a folder in /private/tmp is fine.
        #expect(WatchRoot.refusal(for: "/private/tmp/notes", paths: f.paths, home: f.home) == nil)
        // Case is not a way round the list.
        #expect(WatchRoot.refusal(for: "/SYSTEM", paths: f.paths, home: f.home) == WatchRoot.tooBroadRefusal)
    }

    /// The mount-point rule is the file system's answer, not a spelling: the same temp directory
    /// is refused when it is a mount and allowed when it is not. The lexical `/Volumes/<name>`
    /// rule stays alongside it for a volume that is not mounted and cannot be asked.
    @Test("a mount point anywhere is too broad; the same path unmounted is a folder like any other")
    func mountPointsAreRefusedWhereverTheyAreMounted() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let share = f.base.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let canonical = IrisPaths.canonicalPath(share.path).lowercased()
        #expect(WatchRoot.refusal(for: share.path, paths: f.paths, home: f.home,
                                  isVolume: { $0 == canonical }) == WatchRoot.tooBroadRefusal)
        #expect(WatchRoot.refusal(for: share.path, paths: f.paths, home: f.home,
                                  isVolume: { _ in false }) == nil)
        // An unmounted volume is judged by its spelling, whatever the file system says.
        #expect(WatchRoot.refusal(for: "/Volumes/NotMounted", paths: f.paths, home: f.home,
                                  isVolume: { _ in false }) == WatchRoot.tooBroadRefusal)
        // And the real answer for the real paths.
        #expect(WatchRoot.isMountPoint("/"))
        #expect(WatchRoot.isMountPoint("/System/Volumes/Data"))
        #expect(!WatchRoot.isMountPoint(share.path))
        #expect(!WatchRoot.isMountPoint(f.base.appendingPathComponent("absent").path))
    }

    /// `IrisPaths.isUnderProtectedWriteDir` covers only the "is under" direction; a watch root
    /// that *contains* Iris's directory would see every memory write too, so both directions
    /// are refused here.
    @Test("a root that is, is under, or contains Iris's own directory is refused")
    func protectedRootsInBothDirections() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let refused = [
            f.paths.configDir.path,
            f.paths.configDir.appendingPathComponent("child").path,
            f.paths.pluginsDir.path,
            f.paths.memoryDir.path,
            f.paths.root.path,
            f.base.path,   // contains the Iris root
        ]
        for root in refused {
            #expect(WatchRoot.refusal(for: root, paths: f.paths, home: f.home) == WatchRoot.protectedRefusal,
                    "\(root) should be protected")
        }
        #expect(WatchRoot.refusal(for: f.home + "/Notes", paths: f.paths, home: f.home) == nil)
        #expect(WatchRoot.refusal(for: f.base.appendingPathComponent("sibling").path,
                                  paths: f.paths, home: f.home) == nil)
    }
}
