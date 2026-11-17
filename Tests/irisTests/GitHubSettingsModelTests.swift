import Foundation
import Testing
@testable import IrisKit

/// #966: the logic behind Settings → Integrations → GitHub (iris-main). The view is not under test
/// here (it needs a lease); everything it decides is.
@MainActor
@Suite("GitHub settings model (#966)", .timeLimit(.minutes(1)))
struct GitHubSettingsModelTests {
    private struct Rig {
        let config: ConfigManager
        let keychain: KeychainManager
        let store: UserDefaults
        let name: String
        @MainActor func model(offered: Bool = false) -> GitHubSettingsModel {
            GitHubSettingsModel(config: config, keychain: keychain, toolsOfferedAtLaunch: offered)
        }
        func teardown() {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
    }

    private func rig() -> Rig {
        let name = "iris-966ui-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        return Rig(config: ConfigManager(store: store, guardedSecrets: keychain), keychain: keychain, store: store, name: name)
    }

    private func stored(_ r: Rig) -> String? {
        r.keychain.secrets(service: KeychainManager.githubService)["token"]
    }

    // MARK: repos

    @Test("adding a repo writes the guarded list the gate reads, and a removal cuts it off at once")
    func addAndRemove() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        #expect(m.editState == .editable && m.repos.isEmpty)
        #expect(m.addRepo(" sackheads/iris \n") == nil)
        #expect(m.addRepo("sackheads/other") == nil)
        #expect(m.repos == ["sackheads/iris", "sackheads/other"])
        #expect(r.config.isGitHubRepoAllowed("sackheads/iris") && r.config.allowedGitHubRepos() == m.repos)
        #expect(m.removeRepo("sackheads/iris") == nil)
        #expect(!r.config.isGitHubRepoAllowed("sackheads/iris") && r.config.isGitHubRepoAllowed("sackheads/other"))
    }

    @Test("a name the client would turn away, a duplicate and a full list are refused and write nothing")
    func validation() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        for bad in ["", "iris", "a/b/c", "a/../b", "a b/c", "https://github.com/a/b", "a/b?x=1", "../b", "a/"] {
            #expect(m.addRepo(bad) == .invalidRepo, "\(bad.debugDescription)")
        }
        #expect(m.repos.isEmpty && r.config.guardedBlob(.githubAllowedRepos).isEmpty)
        #expect(m.addRepo("a/b") == nil)
        #expect(m.addRepo("a/b") == .duplicateRepo)
        for i in 1..<GitHubSettingsModel.maxRepos { #expect(m.addRepo("a/r\(i)") == nil) }
        #expect(m.repos.count == GitHubSettingsModel.maxRepos)
        #expect(m.addRepo("a/one-more") == .tooManyRepos)
        #expect(m.repos.count == GitHubSettingsModel.maxRepos)
    }

    @Test("a stored list that does not read is shown as unreadable, allows nothing, and the next edit replaces it")
    func unreadableList() {
        let r = rig(); defer { r.teardown() }
        r.config.setGuardedBlob(.githubAllowedRepos, "[\"a/b\", 5]")
        let m = r.model()
        #expect(m.repos.isEmpty && m.storedListUnreadable && !r.config.isGitHubRepoAllowed("a/b"))
        #expect(m.addRepo("c/d") == nil)
        #expect(m.repos == ["c/d"] && !m.storedListUnreadable)
        // An honestly empty list is not "unreadable".
        r.config.setGuardedBlob(.githubAllowedRepos, "[]")
        m.refresh()
        #expect(!m.storedListUnreadable)
    }

    @Test("it sees what another writer put in the list when it refreshes")
    func refreshSeesOutOfBandWrite() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        r.config.setGuardedBlob(.githubAllowedRepos, "[\"x/y\"]")
        m.refresh()
        #expect(m.repos == ["x/y"])
    }

    // MARK: gating

    @Test("over an item that did not read normally, nothing is editable and nothing is written")
    func gatedByGuardedState() {
        let name = "iris-966ui-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name); IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory) }
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        keychain.simulateReadFailure(errSecAuthFailed)
        let config = ConfigManager(store: store, guardedSecrets: keychain)
        let m = GitHubSettingsModel(config: config, keychain: keychain, toolsOfferedAtLaunch: false)
        guard case .disabled = m.editState else { Issue.record("expected disabled"); return }
        for result in [m.addRepo("a/b"), m.removeRepo("a/b"), m.saveToken("ghp_x"), m.clearToken()] {
            guard case .disabled? = result else { Issue.record("expected a refusal, got \(result)"); continue }
        }
        #expect(keychain.secrets(service: KeychainManager.githubService).isEmpty)
    }

    @Test("a never-upgraded item and a missing one are disabled too, with writes not blocked, so the state gate itself is what refuses")
    func gatedByUpgradeStates() {
        for (marker, mayChange, expected) in [(false, false, GuardedSettings.State.deferredToApp), (true, true, .missing)] {
            let name = "iris-966ui-\(UUID().uuidString)"
            let store = UserDefaults(suiteName: name)!
            defer { store.removePersistentDomain(forName: name); IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory) }
            if marker { store.set(true, forKey: GuardedSettings.markerKey) }
            let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
            let config = ConfigManager(store: store, guardedSecrets: keychain, guardedMayChange: mayChange)
            #expect(config.guardedState == expected && keychain.areWritesBlocked == false)
            let m = GitHubSettingsModel(config: config, keychain: keychain, toolsOfferedAtLaunch: false)
            guard case .disabled = m.editState else { Issue.record("\(expected): expected disabled"); continue }
            guard case .disabled? = m.addRepo("a/b") else { Issue.record("\(expected): expected a refusal"); continue }
            #expect(keychain.secrets(service: KeychainManager.legacyService)[GuardedKey.githubAllowedRepos.rawValue] == nil)
        }
    }

    @Test("with the item's writes blocked the pane is disabled, and a dropped write is reported, not claimed")
    func blockedWrites() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        r.keychain.blockWrites()
        guard case .disabled = m.editState else { Issue.record("expected disabled"); return }
        #expect(m.addRepo("a/b") != nil)
        #expect(!r.config.isGitHubRepoAllowed("a/b"))
    }

    // MARK: token

    @Test("a token is saved to the iris.github item, shown only as a suffix, and replaced or removed on request")
    func tokenLifecycle() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        #expect(m.tokenHint == "not set")
        #expect(m.saveToken("  ghp_abcdefgh1234\n") == nil)
        #expect(stored(r) == "ghp_abcdefgh1234")
        #expect(m.tokenHint.hasSuffix("1234") && !m.tokenHint.contains("ghp_"))
        #expect(m.saveToken("ghp_second_token_9999") == nil)
        #expect(stored(r) == "ghp_second_token_9999")
        #expect(m.clearToken() == nil)
        #expect(stored(r) == nil && m.tokenHint == "not set")
    }

    @Test("an empty or multi-line token is refused and leaves the stored one alone; no message holds a token")
    func tokenValidation() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        _ = m.saveToken("ghp_keepme")
        #expect(m.saveToken("   ") == .emptyToken)
        let pasted = "ghp_line1\nghp_line2"
        #expect(m.saveToken(pasted) == .malformedToken)
        #expect(m.saveToken("ghp_a b") == .malformedToken)
        #expect(stored(r) == "ghp_keepme")
        for failure in [GitHubSettingsModel.Failure.emptyToken, .malformedToken, .notSaved] {
            #expect(!failure.message.contains("ghp_"))
        }
    }

    @Test("the pane and the headless setter agree on what a token may hold")
    func agreesWithCLI() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        for raw in ["ghp_ok", "  ghp_ok  \n", "", "  ", "a b", "a\tb", "a\nb", "a\u{0007}b", "ok\u{00A0}x"] {
            let cli = GitHubConfigSetterCLI.setToken(stdin: Data(raw.utf8), keychain: KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)"))
            let ui = m.saveToken(raw)
            switch (cli, ui) {
            case (.success, nil): break
            case (.failure(.emptyToken), .emptyToken?), (.failure(.malformedToken), .malformedToken?): break
            default: Issue.record("\(raw.debugDescription): setter \(cli), pane \(String(describing: ui))")
            }
        }
    }

    @Test("the headless setter and the pane agree on the list too: repeats are dropped and more than the cap is refused")
    func listAgreesWithCLI() {
        let r = rig(); defer { r.teardown() }
        let dup = GitHubConfigSetterCLI.setRepos(stdin: Data("a/b, c/d\na/b\n".utf8), config: r.config)
        guard case .success = dup else { Issue.record("expected success, got \(dup)"); return }
        #expect(r.config.allowedGitHubRepos() == ["a/b", "c/d"])
        let many = (0...GitHubProxyClient.maxAllowedRepos).map { "a/r\($0)" }.joined(separator: "\n")
        guard case .failure(.tooManyRepos) = GitHubConfigSetterCLI.setRepos(stdin: Data(many.utf8), config: r.config) else {
            Issue.record("expected tooManyRepos"); return
        }
        #expect(r.config.allowedGitHubRepos() == ["a/b", "c/d"], "a refused write leaves the list alone")
        #expect(GitHubSettingsModel.maxRepos == GitHubProxyClient.maxAllowedRepos)
    }

    @Test("clearing the token keeps whatever else the iris.github item holds")
    func clearKeepsOtherKeys() {
        let r = rig(); defer { r.teardown() }
        r.keychain.updateSecrets(service: KeychainManager.githubService) { $0["other"] = "kept"; $0["token"] = "ghp_x" }
        let m = r.model()
        #expect(m.clearToken() == nil)
        #expect(r.keychain.secrets(service: KeychainManager.githubService) == ["other": "kept"])
        // The CLI's --clear-github-token does the same.
        r.keychain.updateSecrets(service: KeychainManager.githubService) { $0["token"] = "ghp_y" }
        _ = GitHubConfigSetterCLI.clearToken(keychain: r.keychain)
        #expect(r.keychain.secrets(service: KeychainManager.githubService) == ["other": "kept"])
    }

    // MARK: launch-cached flags

    @Test("it says to restart exactly when what is stored would offer the tools differently from this launch")
    func needsRestart() {
        let r = rig(); defer { r.teardown() }
        let m = r.model(offered: false)
        #expect(!m.needsRestart)
        _ = m.saveToken("ghp_x")
        #expect(!m.needsRestart, "a token alone offers nothing")
        _ = m.addRepo("a/b")
        #expect(m.needsRestart, "token and a repo: the tools appear after a relaunch")
        let up = r.model(offered: true)
        #expect(!up.needsRestart)
        _ = up.removeRepo("a/b")
        #expect(up.needsRestart, "offered at launch, no longer configured: they go away after a relaunch")
    }

    // MARK: who writes

    @Test("only the pane's model and the headless setter write the token or the allowed list")
    func writersAreTheTwo() throws {
        let dir = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        var writers = Set<String>()
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("setGuardedBlob(.githubAllowedRepos") || text.contains("[\"token\"] =") { writers.insert(url.lastPathComponent) }
        }
        #expect(writers == ["GitHubSettingsModel.swift", "GitHubConfigSetterCLI.swift"], "\(writers.sorted())")
    }
}
