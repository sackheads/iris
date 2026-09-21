import Foundation

struct PermissionRule: Codable, Equatable {
    let toolName: String
    let details: String
}

struct PermissionManager: Sendable {
    static let shared = PermissionManager()

    private let paths: IrisPaths
    private var globalPermissionsURL: URL { paths.permissionsJSON }

    private init() {
        try? IrisPaths.default.ensureDirectories()
        paths = IrisPaths.default
    }

    /// Injectable home, so a test can exercise the `~/.iris` carve-out below against a temp
    /// directory instead of the machine's real allowlist.
    init(paths: IrisPaths) {
        try? paths.ensureDirectories()
        self.paths = paths
    }
    
    private func projectPermissionsURL(for workspace: String) -> URL {
        return URL(fileURLWithPath: workspace).appendingPathComponent(".iris").appendingPathComponent("permissions.json")
    }
    
    /// `isBackground` is the unattended caller: a job run, or any subagent descended from one.
    /// It narrows the `~/.iris` carve-out to reads, because nobody is watching what it writes.
    func isAllowed(toolName: String, details: String, workspace: String?, isBackground: Bool = false) -> Bool {
        let isWrite = (toolName == "write_file")
        // A write that grants permissions must not come from an auto-allow. `IrisPaths`
        // enumerates the directories that qualify (`config/`, `plugins/`) and resolves case and
        // symlinks before deciding, since `isAllowed` re-reads the allowlist on every call — one
        // carved-out write there would grant every later call whatever it asked for. Unattended,
        // the refusal is absolute: not even an explicit rule hands a background run the keys.
        let targetsProtected = isProtectedWrite(toolName: toolName, path: details)
        if targetsProtected && isBackground { return false }

        // Automatically allow access to agent's own ~/.iris directory — reads for anyone, writes
        // only for an attended caller and only outside the protected directories.
        if toolName == "read_file" || (isWrite && !isBackground && !targetsProtected) {
            if paths.isUnderIrisDir(details) { return true }
        }

        let rule = PermissionRule(toolName: toolName, details: details)
        
        // Check global
        if let globalRules = loadRules(from: globalPermissionsURL), globalRules.contains(rule) {
            return true
        }
        
        // Check project
        if let workspace = workspace {
            let projectURL = projectPermissionsURL(for: workspace)
            if let projectRules = loadRules(from: projectURL), projectRules.contains(rule) {
                return true
            }
        }
        
        return false
    }
    
    /// Whether this call would write into a directory where a write is a *grant* rather than an
    /// edit — `IrisPaths.protectedWriteDirs`, resolved canonically. The one refusal that is not a
    /// question of who is asking: `isAllowed` never auto-allows one, and neither does a human
    /// clicking "Approve and run" on an event card (#187 R10). A click says a person vouches for
    /// the call; it cannot make `permissions.json` or a plugin an ordinary file.
    ///
    /// Deny-side only, like `isUnderProtectedWriteDir` itself: never invert it to widen an allow.
    func isProtectedWrite(toolName: String, path: String) -> Bool {
        toolName == "write_file" && paths.isUnderProtectedWriteDir(path)
    }

    /// The same question about a persisted call, asked of the path it would actually write (which
    /// is resolved against the run's directory, not the spelling the model sent).
    func isProtectedWrite(_ call: BlockedCall) -> Bool {
        guard let target = call.writeTarget else { return false }
        return isProtectedWrite(toolName: call.toolName, path: target)
    }

    func allowGlobally(toolName: String, details: String) {
        let rule = PermissionRule(toolName: toolName, details: details)
        var rules = loadRules(from: globalPermissionsURL) ?? []
        if !rules.contains(rule) {
            rules.append(rule)
            saveRules(rules, to: globalPermissionsURL)
        }
    }
    
    func allowInProject(toolName: String, details: String, workspace: String) {
        let projectURL = projectPermissionsURL(for: workspace)
        let projectDir = projectURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: projectDir.path) {
            try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        }
        
        let rule = PermissionRule(toolName: toolName, details: details)
        var rules = loadRules(from: projectURL) ?? []
        if !rules.contains(rule) {
            rules.append(rule)
            saveRules(rules, to: projectURL)
        }
    }
    
    private func loadRules(from url: URL) -> [PermissionRule]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([PermissionRule].self, from: data)
    }
    
    private func saveRules(_ rules: [PermissionRule], to url: URL) {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: url)
        }
    }
}
