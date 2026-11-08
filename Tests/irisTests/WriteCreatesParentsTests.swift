import Testing
import Foundation
@testable import IrisKit

/// #954: `write_file` makes the directories a new nested path needs, on all three write paths
/// (attended `StagedFileWrite`, the granted walk, the approved-path walk), and the walks make none
/// outside their root. Temp directories only; every "outside" is a sibling the test checks stayed empty.
@Suite("write_file creates missing parent directories (#954)", .timeLimit(.minutes(1)))
struct WriteCreatesParentsTests {
    struct Tree {
        let base: URL; let root: URL; let outside: URL
        func tearDown() { try? FileManager.default.removeItem(at: base) }
        func names(_ dir: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? [] }
        func text(_ rel: String) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
    }

    /// The kernel's own spelling (`/private/var/...`): an approved path is a real path, and
    /// `URL.resolvingSymlinksInPath` strips the `/private` the walk then finds a link under.
    private func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func tree() throws -> Tree {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iris-mkparents-\(UUID().uuidString)")
        let root = base.appendingPathComponent("mount"), outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        return Tree(base: base, root: root, outside: outside)
    }

    // MARK: attended write

    @Test("an attended write to a new nested path creates the directories and the file")
    func attendedCreatesParents() throws {
        let t = try tree(); defer { t.tearDown() }
        let path = t.root.appendingPathComponent("artifacts/proj/reviews/x.md").path
        try StagedFileWrite.write("hello", to: path, shouldCommit: { true })
        #expect(t.text("artifacts/proj/reviews/x.md") == "hello")
        #expect(t.names(t.root.appendingPathComponent("artifacts/proj/reviews")) == ["x.md"], "no staging file left")
    }

    @Test("an attended write that does not commit takes back the directories it made, and keeps ones that were there")
    func attendedCancelledRemovesWhatItMade() throws {
        let t = try tree(); defer { t.tearDown() }
        try FileManager.default.createDirectory(at: t.root.appendingPathComponent("keep"), withIntermediateDirectories: true)
        #expect(throws: CancellationError.self) {
            try StagedFileWrite.write("x", to: t.root.appendingPathComponent("keep/a/b/x.md").path, shouldCommit: { false })
        }
        #expect(t.names(t.root) == ["keep"])
        #expect(t.names(t.root.appendingPathComponent("keep")).isEmpty)
    }

    @Test("an attended write under a file fails and leaves no directory behind")
    func attendedFileInTheWay() throws {
        let t = try tree(); defer { t.tearDown() }
        try "f".write(to: t.root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try StagedFileWrite.write("x", to: t.root.appendingPathComponent("file/sub/x.md").path, shouldCommit: { true })
        }
        #expect(t.names(t.root) == ["file"])
    }

    // MARK: granted walk

    @Test("a granted write to a new nested path creates the directories inside the root")
    func grantedCreatesParents() throws {
        let t = try tree(); defer { t.tearDown() }
        try GrantedFileAccess(root: t.root.path).write(relative: ["artifacts", "proj", "reviews", "x.md"], content: "hi")
        #expect(t.text("artifacts/proj/reviews/x.md") == "hi")
        #expect(t.names(t.root.appendingPathComponent("artifacts/proj/reviews")) == ["x.md"])
    }

    @Test("a granted write cannot make a directory outside the root: `..` is refused, nothing is created anywhere")
    func grantedDotDotRefused() throws {
        let t = try tree(); defer { t.tearDown() }
        #expect(throws: GrantedFileError.badComponent("..")) {
            try GrantedFileAccess(root: t.root.path).write(relative: ["new", "..", "..", "outside", "made", "x.md"], content: "leak")
        }
        #expect(t.names(t.outside).isEmpty)
        #expect(t.names(t.root).isEmpty, "the refusal comes before any directory is made")
    }

    @Test("a link inside the root that points outside is not followed to make directories there")
    func grantedSymlinkNotFollowed() throws {
        let t = try tree(); defer { t.tearDown() }
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("link"), withDestinationURL: t.outside)
        #expect(throws: GrantedFileError.symlink(component: "link")) {
            try GrantedFileAccess(root: t.root.path).write(relative: ["link", "made", "x.md"], content: "leak")
        }
        #expect(t.names(t.outside).isEmpty)
    }

    @Test("a dangling link in the path is refused, and nothing is made through it")
    func grantedDanglingLinkNotFollowed() throws {
        let t = try tree(); defer { t.tearDown() }
        let target = t.outside.appendingPathComponent("not-yet")
        try FileManager.default.createSymbolicLink(at: t.root.appendingPathComponent("dangling"), withDestinationURL: target)
        #expect(throws: GrantedFileError.symlink(component: "dangling")) {
            try GrantedFileAccess(root: t.root.path).write(relative: ["dangling", "x.md"], content: "leak")
        }
        #expect(t.names(t.outside).isEmpty)
    }

    @Test("a granted root that is gone is refused, not recreated")
    func grantedRootGone() throws {
        let t = try tree(); defer { t.tearDown() }
        let gone = t.base.appendingPathComponent("vanished")
        #expect(throws: (any Error).self) {
            try GrantedFileAccess(root: gone.path).write(relative: ["a", "x.md"], content: "x")
        }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test("a granted write that does not commit takes back the directories it made")
    func grantedCancelledRemovesWhatItMade() throws {
        let t = try tree(); defer { t.tearDown() }
        try FileManager.default.createDirectory(at: t.root.appendingPathComponent("keep"), withIntermediateDirectories: true)
        #expect(throws: GrantedFileError.cancelled) {
            try GrantedFileAccess(root: t.root.path).write(relative: ["keep", "a", "b", "x.md"], content: "x", shouldCommit: { false })
        }
        #expect(t.names(t.root) == ["keep"])
        #expect(t.names(t.root.appendingPathComponent("keep")).isEmpty)
    }

    @Test("a file where a directory is needed is the usual refusal, and nothing is made")
    func grantedFileInTheWay() throws {
        let t = try tree(); defer { t.tearDown() }
        try "f".write(to: t.root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        #expect(throws: GrantedFileError.notADirectory(component: "file")) {
            try GrantedFileAccess(root: t.root.path).write(relative: ["file", "sub", "x.md"], content: "x")
        }
        #expect(t.names(t.root) == ["file"])
    }

    // MARK: approved-path walk, through the executor

    @Test("an approved-path write creates the directories along the decided path")
    func decidedCreatesParents() async throws {
        let t = try tree(); defer { t.tearDown() }
        let decided = realPath(t.root) + "/a/b/x.md"
        let result = await ToolExecutor().writeFile(decided: decided, content: "ok")
        #expect(result == "Successfully wrote to \(decided)", Comment(rawValue: result))
        #expect(t.text("a/b/x.md") == "ok")
    }

    @Test("an approved-path write through a link swapped in after the approval makes nothing outside")
    func decidedSwappedLinkNotFollowed() async throws {
        let t = try tree(); defer { t.tearDown() }
        let realRoot = realPath(t.root)
        try FileManager.default.createSymbolicLink(atPath: realRoot + "/swapped", withDestinationPath: t.outside.path)
        let result = await ToolExecutor().writeFile(decided: realRoot + "/swapped/new/x.md", content: "leak")
        #expect(result.hasPrefix("Error writing file:"), Comment(rawValue: result))
        #expect(t.names(t.outside).isEmpty)
    }
}
