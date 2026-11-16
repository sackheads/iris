import Foundation
import Testing
@testable import IrisKit

@Suite("iris-main git identity environment (#966 spec §4)")
struct GitIdentityEnvironmentTests {
    // MARK: fragmentContents

    @Test("the fragment sets iris-main's identity and resets credential.helper before re-adding it")
    func fragmentContents() {
        let text = GitIdentityEnvironment.fragmentContents(helperExecutable: "/path/to/iris")
        #expect(text.contains("name = iris-main"))
        #expect(text.contains("email = iris-main@users.noreply.github.com"))
        #expect(text.contains("helper =\n"), "the empty reset must come before the real helper line")
        #expect(text.contains("--git-credential-helper"))
        #expect(!text.contains("ghp_"), "no secret in the static fragment")
    }

    @Test("a helper path with a space is shell-quoted so it runs as one word")
    func fragmentContentsQuotesThePath() {
        let text = GitIdentityEnvironment.fragmentContents(helperExecutable: "/Applications/Iris Dev.app/iris")
        #expect(text.contains("'/Applications/Iris Dev.app/iris'"))
    }

    // MARK: ensureFragment

    @Test("writes the fragment when it doesn't exist, and never overwrites an existing one")
    func ensureFragmentIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iris-gitid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(GitIdentityEnvironment.fragmentFileName).path

        GitIdentityEnvironment.ensureFragment(at: path, helperExecutable: "/path/to/iris")
        let first = try String(contentsOfFile: path, encoding: .utf8)
        #expect(first.contains("iris-main"))

        // A second call with a DIFFERENT helper path must not change the file: proves it never overwrites.
        GitIdentityEnvironment.ensureFragment(at: path, helperExecutable: "/different/path")
        let second = try String(contentsOfFile: path, encoding: .utf8)
        #expect(second == first)
    }

    // MARK: additions

    @Test("one repo gives three includeIf conditions (https, git@, ssh://) and two pushInsteadOf rules")
    func additionsForOneRepo() {
        let pairs = GitIdentityEnvironment.additions(repos: ["sackheads/iris"], fragmentPath: "/frag")
        let includeIfs = pairs.filter { $0.key.hasPrefix("includeIf.hasconfig:remote.*.url:") }
        let pushInsteadOfs = pairs.filter { $0.key.hasSuffix(".pushInsteadOf") }
        #expect(includeIfs.count == 3)
        #expect(includeIfs.allSatisfy { $0.value == "/frag" })
        #expect(includeIfs.contains { $0.key == "includeIf.hasconfig:remote.*.url:https://github.com/sackheads/iris.git.path" })
        #expect(includeIfs.contains { $0.key == "includeIf.hasconfig:remote.*.url:git@github.com:sackheads/iris.git.path" })
        #expect(includeIfs.contains { $0.key == "includeIf.hasconfig:remote.*.url:ssh://git@github.com/sackheads/iris.git.path" })
        #expect(pushInsteadOfs.count == 2)
        #expect(pushInsteadOfs.allSatisfy { $0.key == "url.https://github.com/sackheads/iris.git.pushInsteadOf" })
        #expect(Set(pushInsteadOfs.map(\.value)) == ["git@github.com:sackheads/iris.git", "ssh://git@github.com/sackheads/iris.git"])
    }

    @Test("two repos give additions for both, scoped to each repo's own exact URL")
    func additionsForTwoRepos() {
        let pairs = GitIdentityEnvironment.additions(repos: ["sackheads/iris", "bnaylor/notes"], fragmentPath: "/frag")
        #expect(pairs.contains { $0.key.contains("sackheads/iris") })
        #expect(pairs.contains { $0.key.contains("bnaylor/notes") })
        // Neither repo's entries mention the other's name anywhere (no cross-contamination).
        #expect(!pairs.contains { $0.key.contains("sackheads/iris") && $0.key.contains("bnaylor/notes") })
    }

    @Test("an empty repo list gives no additions")
    func additionsEmptyForNoRepos() {
        #expect(GitIdentityEnvironment.additions(repos: [], fragmentPath: "/frag").isEmpty)
    }

    @Test("a stored entry that isn't a strict owner/name is skipped, never reaching a config key", arguments: [
        "sackheads/iris/../../admin", "sackheads/iris?x=1", "sackheads", "a b/c", "",
    ])
    func additionsSkipMalformedEntries(_ bad: String) {
        let pairs = GitIdentityEnvironment.additions(repos: [bad, "sackheads/iris"], fragmentPath: "/frag")
        let onlyGoodRepo = GitIdentityEnvironment.additions(repos: ["sackheads/iris"], fragmentPath: "/frag")
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
        #expect(GitIdentityEnvironment.environment(repos: [], fragmentPath: "/frag", base: base) == base)
    }

    @Test("with an allowed repo, GIT_CONFIG_COUNT/KEY/VALUE are added and GIT_TERMINAL_PROMPT is set")
    func environmentAddsConfigAndTerminalPrompt() {
        let base = ["PATH": "/usr/bin"]
        let env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], fragmentPath: "/frag", base: base)
        #expect(env["PATH"] == "/usr/bin", "base entries survive")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        let count = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
        #expect(count == 5)
        for i in 0..<count {
            #expect(env["GIT_CONFIG_KEY_\(i)"] != nil)
            #expect(env["GIT_CONFIG_VALUE_\(i)"] != nil)
        }
    }

    @Test("appends after a base that already carries GIT_CONFIG entries, rather than overwriting them")
    func environmentAppendsAfterExistingConfigEntries() {
        let base = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.pager", "GIT_CONFIG_VALUE_0": "cat"]
        let env = GitIdentityEnvironment.environment(repos: ["sackheads/iris"], fragmentPath: "/frag", base: base)
        #expect(env["GIT_CONFIG_KEY_0"] == "core.pager", "the existing entry at index 0 is untouched")
        #expect(env["GIT_CONFIG_VALUE_0"] == "cat")
        #expect(Int(env["GIT_CONFIG_COUNT"] ?? "") == 1 + 5)
        #expect(env["GIT_CONFIG_KEY_1"] != nil, "new entries start right after the existing count")
    }
}

@Suite("ToolExecutor.hostSpawn + iris-main git identity (#966 spec §4)")
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
                                           gitIdentityRepos: ["sackheads/iris"], gitIdentityFragmentPath: "/frag")
        #expect(spawn.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(Int(spawn.environment["GIT_CONFIG_COUNT"] ?? "") == 5)
    }

    @Test("the sandboxed git-read branch ignores the new parameters entirely (#658(a), frozen)")
    func sandboxedBranchUnaffected() {
        let withoutIdentity = ToolExecutor.hostSpawn("ls", restrictedPath: ["/bin"], base: [:])
        let withIdentity = ToolExecutor.hostSpawn("ls", restrictedPath: ["/bin"], base: [:],
                                                   gitIdentityRepos: ["sackheads/iris"], gitIdentityFragmentPath: "/frag")
        #expect(withoutIdentity.environment == withIdentity.environment)
        #expect(withoutIdentity.executable == withIdentity.executable)
        #expect(withoutIdentity.arguments == withIdentity.arguments)
    }

    @Test("an empty repo list with a fragment path still applies no additions")
    func emptyReposNoAdditionsEvenWithFragmentPath() {
        let base = ["PATH": "/usr/bin"]
        let spawn = ToolExecutor.hostSpawn("git push", restrictedPath: nil, base: base,
                                           gitIdentityRepos: [], gitIdentityFragmentPath: "/frag")
        #expect(spawn.environment == BinaryResolver.commandEnvironment(base: base))
    }
}
