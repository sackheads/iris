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
        // A file that grants permissions must not be writable through an auto-allow. `config/`
        // holds permissions.json, the hook definitions and the plugin config, and `isAllowed`
        // re-reads that file on every call — so one carved-out write there would grant every
        // later call whatever it asked for. Unattended, the refusal is absolute: not even an
        // explicit rule hands a background run the keys.
        let targetsConfig = isWrite && paths.isUnderConfigDir(details)
        if targetsConfig && isBackground { return false }

        // Automatically allow access to agent's own ~/.iris directory — reads for anyone, writes
        // only for an attended caller and only outside `config/`.
        if toolName == "read_file" || (isWrite && !isBackground && !targetsConfig) {
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
