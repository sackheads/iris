import Testing
import Foundation
@testable import IrisKit

/// A host repository with the sandbox's copy of it, and a stand-in for the VM: `ContainerVMGit`'s
/// own scripts run by bash on the host with `GIT_DIR` at the copy, which is what git in the VM sees
/// at the mounted path. The copy's alternates name the host's objects directly.
private struct SyncFixture {
    let dir: String
    let ws: String
    let env: [String: String]
    let repo: SandboxGit.Repo

    static func make() async throws -> SyncFixture {
        let (dir, env) = try await GitFixture.repo()
        let ws = dir + "/ws"
        _ = try await GitFixture.sh("git branch -m main", in: ws, env: env)
        let common = IrisPaths.realPath(ws + "/.git")
        let vmDir = dir + "/iris-home/sandbox-git/" + SandboxGit.key(common)
        try SandboxGit.seed(hostCommonDir: common, vmDir: vmDir, hostMount: common)
        // The person's hooks leave a mark if anything Iris runs fires them.
        for hook in ["post-checkout", "post-merge", "reference-transaction", "post-index-change"] {
            try "#!/bin/sh\ntouch \(dir)/HOOK-\(hook)\n".write(toFile: ws + "/.git/hooks/" + hook, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ws + "/.git/hooks/" + hook)
        }
        let repo = SandboxGit.Repo(source: ws, target: ws, hostCommonDir: common, hostGitDir: common, isWorktree: false,
                                   vmDir: vmDir, vmCommonDir: vmDir, hostMount: common)
        return SyncFixture(dir: dir, ws: ws, env: env, repo: repo)
    }

    var vmEnv: [String: String] {
        var e = env
        e["GIT_DIR"] = repo.vmDir
        e["GIT_WORK_TREE"] = ws
        return e
    }

    /// A command run "in the VM": git there uses the copy.
    @discardableResult
    func vm(_ script: String) async throws -> (status: Int32, out: String) {
        try await GitFixture.sh(script, in: ws, env: vmEnv)
    }

    @discardableResult
    func host(_ script: String) async throws -> (status: Int32, out: String) {
        try await GitFixture.sh(script, in: ws, env: env)
    }

    var sync: SandboxGitSync {
        let vmEnv = self.vmEnv
        let ws = self.ws
        return SandboxGitSync(repo: repo, vm: ContainerVMGit(repo: repo) { script in
            guard case .success(let out) = await ProcessGroupRunner.capture(executable: "/bin/bash", arguments: ["-c", script],
                                                                             environment: vmEnv, currentDirectory: ws,
                                                                             timeoutSeconds: 30) else { return nil }
            return (String(data: out.stdout, encoding: .utf8) ?? "", out.status)
        }, host: SandboxHostGit(environment: env))
    }

    func sha(_ ref: String) async throws -> String {
        try await host("git rev-parse \(ref)").out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hooksFired: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("HOOK-") }
    }

    func clearHooks() {
        for marker in hooksFired { try? FileManager.default.removeItem(atPath: dir + "/" + marker) }
    }

    /// One in-VM "command" with the sync around it, as `SandboxSessionManager.run` does. Clears
    /// the hook marks first: the test's own host git may fire the person's hooks, the sync never.
    func around(_ script: String) async throws -> [String] {
        clearHooks()
        let (before, pre) = await sync.before()
        try await vm(script)
        return pre + (await sync.after(before))
    }
}

@Suite("The sandbox's own git dir and its sync (#658)", .serialized, .timeLimit(.minutes(1)))
struct SandboxGitTests {
    // MARK: The decision

    private func facts(_ change: (inout SandboxSyncFacts) -> Void) -> SandboxSyncDecision {
        var f = SandboxSyncFacts(branch: "main", vmSha: "b", hostHeadBranch: "main", hostSha: "a", checkedOutElsewhere: nil,
                                 hostIsAncestor: true, worktreeMatches: true, indexClean: true)
        change(&f)
        return SandboxSyncDecision.decide(f)
    }

    @Test("a fast-forward only when the host branch is checked out here, is the base, the worktree matches and nothing is staged")
    func decision() {
        #expect(facts { _ in } == .fastForward)
        #expect(facts { $0.hostSha = "b" } == .unchanged)
        #expect(facts { $0.hostIsAncestor = false } == .keep(reason: "it has diverged from the sandbox's"))
        #expect(facts { $0.worktreeMatches = false } == .keep(reason: "your files differ from the sandbox's commit"))
        #expect(facts { $0.indexClean = false } == .keep(reason: "your index has staged changes"))
        #expect(facts { $0.hostHeadBranch = nil } == .keep(reason: "your Mac's HEAD is detached"))
        #expect(facts { $0.hostHeadBranch = "dev" } == .keep(reason: "your Mac has dev checked out, not main"))
        #expect(facts { $0.checkedOutElsewhere = "/x/wt" } == .keep(reason: "it is checked out in /x/wt"))
        #expect(facts { $0.hostSha = nil } == .keep(reason: "main does not exist on your Mac"))
    }

    @Test("only plain branch names reach a refspec")
    func branchNames() {
        for good in ["main", "feat/658-x", "a.b_c"] { #expect(SandboxGitSync.isPlainBranch(good), "\(good)") }
        for bad in ["-x", "a:b", "a b", "a..b", "x.lock", "/a", "a/", ".x", "a/.b", "+main", "a\nb", "$(x)"] {
            #expect(!SandboxGitSync.isPlainBranch(bad), "\(bad)")
        }
    }

    // MARK: Seeding

    @Test("the copy holds config, refs, HEAD, index and exclude, not objects or hooks, with alternates; a branch named logs survives")
    func seeding() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git branch -m main && git branch logs && git branch hooks && echo '*.tmp' >> .git/info/exclude", in: dir + "/ws", env: env)
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        guard case .repo(let repo) = SandboxGit.prepare(source: dir + "/ws", target: dir + "/ws", paths: paths) else {
            Issue.record("no copy"); return
        }
        let fm = FileManager.default
        for kept in ["config", "HEAD", "index", "info/exclude", "refs/heads/main", "refs/heads/logs", "refs/heads/hooks"] {
            #expect(fm.fileExists(atPath: repo.vmDir + "/" + kept), "\(kept) copied")
        }
        #expect(try String(contentsOfFile: repo.vmDir + "/objects/info/alternates", encoding: .utf8) == repo.hostMount + "/objects\n")
        #expect(try fm.contentsOfDirectory(atPath: repo.vmDir + "/hooks").isEmpty, "no hooks in the copy")
        #expect(!fm.fileExists(atPath: repo.vmDir + "/logs"))
        #expect(try fm.contentsOfDirectory(atPath: repo.vmDir + "/objects").sorted() == ["info"], "no objects copied")

        // Reused while it belongs to the same repository; made again once that is a new one.
        try "vm".write(toFile: repo.vmDir + "/vm-was-here", atomically: false, encoding: .utf8)
        _ = SandboxGit.prepare(source: dir + "/ws", target: dir + "/ws", paths: paths)
        #expect(fm.fileExists(atPath: repo.vmDir + "/vm-was-here"), "kept across sessions")
        try fm.removeItem(atPath: dir + "/ws/.git")
        try await GitFixture.sh("git init -q", in: dir + "/ws", env: env)
        _ = SandboxGit.prepare(source: dir + "/ws", target: dir + "/ws", paths: paths)
        #expect(!fm.fileExists(atPath: repo.vmDir + "/vm-was-here"), "a re-created repository gets a fresh copy")

        SandboxGit.prune(inUse: [], paths: paths)
        #expect(!fm.fileExists(atPath: repo.vmDir), "pruned once nothing uses it")
    }

    // MARK: Pointers

    @Test("a submodule or worktree pointer leading outside the host repository is moved aside; one inside is left")
    func pointers() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        try await GitFixture.sh("git init -q -b main \(dir)/sub && git -C \(dir)/sub -c user.email=a@b -c user.name=a commit -q --allow-empty -m s && git -c protocol.file.allow=always submodule -q add \(dir)/sub s && git commit -qm sub",
                                in: ws, env: env)
        #expect(SandboxGit.pointerProblems(source: ws, commonDir: ws + "/.git").isEmpty, "git's own pointer")

        try FileManager.default.createDirectory(atPath: ws + "/.evil", withIntermediateDirectories: true)
        try "gitdir: ../.evil\n".write(toFile: ws + "/s/.git", atomically: false, encoding: .utf8)
        #expect(SandboxGit.pointerProblems(source: ws, commonDir: ws + "/.git").map(\.relative) == ["s/.git"])
        let notes = SandboxGit.quarantinePointers(source: ws, commonDir: ws + "/.git")
        #expect(notes.count == 1 && notes[0].contains("moved it aside"), "\(notes)")
        #expect(!FileManager.default.fileExists(atPath: ws + "/s/.git"))
        #expect(FileManager.default.fileExists(atPath: ws + "/s/.git" + WorkspaceGit.quarantineSuffix), "never deleted")

        // A worktree whose own .git file is rewritten to name a repository of the VM's.
        try await GitFixture.sh("git worktree add -q ../wt", in: ws, env: env)
        #expect(SandboxGit.pointerProblems(source: dir + "/wt", commonDir: ws + "/.git").isEmpty)
        try "gitdir: \(ws)/.evil\n".write(toFile: dir + "/wt/.git", atomically: false, encoding: .utf8)
        #expect(SandboxGit.pointerProblems(source: dir + "/wt", commonDir: ws + "/.git").map(\.relative) == [".git"],
                "judged against the common dir Iris recorded, not the one the rewritten file names")

        // A submodule whose .git is a folder in the worktree (added from an existing clone) is the
        // person's own repository, like any nested one: left alone.
        try await GitFixture.sh("git init -q -b main inner && git -C inner -c user.email=a@b -c user.name=a commit -q --allow-empty -m i && git add inner && git commit -qm inner",
                                in: ws, env: env)
        #expect(!SandboxGit.pointerProblems(source: ws, commonDir: ws + "/.git").contains { $0.relative == "inner/.git" })
    }

    // MARK: Sync

    @Test("a VM commit on the checked-out branch moves the host branch and index, with no hook and a note")
    func fastForward() async throws {
        let f = try await SyncFixture.make()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let old = try await f.sha("main")
        let notes = try await f.around("echo vm > v.txt && git add v.txt && git commit -qm vm")
        #expect(f.hooksFired.isEmpty, "no hook ran: \(f.hooksFired)")
        let new = try await f.sha("main")
        #expect(new != old, "the host branch moved")
        #expect(notes == ["Moved main \(old.prefix(7))..\(new.prefix(7)) (1 commit from the sandbox)."], "\(notes)")
        #expect(try await f.host("git status --porcelain").out.isEmpty, "the host index matches")
        #expect(try await f.sha("refs/iris/sandbox/main") == new)
    }

    @Test("diverged, files that differ, or staged changes keep the commits on refs/iris/sandbox and say why")
    func keeps() async throws {
        // Diverged: an unsynced VM commit, then one on the host.
        var f = try await SyncFixture.make()
        try await f.vm("echo v > v.txt && git add v.txt && git commit -qm vm1")
        try await f.host("echo h > h.txt && git add h.txt && git commit -qm host")
        let hostHead = try await f.sha("main")
        var notes = try await f.around("echo v2 >> v.txt && git commit -qam vm2")
        #expect(f.hooksFired.isEmpty, "no hook ran: \(f.hooksFired)")
        #expect(notes.contains { $0.contains("diverged") }, "\(notes)")
        #expect(try await f.sha("main") == hostHead, "the host branch did not move")
        #expect(try await f.sha("refs/iris/sandbox/main") == (try await f.vm("git rev-parse main").out.trimmingCharacters(in: .whitespacesAndNewlines)))
        try? FileManager.default.removeItem(atPath: f.dir)

        // Files that differ: after committing, the VM edits a tracked file.
        f = try await SyncFixture.make()
        notes = try await f.around("echo v > v.txt && git add v.txt && git commit -qm vm && echo edited > f")
        #expect(notes.contains { $0.contains("your files differ") }, "\(notes)")
        try? FileManager.default.removeItem(atPath: f.dir)

        // Staged changes on the host.
        f = try await SyncFixture.make()
        try await f.host("echo s > s.txt && git add s.txt")
        notes = try await f.around("echo v > v.txt && git add v.txt && git commit -qm vm")
        #expect(notes.contains { $0.contains("staged changes") }, "\(notes)")
        #expect(try await f.host("git diff --cached --name-only").out.contains("s.txt"), "the person's staging is untouched")
        try? FileManager.default.removeItem(atPath: f.dir)
    }

    @Test("a branch the VM makes is kept aside; one checked out in another host worktree is never moved")
    func otherBranches() async throws {
        let f = try await SyncFixture.make()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        var notes = try await f.around("git update-ref refs/heads/made $(git commit-tree -p HEAD -m made HEAD^{tree})")
        #expect(notes.contains { $0.hasPrefix("The sandbox made branch made") }, "\(notes)")
        #expect(try await f.host("git rev-parse -q --verify refs/heads/made").status != 0, "not created on the host")

        try await f.host("git branch other && git worktree add -q ../wt other")
        let base = try await f.sha("other")
        notes = try await f.around("git update-ref refs/heads/other $(git commit-tree -p \(base) -m o \(base)^{tree})")
        #expect(notes.contains { $0.contains("checked out in") && $0.contains("/wt") }, "\(notes)")
        #expect(try await f.sha("other") == base, "the other worktree's branch did not move")
        #expect(try await f.sha("refs/iris/sandbox/other") != base)
    }

    @Test("when the host moved ahead, the VM's branch and index follow before the next command")
    func reverse() async throws {
        let f = try await SyncFixture.make()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        try await f.host("echo h > h.txt && git add h.txt && git commit -qm host")
        let host = try await f.sha("main")
        let (_, notes) = await f.sync.before()
        #expect(notes.count == 1 && notes[0].hasPrefix("Moved the sandbox's main"), "\(notes)")
        #expect(try await f.vm("git rev-parse main").out.trimmingCharacters(in: .whitespacesAndNewlines) == host)
        #expect(try await f.vm("git status --porcelain").out.isEmpty, "the VM's index matches the shared worktree")
    }

    @Test("a detached VM HEAD is said; a bundle that is a directory or a link is never handed to host git")
    func detachedAndBundle() async throws {
        let f = try await SyncFixture.make()
        defer { try? FileManager.default.removeItem(atPath: f.dir) }
        let notes = try await f.around("git checkout -q --detach && git commit -q --allow-empty -m d")
        #expect(notes.contains { $0.contains("HEAD is detached") }, "\(notes)")

        let bundle = f.repo.vmDir + "/" + SandboxGit.bundleName
        try? FileManager.default.removeItem(atPath: bundle)
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        #expect(SandboxGitSync.takeBundle(vmDir: f.repo.vmDir) == nil, "a directory (a repository of the VM's) is refused")
        try FileManager.default.removeItem(atPath: bundle)
        try FileManager.default.createSymbolicLink(atPath: bundle, withDestinationPath: f.ws + "/.git/config")
        #expect(SandboxGitSync.takeBundle(vmDir: f.repo.vmDir) == nil, "a link is refused")
        try FileManager.default.removeItem(atPath: bundle)
        try Data("bundle".utf8).write(to: URL(fileURLWithPath: bundle))
        let copy = try #require(SandboxGitSync.takeBundle(vmDir: f.repo.vmDir))
        defer { try? FileManager.default.removeItem(atPath: copy) }
        #expect(FileManager.default.contents(atPath: copy) == Data("bundle".utf8), "a regular file is copied out")
    }
}
