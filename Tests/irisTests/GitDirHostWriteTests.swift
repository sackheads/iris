import Testing
import Foundation
@testable import IrisKit

/// #867: a granted job's `write_file` runs on the host, where a write into a `.git` (hooks, the config
/// git runs programs from) is the next `git` command's code. Every case hands the gate the dispatcher's
/// "yes" for the mount (`grantedMount:`), so the refusal under test can only be this rule's, never the
/// grant's or the executor's walk.
@MainActor
@Suite("A granted job's host writes into a .git (#867)", .timeLimit(.minutes(1)))
struct GitDirHostWriteTests {
    private typealias Tree = JobGrantAllowsTests.Tree
    private func c(_ url: URL, _ tail: String = "") -> String { JobGrantAllowsTests.c(url, tail) }

    private func background(_ t: Tree) -> (AppState, UUID) {
        let app = AppState()
        app.permissions = PermissionManager(paths: IrisPaths(root: t.home.appendingPathComponent(".iris")))
        let cid = app.createNewConversation(isBackground: true, select: false)
        app.setWorkspace(for: cid, path: c(t.proj))
        app.setSandboxGrant(for: cid, t.grant)
        return (app, cid)
    }

    /// The gate's answer for a `write_file` the grant already said yes to.
    private func write(_ path: String, _ t: Tree, _ app: AppState, _ cid: UUID) async -> Bool {
        await app.requestApproval(toolName: "write_file", details: path, args: ["path": .string(path)],
                                  workspace: c(t.proj), conversationId: cid, grantedMount: t.grant.mounts[0])
    }

    @Test("each .git target is refused unattended, as a person's alone, though the grant covers it")
    func gitTargetsAreRefused() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        for rel in [".git/config", ".git/config.worktree", ".git/hooks/pre-commit", ".git/info/exclude", ".git/info/attributes", ".git/HEAD"] {
            let target = c(t.proj, rel)
            #expect(t.grant.allowedMount(toolName: "write_file", details: target, cwd: nil) != nil, "the grant says yes to \(rel); the refusal has to be this rule's")
            #expect(await !write(target, t, app, cid), Comment(rawValue: rel))
            let denial = try #require(app.takeBackgroundDenials(for: cid).first, Comment(rawValue: rel))
            #expect(denial.toolName == "write_file" && denial.reason == .approval && denial.grantNearest == nil,
                    "refused as an approval a person must give, not as 'outside the grant': \(rel)")
        }
        #expect(app.conversations.first { $0.id == cid }?.messages.last?.content == String(format: AppState.unattendedDenialNotice, "write_file"))
    }

    @Test("a sibling that is not a .git is still allowed")
    func siblingsAreAllowed() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        for rel in ["out.md", ".gitignore", ".gitattributes", ".github/workflows/ci.yml", "gitrepo/notes.md", "src/.gitkeep", "a.git/config"] {
            #expect(await write(c(t.proj, rel), t, app, cid), Comment(rawValue: rel))
        }
        #expect(app.takeBackgroundDenials(for: cid).isEmpty)
    }

    @Test("a nested repository's .git, a .git that is a file, and another case are refused too")
    func nestedFileAndCase() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        let fm = FileManager.default
        try fm.createDirectory(at: t.proj.appendingPathComponent("vendor/lib/.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: t.proj.appendingPathComponent("wt"), withIntermediateDirectories: true)
        try "gitdir: ../.git/worktrees/wt\n".write(to: t.proj.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
        for rel in ["vendor/lib/.git/config", "vendor/lib/.git/hooks/post-checkout", "wt/.git", ".GIT/config", "deep/a/b/.Git/hooks/x"] {
            #expect(await !write(c(t.proj, rel), t, app, cid), Comment(rawValue: rel))
            #expect(app.takeBackgroundDenials(for: cid).count == 1, Comment(rawValue: rel))
        }
    }

    @Test("a link into a .git does not hide it: the real path is judged as well as the spelling")
    func symlinkIntoGit() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        let fm = FileManager.default
        try fm.createDirectory(at: t.proj.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: t.proj.appendingPathComponent("link"), withDestinationURL: t.proj.appendingPathComponent(".git"))
        try fm.createSymbolicLink(at: t.proj.appendingPathComponent("hooks"), withDestinationURL: t.proj.appendingPathComponent(".git/hooks"))
        // Nothing in the spelling says `.git`; the real path does.
        for rel in ["link/config", "hooks/pre-commit"] {
            let spelled = t.proj.path + "/" + rel   // as the model typed it: not resolved
            #expect(!spelled.split(separator: "/").contains(".git"), "the spelling holds no .git: \(rel)")
            #expect(await !write(spelled, t, app, cid), Comment(rawValue: rel))
            #expect(app.takeBackgroundDenials(for: cid).count == 1, Comment(rawValue: rel))
        }
    }

    @Test("an attended turn keeps its approval flow: the rule is for unattended runs")
    func attendedIsUnchanged() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let app = AppState()
        app.permissions = PermissionManager(paths: IrisPaths(root: t.home.appendingPathComponent(".iris")))
        app.autoApproveTools = true    // a headless driver: approves what an attended turn would
        let cid = app.createNewConversation(isBackground: false, select: false)
        let ok = await app.requestApproval(toolName: "write_file", details: c(t.proj, ".git/config"), args: [:],
                                           workspace: c(t.proj), conversationId: cid)
        #expect(ok, "not a background conversation: today's flow, unchanged")
        #expect(app.takeBackgroundDenials(for: cid).isEmpty)
    }

    @Test("the rule is about write_file: a read, or a command, is not it")
    func onlyWriteFile() {
        let permissions = PermissionManager(paths: IrisPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("iris-867-\(UUID().uuidString)")))
        #expect(permissions.writesGitDir(toolName: "write_file", details: "/p/.git/config", workspace: nil))
        #expect(!permissions.writesGitDir(toolName: "read_file", details: "/p/.git/config", workspace: nil))
        #expect(!permissions.writesGitDir(toolName: "run_command", details: "git config core.x y", workspace: "/p/.git"))
        #expect(!permissions.writesGitDir(toolName: "write_file", details: "/p/src/main.swift", workspace: nil))
        #expect(permissions.writesGitDir(toolName: "write_file", details: ".git/config", workspace: "/p"), "a relative path is judged against the working directory")
    }

    @Test("#907: config, HEAD, a hooks/ file and an info/ file are all refused before HEAD exists, the moment objects/ or refs/ does")
    func completingWritesRefusedBeforeHeadExists() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        let fm = FileManager.default
        try fm.createDirectory(at: t.proj.appendingPathComponent("evil.git/objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: t.proj.appendingPathComponent("evil.git/refs/heads"), withIntermediateDirectories: true)
        // No HEAD yet: insideGitDirByStructure alone would say this is not a git dir.
        #expect(!FileManager.default.fileExists(atPath: t.proj.appendingPathComponent("evil.git/HEAD").path))

        for rel in ["evil.git/config", "evil.git/HEAD", "evil.git/hooks/post-checkout", "evil.git/info/exclude"] {
            #expect(await !write(c(t.proj, rel), t, app, cid), Comment(rawValue: rel))
        }
        #expect(app.takeBackgroundDenials(for: cid).count == 4)
    }

    @Test("#907: refs/ alone (no objects/) is enough, and a sibling file next to them is unaffected")
    func refsAloneIsEnough() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        let fm = FileManager.default
        try fm.createDirectory(at: t.proj.appendingPathComponent("evil.git/refs"), withIntermediateDirectories: true)
        #expect(await !write(c(t.proj, "evil.git/config"), t, app, cid))
        #expect(await write(c(t.proj, "evil.git/notes.md"), t, app, cid), "a file that is not config/HEAD/hooks/info is not swept in")
    }

    @Test("neither objects/ nor refs/ exists: config and HEAD are not yet completing anything")
    func neitherPresentIsUnaffected() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        try FileManager.default.createDirectory(at: t.proj.appendingPathComponent("evil.git"), withIntermediateDirectories: true)
        for rel in ["evil.git/config", "evil.git/HEAD"] {
            #expect(await write(c(t.proj, rel), t, app, cid), Comment(rawValue: rel))
        }
    }

    @Test("a git dir by its shape is refused whatever it is named: a bare repository, and the dir a .git file points at")
    func gitDirByStructure() async throws {
        let t = try JobGrantAllowsTests.tree(); defer { t.tearDown() }
        let (app, cid) = background(t)
        let fm = FileManager.default
        func gitDir(_ rel: String) throws {
            let d = t.proj.appendingPathComponent(rel)
            try fm.createDirectory(at: d.appendingPathComponent("objects"), withIntermediateDirectories: true)
            try fm.createDirectory(at: d.appendingPathComponent("refs"), withIntermediateDirectories: true)
            try fm.createDirectory(at: d.appendingPathComponent("hooks"), withIntermediateDirectories: true)
            try "ref: refs/heads/main\n".write(to: d.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        }
        try gitDir("x.git")                       // a bare repository
        try gitDir("store/real")                  // a separate git dir; its worktree's .git file points here
        for rel in ["x.git/hooks/post-receive", "x.git/config", "store/real/hooks/pre-commit", "store/real/config"] {
            #expect(await !write(c(t.proj, rel), t, app, cid), Comment(rawValue: rel))
        }
        // A folder that only looks like one (a name, or HEAD alone) stays writable.
        try fm.createDirectory(at: t.proj.appendingPathComponent("plain.git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: t.proj.appendingPathComponent("headonly"), withIntermediateDirectories: true)
        try "x".write(to: t.proj.appendingPathComponent("headonly/HEAD"), atomically: true, encoding: .utf8)
        for rel in ["plain.git/config", "headonly/notes.md"] {
            #expect(await write(c(t.proj, rel), t, app, cid), Comment(rawValue: rel))
        }
    }
}
