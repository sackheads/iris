import Foundation

/// The environment additions that let `run_command`'s host git act as the user's configured GitHub account (#1184) for a
/// user-configured allowed repo, without touching `~/.gitconfig` or any process-global state
/// (#966 spec §4, design confirmed with the planner 2026-11-15; round 2 after dev-2's and dev-3's
/// real-git reviews surfaced that the string-level design didn't actually work).
///
/// Three pieces:
/// - **A static, non-secret identity fragment** (`identityFragmentPath`): `user.name`/
///   `user.email` for the configured login, `credential.helper` pointing at `iris
///   --git-credential-helper`, and `credential.useHttpPath = true` — without it git sends the
///   helper only `protocol`/`host`, never `path`, so the helper (which needs the repo path to
///   check the allowlist) could never answer a real request (dev-3's review, verified against a
///   real git 2.54 invocation: the first round's string-level tests couldn't see this, since they
///   handed the helper a `path` directly rather than letting git decide whether to). Written
///   once; rewritten only if its computed contents ever differ from what's on disk (the baked
///   helper executable path can go stale across a rebuild or reinstall otherwise).
/// - **A routing file** (`routingPath`), rewritten in full on every `run_command` call from the
///   live allowlist: for each allowed repo, one `[include] path = <identity fragment>` plus that
///   repo's own `url.<canonical https>.insteadOf` lines (rewriting every SSH spelling, and each
///   https spelling onto itself — see below). Rewriting the rewrite rules themselves, not only
///   baking them into `fragmentPath`, is what keeps "adding a repo takes effect on the very next
///   call" (planner's correction, 2026-11-15) without the collision this round's `additions`
///   fixes (next point).
/// - **Per-repo `includeIf.hasconfig:remote.*.url:<exact URL>` conditions**, injected fresh as
///   `GIT_CONFIG_KEY`/`VALUE_N` env vars (the same mechanism `GitRead.environment()` already uses
///   for the sandboxed read-only path), one per URL spelling a remote might legitimately have
///   (`https://`, `git@host:`, `ssh://git@host/`, each with and without `.git` — six per repo),
///   all pointing at the one routing file.
///
/// **Why the rewrite rules live in the routing file and not as flat env entries (round 2 fix).**
/// `url.*.insteadOf`/`pushInsteadOf` match by STRING PREFIX, with no word boundary — confirmed
/// against real git 2.54 that `git@github.com:owner/iris.git` is a literal string prefix of
/// `git@github.com:owner/iris.github.io.git` (`"iris.git"` is exactly the first 8 characters of
/// `"iris.github.io.git"`). Injecting the rewrite directly as an unconditional
/// `GIT_CONFIG_KEY`/`VALUE` entry (round 1's design) meant it was part of the effective config for
/// *any* git invocation sharing that process's environment, so an unrelated, unlisted repo
/// (`owner/iris.github.io`) whose name merely shares a prefix with an allowed one (`owner/iris`)
/// had its own remote silently rewritten too — confirmed with a real `git ls-remote --get-url`.
/// `includeIf.hasconfig` has no such hazard: it is evaluated per the *current repository's own*
/// config being resolved, so a file is included only when that repository's own `remote.*.url`
/// exactly matches — confirmed with a real git invocation that a shared routing file holding both
/// an allowed repo's section and an unrelated repo's section leaves the unrelated repo's URL
/// completely untouched when *it* is the one being resolved. Moving the rewrite rules into that
/// conditionally-included file, rather than injecting them unconditionally, is what actually
/// scopes them to the exact repo.
///
/// **Why `insteadOf`, not `pushInsteadOf`, and why each https spelling also gets an identity
/// rule onto itself.** `pushInsteadOf` only rewrites push, and on a Mac with a pre-existing
/// global rule like `url.ssh://git@github.com/.insteadOf = https://github.com/` (from `gh auth
/// setup-git` or similar), `insteadOf` resolution picks the LONGEST matching prefix across every
/// `url.*.insteadOf` rule in the merged config — not the one read last — so that short, generic
/// global rule intercepts an already-https remote before anything keyed on an SSH source could
/// apply, and `pushInsteadOf` alone left identity applying while the push still ran over the
/// user's ambient SSH key (dev-3's review, reproduced live: a silent identity-separation failure,
/// not a loud one). An identity rule whose own prefix *is* the exact repo URL is longer and more
/// specific than the generic global one, so it wins the match and the URL never leaves https; it
/// needs its own entry for every https spelling (with and without `.git`), since a shorter https
/// spelling doesn't, as a string, contain the longer one.
///
/// A remote for a repo **not** on the list gets neither identity nor a rewrite — no
/// `includeIf` condition names it, so its config resolution never even reaches the routing file.
enum GitIdentityEnvironment {
    /// Whether `run_command`'s host path should carry the GitHub git identity at all: a
    /// configured token, a configured account login whose token `GET /user` confirmed (#1184), a non-empty allowlist, and -- planner's
    /// ruling, 2026-11-15 -- the turn not being guest-origin. Pulled out as its own pure function so
    /// the decision is directly unit-testable without touching `ConfigManager.shared` or a real
    /// conversation. An unset login is the same as no token: no behaviour change at all.
    ///
    /// Takes `accountId` itself, not a separate `identityMatches` bool (#1194 review, dev-2's
    /// finding): the caller reads `ConfigManager.shared.githubAccountId` exactly once and passes
    /// that same value both here and to `ensureFragment`, so the two can never disagree about
    /// which state they saw across two lock acquisitions. `accountId == nil` already covers "no
    /// match" (`ConfigManager.githubAccountId`'s own getter is nil whenever `githubIdentity` isn't
    /// `.match`), so this also means a match GitHub answered with no readable id leaves git
    /// identity off rather than writing the unattributed bare noreply form.
    static func shouldApply(hasToken: Bool, login: String?, accountId: Int?, repos: [String], guestOrigin: Bool) -> Bool {
        hasToken && login != nil && accountId != nil && !repos.isEmpty && !guestOrigin
    }

    /// The identity's name and email come from the login (`GitHubProxyClient.commitIdentity`): GitHub's
    /// noreply convention, so no separate email setting exists to configure or leak.
    static let fragmentFileName = "git-identity"
    static let routingFileName = "git-identity-routing"

    /// The static fragment's contents: identity plus the credential helper, no secret. The
    /// leading empty `helper =` clears any `credential.helper` inherited from `~/.gitconfig` or
    /// system config before this point in the read order (it's a multi-valued key; an ambient
    /// helper already holding the user's own cached GitHub credential must never be consulted for
    /// a configured-account remote) — the same empty-then-set pattern `WorkspaceGit.overrides`
    /// already uses for the same reason. `useHttpPath` is required or the helper never receives a
    /// `path` to check the allowlist against (dev-3's review).
    /// #1435 slice 3 (Brian's F5): identity only. The credential left host git; pushing is `vcs push`, whose mirror runs
    /// Iris's helper itself (`VCSMirror.helperConfig`). The empty `helper` clears any the person's own config sets.
    static func fragmentContents(login: String, accountId: Int?) -> String {
        let identity = GitHubProxyClient.commitIdentity(login: login, accountId: accountId)
        return """
        [user]
        \tname = \(identity.name)
        \temail = \(identity.email)
        [credential]
        \thelper =
        """
    }

    /// Writes the fragment if it doesn't exist, or rewrites it if its contents differ from what's
    /// computed now (dev-2's and dev-3's review: the helper's executable path can change across a
    /// rebuild, a reinstall, or a dev home shared between worktrees, and the fragment must not
    /// keep pointing at a now-stale one). No secret in it, safe to call on every launch.
    static func ensureFragment(at path: String, login: String, accountId: Int?) {
        let contents = fragmentContents(login: login, accountId: accountId)
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing == contents { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                  withIntermediateDirectories: true)
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Every URL spelling a `repo` remote might legitimately have: three forms (`https://`,
    /// `git@host:`, `ssh://git@host/`) each with and without the `.git` suffix -- six total. Git
    /// clients vary on which one a person or `gh` actually configures, and both need the identity
    /// (and, for the SSH forms, the push rewrite) to apply.
    ///
    /// **Known residual (planner's ruling, 2026-11-15): a second remote in the SAME checkout
    /// whose name string-extends the allowed repo.** The `includeIf.hasconfig` gate gives us
    /// per-REPOSITORY scoping (confirmed in the type doc and `prefixCollisionRepoUnaffected`), but
    /// once ANY remote in a repo's config matches and the routing file loads, its `insteadOf`
    /// rules become part of the effective config for every remote resolved in that SAME
    /// repository -- including one that only coincidentally shares a string prefix. An allowed
    /// `owner/iris` with a second remote `upstream` pointing at `owner/iris-fork` (unrelated,
    /// not on the allowlist) resolves to a mangled URL
    /// (`https://github.com/owner/iris.git-fork.git`), confirmed empirically. This fails loudly
    /// (a 404/malformed-URL push failure) rather than falling back to the ambient SSH key
    /// silently, which is the trade the planner accepted: the alternative (not rewriting at all)
    /// is exactly the silent ambient-identity failure this feature exists to close. Pinned by
    /// `secondRemoteInSameCheckoutMangledNotSilent`, a real-git test.
    private static func remoteSpellings(_ repo: String) -> (https: [String], ssh: [String]) {
        let suffixes = ["", ".git"]
        let https = suffixes.map { "https://github.com/\(repo)\($0)" }
        let ssh = suffixes.map { "git@github.com:\(repo)\($0)" } + suffixes.map { "ssh://git@github.com/\(repo)\($0)" }
        return (https, ssh)
    }

    /// The routing file's content for the live `repos`: one section per valid repo, each starting
    /// with an `[include]` of the static identity fragment, then that repo's own rewrite rules.
    /// A stored entry that isn't a strict `owner/name` (shouldn't happen -- `setRepos` already
    /// refuses one -- but never trusted twice) is skipped entirely.
    static func routingContents(repos: [String], identityFragmentPath: String) -> String {
        var sections: [String] = []
        for repo in repos where GitHubProxyClient.isOwnerName(repo) {
            let (httpsForms, sshForms) = remoteSpellings(repo)
            let canonical = httpsForms[1]
            // The canonical (.git) form's own [url] block: the identity rule (rewritten to
            // itself) plus every SSH spelling rewritten onto it.
            var lines = ["[include]", "\tpath = \(identityFragmentPath)",
                        "[url \"\(canonical)\"]", "\tinsteadOf = \(canonical)"]
            for sshForm in sshForms { lines.append("\tinsteadOf = \(sshForm)") }
            // Every OTHER https spelling (just the no-suffix one) needs its own [url] block with
            // its own identity rule: a shorter spelling isn't itself matched by a longer one's
            // block above.
            for httpsForm in httpsForms where httpsForm != canonical {
                lines.append("[url \"\(httpsForm)\"]")
                lines.append("\tinsteadOf = \(httpsForm)")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n")
    }

    /// Writes the routing file fresh every time -- unlike the identity fragment, this always
    /// reflects the live allowlist, so adding a repo takes effect on the very next `run_command`
    /// call (planner's correction, 2026-11-15). Cheap for any realistic allowlist size.
    static func writeRoutingFile(repos: [String], identityFragmentPath: String, to path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                  withIntermediateDirectories: true)
        try? routingContents(repos: repos, identityFragmentPath: identityFragmentPath).write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The `includeIf` `GIT_CONFIG_KEY`/`VALUE` pairs for every repo in `repos`, all pointing at
    /// `routingPath` -- the rewrite rules themselves live in that file's content (`routingContents`),
    /// never injected directly here, so they're reachable only when `hasconfig` finds an exact
    /// match against the repository actually being resolved (see the type doc on the collision
    /// this avoids).
    static func additions(repos: [String], routingPath: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        for repo in repos where GitHubProxyClient.isOwnerName(repo) {
            let (httpsForms, sshForms) = remoteSpellings(repo)
            for url in httpsForms + sshForms {
                pairs.append((key: "includeIf.hasconfig:remote.*.url:\(url).path", value: routingPath))
            }
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
    static func environment(repos: [String], routingPath: String, base: [String: String]) -> [String: String] {
        let pairs = additions(repos: repos, routingPath: routingPath)
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
