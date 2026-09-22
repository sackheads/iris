import Foundation

/// Single source of truth for every path under the home config directory (`~/.iris`).
///
/// Storage is segregated by owner: `memory/` (bot-authored, mutable, guard-sanitized),
/// `config/` (human/app config), and `models/` (downloaded bundles). Every consumer resolves
/// paths through here instead of re-deriving `("~/.iris" as NSString).expandingTildeInPath`,
/// which removes the duplication that produced the SOUL split-brain bug. `root` is injectable
/// so `IrisMigrator` and the memory managers can be unit-tested against a temp directory.
///
/// NOTE: `expandingTildeInPath` silently truncates its result to PATH_MAX, so it cannot be used
/// to measure a path's length — `IrisEngine.expandTilde` expands without that, and
/// `IrisEngine.workspaceRefusal` is where the resulting length rule lives (#273).
struct IrisPaths: Sendable {
    let root: URL

    init(root: URL) { self.root = root }

    /// The home every consumer resolves through. A headless perf run installs a volatile copy
    /// (see `useVolatileCopy(at:)`) before any manager is touched; nothing else ever sets it.
    static var `default`: IrisPaths { lock.withLock { override } ?? standard }

    /// The real home, regardless of any headless override — isolation tests compare file
    /// existence at this exact path before and after a test run and must never create anything
    /// here themselves.
    static let standard = IrisPaths(
        root: URL(fileURLWithPath: ("~/.iris" as NSString).expandingTildeInPath)
    )
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: IrisPaths?

    /// True only inside a headless run that installed a copy; never under `swift test`.
    static var isVolatileCopy: Bool { lock.withLock { override != nil } }

    /// Route every path at a fresh copy of the real home under `root` for the rest of the
    /// process. Real-lane perf runs wrote to the user's USER.md and fact store through
    /// `IrisPaths.default`, which neither the sandbox (run_command only) nor the scratch cwd
    /// (relative file tools only) covers. Must run before `MemoryManager.shared`,
    /// `FactStoreManager.shared`, or any other consumer captures `.default`.
    static func useVolatileCopy(at root: URL) throws {
        let copy = try makeVolatileCopy(of: standard, at: root)
        lock.withLock { override = copy }
    }

    /// Copy memory/, rules/, config/ and plugins/ into `root`; models/ is a symlink to the
    /// source (gigabytes, read-only). Reads see the same context; writes stay in the copy.
    static func makeVolatileCopy(of source: IrisPaths, at root: URL) throws -> IrisPaths {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for dir in [source.memoryDir, source.rulesDir, source.configDir, source.pluginsDir] {
            let dest = root.appendingPathComponent(dir.lastPathComponent)
            if fm.fileExists(atPath: dir.path) {
                try fm.copyItem(at: dir, to: dest)
            } else {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
        }
        let modelsLink = root.appendingPathComponent(source.modelsDir.lastPathComponent)
        if fm.fileExists(atPath: source.modelsDir.path) {
            try fm.createSymbolicLink(at: modelsLink, withDestinationURL: source.modelsDir)
        } else {
            try fm.createDirectory(at: modelsLink, withIntermediateDirectories: true)
        }
        return IrisPaths(root: root)
    }

    /// A digest of every file's relative path, size and modification time under `dir`.
    /// A perf run compares the real memory directory's fingerprint before and after so a leak
    /// through some path the copy does not cover fails loudly instead of silently.
    static func fingerprint(of dir: URL) -> String {
        let fm = FileManager.default
        var lines: [String] = []
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                if v?.isDirectory == true { continue }
                let rel = url.path.dropFirst(dir.path.count)
                lines.append("\(rel)|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// The conversation store (#163). At the root on purpose: `makeVolatileCopy` copies only
    /// memory/, rules/, config/ and plugins/, so a headless copy starts with no conversations,
    /// which is the choice `IrisDefaults.perfSeed` already made for the old blob.
    var conversationsDB: URL { root.appendingPathComponent("conversations.sqlite") }

    /// The lock the running app holds beside the store, so `iris --run-job` refuses rather than
    /// writing behind a live `AppState` (#187 §8). Held by `GUILock`; created at launch and
    /// removed at exit, with a dead pid in it treated as stale. Beside the database on purpose:
    /// it guards *that file*, and a volatile copy gets its own lock for its own store.
    var guiLockFile: URL { conversationsDB.appendingPathExtension("lock") }

    // memory/
    var memoryDir: URL { root.appendingPathComponent("memory") }
    var soulMd: URL { memoryDir.appendingPathComponent("SOUL.md") }
    var userMd: URL { memoryDir.appendingPathComponent("USER.md") }
    var memoryMd: URL { memoryDir.appendingPathComponent("memory.md") }
    var skillsDir: URL { memoryDir.appendingPathComponent("skills") }
    var artifactsDir: URL { memoryDir.appendingPathComponent("artifacts") }
    var libraryDir: URL { memoryDir.appendingPathComponent("library") }
    var factStoreDB: URL { memoryDir.appendingPathComponent("fact_store.sqlite") }
    var holographicDB: URL { memoryDir.appendingPathComponent("holographic_memory.sqlite") }

    // config/
    var configDir: URL { root.appendingPathComponent("config") }
    var settingsJSON: URL { configDir.appendingPathComponent("settings.json") }
    var permissionsJSON: URL { configDir.appendingPathComponent("permissions.json") }
    var mcpServersJSON: URL { configDir.appendingPathComponent("mcp_servers.json") }

    // rules/
    var rulesDir: URL { root.appendingPathComponent("rules") }

    // plugins/
    var pluginsDir: URL { root.appendingPathComponent("plugins") }
    var pluginsJSON: URL { configDir.appendingPathComponent("plugins.json") }

    // models/ (resolved path unchanged from the old layout)
    var modelsDir: URL { root.appendingPathComponent("models") }

    /// Goal workspaces created by `GoalWorkspace.resolve` (#68). Every directory directly under
    /// here was created by Iris; this is the eligibility boundary the workspace inventory (#126)
    /// uses to decide what it may ever list or delete.
    var workspacesDir: URL { root.appendingPathComponent("workspaces") }

    /// True if `rawPath` resolves to a location inside `memoryDir` — used to treat reads of
    /// first-party memory content (SOUL, USER, skills, artifacts, library, ...) as trusted.
    /// Tilde-expands and standardizes the path (resolving `..`) first, so a traversal like
    /// `memory/../models/x` does NOT count as inside memory. A trailing separator on the
    /// prefix check prevents a sibling like `memory-evil` from matching.
    func isUnderMemory(_ rawPath: String) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let mem = memoryDir.standardizedFileURL.path
        return resolved == mem || resolved.hasPrefix(mem + "/")
    }

    /// The directories a write into is a grant, not a file edit. `PermissionManager` never
    /// auto-allows one (#187):
    ///
    /// - `config/` holds permissions.json itself, the hook definitions and the plugin config, and
    ///   the allowlist is re-read on every call — one carved-out write there grants all the rest.
    /// - `plugins/` is the same thing one step removed: a plugin with an `mcp` component spawns a
    ///   command at the next launch, and `PluginState` defaults to enabled.
    ///
    /// `rules/` is deliberately NOT here: it is prompt persistence, which the guard already treats
    /// as untrusted content, not a way to make something execute.
    var protectedWriteDirs: [URL] { [configDir, pluginsDir] }

    /// True if `rawPath` resolves to a location inside one of `protectedWriteDirs`.
    ///
    /// Canonical, not merely standardized: APFS is case-insensitive by default, so `~/.iris/CONFIG`
    /// is the same directory as `~/.iris/config`, and a symlink planted in a writable directory
    /// (`memory/cfg -> config`) is a legal path to a protected target. Both sides go through
    /// `canonicalPath` and are compared case-insensitively. This is a DENY check only — never
    /// reuse it to widen an allow, where resolving a symlink the other way would let a link
    /// smuggle an outside path into the carve-out.
    func isUnderProtectedWriteDir(_ rawPath: String) -> Bool {
        let candidate = Self.canonicalPath(rawPath).lowercased()
        return protectedWriteDirs.contains { dir in
            let base = Self.canonicalPath(dir.path).lowercased()
            return candidate == base || candidate.hasPrefix(base + "/")
        }
    }

    /// Tilde-expanded, `..`-resolved, and with symlinks resolved on the deepest ancestor that
    /// actually exists — the file being written usually does not yet, and `resolvingSymlinksInPath`
    /// leaves a path alone when it cannot stat it.
    static func canonicalPath(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        let fm = FileManager.default
        var missing: [String] = []
        while !fm.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            missing.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    /// True if `rawPath` resolves to a location inside `root` (`~/.iris`).
    /// Tilde-expands and standardizes the path (resolving `..`) first.
    func isUnderIrisDir(_ rawPath: String) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return resolved == rootPath || resolved.hasPrefix(rootPath + "/")
    }

    /// Create the bucket directories if absent. Called by the migrator and by managers that
    /// need their directory to exist before writing.
    func ensureDirectories() throws {
        for dir in [memoryDir, skillsDir, artifactsDir, libraryDir, configDir, modelsDir, rulesDir, pluginsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
