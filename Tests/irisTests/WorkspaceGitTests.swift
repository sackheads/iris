import Testing
import Foundation
@testable import IrisKit

/// A throwaway repository made by the real `git`, isolated from the developer's own config.
enum GitFixture {
    /// `HOME` and the system config pointed away, so only the repository's config is read.
    static func environment(home: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("GIT_") { env[key] = nil }
        env["HOME"] = home
        env["XDG_CONFIG_HOME"] = home + "/.config"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        return env
    }

    static func temp(_ label: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-623-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return IrisPaths.realPath(dir.path)
    }

    /// Runs `/bin/sh -c script` in `dir`, answering its exit status and output.
    @discardableResult
    static func sh(_ script: String, in dir: String, env: [String: String]) async throws -> (status: Int32, out: String) {
        let result = await ProcessGroupRunner.capture(executable: "/bin/sh", arguments: ["-c", script], environment: env,
                                                      currentDirectory: dir, mergeStderr: true, timeoutSeconds: 30)
        let out = try result.get()
        return (out.status, String(data: out.stdout, encoding: .utf8) ?? "")
    }

    /// A repository with one commit, in a fresh temp folder that also serves as `HOME`.
    static func repo() async throws -> (dir: String, env: [String: String]) {
        let dir = try temp("repo")
        let env = environment(home: dir + "/home")
        try FileManager.default.createDirectory(atPath: dir + "/home", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/ws", withIntermediateDirectories: true)
        let r = try await sh("git init -q && git config user.email a@b && git config user.name a && echo a > f && git add f && git commit -qm i",
                             in: dir + "/ws", env: env)
        #expect(r.status == 0, "\(r.out)")
        return (dir, env)
    }

    static func read(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
}

@Suite("Git config parsing and the allow-list (#623)")
struct GitConfigFileTests {
    @Test("sections, subsections, bare keys, quotes, escapes, comments and continuations parse as git reads them")
    func parses() throws {
        let text = """
        # top
        [core]
        \tbare = false ; trailing
        \tfilemode
        [remote "origin"]
        \turl = "git@github.com:a/b.git"
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [Branch "Main"] merge = refs/heads/main
        [alias]
        \tlong = a \\
        b
        \tq = "x # y"  \\t z
        """
        let entries = try #require(GitConfigFile.parse(Data(text.utf8)))
        let map = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        #expect(map["core.bare"] == "false")
        #expect(map["core.filemode"] == .some(nil))
        #expect(map["remote.origin.url"] == "git@github.com:a/b.git")
        #expect(map["remote.origin.fetch"] == "+refs/heads/*:refs/remotes/origin/*")
        #expect(map["branch.Main.merge"] == "refs/heads/main", "subsection keeps its case; section and name do not")
        #expect(map["alias.long"] == "a b")
        #expect(map["alias.q"] == "x # y  \t z")
    }

    @Test("what it cannot read in full is nil, so a change to it is put back")
    func strict() {
        for bad in ["[core\nx = 1", "x = 1", "[core]\n\tq = \"open\n", "[core]\n\tq = a\\q", "[a \"b\n", "[core]\n\t= 1"] {
            #expect(GitConfigFile.parse(Data(bad.utf8)) == nil, "parsed: \(bad.debugDescription)")
        }
    }

    private func entries(_ text: String) -> [GitConfigFile.Entry] { GitConfigFile.parse(Data(text.utf8)) ?? [] }

    @Test("a remote, an upstream and user.* may change; anything that can run a program may not")
    func allowList() {
        let base = entries("[core]\n\tbare = false\n")
        let allowed = entries("""
        [core]
        \tbare = false
        [remote "up"]
        \turl = https://github.com/a/b.git
        \tpushurl = git@github.com:a/b.git
        \tfetch = +refs/heads/*:refs/remotes/up/*
        [branch "feature"]
        \tremote = up
        \tmerge = refs/heads/feature
        [user]
        \temail = a@b
        """)
        #expect(GitConfigFile.disallowedKeys(from: base, to: allowed) == [])
        #expect(GitConfigFile.disallowedKeys(from: allowed, to: base) == [], "removing them is allowed too")
        let cases: [(String, String)] = [
            ("[core]\n\tbare = false\n\thooksPath = /tmp/h\n", "core.hookspath"),
            ("[core]\n\tbare = true\n", "core.bare"),
            ("[core]\n\tbare = false\n\tfsmonitor = ./x\n", "core.fsmonitor"),
            ("[core]\n\tbare = false\n[include]\n\tpath = ../x\n", "include.path"),
            ("[core]\n\tbare = false\n[includeIf \"gitdir:/\"]\n\tpath = ../x\n", "includeif.gitdir:/.path"),
            ("[core]\n\tbare = false\n[filter \"lfs\"]\n\tclean = x\n", "filter.lfs.clean"),
            ("[core]\n\tbare = false\n[remote \"o\"]\n\tuploadpack = x\n", "remote.o.uploadpack"),
            ("[core]\n\tbare = false\n[remote \"o\"]\n\tvcs = x\n", "remote.o.vcs"),
            ("[core]\n\tbare = false\n[user]\n\tname\n", "user.name"),
        ]
        for (text, key) in cases {
            #expect(GitConfigFile.disallowedKeys(from: base, to: entries(text)) == [key], "\(key)")
        }
        #expect(GitConfigFile.disallowedKeys(from: base, to: entries("[core]\n\tbare = false\n\tbare = false\n")) == ["core.bare"],
                "a second copy of a key is a change")
    }

    @Test("a URL that names a transport helper or reads as an option is not allowed")
    func urls() {
        let base = entries("")
        for url in ["ext::sh -c touch% /tmp/x", "fd::3", "foo::https://x", "-uhelper", "https://x\u{1}"] {
            for key in ["remote \"o\"]\n\turl", "remote \"o\"]\n\tpushurl", "branch \"m\"]\n\tremote"] {
                let text = "[\(key) = \"\(url)\"\n"
                #expect(!GitConfigFile.disallowedKeys(from: base, to: entries(text)).isEmpty || entries(text).isEmpty,
                        "allowed: \(text.debugDescription)")
            }
        }
        #expect(GitConfigFile.isSafeURL("git@github.com:a/b.git"))
        #expect(GitConfigFile.isSafeURL("../sibling"))
        #expect(!GitConfigFile.isSafeURL("ext::sh"))
    }
}

/// A runtime whose `exec` runs a closure on the host, standing in for what the VM writes.
private final class WritingRuntime: ContainerRuntime, @unchecked Sendable {
    let lock = NSLock()
    var onExec: @Sendable (String) -> Void = { _ in }
    private(set) var mounts: [[String]] = []
    func createDetached(name: String, image: String, mounts: [String], workdir: String, network: NetworkMode) async throws {
        lock.withLock { self.mounts.append(mounts) }
    }
    func ensureIsolatedNetwork(named name: String) async throws {}
    func exec(name: String, workdir: String, command: String, timeoutSeconds: Int?) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        lock.withLock { onExec }(command)
        return ("ran", "", 0)
    }
    func remove(name: String) async -> Bool { true }
    func list(prefix: String) async -> [String] { [] }
}

@Suite("Sandboxed repositories: hooks mounted read-only, config put back (#623)", .serialized, .timeLimit(.minutes(1)))
struct GitConfigGuardTests {
    @Test("a repository at a mount's root gets its .git as a mountpoint and its hooks read-only; none, nothing")
    func protectedMounts() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let items = WorkspaceIrisDir.protected(for: ws)
        #expect(items.map(\.relative) == [".iris", ".git", ".git/hooks"])
        #expect(items.map(\.readOnly) == [true, false, true])
        let list = SandboxSessionManager.mountList(workspace: ContainerMount(source: ws), extra: [])
        #expect(list == ["\(ws):\(ws)", "\(ws)/.iris:\(ws)/.iris:ro", "\(ws)/.git:\(ws)/.git", "\(ws)/.git/hooks:\(ws)/.git/hooks:ro"])
        #expect(WorkspaceIrisDir.protected(for: dir + "/home").map(\.relative) == [".iris"])

        // A hooks folder that is a link cannot be mounted read-only as itself: the run refuses.
        try FileManager.default.removeItem(atPath: ws + "/.git/hooks")
        try FileManager.default.createSymbolicLink(atPath: ws + "/.git/hooks", withDestinationPath: dir + "/home")
        guard case .refused(let why) = WorkspaceIrisDir.prepareForMount(ws, items[2]) else { Issue.record("a linked hooks folder passed"); return }
        #expect(why.contains("repository's hooks"))
        // A missing one is made before the container is, so the VM cannot make it.
        try FileManager.default.removeItem(atPath: ws + "/.git/hooks")
        #expect(WorkspaceIrisDir.prepareForMount(ws, items[2]) == .ready(ws + "/.git/hooks"))
    }

    @Test("a .git that is a link refuses; a worktree whose common dir is elsewhere mounts nothing extra")
    func layouts() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/linked", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/linked/.git", withDestinationPath: dir + "/ws/.git")
        let linked = WorkspaceIrisDir.protected(for: dir + "/linked")
        guard case .refused = WorkspaceIrisDir.prepareForMount(dir + "/linked", linked[1]) else { Issue.record("a linked .git passed"); return }

        try await GitFixture.sh("git worktree add -q ../wt", in: dir + "/ws", env: env)
        #expect(WorkspaceIrisDir.protected(for: dir + "/wt").map(\.relative) == [".iris"])
        let files = WorkspaceGit.watchedFiles(for: dir + "/wt")
        #expect(files[dir + "/wt/.git"] == .pointer, "the worktree's .git file is watched")
        #expect(files.keys.allSatisfy { $0.hasPrefix(dir + "/wt/") }, "nothing outside the mount: \(files.keys.sorted())")
        // The main repository, mounted, watches its linked worktree's commondir.
        let main = WorkspaceGit.watchedFiles(for: dir + "/ws")
        #expect(main[dir + "/ws/.git/worktrees/wt/commondir"] == .pointer)
        #expect(main[dir + "/ws/.git/config"] == .config)
    }

    @Test("a .git file naming a git dir inside the mount gets that dir and its hooks protected, and the file watched")
    func gitDirInside() async throws {
        let dir = try GitFixture.temp("sep")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("mkdir inner && git init -q --separate-git-dir=inner/gitdir", in: dir, env: GitFixture.environment(home: dir))
        let items = WorkspaceGit.protected(for: dir)
        #expect(items.map(\.relative) == ["inner/gitdir", "inner/gitdir/hooks"])
        #expect(items.map(\.readOnly) == [false, true])
        let files = WorkspaceGit.watchedFiles(for: dir)
        #expect(files[dir + "/.git"] == .pointer)
        #expect(files[dir + "/inner/gitdir/config"] == .config)
    }

    @Test("a disallowed key written in the VM is put back byte for byte and reported")
    func revertsDisallowed() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let config = dir + "/ws/.git/config"
        let before = try #require(GitFixture.read(config))
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        try (String(decoding: before, as: UTF8.self) + "[core]\n\thooksPath = /tmp/evil\n").write(toFile: config, atomically: false, encoding: .utf8)
        let notice = try #require(guardian.check(owner: "c"))
        #expect(notice.contains("core.hookspath"))
        #expect(notice.contains("put back"))
        #expect(GitFixture.read(config) == before)
        #expect(guardian.check(owner: "c") == nil, "said once")
    }

    @Test("an upstream or remote added in the VM is kept, and becomes what later changes are judged against")
    func keepsAllowed() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let config = dir + "/ws/.git/config"
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        try await GitFixture.sh("git remote add up https://github.com/a/b.git && git config branch.main.remote up && git config branch.main.merge refs/heads/main && git config user.email c@d",
                                in: dir + "/ws", env: env)
        let kept = try #require(GitFixture.read(config))
        #expect(guardian.check(owner: "c") == nil)
        #expect(GitFixture.read(config) == kept)
        try await GitFixture.sh("git config core.fsmonitor ./x", in: dir + "/ws", env: env)
        #expect(guardian.check(owner: "c") != nil)
        #expect(GitFixture.read(config) == kept, "put back to the kept copy, with the remote")
    }

    @Test("an ext:: URL is put back, though remote URLs may change")
    func revertsExtURL() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let config = dir + "/ws/.git/config"
        let before = try #require(GitFixture.read(config))
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        try await GitFixture.sh("git remote add o 'ext::sh -c touch% /tmp/pwned'", in: dir + "/ws", env: env)
        let notice = try #require(guardian.check(owner: "c"))
        #expect(notice.contains("remote.o.url"))
        #expect(GitFixture.read(config) == before)
    }

    @Test("a config.worktree the VM creates, a link put over config, and a rewritten worktree .git file are all undone")
    func otherFiles() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git worktree add -q ../wt", in: dir + "/ws", env: env)
        let config = dir + "/ws/.git/config"
        let before = try #require(GitFixture.read(config))
        let dotGit = try #require(GitFixture.read(dir + "/wt/.git"))
        let guardian = GitConfigGuard()
        guardian.watch(owner: "ws", sources: [dir + "/ws"])
        guardian.watch(owner: "wt", sources: [dir + "/wt"])

        try "[core]\n\thooksPath = /tmp/evil\n".write(toFile: dir + "/ws/.git/config.worktree", atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: config)
        try "[core]\n\tfsmonitor = x\n".write(toFile: dir + "/home/evil", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: config, withDestinationPath: dir + "/home/evil")
        try "gitdir: \(dir)/home/fake\n".write(toFile: dir + "/wt/.git", atomically: false, encoding: .utf8)

        let all = try #require(guardian.checkAll())
        #expect(all.contains("config.worktree") && all.contains("/wt/.git"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/ws/.git/config.worktree"))
        let attrs = try FileManager.default.attributesOfItem(atPath: config)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular, "the link is replaced, not followed")
        #expect(GitFixture.read(config) == before)
        #expect(GitFixture.read(dir + "/home/evil") == Data("[core]\n\tfsmonitor = x\n".utf8), "the link's target is untouched")
        #expect(GitFixture.read(dir + "/wt/.git") == dotGit)
    }

    @Test("a write after the last command is caught when the container ends and said with the next result")
    func endCatchesLateWrite() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let config = dir + "/ws/.git/config"
        let before = try #require(GitFixture.read(config))
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        #expect(guardian.check(owner: "c") == nil)
        try (String(decoding: before, as: UTF8.self) + "[diff]\n\texternal = ./x\n").write(toFile: config, atomically: false, encoding: .utf8)
        guardian.end(owner: "c")
        #expect(GitFixture.read(config) == before)
        #expect(guardian.check(owner: "other") == nil, "said to its own conversation, not whichever runs next")
        #expect(guardian.check(owner: "c")?.contains("diff.external") == true)
    }

    @Test("a config over 1 MiB is kept and still checked; an unreadable one is never written over")
    func largeAndUnreadable() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer {
            chmod(dir + "/ws/.git/config", 0o644)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let config = dir + "/ws/.git/config"
        let big = String(decoding: try #require(GitFixture.read(config)), as: UTF8.self)
            + "[alias]\n" + (0..<40_000).map { "\ta\($0) = log --oneline -n \($0)\n" }.joined()
        try big.write(toFile: config, atomically: false, encoding: .utf8)
        #expect(try #require(GitFixture.read(config)).count > 1 << 20)
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        #expect(guardian.check(owner: "c") == nil)
        #expect(GitFixture.read(config) == Data(big.utf8), "a large config is not lost")
        try (big + "[core]\n\tfsmonitor = x\n").write(toFile: config, atomically: false, encoding: .utf8)
        #expect(guardian.check(owner: "c")?.contains("core.fsmonitor") == true)
        #expect(GitFixture.read(config) == Data(big.utf8))

        // Unreadable when watched: recorded as there-but-unknown, so nothing is unlinked or written.
        chmod(config, 0o000)
        let other = GitConfigGuard()
        other.watch(owner: "c", sources: [dir + "/ws"])
        #expect(other.check(owner: "c") == nil)
        chmod(config, 0o644)
        try (big + "[core]\n\tfsmonitor = y\n").write(toFile: config, atomically: false, encoding: .utf8)
        let changed = try #require(GitFixture.read(config))
        let notice = try #require(other.check(owner: "c"))
        #expect(notice.contains("cannot check it"))
        #expect(GitFixture.read(config) == changed, "left alone and said so")
        #expect(other.hostRefusal(cwd: dir + "/ws", command: "") != nil, "and host commands there refused")
        #expect(other.check(owner: "c") == nil, "said once")
        #expect(other.hostRefusal(cwd: dir + "/ws", command: "") != nil, "still refused while it differs")
    }

    @Test("a .git/worktrees/<x> swapped for a link to a folder outside is not written through")
    func linkedWorktreeFolder() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git worktree add -q ../wt", in: dir + "/ws", env: env)
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        let entry = dir + "/ws/.git/worktrees/wt"
        try FileManager.default.moveItem(atPath: entry, toPath: dir + "/moved")
        try FileManager.default.createDirectory(atPath: dir + "/outside", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: entry, withDestinationPath: dir + "/outside")
        let notice = try #require(guardian.check(owner: "c"))
        #expect(notice.contains("did not write through"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/outside").isEmpty, "nothing restored into the link's target")
    }

    @Test("a restore refuses a link at any folder on the way, even one swapped in after the check")
    func restoreRefusesLinkedFolder() throws {
        let dir = try GitFixture.temp("restore")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/root/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/outside", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/root/.git/worktrees", withDestinationPath: dir + "/outside")
        #expect(!GitConfigGuard.restore(root: dir + "/root", relative: ".git/worktrees/commondir", to: Data("x".utf8)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/outside").isEmpty)
        #expect(GitConfigGuard.restore(root: dir + "/root", relative: ".git/config", to: Data("y".utf8)))
        #expect(GitFixture.read(dir + "/root/.git/config") == Data("y".utf8))
    }

    @Test("an existing submodule's config is watched and its hooks are read-only")
    func submodules() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git init -q ../sub && git -C ../sub commit -q --allow-empty -m s", in: dir + "/ws", env: env)
        let add = try await GitFixture.sh("git -c protocol.file.allow=always submodule add -q ../sub lib/sub", in: dir + "/ws", env: env)
        #expect(add.status == 0, "\(add.out)")
        let items = WorkspaceGit.protected(for: dir + "/ws").map(\.relative)
        #expect(items == [".git", ".git/hooks", ".git/modules/lib/sub/hooks"])
        let module = dir + "/ws/.git/modules/lib/sub/config"
        #expect(WorkspaceGit.watchedFiles(for: dir + "/ws")[module] == .config)
        let before = try #require(GitFixture.read(module))
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        try await GitFixture.sh("git config core.fsmonitor ./x", in: dir + "/ws/lib/sub", env: env)
        #expect(guardian.check(owner: "c")?.contains("core.fsmonitor") == true)
        #expect(GitFixture.read(module) == before)
    }

    @Test("after a restart the mounted folders are remembered, and a repository the VM made is judged, never adopted or written")
    func restart() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = URL(fileURLWithPath: dir + "/home/sandbox-workspaces.json")
        let plain = dir + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let first = GitConfigGuard(store: store)
        first.watch(owner: "c", sources: [dir + "/ws", plain])
        first.end(owner: "c")

        // The VM makes a repository in the folder that had none, with a filter driver.
        try await GitFixture.sh("git init -q && git config filter.x.clean \(dir)/evil", in: plain, env: env)
        let config = plain + "/.git/config"
        let made = try #require(GitFixture.read(config))

        let second = GitConfigGuard(store: store)
        #expect(second.hostOverrides(cwd: dir + "/ws") == .some(dir + "/ws/.git/hooks"), "overrides before any sandboxed command")
        #expect(second.hostOverrides(cwd: plain) == .some(nil), "no hooks for a repository the VM made")
        second.watch(owner: "d", sources: [plain])
        let notice = try #require(second.check(owner: "d"))
        #expect(notice.contains("filter.x.clean"))
        #expect(GitFixture.read(config) == made, "nothing of the person's to put back: left as it is")
        #expect(second.hostRefusal(cwd: plain, command: "git status") != nil)
        #expect(second.check(owner: "d") == nil, "said once per change")
        #expect(second.hostRefusal(cwd: plain, command: "") != nil, "still refused while it stands")
        try await GitFixture.sh("git config --unset filter.x.clean", in: plain, env: env)
        _ = second.check(owner: "d")
        #expect(second.hostRefusal(cwd: plain, command: "") == nil, "a clean check clears it")
    }

    @Test("a change Iris cannot put back refuses host commands that would read it until a check finds it clean")
    func failsClosed() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git worktree add -q ../wt", in: dir + "/ws", env: env)
        let wt = dir + "/wt"
        let dotGit = try #require(GitFixture.read(wt + "/.git"))
        let guardian = GitConfigGuard()
        let id = UUID()
        guardian.watch(owner: SandboxSessionManager.containerName(for: id), sources: [wt])
        try FileManager.default.removeItem(atPath: wt + "/.git")
        try FileManager.default.createDirectory(atPath: wt + "/.git", withIntermediateDirectories: true)
        try "x".write(toFile: wt + "/.git/keep", atomically: false, encoding: .utf8)

        var executor = ToolExecutor()
        executor.gitGuard = guardian
        let refused = await executor.runCommand("echo ran", cwd: wt, conversationId: id, timeoutSeconds: 30)
        #expect(refused.contains("could not put it back"), "\(refused)")
        #expect(refused.contains("Not run"), "\(refused)")
        #expect(!refused.contains("ran\n"))
        let named = await executor.runCommand("git -C \(wt) status; echo ran", cwd: dir, timeoutSeconds: 30)
        #expect(named.contains("Not run"), "\(named)")

        try FileManager.default.removeItem(atPath: wt + "/.git")
        try dotGit.write(to: URL(fileURLWithPath: wt + "/.git"))
        let clean = await executor.runCommand("echo ran", cwd: wt, conversationId: id, timeoutSeconds: 30)
        #expect(clean.hasPrefix("ran"), "\(clean)")
    }

    /// A repo with an `evil` script and a submodule `lib/sub` already in place.
    private func repoWithSubmodule() async throws -> (dir: String, env: [String: String], marker: String) {
        let (dir, env) = try await GitFixture.repo()
        let marker = dir + "/RAN"
        try "#!/bin/sh\ntouch \(marker)\nexit 0\n".write(toFile: dir + "/evil", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/evil")
        try await GitFixture.sh("git init -q ../sub && git -C ../sub commit -q --allow-empty -m s && git -c protocol.file.allow=always submodule add -q ../sub lib/sub && git commit -qm sub",
                                in: dir + "/ws", env: env)
        return (dir, env, marker)
    }

    /// What dev-1's repro plants: a repository with a poisoned fsmonitor, a gitlink for `path` and a
    /// `.git` pointer to that repository, all without touching `.git/config`.
    private func plantSubmodule(_ path: String, in ws: String, dir: String, env: [String: String]) async throws {
        try await GitFixture.sh("""
            git init -q \(dir)/evilrepo && git -C \(dir)/evilrepo commit -q --allow-empty -m e && git -C \(dir)/evilrepo config core.fsmonitor \(dir)/evil
            mkdir -p \(path) && echo "gitdir: \(dir)/evilrepo/.git" > \(path)/.git && echo y > \(path)/f
            git update-index --add --cacheinfo 160000,$(git -C \(dir)/evilrepo rev-parse HEAD),\(path)
            """, in: ws, env: env)
    }

    @Test("the index parser finds gitlinks in versions 2, 3 and 4")
    func indexVersions() async throws {
        let (dir, env, _) = try await repoWithSubmodule()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        for version in [2, 3, 4] {
            // Intent-to-add sets the extended flag, which needs version 3 or later.
            let add = version >= 3 ? "echo n > new\(version) && git add -N new\(version) && " : ""
            try await GitFixture.sh(add + "git update-index --index-version \(version)", in: ws, env: env)
            let header = try #require(GitFixture.read(ws + "/.git/index"))
            #expect(header[7] == UInt8(version))
            #expect(WorkspaceGit.gitlinks(index: ws + "/.git/index", sha256: false) == ["lib/sub"], "version \(version)")
        }
        try Data("DIRC garbage".utf8).write(to: URL(fileURLWithPath: dir + "/bad-index"))
        #expect(WorkspaceGit.gitlinks(index: dir + "/bad-index", sha256: false) == nil)
        #expect(WorkspaceGit.gitlinks(index: dir + "/no-index", sha256: false) == [])
    }

    @Test("a submodule planted in the VM is moved aside, and git status on the Mac no longer runs its program")
    func plantedSubmodule() async throws {
        let (dir, env, marker) = try await repoWithSubmodule()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [ws])
        try await plantSubmodule("planted", in: ws, dir: dir, env: env)
        try await GitFixture.sh("git status", in: ws, env: env)
        #expect(FileManager.default.fileExists(atPath: marker), "control: before the check, a plain git status runs it")
        try FileManager.default.removeItem(atPath: marker)

        let notice = try #require(guardian.check(owner: "c"))
        #expect(notice.contains("planted/.git") && notice.contains("moved it aside"))
        #expect(!FileManager.default.fileExists(atPath: ws + "/planted/.git"))
        #expect(FileManager.default.fileExists(atPath: ws + "/planted/.git.iris-quarantine"), "renamed, not deleted")
        try await GitFixture.sh("git status", in: ws, env: env)
        #expect(!FileManager.default.fileExists(atPath: marker))
        // The submodule that was there is untouched.
        #expect(FileManager.default.fileExists(atPath: ws + "/lib/sub/.git"))
        #expect(FileManager.default.fileExists(atPath: ws + "/.git/modules/lib/sub"))
        // Planted again: moved again, beside the first.
        try "gitdir: \(dir)/evilrepo/.git\n".write(toFile: ws + "/planted/.git", atomically: false, encoding: .utf8)
        #expect(guardian.check(owner: "c")?.contains(".git.iris-quarantine-2") == true)
    }

    @Test("a submodule planted under a split index is still found and moved aside")
    func splitIndex() async throws {
        let (dir, env, marker) = try await repoWithSubmodule()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [ws])
        try await plantSubmodule("planted", in: ws, dir: dir, env: env)
        try await GitFixture.sh("git update-index --split-index", in: ws, env: env)
        let shared = try FileManager.default.contentsOfDirectory(atPath: ws + "/.git").filter { $0.hasPrefix("sharedindex.") }
        #expect(!shared.isEmpty, "the index really is split")
        #expect(WorkspaceGit.gitlinks(index: ws + "/.git/index", sha256: false, followLink: false) == nil,
                "a link extension is not readable without its shared index")
        #expect(Set(WorkspaceGit.gitlinks(index: ws + "/.git/index", sha256: false) ?? []) == ["lib/sub", "planted"])
        #expect(guardian.check(owner: "c")?.contains("planted/.git") == true)
        try await GitFixture.sh("git status", in: ws, env: env)
        #expect(!FileManager.default.fileExists(atPath: marker))
        // A shared index that is gone fails closed.
        for name in shared { try FileManager.default.removeItem(atPath: ws + "/.git/" + name) }
        #expect(guardian.check(owner: "c")?.contains("too large or malformed") == true)
        #expect(guardian.hostRefusal(cwd: ws, command: "") != nil)
    }

    @Test("a submodule planted in a repository the VM made is moved aside, and git status there runs nothing")
    func submoduleInUntrustedRepo() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let marker = dir + "/RAN"
        try "#!/bin/sh\ntouch \(marker)\nexit 0\n".write(toFile: dir + "/evil", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/evil")
        let plain = dir + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [plain])
        // The VM makes a repository, then plants a submodule whose repository has a filter driver
        // and an attribute that uses it; the outer config stays clean.
        try await GitFixture.sh("git init -q && git config user.email a@b && git config user.name a && git commit -q --allow-empty -m i", in: plain, env: env)
        try await GitFixture.sh("""
            git init -q \(dir)/evilrepo && cd \(dir)/evilrepo && git config filter.x.clean \(dir)/evil && git config core.fsmonitor \(dir)/evil \
              && echo '* filter=x' > .gitattributes && echo a > f && git -c user.email=a@b -c user.name=a add . && git -c user.email=a@b -c user.name=a commit -qm e
            """, in: plain, env: env)
        try await GitFixture.sh("""
            mkdir sub && echo "gitdir: \(dir)/evilrepo/.git" > sub/.git && echo b > sub/f
            git update-index --add --cacheinfo 160000,$(git -C \(dir)/evilrepo rev-parse HEAD),sub
            """, in: plain, env: env)
        try await GitFixture.sh("git status", in: plain, env: env)
        #expect(FileManager.default.fileExists(atPath: marker), "control: before the check, git status runs it")
        try FileManager.default.removeItem(atPath: marker)

        let notice = try #require(guardian.check(owner: "c"))
        #expect(notice.contains("sub/.git"))
        #expect(FileManager.default.fileExists(atPath: plain + "/sub/.git.iris-quarantine"))
        try await GitFixture.sh("git status", in: plain, env: env)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("a folder that ends blocked keeps being checked, is never baselined again, and a clean check unblocks it")
    func blockedFolderStays() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git worktree add -q ../wt", in: dir + "/ws", env: env)
        let wt = dir + "/wt"
        let dotGit = try #require(GitFixture.read(wt + "/.git"))
        let guardian = GitConfigGuard()
        guardian.watch(owner: "a", sources: [wt])
        // A change Iris cannot put back: the .git file replaced by a folder.
        try FileManager.default.removeItem(atPath: wt + "/.git")
        try FileManager.default.createDirectory(atPath: wt + "/.git", withIntermediateDirectories: true)
        guardian.end(owner: "a")
        #expect(guardian.hostRefusal(cwd: wt, command: "") != nil, "still blocked once its container ended")
        _ = guardian.checkAll()
        #expect(guardian.hostRefusal(cwd: wt, command: "") != nil, "a host command's check still finds it")
        // A new watch joins the record: the bad state is not its baseline.
        guardian.watch(owner: "b", sources: [wt])
        _ = guardian.check(owner: "b")
        #expect(guardian.hostRefusal(cwd: wt, command: "") != nil)
        // Fixed by hand: the next check unblocks it.
        try FileManager.default.removeItem(atPath: wt + "/.git")
        try dotGit.write(to: URL(fileURLWithPath: wt + "/.git"))
        _ = guardian.checkAll()
        #expect(guardian.hostRefusal(cwd: wt, command: "") == nil)
    }

    /// A guard over `store`, as Iris has after a restart: the mounted folders and blocks it kept.
    private func restarted(_ store: URL) -> GitConfigGuard { GitConfigGuard(store: store) }

    @Test("blocked for a failed restore: still refused after a restart, cleared once the file is back")
    func restartRestoreBlock() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git worktree add -q ../wt", in: dir + "/ws", env: env)
        let wt = dir + "/wt"
        let dotGit = try #require(GitFixture.read(wt + "/.git"))
        let store = URL(fileURLWithPath: dir + "/home/sw.json")
        let first = GitConfigGuard(store: store)
        first.watch(owner: "a", sources: [wt])
        try FileManager.default.removeItem(atPath: wt + "/.git")
        try FileManager.default.createDirectory(atPath: wt + "/.git", withIntermediateDirectories: true)
        _ = first.check(owner: "a")
        #expect(first.hostRefusal(cwd: wt, command: "") != nil)

        let second = restarted(store)
        #expect(second.hostRefusal(cwd: wt, command: "") != nil, "refused after a restart")
        second.watch(owner: "b", sources: [wt])
        _ = second.check(owner: "b")
        #expect(second.hostRefusal(cwd: wt, command: "") != nil, "a watch after the restart does not baseline the bad state")
        try FileManager.default.removeItem(atPath: wt + "/.git")
        try dotGit.write(to: URL(fileURLWithPath: wt + "/.git"))
        _ = second.checkAll()
        #expect(second.hostRefusal(cwd: wt, command: "") == nil)
        #expect(restarted(store).hostRefusal(cwd: wt, command: "") == nil, "the clear is kept too")
    }

    @Test("blocked for an unreadable index: still refused after a restart, existing submodules never moved, cleared once it reads")
    func restartIndexBlock() async throws {
        let (dir, _, _) = try await repoWithSubmodule()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let store = URL(fileURLWithPath: dir + "/home/sw.json")
        let first = GitConfigGuard(store: store)
        first.watch(owner: "a", sources: [ws])
        let index = try #require(GitFixture.read(ws + "/.git/index"))
        try Data(index.prefix(40)).write(to: URL(fileURLWithPath: ws + "/.git/index"))
        _ = first.check(owner: "a")

        let second = restarted(store)
        #expect(second.checkAll() == nil)
        #expect(second.hostRefusal(cwd: ws, command: "") != nil)
        try index.write(to: URL(fileURLWithPath: ws + "/.git/index"))
        _ = second.checkAll()
        #expect(second.hostRefusal(cwd: ws, command: "") == nil)
        #expect(FileManager.default.fileExists(atPath: ws + "/lib/sub/.git"), "the person's submodule is not moved aside")
        #expect(FileManager.default.fileExists(atPath: ws + "/.git/modules/lib/sub"))
        second.watch(owner: "b", sources: [ws])
        #expect(second.check(owner: "b") == nil, "and the baseline taken now holds it as it is")
    }

    @Test("blocked for a risky key in a repository the VM made: still refused after a restart, cleared once it is gone")
    func restartRiskyBlock() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let plain = dir + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let store = URL(fileURLWithPath: dir + "/home/sw.json")
        let first = GitConfigGuard(store: store)
        first.watch(owner: "a", sources: [plain])
        try await GitFixture.sh("git init -q && git config filter.x.clean ./x", in: plain, env: env)
        _ = first.check(owner: "a")
        #expect(first.hostRefusal(cwd: plain, command: "") != nil)

        let second = restarted(store)
        _ = second.checkAll()
        #expect(second.hostRefusal(cwd: plain, command: "") != nil)
        try await GitFixture.sh("git config --unset filter.x.clean", in: plain, env: env)
        _ = second.checkAll()
        #expect(second.hostRefusal(cwd: plain, command: "") == nil)
    }

    @Test("blocked for a changed file Iris cannot read: still refused after a restart, cleared once it is as it was")
    func restartUnreadableBlock() async throws {
        let (dir, _) = try await GitFixture.repo()
        let config = dir + "/ws/.git/config"
        defer {
            chmod(config, 0o644)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let original = try #require(GitFixture.read(config))
        var was = stat()
        chmod(config, 0o000)
        #expect(lstat(config, &was) == 0)
        let store = URL(fileURLWithPath: dir + "/home/sw.json")
        let first = GitConfigGuard(store: store)
        first.watch(owner: "a", sources: [dir + "/ws"])
        // Changed in place (same file), still unreadable.
        chmod(config, 0o644)
        try (String(decoding: original, as: UTF8.self) + "[core]\n\tfsmonitor = x\n").write(toFile: config, atomically: false, encoding: .utf8)
        chmod(config, 0o000)
        _ = first.check(owner: "a")
        #expect(first.hostRefusal(cwd: dir + "/ws", command: "") != nil)

        let second = restarted(store)
        _ = second.checkAll()
        #expect(second.hostRefusal(cwd: dir + "/ws", command: "") != nil)
        // Put back exactly: same bytes, same file, same times.
        chmod(config, 0o644)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: config))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: original)
        try handle.close()
        chmod(config, 0o000)
        var times = [was.st_atimespec, was.st_mtimespec]
        #expect(utimensat(AT_FDCWD, config, &times, 0) == 0)
        _ = second.checkAll()
        #expect(second.hostRefusal(cwd: dir + "/ws", command: "") == nil)
    }

    @Test("a command names a folder only as a whole path")
    func namesWholePath() {
        #expect(WorkspaceGit.commandNames("git -C /x/iris status", "/x/iris"))
        #expect(WorkspaceGit.commandNames("cd /x/iris/sub && git status", "/x/iris"))
        #expect(WorkspaceGit.commandNames("git -C '/x/iris' log", "/x/iris"))
        #expect(!WorkspaceGit.commandNames("git -C /x/iris-overseer status", "/x/iris"))
        #expect(!WorkspaceGit.commandNames("ls /x/iris2", "/x/iris"))
    }

    @Test("a baseline submodule whose pointer the VM redirects is moved aside")
    func redirectedSubmodule() async throws {
        let (dir, _, _) = try await repoWithSubmodule()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [ws])
        #expect(guardian.check(owner: "c") == nil, "an existing submodule left alone stays untouched")
        try "gitdir: \(dir)/elsewhere/.git\n".write(toFile: ws + "/lib/sub/.git", atomically: false, encoding: .utf8)
        #expect(guardian.check(owner: "c")?.contains("lib/sub/.git") == true)
        #expect(FileManager.default.fileExists(atPath: ws + "/lib/sub/.git.iris-quarantine"))
    }

    @Test("a git submodule add in the VM has its pointer and its module repository moved aside")
    func submoduleAddInVM() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        try await GitFixture.sh("git init -q ../sub && git -C ../sub commit -q --allow-empty -m s", in: ws, env: env)
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [ws])
        try await GitFixture.sh("git -c protocol.file.allow=always submodule add -q ../sub added", in: ws, env: env)
        let notice = try #require(guardian.check(owner: "c"))
        #expect(notice.contains("added/.git"))
        #expect(notice.contains("submodule repository"))
        #expect(notice.contains("submodule.added.url"), "its keys in the root config are put back too")
        #expect(FileManager.default.fileExists(atPath: ws + "/added/.git.iris-quarantine"))
        #expect(FileManager.default.fileExists(atPath: ws + "/.git/modules/added.iris-quarantine/HEAD"))
        #expect(!FileManager.default.fileExists(atPath: ws + "/.git/modules/added"))
        #expect(guardian.check(owner: "c") == nil, "said once")
    }

    @Test("a plain nested clone with no index entry is left alone")
    func nestedClone() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [ws])
        try await GitFixture.sh("git init -q vendor/lib && git -C vendor/lib commit -q --allow-empty -m v", in: ws, env: env)
        #expect(guardian.check(owner: "c") == nil)
        #expect(FileManager.default.fileExists(atPath: ws + "/vendor/lib/.git/HEAD"))
    }

    @Test("an index Iris cannot read fails closed: nothing moved or deleted, host commands refused until it reads")
    func malformedIndex() async throws {
        let (dir, _, _) = try await repoWithSubmodule()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [ws])
        let index = try #require(GitFixture.read(ws + "/.git/index"))
        try Data(index.prefix(40)).write(to: URL(fileURLWithPath: ws + "/.git/index"))
        #expect(guardian.check(owner: "c")?.contains("too large or malformed") == true)
        #expect(guardian.hostRefusal(cwd: ws, command: "git status") != nil)
        #expect(FileManager.default.fileExists(atPath: ws + "/lib/sub/.git"), "nothing moved")
        #expect(GitFixture.read(ws + "/.git/index")?.count == 40, "nothing rewritten")
        try index.write(to: URL(fileURLWithPath: ws + "/.git/index"))
        #expect(guardian.check(owner: "c") == nil)
        #expect(guardian.hostRefusal(cwd: ws, command: "git status") == nil)
    }

    @Test("a second watch of a folder keeps the first one's record, so a background write is never its baseline")
    func secondWatchSharesRecord() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let config = ws + "/.git/config"
        let before = try #require(GitFixture.read(config))
        let bad = String(decoding: before, as: UTF8.self) + "[core]\n\tfsmonitor = x\n"
        let guardian = GitConfigGuard()
        guardian.watch(owner: "a", sources: [ws])
        try bad.write(toFile: config, atomically: false, encoding: .utf8)
        guardian.watch(owner: "b", sources: [ws])    // another conversation, while the write stands
        #expect(guardian.check(owner: "b")?.contains("core.fsmonitor") == true)
        #expect(GitFixture.read(config) == before)
        #expect(guardian.check(owner: "a") == nil, "already clean for both")
        // One ending leaves the folder watched for the other.
        guardian.end(owner: "a")
        try bad.write(toFile: config, atomically: false, encoding: .utf8)
        #expect(guardian.check(owner: "b")?.contains("core.fsmonitor") == true)
        #expect(GitFixture.read(config) == before)
    }

    @Test("a repository the VM makes mid-session is judged at the next check")
    func repoMadeMidSession() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let plain = dir + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [plain])
        #expect(guardian.check(owner: "c") == nil)
        try await GitFixture.sh("git init -q && git config filter.x.clean \(dir)/evil", in: plain, env: env)
        guardian.watch(owner: "c", sources: [plain])
        #expect(guardian.check(owner: "c")?.contains("filter.x.clean") == true)
        #expect(guardian.hostRefusal(cwd: plain, command: "") != nil)
    }

    @Test("the session path checks around each in-VM command and says what it put back")
    func sessionPath() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let config = ws + "/.git/config"
        let before = try #require(GitFixture.read(config))
        let runtime = WritingRuntime()
        runtime.onExec = { _ in
            try? (String(decoding: before, as: UTF8.self) + "[core]\n\tfsmonitor = ./x\n").write(toFile: config, atomically: false, encoding: .utf8)
        }
        let guardian = GitConfigGuard()
        let manager = SandboxSessionManager(runtime: runtime, image: { "img" }, startContainerSystem: { true },
                                            live: LiveContainerNames(), gitGuard: guardian)
        let result = await manager.run(command: "x", conversationId: UUID(), workspace: ContainerMount(source: ws))
        #expect(result.hasPrefix("ran"))
        #expect(result.contains("core.fsmonitor"))
        #expect(GitFixture.read(config) == before)
        #expect(runtime.mounts.first?.contains("\(ws)/.git/hooks:\(ws)/.git/hooks:ro") == true)
        #expect(runtime.mounts.first?.contains("\(ws)/.git:\(ws)/.git") == true)
    }
}

/// Serialized, like the suite above: each test starts dozens of real git processes, and run all at
/// once they held the pool long enough for other suites' 5 s Vibecop bound to miss.
/// The host side: git run by a host `run_command` in a sandboxed workspace with the keys that run
/// programs overridden. Each poisons the repository's own config, runs the real git with the
/// overrides, and checks the poisoned program never ran.
@Suite("Host git in a sandboxed workspace runs with overrides (#623)", .serialized, .timeLimit(.minutes(1)))
struct GitHostOverrideTests {
    /// A repo, an `evil` script that leaves a marker when run, and the override environment.
    private func setUp() async throws -> (dir: String, ws: String, env: [String: String], marker: String) {
        let (dir, base) = try await GitFixture.repo()
        let marker = dir + "/RAN"
        let evil = dir + "/evil"
        try "#!/bin/sh\ntouch \(marker)\nexit 0\n".write(toFile: evil, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evil)
        try FileManager.default.createDirectory(atPath: dir + "/evilhooks", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: evil, toPath: dir + "/evilhooks/pre-commit")
        let env = base.merging(WorkspaceGit.hostEnvironment(hooks: dir + "/ws/.git/hooks", personal: [:])) { $1 }
        return (dir, dir + "/ws", env, marker)
    }

    private func ran(_ marker: String) -> Bool { FileManager.default.fileExists(atPath: marker) }

    @Test("the host git is 2.31 or later, which reads GIT_CONFIG_COUNT; an older one would ignore every override")
    func gitVersion() async throws {
        let dir = try GitFixture.temp("ver")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = try await GitFixture.sh("git --version", in: dir, env: GitFixture.environment(home: dir)).out
        let numbers = out.split(separator: " ").dropFirst(2).first?.split(separator: ".").compactMap { Int($0) } ?? []
        #expect(numbers.count >= 2 && (numbers[0], numbers[1]) >= (2, 31), "git too old for the overrides: \(out)")
    }

    @Test("core.hooksPath: a repository's hooks elsewhere do not run; its own read-only hooks still do")
    func hooksPath() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config core.hooksPath \(dir)/evilhooks", in: ws, env: env)
        try await GitFixture.sh("echo b > f && git commit -qam two", in: ws, env: env)
        #expect(!ran(marker))
        try "#!/bin/sh\ntouch \(dir)/OWN\n".write(toFile: ws + "/.git/hooks/pre-commit", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ws + "/.git/hooks/pre-commit")
        try await GitFixture.sh("echo c > f && git commit -qam three", in: ws, env: env)
        #expect(FileManager.default.fileExists(atPath: dir + "/OWN"), "the repository's own hooks keep working")
    }

    @Test("core.fsmonitor does not run on status")
    func fsmonitor() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config core.fsmonitor \(dir)/evil", in: ws, env: env.filter { !$0.key.hasPrefix("GIT_CONFIG_") })
        try await GitFixture.sh("git status", in: ws, env: env.filter { !$0.key.hasPrefix("GIT_CONFIG_") })
        #expect(ran(marker), "control: without the overrides the poisoned fsmonitor runs")
        try FileManager.default.removeItem(atPath: marker)
        try await GitFixture.sh("git status", in: ws, env: env)
        #expect(!ran(marker))
    }

    @Test("diff.external does not run, and git diff still shows the change")
    func diffExternal() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config diff.external \(dir)/evil && echo changed > f", in: ws, env: env)
        let out = try await GitFixture.sh("git diff", in: ws, env: env).out
        #expect(!ran(marker))
        #expect(out.contains("+changed"), "\(out)")
    }

    @Test("credential.helper from the repository does not run; the person's own helper is kept after it")
    func credentialHelper() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config credential.helper '!\(dir)/evil'", in: ws, env: env)
        try await GitFixture.sh("printf 'protocol=https\\nhost=x.invalid\\n\\n' | GIT_TERMINAL_PROMPT=0 git credential fill", in: ws, env: env)
        #expect(!ran(marker))
        let mine = WorkspaceGit.hostEnvironment(hooks: "/dev/null", personal: ["credential.helper": ["osxkeychain"]])
        let helpers = try await GitFixture.sh("git config --get-all credential.helper", in: ws, env: env.merging(mine) { $1 }).out
        #expect(helpers.split(separator: "\n", omittingEmptySubsequences: false).suffix(2).first == "osxkeychain",
                "the person's helper is read after the reset: \(helpers.debugDescription)")
    }

    @Test("an ext:: remote is refused even when the repository allows it")
    func extProtocol() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config protocol.ext.allow always", in: ws, env: env)
        try await GitFixture.sh("git ls-remote 'ext::sh -c touch% \(marker)'", in: ws, env: env)
        #expect(!ran(marker))
    }

    @Test("core.sshCommand does not run on a fetch over ssh")
    func sshCommand() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config core.sshCommand \(dir)/evil", in: ws, env: env)
        try await GitFixture.sh("GIT_TERMINAL_PROMPT=0 git ls-remote ssh://git@127.0.0.1:1/x", in: ws, env: env)
        #expect(!ran(marker))
    }

    @Test("gpg.program does not run on a signed commit")
    func gpgProgram() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config gpg.program \(dir)/evil && git config gpg.ssh.program \(dir)/evil && git config gpg.x509.program \(dir)/evil", in: ws, env: env)
        // The override names resolve to stubs that refuse, so no real signer starts an agent.
        let stubs = dir + "/stubs"
        try FileManager.default.createDirectory(atPath: stubs, withIntermediateDirectories: true)
        for name in ["gpg", "gpgsm", "ssh-keygen"] {
            try "#!/bin/sh\ntouch \(dir)/STUB-\(name)\nexit 1\n".write(toFile: stubs + "/" + name, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubs + "/" + name)
        }
        var stubbed = env
        stubbed["PATH"] = stubs + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        for format in ["openpgp", "ssh", "x509"] {
            try await GitFixture.sh("echo \(format) > f && git -c gpg.format=\(format) -c user.signingkey=k commit -S -qam s", in: ws, env: stubbed)
        }
        #expect(!ran(marker))
        for name in ["gpg", "gpgsm", "ssh-keygen"] {
            #expect(FileManager.default.fileExists(atPath: dir + "/STUB-" + name), "the override's \(name) ran in its place")
        }
    }

    @Test("gpg.ssh.defaultKeyCommand, interactive.diffFilter and core.gitProxy from the repository do not run")
    func moreKeys() async throws {
        let (dir, ws, env, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config gpg.ssh.defaultKeyCommand \(dir)/evil && echo k > f && git -c gpg.format=ssh commit -S -qam s",
                                in: ws, env: env)
        #expect(!ran(marker), "defaultKeyCommand")
        try await GitFixture.sh("git config --unset gpg.ssh.defaultKeyCommand; git config interactive.diffFilter \(dir)/evil && echo d > f && printf 'q\\n' | git -c color.ui=always add -p",
                                in: ws, env: env)
        #expect(!ran(marker), "diffFilter")
        try await GitFixture.sh("git config --unset interactive.diffFilter; git config core.gitProxy \(dir)/evil && git ls-remote git://127.0.0.1:1/x",
                                in: ws, env: env)
        #expect(!ran(marker), "gitProxy")
        // Controls: each one runs without the overrides, so the checks above prove something.
        let bare = env.filter { !$0.key.hasPrefix("GIT_CONFIG_") && $0.key != "GIT_PROXY_COMMAND" }
        try await GitFixture.sh("git ls-remote git://127.0.0.1:1/x", in: ws, env: bare)
        #expect(ran(marker), "control: gitProxy runs without the overrides")
        try FileManager.default.removeItem(atPath: marker)
        try await GitFixture.sh("git config --unset core.gitProxy; git config interactive.diffFilter \(dir)/evil && printf 'q\\n' | git -c color.ui=always add -p",
                                in: ws, env: bare)
        #expect(ran(marker), "control: diffFilter runs without the overrides")
    }

    @Test("the pager and editors are the overrides, whatever the repository says")
    func pagerAndEditors() async throws {
        let (dir, ws, env, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git config core.pager \(dir)/evil && git config core.editor \(dir)/evil && git config sequence.editor \(dir)/evil && git config core.askPass \(dir)/evil && git config core.alternateRefsCommand \(dir)/evil",
                                in: ws, env: env)
        var clean = env
        clean["GIT_PAGER"] = nil
        #expect(try await GitFixture.sh("git var GIT_PAGER", in: ws, env: env).out == "cat\n")
        #expect(try await GitFixture.sh("git var GIT_PAGER", in: ws, env: clean).out == "cat\n", "core.pager alone, without GIT_PAGER")
        #expect(try await GitFixture.sh("git var GIT_EDITOR", in: ws, env: env.filter { $0.key != "EDITOR" && $0.key != "VISUAL" }).out == "true\n")
        #expect(try await GitFixture.sh("git config --get sequence.editor", in: ws, env: env).out == "true\n")
        #expect(try await GitFixture.sh("git config --get core.askPass", in: ws, env: env).out == "\n")
        #expect(try await GitFixture.sh("git config --get core.alternateRefsCommand", in: ws, env: env).out == "\n")
    }

    @Test("a key the person set globally keeps their value; the rest take the override")
    func personal() {
        let listing = "system\tcredential.helper=osxkeychain\nglobal\tgpg.ssh.program=/Applications/1Password.app/op-ssh-sign\nglobal\tcore.editor=vim\nlocal\tcore.fsmonitor=./evil\ncommand\tcore.pager=x\n"
        let values = WorkspaceGit.personalValues(listing: listing, trustGlobal: true)
        #expect(values == ["credential.helper": ["osxkeychain"], "gpg.ssh.program": ["/Applications/1Password.app/op-ssh-sign"], "core.editor": ["vim"]])
        #expect(WorkspaceGit.personalValues(listing: listing, trustGlobal: false) == ["credential.helper": ["osxkeychain"]],
                "a global config in a folder the VM can write is not the person's")
        let env = WorkspaceGit.hostEnvironment(hooks: "/h", personal: values)
        let pairs = (0..<Int(env["GIT_CONFIG_COUNT"]!)!).map { (env["GIT_CONFIG_KEY_\($0)"]!, env["GIT_CONFIG_VALUE_\($0)"]!) }
        #expect(pairs.contains { $0 == ("core.editor", "vim") })
        #expect(pairs.contains { $0 == ("core.hooksPath", "/h") })
        #expect(pairs.contains { $0 == ("core.fsmonitor", "false") })
        #expect(pairs.filter { $0.0 == "credential.helper" }.map(\.1) == ["", "osxkeychain"])
    }

    @Test("a host run_command in a watched workspace runs git with the overrides even after it writes the config itself")
    func hostRunCommand() async throws {
        let (dir, ws, base, marker) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = base
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [ws])
        var executor = ToolExecutor()
        executor.gitGuard = guardian
        let result = await executor.runCommand("git config core.fsmonitor \(dir)/evil && git status --short && echo done",
                                               cwd: ws, timeoutSeconds: 30)
        #expect(result.contains("done"), "\(result)")
        #expect(!ran(marker), "the tampered config was read with the override in force")
        // And the next check puts the host's own write back, saying so.
        #expect(guardian.checkAll()?.contains("core.fsmonitor") == true)

        // A workspace no VM mounts is left alone.
        let other = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: other.dir) }
        let plain = await executor.runCommand("echo ${GIT_CONFIG_COUNT:-none}", cwd: other.dir + "/ws", timeoutSeconds: 30)
        #expect(plain.hasPrefix("none"), "\(plain)")
    }

    @Test("the overrides follow the conversation, a linked worktree and a named folder, not only the working directory")
    func coverage() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await GitFixture.sh("git worktree add -q ../wt", in: dir + "/ws", env: env)
        let ws = dir + "/ws"
        let owner = SandboxSessionManager.containerName(for: UUID())
        let guardian = GitConfigGuard()
        guardian.watch(owner: owner, sources: [ws])
        #expect(guardian.hostOverrides(cwd: dir + "/wt") == .some(ws + "/.git/hooks"), "a worktree reading the same config")
        #expect(guardian.hostOverrides(cwd: "/", command: "git -C \(ws) status") == .some(ws + "/.git/hooks"))
        #expect(guardian.hostOverrides(cwd: "/", owner: owner) == .some(ws + "/.git/hooks"), "the conversation's own watch")
        #expect(guardian.hostOverrides(cwd: "/", owner: "other") == nil)

        // End to end: `git -C <ws>` from another folder, in the conversation, runs with them.
        let marker = dir + "/RAN"
        try "#!/bin/sh\ntouch \(marker)\n".write(toFile: dir + "/evil", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir + "/evil")
        var executor = ToolExecutor()
        executor.gitGuard = guardian
        let id = UUID()
        guardian.watch(owner: SandboxSessionManager.containerName(for: id), sources: [ws])
        let result = await executor.runCommand("git -C ws config core.fsmonitor \(dir)/evil && git -C ws status --short; echo done",
                                               cwd: dir, conversationId: id, timeoutSeconds: 30)
        #expect(result.contains("done"), "\(result)")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("a repository the VM made itself gets no trusted hooks folder")
    func untrustedHooks() async throws {
        let dir = try GitFixture.temp("init")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let guardian = GitConfigGuard()
        guardian.watch(owner: "c", sources: [dir])
        try await GitFixture.sh("git init -q", in: dir, env: GitFixture.environment(home: dir))
        #expect(guardian.hostOverrides(cwd: dir) == .some(nil), "overrides on, hooks to /dev/null")
        #expect(guardian.hostOverrides(cwd: "/") == nil)
    }
}

@Suite("The saved list of sandboxed folders fails closed when it cannot be read (#641)", .serialized, .timeLimit(.minutes(1)))
struct GitGuardStoreTests {
    private func setUp() async throws -> (dir: String, store: URL, outside: String) {
        let (dir, _) = try await GitFixture.repo()
        let store = URL(fileURLWithPath: dir + "/home/sandbox-workspaces.json")
        try FileManager.default.createDirectory(atPath: dir + "/home", withIntermediateDirectories: true)
        let outside = dir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        return (dir, store, outside)
    }

    private func entry(_ path: String, hooks: String?) -> String {
        "{\"path\":\"\(path)\"" + (hooks.map { ",\"hooks\":\"\($0)\"" } ?? "") + "}"
    }

    @Test("one entry that does not decode is skipped, the rest kept, and the list as it was is kept aside")
    func badEntry() async throws {
        let (dir, store, outside) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original = Data(("[" + entry(dir + "/ws", hooks: dir + "/ws/.git/hooks") + ",{\"hooks\":3},"
                             + entry(dir + "/plain", hooks: nil) + "]").utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        #expect(guardian.hostOverrides(cwd: dir + "/ws") == .some(dir + "/ws/.git/hooks"), "a good entry is kept")
        #expect(guardian.hostOverrides(cwd: dir + "/plain") == .some(nil))
        #expect(guardian.hostOverrides(cwd: outside) == .some(nil), "fails closed: overrides, no hooks, everywhere")
        #expect(guardian.watchedSources() == ["/"], "the person's global config counts as reachable")
        #expect(GitFixture.read(store.path + ".corrupt") == original)
        let note = try #require(guardian.checkAll())
        #expect(note.contains("1 of the 3"))
        #expect(note.contains(store.path + ".corrupt"))
        #expect(guardian.checkAll() == nil, "said once")
    }

    @Test("a truncated list is moved aside, every folder counts as unknown, and a watch covers its folder again")
    func truncated() async throws {
        let (dir, store, outside) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let whole = "[" + entry(dir + "/ws", hooks: dir + "/ws/.git/hooks") + "]"
        let original = Data(whole.prefix(whole.count / 2).utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        #expect(!FileManager.default.fileExists(atPath: store.path), "moved, not left to be written over")
        #expect(GitFixture.read(store.path + ".corrupt") == original)
        #expect(guardian.hostOverrides(cwd: outside) == .some(nil))
        #expect(guardian.hostOverrides(cwd: dir + "/ws") == .some(nil), "no hooks until a watch sees it again")
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        let note = try #require(guardian.check(owner: "c"))
        #expect(note.contains("moved it to \(store.path).corrupt"))
        #expect(note.contains("Delete \(store.path).corrupt to end this"))
        #expect(guardian.hostOverrides(cwd: dir + "/ws") == .some(nil), "adopted: watched again, but its hooks never run")
    }

    @Test("an entry from a newer format, with fields this build does not know, is not a failure")
    func newerFormat() async throws {
        let (dir, store, outside) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(("[{\"path\":\"\(dir)/ws\",\"hooks\":\"\(dir)/ws/.git/hooks\",\"baseline\":{\"x\":1},"
                  + "\"blocked\":{\"kind\":\"quarantine\",\"path\":\"\(dir)/gone\",\"message\":\"m\",\"since\":5}}]").utf8).write(to: store)

        let guardian = GitConfigGuard(store: store)
        #expect(guardian.hostOverrides(cwd: dir + "/ws") == .some(dir + "/ws/.git/hooks"))
        #expect(guardian.hostOverrides(cwd: outside) == nil, "nothing unknown: ordinary git is untouched")
        #expect(!FileManager.default.fileExists(atPath: store.path + ".corrupt"))
        #expect(guardian.checkAll() == nil, "no notice; the cleared block ends quietly")
    }

    @Test("after an unreadable list, the next save leaves the set-aside copies alone and takes a free name")
    func saveKeepsCorrupt() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let earlier = Data("earlier".utf8)
        try earlier.write(to: URL(fileURLWithPath: store.path + ".corrupt"))
        let original = Data("{not json".utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        guardian.end(owner: "c")
        #expect(GitFixture.read(store.path + ".corrupt") == earlier, "an earlier copy is never overwritten")
        #expect(GitFixture.read(store.path + ".corrupt-2") == original)
        let saved = try #require(GitFixture.read(store.path))
        #expect(saved != original)
        let later = GitConfigGuard(store: store)
        #expect(later.hostOverrides(cwd: dir + "/ws") == .some(nil), "the new list holds the folder, still adopted")
        #expect(later.checkAll()?.contains("Delete \(store.path).corrupt and \(store.path).corrupt-2 to end this") == true,
                "said again at the next launch")
    }

    @Test("a list that cannot be moved aside is never written over")
    func cannotMoveAside() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for n in 1...100 {
            try Data().write(to: URL(fileURLWithPath: store.path + ".corrupt" + (n == 1 ? "" : "-\(n)")))
        }
        let original = Data("[{".utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        guardian.watch(owner: "c", sources: [dir + "/ws"])
        let note = try #require(guardian.check(owner: "c"))
        #expect(note.contains("left it as it is"))
        #expect(GitFixture.read(store.path) == original)
    }

    @Test("a list with an unreadable entry that cannot be copied aside is never written over")
    func cannotCopyAside() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for n in 1...100 {
            try Data().write(to: URL(fileURLWithPath: store.path + ".corrupt" + (n == 1 ? "" : "-\(n)")))
        }
        let original = Data(("[" + entry(dir + "/ws", hooks: dir + "/ws/.git/hooks") + ",{\"hooks\":3}]").utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        guardian.watch(owner: "c", sources: [dir + "/plain"])
        guardian.end(owner: "c")
        #expect(GitFixture.read(store.path) == original, "the bad entry's only copy is kept")
    }

    /// A list that is lost, so the next watch adopts its folder.
    private func lostList(_ store: URL) throws { try Data("[{".utf8).write(to: store) }

    private func ran(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("RAN-") }.sorted()
    }

    /// Drivers of every kind the VM could have planted before the restart, with a git script that
    /// reaches each one: filters (clean, smudge, process), diff (textconv, command), a merge
    /// driver, a `!` submodule update, difftool and mergetool commands, a tar command, a `!` alias.
    private func plant(_ dir: String, ws: String, env: [String: String]) async throws -> String {
        let evil = dir + "/evil"
        try "#!/bin/sh\ntouch \(dir)/RAN-$1\ncat\n".write(toFile: evil, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: evil)
        let sub = dir + "/sub-" + (ws as NSString).lastPathComponent
        let setUp = """
        git init -q \(sub) && git -C \(sub) -c user.email=a@b -c user.name=a commit -q --allow-empty -m1 &&
        git -C \(sub) -c user.email=a@b -c user.name=a commit -q --allow-empty -m2 &&
        printf '*.x filter=f diff=d merge=m\\n*.p filter=p\\n' > .gitattributes && echo a > a.x && echo a > b.p && echo a > g &&
        git -c protocol.file.allow=always submodule -q add \(sub) s && git add -A && git commit -qm base &&
        git checkout -qb side && echo side > a.x && echo side > g && git commit -qam side && git checkout -q - &&
        echo main > a.x && echo main > g && git commit -qam main && git -C s checkout -q HEAD~1 &&
        git config filter.f.clean '\(evil) clean' && git config filter.f.smudge '\(evil) smudge' && git config filter.f.required true &&
        git config filter.p.process '\(evil) process' &&
        git config diff.d.textconv '\(evil) textconv' && git config diff.d.command '\(evil) command' &&
        git config merge.m.driver '\(evil) merge' && git config submodule.s.update '!\(evil) subupdate' &&
        git config difftool.dd.cmd '\(evil) difftool' && git config mergetool.mm.cmd '\(evil) mergetool' &&
        git config tar.foo.command '\(evil) tar' && git config alias.zz '!\(evil) alias'
        """
        let r = try await GitFixture.sh(setUp, in: ws, env: env)
        #expect(r.status == 0, "\(r.out)")
        return """
        echo d > a.x; echo d > b.p; git status --short; git diff; git diff --textconv --no-ext-diff; git add a.x b.p;
        echo z > a.x; echo z > b.p; git checkout -- a.x b.p; git archive --format=foo HEAD; git difftool -y -t dd HEAD~1 HEAD -- g; git zz;
        git -c protocol.file.allow=always submodule update s; git stash -q; git merge side -m mm; git mergetool -y -t mm g; echo done
        """
    }

    @Test("a folder first watched after the list was lost runs none of the drivers its config planted in host run_command")
    func adoptedDriversDontRun() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = GitFixture.environment(home: dir + "/home")

        // Control: the same script with no guard reaches every planted program.
        let control = dir + "/control"
        try FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true)
        try await GitFixture.sh("git init -q && git config user.email a@b && git config user.name a && echo a > f && git add f && git commit -qm i",
                                in: control, env: env)
        let script = try await plant(dir, ws: control, env: env)
        _ = try await GitFixture.sh(script, in: control, env: env)
        let all = ["RAN-alias", "RAN-clean", "RAN-command", "RAN-difftool", "RAN-merge", "RAN-mergetool", "RAN-process",
                   "RAN-smudge", "RAN-subupdate", "RAN-tar", "RAN-textconv"]
        #expect(ran(dir) == all, "the script reaches every driver")
        for name in ran(dir) { try FileManager.default.removeItem(atPath: dir + "/" + name) }

        let ws = dir + "/ws"
        let script2 = try await plant(dir, ws: ws, env: env)
        try lostList(store)
        let guardian = GitConfigGuard(store: store)
        guardian.watch(owner: "c", sources: [ws])
        let note = try #require(guardian.check(owner: "c"))
        #expect(note.contains("filter.f.clean") && note.contains("alias.zz"), "names what it found: \(note)")
        #expect(note.contains("not protected"))
        var executor = ToolExecutor()
        executor.gitGuard = guardian
        let result = await executor.runCommand(script2, cwd: ws, timeoutSeconds: 60)
        #expect(result.contains("done"), "\(result)")
        #expect(ran(dir) == [], "nothing planted ran")
        #expect(guardian.hostRefusal(cwd: ws, command: "git status") == nil, "neutralised, not refused")
    }

    @Test("git-lfs's exact values are kept; any other value under filter.lfs is neutralised")
    func lfsExemption() async throws {
        let (dir, _, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = GitFixture.environment(home: dir + "/home")
        let ws = dir + "/ws"
        try await GitFixture.sh("""
            git config filter.lfs.clean 'git-lfs clean -- %f' && git config filter.lfs.smudge 'git-lfs smudge -- %f' &&
            git config filter.lfs.process 'git-lfs filter-process' && git config filter.lfs.required true
            """, in: ws, env: env)
        #expect(WorkspaceGit.adopted(source: ws).overrides.isEmpty, "LFS as git-lfs writes it works in Iris's git")
        try await GitFixture.sh("git config filter.lfs.clean '\(dir)/evil clean'", in: ws, env: env)
        let changed = WorkspaceGit.adopted(source: ws).overrides.map { "\($0.key)=\($0.value)" }
        #expect(changed == ["filter.lfs.clean=", "filter.lfs.required=false"])
    }

    @Test("an include or a key no override can stop refuses host commands there until it is removed")
    func adoptedRefusals() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = GitFixture.environment(home: dir + "/home")
        let ws = dir + "/ws"
        try await GitFixture.sh("git config include.path \(dir)/inc && git config remote.o.uploadpack \(dir)/evil", in: ws, env: env)
        try lostList(store)
        let guardian = GitConfigGuard(store: store)
        guardian.watch(owner: "c", sources: [ws])
        let note = try #require(guardian.check(owner: "c"))
        #expect(note.contains("include.path, remote.o.uploadpack"), "\(note)")
        let refusal = try #require(guardian.hostRefusal(cwd: ws, command: "git status"))
        #expect(refusal.contains("remove them from \(ws)/.git/config to end this"), "\(refusal)")
        #expect(GitConfigGuard(store: store).hostRefusal(cwd: ws, command: "") != nil, "still refused after a restart")
        try await GitFixture.sh("git config --unset include.path && git config --unset remote.o.uploadpack", in: ws, env: env)
        _ = guardian.checkAll()
        #expect(guardian.hostRefusal(cwd: ws, command: "") == nil, "a clean check clears it")
    }

    @Test("an adopted folder stays adopted across a restart, and deleting the copies ends it at the next launch")
    func adoptedSurvivesRestart() async throws {
        let (dir, store, outside) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = GitFixture.environment(home: dir + "/home")
        let ws = dir + "/ws"
        try await GitFixture.sh("git config diff.d.textconv \(dir)/evil", in: ws, env: env)
        try lostList(store)
        let first = GitConfigGuard(store: store)
        first.watch(owner: "c", sources: [ws])
        first.end(owner: "c")

        let second = GitConfigGuard(store: store)
        #expect(second.hostOverrides(cwd: ws) == .some(nil), "its hooks still never run")
        #expect(second.adoptedOverrides(cwd: ws).map(\.key) == ["diff.d.textconv"], "its drivers still neutralised")
        #expect(second.hostOverrides(cwd: outside) == .some(nil), "fail-closed while the copy is kept")
        #expect(second.checkAll()?.contains("Delete \(store.path).corrupt to end this") == true, "said once per launch")
        #expect(second.checkAll() == nil)

        try FileManager.default.removeItem(atPath: store.path + ".corrupt")
        let third = GitConfigGuard(store: store)
        #expect(third.hostOverrides(cwd: ws) == .some(ws + "/.git/hooks"), "trusted once the copy is deleted")
        #expect(third.adoptedOverrides(cwd: ws).isEmpty)
        #expect(third.hostOverrides(cwd: outside) == nil, "fail-closed ended")
        #expect(third.checkAll() == nil, "nothing to say")
    }
}
