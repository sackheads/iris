import Foundation

/// `iris --set-github-token` / `iris --set-github-repos` (#966 Task 6): a headless entry path for
/// the GitHub identity's config, since this slice ships with no Settings UI (deferred to #961).
/// Each reads its value from **stdin**, never argv — argv leaks into process listings (`ps`), so
/// a token passed as an argument would be visible to every other process on the machine. Pipe it
/// in rather than typing it at a prompt: `pbpaste | iris --set-github-token`. Each prints a
/// confirmation that never echoes the token.
///
/// **Cross-process.** This runs as its own process invocation and exits; it writes the Keychain
/// item (or the guarded blob) directly and has no way to reach an already-running app's in-memory
/// state. `ConfigManager.hasGitHubToken` is cached once at that other process's launch (Task 1), so
/// a token this setter writes takes effect the next time Iris launches, not live.
enum GitHubConfigSetterCLI {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyToken
        case malformedToken
        case malformedRepo(String)
        case notYetConfigured
        case writesBlocked

        var description: String {
            switch self {
            case .emptyToken: "no token read from stdin"
            case .malformedToken: "a token may not contain interior whitespace or control characters"
            case .malformedRepo(let name): "not a valid owner/name: \(name.debugDescription)"
            case .notYetConfigured: "launch Iris once first, then re-run this command (its settings have never been read)"
            case .writesBlocked: "Iris's settings could not be saved (the Keychain item is unreadable); nothing was written"
            }
        }
    }

    /// `name` is a valid `owner/name`: exactly one `/`, a non-empty segment on each side, each
    /// part letters/digits/`.`/`_`/`-` and never `.`/`..`. The same shape `GitHubProxyClient`
    /// enforces before building a request (Task 3) — duplicated here rather than shared because
    /// Task 3 isn't merged yet; dev-3's review flagged this for unification once it lands, so the
    /// allowlist can never hold an entry the client would refuse anyway.
    static func isValidRepoName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 100 && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Writes the token read from `stdin` (trimmed) to `keychain`'s `iris.github` service, merging
    /// into whatever else that item holds (`updateSecrets`, #750) rather than replacing the whole
    /// item. Refuses an empty or whitespace-only read, or one with interior whitespace or control
    /// characters (multi-line stdin, e.g. two pasted lines, would otherwise be stored as one
    /// token with an embedded newline) -- either way, writing nothing.
    static func setToken(stdin: Data, keychain: KeychainManager) -> Result<String, Failure> {
        let token = String(decoding: stdin, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.emptyToken) }
        guard !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.malformedToken)
        }
        keychain.updateSecrets(service: KeychainManager.githubService) { $0["token"] = token }
        return .success("GitHub token saved to the iris.github Keychain item. It takes effect the next time Iris launches.")
    }

    /// Writes a comma- or newline-separated repo list read from `stdin` to the guarded
    /// `githubAllowedRepos` blob, as a JSON array. Empty `stdin` clears the list to empty (allows
    /// nothing). Any entry that is not a valid `owner/name` refuses the whole write -- not even
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
        guard config.guardedState == .normal else { return .failure(.notYetConfigured) }

        let raw = String(decoding: stdin, as: UTF8.self)
        let names = raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let bad = names.first(where: { !isValidRepoName($0) }) {
            return .failure(.malformedRepo(bad))
        }
        let json = (try? JSONSerialization.data(withJSONObject: names)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        config.setGuardedBlob(.githubAllowedRepos, json)
        // setGuardedBlob no-ops silently if the Keychain item's writes are blocked (an earlier
        // denied prompt) -- dev-2's finding. Check after, since setGuardedBlob gives no signal.
        if config.guardedKeychain?.areWritesBlocked == true { return .failure(.writesBlocked) }
        return .success(names.isEmpty
            ? "GitHub allowed repos cleared (none configured)."
            : "GitHub allowed repos saved: \(names.joined(separator: ", "))")
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
}
