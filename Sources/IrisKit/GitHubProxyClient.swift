import Foundation

/// Talks to GitHub as Iris's own `iris-main` identity (#966): opens PRs, comments, and approves
/// *routine* (docs/assets) PRs, through three host-side proxy tools. The token lives in the
/// Keychain and is read only here — it never enters a prompt, tool arg, tool result, or error
/// string (spec §3, "spend, never possess"). This file grows the REST calls and the approve gate
/// in later tasks; Task 1 is only the token lookup `ToolExecutor`'s credential gate reads.
struct GitHubProxyClient {
    /// Whether the `iris-main` PAT is present. The credential gate for the three `github_*` tool
    /// declarations (Invariant 6): absent, the tools are not offered at all.
    static func hasToken(keychain: KeychainManager) -> Bool {
        token(keychain: keychain) != nil
    }

    /// The `iris-main` PAT, or nil if none is stored.
    static func token(keychain: KeychainManager) -> String? {
        keychain.secrets(service: KeychainManager.githubService)["token"]
    }
}
