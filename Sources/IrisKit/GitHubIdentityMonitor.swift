import Foundation

/// Keeps `ConfigManager.githubIdentity` current (#1184): whether the stored token belongs to the
/// configured login, asked of GitHub with `GET /user`. The `github_*` tools and the git identity are
/// offered only while it says `.match`, so a token pasted for the wrong account, or a login named
/// wrongly, turns them off rather than acting as someone else.
///
/// It never runs on the launch path: a check is a network call, and a hung one must not hang launch.
/// The state starts unchecked (tools off) and a `Task` fills it in; the request has its own 30 s
/// bound. Only a configured install asks at all.
enum GitHubIdentityMonitor {
    /// An unverified answer (offline, a 5xx) is asked again at most this often, when a turn next
    /// reads whether the tools are on. A mismatch is not retried: it needs the user to change
    /// something, and changing it clears the state and re-asks.
    static let retryInterval: TimeInterval = 60

    /// One check: begin, ask, record, unless one is already running (or, with `minInterval`, one was
    /// just made). Returns what GitHub said, nil if nothing was asked.
    @discardableResult
    static func verify(config: ConfigManager, keychain: KeychainManager, transport: GitHubTransport,
                       minInterval: TimeInterval? = nil,
                       loginProvider: (@Sendable () -> String?)? = nil) async -> GitHubProxyClient.IdentityCheck? {
        // Begin first, read the login after: a change completing after `begin` bumps the generation and
        // drops this answer, and one completing before it is read here (#1190).
        guard let generation = config.beginGitHubIdentityCheck(minInterval: minInterval) else { return nil }
        // `loginProvider` is a test seam: it runs where the login is read, after `begin`.
        guard let login = (loginProvider ?? { config.githubLogin() })() else {
            config.abandonGitHubIdentityCheck(generation)
            return nil
        }
        let client = GitHubProxyClient(keychain: keychain, isRepoAllowed: { _ in false }, transport: transport)
        let result = await client.verifyIdentity(expectedLogin: login)
        config.finishGitHubIdentityCheck(generation, result)
        return result
    }

    /// Starts a check in the background if the tools would be offered but for it: configured at
    /// launch, and the identity unchecked or unverified. Safe to call every turn; it returns at once.
    @discardableResult
    static func kickIfNeeded(config: ConfigManager = .shared, keychain: KeychainManager = .shared,
                             transport: GitHubTransport = URLSessionGitHubTransport()) -> Task<Void, Never>? {
        guard config.githubConfiguredAtLaunch else { return nil }
        switch config.githubIdentity {
        case .match, .mismatch: return nil
        case .none, .unverified: break
        }
        return Task.detached {
            _ = await verify(config: config, keychain: keychain, transport: transport, minInterval: retryInterval)
        }
    }
}
