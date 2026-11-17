import Foundation
import Testing
@testable import IrisKit

/// #966: the logic behind Settings → Integrations → GitHub. The view is not under test
/// here (it needs a lease); everything it decides is.
@MainActor
@Suite("GitHub settings model (#966)", .timeLimit(.minutes(1)))
struct GitHubSettingsModelTests {
    private struct Rig {
        let config: ConfigManager
        let keychain: KeychainManager
        let store: UserDefaults
        let name: String
        @MainActor func model(offered: Bool = false, transport: GitHubTransport = URLSessionGitHubTransport()) -> GitHubSettingsModel {
            GitHubSettingsModel(config: config, keychain: keychain, toolsOfferedAtLaunch: offered, transport: transport)
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
        #expect(!m.needsRestart, "a token and a repo but no account: nothing would be offered")
        _ = m.saveLogin("acme-bot")
        #expect(m.needsRestart, "token, a repo and an account: the tools appear after a relaunch")
        let up = r.model(offered: true)
        #expect(!up.needsRestart)
        _ = up.removeRepo("a/b")
        #expect(up.needsRestart, "offered at launch, no longer configured: they go away after a relaunch")
        _ = up.addRepo("a/b")
        _ = up.clearLogin()
        #expect(up.needsRestart, "an account removed: they go away after a relaunch")
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

    @Test("the pane is mounted in Integrations and goes through the model, never the stores")
    func viewIsThinAndMounted() throws {
        let dir = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        let settings = try String(contentsOf: dir.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("GitHubSettingsSection()"))
        let view = try String(contentsOf: dir.appendingPathComponent("GitHubSettingsSection.swift"), encoding: .utf8)
        for forbidden in ["KeychainManager", "setGuardedBlob", "updateSecrets", "checkToken", "checkRepoList"] {
            #expect(!view.contains(forbidden), "the view must not touch \(forbidden) itself")
        }
    }

    // MARK: account login (#1184)

    private struct UserTransport: GitHubTransport {
        let login: String?
        let status: Int
        func send(_ request: URLRequest, bearer: String) async throws -> (Data, HTTPURLResponse) {
            let body = try JSONSerialization.data(withJSONObject: login.map { ["login": $0] } ?? [:])
            return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test("saving a login writes the guarded blob the tools' gate reads; removing it unsets it; the pane shows it")
    func loginLifecycle() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        #expect(m.login == nil && !m.storedLoginUnreadable)
        #expect(m.saveLogin(" acme-bot \n") == nil)
        #expect(m.login == "acme-bot" && r.config.githubLogin() == "acme-bot")
        #expect(m.clearLogin() == nil)
        #expect(m.login == nil && r.config.guardedBlob(.githubLogin).isEmpty)
    }

    @Test("a bad or empty login is refused and writes nothing")
    func loginValidation() {
        let r = rig(); defer { r.teardown() }
        let m = r.model()
        #expect(m.saveLogin("") == .emptyLogin)
        for bad in ["bad name", "-x", "x-", "a--b", "a/b", "x\npassword=1"] { #expect(m.saveLogin(bad) == .invalidLogin, "\(bad.debugDescription)") }
        #expect(m.login == nil && r.config.guardedBlob(.githubLogin).isEmpty)
    }

    @Test("a stored login that does not read is shown as unreadable, offers nothing, and the next save replaces it")
    func loginUnreadable() {
        let r = rig(); defer { r.teardown() }
        r.config.setGuardedBlob(.githubLogin, "{\"login\":\"bad name\"}")
        let m = r.model()
        #expect(m.login == nil && m.storedLoginUnreadable)
        #expect(m.saveLogin("acme-bot") == nil)
        #expect(m.login == "acme-bot" && !m.storedLoginUnreadable)
    }

    @Test("the login is gated like the other writes: an unreadable, deferred or blocked item refuses it")
    func loginGated() {
        let name = "iris-1184m-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        let keychain = KeychainManager(serviceSuffix: ".test-\(UUID().uuidString)")
        let config = ConfigManager(store: store, guardedSecrets: keychain, guardedMayChange: false)
        defer { store.removePersistentDomain(forName: name); IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory) }
        let m = GitHubSettingsModel(config: config, keychain: keychain, toolsOfferedAtLaunch: false)
        #expect(config.guardedState == .deferredToApp)
        #expect(m.saveLogin("acme-bot") != nil, "a deferred item took a login")
        #expect(m.clearLogin() != nil, "a deferred item cleared a login")
        #expect(m.login == nil)
    }

    @Test("checking the token asks GitHub and compares: match, mismatch with the real account, unverified, and nothing to check")
    func verify() async {
        let r = rig(); defer { r.teardown() }
        let none = r.model(transport: UserTransport(login: "acme-bot", status: 200))
        await none.verifyIdentity()
        #expect(none.identity == .unchecked, "no login, no token: nothing to compare")
        _ = none.saveLogin("acme-bot")
        await none.verifyIdentity()
        #expect(none.identity == .unchecked, "a login but no token")
        _ = none.saveToken("ghp_x")
        let match = r.model(transport: UserTransport(login: "Acme-Bot", status: 200))
        await match.verifyIdentity()
        #expect(match.identity == .match)
        let other = r.model(transport: UserTransport(login: "someone-else", status: 200))
        await other.verifyIdentity()
        #expect(other.identity == .mismatch(actual: "someone-else"))
        let denied = r.model(transport: UserTransport(login: nil, status: 401))
        await denied.verifyIdentity()
        #expect(denied.identity == .unverified("GitHub returned HTTP 401"))
        _ = denied.saveLogin("other-name")
        #expect(denied.identity == .unchecked, "changing the login drops a stale result")
    }

    @Test("a change made in the pane turns the tools' gate off at once, before any recheck")
    func changeDropsTheGate() async {
        let r = rig(); defer { r.teardown() }
        _ = r.model().addRepo("a/b")
        let m = r.model(transport: UserTransport(login: "acme-bot", status: 200))
        _ = m.saveLogin("acme-bot"); _ = m.saveToken("ghp_x")
        await m.verifyIdentity()
        #expect(m.identity == .match && r.config.githubIdentity == .match)
        _ = m.saveToken("ghp_other")
        #expect(r.config.githubIdentity == nil && m.identity == .unchecked)
        await m.verifyIdentity()
        #expect(m.identity == .match)
        _ = m.saveLogin("someone-else")
        #expect(r.config.githubIdentity == nil)
        _ = m.clearLogin()
        #expect(r.config.githubIdentity == nil)
    }

    @Test("the pane shows what the launch check found, without asking again")
    func paneMirrorsTheGateState() {
        let r = rig(); defer { r.teardown() }
        let id = r.config.beginGitHubIdentityCheck()
        r.config.finishGitHubIdentityCheck(try! #require(id), .mismatch(actual: "someone-else"))
        #expect(r.model().identity == .mismatch(actual: "someone-else"))
    }

    @Test("no source names the old hardcoded account: it is a setting, not a constant")
    func noHardcodedAccount() throws {
        let dir = PerfPaths.repoRoot().appendingPathComponent("Sources/IrisKit")
        var found: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            if try String(contentsOf: url, encoding: .utf8).contains("iris-main") { found.append(url.lastPathComponent) }
        }
        #expect(found.isEmpty, "\(found.sorted())")
    }
}
