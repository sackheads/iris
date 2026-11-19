import Foundation

/// #1136: a directory-scoped Always Allow for `read_file`. An exact rule saves one resolved path, so
/// approving reads across a project piles up one rule per file; a directory rule says "reads under
/// this folder" instead. It is a standing allow, so it is narrow by construction:
///
/// - reads only (`write_file` never gets one), attended only (an unattended run keeps its grant; a
///   guest-origin turn re-asks, like every saved rule);
/// - never offered, and never honoured, for a directory that is too broad (the root, a top-level
///   folder, the home directory or anything above it) or that is, holds or sits under a credential
///   store (`JobGrant.credentialStores`), checked again when the rule is READ so a hand-edited
///   `permissions.json` cannot widen it past what the dialog would have offered;
/// - a file whose name says it holds a secret (`.env`, `*.pem`, `id_rsa`, `.netrc`, ...) is not covered
///   by a directory rule and still asks, so a project folder's rule does not hand over its keys;
/// - matched on the resolved real path on a component boundary (`/a/b` covers `/a/b/c`, not `/a/bc`),
///   ignoring case only where the volume does.
enum DirectoryReadRule {
    /// File names that still ask under a directory rule. Deny-side hardening on an allow: a name here
    /// costs one prompt, never a leak.
    static func isSecretFileName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == ".env" || lowered.hasPrefix(".env.") || lowered.hasSuffix(".env") { return true }
        if [".netrc", ".git-credentials", ".npmrc", ".pgpass", ".pypirc", "credentials", "credentials.json",
            "secrets.json", "secrets.yml", "secrets.yaml", "token", "tokens.json"].contains(lowered) { return true }
        if lowered.hasPrefix("id_rsa") || lowered.hasPrefix("id_dsa") || lowered.hasPrefix("id_ecdsa") || lowered.hasPrefix("id_ed25519") { return true }
        return [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".kdbx"].contains { lowered.hasSuffix($0) }
    }

    /// Whether `directory` (a resolved absolute path) may be the subject of a directory rule at all.
    static func isEligible(_ directory: String, home: String = NSHomeDirectory(), paths: IrisPaths = .default) -> Bool {
        guard directory.hasPrefix("/") else { return false }
        let components = directory.split(separator: "/", omittingEmptySubsequences: true)
        // `/`, and a top-level folder (`/etc`, `/Users`, `/var`): too broad to be one decision.
        guard components.count >= 2, !components.contains("..") else { return false }
        let resolved = IrisPaths.canonicalPath(directory)
        let realHome = IrisPaths.canonicalPath(home)
        // The home directory itself and everything above it.
        if resolved == realHome || realHome.hasPrefix(resolved + "/") { return false }
        // Is, holds or sits under a credential store.
        if JobGrant.isCredentialStore(resolved, home: home) { return false }
        // Iris's own folder reads are already allowed for the owner, and a rule over it adds nothing
        // but a way to widen it.
        if paths.isUnderIrisDir(resolved) { return false }
        return !SecretLikeDetector.containsSecretLikeSubstring(directory)
    }

    /// The directory a "reads under this folder" rule would name for a read of `path` (already the
    /// resolved real path, as the dispatcher hands it over), or nil when none may be offered.
    static func directory(forReadOf path: String, home: String = NSHomeDirectory(), paths: IrisPaths = .default) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        guard !isSecretFileName(url.lastPathComponent) else { return nil }
        let parent = url.deletingLastPathComponent().path
        return isEligible(parent, home: home, paths: paths) ? parent : nil
    }

    /// Whether a saved directory rule covers a read of `path`.
    static func covers(directory ruleDirectory: String, read path: String, home: String = NSHomeDirectory(),
                       paths: IrisPaths = .default) -> Bool {
        guard path.hasPrefix("/"), ruleDirectory.hasPrefix("/") else { return false }
        // The rule's directory at its real location now: a link swapped in since it was saved
        // resolves elsewhere and is judged there.
        let real = IrisPaths.realPath(ruleDirectory)
        guard isEligible(real, home: home, paths: paths) else { return false }
        guard !isSecretFileName(URL(fileURLWithPath: path).lastPathComponent) else { return false }
        guard !JobGrant.isCredentialStore(IrisPaths.canonicalPath(path), home: home) else { return false }
        return isUnder(path, directory: real)
    }

    /// `path` strictly inside `directory`, on a component boundary, ignoring case where the volume does.
    static func isUnder(_ path: String, directory: String) -> Bool {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        if path.hasPrefix(prefix), path.count > prefix.count { return true }
        guard path.count > prefix.count, path.lowercased().hasPrefix(prefix.lowercased()) else { return false }
        let head = String(path.prefix(directory.count))
        return IrisPaths.samePath(head, directory)
    }
}

extension PermissionRule {
    /// The rule a "reads under this folder" click saves for a `read_file` of `details`, or nil.
    static func forAlwaysAllowDirectory(toolName: String, details: String, home: String = NSHomeDirectory(),
                                        paths: IrisPaths = .default) -> PermissionRule? {
        guard toolName == "read_file",
              let directory = DirectoryReadRule.directory(forReadOf: details, home: home, paths: paths) else { return nil }
        return PermissionRule(toolName: toolName, details: directory, match: .directory)
    }
}
