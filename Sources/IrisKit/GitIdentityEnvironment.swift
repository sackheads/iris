import Foundation

/// The environment additions that let `run_command`'s host git act as `iris-main` for a
/// user-configured allowed repo, without touching `~/.gitconfig` or any process-global state
/// (#966 spec §4, design confirmed with the planner 2026-11-15).
///
/// Two pieces:
/// - **A static, non-secret identity fragment** (`fragmentPath`): `user.name`/`user.email` for
///   `iris-main`, and `credential.helper` pointing at `iris --git-credential-helper` (#1174's new
///   headless mode). Written once; never touched when the allowed-repo list changes.
/// - **Per-repo routing, computed fresh on every call** from the live allowlist: an
///   `includeIf.hasconfig:remote.*.url:<exact repo URL>` (both the `https://` and `git@` forms)
///   that includes the static fragment only for a remote matching that exact repo, and a
///   `pushInsteadOf` rewriting a push to that repo's SSH form onto HTTPS so the credential
///   helper (HTTPS-only; git credential helpers never apply to SSH) actually engages. Computed
///   fresh, not baked into the fragment, so adding a repo takes effect on the very next
///   `run_command` call rather than waiting on a regeneration (planner's correction, 2026-11-15):
///   removing a repo is already fail-safe (a stale rewrite just makes the push fail at the
///   helper), but adding one needs to be immediate.
///
/// A remote for a repo **not** on the list gets neither: no identity change, no URL rewrite, same
/// behavior as today. This is deliberate — a blanket `github.com` match would rewrite an
/// unrelated SSH push (ordinary coding work on some other repo) onto HTTPS with no credential,
/// breaking a push that works today over the user's own ambient SSH key.
enum GitIdentityEnvironment {
    static let identityName = "iris-main"
    /// GitHub's noreply convention: no separate "iris-main's email" setting to configure or
    /// leak. Any GitHub account gets this for free; it attributes commits to the account without
    /// exposing a real address.
    static let identityEmail = "iris-main@users.noreply.github.com"

    static let fragmentFileName = "git-identity-iris-main"

    /// The static fragment's contents: identity plus the credential helper, no secret. The
    /// leading empty `helper =` clears any `credential.helper` inherited from `~/.gitconfig` or
    /// system config before this point in the read order (it's a multi-valued key; an ambient
    /// helper already holding Brian's own cached GitHub credential must never be consulted for
    /// an `iris-main`-identity remote) — the same empty-then-set pattern `WorkspaceGit.overrides`
    /// already uses for the same reason.
    static func fragmentContents(helperExecutable: String) -> String {
        """
        [user]
        \tname = \(identityName)
        \temail = \(identityEmail)
        [credential]
        \thelper =
        \thelper = !\(PluginAuthRunner.shellQuoted(helperExecutable)) --git-credential-helper
        """
    }

    /// Writes the fragment if it doesn't already exist. Idempotent, no secret in it, safe to call
    /// on every launch; never rewritten after (identity and helper path don't change per-repo).
    static func ensureFragment(at path: String, helperExecutable: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                  withIntermediateDirectories: true)
        try? fragmentContents(helperExecutable: helperExecutable).write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The `GIT_CONFIG_KEY`/`VALUE` pairs for every repo in `repos`, in the order they're added
    /// (count included separately by `environment`). A stored entry that isn't a strict
    /// `owner/name` (shouldn't happen -- `setRepos` already refuses one -- but never trusted
    /// twice) is skipped rather than ever reaching a config key or a shell command.
    static func additions(repos: [String], fragmentPath: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for repo in repos where GitHubProxyClient.isOwnerName(repo) {
            let https = "https://github.com/\(repo).git"
            let sshColon = "git@github.com:\(repo).git"
            let sshURL = "ssh://git@github.com/\(repo).git"
            pairs.append((key: "includeIf.hasconfig:remote.*.url:\(https).path", value: fragmentPath))
            pairs.append((key: "includeIf.hasconfig:remote.*.url:\(sshColon).path", value: fragmentPath))
            pairs.append((key: "includeIf.hasconfig:remote.*.url:\(sshURL).path", value: fragmentPath))
            pairs.append((key: "url.\(https).pushInsteadOf", value: sshColon))
            pairs.append((key: "url.\(https).pushInsteadOf", value: sshURL))
        }
        return pairs
    }

    /// `additions`, merged into `base` as `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_N`/`GIT_CONFIG_VALUE_N`
    /// -- the same environment-based config injection `GitRead.environment()` already uses for
    /// the sandboxed read-only path, applied here to the unrestricted host path. Appends after
    /// whatever `base` already carries (defensive; the unrestricted path doesn't set any
    /// `GIT_CONFIG_*` itself today). `GIT_TERMINAL_PROMPT=0` is set whenever there's at least one
    /// addition, so a push the helper refuses (no credential offered) fails fast instead of
    /// hanging on a terminal prompt that `run_command` has none to answer. `base` is returned
    /// unchanged when `repos` is empty (no token configured, or no allowed repos yet) --
    /// identical behavior to today.
    static func environment(repos: [String], fragmentPath: String, base: [String: String]) -> [String: String] {
        let pairs = additions(repos: repos, fragmentPath: fragmentPath)
        guard !pairs.isEmpty else { return base }
        var env = base
        let existingCount = Int(base["GIT_CONFIG_COUNT"] ?? "") ?? 0
        env["GIT_CONFIG_COUNT"] = String(existingCount + pairs.count)
        for (offset, pair) in pairs.enumerated() {
            env["GIT_CONFIG_KEY_\(existingCount + offset)"] = pair.key
            env["GIT_CONFIG_VALUE_\(existingCount + offset)"] = pair.value
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }
}
