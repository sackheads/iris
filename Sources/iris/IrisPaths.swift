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
    static var `default`: IrisPaths { lock.withLock { override } ?? processDefault }

    /// `standard`, except under `swift test`, where it is an empty home per test process (#304).
    /// Without it every `.shared` manager in the suite read and wrote the developer's real
    /// `~/.iris`, and invariant 7 held for it only by habit: one `allowGlobally` in a test wrote a
    /// real allow rule on every run (#290). Empty rather than a copy, so no assertion can depend
    /// on what the developer happens to have there. Same XCTest signal as `IrisDefaults`.
    /// Removed at exit, or — if a detached task was still writing, or the run was killed — by the
    /// next run's sweep.
    private static let processDefault: IrisPaths = {
        guard NSClassFromString("XCTestCase") != nil else { return standard }
        for stale in staleTestHomes(in: testHomesDir, isAlive: IrisDefaults.isProcessAlive) {
            try? FileManager.default.removeItem(at: stale)
        }
        let home = IrisPaths(root: testHomesDir.appendingPathComponent(
            String(ProcessInfo.processInfo.processIdentifier), isDirectory: true))
        try? FileManager.default.removeItem(at: home.root)   // a recycled pid's leftovers
        try? home.ensureDirectories()
        atexit { try? FileManager.default.removeItem(at: IrisPaths.processDefault.root) }
        return home
    }()

    /// One directory of our own for the test homes, each named by its pid. The sweep must never
    /// list `$TMPDIR` itself: `processDefault` is a `static let`, so every thread touching
    /// `default` parks until it returns, and a crowded temp directory (212k entries on one
    /// machine, ~8s in `contentsOfDirectory(atPath:)`) stalled the whole parallel run past
    /// unrelated suites' wall-clock bounds. This one holds an entry per test process at most.
    static let testHomesDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-tests-homes", isDirectory: true)

    /// Test homes under `directory` whose process is gone — a run that crashed or was killed
    /// before its atexit. This process and live runs are skipped.
    static func staleTestHomes(in directory: URL, isAlive: (pid_t) -> Bool) -> [URL] {
        let me = ProcessInfo.processInfo.processIdentifier
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().compactMap { name in
            guard let pid = pid_t(name), pid != me, !isAlive(pid) else { return nil }
            return directory.appendingPathComponent(name, isDirectory: true)
        }
    }

    /// The current identity's real home (`~/.iris` for the installed app, `~/.iris-dev` for every
    /// dev build and test process), regardless of any headless override. Isolation tests compare
    /// file existence here and at `release` before and after a run and must never create anything
    /// in either.
    static let standard = home(for: .current)

    /// The installed app's home, whatever this process is. Only `--seed-dev-home` reads it.
    static let release = home(for: .release)

    static func home(for identity: BuildIdentity,
                     homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> IrisPaths {
        IrisPaths(root: homeDirectory.appendingPathComponent(identity.homeDirectoryName, isDirectory: true))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: IrisPaths?

    /// True only inside a headless run that installed a copy. Under `swift test` this is false
    /// even though `default` is not the real home: that is `processDefault`, not an override.
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
    /// `realPath` and are compared case-insensitively. This is a DENY check only — never
    /// reuse it to widen an allow, where resolving a symlink the other way would let a link
    /// smuggle an outside path into the carve-out. Real paths, not `canonicalPath`: that one
    /// collapses `..` before following a symlink, and `link/../config` with `link → ~/.iris` is
    /// inside `config` on disk and outside it lexically (#282 §0.9).
    func isUnderProtectedWriteDir(_ rawPath: String) -> Bool {
        let candidate = Self.realPath(rawPath).lowercased()
        return protectedWriteDirs.contains { dir in
            let base = Self.realPath(dir.path).lowercased()
            return candidate == base || candidate.hasPrefix(base + "/")
        }
    }

    /// Tilde-expanded, `..`-resolved, and with symlinks resolved on the deepest ancestor that
    /// actually exists — the file being written usually does not yet, and `resolvingSymlinksInPath`
    /// leaves a path alone when it cannot stat it.
    static func canonicalPath(_ rawPath: String) -> String {
        let expanded = IrisEngine.expandTilde(rawPath)   // #275: never `expandingTildeInPath` on a decider
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

    /// The path the kernel would act on (#282 §0.9): tilde expanded, then `realpath(3)` of the
    /// deepest existing ancestor of the *unstandardised* components — so a symlink is followed
    /// before a `..` that follows it, which is the one thing `canonicalPath` gets wrong — with
    /// the remaining components appended. A `..` among the missing tail pops lexically: a
    /// directory that does not exist cannot be a symlink. `canonicalPath` stays for the callers
    /// that store and display paths; this is for deciding.
    ///
    /// One exception to "what the kernel would act on": a DANGLING final symlink (or a loop) is
    /// returned as its spelling under the resolved parent, while `open(O_CREAT)` would create the
    /// link's *target*. Three things hold that shut: `realPathForAllow` refuses it (an entry that
    /// `lstat` sees but `realpath(3)` cannot resolve is nil on the allow side), `ToolExecutor.writeFile`
    /// writes atomically, so its rename replaces the link rather than following it, and Task 4c's
    /// walk opens the final component `O_NOFOLLOW`. This lenient form is for the deny side.
    static func realPath(_ rawPath: String) -> String {
        realPath(rawPath, strict: false) ?? "/"   // strict: false never returns nil; `/` is the last resort
    }

    /// `realPath` for an *allow*: nil when the path is not absolute after tilde expansion, any
    /// component is `..` (§0.9) — a model never needs either inside a grant, and refusing them
    /// costs nothing a person could not have phrased without them — or the deepest existing
    /// entry will not resolve (a loop, a dangling link, EACCES, a component swapped between the
    /// existence check and `realpath(3)`): an allow must not step past what it could not see.
    static func realPathForAllow(_ rawPath: String) -> String? {
        let expanded = IrisEngine.expandTilde(rawPath)   // #275: never `expandingTildeInPath` on a decider
        guard expanded.hasPrefix("/") else { return nil }
        guard !expanded.split(separator: "/").contains("..") else { return nil }
        return realPath(expanded, strict: true)
    }

    /// The walk both forms share. Existence is `lstat`'s, not `stat`'s, so a symlink that does not
    /// resolve is met as the deepest existing entry and `realpath(3)` is asked about *it*: strict
    /// answers nil there; lenient steps back one more and appends the rest lexically, which is
    /// the answer the deny side has always had. Only `/` itself is trusted without asking.
    private static func realPath(_ rawPath: String, strict: Bool) -> String? {
        let expanded = IrisEngine.expandTilde(rawPath)   // #275: never `expandingTildeInPath` on a decider
        let absolute = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: expanded).path
        let components = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            .filter { $0 != "." }
        var existing = components.count
        var resolved = "/"
        while existing > 0 {
            let prefix = "/" + components[0..<existing].joined(separator: "/")
            var info = stat()
            if lstat(prefix, &info) == 0 {
                if let real = Darwin.realpath(prefix, nil) {
                    resolved = String(cString: real)
                    free(real)
                    break
                }
                if strict { return nil }
            }
            existing -= 1
        }
        for component in components[existing...] {
            if component == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
            } else {
                resolved = (resolved as NSString).appendingPathComponent(component)
            }
        }
        return resolved
    }

    /// True if `rawPath` resolves to a location inside `root` (`~/.iris`).
    /// Tilde-expands and standardizes the path (resolving `..`) first.
    func isUnderIrisDir(_ rawPath: String) -> Bool {
        let expanded = IrisEngine.expandTilde(rawPath)   // #275: never `expandingTildeInPath` on a decider
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return resolved == rootPath || resolved.hasPrefix(rootPath + "/")
    }

    /// `root` as the model should write it: `~/...` when under the user's home.
    var displayRoot: String {
        let home = NSHomeDirectory()
        let path = root.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Bundled text spells the home `~/.iris`. Rewrites it to `displayRoot` so a dev agent is
    /// pointed at `~/.iris-dev`, in prompts and in shell commands it copies from them.
    func agentFacing(_ text: String) -> String {
        text.replacing(/~\/\.iris(?![A-Za-z0-9_.\-])/, with: { _ in displayRoot })
    }

    /// Create the bucket directories if absent. Called by the migrator and by managers that
    /// need their directory to exist before writing.
    func ensureDirectories() throws {
        for dir in [memoryDir, skillsDir, artifactsDir, libraryDir, configDir, modelsDir, rulesDir, pluginsDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
