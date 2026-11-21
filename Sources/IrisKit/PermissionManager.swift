import Foundation

struct PermissionRule: Codable, Equatable, Sendable {
    /// How a rule's `details` is compared with a call's (#1102). A string, not an enum, so a kind a
    /// newer build writes neither makes the whole file unreadable here nor is lost when this build
    /// saves it back; such a rule matches nothing.
    struct Match: RawRepresentable, Codable, Equatable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        /// The whole text, or for a file tool the same file (`PermissionManager.rule(_:matches:)`).
        static let exact = Match(rawValue: "exact")
        /// `run_command` only: `details` is a space-separated word prefix (`git status`), and a
        /// command matches when each of its parts starts with one (`CommandPattern`). Attended
        /// calls only.
        static let prefix = Match(rawValue: "prefix")
        /// `read_file` only (#1136): `details` is an absolute directory, and a read matches when its
        /// resolved path is inside it (`DirectoryReadRule`). Attended calls only. An older build
        /// reads it as an exact rule, which matches only that directory's own spelling, never a file.
        static let directory = Match(rawValue: "directory")
    }

    let toolName: String
    let details: String
    /// nil is `exact`: every rule saved before #1102, and the key is left out when written, so an
    /// older build reads a new file's exact rules unchanged. Optional, so a missing key decodes
    /// (Invariant 1). An older build reads a prefix rule as an exact one, which matches only the
    /// bare prefix itself (`git status`), never more.
    var match: Match? = nil

    var isPrefix: Bool { match == .prefix }
    var isDirectory: Bool { match == .directory }
    var isExact: Bool { match == nil || match == .exact }

    /// The rules an "Always Allow" click on this call saves: a prefix per part of a command that
    /// has one (#1102), else the call exactly as asked.
    static func forAlwaysAllow(toolName: String, details: String) -> [PermissionRule] {
        if toolName == "run_command", let prefixes = CommandPattern.alwaysAllowPrefixes(details) {
            return prefixes.map { PermissionRule(toolName: toolName, details: $0.joined(separator: " "), match: .prefix) }
        }
        return [PermissionRule(toolName: toolName, details: details)]
    }
}

/// Which part of the allowlist let a call run (#599): Iris's own folder, or a rule, with the
/// rule's text as it was when it matched, so a rule edited later does not change the record.
struct AllowMatch: Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case irisHome, global, project }
    var scope: Scope
    /// nil for `irisHome`, which no rule grants.
    var rule: PermissionRule?
}

struct PermissionManager: Sendable {
    static let shared = PermissionManager()

    let paths: IrisPaths
    /// A dev process's home is `~/.iris-dev`, which leaves the installed app's `config/` and
    /// `plugins/` as plain absolute paths to it; `isProtectedWrite` keeps them grants too.
    private let identity: BuildIdentity
    private let release: IrisPaths
    private var globalPermissionsURL: URL { paths.permissionsJSON }

    private init() {
        try? IrisPaths.default.ensureDirectories()
        paths = IrisPaths.default
        identity = .current
        release = .release
    }

    /// Injectable home, so a test can exercise the `~/.iris` carve-out below against a temp
    /// directory instead of the machine's real allowlist. `identity` and `release` likewise, so a
    /// test decides the release-home rule without depending on the process or touching `~/.iris`.
    init(paths: IrisPaths, identity: BuildIdentity = .current, release: IrisPaths = .release) {
        try? paths.ensureDirectories()
        self.paths = paths
        self.identity = identity
        self.release = release
    }
    
    private func projectPermissionsURL(for workspace: String) -> URL {
        return URL(fileURLWithPath: workspace).appendingPathComponent(".iris").appendingPathComponent("permissions.json")
    }
    
    /// `isBackground` is the unattended caller: a job run, or any subagent descended from one.
    /// It narrows the `~/.iris` carve-out to reads, because nobody is watching what it writes.
    /// `isGuestOrigin` (#1141) is a turn a guest's message started or steered: no saved rule, exact or
    /// prefix, applies to it. `isOwner` (#974 Task 9, R3; #1270: required, not defaulted — a caller
    /// that forgot to resolve a binding used to silently read as owner) is a non-owner binding (a
    /// scoped subagent or guest-steered profile, #1216's class — distinct from `isGuestOrigin`, which
    /// is about provenance, not identity) losing the `~/.iris` carve-out below even when it is not
    /// guest-origin.
    func isAllowed(toolName: String, details: String, workspace: String?, isBackground: Bool = false, isGuestOrigin: Bool = false,
                   isOwner: Bool) -> Bool {
        match(toolName: toolName, details: details, workspace: workspace, isBackground: isBackground, isGuestOrigin: isGuestOrigin,
              isOwner: isOwner) != nil
    }

    /// `isAllowed`, saying which part of the allowlist let the call run (#599).
    func match(toolName: String, details: String, workspace: String?, isBackground: Bool = false, isGuestOrigin: Bool = false,
               isOwner: Bool) -> AllowMatch? {
        let isWrite = (toolName == "write_file")
        // A write that grants permissions must not come from an auto-allow. `IrisPaths`
        // enumerates the directories that qualify (`config/`, `plugins/`) and resolves case and
        // symlinks before deciding, since `isAllowed` re-reads the allowlist on every call — one
        // carved-out write there would grant every later call whatever it asked for. Unattended,
        // the refusal is absolute: not even an explicit rule hands a background run the keys.
        let targetsProtected = isProtectedWrite(toolName: toolName, path: details)
        if targetsProtected && isBackground { return nil }

        // Automatically allow access to agent's own ~/.iris directory — reads and writes for the
        // OWNER only (#974 Task 9, R3: removed the open-to-anyone read carve-out -- a non-owner
        // binding, guest-origin or not, must not read memory/skills/config just because nobody
        // steered it; #1216 is the same class of non-owner, non-guest-origin binding this closes).
        // Writes stay gated as before, attended and outside the protected directories. Not on a
        // guest-origin turn (#1150): a guest-steered write there could plant memory or a skill.
        if toolName == "read_file" || (isWrite && !isBackground && !targetsProtected) {
            if isOwner, !isGuestOrigin, paths.isUnderIrisDir(details) { return AllowMatch(scope: .irisHome, rule: nil) }
        }

        // #1141: a turn a guest's message started or steered re-asks for every call a saved rule
        // would have waved through, exact or prefix. A standing "yes" is the person's answer to
        // their own request, not to one a guest steered the session toward (#1119's class).
        if isGuestOrigin { return nil }

        let globalRules = loadRules(from: globalPermissionsURL) ?? []
        let projectRules = workspace.flatMap { loadProjectRules(workspace: $0) } ?? []

        // Check global
        if let rule = globalRules.first(where: { Self.rule($0, matches: toolName, details, base: nil) }) {
            return AllowMatch(scope: .global, rule: rule)
        }
        
        // Check project
        if let workspace, let rule = projectRules.first(where: { Self.rule($0, matches: toolName, details, base: workspace) }) {
            return AllowMatch(scope: .project, rule: rule)
        }

        // #1136: a directory rule covers a `read_file` under its folder. Attended only, for the same reason
        // as the prefix rules below (a guest-origin turn returned above).
        if toolName == "read_file", !isBackground {
            let directoryRules = (globalRules.map { ($0, AllowMatch.Scope.global) } + projectRules.map { ($0, AllowMatch.Scope.project) })
                .filter { $0.0.toolName == toolName && $0.0.isDirectory }
            if let hit = directoryRules.first(where: { DirectoryReadRule.covers(directory: $0.0.details, read: details, paths: paths) }) {
                return AllowMatch(scope: hit.1, rule: hit.0)
            }
        }

        // #1102: prefix rules, global and project together, since one part of a chain can match a
        // global rule and another a project one. Attended only (a guest-origin turn returned above):
        // an unattended run has its grant, and a standing rule widened for a person's convenience is
        // not one to read unwatched.
        if toolName == "run_command", !isBackground {
            let prefixRules = (globalRules.map { ($0, AllowMatch.Scope.global) } + projectRules.map { ($0, AllowMatch.Scope.project) })
                .filter { $0.0.toolName == toolName && $0.0.isPrefix }
            let prefixes = prefixRules.map { $0.0.details.split(separator: " ").map(String.init) }
            if let used = CommandPattern.matchedPrefixes(details, prefixes: prefixes, workspace: workspace) {
                var seen: [Int] = []
                for index in used where !seen.contains(index) { seen.append(index) }
                let scope: AllowMatch.Scope = seen.contains { prefixRules[$0].1 == .project } ? .project : .global
                // What the pill records: every rule that matched, as it read when it matched.
                let record = PermissionRule(toolName: toolName,
                                            details: seen.map { prefixRules[$0].0.details }.joined(separator: "; "),
                                            match: .prefix)
                return AllowMatch(scope: scope, rule: record)
            }
        }
        
        return nil
    }

    /// Exact, or for a file tool the rule's path at its real location (#256), ignoring case where
    /// the volume does. The dispatcher hands a file tool's `details` over already resolved
    /// (`IrisEngine.decidedPath`), so a rule saved in another spelling of the same file —
    /// `~/notes.md`, a path through `/tmp`, or a project rule relative to its workspace (`base`) —
    /// is the same file and matches. A relative global rule has no directory to be relative to and
    /// matches only its exact spelling, which a resolved path never is.
    private static func rule(_ rule: PermissionRule, matches toolName: String, _ details: String, base: String?) -> Bool {
        guard rule.toolName == toolName, rule.isExact else { return false }
        if rule.details == details { return true }
        guard toolName == "read_file" || toolName == "write_file", details.hasPrefix("/") else { return false }
        let spelled = ToolExecutor.resolvePath(rule.details, cwd: base)
        guard spelled.hasPrefix("/") else { return false }
        return IrisPaths.samePath(IrisPaths.realPath(spelled), details)
    }
    
    /// Whether this call would write into a directory where a write is a *grant* rather than an
    /// edit — `IrisPaths.protectedWriteDirs`, resolved canonically. The one refusal that is not a
    /// question of who is asking: `isAllowed` never auto-allows one, and neither does a human
    /// clicking "Approve and run" on an event card (#187 R10). A click says a person vouches for
    /// the call; it cannot make `permissions.json` or a plugin an ordinary file.
    ///
    /// Deny-side only, like `isUnderProtectedWriteDir` itself: never invert it to widen an allow.
    /// In a dev process the installed app's protected directories count as well.
    func isProtectedWrite(toolName: String, path: String) -> Bool {
        guard toolName == "write_file" else { return false }
        if paths.isUnderProtectedWriteDir(path) { return true }
        return identity == .dev && release.isUnderProtectedWriteDir(path)
    }

    /// Whether a model or tool call writes a workspace's `.iris/` (#617), which always asks a
    /// person: Vibecop's rules and the project allowlist there decide what later runs unasked, so
    /// neither Vibecop nor an allowlist rule may approve a change to them. A file write by its
    /// resolved path; a host command when it names one (best effort, see
    /// `WorkspaceIrisDir.commandNamesWorkspaceIris`) or runs inside one. In the VM a command needs
    /// no such check: `.iris/` is mounted read-only there.
    func writesWorkspaceIris(toolName: String, details: String, workspace: String?, inSandbox: Bool) -> Bool {
        let homes = [paths.root.path, release.root.path].flatMap { [$0, IrisPaths.realPath($0)] }
        switch toolName {
        case "write_file":
            return WorkspaceIrisDir.isWorkspaceIrisPath(details, homes: homes)
        case "run_command":
            guard !inSandbox else { return false }
            if WorkspaceIrisDir.commandNamesWorkspaceIris(details) { return true }
            return workspace.map { WorkspaceIrisDir.isWorkspaceIrisPath($0, homes: homes) } ?? false
        default:
            return false
        }
    }

    /// Whether a host command would write one of the access-policy stores (#974 Task 9b, F6 /
    /// Invariant 6): `profiles/` and `config/a2a-peers/`. Task 3 gives the model no API for them, but
    /// a host command can still write the files, so such a command is a person's call alone (never an
    /// allowlist rule's or Vibecop's APPROVE), as a write to a workspace `.iris/` is. `write_file`
    /// is not this rule's: it is already a protected write (`isProtectedWrite`). In the VM a command
    /// needs no such check (`~/.iris` is not mounted there). A read-only command is not flagged:
    /// reading a profile is not the hazard. Best effort, like `commandNamesWorkspaceIris`: a command
    /// that builds the path at run time is not seen.
    func writesPolicyStore(toolName: String, details: String, workspace: String?, inSandbox: Bool) -> Bool {
        guard toolName == "run_command", !inSandbox else { return false }
        guard !ReadOnlyCommand.isReadOnly(details) else { return false }
        return PolicyStores.commandNamesStore(details, paths: paths, release: release, workspace: workspace)
    }

    /// Whether a call writes into a `.git` (#867). `write_file` is the host-side file writer under a
    /// grant; a command's VM writes are the mount's business (#623). An unattended run never gets
    /// this from the grant or the allowlist: the next `git` command a person runs would run it.
    func writesGitDir(toolName: String, details: String, workspace: String?) -> Bool {
        toolName == "write_file" && WorkspaceGitDir.isGitPath(details, cwd: workspace)
    }

    /// The same question about a persisted call, asked of the path it would actually write (which
    /// is resolved against the run's directory, not the spelling the model sent).
    func isProtectedWrite(_ call: BlockedCall) -> Bool {
        guard let target = call.writeTarget else { return false }
        return isProtectedWrite(toolName: call.toolName, path: target)
    }

    func allowGlobally(toolName: String, details: String) {
        allowGlobally([PermissionRule(toolName: toolName, details: details)])
    }

    func allowGlobally(_ new: [PermissionRule]) {
        var rules = loadRules(from: globalPermissionsURL) ?? []
        let added = new.filter { !rules.contains($0) }
        guard !added.isEmpty else { return }
        rules.append(contentsOf: added)
        saveRules(rules, to: globalPermissionsURL)
    }
    
    func allowInProject(toolName: String, details: String, workspace: String) {
        allowInProject([PermissionRule(toolName: toolName, details: details)], workspace: workspace)
    }

    func allowInProject(_ new: [PermissionRule], workspace: String) {
        let projectURL = projectPermissionsURL(for: workspace)
        // A real `.iris/` only (#617): one that is a link would put the rule where the sandbox
        // can write it, and the reader would refuse it anyway.
        guard case .ready = WorkspaceIrisDir.prepareForMount(IrisEngine.expandTilde(workspace)) else { return }

        var rules = loadProjectRules(workspace: workspace) ?? []
        var added = false
        for rule in new where !rules.contains(rule) {
            rules.append(rule)
            added = true
        }
        if added {
            // Iris wrote it, so Iris trusts it (#625): the person's click is the consent. The bytes
            // written, not a second encode: JSONEncoder's key order is not stable across calls, so a
            // re-encode can differ from the file and leave the click untrusted.
            if let written = saveRules(rules, to: projectURL, atomically: true) {
                WorkspaceIrisTrust(paths: paths).recordWritten("permissions.json", workspace: workspace, written: written)
            }
        }
    }
    
    private func loadRules(from url: URL) -> [PermissionRule]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([PermissionRule].self, from: data)
    }
    
    /// Through `WorkspaceIrisDir.read` (#617): a project allowlist that is a link, or a file with
    /// a second hard link, is one the sandbox could have written, so it grants nothing.
    private func loadProjectRules(workspace: String) -> [PermissionRule]? {
        guard let data = WorkspaceIrisDir.read("permissions.json", workspace: workspace,
                                               trust: WorkspaceIrisTrust(paths: paths)) else { return nil }
        return try? JSONDecoder().decode([PermissionRule].self, from: data)
    }

    /// `atomically` for a project file: the rename replaces a link left in its place, not the
    /// file it points to, and leaves one link to a new file.
    /// The bytes it wrote, or nil.
    @discardableResult
    private func saveRules(_ rules: [PermissionRule], to url: URL, atomically: Bool = false) -> Data? {
        guard let data = try? JSONEncoder().encode(rules),
              (try? data.write(to: url, options: atomically ? .atomic : [])) != nil else { return nil }
        return data
    }
}
