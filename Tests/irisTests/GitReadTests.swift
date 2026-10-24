import Foundation
import Testing
@testable import IrisKit

/// #607: a silent host git read runs nothing a repository's config or attributes name. Each trap is
/// first sprung by a plain run (so the fixture is real), then not by the same read as Iris runs it.
@Suite("Silent host git reads (#607)", .serialized, .timeLimit(.minutes(1)))
struct GitReadTests {
    /// A git new enough for `--attr-source`, or nil (the real-git tests then have nothing to run).
    static let git: String? = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { path in
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = ["--version"]
        let out = Pipe(); p.standardOutput = out
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return GitRead.supports(versionOutput: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// A repository with every trap set, and the marker each one leaves when it runs.
    struct Trapped: Sendable {
        let root: URL
        func marker(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("RAN-\(name)").path) }
        func clear() { for f in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where f.hasPrefix("RAN-") {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(f)) } }
    }

    private func sh(_ git: String, _ args: [String], in dir: URL, env: [String: String] = [:], input: String? = nil) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: git); p.arguments = args; p.currentDirectoryURL = dir
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "GIT_CONFIG_NOSYSTEM": "1"].merging(env) { $1 }
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        let inPipe = Pipe(); if input != nil { p.standardInput = inPipe }
        try p.run()
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)); try inPipe.fileHandleForWriting.close() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The fixture, built off the cooperative pool: it waits on a dozen git processes, and blocking
    /// pool threads with them made deadline suites running beside this one miss (#607 gate).
    private func trappedOffPool(_ git: String) async throws -> Trapped {
        let made = await OffPool.run(cancelled: Result<Trapped, Error>.failure(CancellationError())) { _ in
            Result { try self.trapped(git) }
        }
        return try made.get()
    }

    private func trapped(_ git: String) throws -> Trapped {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-607-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = { (name: String) -> String in
            let script = root.appendingPathComponent("tool-\(name)")
            try? "#!/bin/sh\ntouch '\(root.path)/RAN-\(name)'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return script.path
        }
        _ = try sh(git, ["init", "-q"], in: root)
        for (k, v) in [("user.email", "t@t"), ("user.name", "t"),
                       ("filter.evil.clean", tool("filter")), ("diff.evil.textconv", tool("textconv")),
                       ("core.fsmonitor", tool("fsmonitor")), ("diff.external", tool("external")),
                       ("log.showSignature", "true"), ("gpg.program", tool("gpg")),
                       ("core.attributesFile", root.appendingPathComponent("attrs").path)] {
            _ = try sh(git, ["config", k, v], in: root)
        }
        try "hello\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "hello\n".write(to: root.appendingPathComponent("b.dat"), atomically: true, encoding: .utf8)
        _ = try sh(git, ["add", "a.txt", "b.dat"], in: root)
        // A commit carrying a signature, so a signature check has something to run gpg on.
        let tree = try sh(git, ["write-tree"], in: root)
        let commit = try sh(git, ["hash-object", "-t", "commit", "-w", "--stdin"], in: root, input: """
            tree \(tree)
            author t <t@t> 0 +0000
            committer t <t@t> 0 +0000
            gpgsig -----BEGIN PGP SIGNATURE-----

             iQEzBAABCAAdFiEE
             -----END PGP SIGNATURE-----

            signed

            """)
        _ = try sh(git, ["update-ref", "HEAD", commit], in: root)
        // The worktree's attributes pick the filter and the textconv; the attributes file the
        // config names picks them for the second file.
        try "*.txt filter=evil diff=evil\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "*.dat filter=evil diff=evil\n".write(to: root.appendingPathComponent("attrs"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: root.appendingPathComponent("b.dat"), atomically: true, encoding: .utf8)
        // The fixture's own commands (`add`, `update-ref`) ran the fsmonitor already: start clean.
        let repo = Trapped(root: root)
        repo.clear()
        return repo
    }

    /// The read as Iris runs it: `GitRead.argv` with the restricted environment plus `GitRead.environment()`.
    private func silent(_ command: String, _ git: String, in repo: Trapped) async throws {
        let argv = try #require(GitRead.argv(command), "\(command) is an allowed read")
        try await silent(argv, git, cwd: repo.root.path)
    }

    /// `argv` run as Iris runs it from `cwd`: pinned to the repository `ownRepository` judges there.
    private func silent(_ argv: [String], _ git: String, cwd: String, writableRoots: [String] = []) async throws {
        let judged = try #require(GitRead.ownRepository(cwd: cwd, writableRoots: writableRoots), "no repository of the person's own at \(cwd)")
        let env = ReadOnlyCommand.restrictedEnvironment(path: ["/usr/bin", "/bin"], base: ["HOME": cwd])
            .merging(GitRead.environment()) { $1 }.merging(GitRead.pinning(judged)) { $1 }.merging(["GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
        _ = await ProcessGroupRunner.capture(executable: git, arguments: Array(argv.dropFirst()), environment: env,
                                             currentDirectory: cwd, timeoutSeconds: 10)
    }

    @Test("every trap fires on a plain run, so the fixture is real", .enabled(if: git != nil))
    func trapsAreReal() async throws {
        let git = try #require(Self.git)
        let repo = try await trappedOffPool(git); defer { try? FileManager.default.removeItem(at: repo.root) }
        _ = await OffPool.run(cancelled: ()) { _ in
            for args in [["status"], ["diff"], ["log", "-1"]] { _ = try? self.sh(git, args, in: repo.root) }
        }
        for name in ["filter", "fsmonitor", "external", "gpg"] { #expect(repo.marker(name), "\(name) didn't run on a plain read") }
    }

    /// The reads checked against one trapped repository, built once: a fixture per read put
    /// a hundred git processes beside the deadline suites in a full run (#607 gate).
    static let reads = ["git status", "git status --porcelain", "git diff", "git diff --stat", "git log -1",
                        "git log -p -1", "git show HEAD", "git blame a.txt", "git blame b.dat"]

    @Test("status, diff, log, show and blame as Iris runs them run nothing the repository names", .enabled(if: git != nil))
    func silentReadsRunNothing() async throws {
        let git = try #require(Self.git)
        let repo = try await trappedOffPool(git); defer { try? FileManager.default.removeItem(at: repo.root) }
        for command in Self.reads {
            try await silent(command, git, in: repo)
            for name in ["filter", "textconv", "fsmonitor", "external", "gpg"] {
                #expect(!repo.marker(name), "\(command) ran the repository's \(name)")
            }
            repo.clear()
        }
    }

    @Test("a bare git dir a sandbox planted below the person's repository is never the one opened (#758 review)", .enabled(if: git != nil))
    func plantedBareRepository() async throws {
        let git = try #require(Self.git)
        let repo = try await trappedOffPool(git); defer { try? FileManager.default.removeItem(at: repo.root) }
        // The person's repository is `repo.root`, its traps neutralised as above. A sandbox mount
        // `out/` inside it holds a bare layout of the VM's: its own config naming a clean filter, its
        // own info/attributes choosing it for everything, and a work tree pointing back up.
        let out = repo.root.appendingPathComponent("out"), sub = out.appendingPathComponent("sub")
        let fm = FileManager.default
        for d in ["objects", "refs/heads", "info"] { try fm.createDirectory(at: out.appendingPathComponent(d), withIntermediateDirectories: true) }
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: out.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "* filter=vm\n".write(to: out.appendingPathComponent("info/attributes"), atomically: true, encoding: .utf8)
        let trap = out.appendingPathComponent("vm-filter")
        try "#!/bin/sh\ntouch '\(repo.root.path)/RAN-vm'\ncat\n".write(to: trap, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trap.path)
        try "[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = \(repo.root.path)\n[filter \"vm\"]\n\tclean = \(trap.path)\n"
            .write(to: out.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        // The planted repository tracks a.txt (its own index), then a.txt changes, so a diff has
        // something to clean; the add itself runs the filter, so the markers start clear.
        _ = await OffPool.run(cancelled: ()) { _ in
            _ = try? self.sh(git, ["--git-dir", out.path, "--work-tree", repo.root.path, "add", "a.txt"], in: repo.root)
        }
        try "changed again\n".write(to: repo.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        repo.clear()
        // A plain git from inside the mount opens the VM's: the trap is real.
        _ = await OffPool.run(cancelled: ()) { _ in _ = try? self.sh(git, ["diff"], in: sub) }
        #expect(repo.marker("vm"), "precondition: git's own discovery opens the planted git dir")
        repo.clear()
        // From inside the mount, Iris doesn't run it at all: the cwd is the sandbox's, and the
        // walk finds the planted git dir as git would.
        #expect(GitRead.ownRepository(cwd: sub.path, writableRoots: [out.path]) == nil)
        #expect(GitRead.repository(from: sub.path)?.gitDir == out.resolvingSymlinksInPath().path, "the walk matches git's discovery")
        // From the person's own folder, it runs pinned to the person's git dir: the planted one is
        // just a folder in the work tree, and its filter never runs.
        try await silent(try #require(GitRead.argv("git diff")), git, cwd: repo.root.path, writableRoots: [out.path])
        try await silent(try #require(GitRead.argv("git status")), git, cwd: repo.root.path, writableRoots: [out.path])
        #expect(!repo.marker("vm"), "the VM's filter ran on the host")
    }

    @Test("the argv is exactly git, Iris's prefix, the subcommand, its forced flags, then the judged words")
    func argvExact() {
        #expect(GitRead.argv("git diff --stat HEAD~1") == ["git", "--attr-source=\(GitRead.emptyTree)", "diff",
                                                          "--ignore-submodules=all", "--no-ext-diff", "--no-textconv",
                                                          "--stat", "HEAD~1"])
        #expect(GitRead.argv("git log --oneline -5") == ["git", "--attr-source=\(GitRead.emptyTree)", "log",
                                                         "--no-ext-diff", "--no-textconv", "--no-show-signature",
                                                         "--oneline", "-5"])
        #expect(GitRead.argv("git rev-parse HEAD") == ["git", "--attr-source=\(GitRead.emptyTree)", "rev-parse", "HEAD"])
        #expect(GitRead.argv("git push") == nil && GitRead.argv("ls") == nil)
    }

    @Test("a restricted git read spawns as argv with no shell, and the overrides in its environment")
    func hostSpawnArgv() {
        let repo = GitRead.Repository(gitDir: "/p/.git", commonDir: "/p/.git", workTree: "/p")
        let spawn = ToolExecutor.hostSpawn("git status", restrictedPath: ["/usr/bin"], gitRepository: repo,
                                           base: ["HOME": "/h", "GIT_DIR": "/evil"])
        #expect(spawn.executable == "/usr/bin/git")
        #expect(spawn.arguments == ["--attr-source=\(GitRead.emptyTree)", "status", "--ignore-submodules=all"])
        #expect(spawn.environment["GIT_DIR"] == "/p/.git" && spawn.environment["GIT_WORK_TREE"] == "/p",
                "pinned to the judged repository, never the parent's GIT_DIR")
        #expect(spawn.environment["GIT_CONFIG_GLOBAL"] == "/dev/null" && spawn.environment["GIT_CONFIG_NOSYSTEM"] == "1",
                "no global or system config (#758 review)")
        #expect(spawn.environment["GIT_OPTIONAL_LOCKS"] == "0" && spawn.environment["PATH"] == "/usr/bin")
        let keys = (0..<(Int(spawn.environment["GIT_CONFIG_COUNT"] ?? "0") ?? 0)).compactMap { spawn.environment["GIT_CONFIG_KEY_\($0)"] }
        for key in ["core.fsmonitor", "diff.external", "core.attributesFile", "log.showSignature", "gpg.program",
                    "gpg.ssh.program", "gpg.x509.program", "core.hooksPath", "core.pager"] {
            #expect(keys.contains(key), "\(key) isn't overridden")
        }
        // A git the restricted PATH can't find, or no judged repository to pin, runs nothing at all.
        #expect(ToolExecutor.hostSpawn("git status", restrictedPath: ["/nonexistent"], gitRepository: repo, base: [:]).executable == "/usr/bin/false")
        #expect(ToolExecutor.hostSpawn("git status", restrictedPath: ["/usr/bin"], base: [:]).executable == "/usr/bin/false")
    }

    @Test("only a repository whose git dir no sandbox can write is read silently")
    func repositoryRule() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iris-607-reach-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo"), mount = base.appendingPathComponent("mount")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: mount.appendingPathComponent("nested/.git"), withIntermediateDirectories: true)
        #expect(GitRead.repositoryOutOfReach(cwd: repo.appendingPathComponent("sub").path, writableRoots: [mount.path]))
        #expect(!GitRead.repositoryOutOfReach(cwd: repo.path, writableRoots: [repo.path]), "a mount-root repo's own dir")
        #expect(!GitRead.repositoryOutOfReach(cwd: mount.appendingPathComponent("nested").path, writableRoots: [mount.path]),
                "a repository nested in a mount")
        // A worktree whose `.git` file points into a mount: its git dir is the VM's to write.
        let linked = base.appendingPathComponent("linked")
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(mount.appendingPathComponent("nested/.git").path)\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(!GitRead.repositoryOutOfReach(cwd: linked.path, writableRoots: [mount.path]))
        #expect(!GitRead.repositoryOutOfReach(cwd: base.path, writableRoots: []), "no repository at all")
        // A sandbox mount inside the person's repository, with nothing planted yet: the git dir is the
        // person's, but a read run from the mount asks, since the sandbox could plant what git's
        // discovery takes first (dev-2's review). From the repository's root it still runs.
        let build = repo.appendingPathComponent("build")
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        #expect(!GitRead.repositoryOutOfReach(cwd: build.path, writableRoots: [build.path]))
        #expect(GitRead.repositoryOutOfReach(cwd: repo.path, writableRoots: [build.path]))
    }

    @Test("a git read through the gate: out of reach runs restricted, nested in a mount asks")
    func gate() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("iris-607-gate-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let lookup = { (roots: [String]) in
            ReadOnlyCommand.HostLookup(path: "/usr/bin", cwd: repo.path, home: "/nonexistent-home", writableRoots: roots,
                                       isExecutable: { $0 == "/usr/bin/git" })
        }
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "git status", inSandbox: false,
                                            cwd: repo.path, lookup: lookup([])) == .runRestricted(path: ["/usr/bin"]))
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "git status", inSandbox: false,
                                            cwd: repo.path, lookup: lookup([base.path])) == .ask)
        #expect(ReadOnlyCommand.vibecopGate(toolName: "run_command", details: "git push", inSandbox: false,
                                            cwd: repo.path, lookup: lookup([])) == .ask)
    }

    @Test("a git older than 2.40, or one whose version can't be read, isn't trusted")
    func versions() {
        #expect(GitRead.supports(versionOutput: "git version 2.50.1 (Apple Git-155)"))
        #expect(GitRead.supports(versionOutput: "git version 2.40.0"))
        #expect(!GitRead.supports(versionOutput: "git version 2.39.5 (Apple Git-154)"))
        #expect(!GitRead.supports(versionOutput: "git version 1.99.9"))
        #expect(!GitRead.supports(versionOutput: "nonsense"))
    }
}
