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

    @Test("a token with interior whitespace or a control character is malformed and writes nothing (dev-3's finding)", arguments: [
        "ghp_abc\nghp_def", "ghp_abc ghp_def", "ghp_abc\tghp_def", "ghp_abc\u{0007}ghp_def",
    ])
    func setTokenRejectsInteriorWhitespaceOrControl(_ stdin: String) {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let result = GitHubConfigSetterCLI.setToken(stdin: Data(stdin.utf8), keychain: keychain)
        switch result {
        case .success: Issue.record("\(stdin.debugDescription) should have been rejected")
        case .failure(let error): #expect(error == .malformedToken)
        }
        #expect(keychain.secrets(service: KeychainManager.githubService).isEmpty)
    }

    @Test("writing the token merges into the Keychain item rather than replacing it (updateSecrets, #750)")
    func setTokenMergesRatherThanReplaces() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["other_key": "untouched"], service: KeychainManager.githubService)
        _ = GitHubConfigSetterCLI.setToken(stdin: Data("ghp_realtoken123\n".utf8), keychain: keychain)
        let secrets = keychain.secrets(service: KeychainManager.githubService)
        #expect(secrets["token"] == "ghp_realtoken123")
        #expect(secrets["other_key"] == "untouched")
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

    @Test("a repo shape the GitHub client would refuse anyway is malformed here too, so the list can never hold one (dev-3's finding)", arguments: [
        "sackheads/iris/../../admin", "sackheads/iris?x=1", "sackheads/iris#f", "a b/c",
    ])
    func setReposRejectsShapesTheClientWouldRefuse(_ entry: String) {
        let (config, _, store, name) = isolatedConfig()
        defer { teardown(store, name) }
        let result = GitHubConfigSetterCLI.setRepos(stdin: Data(entry.utf8), config: config)
        switch result {
        case .success: Issue.record("\(entry.debugDescription) should have been rejected")
        case .failure(let error): #expect(error == .malformedRepo(entry))
        }
    }

    @Test("refuses when the guarded item has never been upgraded and this process doesn't announce (#679, dev-3's finding)")
    func setReposRefusesWhenDeferredToApp() {
        let name = "iris-966t6-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        // mayChange: false, over an unmarked (never-upgraded) item: a non-app role that does not
        // announce must not silently complete the upgrade that #679 reserves for the app.
        let config = ConfigManager(store: store, guardedSecrets: keychain, guardedMayChange: false)
        defer { teardown(store, name) }
        #expect(config.guardedState == .deferredToApp)

        let result = GitHubConfigSetterCLI.setRepos(stdin: Data("sackheads/iris\n".utf8), config: config)

        switch result {
        case .success: Issue.record("expected failure: the guarded item was never upgraded")
        case .failure(let error): #expect(error == .notYetConfigured)
        }
        #expect(keychain.secrets(service: KeychainManager.legacyService)[GuardedKey.githubAllowedRepos.rawValue] == nil)
    }

    @Test("also refuses over a .missing guarded item (upgrade ran before, item now empty), not just .deferredToApp (dev-3's \"for good measure\")")
    func setReposRefusesWhenGuardedStateIsMissing() {
        let name = "iris-966t6-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.set(true, forKey: GuardedSettings.markerKey)
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        defer { teardown(store, name) }
        #expect(config.guardedState == .missing)

        let result = GitHubConfigSetterCLI.setRepos(stdin: Data("sackheads/iris\n".utf8), config: config)

        switch result {
        case .success: Issue.record("expected failure: the guarded item is missing its values")
        case .failure(let error): #expect(error == .notYetConfigured)
        }
    }

    @Test("reports failure rather than silent success when the Keychain item's writes are blocked (dev-2's finding)")
    func setReposReportsFailureWhenWritesAreBlocked() {
        let (config, keychain, store, name) = isolatedConfig()
        defer { teardown(store, name) }
        #expect(config.guardedState == .normal)
        keychain.blockWrites()

        let result = GitHubConfigSetterCLI.setRepos(stdin: Data("sackheads/iris\n".utf8), config: config)

        switch result {
        case .success: Issue.record("expected failure: setGuardedBlob silently no-ops when writes are blocked")
        case .failure(let error): #expect(error == .writesBlocked)
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
