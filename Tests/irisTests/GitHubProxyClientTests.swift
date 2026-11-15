import Foundation
import Testing
@testable import IrisKit

@Suite("GitHubProxyClient: Keychain token lookup (#966 Task 1)")
struct GitHubProxyClientTests {
    @Test("hasToken is false over an empty store, true after a token is written")
    func hasTokenReadsTheGithubService() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        #expect(!GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == nil)

        keychain.replaceSecrets(["token": "ghp_test123"], service: KeychainManager.githubService)

        #expect(GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == "ghp_test123")
    }

    @Test("an empty or whitespace-only stored token counts as absent (dev-2's finding)")
    func emptyOrWhitespaceTokenIsAbsent() {
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.replaceSecrets(["token": ""], service: KeychainManager.githubService)
        #expect(!GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == nil)

        keychain.replaceSecrets(["token": "  \n"], service: KeychainManager.githubService)
        #expect(!GitHubProxyClient.hasToken(keychain: keychain))
        #expect(GitHubProxyClient.token(keychain: keychain) == nil)
    }

    @Test("ConfigManager caches the presence check once at init, not per read (#966 Task 1, dev-3's finding)")
    func configManagerCachesPresence() {
        let name = "iris-966-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }

        let withoutToken = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        #expect(!ConfigManager(store: store, guardedSecrets: withoutToken).hasGitHubToken)

        let withToken = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        withToken.replaceSecrets(["token": "ghp_cached"], service: KeychainManager.githubService)
        #expect(ConfigManager(store: store, guardedSecrets: withToken).hasGitHubToken)
    }

    @Test("the cached flag is fixed at construction, not computed per access (dev-2's finding)")
    func cachedFlagDoesNotLiveRefresh() {
        let name = "iris-966-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        #expect(!config.hasGitHubToken)

        // A write after construction must not retroactively flip an already-built manager's flag
        // -- that would mean the value is computed per access, not cached once at launch, and
        // #966's headless setter (a separate process) relies on exactly that fixed-ness.
        keychain.replaceSecrets(["token": "ghp_written_later"], service: KeychainManager.githubService)
        #expect(!config.hasGitHubToken)
    }
}
