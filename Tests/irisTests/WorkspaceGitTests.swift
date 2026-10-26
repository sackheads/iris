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

    @Test("what it cannot read in full is nil, so host commands there are refused")
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

        // Without risky key, running through ToolExecutor.runCommand runs with no hooks
        var executor = ToolExecutor()
        executor.gitGuard = guardian
        let out = await executor.runCommand("git commit --allow-empty -m test", cwd: ws)
        #expect(!out.contains("Not run:"), "\(out)")
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

    @Test("9. index parser finds gitlinks in versions 2, 3, 4 and split index; missing sharedindex refuses; planted submodule in untrusted repo is quarantined")
    func indexVersionsSplitIndexAndUntrustedSubmodule() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        try await GitFixture.sh("git init -q ../sub && git -C ../sub commit -q --allow-empty -m s && git -c protocol.file.allow=always submodule add -q ../sub lib/sub && git commit -qm sub",
                                in: ws, env: env)
        for version in [2, 3, 4] {
            let add = version >= 3 ? "echo n > new\(version) && git add -N new\(version) && " : ""
            try await GitFixture.sh(add + "git update-index --index-version \(version)", in: ws, env: env)
            let header = try #require(GitFixture.read(ws + "/.git/index"))
            #expect(header[7] == UInt8(version))
            #expect(WorkspaceGit.gitlinks(index: ws + "/.git/index", sha256: false) == ["lib/sub"], "version \(version)")
        }
        try Data("DIRC garbage".utf8).write(to: URL(fileURLWithPath: dir + "/bad-index"))
        #expect(WorkspaceGit.gitlinks(index: dir + "/bad-index", sha256: false) == nil)
        #expect(WorkspaceGit.gitlinks(index: dir + "/no-index", sha256: false) == [])

        // Planted submodule under a split index in an untrusted repository:
        let plain = dir + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        try await GitFixture.sh("""
            git init -q && git config user.email a@b && git config user.name a && echo x > a && git add a && git commit -qm i
            git init -q \(dir)/evilrepo && git -C \(dir)/evilrepo commit -q --allow-empty -m e && git -C \(dir)/evilrepo config core.fsmonitor /bin/true
            mkdir -p planted && echo "gitdir: \(dir)/evilrepo/.git" > planted/.git && echo y > planted/f
            git update-index --add --cacheinfo 160000,$(git -C \(dir)/evilrepo rev-parse HEAD),planted
            git update-index --split-index
            """, in: plain, env: env)
        let shared = try FileManager.default.contentsOfDirectory(atPath: plain + "/.git").filter { $0.hasPrefix("sharedindex.") }
        #expect(!shared.isEmpty)
        #expect(WorkspaceGit.gitlinks(index: plain + "/.git/index", sha256: false, followLink: false) == nil)
        #expect(Set(WorkspaceGit.gitlinks(index: plain + "/.git/index", sha256: false) ?? []) == ["planted"])

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [plain])
        let d1 = guardian.judgeHostCommand(cwd: plain, command: "git status")
        guard case .noHooks(let notice) = d1 else {
            Issue.record("expected noHooks with quarantined pointer, got \(d1)")
            return
        }
        #expect(notice?.contains("planted/.git") == true && notice?.contains("moved it aside") == true)
        #expect(FileManager.default.fileExists(atPath: plain + "/planted/.git.iris-quarantine"))

        // Missing shared index fails closed:
        for name in shared { try FileManager.default.removeItem(atPath: plain + "/.git/" + name) }
        let d2 = guardian.judgeHostCommand(cwd: plain, command: "git status")
        guard case .refuse(let why, _) = d2 else {
            Issue.record("expected refuse for broken split index, got \(d2)")
            return
        }
        #expect(why.contains("index cannot be read"))
    }

    @Test("H1. parent mount makes repository with sandbox-git copy untrusted")
    func parentMountMakesRepoWithCopyUntrusted() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))

        // Step 1: earlier session mounted ws directly -> creates sandbox-git seed for ws/.git
        _ = SandboxGit.prepare(source: ws, target: ws, paths: paths)

        // Step 2: later session mounts the parent directory `dir` (no .git at `dir`, so no overlay on ws/.git)
        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [dir])

        // Step 3: VM writes core.fsmonitor into ws/.git/config (writable under the parent mount)
        try await GitFixture.sh("git config core.fsmonitor 'touch \(dir)/PWNED'", in: ws, env: env)

        // Step 4: host command in ws MUST refuse, not trust the stale seed
        let decision = guardian.judgeHostCommand(cwd: ws, command: "git status", paths: paths)
        guard case .refuse(let why, _) = decision else {
            Issue.record("expected refuse when parent mount makes .git writable, got \(decision)")
            return
        }
        #expect(why.contains("core.fsmonitor"))
    }

    @Test("H2. commands reaching an untrusted repo without starting in it are judged")
    func commandsReachingRepoWithoutStartingInIt() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let outside = dir + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)

        try await GitFixture.sh("git config core.fsmonitor /bin/true", in: ws, env: env)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        let commands = [
            "cd '\(ws)' && git status",
            #"git --git-dir='\#(ws)/.git' --work-tree='\#(ws)' status"#,
            #"GIT_DIR='\#(ws)/.git' git status"#,
            #"git -c user.name=a -C '\#(ws)' status"#,
            #"echo $(git -C '\#(ws)' status)"#,
        ]
        for cmd in commands {
            let d = guardian.judgeHostCommand(cwd: outside, command: cmd)
            guard case .refuse = d else {
                Issue.record("expected refuse for `\(cmd)`, got \(d)")
                return
            }
        }
    }

    @Test("H3. bare repository created by VM inside mounted folder is judged")
    func bareRepoCreatedByVMIsJudged() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        _ = SandboxGit.prepare(source: ws, target: ws, paths: paths)

        // VM creates a bare repo inside ws with a malicious alias
        try await GitFixture.sh("git init -q --bare evil && git -C evil config alias.st '!touch \(dir)/BARE_PWNED'", in: ws, env: env)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        // Host command run in ws/evil or via git -C ws/evil
        let d1 = guardian.judgeHostCommand(cwd: ws + "/evil", command: "git st", paths: paths)
        let d2 = guardian.judgeHostCommand(cwd: ws, command: "git -C '\(ws)/evil' st", paths: paths)
        guard case .refuse = d1, case .refuse = d2 else {
            Issue.record("expected refuse for bare repo, got d1=\(d1) d2=\(d2)")
            return
        }
    }

    @Test("11. global and system git config in reach set GIT_CONFIG_GLOBAL=/dev/null and GIT_CONFIG_NOSYSTEM=1 without refusing normal commands")
    func globalConfigInMountedHome() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/home"
        let ws = dir + "/ws"
        let prefix = dir + "/prefix"
        try FileManager.default.createDirectory(atPath: prefix + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: prefix + "/etc", withIntermediateDirectories: true)
        let base = ["HOME": home, "XDG_CONFIG_HOME": home + "/.config", "PATH": prefix + "/bin:/usr/bin:/bin"]

        let guardian = GitConfigGuard()
        #expect(!guardian.globalConfigInReach(base: base))
        #expect(!guardian.systemConfigInReach(base: base))

        // Global config outside mount that includes a file inside `ws` (which is mounted)
        try "[include]\n\tpath = \(ws)/extra.gitconfig\n".write(toFile: home + "/.gitconfig", atomically: false, encoding: .utf8)
        guardian.recordMounted(sources: [ws])
        #expect(guardian.globalConfigInReach(base: base), "include.path into mounted folder puts global config in reach")

        // Mounting home directly with normal user settings (core.editor, alias.co) does NOT refuse ls or git status
        guardian.recordMounted(sources: [home, prefix])
        try "[core]\n\teditor = vim\n[alias]\n\tco = checkout\n".write(toFile: home + "/.gitconfig", atomically: false, encoding: .utf8)
        let d1 = guardian.judgeHostCommand(cwd: dir, command: "ls", base: base)
        #expect(d1 != .refuse("", notice: nil))
        if case .refuse(let why, _) = d1 {
            Issue.record("ordinary ~/.gitconfig must not refuse host commands: \(why)")
        }

        var spawned = base
        guardian.applyEnvironment(decision: d1, base: base, to: &spawned)
        #expect(spawned["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(spawned["GIT_CONFIG_NOSYSTEM"] == "1")
    }

    @Test("13. unknownFolders mode refuses pointer problems in outside repositories without renaming files on disk")
    func unknownFoldersDoesNotQuarantineOutsideRepo() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = URL(fileURLWithPath: dir + "/home/sandbox-workspaces.json")
        try Data("[{corrupt".utf8).write(to: store)

        let outside = dir + "/outside"
        try FileManager.default.createDirectory(atPath: outside + "/sub", withIntermediateDirectories: true)
        try await GitFixture.sh("git init -q", in: outside, env: env)
        try await GitFixture.sh("git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,sub", in: outside, env: env)
        let subGit = outside + "/sub/.git"
        try Data("gitdir: /etc/passwd\n".utf8).write(to: URL(fileURLWithPath: subGit))

        let guardian = GitConfigGuard(store: store)
        #expect(guardian.isUnknownFolders)
        let d = guardian.judgeHostCommand(cwd: outside, command: "git status")
        guard case .refuse = d else {
            Issue.record("expected refuse for bad pointer in unknownFolders mode, got \(d)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: subGit), "outside repository's files must not be renamed in unknownFolders mode")
        #expect(!FileManager.default.fileExists(atPath: subGit + ".iris-quarantine"))
    }

    @Test("12. upgrade from old sandbox-workspaces.json with blocked or adopted keeps repository untrusted across saves")
    func upgradeFromBlockedOrAdopted() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        let store = URL(fileURLWithPath: dir + "/home/sandbox-workspaces.json")

        // Even with a sandbox-git seed marker, a legacy blocked/adopted entry must not be trusted
        _ = SandboxGit.prepare(source: ws, target: ws, paths: paths)
        try await GitFixture.sh("git config core.fsmonitor /bin/true", in: ws, env: env)

        let legacyJSON = "[{\"path\":\"\(ws)\",\"hooks\":\"\(ws)/.git/hooks\",\"blocked\":{\"kind\":\"restore\",\"path\":\"\(ws)/.git/config\",\"message\":\"m\"}}]"
        try Data(legacyJSON.utf8).write(to: store)

        let g1 = GitConfigGuard(store: store)
        let d1 = g1.judgeHostCommand(cwd: ws, command: "git status", paths: paths)
        guard case .refuse(let why1, _) = d1 else {
            Issue.record("expected legacy blocked repo to be judged as untrusted and refused, got \(d1)")
            return
        }
        #expect(why1.contains("core.fsmonitor"))

        // Trigger a save() by recording another mount, then reload from store
        let plain = dir + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        g1.recordMounted(sources: [plain])

        let g2 = GitConfigGuard(store: store)
        let d2 = g2.judgeHostCommand(cwd: ws, command: "git status", paths: paths)
        guard case .refuse(let why2, _) = d2 else {
            Issue.record("expected untrusted flag to survive save and reload, got \(d2)")
            return
        }
        #expect(why2.contains("core.fsmonitor"))
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

@Suite("PR 773 review holes", .timeLimit(.minutes(1)))
struct R773HoleTests {
    @Test("H1: parent mount over a repo that has a sandbox-git copy makes .git writable and untrusted")
    func parentMountOverSeededRepo() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        let guardian = GitConfigGuard()

        let prep1 = SandboxGit.prepare(source: ws, target: ws, paths: paths)
        guard case .repo = prep1 else { Issue.record("prep1 failed: \(prep1)"); return }
        guardian.recordMounted(sources: [ws])

        let prep2 = SandboxGit.prepare(source: dir, target: dir, paths: paths)
        #expect(prep2 == .none)
        guardian.recordMounted(sources: [dir])

        try await GitFixture.sh("git config core.fsmonitor 'touch \(dir)/PWNED'", in: ws, env: env)

        let d = guardian.judgeHostCommand(cwd: ws, command: "git status", paths: paths)
        guard case .refuse(let why, _) = d else {
            Issue.record("expected refuse when parent mount exposed .git, got \(d)")
            return
        }
        #expect(why.contains("core.fsmonitor"))
    }

    @Test("H2: host command starting in parent dir and entering mounted repo via cd / GIT_DIR / --git-dir / script")
    func commandReachesMountedRepoWithoutCwdOrGitDashC() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        try await GitFixture.sh("git config core.fsmonitor 'touch \(dir)/PWNED'", in: ws, env: env)

        let dA = guardian.judgeHostCommand(cwd: dir, command: "cd ws && git status", paths: paths)
        let dB = guardian.judgeHostCommand(cwd: dir, command: "GIT_DIR=ws/.git git status", paths: paths)
        let dC = guardian.judgeHostCommand(cwd: dir, command: "git --git-dir=ws/.git status", paths: paths)
        let dD = guardian.judgeHostCommand(cwd: dir, command: "./ws/script.sh", paths: paths)

        guard case .refuse = dA, case .refuse = dB, case .refuse = dC, case .refuse = dD else {
            Issue.record("expected all 4 to refuse: dA=\(dA) dB=\(dB) dC=\(dC) dD=\(dD)")
            return
        }
    }

    @Test("H3: bare repository created in sandbox is judged")
    func bareRepoCreatedInSandbox() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bare = dir + "/plain/bare.git"
        try FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
        try await GitFixture.sh("git init --bare -q", in: bare, env: env)
        try await GitFixture.sh("git config core.fsmonitor 'touch \(dir)/PWNED_BARE'", in: bare, env: env)

        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [dir + "/plain"])

        let d1 = guardian.judgeHostCommand(cwd: bare, command: "git log", paths: paths)
        let d2 = guardian.judgeHostCommand(cwd: dir + "/plain", command: "git -C \(bare) log", paths: paths)
        guard case .refuse = d1, case .refuse = d2 else {
            Issue.record("expected bare repo to refuse: d1=\(d1) d2=\(d2)")
            return
        }
    }

    @Test("H4: end-to-end ToolExecutor.runCommand refuses when host git reaches untrusted repo via cd from parent")
    func endToEndCdIntoMountedRepo() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        let marker = dir + "/PWNED_E2E"
        try await GitFixture.sh("git config core.fsmonitor 'touch \(marker)'", in: ws, env: env)

        let exec = ToolExecutor(irisPaths: paths, gitGuard: guardian)
        _ = await exec.runCommand("cd ws && git status", cwd: dir, useSandbox: false)

        #expect(!FileManager.default.fileExists(atPath: marker), "core.fsmonitor executed on host via `cd ws && git status`!")
    }
}

@Suite("PR 773 round 2 variants", .timeLimit(.minutes(1)))
struct R773VariantTests {
    @Test("V1-V5: ways a host command from parent dir reaches a mounted repo")
    func variantsReachingMountedRepo() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        try await GitFixture.sh("git config core.fsmonitor 'touch \(dir)/PWNED'", in: ws, env: env)

        let v1 = guardian.judgeHostCommand(cwd: dir, command: "pushd ws && git status", paths: paths)
        let v2 = guardian.judgeHostCommand(cwd: dir, command: "sh -c 'cd ws && git status'", paths: paths)
        let v3 = guardian.judgeHostCommand(cwd: dir, command: "sh -c 'cd ws; git status'", paths: paths)
        let v4 = guardian.judgeHostCommand(cwd: dir, command: "./build.sh", paths: paths)
        let v5 = guardian.judgeHostCommand(cwd: dir, command: "make test", paths: paths)
        let vEnv = guardian.judgeHostCommand(cwd: dir, command: "git status", paths: paths,
                                             base: ["GIT_DIR": ws + "/.git"])

        for (label, d) in [("V1", v1), ("V2", v2), ("V3", v3), ("V4", v4), ("V5", v5), ("V-env", vEnv)] {
            guard case .refuse = d else {
                Issue.record("\(label) expected refuse, got \(d)")
                return
            }
        }
    }

    @Test("V6: global config in mounted home with normal user settings (core.editor, alias.*) does not refuse ls")
    func globalConfigWithNormalSettingsInMountedHome() async throws {
        let (dir, _) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let home = dir + "/home"
        let base = ["HOME": home, "XDG_CONFIG_HOME": home + "/.config"]

        try """
        [user]
            name = Alice
        [core]
            editor = vim
        [alias]
            co = checkout
        [init]
            defaultBranch = main
        """.write(toFile: home + "/.gitconfig", atomically: false, encoding: .utf8)

        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [home])

        let d = guardian.judgeHostCommand(cwd: dir, command: "ls", base: base)
        if case .refuse(let why, _) = d {
            Issue.record("ordinary ~/.gitconfig must not refuse ls: \(why)")
        }
    }
}

@Suite("PR 773 sh -c and pushd e2e", .timeLimit(.minutes(1)))
struct R773ShE2E {
    @Test("sh -c 'cd ws && git status' and pushd in parent dir do not run fsmonitor or hooks")
    func shDashCCdAndPushd() async throws {
        let (dir, env) = try await GitFixture.repo()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ws = dir + "/ws"
        let paths = IrisPaths(root: URL(fileURLWithPath: dir + "/iris-home"))
        let guardian = GitConfigGuard()
        guardian.recordMounted(sources: [ws])

        let marker = dir + "/PWNED_SH"
        try await GitFixture.sh("git config core.fsmonitor 'touch \(marker)'", in: ws, env: env)

        let exec = ToolExecutor(irisPaths: paths, gitGuard: guardian)
        _ = await exec.runCommand("sh -c 'cd ws && git status'", cwd: dir, useSandbox: false)
        _ = await exec.runCommand("pushd ws >/dev/null && git status", cwd: dir, useSandbox: false)

        #expect(!FileManager.default.fileExists(atPath: marker), "core.fsmonitor executed via sh -c or pushd!")

        // Also verify that when config is clean, a restrictedPath command still gets core.hooksPath=/dev/null
        try await GitFixture.sh("git config --unset core.fsmonitor", in: ws, env: env)
        let hookMarker = dir + "/PWNED_HOOK"
        try FileManager.default.createDirectory(atPath: ws + "/.git/hooks", withIntermediateDirectories: true)
        let hookPath = ws + "/.git/hooks/post-checkout"
        try "#!/bin/sh\ntouch '\(hookMarker)'\n".write(toFile: hookPath, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

        _ = await exec.runCommand("git checkout HEAD", cwd: ws, useSandbox: false, restrictedPath: ["/usr/bin", "/bin"])
        #expect(!FileManager.default.fileExists(atPath: hookMarker), "hook executed under restrictedPath!")
    }
}
