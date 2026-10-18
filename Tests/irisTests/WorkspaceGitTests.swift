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

@Suite("Sandboxed repositories: hooks mounted read-only, config put back (#623)", .timeLimit(.minutes(1)))
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
        #expect(guardian.check(owner: "other")?.contains("diff.external") == true)
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

/// The host side: git run by a host `run_command` in a sandboxed workspace with the keys that run
/// programs overridden. Each poisons the repository's own config, runs the real git with the
/// overrides, and checks the poisoned program never ran.
@Suite("Host git in a sandboxed workspace runs with overrides (#623)", .timeLimit(.minutes(1)))
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
