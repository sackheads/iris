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
    static func deniesNonOwnerHostRead(_ path: String, cwd: String? = nil, home: String = NSHomeDirectory()) -> Bool {
        let resolved = IrisPaths.canonicalPath(ToolExecutor.resolvePath(path, cwd: cwd)).lowercased()
        return nonOwnerDeniedHostReads.contains { suffix in
            let denied = IrisPaths.canonicalPath(home + suffix).lowercased()
            return resolved == denied || resolved.hasPrefix(denied + "/")
        }
    }
}
