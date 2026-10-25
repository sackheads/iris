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

    @Test("a remote, an upstream and user.* may change; anything that can run a program may not")
    func allowList() {
        #expect(GitConfigFile.isAllowed(key: "remote.up.url", values: ["https://github.com/a/b.git"]))
        #expect(GitConfigFile.isAllowed(key: "remote.up.pushurl", values: ["git@github.com:a/b.git"]))
        #expect(GitConfigFile.isAllowed(key: "remote.up.fetch", values: ["+refs/heads/*:refs/remotes/up/*"]))
        #expect(GitConfigFile.isAllowed(key: "branch.feature.remote", values: ["up"]))
        #expect(GitConfigFile.isAllowed(key: "branch.feature.merge", values: ["refs/heads/feature"]))
        #expect(GitConfigFile.isAllowed(key: "user.email", values: ["a@b"]))
        #expect(GitConfigFile.isAllowed(key: "user.name", values: ["a name"]))

        let disallowed: [(String, [String])] = [
            ("core.hookspath", ["/tmp/h"]),
            ("core.bare", ["true"]),
            ("core.fsmonitor", ["./x"]),
            ("include.path", ["../x"]),
            ("includeif.gitdir:/.path", ["../x"]),
            ("filter.lfs.clean", ["x"]),
            ("remote.o.uploadpack", ["x"]),
            ("remote.o.vcs", ["x"]),
            ("user.name", ["\u{0}"]),
        ]
        for (key, values) in disallowed {
            #expect(!GitConfigFile.isAllowed(key: key, values: values), "\(key)")
        }
    }

    @Test("a URL that names a transport helper or reads as an option is not allowed")
    func urls() {
        for url in ["ext::sh -c touch% /tmp/x", "fd::3", "foo::https://x", "-uhelper", "https://x\u{1}"] {
            #expect(!GitConfigFile.isSafeURL(url), "safe: \(url)")
            #expect(!GitConfigFile.isAllowed(key: "remote.o.url", values: [url]))
            #expect(!GitConfigFile.isAllowed(key: "remote.o.pushurl", values: [url]))
            #expect(!GitConfigFile.isAllowed(key: "branch.m.remote", values: [url]))
        }
        #expect(GitConfigFile.isSafeURL("git@github.com:a/b.git"))
        #expect(GitConfigFile.isSafeURL("../sibling"))
        #expect(!GitConfigFile.isSafeURL("ext::sh"))
    }
}

@Suite("Untrusted repository judging and host git decisions (#658)", .serialized, .timeLimit(.minutes(1)))
struct UntrustedRepositoryTests {
    @Test("1. root git init in mounted folder with risky key is refused; without risky key runs no hooks; notice once")
    func rootInitJudging() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"

        // Marker hook in ws/.git/hooks/pre-commit
        let hookPath = ws + "/.git/hooks/pre-commit"
        try FileManager.default.createDirectory(atPath: ws + "/.git/hooks", withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch \"\(dir)/HOOK_RAN\"\n".write(toFile: hookPath, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        // Add risky key
        try await GitFixture.sh("git config core.fsmonitor /bin/true", in: ws, env: env)
        let d1 = guardian.judgeHostCommand(cwd: ws, command: "git status")
        guard case .refuse(let why, _) = d1 else {
            Issue.record("expected refuse, got \(d1)")
            return
        }
        #expect(why.contains("sets core.fsmonitor"))

        // Remove risky key
        try await GitFixture.sh("git config --unset core.fsmonitor", in: ws, env: env)
        let d2 = guardian.judgeHostCommand(cwd: ws, command: "git commit --allow-empty -m test")
        guard case .noHooks(let notice) = d2 else {
            Issue.record("expected noHooks, got \(d2)")
            return
        }
        #expect(notice?.contains("[sandbox] A repository at \(ws) was created or modified in a sandbox") == true)

        // Notice is said once
        let d3 = guardian.judgeHostCommand(cwd: ws, command: "git status")
        guard case .noHooks(let notice3) = d3 else {
            Issue.record("expected noHooks, got \(d3)")
            return
        }
        #expect(notice3 == nil, "notice should be said only once")

        // Without risky key, it runs with no hooks
        var hostEnv = env
        hostEnv["GIT_CONFIG_COUNT"] = "1"
        hostEnv["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        hostEnv["GIT_CONFIG_VALUE_0"] = "/dev/null"
        let r = try await GitFixture.sh("git commit --allow-empty -m test", in: ws, env: hostEnv)
        #expect(r.status == 0, "\(r.out)")
        #expect(!FileManager.default.fileExists(atPath: dir + "/HOOK_RAN"), "marker hook must not fire")
    }

    @Test("2. nested repository inside mounted repository that has a sandbox copy is judged")
    func nestedRepoJudging() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))

        // Make root repository trusted by seeding its sandbox copy
        let prepared = SandboxGit.prepare(source: ws, target: ws, paths: paths)
        guard case .repo = prepared else {
            Issue.record("failed to prepare root repo: \(prepared)")
            return
        }

        let nested = ws + "/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await GitFixture.sh("git init -q", in: nested, env: env)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        // Root repo is trusted
        let rootDecision = guardian.judgeHostCommand(cwd: ws, command: "git status", paths: paths)
        #expect(rootDecision == .ordinary(notice: nil), "trusted root repo is untouched")

        // Nested repo has no sandbox copy, so it is untrusted
        try await GitFixture.sh("git config diff.external /bin/true", in: nested, env: env)
        let d1 = guardian.judgeHostCommand(cwd: nested, command: "git status", paths: paths)
        guard case .refuse(let why, _) = d1 else {
            Issue.record("expected refuse, got \(d1)")
            return
        }
        #expect(why.contains("sets diff.external"))

        try await GitFixture.sh("git config --unset diff.external", in: nested, env: env)
        let d2 = guardian.judgeHostCommand(cwd: nested, command: "git status", paths: paths)
        guard case .noHooks(let notice) = d2 else {
            Issue.record("expected noHooks, got \(d2)")
            return
        }
        #expect(notice?.contains("[sandbox] A repository at \(nested) was created or modified in a sandbox") == true)
    }

    @Test("3. a walk from a subfolder of the nested repository finds it")
    func walkFromSubfolder() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))

        _ = SandboxGit.prepare(source: ws, target: ws, paths: paths)
        let nested = ws + "/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await GitFixture.sh("git init -q", in: nested, env: env)

        let subfolder = nested + "/deep/sub/dir"
        try FileManager.default.createDirectory(atPath: subfolder, withIntermediateDirectories: true)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        let d = guardian.judgeHostCommand(cwd: subfolder, command: "git status", paths: paths)
        guard case .noHooks = d else {
            Issue.record("expected noHooks from subfolder walk, got \(d)")
            return
        }
    }

    @Test("4. git -C <path> from a working directory outside the mounted folder is judged")
    func gitCFromOutside() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))

        _ = SandboxGit.prepare(source: ws, target: ws, paths: paths)
        let nested = ws + "/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try await GitFixture.sh("git init -q", in: nested, env: env)
        try await GitFixture.sh("git config diff.external /bin/true", in: nested, env: env)

        let outside = dir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        let d1 = guardian.judgeHostCommand(cwd: outside, command: "git -C '\(nested)' status", paths: paths)
        guard case .refuse(let why, _) = d1 else {
            Issue.record("expected refuse, got \(d1)")
            return
        }
        #expect(why.contains("sets diff.external"))

        try await GitFixture.sh("git config --unset diff.external", in: nested, env: env)
        let d2 = guardian.judgeHostCommand(cwd: outside, command: "git -C \(nested) status", paths: paths)
        guard case .noHooks = d2 else {
            Issue.record("expected noHooks, got \(d2)")
            return
        }
    }

    @Test("5. LFS: git-lfs's exact values are not refused; a modified filter.lfs.clean is")
    func lfsExemption() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        try await GitFixture.sh("""
            git config filter.lfs.clean 'git-lfs clean -- %f' &&
            git config filter.lfs.smudge 'git-lfs smudge -- %f' &&
            git config filter.lfs.process 'git-lfs filter-process' &&
            git config filter.lfs.required true
            """, in: ws, env: env)

        let d1 = guardian.judgeHostCommand(cwd: ws, command: "git status")
        guard case .noHooks = d1 else {
            Issue.record("expected noHooks (not refused) for exact LFS values, got \(d1)")
            return
        }

        try await GitFixture.sh("git config filter.lfs.clean '/bin/evil clean'", in: ws, env: env)
        let d2 = guardian.judgeHostCommand(cwd: ws, command: "git status")
        guard case .refuse(let why, _) = d2 else {
            Issue.record("expected refuse for modified filter.lfs.clean, got \(d2)")
            return
        }
        #expect(why.contains("sets filter.lfs.clean"))
    }

    @Test("6. a repository outside every mounted folder is untouched (ordinary)")
    func repoOutsideMountedUntouched() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let outside = dir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try await GitFixture.sh("git init -q", in: outside, env: env)
        try await GitFixture.sh("git config core.fsmonitor /bin/true", in: outside, env: env)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [dir + "/ws"])

        let d = guardian.judgeHostCommand(cwd: outside, command: "git status")
        #expect(d == .ordinary(notice: nil))
    }

    @Test("7. a copy whose marker names a different common dir does not make the repository trusted")
    func markerCommonDirMismatch() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))

        let canonicalCommon = IrisPaths.realPath(ws + "/.git")
        let key = SandboxGit.key(canonicalCommon)
        let copyDir = dir + "/iris-home/sandbox-git/" + key
        try FileManager.default.createDirectory(atPath: copyDir, withIntermediateDirectories: true)
        try Data("/different/repo/.git\n123:456\n".utf8).write(to: URL(fileURLWithPath: copyDir + "/iris-sandbox-seed"))

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        #expect(!GitConfigGuard.isTrusted(commonDir: canonicalCommon, paths: paths))
        let d = guardian.judgeHostCommand(cwd: ws, command: "git status", paths: paths)
        guard case .noHooks = d else {
            Issue.record("expected noHooks (untrusted), got \(d)")
            return
        }
    }

    @Test("8. an unreadable store: repositories outside mounted folders are judged too; deleting .corrupt ends it")
    func unreadableStoreJudgesAll() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = URL(fileURLWithPath: dir + "/home/sandbox-workspaces.json")
        try FileManager.default.createDirectory(atPath: dir + "/home", withIntermediateDirectories: true)

        let outside = dir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try await GitFixture.sh("git init -q", in: outside, env: env)

        // Write corrupt store
        try Data("[{corrupt json".utf8).write(to: store)

        let g1 = GitConfigGuard(store: store)
        #expect(g1.isUnknownFolders)
        let note = try #require(g1.takeLoadNote())
        #expect(note.contains("Delete \(store.path).corrupt to end this"))

        // Risky key in outside repo is refused even though outside was never mounted!
        try await GitFixture.sh("git config core.fsmonitor /bin/true", in: outside, env: env)
        let d1 = g1.judgeHostCommand(cwd: outside, command: "git status")
        guard case .refuse(let why, _) = d1 else {
            Issue.record("expected refuse in outside repo under unknownFolders, got \(d1)")
            return
        }
        #expect(why.contains("sets core.fsmonitor"))

        try await GitFixture.sh("git config --unset core.fsmonitor", in: outside, env: env)
        let d2 = g1.judgeHostCommand(cwd: outside, command: "git status")
        guard case .noHooks = d2 else {
            Issue.record("expected noHooks in outside repo under unknownFolders, got \(d2)")
            return
        }

        // Delete .corrupt and restart
        try FileManager.default.removeItem(atPath: store.path + ".corrupt")
        let g2 = GitConfigGuard(store: store)
        #expect(!g2.isUnknownFolders)
        let d3 = g2.judgeHostCommand(cwd: outside, command: "git status")
        #expect(d3 == .ordinary(notice: nil))
    }

    @Test("10. end to end through ToolExecutor.runCommand on host: hook doesn't run, refused command doesn't run")
    func toolExecutorEndToEnd() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"

        let hookPath = ws + "/.git/hooks/pre-commit"
        try FileManager.default.createDirectory(atPath: ws + "/.git/hooks", withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch \"\(dir)/E2E_HOOK_RAN\"\n".write(toFile: hookPath, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        var executor = ToolExecutor()
        executor.gitGuard = guardian

        // Risky command: refused and doesn't run
        try await GitFixture.sh("git config core.fsmonitor /bin/true", in: ws, env: env)
        let res1 = await executor.runCommand("git commit --allow-empty -m test", cwd: ws)
        #expect(res1.contains("Not run: git on your Mac would read a repository the sandbox left unsafe"))
        #expect(res1.contains("sets core.fsmonitor"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/E2E_HOOK_RAN"))

        // Safe command: runs with no hooks
        try await GitFixture.sh("git config --unset core.fsmonitor", in: ws, env: env)
        let res2 = await executor.runCommand("git commit --allow-empty -m test", cwd: ws)
        #expect(res2.contains("[sandbox] A repository at \(ws) was created or modified in a sandbox"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/E2E_HOOK_RAN"), "hook must not run in untrusted repo")
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

    private func entry(_ path: String) -> String {
        "{\"path\":\"\(path)\"}"
    }

    @Test("one entry that does not decode is skipped, the rest kept, and the list as it was is kept aside")
    func badEntry() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let original = Data(("[" + entry(dir + "/ws") + ",{\"hooks\":3},"
                             + entry(dir + "/plain") + "]").utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        #expect(guardian.mountedWorkspaces == [dir + "/plain", dir + "/ws"].map(IrisPaths.realPath), "good entries kept")
        #expect(guardian.isUnknownFolders, "fails closed: unknown folders active")
        #expect(GitFixture.read(store.path + ".corrupt") == original)
        let note = try #require(guardian.takeLoadNote())
        #expect(note.contains("1 of the 3"))
        #expect(note.contains(store.path + ".corrupt"))
        #expect(guardian.takeLoadNote() == nil, "said once")
    }

    @Test("a truncated list is moved aside, every folder counts as unknown, and a recordMounted covers its folder")
    func truncated() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let whole = "[" + entry(dir + "/ws") + "]"
        let original = Data(whole.prefix(whole.count / 2).utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        #expect(!FileManager.default.fileExists(atPath: store.path), "moved, not left to be written over")
        #expect(GitFixture.read(store.path + ".corrupt") == original)
        #expect(guardian.isUnknownFolders)
        let note = try #require(guardian.takeLoadNote())
        #expect(note.contains("moved it to \(store.path).corrupt"))
        #expect(note.contains("Delete \(store.path).corrupt to end this"))
    }

    @Test("an entry from a newer format, with fields this build does not know, is not a failure")
    func newerFormat() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(("[{\"path\":\"\(dir)/ws\",\"hooks\":\"\(dir)/ws/.git/hooks\",\"baseline\":{\"x\":1},"
                  + "\"blocked\":{\"kind\":\"quarantine\",\"path\":\"\(dir)/gone\",\"message\":\"m\",\"since\":5}}]").utf8).write(to: store)

        let guardian = GitConfigGuard(store: store)
        #expect(guardian.mountedWorkspaces == [IrisPaths.realPath(dir + "/ws")])
        #expect(!guardian.isUnknownFolders)
        #expect(!FileManager.default.fileExists(atPath: store.path + ".corrupt"))
        #expect(guardian.takeLoadNote() == nil)
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
        guardian.recordMounted(sources: [dir + "/ws"])
        #expect(GitFixture.read(store.path + ".corrupt") == earlier, "an earlier copy is never overwritten")
        #expect(GitFixture.read(store.path + ".corrupt-2") == original)
        let saved = try #require(GitFixture.read(store.path))
        #expect(saved != original)
        let later = GitConfigGuard(store: store)
        #expect(later.isUnknownFolders)
        #expect(later.takeLoadNote()?.contains("Delete \(store.path).corrupt and \(store.path).corrupt-2 to end this") == true,
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
        guardian.recordMounted(sources: [dir + "/ws"])
        let note = try #require(guardian.takeLoadNote())
        #expect(note.contains("left it as it is"))
        #expect(GitFixture.read(store.path) == original, "not written over")
    }

    @Test("a list with an unreadable entry that cannot be copied aside is never written over")
    func cannotCopyAside() async throws {
        let (dir, store, _) = try await setUp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for n in 1...100 {
            try Data().write(to: URL(fileURLWithPath: store.path + ".corrupt" + (n == 1 ? "" : "-\(n)")))
        }
        let original = Data(("[" + entry(dir + "/ws") + ",{\"hooks\":3}]").utf8)
        try original.write(to: store)

        let guardian = GitConfigGuard(store: store)
        guardian.recordMounted(sources: [dir + "/plain"])
        #expect(GitFixture.read(store.path) == original, "the bad entry's only copy is kept")
    }
}
