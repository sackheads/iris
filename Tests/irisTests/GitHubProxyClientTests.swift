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
}
