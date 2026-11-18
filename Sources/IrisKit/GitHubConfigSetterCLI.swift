import Foundation

/// `iris --set-github-token` / `--set-github-repos` / `--set-github-login` (#966 Task 6, #1184): a headless entry path for
/// the GitHub identity's config, for a headless machine or a script. The Settings pane's model (`GitHubSettingsModel`) shares its token, repo-list and login checks, so the two cannot disagree about what is storable.
/// Each reads its value from **stdin**, never argv — argv leaks into process listings (`ps`), so
/// a token passed as an argument would be visible to every other process on the machine. Pipe it
/// in rather than typing it at a prompt: `pbpaste | iris --set-github-token`. Each prints a
/// confirmation that never echoes the token.
///
/// **Cross-process.** This runs as its own process invocation and exits; it writes the Keychain
/// item (or the guarded blob) directly and has no way to reach an already-running app's in-memory
/// state. `ConfigManager.hasGitHubToken` is cached once at that other process's launch (Task 1), so
/// a token this setter writes is seen only the next time Iris launches, not live.
///
/// **Relaunch Iris after `--set-github-repos` / `--set-github-login`.** A running app keeps what it
/// read at its own launch, so a change made here reaches it at its next launch, not live. It is not
/// lost in the meantime: since #1167 (fixed by #1171) a save the app makes over a `.normal` item leaves
/// a blob key as the item already holds it, so an unrelated Settings change cannot write the app's stale
/// copy of the list over this one. Over an item that is not `.normal` this setter refuses to write at all.
enum GitHubConfigSetterCLI {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyToken
        case malformedToken
        case malformedRepo(String)
        case malformedLogin
        case tooManyRepos
        case notYetConfigured
        case settingsUnreadable
        case writesBlocked

        var description: String {
            switch self {
            case .emptyToken: "no token read from stdin"
            case .malformedToken: "a token may not contain interior whitespace or control characters"
            case .malformedRepo(let name): "not a valid owner/name: \(name.debugDescription)"
            case .malformedLogin: "not a GitHub username (1 to 39 letters, digits and single hyphens, not starting or ending with one)"
            case .tooManyRepos: "more than \(GitHubProxyClient.maxAllowedRepos) repositories"
            case .notYetConfigured: "launch Iris once first, then re-run this command (its settings have never been read)"
            case .settingsUnreadable: "Iris's protected settings couldn't be read from the Keychain; this command can't change them until it can -- check for a denied Keychain prompt"
            case .writesBlocked: "Iris's settings could not be saved (the Keychain item is unreadable); nothing was written"
            }
        }
    }

    /// Writes the token read from `stdin` (trimmed) to `keychain`'s `iris.github` service, merging
    /// into whatever else that item holds (`updateSecrets`, #750) rather than replacing the whole
    /// item. Refuses an empty or whitespace-only read, or one with interior whitespace or control
    /// characters (multi-line stdin, e.g. two pasted lines, would otherwise be stored as one
    /// token with an embedded newline) -- either way, writing nothing.
    static func setToken(stdin: Data, keychain: KeychainManager) -> Result<String, Failure> {
        let token: String
        switch GitHubProxyClient.checkToken(String(decoding: stdin, as: UTF8.self)) {
        case .empty: return .failure(.emptyToken)
        case .malformed: return .failure(.malformedToken)
        case .ok(let checked): token = checked
        }
        keychain.updateSecrets(service: KeychainManager.githubService) { $0["token"] = token }
        return .success("GitHub token saved to the iris.github Keychain item. Iris reads it only at launch, so this takes effect the next time Iris launches.")
    }

    /// Removes the stored token, leaving anything else in the `iris.github` item. A running app keeps
    /// offering the tools until it quits (its token flag is read once at launch), but its calls find
    /// no token and refuse.
    static func clearToken(keychain: KeychainManager) -> Result<String, Failure> {
        do {
            try keychain.updateSecretsOrThrow(service: KeychainManager.githubService) { $0["token"] = nil }
        } catch {
            return .failure(.writesBlocked)
        }
        return .success("GitHub token removed from the iris.github Keychain item.")
    }

    /// Writes a comma- or newline-separated repo list read from `stdin` to the guarded
    /// `githubAllowedRepos` blob, as a JSON array. Empty `stdin` clears the list to empty (allows
    /// nothing). Any entry `GitHubProxyClient.isOwnerName` refuses (the one definition: the list can
    /// never hold an entry the client would turn away) refuses the whole write -- not even
    /// the valid entries beside it are saved, so a typo cannot silently narrow (or widen, if the
    /// bad entry were later fixed to match something else) the list to an unintended partial set.
    ///
    /// Refuses outright unless `config.guardedState == .normal` (dev-3's finding, #679): this
    /// setter runs as a non-app, non-announcing process, so over a never-upgraded guarded item
    /// `setGuardedBlob` would silently complete the upgrade -- writing every guarded value plus
    /// the marker -- that #679 reserves for the app to announce. "Write without the marker"
    /// doesn't work either: the app's own later upgrade path overwrites an unmarked item's values
    /// with the built-ins (empty, for this key) regardless of what a bypass already wrote. The
    /// safe fix is to require the item already be at `.normal` -- the user has launched Iris at
    /// least once -- before this setter touches it at all.
    static func setRepos(stdin: Data, config: ConfigManager) -> Result<String, Failure> {
        // .unreadable gets its own message (dev-2's finding): "launch Iris once first" is wrong
        // advice for a denied Keychain prompt or a damaged item -- relaunching alone won't fix it.
        if case .unreadable = config.guardedState { return .failure(.settingsUnreadable) }
        guard config.guardedState == .normal else { return .failure(.notYetConfigured) }

        let raw = String(decoding: stdin, as: UTF8.self)
        let listed = raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let names: [String]
        switch GitHubProxyClient.checkRepoList(listed) {
        case .invalid(let bad): return .failure(.malformedRepo(bad))
        case .tooMany: return .failure(.tooManyRepos)
        case .ok(let checked): names = checked
        }
        let json = (try? JSONSerialization.data(withJSONObject: names)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        config.setGuardedBlob(.githubAllowedRepos, json)
        // setGuardedBlob no-ops silently if the Keychain item's writes are blocked (an earlier
        // denied prompt) -- dev-2's finding. Check after, since setGuardedBlob gives no signal.
        if config.guardedKeychain?.areWritesBlocked == true { return .failure(.writesBlocked) }
        // "Takes effect" would be wrong (dev-2's finding): a running app keeps what it read at its own
        // launch, so this reaches it at the next one. It is not overwritten meanwhile (#1167, #1171).
        return .success(names.isEmpty
            ? "GitHub allowed repos cleared (none configured). \(Self.relaunchNote)"
            : "GitHub allowed repos saved: \(names.joined(separator: ", ")). \(Self.relaunchNote)")
    }

    private static let relaunchNote = "Relaunch Iris for it to take effect: a running app keeps what it read at launch."

    /// Writes the account login read from `stdin` to the guarded `githubLogin` blob. Empty `stdin`
    /// clears it (the tools are then not offered at the next launch). Refused unless the guarded item
    /// is at `.normal`, for the same reasons as `setRepos`. Relaunch Iris after: a running app keeps what it read.
    static func setLogin(stdin: Data, config: ConfigManager) -> Result<String, Failure> {
        if case .unreadable = config.guardedState { return .failure(.settingsUnreadable) }
        guard config.guardedState == .normal else { return .failure(.notYetConfigured) }
        let blob: String
        let shown: String?
        switch GitHubProxyClient.checkLogin(String(decoding: stdin, as: UTF8.self)) {
        case .invalid: return .failure(.malformedLogin)
        case .empty: blob = ""; shown = nil
        case .ok(let login): blob = GitHubProxyClient.loginBlob(login); shown = login
        }
        config.setGuardedBlob(.githubLogin, blob)
        if config.guardedKeychain?.areWritesBlocked == true { return .failure(.writesBlocked) }
        return .success(shown.map { "GitHub account login saved: \($0). \(Self.relaunchNote)" }
            ?? "GitHub account login cleared (the GitHub tools are not offered). \(Self.relaunchNote)")
    }

    // MARK: - Real CLI entry points (IrisMain.swift)

    static func runSetToken() -> Int32 {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        switch setToken(stdin: stdin, keychain: .shared) {
        case .success(let message):
            print(message)
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("iris --set-github-token: \(error)\n".utf8))
            return 64
        }
    }

    static func runClearToken() -> Int32 {
        switch clearToken(keychain: .shared) {
        case .success(let message):
            print(message)
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("iris --clear-github-token: \(error)\n".utf8))
            return 64
        }
    }

    static func runSetRepos() -> Int32 {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        switch setRepos(stdin: stdin, config: .shared) {
        case .success(let message):
            print(message)
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("iris --set-github-repos: \(error)\n".utf8))
            return 64
        }
    }

    static func runSetLogin() -> Int32 {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        switch setLogin(stdin: stdin, config: .shared) {
        case .success(let message):
            print(message)
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("iris --set-github-login: \(error)\n".utf8))
            return 64
        }
    }
}
