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
    /// Name fragments that make a file (or any folder on the way to it) still ask under a directory rule.
    /// Case-insensitive SUBSTRINGS, because the failure that matters is a secret nobody listed: this errs
    /// toward asking, so `token.swift` or `history.md` costs one prompt (the exact rule is still one click
    /// away) and a `.vault-token` or `terraform.tfstate` never rides a folder rule. Deny-side only.
    private static let sensitiveFragments = [
        "secret", "password", "passwd", "credential", "token", "private", "tfstate", "tfvars", "kubeconfig",
        "keystore", "wallet", "ssh_host", "history", "cookies", "login data", "key4.db", "cert9.db", "logins.json",
        "service-account", "service_account", "serviceaccount", "vault", "apikey", "api_key", "api-key", "oauth", "bearer",
    ]
    /// Extensions and exact names that are credentials by shape.
    private static let sensitiveSuffixes = [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".kdbx", ".ovpn", ".jks", ".gpg", ".pgp", ".ppk"]
    private static let sensitiveNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".pgpass", ".dockercfg", ".s3cfg", ".boto", ".htpasswd", "authorized_keys", "known_hosts",
    ]
    /// Folders whose contents are credentials or credential config, wherever they sit under a rule's folder.
    private static let sensitiveFolders: Set<String> = [
        ".ssh", ".aws", ".gnupg", ".gpg", ".kube", ".docker", ".azure", ".password-store", ".terraform.d", ".config",
        ".secrets", "secrets", ".git-credentials", ".cache", ".local", ".zsh_sessions",
    ]

    /// Whether one path component (a file or a folder name) says it holds something sensitive.
    static func isSensitiveName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == ".env" || lowered.hasPrefix(".env.") || lowered.hasSuffix(".env") { return true }
        if sensitiveNames.contains(lowered) { return true }
        for key in ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"] where lowered.hasPrefix(key) { return true }
        if sensitiveSuffixes.contains(where: { lowered.hasSuffix($0) }) { return true }
        return sensitiveFragments.contains { lowered.contains($0) }
    }

    /// Kept for callers that ask about a bare file name.
    static func isSecretFileName(_ name: String) -> Bool { isSensitiveName(name) }

    /// Whether a read of `components` (the path BELOW the rule's folder) still asks: any component that
    /// says it is sensitive, a credential folder on the way, or a `.git` folder's `config`/`credentials`
    /// (a remote URL there can carry a token).
    static func isSensitivePath(below components: [String]) -> Bool {
        let lowered = components.map { $0.lowercased() }
        if lowered.contains(where: { isSensitiveName($0) || sensitiveFolders.contains($0) }) { return true }
        if let gitIndex = lowered.firstIndex(of: ".git"), gitIndex < lowered.count - 1 {
            let last = lowered[lowered.count - 1]
            if last == "config" || last == "credentials" || last.hasPrefix("config.") { return true }
        }
        return false
    }

    /// Whether `directory` (a resolved absolute path) may be the subject of a directory rule at all.
    static func isEligible(_ directory: String, home: String = NSHomeDirectory(), paths: IrisPaths = .default) -> Bool {
        guard directory.hasPrefix("/") else { return false }
        var components = directory.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else { return false }
        // A read arrives as its real path, where macOS spells `/etc`, `/var` and `/tmp` under `/private`:
        // that prefix does not make `/private/etc` a deeper folder.
        if components.first == "private" { components.removeFirst() }
        // `/`, and a top-level folder (`/etc`, `/Users`, `/var`): too broad to be one decision.
        guard components.count >= 2 else { return false }
        // System folders (`/Library`, `/var`, `/usr`, ...) hold the machine's own configuration, logs and
        // credentials; temp folders under `/var/folders` are the one place a person's files sit there.
        let resolvedSystem = IrisPaths.canonicalPath(directory)
        let systemRoots = ["/etc", "/private/etc", "/var", "/private/var", "/Library", "/System", "/usr", "/bin", "/sbin", "/dev", "/cores", "/opt"]
        let temp = ["/var/folders", "/private/var/folders", "/var/tmp", "/private/var/tmp", "/tmp", "/private/tmp"]
        let inTemp = temp.contains { resolvedSystem == $0 || resolvedSystem.hasPrefix($0 + "/") }
        if !inTemp, systemRoots.contains(where: { resolvedSystem == $0 || resolvedSystem.hasPrefix($0 + "/") }) { return false }
        // A volume root (`/Volumes/Backup`) is a whole disk, not a project.
        if components.first == "Volumes", components.count < 3 { return false }
        let resolved = resolvedSystem
        let realHome = IrisPaths.canonicalPath(home)
        // Everything under the home's Library (browser profiles, Mail, Messages, Safari, iCloud Drive,
        // Preferences): app data, not a project.
        if resolved == realHome + "/Library" || resolved.hasPrefix(realHome + "/Library/") { return false }
        // The home directory itself and everything above it.
        if resolved == realHome || realHome.hasPrefix(resolved + "/") { return false }
        // Is, holds or sits under a credential store.
        if JobGrant.isCredentialStore(resolved, home: home) { return false }
        // A folder that is itself named for something sensitive (`secrets/`, `.config/`, `private-keys/`),
        // judged below the home where there is one: the person's own folders, not the system's spelling.
        let below = resolved.hasPrefix(realHome + "/") ? String(resolved.dropFirst(realHome.count)) : resolved
        if isSensitivePath(below: below.split(separator: "/").map(String.init)) { return false }
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
        guard !isSensitiveName(url.lastPathComponent) else { return nil }
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
        guard isUnder(path, directory: real) else { return false }
        // What is below the folder: a sensitive file or folder on the way still asks.
        let relative = String(path.dropFirst(real.count)).split(separator: "/").map(String.init)
        guard !isSensitivePath(below: relative) else { return false }
        guard !JobGrant.isCredentialStore(IrisPaths.canonicalPath(path), home: home) else { return false }
        return true
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
