import Foundation
import Testing
@testable import IrisKit

@Suite("GitHub git identity environment (#966 spec §4, #1184)")
struct GitIdentityEnvironmentTests {
    // MARK: shouldApply

    @Test("applies only with a token, a login, a readable account id, a non-empty allowlist, and a non-guest-origin turn", arguments: [
        (hasToken: true, login: "acme-bot" as String?, accountId: 12345 as Int?, repos: ["sackheads/iris"], guestOrigin: false, expected: true),
        (hasToken: false, login: "acme-bot" as String?, accountId: 12345 as Int?, repos: ["sackheads/iris"], guestOrigin: false, expected: false),
        (hasToken: true, login: nil as String?, accountId: 12345 as Int?, repos: ["sackheads/iris"], guestOrigin: false, expected: false),
        (hasToken: true, login: "acme-bot" as String?, accountId: nil as Int?, repos: ["sackheads/iris"], guestOrigin: false, expected: false),
        (hasToken: true, login: "acme-bot" as String?, accountId: 12345 as Int?, repos: [], guestOrigin: false, expected: false),
        (hasToken: true, login: "acme-bot" as String?, accountId: 12345 as Int?, repos: ["sackheads/iris"], guestOrigin: true, expected: false),
        (hasToken: false, login: nil as String?, accountId: nil as Int?, repos: [], guestOrigin: true, expected: false),
    ])
    func shouldApply(_ c: (hasToken: Bool, login: String?, accountId: Int?, repos: [String], guestOrigin: Bool, expected: Bool)) {
        #expect(GitIdentityEnvironment.shouldApply(hasToken: c.hasToken, login: c.login, accountId: c.accountId,
                                                   repos: c.repos, guestOrigin: c.guestOrigin) == c.expected)
    }

    @Test("a match with no readable id (dev-2's finding 2) does not apply: the same accountId == nil that stops commitIdentity's bare-form fallback also stops shouldApply")
    func shouldApplyFalseWithoutIdEvenIfMatched() {
        #expect(!GitIdentityEnvironment.shouldApply(hasToken: true, login: "acme-bot", accountId: nil,
                                                     repos: ["sackheads/iris"], guestOrigin: false))
    }

    // MARK: fragmentContents

    @Test("the fragment sets the configured login's identity (id+login noreply form) and resets credential.helper before re-adding it")
    func fragmentContents() {
        let text = GitIdentityEnvironment.fragmentContents(login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        #expect(text.contains("name = acme-bot"))
        #expect(text.contains("email = 12345+acme-bot@users.noreply.github.com"),
                "an account made for this feature is always created after GitHub's 2017 cutoff (#1188): only the id+login form attributes")
        #expect(!text.contains("iris-main"))
        #expect(text.contains("helper =\n"), "the empty reset must come before the real helper line")
        #expect(text.contains("--git-credential-helper"))
        #expect(text.contains("useHttpPath = true"), "without this git never sends the helper a path (dev-3's review, real git 2.54)")
        #expect(!text.contains("ghp_"), "no secret in the static fragment")
    }

    @Test("a nil account id falls back to the bare noreply form (#1188): shouldApply never lets this reach a real commit")
    func fragmentContentsNilIdFallsBack() {
        let text = GitIdentityEnvironment.fragmentContents(login: "acme-bot", accountId: nil, helperExecutable: "/path/to/iris")
        #expect(text.contains("email = acme-bot@users.noreply.github.com"))
    }

    @Test("a helper path with a space is shell-quoted so it runs as one word")
    func fragmentContentsQuotesThePath() {
        let text = GitIdentityEnvironment.fragmentContents(login: "acme-bot", accountId: 12345, helperExecutable: "/Applications/Iris Dev.app/iris")
        #expect(text.contains("'/Applications/Iris Dev.app/iris'"))
    }

    // MARK: ensureFragment

    @Test("writes the fragment when it doesn't exist, leaves it alone when unchanged, rewrites it when stale")
    func ensureFragmentWritesAndRefreshes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(GitIdentityEnvironment.fragmentFileName).path

        GitIdentityEnvironment.ensureFragment(at: path, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        let first = try String(contentsOfFile: path, encoding: .utf8)
        #expect(first.contains("12345+acme-bot@users.noreply.github.com"))

        // The login changed in Settings: the fragment follows it, nothing of the old one stays.
        GitIdentityEnvironment.ensureFragment(at: path, login: "other-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        let relogin = try String(contentsOfFile: path, encoding: .utf8)
        #expect(relogin.contains("name = other-bot") && !relogin.contains("acme-bot"))
        GitIdentityEnvironment.ensureFragment(at: path, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")

        // Same helper path and id again: the file is left exactly as it was (no gratuitous rewrite).
        GitIdentityEnvironment.ensureFragment(at: path, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == first)

        // The id changed (re-verified under a different account, #1188): the fragment follows it too.
        GitIdentityEnvironment.ensureFragment(at: path, login: "acme-bot", accountId: 99999, helperExecutable: "/path/to/iris")
        let reidentified = try String(contentsOfFile: path, encoding: .utf8)
        #expect(reidentified.contains("99999+acme-bot@users.noreply.github.com") && !reidentified.contains("12345"))
        GitIdentityEnvironment.ensureFragment(at: path, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")

        // A DIFFERENT helper path (a rebuild or reinstall moved the binary): the fragment must
        // refresh, or the baked `credential.helper` line goes stale (dev-3's review).
        GitIdentityEnvironment.ensureFragment(at: path, login: "acme-bot", accountId: 12345, helperExecutable: "/different/path")
        let refreshed = try String(contentsOfFile: path, encoding: .utf8)
        #expect(refreshed != first)
        #expect(refreshed.contains("/different/path"))
    }

    // MARK: additions

    @Test("one repo gives six includeIf conditions (3 url forms x with/without .git), all pointing at the routing path")
    func additionsForOneRepo() {
        let pairs = GitIdentityEnvironment.additions(repos: ["sackheads/iris"], routingPath: "/routing")
        #expect(pairs.count == 6)
        #expect(pairs.allSatisfy { $0.key.hasPrefix("includeIf.hasconfig:remote.*.url:") && $0.value == "/routing" })
        for url in ["https://github.com/sackheads/iris.git", "https://github.com/sackheads/iris",
                    "git@github.com:sackheads/iris.git", "git@github.com:sackheads/iris",
                    "ssh://git@github.com/sackheads/iris.git", "ssh://git@github.com/sackheads/iris"] {
            #expect(pairs.contains { $0.key == "includeIf.hasconfig:remote.*.url:\(url).path" },
                    "missing includeIf for \(url)")
        }
    }

    @Test("routingContents for one repo carries the identity include plus six insteadOf lines (4 ssh rewrites + 2 https identity rules)")
    func routingContentsForOneRepo() {
        let text = GitIdentityEnvironment.routingContents(repos: ["sackheads/iris"], identityFragmentPath: "/frag")
        #expect(text.contains("path = /frag"), "the identity fragment must be included")
        // insteadOf (never pushInsteadOf: a global SSH->HTTPS rewrite would run first and
        // pushInsteadOf alone wouldn't see it again, dev-3's review) rewrites every SSH spelling
        // onto the canonical .git https form. PLUS a self-mapping "identity" rule for each https
        // spelling: verified against real git 2.54, insteadOf picks the longest matching prefix
        // across every url.*.insteadOf rule, so a pre-existing generic global rule
        // (url.ssh://git@github.com/.insteadOf = https://github.com/, from `gh auth setup-git`)
        // would otherwise intercept an already-https remote before any ssh-keyed rule could run;
        // the longer, exact-URL identity rule outcompetes it on specificity and the URL never
        // leaves https. These rules live in the routing file's content, gated by the same exact
        // includeIf conditions that reach it -- never injected as flat, unconditional env entries
        // (round 1's design), which is what let them bleed into an unrelated repo sharing a
        // string prefix (see the type doc and `prefixCollisionRepoUnaffected`, a real-git test).
        for ssh in ["git@github.com:sackheads/iris.git", "git@github.com:sackheads/iris",
                    "ssh://git@github.com/sackheads/iris.git", "ssh://git@github.com/sackheads/iris"] {
            #expect(text.contains("insteadOf = \(ssh)"), "missing ssh-rewrite for \(ssh)")
        }
        #expect(text.contains("insteadOf = https://github.com/sackheads/iris.git"))
        #expect(text.contains("insteadOf = https://github.com/sackheads/iris\n") || text.hasSuffix("insteadOf = https://github.com/sackheads/iris"))
        let insteadOfCount = text.components(separatedBy: "insteadOf = ").count - 1
        #expect(insteadOfCount == 6)
    }

    @Test("routingContents is empty for an empty or all-malformed repo list")
    func routingContentsEmptyForNoValidRepos() {
        #expect(GitIdentityEnvironment.routingContents(repos: [], identityFragmentPath: "/frag").isEmpty)
        #expect(GitIdentityEnvironment.routingContents(repos: ["not-a-repo", "a/b/c"], identityFragmentPath: "/frag").isEmpty)
    }

    @Test("routingContents for two repos keeps each repo's section independent (no cross-contamination in the text)")
    func routingContentsForTwoRepos() {
        let text = GitIdentityEnvironment.routingContents(repos: ["sackheads/iris", "bnaylor/notes"], identityFragmentPath: "/frag")
        #expect(text.contains("sackheads/iris"))
        #expect(text.contains("bnaylor/notes"))
    }

    @Test("two repos give additions for both, scoped to each repo's own exact URL")
    func additionsForTwoRepos() {
        let pairs = GitIdentityEnvironment.additions(repos: ["sackheads/iris", "bnaylor/notes"], routingPath: "/frag")
        #expect(pairs.contains { $0.key.contains("sackheads/iris") })
        #expect(pairs.contains { $0.key.contains("bnaylor/notes") })
        // Neither repo's entries mention the other's name anywhere (no cross-contamination).
        #expect(!pairs.contains { $0.key.contains("sackheads/iris") && $0.key.contains("bnaylor/notes") })
    }

    @Test("an empty repo list gives no additions")
    func additionsEmptyForNoRepos() {
        #expect(GitIdentityEnvironment.additions(repos: [], routingPath: "/frag").isEmpty)
    }

    @Test("a stored entry that isn't a strict owner/name is skipped, never reaching a config key", arguments: [
        "sackheads/iris/../../admin", "sackheads/iris?x=1", "sackheads", "a b/c", "",
    ])
    func additionsSkipMalformedEntries(_ bad: String) {
        let pairs = GitIdentityEnvironment.additions(repos: [bad, "sackheads/iris"], routingPath: "/frag")
        let onlyGoodRepo = GitIdentityEnvironment.additions(repos: ["sackheads/iris"], routingPath: "/frag")
        // The bad entry contributes nothing: the pair count and content are identical to the good
        // repo alone, not merely "not literally containing the bad string" (which a substring of
        // the good repo's own name, like "sackheads", would pass vacuously).
        #expect(pairs.count == onlyGoodRepo.count)
        #expect(pairs.map(\.key) == onlyGoodRepo.map(\.key))
    }

    // MARK: environment

    @Test("no additions when there are no allowed repos: base is returned unchanged")
    func environmentUnchangedWithNoRepos() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/x"]
        #expect(GitIdentityEnvironment.environment(repos: [], routingPath: "/frag", base: base) == base)
    }

    @Test("with an allowed repo, GIT_CONFIG_COUNT/KEY/VALUE are added and GIT_TERMINAL_PROMPT is set")
    func environmentAddsConfigAndTerminalPrompt() {
        let base = ["PATH": "/usr/bin"]
        let env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], routingPath: "/frag", base: base)
        #expect(env["PATH"] == "/usr/bin", "base entries survive")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        let count = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        #expect(count == 6)
        for i in 0..<count {
            #expect(env["GIT_CONFIG_KEY_\(i)"] != nil)
            #expect(env["GIT_CONFIG_VALUE_\(i)"] != nil)
        }
    }

    @Test("appends after a base that already carries GIT_CONFIG entries, rather than overwriting them")
    func environmentAppendsAfterExistingConfigEntries() {
        let base = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.pager", "GIT_CONFIG_VALUE_0": "cat"]
        let env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], routingPath: "/frag", base: base)
        #expect(env["GIT_CONFIG_KEY_0"] == "core.pager", "the existing entry at index 0 is untouched")
        #expect(env["GIT_CONFIG_VALUE_0"] == "cat")
        #expect(Int(env["GIT_CONFIG_COUNT"] ?? "") == 1 + 6)
        #expect(env["GIT_CONFIG_KEY_1"] != nil, "new entries start right after the existing count")
    }
}

@Suite("ToolExecutor.hostSpawn + GitHub git identity (#966 spec §4)")
struct HostSpawnGitIdentityTests {
    @Test("without the new parameters, the unrestricted branch is unchanged (regression guard)")
    func unaffectedWithoutParameters() {
        let base = ["PATH": "/usr/bin"]
        let spawn = ToolExecutor.hostSpawn("git push", restrictedPath: nil, base: base)
        #expect(spawn.executable == "/bin/zsh")
        #expect(spawn.arguments == ["-c", "git push"])
        #expect(spawn.environment["GIT_CONFIG_COUNT"] == nil)
        #expect(spawn.environment["GIT_TERMINAL_PROMPT"] == nil)
    }

    @Test("with a fragment path and an allowed repo, the unrestricted branch carries the git-identity environment")
    func appliedWhenConfigured() {
        let base = ["PATH": "/usr/bin"]
        let spawn = ToolExecutor.hostSpawn("git push", restrictedPath: nil, base: base,
                                           gitIdentityRepos: ["sackheads/iris"], gitIdentityRoutingPath: "/frag")
        #expect(spawn.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(Int(spawn.environment["GIT_CONFIG_COUNT"] ?? "") == 6)
    }

    @Test("the sandboxed git-read branch ignores the new parameters entirely (#658(a), frozen)")
    func sandboxedBranchUnaffected() {
        let withoutIdentity = ToolExecutor.hostSpawn("ls", restrictedPath: ["/bin"], base: [:])
        let withIdentity = ToolExecutor.hostSpawn("ls", restrictedPath: ["/bin"], base: [:],
                                                   gitIdentityRepos: ["sackheads/iris"], gitIdentityRoutingPath: "/frag")
        #expect(withoutIdentity.environment == withIdentity.environment)
        #expect(withoutIdentity.executable == withIdentity.executable)
        #expect(withoutIdentity.arguments == withIdentity.arguments)
    }

    @Test("an empty repo list with a fragment path still applies no additions")
    func emptyReposNoAdditionsEvenWithFragmentPath() {
        let base = ["PATH": "/usr/bin"]
        let spawn = ToolExecutor.hostSpawn("git push", restrictedPath: nil, base: base,
                                           gitIdentityRepos: [], gitIdentityRoutingPath: "/frag")
        #expect(spawn.environment == BinaryResolver.commandEnvironment(base: base))
    }
}

/// Real git 2.54, not string-level assertions on `additions`' shape (dev-3's review): the shape
/// tests above proved the config keys look right, but they couldn't have caught either of the
/// bugs a real git invocation did -- `credential.useHttpPath` being required before git will even
/// send the helper a `path`, and `insteadOf`'s longest-matching-prefix resolution defeating the
/// SSH-rewrite rules on an already-https remote under a pre-existing global rewrite. These tests
/// run a real `git`, no network: `git ls-remote --get-url` and `git credential fill` both resolve
/// locally without ever reaching GitHub.
@Suite("real git end-to-end (#966 Task 8, dev-3's review)", .serialized)
struct RealGitEndToEndTests {
    static let git: String? = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private func run(_ arguments: [String], cwd: URL, env: [String: String], stdin: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.git!)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        if stdin != nil { process.standardInput = Pipe() }
        try process.run()
        if let stdin, let inPipe = process.standardInput as? Pipe {
            inPipe.fileHandleForWriting.write(stdin)
            try inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRepo(home: URL, globalInsteadOf: String? = nil) throws -> URL {
        if let globalInsteadOf {
            try globalInsteadOf.write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        }
        let repo = home.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try run(["init", "-q"], cwd: repo, env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        return repo
    }

    @Test("without credential.useHttpPath, a real git sends no path to the helper; with it, it does")
    func useHttpPathIsRequired() throws {
        guard Self.git != nil else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try makeRepo(home: home)
        let fillInput = Data("url=https://github.com/sackheads/iris.git\n\n".utf8)
        // A stub helper that just dumps whatever it was handed: `git credential fill` prints
        // NOTHING on stdout when no helper is configured at all (it doesn't echo the request back
        // on its own), so observing what the helper actually received needs a real helper.
        let captured = home.appendingPathComponent("captured.txt")
        let stub = home.appendingPathComponent("stub.sh")
        try "#!/bin/sh\ncat > \(PluginAuthRunner.shellQuoted(captured.path))\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let baseEnv = ["HOME": home.path, "PATH": "/usr/bin:/bin",
                       "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper",
                       "GIT_CONFIG_VALUE_0": stub.path]
        _ = try run(["credential", "fill"], cwd: repo, env: baseEnv, stdin: fillInput)
        let withoutUseHttpPath = try String(contentsOf: captured, encoding: .utf8)
        #expect(!withoutUseHttpPath.contains("path="), "a plain credential fill shouldn't add path on its own")
        try FileManager.default.removeItem(at: captured)

        var withEnv = baseEnv
        withEnv["GIT_CONFIG_COUNT"] = "2"
        withEnv["GIT_CONFIG_KEY_1"] = "credential.useHttpPath"
        withEnv["GIT_CONFIG_VALUE_1"] = "true"
        _ = try run(["credential", "fill"], cwd: repo, env: withEnv, stdin: fillInput)
        let withUseHttpPath = try String(contentsOf: captured, encoding: .utf8)
        #expect(withUseHttpPath.contains("path=sackheads/iris.git"),
                "credential.useHttpPath=true must make git add the repo path for the helper to check")
    }

    @Test("the fragment's stub helper actually receives the repo path through GitIdentityEnvironment.environment()")
    func fragmentDrivesTheRealHelper() throws {
        guard Self.git != nil else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try makeRepo(home: home)
        // `includeIf.hasconfig:remote.*.url:` matches against a CONFIGURED remote, not the
        // `credential fill` request's own `url=` field -- the repo needs a real matching remote.
        _ = try run(["remote", "add", "origin", "https://github.com/sackheads/iris.git"], cwd: repo,
                    env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])

        let captured = home.appendingPathComponent("captured.txt")
        let stub = home.appendingPathComponent("stub.sh")
        try "#!/bin/sh\ncat > \(PluginAuthRunner.shellQuoted(captured.path))\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let fragmentPath = home.appendingPathComponent(GitIdentityEnvironment.fragmentFileName).path
        GitIdentityEnvironment.ensureFragment(at: fragmentPath, login: "acme-bot", accountId: 12345, helperExecutable: stub.path)
        let routingPath = home.appendingPathComponent(GitIdentityEnvironment.routingFileName).path
        GitIdentityEnvironment.writeRoutingFile(repos: ["sackheads/iris"], identityFragmentPath: fragmentPath, to: routingPath)

        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], routingPath: routingPath, base: env)

        let fillInput = Data("url=https://github.com/sackheads/iris.git\n\n".utf8)
        _ = try run(["credential", "fill"], cwd: repo, env: env, stdin: fillInput)

        let capturedText = try String(contentsOf: captured, encoding: .utf8)
        #expect(capturedText.contains("path=sackheads/iris.git"))
    }

    @Test("a push URL resolves to https for an allowed repo even under a pre-existing global SSH insteadOf rule (dev-3's review, reproduced)")
    func pushURLResolvesToHTTPSDespiteAGlobalSSHRewrite() throws {
        guard Self.git != nil else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // The quirk dev-3 found on a real Mac (from `gh auth setup-git` or similar): a global rule
        // that rewrites ANY github.com https remote to ssh.
        let repo = try makeRepo(home: home, globalInsteadOf: "[url \"ssh://git@github.com/\"]\n\tinsteadOf = https://github.com/\n")
        _ = try run(["remote", "add", "origin", "https://github.com/sackheads/iris.git"], cwd: repo,
                    env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])

        // Without the fix: the global rule wins, resolving to ssh (reproduces the bug).
        let withoutFix = try run(["ls-remote", "--get-url", "origin"], cwd: repo,
                                 env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        #expect(withoutFix.trimmingCharacters(in: .whitespacesAndNewlines) == "ssh://git@github.com/sackheads/iris.git")

        // With the fix: GitIdentityEnvironment's identity rule outcompetes the global one.
        let fragmentPath = home.appendingPathComponent(GitIdentityEnvironment.fragmentFileName).path
        GitIdentityEnvironment.ensureFragment(at: fragmentPath, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        let routingPath = home.appendingPathComponent(GitIdentityEnvironment.routingFileName).path
        GitIdentityEnvironment.writeRoutingFile(repos: ["sackheads/iris"], identityFragmentPath: fragmentPath, to: routingPath)
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], routingPath: routingPath, base: env)
        let withFix = try run(["ls-remote", "--get-url", "origin"], cwd: repo, env: env)
        #expect(withFix.trimmingCharacters(in: .whitespacesAndNewlines) == "https://github.com/sackheads/iris.git")
    }

    @Test("a repo NOT on the allowlist gets no URL rewrite at all: the global rule still applies")
    func unlistedRepoUnaffected() throws {
        guard Self.git != nil else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try makeRepo(home: home, globalInsteadOf: "[url \"ssh://git@github.com/\"]\n\tinsteadOf = https://github.com/\n")
        _ = try run(["remote", "add", "origin", "https://github.com/other/repo.git"], cwd: repo,
                    env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])

        let fragmentPath = home.appendingPathComponent(GitIdentityEnvironment.fragmentFileName).path
        GitIdentityEnvironment.ensureFragment(at: fragmentPath, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        let routingPath = home.appendingPathComponent(GitIdentityEnvironment.routingFileName).path
        // "sackheads/iris" is allowed; "other/repo" (this remote) is not.
        GitIdentityEnvironment.writeRoutingFile(repos: ["sackheads/iris"], identityFragmentPath: fragmentPath, to: routingPath)
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], routingPath: routingPath, base: env)
        let resolved = try run(["ls-remote", "--get-url", "origin"], cwd: repo, env: env)
        #expect(resolved.trimmingCharacters(in: .whitespacesAndNewlines) == "ssh://git@github.com/other/repo.git",
                "an unlisted repo keeps today's behavior -- the global rewrite, untouched by ours")
    }

    @Test("the real collision case: an allowed repo's rewrite does not bleed into an unrelated repo sharing its name as a literal string prefix (planner's load-bearing regression guard)")
    func prefixCollisionRepoUnaffected() throws {
        guard Self.git != nil else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // "sackheads/iris" is allowed below. "sackheads/iris.github.io" is NOT, but
        // "git@github.com:sackheads/iris.git" is a literal string prefix of
        // "git@github.com:sackheads/iris.github.io.git" ("iris.git" is exactly the first 8
        // characters of "iris.github.io.git") -- the exact shape that defeated a flat,
        // unconditional `url.*.insteadOf` injection (round 1 of this PR).
        let repo = try makeRepo(home: home)
        _ = try run(["remote", "add", "origin", "git@github.com:sackheads/iris.github.io.git"], cwd: repo,
                    env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])

        let fragmentPath = home.appendingPathComponent(GitIdentityEnvironment.fragmentFileName).path
        GitIdentityEnvironment.ensureFragment(at: fragmentPath, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        let routingPath = home.appendingPathComponent(GitIdentityEnvironment.routingFileName).path
        GitIdentityEnvironment.writeRoutingFile(repos: ["sackheads/iris"], identityFragmentPath: fragmentPath, to: routingPath)
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], routingPath: routingPath, base: env)

        let resolved = try run(["ls-remote", "--get-url", "origin"], cwd: repo, env: env)
        #expect(resolved.trimmingCharacters(in: .whitespacesAndNewlines) == "git@github.com:sackheads/iris.github.io.git",
                "sackheads/iris.github.io's remote must be untouched by sackheads/iris's rewrite rules")
    }

    @Test("a known residual: a second remote in the SAME checkout that string-extends the allowed repo fails loudly, not silently over the ambient key (planner's ruling, pinned)")
    func secondRemoteInSameCheckoutMangledNotSilent() throws {
        guard Self.git != nil else { return }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-rg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try makeRepo(home: home)
        let env0 = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        // "origin" is the allowed repo; "upstream" is a second, UNRELATED remote in the same
        // checkout whose name string-extends it ("iris" -> "iris-fork"). Once origin's exact
        // match loads the routing file, its insteadOf rules apply to every remote resolved in
        // this repository -- including upstream, which the includeIf gate alone cannot scope out
        // (that gate is per-repository, not per-remote). This is the one case the fix doesn't
        // close; see the comment on `remoteSpellings`.
        _ = try run(["remote", "add", "origin", "https://github.com/sackheads/iris.git"], cwd: repo, env: env0)
        _ = try run(["remote", "add", "upstream", "git@github.com:sackheads/iris-fork.git"], cwd: repo, env: env0)

        let fragmentPath = home.appendingPathComponent(GitIdentityEnvironment.fragmentFileName).path
        GitIdentityEnvironment.ensureFragment(at: fragmentPath, login: "acme-bot", accountId: 12345, helperExecutable: "/path/to/iris")
        let routingPath = home.appendingPathComponent(GitIdentityEnvironment.routingFileName).path
        GitIdentityEnvironment.writeRoutingFile(repos: ["sackheads/iris"], identityFragmentPath: fragmentPath, to: routingPath)
        var env = env0
        env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], routingPath: routingPath, base: env)

        let originResolved = try run(["ls-remote", "--get-url", "origin"], cwd: repo, env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(originResolved == "https://github.com/sackheads/iris.git", "the allowed repo itself still resolves correctly")

        let upstreamResolved = try run(["ls-remote", "--get-url", "upstream"], cwd: repo, env: env)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Confirmed empirically: this mangles to a nonsense URL that would 404 or fail to parse
        // as a repo -- a loud failure, never a silent fallback to the user's own ambient SSH key.
        #expect(upstreamResolved != "git@github.com:sackheads/iris-fork.git", "mangled, not untouched")
        #expect(!upstreamResolved.contains("iris-fork"), "the rewrite breaks the URL rather than reaching the real fork")
    }
}

/// #1194 review (dev-2's finding 1): `ToolExecutor.hostSpawn` is the one call that feeds a real
/// `ConfigManager.shared.githubAccountId` into `ensureFragment` and so is the one place that can
/// silently revert to the unattributed bare noreply form -- it reads `ConfigManager.shared`
/// directly, so no test can drive it with an isolated config. A source scan pins the wiring
/// instead. A suite of its own, not `@MainActor` (#642): a scan held main for a quarter second of
/// a parallel run's start once, where every `@MainActor` suite waits on it.
@Suite("ToolExecutor's git-identity wiring (#1194): source scan")
struct ToolExecutorGitIdentityWiringSourceScanTests {
    @Test("ensureFragment's accountId comes from a real ConfigManager.shared.githubAccountId read, not a literal nil")
    func accountIdIsWired() throws {
        let url = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit/ToolExecutor.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("let accountId = ConfigManager.shared.githubAccountId"),
                "ensureFragment's accountId must come from a real read, not a hardcoded value -- changing it to nil would silently revert #1188 with every test still green")
        let occurrences = source.components(separatedBy: "accountId: accountId").count - 1
        #expect(occurrences == 2, "the one read must feed both shouldApply's gate and ensureFragment's write -- two uses of the same captured value, not a second independent read (dev-2's finding 2: two reads can straddle an invalidate)")
    }
}
