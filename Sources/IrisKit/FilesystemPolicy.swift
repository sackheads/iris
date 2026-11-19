import Foundation

/// #974 Task 8 (C5): what a binding may reach through the two host file tools. The owner keeps
/// today's unrestricted access (named exception, spec Inv 1/2026-11-15); every non-owner binding
/// is confined to a `JobGrant` — the same shape a background job's sandbox grant already is — so
/// `ToolExecutor`'s existing grant-walk logic (`grantedComponents`, `allowedMount`) gates it with
/// no new routing code. An absent grant confines to nothing (deny-all), never "no grant, so
/// unrestricted": that would be exactly the fail-open this task closes.
enum FilesystemPolicy: Equatable, Sendable {
    case unrestrictedOwner
    case confined(JobGrant)

    static func resolve(binding: AccessBinding, grant: JobGrant?) -> FilesystemPolicy {
        binding.isOwner ? .unrestrictedOwner : .confined(grant ?? JobGrant())
    }

    /// The non-owner host-read denial set (replaces the non-existent `deniedHomeSubpaths`,
    /// spec/plan Task 8). `JobGrant.credentialStores` already denies most of these as *mount*
    /// targets for a background job's grant, but it has no `~/.netrc`/`~/.git-credentials` and
    /// does not gate a host `read_file` at all — this is a new, separate mechanism even for the
    /// paths it already lists. `~/.config` is denied whole (not just `~/.config/gh`): a non-owner
    /// binding has no legitimate reason to read another program's config directory on this host.
    /// `~/.iris`/`~/.iris-dev`: a non-owner must not read Iris's own directory on the host either,
    /// unlike the owner's first-party-read carve-out (`IrisPaths.default.isUnderIrisDir`) — that
    /// carve-out is about trusting content the OWNER's own agent already has standing access to,
    /// which does not extend to a bound, non-owner run.
    static let nonOwnerDeniedHostReads = [
        "/.netrc", "/.git-credentials", "/.ssh", "/.config/gh", "/.config", "/.iris", "/.iris-dev",
    ]

    /// Whether a non-owner's host read of `path` lands in or under a denied store. Compared on the
    /// RESOLVED path (`IrisPaths.canonicalPath`: `..` normalized, every symlink followed) so a
    /// symlink or a `..`-containing path that reaches a denied store is caught the same as the
    /// store's own direct spelling — Review Focus 4's security-critical case. Case-insensitive,
    /// matching `JobGrant.isCredentialStore`'s own comparison.
    ///
    /// dev-2 review of #1217, finding 1: a superset of `JobGrant.credentialStores` BY
    /// CONSTRUCTION, not by independently naming an overlapping-but-narrower list — a background
    /// job's grant already refuses `.aws`/`.gnupg`/`.docker`/`.kube`/`.password-store`/Keychains as
    /// *mount* targets, and this read gate must refuse at least that much. `isCredentialStore`'s
    /// own comparison is reused directly, so the two can never drift apart again.
    static func deniesNonOwnerHostRead(_ path: String, cwd: String? = nil, home: String = NSHomeDirectory()) -> Bool {
        let resolved = IrisPaths.canonicalPath(ToolExecutor.resolvePath(path, cwd: cwd))
        if JobGrant.isCredentialStore(resolved, home: home) { return true }
        let loweredResolved = resolved.lowercased()
        return nonOwnerDeniedHostReads.contains { suffix in
            let denied = IrisPaths.canonicalPath(home + suffix).lowercased()
            return loweredResolved == denied || loweredResolved.hasPrefix(denied + "/")
        }
    }

    /// dev-2 review of #1217, finding 1: a non-owner's `fsRoots` must go through the SAME mount
    /// validation a background job's user-named grant does (`JobGrant.resolve`'s refusals: too
    /// broad, protected, a credential store, a startup location, a login-PATH entry) — building a
    /// `JobGrant` directly from `fsRoots` bypassed every one of those, so a non-owner could still
    /// reach `~/.zshrc` or `~/Library/LaunchAgents` through a root that would never have survived
    /// `resolve`. Any root that fails validation is dropped from the grant (fails closed per root,
    /// never the whole binding to owner-shaped access); `profile: .mutating` is required for
    /// `resolve` to accept mounts at all, and this grant is never network-enabled.
    static func grant(fromFsRoots fsRoots: Set<String>) -> JobGrant {
        var mounts: [ContainerMount] = []
        for root in fsRoots.sorted() {
            switch JobGrant.resolve(mounts: [root], network: nil, profile: .mutating) {
            case .success(let validated):
                if let m = validated?.mounts.first { mounts.append(m) }
            case .failure:
                continue
            }
        }
        return JobGrant(mounts: mounts)
    }
}
