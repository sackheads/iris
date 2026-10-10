import Testing
import Foundation
@testable import IrisKit

@Suite("GitHead")
struct GitHeadTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("githead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ s: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a plain repo: its directory name and branch")
    func plainRepo() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("iris")
        try write("ref: refs/heads/main\n", root.appendingPathComponent(".git/HEAD"))
        #expect(GitHead.read(workspace: root.path) == GitProject(repo: "iris", branch: "main"))
    }

    @Test("a subdirectory of a repo resolves to the repo")
    func subdirectory() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("iris")
        try write("ref: refs/heads/feat/x\n", root.appendingPathComponent(".git/HEAD"))
        let sub = root.appendingPathComponent("Sources/IrisKit")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(GitHead.read(workspace: sub.path) == GitProject(repo: "iris", branch: "feat/x"))
    }

    @Test("a worktree: the main repo's name and the worktree's branch")
    func worktree() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("iris")
        let wtGit = main.appendingPathComponent(".git/worktrees/iris-469")
        try write("ref: refs/heads/docs/469\n", wtGit.appendingPathComponent("HEAD"))
        let wt = base.appendingPathComponent("iris-469")
        try write("gitdir: \(wtGit.path)\n", wt.appendingPathComponent(".git"))
        #expect(GitHead.read(workspace: wt.path) == GitProject(repo: "iris", branch: "docs/469"))
    }

    @Test("a worktree with relative gitdir path")
    func worktreeRelativePath() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("iris")
        let wtGit = main.appendingPathComponent(".git/worktrees/iris-469")
        try write("ref: refs/heads/feat/relative\n", wtGit.appendingPathComponent("HEAD"))
        let wt = base.appendingPathComponent("iris-469")
        try write("gitdir: ../iris/.git/worktrees/iris-469\n", wt.appendingPathComponent(".git"))
        #expect(GitHead.read(workspace: wt.path) == GitProject(repo: "iris", branch: "feat/relative"))
    }

    @Test("a detached HEAD shows the short sha")
    func detached() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("r")
        try write("0123456789abcdef0123456789abcdef01234567\n", root.appendingPathComponent(".git/HEAD"))
        #expect(GitHead.read(workspace: root.path) == GitProject(repo: "r", branch: "detached@0123456"))
    }

    @Test("no repo is nil")
    func noRepo() throws {
        let base = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        #expect(GitHead.read(workspace: base.path) == nil)
    }
}
