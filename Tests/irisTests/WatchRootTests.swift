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
        for root in WatchRoot.tooBroad + [f.home, "/Volumes/Data", "/private/var"] {
            #expect(WatchRoot.refusal(for: root, paths: f.paths, home: f.home) == WatchRoot.tooBroadRefusal,
                    "\(root) should be too broad")
        }
        // Being under a broad root is not the same as being one: a folder in /private/tmp is fine.
        #expect(WatchRoot.refusal(for: "/private/tmp/notes", paths: f.paths, home: f.home) == nil)
        // Case is not a way round the list.
        #expect(WatchRoot.refusal(for: "/SYSTEM", paths: f.paths, home: f.home) == WatchRoot.tooBroadRefusal)
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
