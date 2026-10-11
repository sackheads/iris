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

    @Test("an oversized HEAD (over 4KB, not a valid ref or sha) yields no branch, without reading past the cap")
    func oversizedHeadGarbage() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("r")
        // Non-hex so a read that (incorrectly) ran past the 4 KB cap could not accidentally land
        // on a valid-looking detached-HEAD prefix either.
        let garbage = String(repeating: "not-a-ref-or-sha-", count: 500)
        #expect(garbage.utf8.count > 4096)
        try write(garbage, root.appendingPathComponent(".git/HEAD"))
        #expect(GitHead.read(workspace: root.path) == GitProject(repo: "r", branch: nil))
    }

    @Test("a symlinked .git (to a directory) is skipped, not followed")
    func symlinkedGitDirectoryIsSkipped() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real-git-dir")
        try write("ref: refs/heads/main\n", real.appendingPathComponent("HEAD"))
        let root = base.appendingPathComponent("r")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git"), withDestinationURL: real)
        #expect(GitHead.read(workspace: root.path) == nil)
    }

    @Test("a symlinked .git (to a file) is skipped, not followed")
    func symlinkedGitFileIsSkipped() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let realFile = base.appendingPathComponent("real-dotgit-file")
        try write("gitdir: /nonexistent\n", realFile)
        let root = base.appendingPathComponent("r")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".git"), withDestinationURL: realFile)
        #expect(GitHead.read(workspace: root.path) == nil)
    }

    /// A symlinked `.git` is a dead end, not a reason to keep walking up: an outer directory that
    /// happens to BE a real repo must not get credited to a workspace whose own `.git` is a
    /// symlink. Walking past it would misreport the OUTER repo as this workspace's project rather
    /// than correctly reporting that this workspace has none.
    @Test("a symlinked .git does not fall through to a real repo further up")
    func symlinkedGitStopsTheWalkEvenUnderARealRepo() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // The outer directory IS a repo.
        try write("ref: refs/heads/outer\n", base.appendingPathComponent(".git/HEAD"))
        let realGitDir = base.appendingPathComponent("elsewhere-git-dir")
        try write("ref: refs/heads/inner\n", realGitDir.appendingPathComponent("HEAD"))
        let workspace = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent(".git"), withDestinationURL: realGitDir)
        #expect(GitHead.read(workspace: workspace.path) == nil)
    }

    /// Pins the 4 KB read cap against the exact shape #480 review item 3 was worried about: a
    /// `HEAD` that starts with a valid ref prefix but keeps going well past the cap. The read
    /// must never hand back anywhere near the full 5,000-character branch name.
    @Test("a HEAD far longer than 4KB never yields its full branch name")
    func headLongerThanCapIsBounded() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("r")
        let longBranch = String(repeating: "a", count: 5_000)
        try write("ref: refs/heads/" + longBranch, root.appendingPathComponent(".git/HEAD"))
        let project = GitHead.read(workspace: root.path)
        #expect(project?.repo == "r")
        let branchLength = project?.branch?.count ?? 0
        #expect(branchLength < 4_096, "branch length \(branchLength) must be bounded well under the 5,000-char input")
    }

    /// #480 review item 6: a submodule's `gitdir:` line points into the SUPERPROJECT's
    /// `.git/modules/<name>`, so naming the repo from that path's own component (as the worktree
    /// case does) mislabels it with the superproject's directory name. It must be named after the
    /// submodule's own checkout directory instead.
    @Test("a submodule is named after itself, not the superproject")
    func submoduleNamedAfterItself() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let superproject = base.appendingPathComponent("super")
        let moduleGitDir = superproject.appendingPathComponent(".git/modules/sub")
        try write("ref: refs/heads/sub-branch\n", moduleGitDir.appendingPathComponent("HEAD"))
        let subWorkspace = superproject.appendingPathComponent("vendor/sub")
        try write("gitdir: \(moduleGitDir.path)\n", subWorkspace.appendingPathComponent(".git"))
        #expect(GitHead.read(workspace: subWorkspace.path) == GitProject(repo: "sub", branch: "sub-branch"))
    }

    @Test("no repo is nil")
    func noRepo() throws {
        let base = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: base)
        }
        #expect(GitHead.read(workspace: base.path) == nil)
    }

    @Test("a dotfiles repo at home does not claim a workspace below it")
    func homeBoundary() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("ref: refs/heads/main\n", home.appendingPathComponent(".git/HEAD"))
        let sub = home.appendingPathComponent("src/project")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(GitHead.read(workspace: sub.path, homeDirectory: home) == nil)
    }

    @Test("a workspace that IS home still reads its own repo")
    func homeItself() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("ref: refs/heads/main\n", home.appendingPathComponent(".git/HEAD"))
        #expect(GitHead.read(workspace: home.path, homeDirectory: home)
                == GitProject(repo: home.lastPathComponent, branch: "main"))
    }
}
