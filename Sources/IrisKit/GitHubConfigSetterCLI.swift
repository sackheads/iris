import Foundation

/// `iris --set-github-token` / `iris --set-github-repos` (#966 Task 6): a headless entry path for
/// the GitHub identity's config, since this slice ships with no Settings UI (deferred to #961).
/// Each reads its value from **stdin**, never argv — argv leaks into process listings (`ps`), so
/// a token passed as an argument would be visible to every other process on the machine. Each
/// prints a confirmation that never echoes the token.
///
/// **Cross-process.** This runs as its own process invocation and exits; it writes the Keychain
/// item (or the guarded blob) directly and has no way to reach an already-running app's in-memory
/// state. `ConfigManager.hasGitHubToken` is cached once at that other process's launch (Task 1), so
/// a token this setter writes takes effect the next time Iris launches, not live.
enum GitHubConfigSetterCLI {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyToken
        case malformedRepo(String)

        var description: String {
            switch self {
            case .emptyToken: "no token read from stdin"
            case .malformedRepo(let name): "not a valid owner/name: \(name.debugDescription)"
            }
        }
    }

    /// `name` is a valid `owner/name`: exactly one `/`, with a non-empty segment on each side.
    static func isValidRepoName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Writes the token read from `stdin` (trimmed) to `keychain`'s `iris.github` service. Refuses
    /// an empty or whitespace-only read, writing nothing.
    static func setToken(stdin: Data, keychain: KeychainManager) -> Result<String, Failure> {
        let token = String(decoding: stdin, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.emptyToken) }
        keychain.replaceSecrets(["token": token], service: KeychainManager.githubService)
        return .success("GitHub token saved to the iris.github Keychain item. It takes effect the next time Iris launches.")
    }

    /// Writes a comma- or newline-separated repo list read from `stdin` to the guarded
    /// `githubAllowedRepos` blob, as a JSON array. Empty `stdin` clears the list to empty (allows
    /// nothing). Any entry that is not a valid `owner/name` refuses the whole write -- not even
    /// the valid entries beside it are saved, so a typo cannot silently narrow (or widen, if the
    /// bad entry were later fixed to match something else) the list to an unintended partial set.
    static func setRepos(stdin: Data, config: ConfigManager) -> Result<String, Failure> {
        let raw = String(decoding: stdin, as: UTF8.self)
        let names = raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let bad = names.first(where: { !isValidRepoName($0) }) {
            return .failure(.malformedRepo(bad))
        }
        let json = (try? JSONSerialization.data(withJSONObject: names)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        config.setGuardedBlob(.githubAllowedRepos, json)
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
