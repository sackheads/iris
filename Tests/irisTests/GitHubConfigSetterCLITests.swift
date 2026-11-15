import Foundation
import Testing
@testable import IrisKit

@Suite("GitHub headless config setter: --set-github-token / --set-github-repos (#966 Task 6)")
struct GitHubConfigSetterCLITests {
    private func isolatedConfig() -> (ConfigManager, KeychainManager, UserDefaults, String) {
        let name = "iris-966t6-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        return (ConfigManager(store: store, guardedSecrets: keychain), keychain, store, name)
    }

    private func teardown(_ store: UserDefaults, _ name: String) {
        store.removePersistentDomain(forName: name)
        IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
    }

    // MARK: --set-github-token

    @Test("writes the trimmed token read from stdin to the Keychain item, confirmation never echoes it")
    func setTokenWritesTheKeychainItem() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let stdin = Data("ghp_realtoken123\n".utf8)

        let result = GitHubConfigSetterCLI.setToken(stdin: stdin, keychain: keychain)

        #expect(keychain.secrets(service: KeychainManager.githubService)["token"] == "ghp_realtoken123")
        switch result {
        case .success(let message):
            #expect(!message.contains("ghp_realtoken123"))
        case .failure:
            Issue.record("expected success")
        }
    }

    @Test("empty or whitespace-only stdin refuses and writes nothing")
    func setTokenRefusesEmptyStdin() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let result = GitHubConfigSetterCLI.setToken(stdin: Data("   \n".utf8), keychain: keychain)
        switch result {
        case .success: Issue.record("expected failure")
        case .failure(let error): #expect(error == .emptyToken)
        }
        #expect(keychain.secrets(service: KeychainManager.githubService).isEmpty)
    }

    @Test("does not update a live app's cached hasGitHubToken flag: the setter is a separate process (#966 cross-process reality)")
    func setTokenDoesNotLiveRefreshAnAlreadyBuiltConfigManager() {
        let (config, keychain, store, name) = isolatedConfig()
        defer { teardown(store, name) }
        #expect(!config.hasGitHubToken)

        _ = GitHubConfigSetterCLI.setToken(stdin: Data("ghp_written_after\n".utf8), keychain: keychain)

        // The Keychain item itself was written -- that's what this call can prove.
        #expect(keychain.secrets(service: KeychainManager.githubService)["token"] == "ghp_written_after")
        // But the already-built manager's cached flag does not flip: it belongs to a future launch.
        #expect(!config.hasGitHubToken)
    }

    // MARK: --set-github-repos

    @Test("writes a comma- or newline-separated repo list to the guarded blob")
    func setReposWritesTheGuardedBlob() {
        let (config, _, store, name) = isolatedConfig()
        defer { teardown(store, name) }

        let result = GitHubConfigSetterCLI.setRepos(stdin: Data("sackheads/iris, bnaylor/notes\n".utf8), config: config)

        switch result {
        case .success: break
        case .failure: Issue.record("expected success")
        }
        #expect(config.isGitHubRepoAllowed("sackheads/iris"))
        #expect(config.isGitHubRepoAllowed("bnaylor/notes"))
        #expect(!config.isGitHubRepoAllowed("evil/repo"))
    }

    @Test("newline-separated entries work the same as comma-separated")
    func setReposAcceptsNewlineSeparator() {
        let (config, _, store, name) = isolatedConfig()
        defer { teardown(store, name) }
        _ = GitHubConfigSetterCLI.setRepos(stdin: Data("sackheads/iris\nbnaylor/notes\n".utf8), config: config)
        #expect(config.isGitHubRepoAllowed("sackheads/iris"))
        #expect(config.isGitHubRepoAllowed("bnaylor/notes"))
    }

    @Test("a malformed entry is rejected and writes nothing, not even the valid entries beside it")
    func setReposRejectsMalformedEntryAndWritesNothing() {
        let (config, _, store, name) = isolatedConfig()
        defer { teardown(store, name) }

        let result = GitHubConfigSetterCLI.setRepos(stdin: Data("sackheads/iris, not-a-repo\n".utf8), config: config)

        switch result {
        case .success: Issue.record("expected failure")
        case .failure(let error): #expect(error == .malformedRepo("not-a-repo"))
        }
        #expect(!config.isGitHubRepoAllowed("sackheads/iris"), "nothing is written when any entry is malformed")
    }

    @Test("an empty owner or name segment is malformed", arguments: [
        "/iris", "sackheads/", "/", "sackheads", "sackheads/iris/extra",
    ])
    func setReposRejectsEmptySegments(_ entry: String) {
        let (config, _, store, name) = isolatedConfig()
        defer { teardown(store, name) }
        let result = GitHubConfigSetterCLI.setRepos(stdin: Data(entry.utf8), config: config)
        switch result {
        case .success: Issue.record("\(entry.debugDescription) should have been rejected")
        case .failure(let error): #expect(error == .malformedRepo(entry))
        }
    }

    @Test("empty stdin clears the list to empty, allowing nothing")
    func setReposEmptyStdinClearsTheList() {
        let (config, _, store, name) = isolatedConfig()
        defer { teardown(store, name) }
        config.setGuardedBlob(.githubAllowedRepos, "[\"sackheads/iris\"]")
        #expect(config.isGitHubRepoAllowed("sackheads/iris"))

        let result = GitHubConfigSetterCLI.setRepos(stdin: Data(), config: config)

        switch result {
        case .success: break
        case .failure: Issue.record("expected success")
        }
        #expect(!config.isGitHubRepoAllowed("sackheads/iris"))
    }
}
