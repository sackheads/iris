import Foundation
import Observation

/// The logic behind Settings → Integrations → GitHub (#966): the `iris.github` token
/// and the allowed-repos list, with the view left to draw it. It is the one in-process writer of
/// both outside the headless setters, and shares their validation (`GitHubProxyClient.checkToken`,
/// `checkRepoList`), so the two entry paths cannot disagree about what is storable. Nothing here
/// reads a token back out except to show `KeyHint`'s suffix, and no message it produces holds one.
@MainActor @Observable
final class GitHubSettingsModel {
    nonisolated static let maxRepos = GitHubProxyClient.maxAllowedRepos

    enum EditState: Equatable {
        case editable
        case disabled(String)
    }

    enum Failure: Error, Equatable {
        case disabled(String)
        case invalidRepo
        case duplicateRepo
        case tooManyRepos
        case emptyToken
        case emptyLogin
        case invalidLogin
        case malformedToken
        case notSaved

        var message: String {
            switch self {
            case .disabled(let reason): reason
            case .invalidRepo: "That is not an owner/name repository (letters, digits, . _ - on each side of one slash)."
            case .duplicateRepo: "That repository is already on the list."
            case .tooManyRepos: "The list is at its limit of \(GitHubSettingsModel.maxRepos) repositories."
            case .emptyToken: "Paste the token first."
            case .emptyLogin: "Type the account's GitHub username first."
            case .invalidLogin: "That is not a GitHub username (1 to 39 letters, digits and single hyphens, not starting or ending with one)."
            case .malformedToken: "A token has no spaces or line breaks inside it. Paste just the token."
            case .notSaved: "It could not be saved: Iris's Keychain item would not take the change."
            }
        }
    }

    @ObservationIgnored private let config: ConfigManager
    @ObservationIgnored private let keychain: KeychainManager
    /// Whether the `github_*` tools were offered when this process launched: that flag is read once
    /// (Invariant 6), so a change made here reaches the tools at the next launch.
    @ObservationIgnored private let toolsOfferedAtLaunch: Bool
    @ObservationIgnored private let transport: GitHubTransport

    /// What `GET /user` said about the stored token, for the configured login (#1184).
    enum IdentityState: Equatable {
        case unchecked
        case checking
        case match
        case mismatch(actual: String)
        case unverified(String)
    }

    private(set) var repos: [String] = []
    /// A list is stored but does not read as one, so nothing is allowed until an edit replaces it.
    private(set) var storedListUnreadable = false
    /// The configured account login, or nil when unset or when the stored value does not read as one.
    private(set) var login: String?
    /// A login is stored but does not read as one, so the tools stay off until an edit replaces it.
    private(set) var storedLoginUnreadable = false
    private(set) var identity: IdentityState = .unchecked
    private(set) var tokenHint = "not set"
    private var storedTokenPresent = false

    init(config: ConfigManager, keychain: KeychainManager = .shared, toolsOfferedAtLaunch: Bool,
         transport: GitHubTransport = URLSessionGitHubTransport()) {
        self.config = config
        self.keychain = keychain
        self.transport = transport
        self.toolsOfferedAtLaunch = toolsOfferedAtLaunch
        refresh()
    }

    /// Re-reads both from where they live.
    func refresh() {
        repos = config.allowedGitHubRepos()
        let blob = config.guardedBlob(.githubAllowedRepos).trimmingCharacters(in: .whitespacesAndNewlines)
        storedListUnreadable = repos.isEmpty && !blob.isEmpty && blob != "[]"
        login = config.githubLogin()
        storedLoginUnreadable = login == nil && !config.guardedBlob(.githubLogin).isEmpty
        let token = GitHubProxyClient.token(keychain: keychain)
        storedTokenPresent = token != nil
        tokenHint = KeyHint.text(token)
    }

    /// Both are written only over a guarded item that read normally: any other state is protective
    /// for this run, and a write over it is refused rather than half-applied.
    var editState: EditState {
        if config.guardedState != .normal {
            return .disabled(GuardedSettings.settingsBanner(for: config.guardedState)
                ?? "Iris's protected settings are not available yet, so they cannot be changed here.")
        }
        if config.guardedKeychain?.areWritesBlocked == true {
            return .disabled("Iris's Keychain item could not be read at launch, so nothing can be saved to it.")
        }
        return .editable
    }

    /// The stored token, list and login would offer the tools, and what this launch offered differs.
    var needsRestart: Bool {
        (storedTokenPresent && !repos.isEmpty && login != nil) != toolsOfferedAtLaunch
    }

    // MARK: Login

    /// Saves the account login (checked by `GitHubProxyClient.checkLogin`) as the guarded blob and
    /// reads it back. Clearing is its own action, so an empty field is a prompt, not a clear.
    @discardableResult
    func saveLogin(_ raw: String) -> Failure? {
        if case .disabled(let reason) = editState { return .disabled(reason) }
        switch GitHubProxyClient.checkLogin(raw) {
        case .empty: return .emptyLogin
        case .invalid: return .invalidLogin
        case .ok(let checked):
            config.setGuardedBlob(.githubLogin, GitHubProxyClient.loginBlob(checked))
            refresh()
            identity = .unchecked
            return login == checked ? nil : .notSaved
        }
    }

    @discardableResult
    func clearLogin() -> Failure? {
        if case .disabled(let reason) = editState { return .disabled(reason) }
        config.setGuardedBlob(.githubLogin, "")
        refresh()
        identity = .unchecked
        return login == nil && !storedLoginUnreadable ? nil : .notSaved
    }

    /// Asks GitHub whose token this is and compares it with the configured login. Does nothing
    /// without both. Never throws: a failure to ask is `.unverified`, not a match.
    func verifyIdentity() async {
        guard let login, storedTokenPresent else { identity = .unchecked; return }
        identity = .checking
        let client = GitHubProxyClient(keychain: keychain, isRepoAllowed: { _ in false }, transport: transport)
        switch await client.verifyIdentity(expectedLogin: login) {
        case .match: identity = .match
        case .mismatch(let actual): identity = .mismatch(actual: actual)
        case .unverified(let why): identity = .unverified(why)
        }
    }

    // MARK: Repos

    @discardableResult
    func addRepo(_ raw: String) -> Failure? {
        if case .disabled(let reason) = editState { return .disabled(reason) }
        let repo = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repos.contains(repo) else { return .duplicateRepo }
        switch GitHubProxyClient.checkRepoList(repos + [repo]) {
        case .invalid: return .invalidRepo
        case .tooMany: return .tooManyRepos
        case .ok(let list): return write(list)
        }
    }

    @discardableResult
    func removeRepo(_ repo: String) -> Failure? {
        if case .disabled(let reason) = editState { return .disabled(reason) }
        return write(repos.filter { $0 != repo })
    }

    /// Saves `list` as the guarded blob and reads it back: `setGuardedBlob` gives no signal when a
    /// write is dropped, so the read is what says it landed.
    private func write(_ list: [String]) -> Failure? {
        let json = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        config.setGuardedBlob(.githubAllowedRepos, json)
        refresh()
        return repos == list ? nil : .notSaved
    }

    // MARK: Token

    @discardableResult
    func saveToken(_ raw: String) -> Failure? {
        if case .disabled(let reason) = editState { return .disabled(reason) }
        let token: String
        switch GitHubProxyClient.checkToken(raw) {
        case .empty: return .emptyToken
        case .malformed: return .malformedToken
        case .ok(let checked): token = checked
        }
        do {
            try keychain.updateSecretsOrThrow(service: KeychainManager.githubService) { $0["token"] = token }
        } catch {
            return .notSaved
        }
        refresh()
        return GitHubProxyClient.token(keychain: keychain) == token ? nil : .notSaved
    }

    @discardableResult
    func clearToken() -> Failure? {
        if case .disabled(let reason) = editState { return .disabled(reason) }
        do {
            try keychain.updateSecretsOrThrow(service: KeychainManager.githubService) { $0["token"] = nil }
        } catch {
            return .notSaved
        }
        refresh()
        return storedTokenPresent ? .notSaved : nil
    }
}
